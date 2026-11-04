//! nox-bus-bridge (VM): the VM's apps use its own session bus (portals such
//! as ScreenCast hand over file descriptors, which no relayed bus can carry),
//! while notifications and the tray stay in dom0, on its filtered bus
//! (`/tmp/ssh_dbus.sock`, dom0's xdg-dbus-proxy decides what passes).
//!
//! - Imported (dom0 → VM): the bridge owns `org.freedesktop.Notifications`
//!   and the StatusNotifierWatcher names on the local bus and passes every
//!   call to dom0's bus, the answers and these services' signals back.
//! - Exported (VM → dom0): when an app registers a tray item with the
//!   watcher, the bridge opens a connection of its own to dom0's bus for it,
//!   owns `org.kde.StatusNotifierItem-<pid>-<n>` there (the names dom0's
//!   proxy lets VMs own), registers that name with dom0's watcher and passes
//!   dom0's calls (properties, Activate, the dbusmenu) to the app and the
//!   app's signals to dom0. When the app leaves the local bus, its item goes.
//!
//! Messages are copied as they are (header fields rewritten, body bytes
//! unchanged); file descriptors are not passed.
//!
//! `nox-bus-bridge --local <address> --remote <address>`

use std::collections::HashMap;
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::thread;

use zbus::blocking::{Connection, MessageIterator};
use zbus::message::{Flags, Message, Type};
use zbus::zvariant::ObjectPath;
use zbus::MatchRule;

const IMPORTED: &[&str] = &[
    "org.freedesktop.Notifications",
    "org.kde.StatusNotifierWatcher",
    "org.freedesktop.StatusNotifierWatcher",
];
const WATCHER_IFACES: &[&str] = &[
    "org.kde.StatusNotifierWatcher",
    "org.freedesktop.StatusNotifierWatcher",
];
const ITEM_PATH: &str = "/StatusNotifierItem";

/// A tray item of a local app, shown in dom0 under `remote_name`
struct Item {
    /// The app's unique name on the local bus
    owner: String,
    /// The name the app registered (well-known or unique), to see it leave
    local_name: String,
    /// The item's object path at the app
    path: String,
    remote_name: String,
    conn: Connection,
}

#[derive(Default)]
struct State {
    /// Local apps' calls, by serial of the copy sent on dom0's main connection
    to_remote: HashMap<u32, Message>,
    /// dom0's calls to tray items, by serial of the copy sent on the local
    /// bus: the item's connection to answer on and the call
    to_local: HashMap<u32, (Connection, Message)>,
    /// By remote name
    items: HashMap<String, Item>,
    next_item: u32,
}

#[derive(Clone)]
struct Bridge {
    local: Connection,
    remote: Connection,
    remote_address: String,
    state: Arc<Mutex<State>>,
}

fn serial(msg: &Message) -> u32 {
    msg.primary_header().serial_num().get()
}

/// The same body, raw
fn with_body(builder: zbus::message::Builder<'_>, msg: &Message) -> zbus::Result<Message> {
    let body = msg.body();
    let sig = body.signature().clone();
    // SAFETY: the bytes and signature come from a message that was valid
    unsafe { builder.build_raw_body(body.data().bytes(), sig, Vec::new()) }
}

/// A copy of a method call for another destination (and path)
fn copy_call(msg: &Message, destination: &str, path: &str) -> zbus::Result<Message> {
    let h = msg.header();
    let member = h
        .member()
        .ok_or_else(|| zbus::Error::Failure("call without member".into()))?;
    let mut b = Message::method_call(ObjectPath::try_from(path)?, member.as_str())?
        .destination(destination)?;
    if let Some(i) = h.interface() {
        b = b.interface(i.as_str())?;
    }
    if msg
        .primary_header()
        .flags()
        .contains(Flags::NoReplyExpected)
    {
        b = b.with_flags(Flags::NoReplyExpected)?;
    }
    with_body(b, msg)
}

/// The answer `reply` (return or error) as an answer to `call`
fn copy_reply(reply: &Message, call: &Message) -> zbus::Result<Message> {
    let call_header = call.header();
    let b = match reply.message_type() {
        Type::Error => {
            let h = reply.header();
            let name = h
                .error_name()
                .map(|n| n.as_str().to_owned())
                .unwrap_or_else(|| "org.freedesktop.DBus.Error.Failed".into());
            Message::error(&call_header, name)?
        }
        _ => Message::method_return(&call_header)?,
    };
    with_body(b, reply)
}

/// A copy of a signal, broadcast from this connection
fn copy_signal(msg: &Message, path: Option<&str>) -> zbus::Result<Message> {
    let h = msg.header();
    let (Some(p), Some(i), Some(m)) = (h.path(), h.interface(), h.member()) else {
        return Err(zbus::Error::Failure("incomplete signal".into()));
    };
    let path = ObjectPath::try_from(path.unwrap_or(p.as_str()))?;
    with_body(Message::signal(path, i.as_str(), m.as_str())?, msg)
}

/// The imported service a call to the bridge's unique name means
fn service_for(msg: &Message) -> Option<&'static str> {
    let h = msg.header();
    let path = h.path()?.as_str().to_owned();
    let iface = h.interface().map(|i| i.as_str().to_owned());
    match path.as_str() {
        "/org/freedesktop/Notifications" => Some(IMPORTED[0]),
        "/StatusNotifierWatcher" => {
            // Properties name the interface as their first argument
            let named = if iface.as_deref() == Some("org.freedesktop.DBus.Properties") {
                msg.body()
                    .deserialize::<(String,)>()
                    .ok()
                    .map(|(i,)| i)
                    .or_else(|| {
                        msg.body()
                            .deserialize::<(String, String)>()
                            .ok()
                            .map(|(i, _)| i)
                    })
                    .or_else(|| {
                        msg.body()
                            .deserialize::<(String, String, zbus::zvariant::OwnedValue)>()
                            .ok()
                            .map(|(i, _, _)| i)
                    })
            } else {
                iface
            };
            Some(
                if named.as_deref() == Some("org.freedesktop.StatusNotifierWatcher") {
                    IMPORTED[2]
                } else {
                    IMPORTED[1]
                },
            )
        }
        _ => None,
    }
}

fn error_reply(call: &Message, text: &str) -> zbus::Result<Message> {
    Message::error(&call.header(), "org.freedesktop.DBus.Error.Failed")?.build(&(text,))
}

impl Bridge {
    /// A local app's call to an imported service: on to dom0
    fn import_call(&self, msg: &Message, destination: &str) -> zbus::Result<()> {
        let h = msg.header();
        let iface = h.interface().map(|i| i.as_str().to_owned());
        let member = h.member().map(|m| m.as_str().to_owned());
        let path = h.path().map(|p| p.as_str().to_owned()).unwrap_or_default();
        let forwarded = if iface
            .as_deref()
            .is_some_and(|i| WATCHER_IFACES.contains(&i))
            && member.as_deref() == Some("RegisterStatusNotifierItem")
        {
            match self.export_item(msg) {
                Ok(remote_name) => Message::method_call(
                    ObjectPath::try_from(path.as_str())?,
                    "RegisterStatusNotifierItem",
                )?
                .destination(destination)?
                .interface(iface.as_deref().unwrap_or_default())?
                .build(&(remote_name.as_str(),))?,
                Err(e) => {
                    eprintln!("nox-bus-bridge: tray item: {e}");
                    return self.local.send(&error_reply(msg, &e.to_string())?);
                }
            }
        } else {
            copy_call(msg, destination, &path)?
        };
        let expects_reply = !msg
            .primary_header()
            .flags()
            .contains(Flags::NoReplyExpected);
        if expects_reply {
            self.state
                .lock()
                .unwrap()
                .to_remote
                .insert(serial(&forwarded), msg.clone());
        }
        self.remote.send(&forwarded)
    }

    /// An app registers a tray item: a connection to dom0 that owns a name
    /// for it. Returns that name.
    fn export_item(&self, msg: &Message) -> zbus::Result<String> {
        let h = msg.header();
        let owner = h
            .sender()
            .map(|s| s.as_str().to_owned())
            .ok_or_else(|| zbus::Error::Failure("no sender".into()))?;
        let arg: String = msg.body().deserialize()?;
        // The argument is a bus name (well-known or unique) or, from some
        // libraries, an object path at the sender
        let (local_name, path) = if arg.starts_with('/') {
            ObjectPath::try_from(arg.as_str())?;
            (owner.clone(), arg.clone())
        } else {
            (arg.clone(), ITEM_PATH.to_owned())
        };
        // The unique owner of a well-known name: answers come from it
        let item_owner = if local_name.starts_with(':') {
            local_name.clone()
        } else {
            let dbus = zbus::blocking::fdo::DBusProxy::new(&self.local)?;
            dbus.get_name_owner(local_name.as_str().try_into()?)?
                .as_str()
                .to_owned()
        };

        {
            // Registered again (an app re-registers after the watcher
            // restarted): keep the item it has
            let state = self.state.lock().unwrap();
            if let Some(item) = state
                .items
                .values()
                .find(|i| i.local_name == local_name && i.path == path)
            {
                return Ok(item.remote_name.clone());
            }
        }

        let n = {
            let mut state = self.state.lock().unwrap();
            state.next_item += 1;
            state.next_item
        };
        let remote_name = format!("org.kde.StatusNotifierItem-{}-{n}", std::process::id());
        let conn =
            zbus::blocking::connection::Builder::address(self.remote_address.as_str())?.build()?;
        // Before the name: calls for it may come right away
        let calls = MessageIterator::from(&conn);
        conn.request_name(remote_name.as_str())?;
        // The app's signals (NewIcon, dbusmenu, …)
        zbus::blocking::fdo::DBusProxy::new(&self.local)?.add_match_rule(
            MatchRule::builder()
                .msg_type(Type::Signal)
                .sender(item_owner.as_str())?
                .build(),
        )?;

        let item = Item {
            owner: item_owner,
            local_name,
            path,
            remote_name: remote_name.clone(),
            conn: conn.clone(),
        };
        self.state
            .lock()
            .unwrap()
            .items
            .insert(remote_name.clone(), item);
        let bridge = self.clone();
        let name = remote_name.clone();
        thread::spawn(move || bridge.serve_item(&name, calls));
        Ok(remote_name)
    }

    /// dom0's calls to an exported item: on to the app
    fn serve_item(&self, remote_name: &str, calls: MessageIterator) {
        for msg in calls {
            let Ok(msg) = msg else { break };
            if msg.message_type() != Type::MethodCall {
                continue;
            }
            let (owner, item_path, conn) = {
                let state = self.state.lock().unwrap();
                let Some(item) = state.items.get(remote_name) else {
                    break;
                };
                (item.owner.clone(), item.path.clone(), item.conn.clone())
            };
            let h = msg.header();
            let path = h.path().map(|p| p.as_str().to_owned()).unwrap_or_default();
            // dom0 asks for the item at the usual path; the app may use another
            let path = if path == ITEM_PATH { item_path } else { path };
            match copy_call(&msg, &owner, &path) {
                Ok(forwarded) => {
                    if !msg
                        .primary_header()
                        .flags()
                        .contains(Flags::NoReplyExpected)
                    {
                        self.state
                            .lock()
                            .unwrap()
                            .to_local
                            .insert(serial(&forwarded), (conn, msg.clone()));
                    }
                    if let Err(e) = self.local.send(&forwarded) {
                        eprintln!("nox-bus-bridge: to {owner}: {e}");
                    }
                }
                Err(e) => {
                    if let Ok(err) = error_reply(&msg, &e.to_string()) {
                        let _ = conn.send(&err);
                    }
                }
            }
        }
    }

    fn drop_items_of(&self, name: &str) {
        let gone: Vec<Item> = {
            let mut state = self.state.lock().unwrap();
            let names: Vec<String> = state
                .items
                .values()
                .filter(|i| i.owner == name || i.local_name == name)
                .map(|i| i.remote_name.clone())
                .collect();
            names.iter().filter_map(|n| state.items.remove(n)).collect()
        };
        for item in gone {
            // Releasing the name tells dom0's watcher the item is gone
            let _ = item.conn.release_name(item.remote_name.as_str());
            drop(item.conn);
        }
    }

    /// Everything that arrives on the local bus
    fn serve_local(&self, messages: MessageIterator) {
        for msg in messages {
            let Ok(msg) = msg else { break };
            let h = msg.header();
            match msg.message_type() {
                Type::MethodCall => {
                    let dest = h.destination().map(|d| d.as_str().to_owned());
                    let service = match dest.as_deref() {
                        Some(d) if IMPORTED.contains(&d) => Some(d),
                        // GDBus proxies call the name's owner, the bridge's
                        // unique name: the service by path and interface
                        Some(d) if Some(d) == self.local.unique_name().map(|u| u.as_str()) => {
                            service_for(&msg)
                        }
                        _ => None,
                    };
                    match service {
                        Some(d) => {
                            if let Err(e) = self.import_call(&msg, d) {
                                eprintln!("nox-bus-bridge: to dom0: {e}");
                                if let Ok(err) = error_reply(&msg, &e.to_string()) {
                                    let _ = self.local.send(&err);
                                }
                            }
                        }
                        _ => {
                            if let Ok(err) =
                                error_reply(&msg, "nox-bus-bridge forwards only its names")
                            {
                                let _ = self.local.send(&err);
                            }
                        }
                    }
                }
                Type::MethodReturn | Type::Error => {
                    let Some(rs) = h.reply_serial() else { continue };
                    let pending = self.state.lock().unwrap().to_local.remove(&rs.get());
                    if let Some((conn, call)) = pending {
                        match copy_reply(&msg, &call) {
                            Ok(reply) => {
                                let _ = conn.send(&reply);
                            }
                            Err(e) => eprintln!("nox-bus-bridge: answer to dom0: {e}"),
                        }
                    }
                }
                Type::Signal => {
                    let sender = h
                        .sender()
                        .map(|s| s.as_str().to_owned())
                        .unwrap_or_default();
                    if h.interface().map(|i| i.as_str()) == Some("org.freedesktop.DBus")
                        && h.member().map(|m| m.as_str()) == Some("NameOwnerChanged")
                    {
                        if let Ok((name, _old, new)) =
                            msg.body().deserialize::<(String, String, String)>()
                        {
                            if new.is_empty() {
                                self.drop_items_of(&name);
                            }
                        }
                        continue;
                    }
                    // An app's tray signal: on the item's connection in dom0
                    let targets: Vec<(Connection, String, String)> = {
                        let state = self.state.lock().unwrap();
                        state
                            .items
                            .values()
                            .filter(|i| i.owner == sender)
                            .map(|i| (i.conn.clone(), i.path.clone(), i.remote_name.clone()))
                            .collect()
                    };
                    for (conn, item_path, _) in targets {
                        let path = h.path().map(|p| p.as_str().to_owned()).unwrap_or_default();
                        let path = if path == item_path {
                            ITEM_PATH.to_owned()
                        } else {
                            path
                        };
                        if let Ok(signal) = copy_signal(&msg, Some(&path)) {
                            let _ = conn.send(&signal);
                        }
                    }
                }
            }
        }
        eprintln!("nox-bus-bridge: local bus gone");
        std::process::exit(1);
    }

    /// Everything that arrives on dom0's main connection
    fn serve_remote(&self, messages: MessageIterator) {
        for msg in messages {
            let Ok(msg) = msg else { break };
            let h = msg.header();
            match msg.message_type() {
                Type::MethodReturn | Type::Error => {
                    let Some(rs) = h.reply_serial() else { continue };
                    let call = self.state.lock().unwrap().to_remote.remove(&rs.get());
                    if let Some(call) = call {
                        match copy_reply(&msg, &call) {
                            Ok(reply) => {
                                let _ = self.local.send(&reply);
                            }
                            Err(e) => eprintln!("nox-bus-bridge: answer to an app: {e}"),
                        }
                    }
                }
                // The imported services' signals (notification closed or
                // clicked, watcher changes): to the local apps
                Type::Signal => {
                    if h.interface().map(|i| i.as_str()) == Some("org.freedesktop.DBus") {
                        continue;
                    }
                    if let Ok(signal) = copy_signal(&msg, None) {
                        let _ = self.local.send(&signal);
                    }
                }
                Type::MethodCall => {
                    if let Ok(err) = error_reply(&msg, "nothing here") {
                        let _ = self.remote.send(&err);
                    }
                }
            }
        }
        eprintln!("nox-bus-bridge: dom0's bus gone");
        std::process::exit(1);
    }
}

fn usage() -> ExitCode {
    eprintln!("usage: nox-bus-bridge --local <address> --remote <address>");
    ExitCode::from(2)
}

fn run(local_address: &str, remote_address: &str) -> zbus::Result<()> {
    let local = zbus::blocking::connection::Builder::address(local_address)?.build()?;
    let remote = zbus::blocking::connection::Builder::address(remote_address)?.build()?;
    // Streams before any name or match rule: nothing gets lost
    let local_messages = MessageIterator::from(&local);
    let remote_messages = MessageIterator::from(&remote);

    // The imported services' signals from dom0
    for name in IMPORTED {
        let rule = MatchRule::builder()
            .msg_type(Type::Signal)
            .sender(*name)?
            .build();
        zbus::blocking::fdo::DBusProxy::new(&remote)?.add_match_rule(rule)?;
    }
    // Apps leaving the local bus (their tray items go with them)
    let rule = MatchRule::builder()
        .msg_type(Type::Signal)
        .sender("org.freedesktop.DBus")?
        .interface("org.freedesktop.DBus")?
        .member("NameOwnerChanged")?
        .build();
    zbus::blocking::fdo::DBusProxy::new(&local)?.add_match_rule(rule)?;

    let bridge = Bridge {
        local: local.clone(),
        remote: remote.clone(),
        remote_address: remote_address.to_owned(),
        state: Arc::new(Mutex::new(State::default())),
    };
    let b = bridge.clone();
    thread::spawn(move || b.serve_remote(remote_messages));
    for name in IMPORTED {
        local.request_name(*name)?;
    }
    bridge.serve_local(local_messages);
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (mut local, mut remote) = (None, None);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--local" => local = it.next().cloned(),
            "--remote" => remote = it.next().cloned(),
            _ => return usage(),
        }
    }
    let (Some(local), Some(remote)) = (local, remote) else {
        return usage();
    };
    match run(&local, &remote) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("nox-bus-bridge: {e}");
            ExitCode::FAILURE
        }
    }
}

//! nox-screencast-portal (VM): an xdg-desktop-portal backend for
//! `org.freedesktop.impl.portal.ScreenCast` (bus name
//! `org.freedesktop.impl.portal.desktop.nox`). The VM has no screen of its
//! own: on `Start` it asks dom0 over the relay socket, dom0 lets the user
//! pick a window or an output (rofi) and sends that picture as an H.264
//! stream on the same connection. The receiver (`--receiver`, a program
//! that reads the stream on stdin, offers it as a PipeWire video source and
//! prints that node's id on stdout) turns it into the stream the app gets.
//!
//! Protocol on the socket: the VM writes `screencast <app id>\n`; dom0
//! answers one line, `ok <window|monitor>`, `cancel` or `error <text>`, and
//! after `ok` the H.264 byte stream follows. Closing the connection on
//! either side ends the share.
//!
//! `nox-screencast-portal --socket <path> --receiver <program>`

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, ExitCode, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};
use zbus::{interface, ObjectServer};

const BUS_NAME: &str = "org.freedesktop.impl.portal.desktop.nox";
const PATH: &str = "/org/freedesktop/portal/desktop";
// Portal response codes
const SUCCESS: u32 = 0;
const CANCELLED: u32 = 1;
const OTHER: u32 = 2;
// Source types (bit mask)
const MONITOR: u32 = 1;
const WINDOW: u32 = 2;
// Cursor modes: the cursor is part of the picture (dom0 casts it embedded)
const CURSOR_EMBEDDED: u32 = 2;

type Results = HashMap<String, OwnedValue>;

#[derive(Clone)]
struct Config {
    socket: PathBuf,
    receiver: PathBuf,
}

/// One share: the receiver (its process group) and the connection to dom0
struct Share {
    child: Child,
}

impl Drop for Share {
    fn drop(&mut self) {
        // The receiver's process group: the program and its pipeline
        let pid = self.child.id() as i32;
        unsafe {
            libc::kill(-pid, libc::SIGTERM);
        }
        let _ = self.child.wait();
    }
}

type Shares = Arc<Mutex<HashMap<OwnedObjectPath, Option<Share>>>>;

struct ScreenCast {
    config: Config,
    shares: Shares,
    /// Source types each session asked for (SelectSources `types`)
    types: Mutex<HashMap<OwnedObjectPath, u32>>,
}

/// App ids are reverse-DNS names; anything else becomes `?`
fn clean_app_id(app_id: &str) -> String {
    let s: String = app_id
        .chars()
        .take(64)
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') {
                c
            } else {
                '?'
            }
        })
        .collect();
    if s.is_empty() {
        "unknown".into()
    } else {
        s
    }
}

enum Outcome {
    Started {
        node: u32,
        source_type: u32,
        share: Share,
    },
    Cancelled,
    Failed(String),
}

/// Asks dom0, starts the receiver on the connection, waits for its node id.
/// Blocking: runs on its own thread.
fn start_share(config: &Config, app_id: &str, types: u32) -> Outcome {
    let mut conn = match UnixStream::connect(&config.socket) {
        Ok(c) => c,
        Err(e) => return Outcome::Failed(format!("{}: {e}", config.socket.display())),
    };
    if let Err(e) = writeln!(conn, "screencast {} {types}", clean_app_id(app_id)) {
        return Outcome::Failed(format!("request: {e}"));
    }
    // dom0's answer, byte by byte: what follows belongs to the receiver
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match conn.read(&mut byte) {
            Ok(1) if byte[0] == b'\n' => break,
            Ok(1) if line.len() < 256 => line.push(byte[0]),
            Ok(1) => return Outcome::Failed("answer too long".into()),
            Ok(_) => return Outcome::Failed("dom0 closed the connection".into()),
            Err(e) => return Outcome::Failed(format!("answer: {e}")),
        }
    }
    let answer = String::from_utf8_lossy(&line).into_owned();
    let source_type = match answer.as_str() {
        "ok window" => WINDOW,
        "ok monitor" => MONITOR,
        "cancel" => return Outcome::Cancelled,
        other => return Outcome::Failed(format!("dom0: {other}")),
    };
    // The portal frontend refuses a type the app did not ask for
    if source_type & types == 0 {
        return Outcome::Failed(format!("dom0 sent type {source_type}, asked for {types}"));
    }

    let stdin: OwnedFd = conn.into();
    let mut child = match Command::new(&config.receiver)
        .stdin(Stdio::from(stdin))
        .stdout(Stdio::piped())
        .process_group(0)
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return Outcome::Failed(format!("{}: {e}", config.receiver.display())),
    };
    let stdout = child.stdout.take().expect("piped stdout");
    let share = Share { child };
    let mut first = String::new();
    // The receiver prints the id once its node exists (or exits)
    match BufReader::new(stdout).read_line(&mut first) {
        Ok(n) if n > 0 => match first.trim().parse() {
            Ok(node) => Outcome::Started {
                node,
                source_type,
                share,
            },
            Err(_) => Outcome::Failed(format!("receiver: {}", first.trim())),
        },
        _ => Outcome::Failed("receiver ended without a node".into()),
    }
}

#[interface(name = "org.freedesktop.impl.portal.ScreenCast")]
impl ScreenCast {
    async fn create_session(
        &self,
        _handle: OwnedObjectPath,
        session_handle: OwnedObjectPath,
        _app_id: String,
        _options: HashMap<String, OwnedValue>,
        #[zbus(object_server)] server: &ObjectServer,
    ) -> (u32, Results) {
        let session = Session {
            path: session_handle.clone(),
            shares: self.shares.clone(),
        };
        match server.at(&session_handle, session).await {
            Ok(_) => {
                self.shares.lock().unwrap().insert(session_handle, None);
                (SUCCESS, Results::new())
            }
            Err(e) => {
                eprintln!("nox-screencast-portal: session: {e}");
                (OTHER, Results::new())
            }
        }
    }

    /// dom0 decides what is shared; the choice happens at Start
    async fn select_sources(
        &self,
        _handle: OwnedObjectPath,
        session_handle: OwnedObjectPath,
        _app_id: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, Results) {
        let types = options
            .get("types")
            .and_then(|v| u32::try_from(v).ok())
            .map(|t| t & (MONITOR | WINDOW))
            .filter(|t| *t != 0)
            .unwrap_or(MONITOR | WINDOW);
        self.types.lock().unwrap().insert(session_handle, types);
        (SUCCESS, Results::new())
    }

    async fn start(
        &self,
        _handle: OwnedObjectPath,
        session_handle: OwnedObjectPath,
        app_id: String,
        _parent_window: String,
        _options: HashMap<String, OwnedValue>,
    ) -> (u32, Results) {
        if !self.shares.lock().unwrap().contains_key(&session_handle) {
            return (OTHER, Results::new());
        }
        let types = self
            .types
            .lock()
            .unwrap()
            .get(&session_handle)
            .copied()
            .unwrap_or(MONITOR | WINDOW);
        let config = self.config.clone();
        let outcome = blocking::unblock(move || start_share(&config, &app_id, types)).await;
        match outcome {
            Outcome::Started {
                node,
                source_type,
                share,
            } => {
                let mut shares = self.shares.lock().unwrap();
                // The session may have been closed meanwhile: drop the share
                let Some(slot) = shares.get_mut(&session_handle) else {
                    return (OTHER, Results::new());
                };
                *slot = Some(share);
                let mut props: HashMap<String, OwnedValue> = HashMap::new();
                props.insert("source_type".into(), OwnedValue::from(source_type));
                let streams = vec![(node, props)];
                let mut results = Results::new();
                match OwnedValue::try_from(Value::from(streams)) {
                    Ok(v) => {
                        results.insert("streams".into(), v);
                        (SUCCESS, results)
                    }
                    Err(_) => (OTHER, Results::new()),
                }
            }
            Outcome::Cancelled => (CANCELLED, Results::new()),
            Outcome::Failed(e) => {
                eprintln!("nox-screencast-portal: {e}");
                (OTHER, Results::new())
            }
        }
    }

    #[zbus(property)]
    fn available_source_types(&self) -> u32 {
        MONITOR | WINDOW
    }

    #[zbus(property)]
    fn available_cursor_modes(&self) -> u32 {
        CURSOR_EMBEDDED
    }

    #[zbus(property, name = "version")]
    fn version(&self) -> u32 {
        5
    }
}

struct Session {
    path: OwnedObjectPath,
    shares: Shares,
}

#[interface(name = "org.freedesktop.impl.portal.Session")]
impl Session {
    async fn close(&self, #[zbus(object_server)] server: &ObjectServer) {
        // Dropping the share stops the receiver and closes dom0's connection
        let share = self.shares.lock().unwrap().remove(&self.path);
        drop(share);
        let _ = server.remove::<Session, _>(&self.path).await;
    }

    #[zbus(signal)]
    async fn closed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    #[zbus(property, name = "version")]
    fn version(&self) -> u32 {
        1
    }
}

fn usage() -> ExitCode {
    eprintln!("usage: nox-screencast-portal --socket <path> --receiver <program>");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut socket = None;
    let mut receiver = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--socket" => socket = it.next().map(PathBuf::from),
            "--receiver" => receiver = it.next().map(PathBuf::from),
            _ => return usage(),
        }
    }
    let (Some(socket), Some(receiver)) = (socket, receiver) else {
        return usage();
    };
    let shares: Shares = Arc::new(Mutex::new(HashMap::new()));
    let portal = ScreenCast {
        config: Config { socket, receiver },
        shares: shares.clone(),
        types: Mutex::new(HashMap::new()),
    };
    let conn = zbus::blocking::connection::Builder::session()
        .and_then(|b| b.serve_at(PATH, portal))
        .and_then(|b| b.name(BUS_NAME))
        .and_then(|b| b.build());
    let conn = match conn {
        Ok(c) => c,
        Err(e) => {
            eprintln!("nox-screencast-portal: {e}");
            return ExitCode::FAILURE;
        }
    };

    // Shares whose receiver ended (dom0 stopped the cast, the stream broke):
    // tell the frontend the session is over, so the app stops too
    loop {
        std::thread::sleep(Duration::from_secs(1));
        let ended: Vec<OwnedObjectPath> = {
            let mut shares = shares.lock().unwrap();
            shares
                .iter_mut()
                .filter_map(|(path, share)| {
                    let s = share.as_mut()?;
                    (!matches!(s.child.try_wait(), Ok(None))).then(|| path.clone())
                })
                .collect()
        };
        for path in ended {
            let share = shares.lock().unwrap().remove(&path);
            drop(share);
            let server = conn.object_server();
            if let Ok(iface) = server.interface::<_, Session>(&path) {
                let _ = zbus::block_on(Session::closed(iface.signal_emitter()));
            }
            let _ = server.remove::<Session, _>(&path);
        }
    }
}

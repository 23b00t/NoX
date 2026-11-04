//! nox-mutter-cast (dom0): casts one window or one output through the
//! compositor's `org.gnome.Mutter.ScreenCast` D-Bus API (niri offers it for
//! xdg-desktop-portal-gnome), without the portal and its dialog.
//!
//! `nox-mutter-cast window <id>` | `nox-mutter-cast output <connector>`
//! prints the PipeWire node id of the stream on stdout once it runs and keeps
//! the session until stdin reaches EOF (or SIGTERM/SIGINT, or the compositor
//! closes the session); then it stops the session and exits.
//!
//! The session belongs to this process's bus connection: when the process
//! dies, the compositor ends the cast.

use std::collections::HashMap;
use std::io::Read;
use std::process::ExitCode;
use std::sync::mpsc;
use std::thread;

use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::{OwnedObjectPath, Value};

const DEST: &str = "org.gnome.Mutter.ScreenCast";
const SESSION_IFACE: &str = "org.gnome.Mutter.ScreenCast.Session";
const STREAM_IFACE: &str = "org.gnome.Mutter.ScreenCast.Stream";
/// Mutter's cursor-mode: 0 hidden, 1 embedded, 2 metadata
const CURSOR_EMBEDDED: u32 = 1;

enum Source {
    Window(u64),
    Output(String),
}

fn usage() -> ExitCode {
    eprintln!("usage: nox-mutter-cast window <id> | output <connector>");
    ExitCode::from(2)
}

enum Stop {
    Eof,
    Closed,
}

fn run(source: Source) -> zbus::Result<()> {
    let conn = Connection::session()?;
    let cast = Proxy::new(&conn, DEST, "/org/gnome/Mutter/ScreenCast", DEST)?;
    let props: HashMap<&str, Value> = HashMap::new();
    let session: OwnedObjectPath = cast.call("CreateSession", &(props,))?;
    let session = Proxy::new(&conn, DEST, session, SESSION_IFACE)?;

    let mut props: HashMap<&str, Value> = HashMap::new();
    props.insert("cursor-mode", Value::U32(CURSOR_EMBEDDED));
    let stream: OwnedObjectPath = match &source {
        Source::Window(id) => {
            props.insert("window-id", Value::U64(*id));
            session.call("RecordWindow", &(props,))?
        }
        Source::Output(name) => session.call("RecordMonitor", &(name.as_str(), props))?,
    };
    let stream = Proxy::new(&conn, DEST, stream, STREAM_IFACE)?;

    // Subscribe before Start, the signal comes right after it
    let mut added = stream.receive_signal("PipeWireStreamAdded")?;
    let mut closed = session.receive_signal("Closed")?;
    session.call_method("Start", &())?;

    let node: u32 = match added.next() {
        Some(msg) => msg.body().deserialize()?,
        None => return Err(zbus::Error::Failure("no PipeWireStreamAdded".into())),
    };
    println!("{node}");

    let (tx, rx) = mpsc::channel();
    let eof = tx.clone();
    thread::spawn(move || {
        let mut buf = [0u8; 256];
        let mut stdin = std::io::stdin();
        while matches!(stdin.read(&mut buf), Ok(n) if n > 0) {}
        let _ = eof.send(Stop::Eof);
    });
    thread::spawn(move || {
        if closed.next().is_some() {
            let _ = tx.send(Stop::Closed);
        }
    });
    // SIGTERM/SIGINT: default action ends the process, the compositor sees
    // the connection go and stops the cast itself
    match rx.recv() {
        Ok(Stop::Closed) => {
            eprintln!("nox-mutter-cast: the compositor closed the session");
        }
        _ => {
            let _ = session.call_method("Stop", &());
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let source = match args.as_slice() {
        [kind, id] if kind == "window" => match id.parse() {
            Ok(id) => Source::Window(id),
            Err(_) => return usage(),
        },
        [kind, name] if kind == "output" => {
            if name.is_empty()
                || !name
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
            {
                return usage();
            }
            Source::Output(name.clone())
        }
        _ => return usage(),
    };
    match run(source) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("nox-mutter-cast: {e}");
            ExitCode::FAILURE
        }
    }
}

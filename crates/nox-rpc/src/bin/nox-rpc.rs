//! nox-rpc (guest): `nox-rpc <service> <target>` asks dom0 for the call; if
//! allowed, stdin goes to the target's handler and its output to stdout.
//!
//! nox-rpc (dom0): `nox-rpc --dom0 <service> <target>` calls the target's
//! `rpc-in` socket directly with the source `dom0`, no policy.
//! `nox-rpc --broker <service> <target> [as=<guest>] [max=<bytes>]` goes
//! through the broker's dom0 socket instead: policy (the user's own call:
//! `ask` counts as yes, `warn` and `deny` stay), copy manifest and limit.
//!
//! For `copy`, stdin starts with the manifest (`nox-pack`); it goes to the
//! broker before the answer, the tar stream after it.

use nox_rpc::{pipe, read_status, valid_name, Manifest, DOM0};
use std::io::{self, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::process::ExitCode;
use std::thread;

const DEFAULT_SOCKET: &str = "/run/nox-rpc.sock";
const DEFAULT_RPC_IN_DIR: &str = "/run/nox-relay";
const DEFAULT_BROKER_SOCKET: &str = "/run/nox-rpcd/dom0.sock";

const USAGE: &str = "usage: nox-rpc <service> <target>          (in a guest)\n       \
                     nox-rpc --dom0 <service> <target>   (in dom0, direct)\n       \
                     nox-rpc --broker <service> <target> [as=<guest>] [max=<bytes>]\n\
                     stdin goes to the target, its answer to stdout";

enum Mode {
    Guest,
    Dom0,
    Broker(Vec<String>),
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (mode, service, target) = match args.as_slice() {
        [flag, service, target] if flag == "--dom0" => (Mode::Dom0, service, target),
        [flag, service, target, opts @ ..] if flag == "--broker" => {
            (Mode::Broker(opts.to_vec()), service, target)
        }
        [service, target] => (Mode::Guest, service, target),
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    if !valid_name(service) || !valid_name(target) {
        eprintln!("nox-rpc: service and target: 1-32 of [a-z0-9-]");
        return ExitCode::from(2);
    }
    let result = match mode {
        Mode::Dom0 => {
            let dir = std::env::var("NOX_RPC_IN_DIR").unwrap_or_else(|_| DEFAULT_RPC_IN_DIR.into());
            let path = format!("{dir}/{target}-rpc-in.sock");
            match UnixStream::connect(&path) {
                // No relay socket (or nobody behind it): the domain is down
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                    ) =>
                {
                    eprintln!("nox-rpc: {target} is not running (no {path})");
                    return ExitCode::FAILURE;
                }
                conn => {
                    conn.and_then(|conn| call(conn, &format!("{service} {DOM0}\n"), false, false))
                }
            }
        }
        Mode::Guest => {
            let socket = std::env::var("NOX_RPC_SOCKET").unwrap_or_else(|_| DEFAULT_SOCKET.into());
            UnixStream::connect(socket).and_then(|conn| {
                call(
                    conn,
                    &format!("{service} {target}\n"),
                    true,
                    service == "copy",
                )
            })
        }
        Mode::Broker(opts) => {
            let socket = std::env::var("NOX_RPC_BROKER_SOCKET")
                .unwrap_or_else(|_| DEFAULT_BROKER_SOCKET.into());
            let mut header = format!("{service} {target}");
            for o in &opts {
                header.push(' ');
                header.push_str(o);
            }
            header.push('\n');
            UnixStream::connect(socket)
                .and_then(|conn| call(conn, &header, true, service == "copy"))
        }
    };
    match result {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("nox-rpc: {service} to {target}: {e}");
            ExitCode::FAILURE
        }
    }
}

/// Sends the header (and a copy's manifest from stdin), waits for dom0's
/// `ok` if `status`, then pipes stdin to the call and the call's output to
/// stdout until the call closes its side. Stdin may stay open (a terminal,
/// a pipe nobody closes): once the answer is complete there is nothing left
/// to send, so the upload is only waited for if it has already finished.
fn call(mut conn: UnixStream, header: &str, status: bool, manifest: bool) -> io::Result<bool> {
    conn.write_all(header.as_bytes())?;
    if manifest {
        // Stdin's buffer keeps whatever was read past the manifest for the
        // pipe below
        Manifest::read(&mut io::stdin().lock())?.write(&mut conn)?;
    }

    let mut answer = BufReader::new(conn.try_clone()?);
    if status {
        let status = read_status(&mut answer)?;
        if status != "ok" {
            eprintln!("nox-rpc: {}: {status}", header.trim_end());
            return Ok(false);
        }
    }

    let sender = conn.try_clone()?;
    let up = thread::spawn(move || {
        let r = pipe(io::stdin().lock(), &sender);
        let _ = sender.shutdown(Shutdown::Write);
        r
    });
    pipe(&mut answer, io::stdout().lock())?;
    if up.is_finished() {
        up.join().unwrap_or(Ok(0))?;
    }
    Ok(true)
}

//! nox-rpc (guest): `nox-rpc <service> <target>` asks dom0 for the call; if
//! allowed, stdin goes to the target's handler and its output to stdout.
//!
//! nox-rpc (dom0): `nox-rpc --dom0 <service> <target>` calls the target's
//! `rpc-in` socket directly with the source `dom0`, no policy.

use nox_rpc::{pipe, read_status, valid_name, DOM0};
use std::io::{self, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::process::ExitCode;
use std::thread;

const DEFAULT_SOCKET: &str = "/run/nox-rpc.sock";
const DEFAULT_RPC_IN_DIR: &str = "/run/nox-relay";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (dom0, service, target) = match args.as_slice() {
        [flag, service, target] if flag == "--dom0" => (true, service, target),
        [service, target] => (false, service, target),
        _ => {
            eprintln!(
                "usage: nox-rpc <service> <target>          (in a guest)\n       \
                 nox-rpc --dom0 <service> <target>   (in dom0)\n\
                 stdin goes to the target, its answer to stdout"
            );
            return ExitCode::from(2);
        }
    };
    if !valid_name(service) || !valid_name(target) {
        eprintln!("nox-rpc: service and target: 1-32 of [a-z0-9-]");
        return ExitCode::from(2);
    }
    let result = if dom0 {
        let dir = std::env::var("NOX_RPC_IN_DIR").unwrap_or_else(|_| DEFAULT_RPC_IN_DIR.into());
        UnixStream::connect(format!("{dir}/{target}-rpc-in.sock"))
            .and_then(|conn| call(conn, &format!("{service} {DOM0}\n"), false))
    } else {
        let socket = std::env::var("NOX_RPC_SOCKET").unwrap_or_else(|_| DEFAULT_SOCKET.into());
        UnixStream::connect(socket)
            .and_then(|conn| call(conn, &format!("{service} {target}\n"), true))
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

/// Sends the header, waits for dom0's `ok` if `status`, then pipes stdin to
/// the call and the call's output to stdout until both ends are done.
fn call(mut conn: UnixStream, header: &str, status: bool) -> io::Result<bool> {
    conn.write_all(header.as_bytes())?;

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
    up.join().unwrap_or(Ok(0))?;
    Ok(true)
}

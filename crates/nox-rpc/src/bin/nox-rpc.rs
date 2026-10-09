//! nox-rpc (guest): `nox-rpc <service> <target>` asks dom0 for the call; if
//! allowed, stdin goes to the target's handler and its output to stdout.

use nox_rpc::{pipe, read_status, valid_name};
use std::io::{self, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::process::ExitCode;
use std::thread;

const DEFAULT_SOCKET: &str = "/run/nox-rpc.sock";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [service, target] = args.as_slice() else {
        eprintln!(
            "usage: nox-rpc <service> <target>   (stdin to the target, its answer to stdout)"
        );
        return ExitCode::from(2);
    };
    if !valid_name(service) || !valid_name(target) {
        eprintln!("nox-rpc: service and target: 1-32 of [a-z0-9-]");
        return ExitCode::from(2);
    }
    match run(service, target) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("nox-rpc: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(service: &str, target: &str) -> io::Result<bool> {
    let socket = std::env::var("NOX_RPC_SOCKET").unwrap_or_else(|_| DEFAULT_SOCKET.into());
    let mut conn = UnixStream::connect(&socket)?;
    conn.write_all(format!("{service} {target}\n").as_bytes())?;

    let mut answer = BufReader::new(conn.try_clone()?);
    let status = read_status(&mut answer)?;
    if status != "ok" {
        eprintln!("nox-rpc: {service} to {target}: {status}");
        return Ok(false);
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

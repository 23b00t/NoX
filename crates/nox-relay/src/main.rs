//! nox-relay: carries Unix socket connections between two Xen domains over a
//! single vchan (see proto.rs for the framing, config.rs for the rules).
//!
//! One side offers the vchan (`--role server`, writes the ring to xenstore),
//! the other connects (`--role client`). Both exit when the peer goes away;
//! the service manager restarts them.

mod config;
mod proto;
mod relay;
mod vchan;

use std::process::ExitCode;
use std::time::Duration;

/// Client: connection attempts, 2 s apart, before giving up.
const CLIENT_ATTEMPTS: u32 = 15;

const USAGE: &str = "usage: nox-relay --role server|client --peer <domid> --path <xenstore-path> --config <file> [--ring <bytes>]";

struct Args {
    server: bool,
    peer: u32,
    path: String,
    config: String,
    ring: usize,
}

fn parse_args() -> Result<Args, String> {
    let mut role = None;
    let (mut peer, mut path, mut config, mut ring) = (None, None, None, 65536);
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or_else(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--role" => role = Some(value()?),
            "--peer" => peer = Some(value()?.parse::<u32>().map_err(|_| "--peer: domain id")?),
            "--path" => path = Some(value()?),
            "--config" => config = Some(value()?),
            "--ring" => ring = value()?.parse().map_err(|_| "--ring: bytes")?,
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    let server = match role.as_deref() {
        Some("server") => true,
        Some("client") => false,
        _ => return Err("--role server|client".into()),
    };
    Ok(Args {
        server,
        peer: peer.ok_or("--peer missing")?,
        path: path.ok_or("--path missing")?,
        config: config.ok_or("--config missing")?,
        ring,
    })
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let cfg = match std::fs::read_to_string(&args.config)
        .map_err(|e| e.to_string())
        .and_then(|t| config::parse(&t))
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{}: {e}", args.config);
            return ExitCode::from(2);
        }
    };
    // Sockets we create start private; listen rules set their mode
    // SAFETY: umask has no memory effects
    unsafe { libc::umask(0o077) };

    let vchan = if args.server {
        match vchan::Vchan::server(args.peer, &args.path, args.ring) {
            Ok(v) => v,
            Err(e) => {
                eprintln!(
                    "offering vchan at {} to domain {}: {e}",
                    args.path, args.peer
                );
                return ExitCode::FAILURE;
            }
        }
    } else {
        // The server may not be up yet (guest booting): keep trying for a
        // while, then exit. The domain id may also be stale (a guest that was
        // shutting down when it was looked up); the service manager restarts
        // us with a fresh one.
        let mut attempt = 0;
        loop {
            match vchan::Vchan::client(args.peer, &args.path) {
                Ok(v) => break v,
                Err(e) => {
                    if attempt == 0 {
                        eprintln!("waiting for domain {} at {}: {e}", args.peer, args.path);
                    }
                    attempt += 1;
                    if attempt >= CLIENT_ATTEMPTS {
                        eprintln!("domain {} did not offer the vchan, giving up", args.peer);
                        return ExitCode::FAILURE;
                    }
                    std::thread::sleep(Duration::from_secs(2));
                }
            }
        }
    };

    let result = relay::Relay::new(vchan, cfg, args.server).and_then(|mut r| r.run());
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

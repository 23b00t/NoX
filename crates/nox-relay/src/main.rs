//! nox-relay: carries Unix socket connections between two Xen domains over a
//! single vchan (see proto.rs for the framing, config.rs for the rules).
//!
//! One side offers the vchan (`--role server`, writes the ring to xenstore),
//! the other connects (`--role client`). Both exit when the peer goes away;
//! the service manager restarts them.

mod config;
mod grants;
mod proto;
mod relay;
mod vchan;

use std::process::ExitCode;
use std::time::Duration;

/// Client: connection attempts, `CLIENT_INTERVAL` apart, before giving up
/// (60 s: a guest booting under load offered its vchan only after ~40 s and
/// the restart cost seconds; every 0.5 s: connected right after the offer)
const CLIENT_ATTEMPTS: u32 = 120;
const CLIENT_INTERVAL: Duration = Duration::from_millis(500);

const USAGE: &str = "usage: nox-relay --role server|client --peer <domid> --path <xenstore-path> --config <file> [--ring <bytes>] [--ready-file <path>]";

struct Args {
    server: bool,
    peer: u32,
    path: String,
    config: String,
    ring: usize,
    /// Exists while the peer is connected (after its Hello), so the host can
    /// wait for a booted guest without SSH (boot order, uplink readiness)
    ready_file: Option<String>,
}

fn parse_args() -> Result<Args, String> {
    let mut role = None;
    let (mut peer, mut path, mut config, mut ring) = (None, None, None, 65536);
    let mut ready_file = None;
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or_else(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--role" => role = Some(value()?),
            "--peer" => peer = Some(value()?.parse::<u32>().map_err(|_| "--peer: domain id")?),
            "--path" => path = Some(value()?),
            "--config" => config = Some(value()?),
            "--ring" => ring = value()?.parse().map_err(|_| "--ring: bytes")?,
            "--ready-file" => ready_file = Some(value()?),
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
        ready_file,
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

    // Independent of the vchan: the fds it hands out outlive a reconnect
    if let Some(rule) = &cfg.grants {
        match relay::bind(rule).and_then(|l| grants::Broker::new(l, args.peer, args.server)) {
            Ok(broker) => broker.spawn(),
            Err(e) => eprintln!("grants: {e}"),
        }
    }

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
                    std::thread::sleep(CLIENT_INTERVAL);
                }
            }
        }
    };

    // A file left by a killed predecessor must not claim a connection
    if let Some(f) = &args.ready_file {
        let _ = std::fs::remove_file(f);
    }
    let result = relay::Relay::new(vchan, args.peer, cfg, args.server, args.ready_file.clone())
        .and_then(|mut r| r.run());
    if let Some(f) = &args.ready_file {
        let _ = std::fs::remove_file(f);
    }
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

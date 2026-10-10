//! nox-rpcd (dom0): one listening socket per source domain (relayed from that
//! domain's `rpc` service), policy check, then a byte pipe to the target's
//! `rpc-in` socket.

use nox_rpc::config::{self, Action, Config};
use nox_rpc::{parse_pair, pipe, read_line};
use std::fs;
use std::io::{self, Write};
use std::net::Shutdown;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::{Command, ExitCode};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let path = match args.as_slice() {
        [_, flag, path] if flag == "--config" => path,
        _ => {
            eprintln!("usage: nox-rpcd --config <file>");
            return ExitCode::from(2);
        }
    };
    let cfg = match fs::read_to_string(path)
        .map_err(|e| e.to_string())
        .and_then(|t| config::parse(&t))
    {
        Ok(c) => Arc::new(c),
        Err(e) => {
            eprintln!("{path}: {e}");
            return ExitCode::from(2);
        }
    };

    let mut threads = Vec::new();
    for (domain, socket) in &cfg.sources {
        let listener = match bind(socket) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("{}: {e}", socket.display());
                return ExitCode::FAILURE;
            }
        };
        let (cfg, domain) = (Arc::clone(&cfg), domain.clone());
        // One open `ask` per source: a guest must not flood the user with
        // questions
        let asking = Arc::new(AtomicBool::new(false));
        threads.push(thread::spawn(move || {
            for conn in listener.incoming().flatten() {
                let (cfg, domain, asking) = (Arc::clone(&cfg), domain.clone(), Arc::clone(&asking));
                thread::spawn(move || {
                    if let Err(e) = handle(conn, &domain, &cfg, &asking) {
                        eprintln!("{domain}: {e}");
                    }
                });
            }
        }));
    }
    for t in threads {
        let _ = t.join();
    }
    ExitCode::SUCCESS
}

fn bind(path: &Path) -> io::Result<UnixListener> {
    if let Ok(m) = fs::symlink_metadata(path) {
        if !m.file_type().is_socket() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "exists and is no socket",
            ));
        }
        fs::remove_file(path)?;
    }
    let l = UnixListener::bind(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(l)
}

fn handle(mut conn: UnixStream, source: &str, cfg: &Config, asking: &AtomicBool) -> io::Result<()> {
    conn.set_read_timeout(Some(Duration::from_secs(10)))?;
    let header = read_line(&mut conn)?;
    let Some((service, target)) = parse_pair(&header) else {
        conn.write_all(b"error bad header\n")?;
        return Ok(());
    };

    let action = match cfg.decide(service, source, target) {
        Action::Ask if asking.swap(true, Ordering::SeqCst) => {
            eprintln!("{service}: {source} -> {target}: a question is already open");
            Action::Deny
        }
        Action::Ask => {
            let a = ask(cfg, service, source, target);
            asking.store(false, Ordering::SeqCst);
            a
        }
        a => a,
    };
    eprintln!("{service}: {source} -> {target}: {action:?}");
    if action != Action::Allow {
        conn.write_all(b"denied\n")?;
        return Ok(());
    }

    let socket = cfg
        .target_socket(target)
        .expect("decide() checked the target");
    let mut remote = match UnixStream::connect(socket) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("{target}: {}: {e}", socket.display());
            conn.write_all(b"error target unreachable\n")?;
            return Ok(());
        }
    };
    remote.write_all(format!("{service} {source}\n").as_bytes())?;
    conn.write_all(b"ok\n")?;
    conn.set_read_timeout(None)?;

    // Both directions until EOF; half-close passes the end of input along
    let (conn_r, remote_w) = (conn.try_clone()?, remote.try_clone()?);
    let up = thread::spawn(move || {
        let r = pipe(&conn_r, &remote_w);
        let _ = remote_w.shutdown(Shutdown::Write);
        r
    });
    let down = pipe(&remote, &conn);
    let _ = conn.shutdown(Shutdown::Write);
    let up = up.join().unwrap_or(Ok(0));
    eprintln!(
        "{service}: {source} -> {target}: done ({} bytes up, {} down)",
        up.unwrap_or(0),
        down.unwrap_or(0)
    );
    Ok(())
}

/// Policy `ask`: the configured command decides (exit 0 = allow).
fn ask(cfg: &Config, service: &str, source: &str, target: &str) -> Action {
    let Some(cmd) = &cfg.ask_command else {
        return Action::Deny;
    };
    match Command::new(cmd).args([service, source, target]).status() {
        Ok(s) if s.success() => Action::Allow,
        Ok(_) => Action::Deny,
        Err(e) => {
            eprintln!("{}: {e}", cmd.display());
            Action::Deny
        }
    }
}

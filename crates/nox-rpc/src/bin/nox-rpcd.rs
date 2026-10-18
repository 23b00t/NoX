//! nox-rpcd (dom0): one listening socket per source domain (relayed from that
//! domain's `rpc` service), policy check, then a byte pipe to the target's
//! `rpc-in` socket.
//!
//! dom0's own calls come in on `dom0-socket` with the header
//! `<service> <target> [as=<guest>] [max=<bytes>]`: `as` names the guest dom0
//! acts for (`nox copy chat coding …`), `max` raises the copy limit.
//!
//! `copy` sends a manifest (entries, bytes, a few names) before its tar
//! stream: the broker shows it in the question and passes at most what it
//! announced (plus tar's overhead) and never more than `copy-limit`.

use nox_rpc::config::{self, Action, Config};
use nox_rpc::{parse_pair, pipe, pipe_limited, read_line, valid_name, Manifest, DOM0};
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

    // (socket, source domain; None = dom0's own socket)
    let mut sockets: Vec<(&Path, Option<String>)> = cfg
        .sources
        .iter()
        .map(|(d, s)| (s.as_path(), Some(d.clone())))
        .collect();
    if let Some(s) = &cfg.dom0_socket {
        sockets.push((s.as_path(), None));
    }

    let mut threads = Vec::new();
    for (socket, domain) in sockets {
        let listener = match bind(socket) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("{}: {e}", socket.display());
                return ExitCode::FAILURE;
            }
        };
        let cfg = Arc::clone(&cfg);
        // One open question per source: a guest must not flood the user with
        // questions
        let asking = Arc::new(AtomicBool::new(false));
        threads.push(thread::spawn(move || {
            for conn in listener.incoming().flatten() {
                let (cfg, domain, asking) = (Arc::clone(&cfg), domain.clone(), Arc::clone(&asking));
                thread::spawn(move || {
                    let name = domain.as_deref().unwrap_or(DOM0).to_string();
                    if let Err(e) = handle(conn, domain.as_deref(), &cfg, &asking) {
                        eprintln!("{name}: {e}");
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

/// A call as the broker sees it after the header
struct Call {
    service: String,
    target: String,
    /// The guest the call is for (the caller, or the one dom0 acts for);
    /// None = dom0 itself
    source: Option<String>,
    /// From dom0's socket: the user's own request
    by_dom0: bool,
    /// Copy limit dom0 asked for (`max=`)
    max: Option<u64>,
}

impl Call {
    fn source_name(&self) -> &str {
        self.source.as_deref().unwrap_or(DOM0)
    }
}

/// Guest sockets: `<service> <target>`. dom0's socket: the same plus
/// `as=<guest>` and `max=<bytes>`.
fn parse_header(header: &str, caller: Option<&str>) -> Option<Call> {
    let Some(caller) = caller else {
        let mut w = header.split(' ');
        let (service, target) = parse_pair(&format!("{} {}", w.next()?, w.next()?))
            .map(|(s, t)| (s.to_string(), t.to_string()))?;
        let mut call = Call {
            service,
            target,
            source: None,
            by_dom0: true,
            max: None,
        };
        for opt in w {
            match opt.split_once('=')? {
                ("as", g) if valid_name(g) && g != DOM0 => call.source = Some(g.into()),
                ("max", b) => call.max = Some(b.parse().ok()?),
                _ => return None,
            }
        }
        return Some(call);
    };
    let (service, target) = parse_pair(header)?;
    Some(Call {
        service: service.into(),
        target: target.into(),
        source: Some(caller.into()),
        by_dom0: false,
        max: None,
    })
}

fn handle(
    mut conn: UnixStream,
    caller: Option<&str>,
    cfg: &Config,
    asking: &AtomicBool,
) -> io::Result<()> {
    conn.set_read_timeout(Some(Duration::from_secs(10)))?;
    let header = read_line(&mut conn)?;
    let Some(call) = parse_header(&header, caller) else {
        conn.write_all(b"error bad header\n")?;
        return Ok(());
    };
    let (service, target, source) = (&call.service, &call.target, call.source_name());

    let manifest = if service == "copy" {
        match Manifest::read(&mut conn) {
            Ok(m) => Some(m),
            Err(e) => {
                eprintln!("{service}: {source} -> {target}: {e}");
                conn.write_all(b"error bad manifest\n")?;
                return Ok(());
            }
        }
    } else {
        None
    };
    let limit = match &manifest {
        Some(m) => {
            let max = call.max.unwrap_or(cfg.copy_limit);
            if m.bytes > max {
                eprintln!(
                    "{service}: {source} -> {target}: {} bytes, limit {max}",
                    m.bytes
                );
                conn.write_all(format!("error more than {max} bytes\n").as_bytes())?;
                return Ok(());
            }
            Some(m.allowance())
        }
        None => None,
    };

    let decided = if call.by_dom0 {
        cfg.decide_dom0(service, call.source.as_deref(), target)
    } else {
        cfg.decide(service, source, target)
    };
    let action = match decided {
        a @ (Action::Ask | Action::Warn) if asking.swap(true, Ordering::SeqCst) => {
            eprintln!("{service}: {source} -> {target}: a question is already open ({a:?})");
            Action::Deny
        }
        a @ (Action::Ask | Action::Warn) => {
            let answer = ask(cfg, &call, a, manifest.as_ref());
            asking.store(false, Ordering::SeqCst);
            answer
        }
        a => a,
    };
    eprintln!("{service}: {source} -> {target}: {decided:?} -> {action:?}");
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

    // Both directions until EOF; half-close passes the end of input along. A
    // copy that grows past its allowance is cut off: the target gets a
    // broken tar and keeps nothing
    let (conn_r, remote_w) = (conn.try_clone()?, remote.try_clone()?);
    let up = thread::spawn(move || {
        let r = match limit {
            Some(l) => pipe_limited(&conn_r, &remote_w, l),
            None => pipe(&conn_r, &remote_w),
        };
        let _ = remote_w.shutdown(if r.is_ok() {
            Shutdown::Write
        } else {
            Shutdown::Both
        });
        r
    });
    let down = pipe(&remote, &conn);
    let _ = conn.shutdown(Shutdown::Write);
    match up.join().unwrap_or(Ok(0)) {
        Ok(n) => eprintln!(
            "{service}: {source} -> {target}: done ({n} bytes up, {} down)",
            down.unwrap_or(0)
        ),
        Err(e) => eprintln!("{service}: {source} -> {target}: stopped: {e}"),
    }
    Ok(())
}

/// `ask`/`warn`: the configured command decides (exit 0 = allow). Args:
/// service source target ask|warn, for a copy also entries bytes names…
fn ask(cfg: &Config, call: &Call, action: Action, manifest: Option<&Manifest>) -> Action {
    let Some(cmd) = &cfg.ask_command else {
        return Action::Deny;
    };
    let mut args: Vec<String> = vec![
        call.service.clone(),
        call.source_name().into(),
        call.target.clone(),
        if action == Action::Warn {
            "warn"
        } else {
            "ask"
        }
        .into(),
    ];
    if let Some(m) = manifest {
        args.push(m.entries.to_string());
        args.push(m.bytes.to_string());
        args.extend(m.names.iter().cloned());
    }
    match Command::new(cmd).args(&args).status() {
        Ok(s) if s.success() => Action::Allow,
        Ok(_) => Action::Deny,
        Err(e) => {
            eprintln!("{}: {e}", cmd.display());
            Action::Deny
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headers() {
        let c = parse_header("copy coding", Some("chat")).unwrap();
        assert_eq!((c.source_name(), c.by_dom0), ("chat", false));
        assert!(parse_header("copy coding as=vault", Some("chat")).is_none());
        let d = parse_header("copy coding", None).unwrap();
        assert_eq!((d.source_name(), d.by_dom0, d.max), ("dom0", true, None));
        let d = parse_header("copy coding as=chat max=5", None).unwrap();
        assert_eq!((d.source_name(), d.max), ("chat", Some(5)));
        assert!(parse_header("copy coding as=dom0", None).is_none());
        assert!(parse_header("copy coding max=x", None).is_none());
        assert!(parse_header("copy coding what=1", None).is_none());
        assert!(parse_header("copy", None).is_none());
    }
}

//! `nox run`, `nox exec`: start a program in a VM.
//!
//! GUI programs and terminals go over wprs (vm-gui: wprs + app start by
//! RPC), `nox exec` (`cli`) runs a command in a terminal window of the VM
//! that stays open. Only the builder is reached by SSH. A stopped VM is
//! started first (or waited for, when its start is already queued at boot).
//! The domains come from the registry (`domains`).

use std::ffi::OsString;
use std::process::ExitCode;
use std::thread::sleep;
use std::time::Duration;

use crate::registry::{self, Domain};
use crate::sys;

fn usage(domains: &[Domain]) -> ExitCode {
    eprintln!("Usage: nox run <vm-name-or-short> <binary> [args...]");
    eprintln!("       nox exec <vm-name-or-short> <command> [args...]   (in a terminal of the VM; the builder: SSH)");
    eprintln!("Example: nox exec coding htop; nox exec builder uptime");
    eprintln!("Available VMs:");
    for d in domains {
        match &d.short {
            Some(s) if *s != d.name => eprintln!("  {} ({s})", d.name),
            _ => eprintln!("  {}", d.name),
        }
    }
    ExitCode::from(1)
}

/// What to run once the VM is up
#[derive(Debug, PartialEq)]
enum Action {
    Exec(&'static str, Vec<OsString>),
    Fail(String),
}

fn action(cli: bool, d: &Domain, prog: &OsString, args: &[OsString]) -> Action {
    let name = d.name.as_str();
    let os = |s: &str| OsString::from(s);
    if cli && d.wprs && name != "builder" {
        let mut cmd = prog.to_string_lossy().into_owned();
        for a in args {
            cmd.push(' ');
            cmd.push_str(&sys::shell_quote(&a.to_string_lossy()));
        }
        let argv = if d.foot_image {
            vec![
                os(name),
                os("/nix/store/nox/bin/foot"),
                os("--hold"),
                os("sh"),
                os("-c"),
                cmd.into(),
            ]
        } else if d.image {
            let cmd = format!("{cmd}; echo; read -r -p 'Enter: close ' _");
            vec![
                os(name),
                os("x-terminal-emulator"),
                os("-e"),
                os("sh"),
                os("-c"),
                cmd.into(),
            ]
        } else {
            vec![
                os(name),
                os("foot"),
                os("--hold"),
                os("sh"),
                os("-c"),
                cmd.into(),
            ]
        };
        return Action::Exec("vm-gui", argv);
    }
    if d.wprs && !cli {
        // Xen guest: wprs over vchan, app started by RPC, no SSH
        let mut argv = vec![os(name), prog.clone()];
        argv.extend(args.iter().cloned());
        return Action::Exec("vm-gui", argv);
    }
    // Without wprs only the builder is reachable, by SSH over vchan; the
    // other domains have no sshd
    if name != "builder" {
        return Action::Fail(format!(
            "nox run: {name} has no wprs and no SSH (emergency: sudo xl console {name}-vm)"
        ));
    }
    if !cli {
        return Action::Fail(
            "nox run: the builder runs no wprs, use nox exec builder <cmd> (SSH)".into(),
        );
    }
    let mut argv = vec![os("-t"), os("builder"), os("--"), prog.clone()];
    argv.extend(args.iter().cloned());
    Action::Exec("ssh", argv)
}

/// Starts the VM's unit, or waits for its queued start (at boot the
/// autostart VMs wait for nox-sys.target: starting again would ask polkit
/// once per VM)
fn ensure_running(d: &Domain) -> Result<(), ExitCode> {
    let service = d.service();
    if sys::is_active(&service) {
        return Ok(());
    }
    if sys::has_job(&service) {
        sys::notify(
            &format!("Waiting for VM: {}", d.name),
            "It is still starting...",
        );
        for _ in 0..300 {
            if !sys::has_job(&service) {
                break;
            }
            sleep(Duration::from_secs(1));
        }
    } else {
        sys::notify(&format!("Starting VM: {}", d.name), "Please wait...");
        let rc = sys::run("systemctl", ["start", service.as_str()]);
        if rc != 0 {
            return Err(ExitCode::from(rc.clamp(1, 255) as u8));
        }
    }
    Ok(())
}

/// `nox run <vm> <cmd…>` (cli = false), `nox exec <vm> <cmd…>` (cli = true)
pub fn main(cli: bool, vm: &str, cmd: &[OsString]) -> ExitCode {
    let domains = match registry::domains() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("nox run: {e:#}");
            return ExitCode::from(1);
        }
    };
    let Some(d) = registry::find(&domains, vm) else {
        eprintln!("Error: Unknown VM '{vm}'");
        return usage(&domains);
    };
    let Some((prog, args)) = cmd.split_first() else {
        return usage(&domains);
    };
    if let Err(code) = ensure_running(d) {
        return code;
    }
    match action(cli, d, prog, args) {
        Action::Exec(p, argv) => sys::exec(p, argv),
        Action::Fail(msg) => {
            eprintln!("{msg}");
            ExitCode::from(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn os(v: &[&str]) -> Vec<OsString> {
        v.iter().map(OsString::from).collect()
    }

    fn act(cli: bool, args: &[&str]) -> Action {
        let doms = registry::sample();
        let a = os(args);
        let d = registry::find(&doms, args[0]).unwrap().clone();
        action(cli, &d, &a[1], &a[2..])
    }

    #[test]
    fn actions() {
        assert_eq!(
            act(false, &["c", "firefox", "--private-window"]),
            Action::Exec("vm-gui", os(&["chat", "firefox", "--private-window"]))
        );
        assert_eq!(
            act(true, &["chat", "ls", "a b"]),
            Action::Exec(
                "vm-gui",
                os(&["chat", "foot", "--hold", "sh", "-c", "ls 'a b'"])
            )
        );
        assert_eq!(
            act(true, &["wg", "nmtui"]),
            Action::Exec(
                "vm-gui",
                os(&[
                    "whonix-gateway",
                    "/nix/store/nox/bin/foot",
                    "--hold",
                    "sh",
                    "-c",
                    "nmtui"
                ])
            )
        );
        assert_eq!(
            act(true, &["ww", "uname", "-a"]),
            Action::Exec(
                "vm-gui",
                os(&[
                    "whonix-workstation",
                    "x-terminal-emulator",
                    "-e",
                    "sh",
                    "-c",
                    "uname -a; echo; read -r -p 'Enter: close ' _"
                ])
            )
        );
        assert_eq!(
            act(true, &["builder", "uptime"]),
            Action::Exec("ssh", os(&["-t", "builder", "--", "uptime"]))
        );
        assert!(
            matches!(act(false, &["builder", "uptime"]), Action::Fail(m) if m.contains("use nox exec builder"))
        );
    }

    #[test]
    fn no_wprs_no_ssh() {
        let mut d = registry::sample()[0].clone();
        d.wprs = false;
        assert!(matches!(
            action(false, &d, &"x".into(), &[]),
            Action::Fail(m) if m == "nox run: chat has no wprs and no SSH (emergency: sudo xl console chat-vm)"
        ));
    }
}

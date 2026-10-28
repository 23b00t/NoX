//! `vm-run` (`nox run`, `nox exec`): start a program in a VM.
//!
//! GUI programs and terminals go over wprs (vm-gui: wprs + app start by
//! RPC), `-c` runs a command in a terminal window of the VM that stays open.
//! Only the builder is reached by SSH. A stopped VM is started first (or
//! waited for, when its start is already queued at boot). The domains come
//! from the registry (`domains`).

use std::ffi::OsString;
use std::process::ExitCode;
use std::thread::sleep;
use std::time::Duration;

use crate::registry::{self, Domain};
use crate::sys;

#[derive(Debug, Default, PartialEq)]
struct Opts {
    cli: bool,
    print_user: bool,
    ssh_args: Vec<OsString>,
    /// VM name or short alias, then the program and its arguments
    rest: Vec<OsString>,
}

/// getopts ":cue:h": options until the first word that is none, `--` ends
/// them; flags may be bundled (`-cu`), -e takes the rest or the next word
fn parse(args: &[OsString]) -> Result<Opts, String> {
    let mut o = Opts::default();
    let mut i = 0;
    while i < args.len() {
        let a = args[i].to_string_lossy();
        if a == "--" {
            i += 1;
            break;
        }
        if !a.starts_with('-') || a == "-" {
            break;
        }
        let chars: Vec<char> = a.chars().skip(1).collect();
        let mut j = 0;
        while j < chars.len() {
            match chars[j] {
                'c' => o.cli = true,
                'u' => o.print_user = true,
                'h' => return Err(String::new()),
                'e' => {
                    let attached: String = chars[j + 1..].iter().collect();
                    if !attached.is_empty() {
                        o.ssh_args.push(attached.into());
                    } else if i + 1 < args.len() {
                        i += 1;
                        o.ssh_args.push(args[i].clone());
                    } else {
                        return Err("Option -e requires an argument.".into());
                    }
                    break;
                }
                c => return Err(format!("Unknown option: -{c}")),
            }
            j += 1;
        }
        i += 1;
    }
    o.rest = args[i..].to_vec();
    Ok(o)
}

fn usage(domains: &[Domain]) -> ExitCode {
    eprintln!("Usage: vm-run [-c] [-u] [-e <ssh-arg>]... <vm-name-or-short> <binary> [args...]");
    eprintln!("  -c: in a terminal of the VM (foot over wprs; the builder: SSH, -e for ssh)");
    eprintln!("       vm-run -u <vm-name-or-short>");
    eprintln!("Example: vm-run -c coding htop; vm-run -c -e -v builder uptime");
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

fn action(o: &Opts, d: &Domain, prog: &OsString, args: &[OsString]) -> Action {
    let name = d.name.as_str();
    let os = |s: &str| OsString::from(s);
    if o.cli && d.wprs && name != "builder" {
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
    if d.wprs && !o.cli {
        // Xen guest: wprs over vchan, app started by RPC, no SSH
        let mut argv = vec![os(name), prog.clone()];
        argv.extend(args.iter().cloned());
        return Action::Exec("vm-gui", argv);
    }
    // Without wprs only the builder is reachable, by SSH over vchan; the
    // other domains have no sshd
    if name != "builder" {
        return Action::Fail(format!(
            "vm-run: {name} has no wprs and no SSH (emergency: sudo xl console {name}-vm)"
        ));
    }
    if !o.cli {
        return Action::Fail(
            "vm-run: the builder runs no wprs, use vm-run -c builder <cmd> (SSH)".into(),
        );
    }
    let mut argv = o.ssh_args.clone();
    argv.extend([os("-t"), os("builder"), os("--"), prog.clone()]);
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

pub fn main(args: &[OsString]) -> ExitCode {
    let domains = match registry::domains() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("vm-run: {e:#}");
            return ExitCode::from(1);
        }
    };
    let o = match parse(args) {
        Ok(o) => o,
        Err(msg) => {
            if !msg.is_empty() {
                eprintln!("{msg}");
            }
            return usage(&domains);
        }
    };
    let Some((key, rest)) = o.rest.split_first() else {
        return usage(&domains);
    };
    let key = key.to_string_lossy();
    let Some(d) = registry::find(&domains, &key) else {
        eprintln!("Error: Unknown VM '{key}'");
        return ExitCode::from(1);
    };
    if o.print_user {
        println!("{}", d.user);
        return ExitCode::SUCCESS;
    }
    let Some((prog, args)) = rest.split_first() else {
        return usage(&domains);
    };
    if let Err(code) = ensure_running(d) {
        return code;
    }
    match action(&o, d, prog, args) {
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

    #[test]
    fn options() {
        let o = parse(&os(&["-c", "coding", "htop", "-d", "1"])).unwrap();
        assert!(o.cli && !o.print_user);
        assert_eq!(o.rest, os(&["coding", "htop", "-d", "1"]));
        let o = parse(&os(&["-c", "-e", "-v", "-e-4", "builder", "uptime"])).unwrap();
        assert_eq!(o.ssh_args, os(&["-v", "-4"]));
        let o = parse(&os(&["-cu", "chat"])).unwrap();
        assert!(o.cli && o.print_user);
        let o = parse(&os(&["--", "-x"])).unwrap();
        assert_eq!(o.rest, os(&["-x"]));
        assert_eq!(
            parse(&os(&["-x", "chat"])),
            Err("Unknown option: -x".into())
        );
        assert_eq!(
            parse(&os(&["-e"])),
            Err("Option -e requires an argument.".into())
        );
        assert_eq!(parse(&os(&["-h"])), Err(String::new()));
    }

    fn act(args: &[&str]) -> Action {
        let doms = registry::sample();
        let o = parse(&os(args)).unwrap();
        let d = registry::find(&doms, &o.rest[0].to_string_lossy())
            .unwrap()
            .clone();
        action(&o, &d, &o.rest[1], &o.rest[2..])
    }

    #[test]
    fn actions() {
        assert_eq!(
            act(&["c", "firefox", "--private-window"]),
            Action::Exec("vm-gui", os(&["chat", "firefox", "--private-window"]))
        );
        assert_eq!(
            act(&["-c", "chat", "ls", "a b"]),
            Action::Exec(
                "vm-gui",
                os(&["chat", "foot", "--hold", "sh", "-c", "ls 'a b'"])
            )
        );
        assert_eq!(
            act(&["-c", "wg", "nmtui"]),
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
            act(&["-c", "ww", "uname", "-a"]),
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
            act(&["-c", "-e", "-v", "builder", "uptime"]),
            Action::Exec("ssh", os(&["-v", "-t", "builder", "--", "uptime"]))
        );
        assert!(
            matches!(act(&["builder", "uptime"]), Action::Fail(m) if m.contains("use vm-run -c builder"))
        );
    }

    #[test]
    fn no_wprs_no_ssh() {
        let mut d = registry::sample()[0].clone();
        d.wprs = false;
        let o = Opts::default();
        assert!(matches!(
            action(&o, &d, &"x".into(), &[]),
            Action::Fail(m) if m == "vm-run: chat has no wprs and no SSH (emergency: sudo xl console chat-vm)"
        ));
    }
}

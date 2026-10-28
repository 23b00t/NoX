//! `manage-vms` (`nox list|start|stop|restart`): status table and
//! start/stop/restart/reload of VMs and image domains (microvm@… /
//! xen-image@…), filtered by state, store group and stale image; `--fresh`
//! for disposable VMs. A started VM gets its tray apps and session windows
//! again (vm-tray, vm-autostart). The domains come from the registry.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::Path;
use std::process::ExitCode;

use crate::registry::{self, Domain};
use crate::sys;

const STATE_DIR: &str = "/var/lib/microvms";

const USAGE: &str = "Usage:
  manage-vms status [<vm>...] [--running] [--group <group>] [--stale]
  manage-vms <start|stop|restart|reload> [<vm>...] [--running] [--group <group>] [--stale]
  manage-vms <start|restart> --fresh <vm>...

  <vm>...          these VMs (default: all), narrowed by the filters
  --group <group>  only VMs of this store group (registry storeGroup)
  --stale          only running VMs whose store image differs from the
                   current one (e.g. after a group update)
  --fresh          disposable VMs only (registry disposable): stop, set all
                   their volume images aside (<image>.pre-fresh, needs sudo),
                   start with empty ones. Back: stop the VM, move the
                   .pre-fresh files back, start it

A VM that gets started or restarted gets its tray apps again (vm-tray)
and its missing windows from the session start (vm-autostart).

Examples:
  manage-vms status
  manage-vms status --running
  manage-vms start chat
  manage-vms restart --running
  manage-vms restart --stale
  manage-vms restart --group desktop";

fn usage() -> ExitCode {
    eprintln!("{USAGE}");
    ExitCode::from(1)
}

#[derive(Debug, Default, PartialEq)]
struct Opts {
    command: String,
    names: Vec<String>,
    running: bool,
    stale: bool,
    fresh: bool,
    group: Option<String>,
}

enum Parsed {
    Ok(Opts),
    Usage,
    Fail(String),
}

fn parse(args: &[String], domains: &[Domain]) -> Parsed {
    let Some((command, rest)) = args.split_first() else {
        return Parsed::Usage;
    };
    let mut o = Opts {
        command: command.clone(),
        ..Opts::default()
    };
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--running" => o.running = true,
            "--stale" => o.stale = true,
            "--fresh" => o.fresh = true,
            "--group" => match it.next() {
                Some(g) => o.group = Some(g.clone()),
                None => return Parsed::Usage,
            },
            "-h" | "--help" | "help" => return Parsed::Usage,
            s if s.starts_with('-') => {
                eprintln!("Unknown argument: {s}");
                return Parsed::Usage;
            }
            s if domains.iter().any(|d| d.name == s) => o.names.push(s.to_string()),
            s => return Parsed::Fail(format!("Unknown VM: {s}")),
        }
    }
    Parsed::Ok(o)
}

/// ok | stale | - (not running, or the runner has no store image)
fn image_state(vm: &str) -> &'static str {
    let dir = Path::new(STATE_DIR).join(vm);
    let booted = dir.join("booted");
    if !booted.exists() {
        return "-";
    }
    match store_image(&booted) {
        None => "-",
        Some(b) if Some(&b) == store_image(&dir.join("current")).as_ref() => "ok",
        Some(_) => "stale",
    }
}

/// Store image a runner boots from (none: e.g. a virtiofs store)
fn store_image(runner: &Path) -> Option<String> {
    if !runner.exists() {
        return None;
    }
    sys::output("nix-store", [OsString::from("-qR"), runner.into()])?
        .lines()
        .find(|l| l.contains("-microvm-store-disk."))
        .map(str::to_string)
}

fn running_vms() -> Vec<String> {
    let out = sys::output(
        "systemctl",
        [
            "list-units",
            "--type=service",
            "--state=running",
            "--no-legend",
            "--no-pager",
            "microvm@*.service",
            "xen-image@*.service",
        ],
    )
    .unwrap_or_default();
    out.lines()
        .filter_map(|l| l.split_whitespace().next())
        .filter_map(|u| u.split_once('@'))
        .map(|(_, rest)| rest.trim_end_matches(".service").to_string())
        .collect()
}

fn targets<'a>(o: &Opts, domains: &'a [Domain]) -> Vec<&'a Domain> {
    let by_name = |n: &str| domains.iter().find(|d| d.name == n);
    let candidates: Vec<&Domain> = if !o.names.is_empty() {
        o.names
            .iter()
            .filter_map(|n| by_name(n))
            .filter(|d| !o.running || sys::is_active(&d.service()))
            .collect()
    } else if o.running {
        // A running unit the registry doesn't know is left out
        running_vms().iter().filter_map(|n| by_name(n)).collect()
    } else {
        domains.iter().collect()
    };
    candidates
        .into_iter()
        .filter(|d| o.group.is_none() || d.store_group == o.group)
        .filter(|d| !o.stale || image_state(&d.name) == "stale")
        .collect()
}

/// ActiveState, SubState, UnitFileState of the units, one systemctl call
fn unit_states(units: &[String]) -> HashMap<String, (String, String, String)> {
    let mut args = vec![
        "show".to_string(),
        "-p".into(),
        "Id,ActiveState,SubState,UnitFileState".into(),
    ];
    args.extend(units.iter().cloned());
    parse_show(&sys::output("systemctl", &args).unwrap_or_default())
}

fn parse_show(text: &str) -> HashMap<String, (String, String, String)> {
    let mut out = HashMap::new();
    for block in text.split("\n\n") {
        let mut f: HashMap<&str, &str> = HashMap::new();
        for line in block.lines() {
            if let Some((k, v)) = line.split_once('=') {
                f.insert(k, v);
            }
        }
        if let Some(id) = f.get("Id") {
            let get = |k| f.get(k).copied().unwrap_or("").to_string();
            out.insert(
                id.to_string(),
                (get("ActiveState"), get("SubState"), get("UnitFileState")),
            );
        }
    }
    out
}

fn or_dash(s: &str) -> &str {
    if s.is_empty() {
        "-"
    } else {
        s
    }
}

fn row(cols: [&str; 6]) -> String {
    format!(
        "{:<14} {:<10} {:<12} {:<10} {:<9} {:<6}",
        cols[0], cols[1], cols[2], cols[3], cols[4], cols[5]
    )
}

fn status(targets: &[&Domain]) {
    let units: Vec<String> = targets.iter().map(|d| d.service()).collect();
    let states = unit_states(&units);
    println!(
        "{}",
        row(["VM", "ACTIVE", "SUBSTATE", "ENABLED", "GROUP", "IMAGE"])
    );
    println!(
        "{}",
        row([
            "--------------",
            "----------",
            "------------",
            "----------",
            "---------",
            "------"
        ])
    );
    for d in targets {
        let empty = (String::new(), String::new(), String::new());
        let (active, sub, enabled) = states.get(&d.service()).unwrap_or(&empty);
        println!(
            "{}",
            row([
                &d.name,
                if active.is_empty() {
                    "not-found"
                } else {
                    active
                },
                or_dash(sub),
                or_dash(enabled),
                d.store_group.as_deref().unwrap_or("-"),
                image_state(&d.name),
            ])
        );
    }
}

/// --fresh: stop each (disposable) target and set its volume images aside;
/// the start then makes empty ones (the runner creates them)
fn fresh_images(o: &Opts, targets: &[&Domain]) -> Result<(), ExitCode> {
    if o.names.is_empty() {
        eprintln!("--fresh needs VM names");
        return Err(ExitCode::from(1));
    }
    if let Some(d) = targets.iter().find(|d| !d.disposable) {
        eprintln!("{} is not disposable (registry), --fresh refused", d.name);
        return Err(ExitCode::from(1));
    }
    for d in targets {
        let unit = d.service();
        println!("sudo systemctl stop {unit}");
        let rc = sys::run("sudo", ["systemctl", "stop", unit.as_str()]);
        if rc != 0 {
            return Err(code(rc));
        }
        // Image files are root's: sudo with password
        let dir = format!("{STATE_DIR}/{}", d.name);
        let rc = sys::run(
            "sudo",
            [
                "sh",
                "-c",
                r#"cd "$1" || exit 0; for f in *.img; do [ -e "$f" ] || continue; mv -f "$f" "$f.pre-fresh" && echo "set aside: $1/$f.pre-fresh"; done"#,
                "sh",
                dir.as_str(),
            ],
        );
        if rc != 0 {
            return Err(code(rc));
        }
    }
    Ok(())
}

fn code(rc: i32) -> ExitCode {
    ExitCode::from(rc.clamp(1, 255) as u8)
}

fn act(action: &str, targets: &[&Domain]) -> ExitCode {
    let mut rc = 0;
    for d in targets {
        let unit = d.service();
        let was_active = sys::is_active(&unit);
        println!("sudo systemctl {action} {unit}");
        // sudo: NOPASSWD for start/stop/restart of microvm@ and xen-image@
        if sys::run("sudo", ["systemctl", action, unit.as_str()]) != 0 {
            rc = 1;
            continue;
        }
        let started = action == "restart" || (action == "start" && !was_active);
        if started && sys::on_path("vm-tray") {
            let r = sys::run("vm-tray", [d.name.as_str()]);
            if r != 0 {
                return code(r);
            }
            // and its windows from the session start (terminal tab, zen, …)
            if sys::on_path("vm-autostart") {
                let r = sys::run("vm-autostart", [d.name.as_str()]);
                if r != 0 {
                    return code(r);
                }
            }
        }
    }
    ExitCode::from(rc)
}

pub fn main(args: &[OsString]) -> ExitCode {
    let domains = match registry::domains() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("manage-vms: {e:#}");
            return ExitCode::from(1);
        }
    };
    let args: Vec<String> = args
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let o = match parse(&args, &domains) {
        Parsed::Ok(o) => o,
        Parsed::Usage => return usage(),
        Parsed::Fail(msg) => {
            eprintln!("{msg}");
            return ExitCode::from(1);
        }
    };
    let targets = targets(&o, &domains);
    if targets.is_empty() {
        println!("No matching VMs found.");
        return ExitCode::SUCCESS;
    }
    match o.command.as_str() {
        "status" => {
            status(&targets);
            ExitCode::SUCCESS
        }
        "start" | "restart" => {
            if o.fresh {
                if let Err(c) = fresh_images(&o, &targets) {
                    return c;
                }
            }
            act(&o.command, &targets)
        }
        "stop" | "reload" => {
            if o.fresh {
                eprintln!("--fresh only with start or restart");
                return ExitCode::from(1);
            }
            act(&o.command, &targets)
        }
        c => {
            eprintln!("Unsupported command: {c}");
            usage()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> Parsed {
        let a: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        parse(&a, &registry::sample())
    }

    #[test]
    fn arguments() {
        let Parsed::Ok(o) = p(&["restart", "--group", "desktop", "chat", "--stale"]) else {
            panic!()
        };
        assert_eq!(o.command, "restart");
        assert_eq!(o.names, ["chat"]);
        assert_eq!(o.group.as_deref(), Some("desktop"));
        assert!(o.stale && !o.running && !o.fresh);
        // full names only, like the script
        assert!(matches!(p(&["start", "c"]), Parsed::Fail(m) if m == "Unknown VM: c"));
        assert!(matches!(p(&[]), Parsed::Usage));
        assert!(matches!(p(&["status", "--group"]), Parsed::Usage));
        assert!(matches!(p(&["status", "--bogus"]), Parsed::Usage));
        assert!(matches!(p(&["status", "help"]), Parsed::Usage));
    }

    #[test]
    fn filters_without_systemd() {
        let doms = registry::sample();
        let all = Opts {
            command: "status".into(),
            ..Opts::default()
        };
        assert_eq!(targets(&all, &doms).len(), 5);
        let group = Opts {
            group: Some("desktop".into()),
            ..Opts::default()
        };
        let t = targets(&group, &doms);
        assert_eq!(t.len(), 1);
        assert_eq!(t[0].name, "chat");
        let named = Opts {
            names: vec!["disp".into(), "builder".into()],
            ..Opts::default()
        };
        let t: Vec<&str> = targets(&named, &doms)
            .iter()
            .map(|d| d.name.as_str())
            .collect();
        assert_eq!(t, ["disp", "builder"]);
    }

    #[test]
    fn systemctl_show_blocks() {
        let s = parse_show(
            "Id=microvm@chat.service\nActiveState=active\nSubState=running\nUnitFileState=enabled\n\n\
             Id=xen-image@x.service\nActiveState=inactive\nSubState=dead\nUnitFileState=\n",
        );
        assert_eq!(
            s["microvm@chat.service"],
            ("active".into(), "running".into(), "enabled".into())
        );
        assert_eq!(s["xen-image@x.service"].2, "");
        assert_eq!(or_dash(&s["xen-image@x.service"].2), "-");
    }
}

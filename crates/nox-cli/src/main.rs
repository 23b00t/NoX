//! nox: one command for the NoX tools in dom0.
//!
//! A thin wrapper for now: every subcommand execs the script that does the
//! work (manage-vms, vm-run, vm-clip, nox-copy, dom0-update, update-all,
//! vm-usb), found on PATH, so its output and exit code are the script's own.

use std::ffi::OsString;
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode};

use clap::{Args, Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "nox",
    version,
    about = "Manage the NoX domains from dom0",
    long_about = "Manage the NoX domains from dom0.\n\nWithout a command: the running VMs (`nox list --running`)."
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Cmd>,
}

/// Which VMs a command applies to. Names and filters combine: names are
/// narrowed by the filters; filters alone pick from all VMs.
#[derive(Args)]
struct Select {
    /// VMs by name
    #[arg(value_name = "VM")]
    vms: Vec<String>,
    #[command(flatten)]
    filter: Filter,
}

#[derive(Args)]
struct Filter {
    /// Only running VMs
    #[arg(long)]
    running: bool,
    /// Only running VMs whose store image differs from the current one
    #[arg(long)]
    stale: bool,
    /// Only VMs of this store group (registry `storeGroup`)
    #[arg(long, value_name = "GROUP")]
    group: Option<String>,
}

impl Filter {
    fn args(&self) -> Vec<OsString> {
        let mut a: Vec<OsString> = Vec::new();
        if self.running {
            a.push("--running".into());
        }
        if self.stale {
            a.push("--stale".into());
        }
        if let Some(g) = &self.group {
            a.push("--group".into());
            a.push(g.into());
        }
        a
    }
}

/// `--fresh` for start/restart: disposable VMs (registry `disposable`) with
/// their volume images set aside (manage-vms keeps them as `*.pre-fresh`)
#[derive(Args)]
struct Fresh {
    /// Disposable VMs only: start without their data volumes (emergency,
    /// e.g. a broken NetworkManager profile in sys-net)
    #[arg(long)]
    fresh: bool,
}

#[derive(Subcommand)]
enum Cmd {
    /// List VMs: state, store group, image (ok/stale)
    #[command(visible_alias = "ls")]
    List {
        #[command(flatten)]
        filter: Filter,
    },
    /// Start VMs (a started VM gets its tray apps)
    Start {
        #[command(flatten)]
        sel: Select,
        #[command(flatten)]
        fresh: Fresh,
    },
    /// Stop VMs
    Stop(Select),
    /// Restart VMs (a restarted VM gets its tray apps)
    Restart {
        #[command(flatten)]
        sel: Select,
        #[command(flatten)]
        fresh: Fresh,
    },
    /// Start the ad-hoc disposable `disp` (empty on every start) and open a
    /// program in it, foot by default; `nox stop disp` throws it away
    Disp {
        /// Program and its arguments (default: foot)
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        cmd: Vec<OsString>,
    },
    /// Back up onto the external LUKS disk (vm-backup): /home of VMs
    /// (default), --full images, restore, list, prune
    Backup {
        /// vm-backup's arguments (`nox backup --help`)
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<OsString>,
    },
    /// Copy a file once from a VM's ~/outbox into dom0 (~/Incoming/<vm>/,
    /// vm-pull, asks first); without a file, list the outbox
    Pull {
        /// VM name or short alias
        vm: String,
        /// File name in the VM's ~/outbox
        file: Option<String>,
    },
    /// Start a program in a VM (GUI programs show up in dom0 over wprs)
    Run {
        /// VM name or short alias
        vm: String,
        /// Program and its arguments
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        cmd: Vec<OsString>,
    },
    /// Run a shell command in a VM, output in this terminal
    Exec {
        /// VM name or short alias
        vm: String,
        /// Command and its arguments
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        cmd: Vec<OsString>,
    },
    /// SSH session to a VM (extra arguments go to ssh)
    Ssh {
        /// VM name or short alias
        vm: String,
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<OsString>,
    },
    /// Clipboard between dom0 and the VM of the focused window
    Clip {
        #[command(subcommand)]
        action: Clip,
    },
    /// Copy files to a VM (~/Incoming/<source> there), from dom0 or from
    /// another VM: `nox copy [<from-vm>] <to-vm> <path>…` (from a VM when
    /// the first two arguments are VMs; its paths are relative to its home)
    Copy {
        /// Remove the sources after the transfer
        #[arg(short, long = "move")]
        move_: bool,
        /// Only show what would be sent
        #[arg(short = 'n', long)]
        dry_run: bool,
        /// Allow more than the copy limit (bytes)
        #[arg(long, value_name = "BYTES")]
        max: Option<u64>,
        /// [FROM-VM] TO-VM PATH…
        #[arg(required = true, num_args = 2.., value_name = "ARGS")]
        args: Vec<OsString>,
    },
    /// Update dom0 from the builder VM; --all: then the Whonix domains too
    Update {
        /// Also update the image domains (Whonix, apt over Tor)
        #[arg(long)]
        all: bool,
        /// Activate right away instead of on the next boot
        #[arg(long)]
        switch: bool,
        /// nixosConfiguration to build (default: the script's)
        #[arg(long, value_name = "NAME")]
        machine: Option<String>,
        /// Branch to build (default: the script's)
        #[arg(long, value_name = "BRANCH")]
        branch: Option<String>,
    },
    /// USB devices: list, attach to a VM, detach
    Usb {
        #[command(subcommand)]
        action: Usb,
    },
    /// Smoke test of the running system (starts nothing, exit 1 on a failure)
    Doctor,
    /// Run a VM from an older system generation, or its images from the snapshot
    #[command(
        after_help = "Without --gen/--reset/--data: the generations with another runner for VM.\n\
        A rollback holds until a switch installs a changed runner for that VM."
    )]
    Rollback {
        /// VM name
        vm: String,
        /// Generation whose runner to use (restarts the VM)
        #[arg(long, value_name = "N", conflicts_with_all = ["reset", "data"])]
        gen: Option<u32>,
        /// Back to the running system's runner (restarts the VM)
        #[arg(long, conflicts_with = "data")]
        reset: bool,
        /// Images back from the snapshot (`nox snapshot`), VM stopped
        #[arg(long)]
        data: bool,
    },
    /// Copy a stopped VM's images (one snapshot per VM, replaces the last)
    Snapshot {
        /// VM name
        vm: String,
    },
    /// Delete old system generations, then collect garbage
    Gc {
        /// Generations to keep
        #[arg(long, value_name = "N", default_value_t = 3)]
        keep: u32,
        /// Only show what would be deleted
        #[arg(short = 'n', long)]
        dry_run: bool,
    },
    /// The most useful xl/Xen commands: pick one by number, edit it, run it
    Xen(Pick),
    /// The most useful nix/NixOS commands: pick one by number, edit it, run it
    Nix(Pick),
    /// The most useful admin commands: pick one by number, edit it, run it
    Root(Pick),
}

/// A command list from /etc/nox/commands (section `## <group>`)
#[derive(Args)]
struct Pick {
    /// Entry number; without it the list is shown and asks for one
    n: Option<usize>,
}

#[derive(Subcommand)]
enum Clip {
    /// dom0 clipboard into the focused VM
    Copy,
    /// Focused VM's clipboard into dom0
    Paste,
}

#[derive(Subcommand)]
enum Usb {
    /// Devices and their owners
    #[command(visible_alias = "ls")]
    List,
    /// Give a device to a VM
    Attach {
        /// busid, vendor:product or registry name
        device: String,
        /// VM name
        vm: String,
    },
    /// Take a device back from its VM
    Detach {
        /// busid, vendor:product or registry name
        device: String,
    },
    /// Let an input device into dom0 until it is unplugged
    AllowInput {
        /// busid
        busid: String,
    },
}

/// Replaces this process with `prog args…`; returns only if that fails.
fn exec<I, S>(prog: &str, args: I) -> ExitCode
where
    I: IntoIterator<Item = S>,
    S: Into<OsString>,
{
    let args: Vec<OsString> = args.into_iter().map(Into::into).collect();
    let err = Command::new(prog).args(&args).exec();
    eprintln!("nox: cannot run {prog}: {err}");
    ExitCode::from(127)
}

fn vm_action(action: &str, sel: Select, fresh: bool) -> ExitCode {
    let mut a: Vec<OsString> = vec![action.into()];
    if fresh {
        a.push("--fresh".into());
    }
    a.extend(sel.filter.args());
    a.extend(sel.vms.into_iter().map(OsString::from));
    exec("manage-vms", a)
}

/// Where `nox xen|nix|root` read their entries (NixOS module programs.nox)
const COMMANDS_FILE: &str = "/etc/nox/commands";

/// One entry: the command line and its description (after the last " # ")
#[derive(Debug, PartialEq)]
struct Entry {
    cmd: String,
    desc: String,
}

/// Entries of `## <group>` in the commands file. Lines are `cmd # desc`;
/// blank lines and other `#` lines are skipped; a group may appear in
/// several sections (extra entries appended by the configuration).
fn entries(text: &str, group: &str) -> Vec<Entry> {
    let mut inside = false;
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if let Some(name) = line.strip_prefix("## ") {
            inside = name.trim() == group;
            continue;
        }
        if !inside || line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (cmd, desc) = match line.rsplit_once(" # ") {
            Some((c, d)) => (c.trim(), d.trim()),
            None => (line, ""),
        };
        out.push(Entry {
            cmd: cmd.into(),
            desc: desc.into(),
        });
    }
    out
}

/// `nox xen|nix|root [n]`: list the group, take a number, then let bash
/// edit the line (readline, prefilled like pcmd; placeholders `<…>` are
/// replaced by hand), add it to the history and run it
fn pick(group: &str, p: Pick) -> ExitCode {
    let path = std::env::var("NOX_COMMANDS").unwrap_or_else(|_| COMMANDS_FILE.into());
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("nox: {path}: {e}");
            return ExitCode::from(2);
        }
    };
    let list = entries(&text, group);
    if list.is_empty() {
        eprintln!("nox: no entries under \"## {group}\" in {path}");
        return ExitCode::from(2);
    }
    let n = match p.n {
        Some(n) => n,
        None => {
            let width = list
                .iter()
                .map(|e| e.cmd.chars().count())
                .max()
                .unwrap_or(0);
            for (i, e) in list.iter().enumerate() {
                println!("{:>3}  {:<width$}  {}", i + 1, e.cmd, e.desc);
            }
            eprint!("> ");
            let mut answer = String::new();
            if std::io::stdin().read_line(&mut answer).is_err() {
                return ExitCode::from(130);
            }
            match answer.trim() {
                "" => return ExitCode::SUCCESS,
                a => match a.parse() {
                    Ok(n) => n,
                    Err(_) => {
                        eprintln!("nox: not a number: {a}");
                        return ExitCode::from(2);
                    }
                },
            }
        }
    };
    let Some(entry) = n.checked_sub(1).and_then(|i| list.get(i)) else {
        eprintln!("nox: no entry {n} (1-{})", list.len());
        return ExitCode::from(2);
    };
    // Empty line or Ctrl+C: nothing runs
    let script = r#"read -r -e -i "$1" -p '> ' c || exit 130
[ -n "$c" ] || exit 0
printf '%s\n' "$c" >>"${HISTFILE:-$HOME/.bash_history}"
eval "$c""#;
    exec("bash", ["-c", script, "nox", entry.cmd.as_str()])
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let Some(cmd) = cli.command else {
        return exec("manage-vms", ["status", "--running"]);
    };
    match cmd {
        Cmd::List { filter } => {
            let mut a: Vec<OsString> = vec!["status".into()];
            a.extend(filter.args());
            exec("manage-vms", a)
        }
        Cmd::Start { sel, fresh } => vm_action("start", sel, fresh.fresh),
        Cmd::Stop(sel) => vm_action("stop", sel, false),
        Cmd::Restart { sel, fresh } => vm_action("restart", sel, fresh.fresh),
        Cmd::Disp { cmd } => exec("vm-disp", cmd),
        Cmd::Backup { args } => exec("vm-backup", args),
        Cmd::Pull { vm, file } => {
            let mut a: Vec<OsString> = vec![vm.into()];
            a.extend(file.map(OsString::from));
            exec("vm-pull", a)
        }
        Cmd::Run { vm, cmd } => {
            let mut a: Vec<OsString> = vec![vm.into()];
            a.extend(cmd);
            exec("vm-run", a)
        }
        Cmd::Exec { vm, cmd } => {
            let mut a: Vec<OsString> = vec!["-c".into(), vm.into()];
            a.extend(cmd);
            exec("vm-run", a)
        }
        Cmd::Ssh { vm, args } => {
            let mut a: Vec<OsString> = vec![vm.into()];
            a.extend(args);
            exec("ssh", a)
        }
        Cmd::Clip { action } => exec(
            "vm-clip",
            [match action {
                Clip::Copy => "copy",
                Clip::Paste => "paste",
            }],
        ),
        Cmd::Copy {
            move_,
            dry_run,
            max,
            args,
        } => {
            let mut a: Vec<OsString> = Vec::new();
            if move_ {
                a.push("-m".into());
            }
            if dry_run {
                a.push("-n".into());
            }
            if let Some(m) = max {
                a.push("--max".into());
                a.push(m.to_string().into());
            }
            a.push("--".into());
            a.extend(args);
            exec("nox-copy", a)
        }
        Cmd::Update {
            all,
            switch,
            machine,
            branch,
        } => {
            let mut a: Vec<OsString> = Vec::new();
            if switch {
                a.push("--switch".into());
            }
            if let Some(m) = machine {
                a.push("--machine".into());
                a.push(m.into());
            }
            if let Some(b) = branch {
                a.push("--branch".into());
                a.push(b.into());
            }
            exec(if all { "update-all" } else { "dom0-update" }, a)
        }
        Cmd::Usb { action } => match action {
            Usb::List => exec("vm-usb", ["list"]),
            Usb::Attach { device, vm } => exec("vm-usb", ["attach".to_string(), device, vm]),
            Usb::Detach { device } => exec("vm-usb", ["detach".to_string(), device]),
            Usb::AllowInput { busid } => exec("vm-usb", ["allow-input".to_string(), busid]),
        },
        Cmd::Doctor => exec("vm-doctor", Vec::<OsString>::new()),
        Cmd::Rollback {
            vm,
            gen,
            reset,
            data,
        } => {
            let mut a: Vec<String> = Vec::new();
            if data {
                a.push("--data".into());
                a.push(vm);
            } else {
                a.push(vm);
                if let Some(n) = gen {
                    a.push("--gen".into());
                    a.push(n.to_string());
                } else if reset {
                    a.push("--reset".into());
                }
            }
            exec("vm-rollback", a)
        }
        Cmd::Snapshot { vm } => exec("vm-snapshot", [vm]),
        Cmd::Gc { keep, dry_run } => {
            let mut a = vec!["--keep".to_string(), keep.to_string()];
            if dry_run {
                a.push("--dry-run".into());
            }
            exec("vm-gc", a)
        }
        Cmd::Xen(p) => pick("xen", p),
        Cmd::Nix(p) => pick("nix", p),
        Cmd::Root(p) => pick("root", p),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn cli_is_consistent() {
        Cli::command().debug_assert();
    }

    #[test]
    fn run_keeps_program_flags() {
        let cli = Cli::try_parse_from(["nox", "run", "coding", "foot", "-e", "htop"]).unwrap();
        let Some(Cmd::Run { vm, cmd }) = cli.command else {
            panic!("not run")
        };
        assert_eq!(vm, "coding");
        assert_eq!(cmd, ["foot", "-e", "htop"]);
    }

    #[test]
    fn restart_names_and_filters() {
        let cli = Cli::try_parse_from(["nox", "restart", "--stale", "chat", "irc"]).unwrap();
        let Some(Cmd::Restart { sel, fresh }) = cli.command else {
            panic!("not restart")
        };
        assert_eq!(sel.vms, ["chat", "irc"]);
        assert_eq!(sel.filter.args(), ["--stale"]);
        assert!(!fresh.fresh);
    }

    #[test]
    fn restart_fresh_and_disp() {
        let cli = Cli::try_parse_from(["nox", "restart", "--fresh", "sys-net"]).unwrap();
        let Some(Cmd::Restart { sel, fresh }) = cli.command else {
            panic!("not restart")
        };
        assert_eq!(sel.vms, ["sys-net"]);
        assert!(fresh.fresh);
        let cli = Cli::try_parse_from(["nox", "disp", "firefox", "--private-window"]).unwrap();
        let Some(Cmd::Disp { cmd }) = cli.command else {
            panic!("not disp")
        };
        assert_eq!(cmd, ["firefox", "--private-window"]);
        assert!(Cli::try_parse_from(["nox", "stop", "--fresh", "x"]).is_err());
    }

    #[test]
    fn entries_by_group() {
        let text = "## xen\nsudo xl list # Domains\n\n# a comment\nsudo xl console <vm>-vm\n\
                    ## nix\nnix eval \"nixpkgs#hello.version\" # Version of a package\n\
                    ## xen\nsudo xl dmesg # appended later\n";
        let xen = entries(text, "xen");
        assert_eq!(
            xen,
            [
                Entry {
                    cmd: "sudo xl list".into(),
                    desc: "Domains".into()
                },
                Entry {
                    cmd: "sudo xl console <vm>-vm".into(),
                    desc: "".into()
                },
                Entry {
                    cmd: "sudo xl dmesg".into(),
                    desc: "appended later".into()
                },
            ]
        );
        let nix = entries(text, "nix");
        assert_eq!(nix[0].cmd, "nix eval \"nixpkgs#hello.version\"");
        assert_eq!(nix[0].desc, "Version of a package");
        assert!(entries(text, "root").is_empty());
    }
}

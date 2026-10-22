//! nox: one command for the NoX tools in dom0.
//!
//! A thin wrapper for now: every subcommand execs the script that does the
//! work (manage-vms, vm-run, vm-clip, nox-copy, dom0-update, update-all,
//! vm-usb), found on PATH, so its output and exit code are the script's own.

use std::ffi::OsString;
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode};

use clap::{Args, CommandFactory, Parser, Subcommand};

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
    /// Back up VMs onto the external LUKS backup disk (vm-backup): home =
    /// /home/user of NixOS VMs, --full = whole disks; restore, list, prune
    #[command(long_about = BACKUP_ABOUT)]
    Backup(Backup),
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
    /// SSH session to the builder, the only VM with sshd (extra arguments go
    /// to ssh); the other VMs: nox exec
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

/// `nox backup --help`: the two kinds and the generations
const BACKUP_ABOUT: &str =
    "Back up VMs onto the external LUKS backup disk (vm-backup, README \"Backup\").\n\n\
    Two kinds:\n  \
      home  /home/user of NixOS VMs (the default)\n  \
      full  whole disks: a VM's disks, an image domain's image, dom0's ~/.ssh, the builder's key\n\
    Every run is a generation named by its start time, e.g. 2026-10-21_201500.";

/// `nox backup`: the arguments are checked here, the work is vm-backup's
/// (README "Backup" explains every case)
#[derive(Args)]
#[command(
    args_conflicts_with_subcommands = true,
    subcommand_negates_reqs = true,
    arg_required_else_help = true,
    after_long_help = "Examples:\n  \
      nox backup nvim chat                  home of nvim and chat\n  \
      nox backup --all                      home of the VMs with registry `backup`\n  \
      nox backup --full coding nvim         all disks of coding and nvim\n  \
      nox backup --full coding:home,var     only these disks of coding\n  \
      nox backup --full whonix-workstation  an image domain (its disk: image)\n  \
      nox backup --full dom0 builder        dom0's ~/.ssh, the builder's key\n  \
      nox backup --full --level 9 coding    smaller files, much slower\n  \
      nox backup --full --all               everything\n  \
      nox backup restore nvim               see: nox backup restore help\n  \
      nox backup disks --all                what --full can back up\n  \
      nox backup list                       all generations, free space\n  \
      nox backup prune home --keep 5 -n     see: nox backup prune help"
)]
struct Backup {
    #[command(subcommand)]
    action: Option<BackupCmd>,
    #[command(flatten)]
    sel: BackupSel,
    /// Whole disks instead of /home/user. TARGET: a VM (all its disks),
    /// VM:DISK,DISK, an image domain, dom0, builder (`nox backup disks --all`)
    #[arg(long)]
    full: bool,
    /// zstd level for --full: 1 (fast, big) .. 19 (slow, small), default 3
    #[arg(long, value_name = "N", requires = "full", value_parser = clap::value_parser!(u8).range(1..=19))]
    level: Option<u8>,
}

/// Names or --all, exactly one of them
#[derive(Args)]
#[group(required = true, multiple = false)]
struct BackupSel {
    /// VMs (home) or targets (--full)
    #[arg(value_name = "TARGET")]
    targets: Vec<String>,
    /// home: the VMs with registry `backup`; --full: every target
    #[arg(long)]
    all: bool,
}

impl BackupSel {
    fn args(self) -> Vec<String> {
        if self.all {
            vec!["--all".into()]
        } else {
            self.targets
        }
    }
}

#[derive(Subcommand)]
enum BackupCmd {
    /// Put a backup back: home adds files (deletes nothing, newer files in
    /// the VM stay); --full replaces the disks (asks first, VM stopped)
    #[command(after_long_help = "Examples:\n  \
      nox backup restore nvim chat                       home, newest generation\n  \
      nox backup restore --all                           home of the VMs with registry `backup`\n  \
      nox backup restore --from 2026-10-21_201500 nvim   a specific generation\n  \
      nox backup restore --full coding                   all disks of coding\n  \
      nox backup restore --full coding:home              one disk\n  \
      nox backup restore --full dom0 builder             only unpacked to ~/nox-restore; prints how to put them back")]
    Restore {
        /// Whole disks (a full generation) instead of /home/user
        #[arg(long)]
        full: bool,
        /// Generation to restore (default: the newest; names: nox backup list)
        #[arg(long, value_name = "GEN", value_parser = generation)]
        from: Option<String>,
        #[command(flatten)]
        sel: BackupSel,
    },
    /// The disks --full can back up, with size and used space
    #[command(after_long_help = "Examples:\n  \
      nox backup disks coding\n  \
      nox backup disks --all")]
    Disks {
        #[command(flatten)]
        sel: BackupSel,
    },
    /// All generations on the disk (home and full) and the free space
    List,
    /// Delete old generations: all but the newest KEEP per VM/target
    #[command(after_long_help = "Examples:\n  \
      nox backup prune home --keep 5 -n          only show what would go\n  \
      nox backup prune home --keep 5             all VMs\n  \
      nox backup prune full --keep 2 coding      only coding")]
    Prune {
        /// home or full
        #[arg(value_parser = ["home", "full"])]
        kind: String,
        /// Generations to keep per VM/target
        #[arg(long, value_name = "N", value_parser = clap::value_parser!(u32).range(1..))]
        keep: u32,
        /// Only show what would be deleted
        #[arg(short = 'n', long)]
        dry_run: bool,
        /// Only these VMs/targets (default: all)
        #[arg(value_name = "TARGET")]
        targets: Vec<String>,
    },
}

/// `--from`: a generation name like 2026-10-21_201500
fn generation(s: &str) -> Result<String, String> {
    let ok = s.len() == 17
        && s.char_indices().all(|(i, c)| match i {
            4 | 7 => c == '-',
            10 => c == '_',
            _ => c.is_ascii_digit(),
        });
    if ok {
        Ok(s.into())
    } else {
        Err("a generation like 2026-10-21_201500 (names: nox backup list)".into())
    }
}

/// vm-backup's arguments for `nox backup …`
fn backup_args(b: Backup) -> Vec<String> {
    let mut a: Vec<String> = Vec::new();
    match b.action {
        None => {
            if b.full {
                a.push("--full".into());
                if let Some(l) = b.level {
                    a.push("--level".into());
                    a.push(l.to_string());
                }
            }
            a.extend(b.sel.args());
        }
        Some(BackupCmd::Restore { full, from, sel }) => {
            a.push("restore".into());
            if full {
                a.push("--full".into());
            }
            if let Some(g) = from {
                a.push("--from".into());
                a.push(g);
            }
            a.extend(sel.args());
        }
        Some(BackupCmd::Disks { sel }) => {
            a.push("disks".into());
            a.extend(sel.args());
        }
        Some(BackupCmd::List) => a.push("list".into()),
        Some(BackupCmd::Prune {
            kind,
            keep,
            dry_run,
            targets,
        }) => {
            a.extend(["prune".into(), kind, "--keep".into(), keep.to_string()]);
            a.extend(targets);
            if dry_run {
                a.push("-n".into());
            }
        }
    }
    a
}

/// `nox <cmd>… help` = `nox <cmd>… --help`: the word `help` as the last
/// argument, right after subcommand names (`nox backup restore help`,
/// `nox usb attach help`). `nox help [cmd]` is clap's own.
fn help_word(mut args: Vec<OsString>) -> Vec<OsString> {
    let mut cmd = Cli::command();
    let mut i = 1;
    while i < args.len() {
        let Some(a) = args[i].to_str() else { break };
        if a == "help" && i > 1 && i + 1 == args.len() {
            args[i] = "--help".into();
            break;
        }
        match cmd.find_subcommand(a) {
            Some(sub) => {
                let sub = sub.clone();
                cmd = sub;
                i += 1;
            }
            None => break,
        }
    }
    args
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
    let cli = Cli::parse_from(help_word(std::env::args_os().collect()));
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
        Cmd::Backup(b) => exec("vm-backup", backup_args(b)),
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

    fn backup(args: &[&str]) -> Result<Vec<String>, clap::Error> {
        let mut v = vec!["nox", "backup"];
        v.extend(args);
        let cli = Cli::try_parse_from(v)?;
        let Some(Cmd::Backup(b)) = cli.command else {
            panic!("not backup")
        };
        Ok(backup_args(b))
    }

    #[test]
    fn backup_home_and_full() {
        assert_eq!(backup(&["nvim", "chat"]).unwrap(), ["nvim", "chat"]);
        assert_eq!(backup(&["--all"]).unwrap(), ["--all"]);
        assert_eq!(
            backup(&["--full", "coding:home,var", "nvim"]).unwrap(),
            ["--full", "coding:home,var", "nvim"]
        );
        // --level goes right after --full, wherever it was written
        assert_eq!(
            backup(&["coding", "--level", "9", "--full"]).unwrap(),
            ["--full", "--level", "9", "coding"]
        );
        assert!(backup(&[]).is_err());
        assert!(backup(&["--all", "nvim"]).is_err());
        assert!(backup(&["--level", "9", "coding"]).is_err());
        assert!(backup(&["--full", "--level", "20", "coding"]).is_err());
    }

    #[test]
    fn backup_subcommands() {
        assert_eq!(
            backup(&["restore", "--from", "2026-10-21_201500", "nvim"]).unwrap(),
            ["restore", "--from", "2026-10-21_201500", "nvim"]
        );
        assert_eq!(
            backup(&["restore", "coding", "--full"]).unwrap(),
            ["restore", "--full", "coding"]
        );
        assert!(backup(&["restore", "--from", "yesterday", "nvim"]).is_err());
        assert!(backup(&["restore"]).is_err());
        assert_eq!(backup(&["disks", "--all"]).unwrap(), ["disks", "--all"]);
        assert_eq!(backup(&["list"]).unwrap(), ["list"]);
        assert_eq!(
            backup(&["prune", "home", "--keep", "5", "-n", "nvim"]).unwrap(),
            ["prune", "home", "--keep", "5", "nvim", "-n"]
        );
        assert!(backup(&["prune", "home", "--keep", "0"]).is_err());
        assert!(backup(&["prune", "all", "--keep", "2"]).is_err());
        assert!(backup(&["list", "nvim"]).is_err());
    }

    #[test]
    fn help_as_last_word() {
        let os = |v: &[&str]| v.iter().map(OsString::from).collect::<Vec<_>>();
        assert_eq!(
            help_word(os(&["nox", "backup", "restore", "help"])),
            os(&["nox", "backup", "restore", "--help"])
        );
        assert_eq!(
            help_word(os(&["nox", "backup", "help"])),
            os(&["nox", "backup", "--help"])
        );
        assert_eq!(
            help_word(os(&["nox", "ls", "help"])),
            os(&["nox", "ls", "--help"])
        );
        // only directly after subcommand names, and only as the last word
        assert_eq!(help_word(os(&["nox", "help"])), os(&["nox", "help"]));
        assert_eq!(
            help_word(os(&["nox", "run", "coding", "help"])),
            os(&["nox", "run", "coding", "help"])
        );
        assert_eq!(
            help_word(os(&["nox", "backup", "help", "restore"])),
            os(&["nox", "backup", "help", "restore"])
        );
    }
}

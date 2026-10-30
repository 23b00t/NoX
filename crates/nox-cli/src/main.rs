//! nox: one command for the NoX tools in dom0.
//!
//! Moving from scripts to Rust tool by tool (xen-migration.md, nox-cli
//! spec): `doctor`, `backup`, `vm-run` and `manage-vms` run here (src/doctor.rs,
//! src/backup.rs, src/run.rs, src/manage.rs; their old names are links to nox, picked by
//! argv[0]); every other subcommand execs the script that does the work
//! (vm-clip, nox-copy, dom0-update, update-all, vm-usb, …), found on PATH,
//! so its output and exit code are the script's own.

use std::ffi::OsString;
use std::process::ExitCode;

use clap::{Args, CommandFactory, Parser, Subcommand};

mod backup;
mod doctor;
mod manage;
mod registry;
mod run;
mod sys;

use sys::exec;

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
    /// program in it, foot by default; `nox stop disp` throws it away.
    /// --from <vm>: the disposable of that VM instead (disp-<vm>, its role,
    /// apps and module, empty; `hasDisposable = true` in vms.nix)
    Disp {
        /// VM whose disposable to use (name or short alias)
        #[arg(long, value_name = "VM")]
        from: Option<String>,
        /// Program and its arguments (default: foot)
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        cmd: Vec<OsString>,
    },
    /// Back up VMs onto the external LUKS backup disk (src/backup.rs): whole
    /// disks per VM, image domain, dom0's ~/.ssh; restore, list, prune
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
    /// Run a shell command in a terminal window of the VM (foot over wprs,
    /// stays open with the output); the builder: over SSH in this terminal
    Exec {
        /// VM name or short alias
        vm: String,
        /// Command and its arguments
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        cmd: Vec<OsString>,
    },
    /// SSH session to the builder, the only VM with sshd (extra arguments go
    /// to ssh); the other VMs: nox exec (a terminal window in the VM)
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
    /// Find the IPP printers in the local network (sys-print scans what
    /// sys-net names; starts sys-print): address, name, model
    Printers {
        /// rofi list; the chosen address goes to the clipboard (Mod+Alt+V)
        #[arg(long)]
        menu: bool,
    },
    /// Update: the builder VM updates the flake inputs (flake.lock as its own
    /// signed commit, pushed), then builds dom0 like `rebuild`; --all: then
    /// the Whonix domains too
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
        /// Branch to update and build (default: the script's)
        #[arg(long, value_name = "BRANCH")]
        branch: Option<String>,
    },
    /// Rebuild dom0 from the builder VM as the branch is (no new inputs);
    /// --iso: the installer ISO instead, from the builder straight to a VM
    Rebuild {
        /// Activate right away instead of on the next boot
        #[arg(long)]
        switch: bool,
        /// Build the installer ISO and move it to this VM's ~/Incoming/builder
        #[arg(long, value_name = "VM", conflicts_with_all = ["switch", "machine"])]
        iso: Option<String>,
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
    /// The lab bridge: a labTarget VM (registry) on sys-firewall's vm-lab
    /// while kali tests its apps (vm-lab; gone after a restart of the VM)
    Lab {
        #[command(subcommand)]
        action: Lab,
    },
    /// Keyboard and mouse (optionally the Bluetooth adapter) to a VM and back
    Input {
        #[command(subcommand)]
        action: Input,
    },
    /// Smoke test of the running system (starts nothing, exit 1 on a
    /// failure): the result line and the failures with their details
    Doctor {
        /// -v: every check; -vv: every check with its details
        #[arg(short, action = clap::ArgAction::Count)]
        verbose: u8,
        /// The errors the runs reported (kernel, xl dmesg) are known noise
        /// of this machine from now on: they no longer fail
        #[arg(long, conflicts_with = "verbose")]
        ack: bool,
    },
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

/// `nox backup --help`: what a target is and the generations
const BACKUP_ABOUT: &str =
    "Back up VMs onto the external LUKS backup disk (README \"Backup\").\n\n\
    Whole disks: a VM's disks, an image domain's image, dom0's ~/.ssh, the builder's key.\n\
    Every run is a generation named by its start time, e.g. 2026-10-21_201500.";

/// `nox backup`: the arguments are checked here, the work is src/backup.rs
/// (README "Backup" explains every case)
#[derive(Args)]
#[command(
    args_conflicts_with_subcommands = true,
    subcommand_negates_reqs = true,
    arg_required_else_help = true,
    after_long_help = "Examples:\n  \
      nox backup coding chat                all disks of coding and chat\n  \
      nox backup coding:home,var            only these disks of coding\n  \
      nox backup whonix-workstation         an image domain (its disk: image)\n  \
      nox backup dom0 builder               dom0's ~/.ssh, the builder's key\n  \
      nox backup --level 9 coding           smaller files, much slower\n  \
      nox backup --all                      the VMs with registry `backup` and dom0\n  \
      nox backup restore coding             see: nox backup restore help\n  \
      nox backup disks --all                every target with its disks\n  \
      nox backup list                       all generations, free space\n  \
      nox backup prune --keep 2 -n          see: nox backup prune help"
)]
struct Backup {
    #[command(subcommand)]
    action: Option<BackupCmd>,
    #[command(flatten)]
    sel: BackupSel,
    /// zstd level: 1 (fast, big) .. 19 (slow, small), default 3
    #[arg(long, value_name = "N", value_parser = clap::value_parser!(u8).range(1..=19))]
    level: Option<u8>,
}

/// Names or --all, exactly one of them
#[derive(Args)]
#[group(required = true, multiple = false)]
struct BackupSel {
    /// A VM (all its disks), VM:DISK,DISK, an image domain, dom0, builder
    /// (`nox backup disks --all`)
    #[arg(value_name = "TARGET")]
    targets: Vec<String>,
    /// The VMs with registry `backup` (not sys-*, disposables, steam) and
    /// dom0; for disks: every target
    #[arg(long)]
    all: bool,
}

#[derive(Subcommand)]
enum BackupCmd {
    /// Put a backup back: replaces the disks (asks first, VM stopped)
    #[command(after_long_help = "Examples:\n  \
      nox backup restore coding chat                       all disks, newest generation\n  \
      nox backup restore coding:home                       one disk\n  \
      nox backup restore --from 2026-10-21_201500 coding   a specific generation\n  \
      nox backup restore --all                             the VMs with registry `backup` and dom0\n  \
      nox backup restore dom0 builder                      only unpacked to ~/nox-restore; prints how to put them back")]
    Restore {
        /// Generation to restore (default: the newest; names: nox backup list)
        #[arg(long, value_name = "GEN", value_parser = generation)]
        from: Option<String>,
        #[command(flatten)]
        sel: BackupSel,
    },
    /// The disks a backup takes, with size and used space
    #[command(after_long_help = "Examples:\n  \
      nox backup disks coding\n  \
      nox backup disks --all")]
    Disks {
        #[command(flatten)]
        sel: BackupSel,
    },
    /// All generations on the disk and the free space
    List,
    /// Delete old generations: all but the newest KEEP per target
    #[command(after_long_help = "Examples:\n  \
      nox backup prune --keep 2 -n          only show what would go\n  \
      nox backup prune --keep 2             all targets\n  \
      nox backup prune --keep 1 coding      only coding")]
    Prune {
        /// Generations to keep per target (0: all go, asks first)
        #[arg(long, value_name = "N", value_parser = clap::value_parser!(u32))]
        keep: u32,
        /// Only show what would be deleted
        #[arg(short = 'n', long)]
        dry_run: bool,
        /// Only these targets (default: all)
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

/// What `nox backup …` asks for (src/backup.rs does it)
fn backup_req(b: Backup) -> backup::Req {
    use backup::{Req, Sel};
    let sel = |s: BackupSel| {
        if s.all {
            Sel::All
        } else {
            Sel::Names(s.targets)
        }
    };
    match b.action {
        None => Req::Backup {
            sel: sel(b.sel),
            level: b.level.unwrap_or(3),
        },
        Some(BackupCmd::Restore { from, sel: s }) => Req::Restore { from, sel: sel(s) },
        Some(BackupCmd::Disks { sel: s }) => Req::Disks(sel(s)),
        Some(BackupCmd::List) => Req::List,
        Some(BackupCmd::Prune {
            keep,
            dry_run,
            targets,
        }) => Req::Prune {
            keep,
            dry_run,
            targets,
        },
    }
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

#[derive(Subcommand)]
enum Lab {
    /// Lab targets and which are on the bridge (address from kali)
    #[command(visible_aliases = ["ls", "status"])]
    List,
    /// Hang a running lab target on the lab bridge
    Attach {
        /// VM name or short alias
        vm: String,
    },
    /// Take it off the lab bridge
    Detach {
        /// VM name or short alias
        vm: String,
    },
}

#[derive(Subcommand)]
enum Input {
    /// Give dom0's keyboard and mouse to a VM (the registry's allowedOwners)
    To {
        /// VM name
        vm: String,
        /// Also the Bluetooth adapter (controllers)
        #[arg(long)]
        bt: bool,
    },
    /// Take them back to dom0 (from VM, default: wherever they are)
    Back {
        /// VM name
        vm: Option<String>,
    },
}

/// dom0-update's arguments for `nox update` / `nox rebuild`
fn build_args(
    switch: bool,
    iso: Option<String>,
    machine: Option<String>,
    branch: Option<String>,
) -> Vec<OsString> {
    let mut a: Vec<OsString> = Vec::new();
    if switch {
        a.push("--switch".into());
    }
    if let Some(vm) = iso {
        a.push("--iso".into());
        a.push(vm.into());
    }
    if let Some(m) = machine {
        a.push("--machine".into());
        a.push(m.into());
    }
    if let Some(b) = branch {
        a.push("--branch".into());
        a.push(b.into());
    }
    a
}

fn vm_action(action: &str, sel: Select, fresh: bool) -> ExitCode {
    let mut a: Vec<OsString> = vec![action.into()];
    if fresh {
        a.push("--fresh".into());
    }
    a.extend(sel.filter.args());
    a.extend(sel.vms.into_iter().map(OsString::from));
    manage::main(&a)
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
    // Empty line or Ctrl+C: nothing runs. NOX_HISTORY_OUT (set by the `nox`
    // shell function in dom0): the line goes there and the calling shell
    // adds it to its own history (`history -s`); without it, to HISTFILE
    // (seen by new shells only)
    let script = r#"read -r -e -i "$1" -p '> ' c || exit 130
[ -n "$c" ] || exit 0
if [ -n "${NOX_HISTORY_OUT:-}" ]; then
  printf '%s\n' "$c" >"$NOX_HISTORY_OUT"
else
  printf '%s\n' "$c" >>"${HISTFILE:-$HOME/.bash_history}"
fi
eval "$c""#;
    exec("bash", ["-c", script, "nox", entry.cmd.as_str()])
}

/// `nox disp [--from <vm>] [cmd…]`: vm-disp with the disposable to use
/// (`--vm disp-<vm>`, the registry entry NoX adds for `hasDisposable`).
/// A disposable that is down starts only if Xen has its boot memory free:
/// otherwise systemd retried the start for minutes ("can't allocate low
/// memory", hp 2026-10-28)
fn disp(from: Option<String>, cmd: Vec<OsString>) -> ExitCode {
    let domains = match registry::domains() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("nox: {e:#}");
            return ExitCode::from(1);
        }
    };
    let mut a: Vec<OsString> = Vec::new();
    let vm = match from {
        Some(base) => {
            let name = registry::find(&domains, &base).map_or(base.clone(), |d| d.name.clone());
            let vm = format!("disp-{name}");
            if registry::find(&domains, &vm).is_none() {
                eprintln!("nox: {base} has no disposable (hasDisposable = true in vms.nix)");
                return ExitCode::from(1);
            }
            a.extend(["--vm".into(), vm.clone().into()]);
            vm
        }
        None => "disp".to_string(),
    };
    if let Some(d) = registry::find(&domains, &vm) {
        if let Err(msg) = memory_for(d) {
            eprintln!("nox: {msg}");
            return ExitCode::from(1);
        }
    }
    a.extend(cmd);
    exec("vm-disp", a)
}

/// Xen's free memory (MiB) is enough for `d`'s boot memory, or it runs
/// already. Unknown (no sudo rule, no xl): the start is tried
fn memory_for(d: &registry::Domain) -> Result<(), String> {
    let Some(need) = d.memory else { return Ok(()) };
    if sys::is_active(&d.service()) {
        return Ok(());
    }
    let free = sys::output("sudo", ["-n", "xl", "info", "free_memory"])
        .and_then(|s| s.trim().parse::<u64>().ok());
    match free {
        Some(free) => enough_memory(&d.name, need, free),
        None => Ok(()),
    }
}

/// Boot memory plus a little for Xen's own tables
fn enough_memory(vm: &str, need: u64, free: u64) -> Result<(), String> {
    const MARGIN: u64 = 64;
    if free >= need + MARGIN {
        Ok(())
    } else {
        Err(format!(
            "{vm} needs {need} MiB, Xen has {free} MiB free: stop a VM first (nox list --running, nox stop <vm>)"
        ))
    }
}

fn main() -> ExitCode {
    sys::default_sigpipe();
    let args: Vec<OsString> = std::env::args_os().collect();
    // Old tool names linked to nox pick their tool (vm-doctor -> nox doctor)
    let name = args
        .first()
        .and_then(|a| std::path::Path::new(a).file_name())
        .map(|n| n.to_string_lossy().into_owned());
    match name.as_deref() {
        Some("vm-doctor") => {
            let rest: Vec<String> = args[1..]
                .iter()
                .map(|a| a.to_string_lossy().into_owned())
                .collect();
            return doctor::main_args(&rest);
        }
        Some("vm-run") => return run::main(&args[1..]),
        Some("manage-vms") => return manage::main(&args[1..]),
        _ => {}
    }
    let cli = Cli::parse_from(help_word(args));
    let Some(cmd) = cli.command else {
        return manage::main(&["status".into(), "--running".into()]);
    };
    match cmd {
        Cmd::List { filter } => {
            let mut a: Vec<OsString> = vec!["status".into()];
            a.extend(filter.args());
            manage::main(&a)
        }
        Cmd::Start { sel, fresh } => vm_action("start", sel, fresh.fresh),
        Cmd::Stop(sel) => vm_action("stop", sel, false),
        Cmd::Restart { sel, fresh } => vm_action("restart", sel, fresh.fresh),
        Cmd::Disp { from, cmd } => disp(from, cmd),
        Cmd::Backup(b) => backup::main(backup_req(b)),
        Cmd::Pull { vm, file } => {
            let mut a: Vec<OsString> = vec![vm.into()];
            a.extend(file.map(OsString::from));
            exec("vm-pull", a)
        }
        Cmd::Run { vm, cmd } => {
            let mut a: Vec<OsString> = vec![vm.into()];
            a.extend(cmd);
            run::main(&a)
        }
        Cmd::Exec { vm, cmd } => {
            let mut a: Vec<OsString> = vec!["-c".into(), vm.into()];
            a.extend(cmd);
            run::main(&a)
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
        Cmd::Printers { menu } => exec("nox-printers", if menu { vec!["--menu"] } else { vec![] }),
        Cmd::Update {
            all,
            switch,
            machine,
            branch,
        } => {
            let mut a: Vec<OsString> = vec!["--bump".into()];
            a.extend(build_args(switch, None, machine, branch));
            exec(if all { "update-all" } else { "dom0-update" }, a)
        }
        Cmd::Rebuild {
            switch,
            iso,
            machine,
            branch,
        } => exec("dom0-update", build_args(switch, iso, machine, branch)),
        Cmd::Usb { action } => match action {
            Usb::List => exec("vm-usb", ["list"]),
            Usb::Attach { device, vm } => exec("vm-usb", ["attach".to_string(), device, vm]),
            Usb::Detach { device } => exec("vm-usb", ["detach".to_string(), device]),
            Usb::AllowInput { busid } => exec("vm-usb", ["allow-input".to_string(), busid]),
        },
        Cmd::Lab { .. } if !sys::on_path("vm-lab") => {
            eprintln!("nox: this machine has no lab bridge (NoX services.xen-lab, with kali)");
            ExitCode::from(1)
        }
        Cmd::Lab { action } => match action {
            Lab::List => exec("vm-lab", ["status"]),
            Lab::Attach { vm } => exec("vm-lab", ["attach".to_string(), vm]),
            Lab::Detach { vm } => exec("vm-lab", ["detach".to_string(), vm]),
        },
        Cmd::Input { action } => match action {
            Input::To { vm, bt } => {
                let mut args = vec![vm];
                if bt {
                    args.push("--bt".to_string());
                }
                exec("input-to", args)
            }
            Input::Back { vm } => exec("input-back", vm),
        },
        Cmd::Doctor { verbose, ack } => {
            if ack {
                doctor::main_args(&["--ack".into()])
            } else {
                doctor::run_doctor(verbose)
            }
        }
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
    fn input_to_and_back() {
        let cli = Cli::try_parse_from(["nox", "input", "to", "steam", "--bt"]).unwrap();
        let Some(Cmd::Input {
            action: Input::To { vm, bt },
        }) = cli.command
        else {
            panic!("not input to")
        };
        assert_eq!(vm, "steam");
        assert!(bt);
        let cli = Cli::try_parse_from(["nox", "input", "back"]).unwrap();
        let Some(Cmd::Input {
            action: Input::Back { vm },
        }) = cli.command
        else {
            panic!("not input back")
        };
        assert_eq!(vm, None);
    }

    #[test]
    fn disp_memory() {
        assert!(enough_memory("disp-net", 3072, 5520).is_ok());
        let e = enough_memory("disp-net", 3072, 2400).unwrap_err();
        assert!(e.contains("3072 MiB") && e.contains("2400 MiB free"));
        // Xen's own tables: not exactly the boot size
        assert!(enough_memory("disp", 2048, 2048).is_err());
    }

    #[test]
    fn lab_commands() {
        let cli = Cli::try_parse_from(["nox", "lab", "attach", "coding"]).unwrap();
        let Some(Cmd::Lab {
            action: Lab::Attach { vm },
        }) = cli.command
        else {
            panic!("not lab attach")
        };
        assert_eq!(vm, "coding");
        assert!(matches!(
            Cli::try_parse_from(["nox", "lab", "status"])
                .unwrap()
                .command,
            Some(Cmd::Lab { action: Lab::List })
        ));
        assert!(Cli::try_parse_from(["nox", "lab", "attach"]).is_err());
    }

    #[test]
    fn rebuild_iso() {
        let cli =
            Cli::try_parse_from(["nox", "rebuild", "--iso", "disp", "--branch", "b"]).unwrap();
        let Some(Cmd::Rebuild {
            switch,
            iso,
            machine,
            branch,
        }) = cli.command
        else {
            panic!("not rebuild")
        };
        assert_eq!(
            build_args(switch, iso, machine, branch),
            ["--iso", "disp", "--branch", "b"]
        );
        assert!(Cli::try_parse_from(["nox", "rebuild", "--iso", "disp", "--switch"]).is_err());
        assert!(Cli::try_parse_from(["nox", "update", "--iso", "disp"]).is_err());
    }

    #[test]
    fn update_bumps() {
        let cli = Cli::try_parse_from(["nox", "update", "--all", "--switch"]).unwrap();
        let Some(Cmd::Update {
            all,
            switch,
            machine,
            branch,
        }) = cli.command
        else {
            panic!("not update")
        };
        assert!(all);
        assert_eq!(build_args(switch, None, machine, branch), ["--switch"]);
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
        let Some(Cmd::Disp { from, cmd }) = cli.command else {
            panic!("not disp")
        };
        assert_eq!(cmd, ["firefox", "--private-window"]);
        assert_eq!(from, None);
        let cli = Cli::try_parse_from(["nox", "disp", "--from", "b", "firefox"]).unwrap();
        let Some(Cmd::Disp { from, cmd }) = cli.command else {
            panic!("not disp")
        };
        assert_eq!(from.as_deref(), Some("b"));
        assert_eq!(cmd, ["firefox"]);
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

    fn backup(args: &[&str]) -> Result<backup::Req, clap::Error> {
        let mut v = vec!["nox", "backup"];
        v.extend(args);
        let cli = Cli::try_parse_from(v)?;
        let Some(Cmd::Backup(b)) = cli.command else {
            panic!("not backup")
        };
        Ok(backup_req(b))
    }

    #[test]
    fn backup_targets() {
        use backup::{Req, Sel};
        let names = |v: &[&str]| Sel::Names(v.iter().map(|s| s.to_string()).collect());
        assert_eq!(
            backup(&["coding:home,var", "chat"]).unwrap(),
            Req::Backup {
                sel: names(&["coding:home,var", "chat"]),
                level: 3
            }
        );
        assert_eq!(
            backup(&["--all"]).unwrap(),
            Req::Backup {
                sel: Sel::All,
                level: 3
            }
        );
        assert_eq!(
            backup(&["coding", "--level", "9"]).unwrap(),
            Req::Backup {
                sel: names(&["coding"]),
                level: 9
            }
        );
        assert!(backup(&[]).is_err());
        assert!(backup(&["--all", "chat"]).is_err());
        assert!(backup(&["--level", "20", "coding"]).is_err());
        // the home mode is gone
        assert!(backup(&["--full", "coding"]).is_err());
    }

    #[test]
    fn backup_subcommands() {
        use backup::{Req, Sel};
        let names = |v: &[&str]| Sel::Names(v.iter().map(|s| s.to_string()).collect());
        assert_eq!(
            backup(&["restore", "--from", "2026-10-21_201500", "chat"]).unwrap(),
            Req::Restore {
                from: Some("2026-10-21_201500".into()),
                sel: names(&["chat"])
            }
        );
        assert_eq!(
            backup(&["restore", "--all"]).unwrap(),
            Req::Restore {
                from: None,
                sel: Sel::All
            }
        );
        assert!(backup(&["restore", "--from", "yesterday", "chat"]).is_err());
        assert!(backup(&["restore"]).is_err());
        assert!(backup(&["restore", "--full", "coding"]).is_err());
        assert_eq!(backup(&["disks", "--all"]).unwrap(), Req::Disks(Sel::All));
        assert_eq!(backup(&["list"]).unwrap(), Req::List);
        assert_eq!(
            backup(&["prune", "--keep", "5", "-n", "chat"]).unwrap(),
            Req::Prune {
                keep: 5,
                dry_run: true,
                targets: vec!["chat".into()]
            }
        );
        // --keep 0: everything goes (asks first)
        assert!(backup(&["prune", "--keep", "0"]).is_ok());
        assert!(backup(&["prune", "chat"]).is_err());
        assert!(backup(&["list", "chat"]).is_err());
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

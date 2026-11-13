//! `nox doctor`: smoke test of the running system.
//!
//! Starts no VMs, checks only what runs: rpc and relay per VM, network over
//! sys-firewall (and the tunnel for sys-vpn clients), app start by RPC,
//! clipboard round trip, wprs (and its grants), D-Bus, sound, Tor in the
//! Whonix-Gateway, USB (controllers, assignments, input proxy), backup age,
//! stale runners, rollbacks, disk, failed units, kernel/Xen errors. Table of
//! PASS/FAIL/WARN/SKIP, exit 1 on any FAIL. The data per domain comes from
//! `/etc/nox/registry.json` (`doctor`), written by NoX's dom0/tools/vm-doctor.nix;
//! the tools it asks (systemctl, nox-rpc, journalctl, xl, wl-clipboard, df,
//! wpctl, pw-dump) run as processes. Sound, Tor and USB only read: no sound
//! is played, no pipewire started, no device moved.

use std::cell::RefCell;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, ExitCode, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use serde::Deserialize;

const REGISTRY: &str = "/etc/nox/registry.json";

/// `doctor` in the registry
#[derive(Deserialize, Default)]
pub struct Data {
    #[serde(default)]
    pub domains: Vec<Domain>,
    /// None: no sys-usb on this machine
    #[serde(default)]
    pub usb: Option<Usb>,
}

/// sys-usb's controllers and the registry's USB inventory
#[derive(Deserialize, Default)]
pub struct Usb {
    /// PCI paths of the USB controllers sys-usb owns
    #[serde(default)]
    pub pci: Vec<String>,
    #[serde(default)]
    pub devices: Vec<UsbDevice>,
}

#[derive(Deserialize, Clone)]
pub struct UsbDevice {
    /// vendor:product
    pub id: String,
    pub name: String,
    /// defaultOwner: a VM, `host` (input device for dom0), `sys-usb` or empty
    #[serde(default)]
    pub owner: String,
    /// allowedOwners (empty: any target VM)
    #[serde(default)]
    pub allowed: Vec<String>,
}

#[derive(Deserialize, Clone)]
pub struct Domain {
    pub name: String,
    /// systemd unit without `.service`
    pub unit: String,
    /// Xen domain name of the relayed guest (empty: no relay)
    #[serde(default)]
    pub domain: String,
    #[serde(default)]
    pub wprs: bool,
    /// wprs pixels over grant-shared memory (a grant broker in the relay)
    #[serde(default)]
    pub grants: bool,
    #[serde(default)]
    pub dbus: bool,
    /// Sound over the relay into the VM's own pipewire
    #[serde(default)]
    pub audio: bool,
    /// Tor gateway (the Whonix-Gateway image domain)
    #[serde(default)]
    pub tor: bool,
    /// sys-firewall / sys-vpn for VMs with an uplink, empty otherwise
    #[serde(default)]
    pub uplink: String,
    /// allow / deny / warn (vm-clip's rule)
    #[serde(default)]
    pub clip: String,
}

#[derive(Deserialize)]
struct Registry {
    #[serde(default)]
    doctor: Data,
}

pub fn load(path: &str) -> Result<Data> {
    let text = fs::read_to_string(path).with_context(|| format!("reading {path}"))?;
    let reg: Registry = serde_json::from_str(&text).with_context(|| format!("parsing {path}"))?;
    Ok(reg.doctor)
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stat {
    Pass,
    Fail,
    Warn,
    Skip,
}

impl Stat {
    fn label(self) -> &'static str {
        match self {
            Stat::Pass => "PASS",
            Stat::Fail => "FAIL",
            Stat::Warn => "WARN",
            Stat::Skip => "SKIP",
        }
    }
}

/// The table: one line per check, counted as it is printed. Level 0 (the
/// default) prints only FAIL/WARN rows with their details, 1 (`-v`) every
/// row, 2 (`-vv`) every row with its details and the commands behind it
/// (input, output, exit code)
#[derive(Default)]
pub struct Table {
    pub pass: u32,
    pub fail: u32,
    pub warn: u32,
    pub skip: u32,
    pub verbose: u8,
    header: bool,
}

impl Table {
    fn row(&mut self, stat: Stat, check: &str, detail: &str) {
        self.row_more(stat, check, detail, &[]);
    }
    /// A row with more lines below it (e.g. every new kernel error)
    fn row_more(&mut self, stat: Stat, check: &str, detail: &str, more: &[String]) {
        let bad = matches!(stat, Stat::Fail | Stat::Warn);
        if bad || self.verbose >= 1 {
            if !self.header {
                println!("{:<4}  {:<26} DETAIL", "STAT", "CHECK");
                self.header = true;
            }
            println!("{:<4}  {:<26} {}", stat.label(), check, detail);
            if bad || self.verbose >= 2 {
                for l in more {
                    println!("      {}", cut(l, 150));
                }
            }
            if self.verbose >= 2 {
                for l in take_trace() {
                    println!("      | {}", cut(&l, 150));
                }
            }
            let _ = std::io::stdout().flush();
        }
        // the next row shows only its own commands
        take_trace();
        match stat {
            Stat::Pass => self.pass += 1,
            Stat::Fail => self.fail += 1,
            Stat::Warn => self.warn += 1,
            Stat::Skip => self.skip += 1,
        }
    }
}

/// Runs `prog args…` with `input` on stdin; stdout trimmed of the final
/// newline, None if it could not start or exited non-zero.
fn run(prog: &str, args: &[&str], input: Option<&[u8]>) -> Option<String> {
    let mut cmd = Command::new(prog);
    cmd.args(args).stderr(Stdio::null()).stdout(Stdio::piped());
    cmd.stdin(if input.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    });
    let Ok(mut child) = cmd.spawn() else {
        trace(prog, args, input, "", None);
        return None;
    };
    if let Some(data) = input {
        let mut stdin = child.stdin.take()?;
        let _ = stdin.write_all(data);
    }
    let out = child.wait_with_output().ok()?;
    let mut s = String::from_utf8_lossy(&out.stdout).into_owned();
    while s.ends_with('\n') {
        s.pop();
    }
    trace(prog, args, input, &s, out.status.code());
    if !out.status.success() {
        return None;
    }
    Some(s)
}

/// Like `run`, but the output also on failure (empty if it could not start)
fn output(prog: &str, args: &[&str]) -> String {
    match Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
    {
        Ok(o) => {
            let s = String::from_utf8_lossy(&o.stdout).trim_end().to_string();
            trace(prog, args, None, &s, o.status.code());
            s
        }
        Err(_) => {
            trace(prog, args, None, "", None);
            String::new()
        }
    }
}

fn active(unit: &str) -> bool {
    let service = format!("{unit}.service");
    let args = ["is-active", "--quiet", service.as_str()];
    let code = Command::new("systemctl")
        .args(args)
        .status()
        .ok()
        .and_then(|s| s.code());
    trace("systemctl", &args, None, "", code);
    code == Some(0)
}

// `-vv`: every command a check runs, with its input, output and exit code,
// printed under the check's row (Table::row_more) and then cleared
thread_local! {
    static TRACE: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

/// Notes one command for `-vv`. Clipboard contents (wl-paste/wl-copy, the
/// `clip` rpc) show only their size: the user's clipboard stays off screen
fn trace(prog: &str, args: &[&str], input: Option<&[u8]>, out: &str, code: Option<i32>) {
    let secret = matches!(prog, "wl-paste" | "wl-copy") || args.contains(&"clip");
    let mut lines = vec![format!("$ {prog} {}", args.join(" "))];
    if let Some(data) = input.filter(|d| !d.is_empty()) {
        if secret {
            lines.push(format!("< ({} bytes)", data.len()));
        } else {
            let text = String::from_utf8_lossy(data).replace('\0', " ");
            lines.extend(text.trim_end().lines().map(|l| format!("< {l}")));
        }
    }
    if secret {
        if !out.is_empty() {
            lines.push(format!("({} bytes)", out.len()));
        }
    } else {
        let all: Vec<&str> = out.lines().collect();
        lines.extend(all.iter().take(20).map(|l| (*l).to_string()));
        if all.len() > 20 {
            lines.push(format!("... {} more lines", all.len() - 20));
        }
    }
    lines.push(match code {
        Some(c) => format!("(exit {c})"),
        None => "(did not start or was killed)".to_string(),
    });
    TRACE.with(|t| t.borrow_mut().extend(lines));
}

fn take_trace() -> Vec<String> {
    TRACE.with(|t| std::mem::take(&mut *t.borrow_mut()))
}

/// `nox-rpc --dom0 <service> <vm>` under `timeout`
fn rpc(service: &str, vm: &str, secs: &str, input: &[u8]) -> Option<String> {
    run(
        "timeout",
        &[secs, "nox-rpc", "--dom0", service, vm],
        Some(input),
    )
}

fn rpc_up(vm: &str) -> bool {
    rpc("ping", vm, "5", b"").as_deref() == Some("ok")
}

/// The VM's `doctor` rpc service: net|ip|wprsd|dbus
fn probe(vm: &str, what: &str) -> String {
    rpc("doctor", vm, "20", format!("{what}\n").as_bytes()).unwrap_or_default()
}

fn clip_get(vm: &str) -> Option<String> {
    rpc("clip", vm, "20", b"get\n")
}

fn clip_set(vm: &str, text: &str) {
    let _ = rpc("clip", vm, "20", format!("set\n{text}").as_bytes());
}

/// The relay's `--peer <domid>` from its command line
fn relay_peer(vm: &str) -> Option<String> {
    let pid = output(
        "systemctl",
        &[
            "show",
            "-p",
            "MainPID",
            "--value",
            &format!("nox-relay-{vm}.service"),
        ],
    );
    let cmdline = fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let args: Vec<&[u8]> = cmdline.split(|b| *b == 0).collect();
    let i = args.iter().position(|a| *a == b"--peer")?;
    args.get(i + 1)
        .map(|a| String::from_utf8_lossy(a).into_owned())
}

/// "… (domid N) to die" in the journal of the unit's current invocation
pub fn domid_from_journal(text: &str) -> Option<String> {
    text.lines().rev().find_map(|l| {
        let start = l.find("(domid ")? + "(domid ".len();
        let rest = &l[start..];
        let end = rest.find(')')?;
        let id = &rest[..end];
        (!id.is_empty() && id.bytes().all(|b| b.is_ascii_digit())).then(|| id.to_string())
    })
}

fn domid(d: &Domain) -> Option<String> {
    let inv = output(
        "systemctl",
        &[
            "show",
            "-p",
            "InvocationID",
            "--value",
            &format!("{}.service", d.unit),
        ],
    );
    let journal = output(
        "journalctl",
        &[
            "-q",
            &format!("_SYSTEMD_INVOCATION_ID={inv}"),
            "-o",
            "cat",
            "--no-pager",
        ],
    );
    domid_from_journal(&journal)
        .or_else(|| run("sudo", &["-n", "xl", "domid", &d.domain], None).filter(|s| !s.is_empty()))
}

fn state_dir(sub: &str) -> PathBuf {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state")
        });
    base.join(sub)
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Backup age in days from nox backup's record, None if there is none
pub fn backup_days(last: u64, now: u64) -> Option<u64> {
    (last != 0).then(|| now.saturating_sub(last) / 86400)
}

/// nox backup's `last`: the end time of the last finished `--all` run, then
/// `ok` or `partial` (older records have only the time) → (time, partial)
pub fn backup_last(s: &str) -> (u64, bool) {
    let mut l = s.lines();
    let t = l.next().and_then(|t| t.trim().parse().ok()).unwrap_or(0);
    (t, l.next().is_some_and(|w| w.trim() == "partial"))
}

const XEN_ERR: &str = r"^\(XEN\).*\b(err(or)?|fail(ed|ure)?|fault|panic)\b";

/// Lines of `text` matching `XEN_ERR` (grep -Ei, as the shell version)
fn xen_errors(text: &str) -> Vec<String> {
    run("grep", &["-Ei", XEN_ERR], Some(text.as_bytes()))
        .map(|s| s.lines().map(str::to_string).collect())
        .unwrap_or_default()
}

fn cut90(s: &str) -> String {
    cut(s, 90)
}

fn cut(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// `[-v|-vv] [--ack]` (`nox doctor --ack` comes here; nox parses with clap)
pub fn main_args(args: &[String]) -> ExitCode {
    let mut verbose = 0;
    let mut ack = false;
    for a in args {
        match a.as_str() {
            "-v" => verbose += 1,
            "-vv" => verbose += 2,
            "--ack" => ack = true,
            _ => {
                eprintln!("usage: nox doctor [-v|-vv] [--ack]   (checks the running system, starts nothing)");
                return ExitCode::from(2);
            }
        }
    }
    if ack {
        acknowledge()
    } else {
        run_doctor(verbose)
    }
}

/// Error lines the runs reported and nobody acknowledged yet (normalized,
/// one per line), and the ones acknowledged as known noise of this machine
const PENDING: &str = "errors-pending";
const KNOWN: &str = "errors-known";

/// The text of an error line without what changes between two of them:
/// the journal's date/host prefix, Xen's `(XEN) [time]` prefix, numbers and
/// long hex values (addresses)
pub fn normalize(line: &str) -> String {
    let msg = match line.find(" kernel: ") {
        Some(i) => &line[i + " kernel: ".len()..],
        None => line,
    };
    let msg = msg.trim_start_matches("(XEN)").trim_start();
    let msg = match msg.strip_prefix('[') {
        Some(rest) => rest.split_once(']').map_or(msg, |(_, r)| r.trim_start()),
        None => msg,
    };
    let mut out = String::new();
    for word in msg.split(' ') {
        if !out.is_empty() {
            out.push(' ');
        }
        let w = word.trim_start_matches("0x");
        if w.len() >= 6 && w.chars().all(|c| c.is_ascii_hexdigit()) {
            out.push('#');
            continue;
        }
        let mut digits = false;
        for c in word.chars() {
            if c.is_ascii_digit() {
                if !digits {
                    out.push('#');
                }
                digits = true;
            } else {
                out.push(c);
                digits = false;
            }
        }
    }
    out
}

fn read_set(path: &std::path::Path) -> Vec<String> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect()
}

/// Adds the new ones of `lines` to the pending file
fn remember_pending(dir: &std::path::Path, lines: &[String]) {
    let path = dir.join(PENDING);
    let mut set = read_set(&path);
    for l in lines {
        let n = normalize(l);
        if !set.contains(&n) {
            set.push(n);
        }
    }
    let _ = fs::write(
        &path,
        set.iter().map(|l| format!("{l}\n")).collect::<String>(),
    );
}

/// `nox doctor --ack`: the errors the runs reported become known noise of
/// this machine (they no longer fail; `-vv` still lists them)
fn acknowledge() -> ExitCode {
    let dir = state_dir("nox-doctor");
    let pending = read_set(&dir.join(PENDING));
    if pending.is_empty() {
        println!("nothing to acknowledge (no reported errors pending)");
        return ExitCode::SUCCESS;
    }
    let mut known = read_set(&dir.join(KNOWN));
    for p in &pending {
        println!("known from now on: {p}");
        if !known.contains(p) {
            known.push(p.clone());
        }
    }
    let ok = fs::write(
        dir.join(KNOWN),
        known.iter().map(|l| format!("{l}\n")).collect::<String>(),
    )
    .and_then(|()| fs::remove_file(dir.join(PENDING)));
    match ok {
        Ok(()) => {
            println!(
                "(list: {}; delete a line to forget it)",
                dir.join(KNOWN).display()
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("nox doctor: {e}");
            ExitCode::from(1)
        }
    }
}

/// Splits error lines into new and known (by their normalized text)
pub fn split_known(lines: Vec<String>, known: &[String]) -> (Vec<String>, Vec<String>) {
    lines
        .into_iter()
        .partition(|l| !known.contains(&normalize(l)))
}

pub fn run_doctor(verbose: u8) -> ExitCode {
    // NOX_REGISTRY: another registry (tests), as registry.rs
    let path = std::env::var("NOX_REGISTRY").unwrap_or_else(|_| REGISTRY.into());
    let data = match load(&path) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("nox doctor: {e:#}");
            return ExitCode::from(2);
        }
    };
    let mut t = Table {
        verbose,
        ..Table::default()
    };

    // --- domains
    let running: Vec<Domain> = data
        .domains
        .iter()
        .filter(|d| active(&d.unit))
        .cloned()
        .collect();
    // which domains run is setup, not a check of its own
    take_trace();

    // --- rpc and relay per running VM
    for d in &running {
        let vm = &d.name;
        if rpc_up(vm) {
            t.row(Stat::Pass, &format!("rpc {vm}"), "ok");
        } else {
            t.row(Stat::Fail, &format!("rpc {vm}"), "no answer");
        }
        if d.domain.is_empty() {
            continue;
        }
        let peer = relay_peer(vm);
        match domid(d) {
            None => t.row(
                Stat::Skip,
                &format!("relay {vm}"),
                &format!("no domid (journal of {}, xl)", d.unit),
            ),
            Some(id) if peer.as_deref() == Some(id.as_str()) => {
                t.row(Stat::Pass, &format!("relay {vm}"), &format!("domain {id}"))
            }
            Some(id) => t.row(
                Stat::Fail,
                &format!("relay {vm}"),
                &format!(
                    "relay on {}, domain is {id} (systemctl restart nox-relay-{vm})",
                    peer.as_deref().unwrap_or("none")
                ),
            ),
        }
    }

    // --- network
    let mut direct_ip = String::new();
    match running
        .iter()
        .find(|d| d.uplink == "sys-firewall" && !d.name.starts_with("sys-"))
    {
        Some(d) => {
            let code = probe(&d.name, "net");
            // the public IP (compared with sys-vpn clients below), before the
            // row so -vv shows it here
            direct_ip = probe(&d.name, "ip");
            let check = format!("net via sys-firewall ({})", d.name);
            if code == "200" {
                t.row(Stat::Pass, &check, "DNS + HTTPS");
            } else {
                let detail = if code.is_empty() {
                    "no DNS/connection"
                } else {
                    &code
                };
                t.row(Stat::Fail, &check, detail);
            }
        }
        None => t.row(
            Stat::Skip,
            "net via sys-firewall",
            "no running VM behind sys-firewall",
        ),
    }
    for d in running.iter().filter(|d| d.uplink == "sys-vpn") {
        let code = probe(&d.name, "net");
        let ip = probe(&d.name, "ip");
        let check = format!("net via sys-vpn ({})", d.name);
        if code != "200" {
            let detail = if code.is_empty() {
                "no DNS/connection"
            } else {
                &code
            };
            t.row(Stat::Fail, &check, detail);
        } else if direct_ip.is_empty() || ip.is_empty() {
            t.row(Stat::Skip, &check, "online, tunnel IP not compared");
        } else if ip != direct_ip {
            t.row(Stat::Pass, &check, &format!("tunnel IP {ip}"));
        } else {
            t.row(
                Stat::Fail,
                &check,
                &format!("same public IP as sys-net ({ip})"),
            );
        }
    }

    // --- GUI: app start by RPC, clipboard, wprs
    match running
        .iter()
        .find(|d| d.wprs && fs::metadata(format!("/run/nox-relay/{}-rpc-in.sock", d.name)).is_ok())
    {
        Some(d) => {
            let out = Command::new("timeout")
                .args(["20", "nox-rpc", "--dom0", "app", &d.name])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .and_then(|mut c| {
                    if let Some(mut i) = c.stdin.take() {
                        let _ = i.write_all(b"true\0");
                    }
                    c.wait_with_output()
                });
            let code = out.as_ref().ok().and_then(|o| o.status.code());
            let answer = out
                .map(|o| {
                    let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
                    s.push_str(&String::from_utf8_lossy(&o.stderr));
                    s.trim_end().to_string()
                })
                .unwrap_or_default();
            trace(
                "timeout",
                &["20", "nox-rpc", "--dom0", "app", &d.name],
                Some(b"true\0"),
                &answer,
                code,
            );
            let check = format!("rpc app ({})", d.name);
            if answer.starts_with("ok") {
                t.row(Stat::Pass, &check, &answer);
            } else {
                let detail = if answer.is_empty() {
                    "no answer"
                } else {
                    &answer
                };
                t.row(Stat::Fail, &check, detail);
            }
        }
        None => t.row(Stat::Skip, "rpc app", "no running VM with app RPC"),
    }

    if std::env::var_os("WAYLAND_DISPLAY").is_none_or(|v| v.is_empty()) {
        t.row(Stat::Skip, "clipboard round trip", "no Wayland session");
    } else if let Some(d) = running.iter().find(|d| d.wprs && d.clip == "allow") {
        clipboard(&mut t, &d.name);
    } else {
        t.row(
            Stat::Skip,
            "clipboard round trip",
            "no running wprs VM with clipboard allowed",
        );
    }

    let wprsc = output("pgrep", &["-x", "wprsc"]);
    for d in running.iter().filter(|d| d.wprs) {
        let state = probe(&d.name, "wprsd");
        let sock = format!("--socket=/run/nox-relay/{}-wprs.sock", d.name);
        let pids: Vec<(&str, Vec<u8>)> = wprsc
            .lines()
            .filter_map(|pid| {
                let c = fs::read(format!("/proc/{pid}/cmdline")).ok()?;
                c.split(|b| *b == 0)
                    .any(|a| a == sock.as_bytes())
                    .then_some((pid, c))
            })
            .collect();
        let n = pids.len();
        let check = format!("wprs {}", d.name);
        if state != "active" {
            let s = if state.is_empty() { "unknown" } else { &state };
            t.row(Stat::Fail, &check, &format!("wprsd {s}"));
        } else if n > 1 {
            t.row(
                Stat::Fail,
                &check,
                &format!("{n} wprsc in dom0 (one expected)"),
            );
        } else {
            t.row(Stat::Pass, &check, &format!("wprsd active, {n} wprsc"));
        }
        if d.grants && state == "active" {
            wprs_grants(&mut t, &d.name, pids.first());
        }
    }

    // --- D-Bus (filtered session bus over the relay)
    for d in running.iter().filter(|d| d.dbus) {
        let check = format!("dbus {}", d.name);
        if fs::metadata("/run/user/1000/vm-session-bus.sock").is_err() {
            t.row(Stat::Fail, &check, "dom0 proxy socket missing");
        } else if probe(&d.name, "dbus") == "ok" {
            t.row(Stat::Pass, &check, "notifications reachable");
        } else {
            t.row(
                Stat::Fail,
                &check,
                "org.freedesktop.Notifications not reachable",
            );
        }
    }

    // --- sound, Tor, USB (read only)
    audio(&mut t, &data.domains, &running);
    tor(&mut t, &data.domains, &running);
    usb(&mut t, data.usb.as_ref(), &running);

    // --- backup (nox backup records the last finished --all run)
    let (last, partial) =
        backup_last(&fs::read_to_string(state_dir("nox-backup").join("last")).unwrap_or_default());
    match backup_days(last, now()) {
        None => t.row(Stat::Warn, "backup", "none yet (nox backup --all)"),
        Some(age) if age > 7 => t.row(
            Stat::Warn,
            "backup",
            &format!("{age} days ago (nox backup --all)"),
        ),
        Some(age) if partial => t.row(
            Stat::Warn,
            "backup",
            &format!(
                "{age} days ago, partial: a target failed (its log in ~/.local/state/nox-backup)"
            ),
        ),
        Some(age) => t.row(Stat::Pass, "backup", &format!("{age} days ago")),
    }

    // --- system
    let stale: Vec<&str> = running
        .iter()
        .filter(|d| {
            let dir = PathBuf::from("/var/lib/microvms").join(&d.name);
            let booted = fs::canonicalize(dir.join("booted"));
            booted.is_ok() && fs::canonicalize(dir.join("current")).ok() != booted.ok()
        })
        .map(|d| d.name.as_str())
        .collect();
    if stale.is_empty() {
        t.row(Stat::Pass, "runners current", "no current != booted");
    } else {
        t.row(
            Stat::Fail,
            "runners current",
            &format!("restart: {}", stale.join(" ")),
        );
    }

    // nox rollback: a VM on an older runner is a temporary state
    let mut rolled: Vec<String> = fs::read_dir("/var/lib/microvms")
        .map(|it| {
            it.filter_map(|e| e.ok())
                .filter_map(|e| {
                    let vm = e.file_name().to_string_lossy().into_owned();
                    crate::manage::rollback_label(&vm).map(|l| format!("{vm} ({l})"))
                })
                .collect()
        })
        .unwrap_or_default();
    rolled.sort();
    if rolled.is_empty() {
        t.row(Stat::Pass, "rollbacks", "no VM rolled back");
    } else {
        t.row(
            Stat::Warn,
            "rollbacks",
            &format!(
                "{} (nox rollback <vm> --reset, or the next update)",
                rolled.join(" ")
            ),
        );
    }

    let use_pct: u32 = output("df", &["--output=pcent", "/"])
        .lines()
        .last()
        .unwrap_or("")
        .chars()
        .filter(char::is_ascii_digit)
        .collect::<String>()
        .parse()
        .unwrap_or(100);
    let stat = if use_pct < 90 { Stat::Pass } else { Stat::Fail };
    t.row(stat, "disk /", &format!("{use_pct} % used"));

    let failed = |user: bool| -> String {
        let mut a = vec!["--failed", "--no-legend", "--plain"];
        if user {
            a.insert(0, "--user");
        }
        output("systemctl", &a)
            .lines()
            .filter_map(|l| l.split_whitespace().next())
            .map(|u| format!("{u} "))
            .collect()
    };
    let units = format!("{}{}", failed(false), failed(true));
    if units.is_empty() {
        t.row(Stat::Pass, "failed units", "none");
    } else {
        t.row(Stat::Fail, "failed units", &units);
    }

    // Errors since the last run (first run: since boot). Known noise of
    // this machine (`nox doctor --ack`, e.g. a Bluetooth firmware message at
    // every boot) is no failure; new ones are remembered until acknowledged
    let dir = state_dir("nox-doctor");
    let _ = fs::create_dir_all(&dir);
    let known = read_set(&dir.join(KNOWN));
    let boot = fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .unwrap_or_default()
        .trim()
        .to_string();
    let prev = fs::read_to_string(dir.join("last")).unwrap_or_default();
    let prev: Vec<&str> = prev.lines().collect();
    let same_boot = prev.first() == Some(&boot.as_str());
    let since = match (same_boot, prev.get(1)) {
        (true, Some(ts)) => format!("--since=@{ts}"),
        _ => "-b".to_string(),
    };
    let kerr: Vec<String> = output(
        "journalctl",
        &["-k", "-p", "err", "-q", "--no-pager", &since],
    )
    .lines()
    .map(str::to_string)
    .collect();
    let (new, old) = split_known(kerr, &known);
    errors_row(&mut t, "kernel errors", &new, &old);
    remember_pending(&dir, &new);
    // xl dmesg: NoX lets the wheel group run exactly `xl dmesg` without a
    // password (read only), so it works where sudo asks for the rest
    let xerr = match run("sudo", &["-n", "xl", "dmesg"], None) {
        Some(xd) => {
            // Xen's own lines only: (dN) lines are guest consoles. The ring
            // keeps the whole boot: the count of the last run marks the new ones
            let errs = xen_errors(&xd);
            let before: usize = if same_boot {
                prev.get(2).and_then(|s| s.parse().ok()).unwrap_or(0)
            } else {
                0
            };
            let fresh = errs.iter().skip(before).cloned().collect();
            let (new, old) = split_known(fresh, &known);
            errors_row(&mut t, "xl dmesg", &new, &old);
            remember_pending(&dir, &new);
            errs.len()
        }
        None => {
            t.row(
                Stat::Skip,
                "xl dmesg",
                "sudo -n xl dmesg refused (NoX sudo rule missing?)",
            );
            0
        }
    };
    let _ = fs::write(dir.join("last"), format!("{boot}\n{}\n{xerr}\n", now()));

    println!();
    println!(
        "{} passed, {} failed, {} warnings, {} skipped",
        t.pass, t.fail, t.warn, t.skip
    );
    if t.fail == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

/// dom0's pulse server for the VMs (dom0/vm-audio.nix)
const PULSE_VM: &str = "/run/user/1000/nox-pulse-vm/native";

/// Sound: dom0's side (pipewire, the VMs' playback-only pulse server, a
/// default sink), then per running VM its tunnel sink and its stream in
/// dom0. A VM whose pipewire socket activation has not started is SKIP:
/// the probe does not start it
fn audio(t: &mut Table, all: &[Domain], running: &[Domain]) {
    if !all.iter().any(|d| d.audio) {
        t.row(Stat::Skip, "audio dom0", "no VM with sound on this machine");
        return;
    }
    let mut missing: Vec<String> = ["pipewire", "wireplumber", "nox-pulse-vm"]
        .iter()
        .filter_map(|u| {
            let state = output(
                "systemctl",
                &["--user", "is-active", &format!("{u}.service")],
            );
            (state != "active")
                .then(|| format!("{u} {}", if state.is_empty() { "unknown" } else { &state }))
        })
        .collect();
    if fs::metadata(PULSE_VM).is_err() {
        missing.push(format!("{PULSE_VM} missing"));
    }
    if !missing.is_empty() {
        t.row(Stat::Fail, "audio dom0", &missing.join(", "));
    } else if let Some(info) = run(
        "timeout",
        &["5", "wpctl", "inspect", "@DEFAULT_AUDIO_SINK@"],
        None,
    ) {
        let mut detail = format!("nox-pulse-vm up, sink {}", sink_name(&info).unwrap_or("?"));
        let volume = output(
            "timeout",
            &["5", "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"],
        );
        if volume.contains("[MUTED]") {
            detail.push_str(", muted");
        }
        if output(
            "systemctl",
            &["--user", "is-active", "nox-pulse-mic.service"],
        ) == "active"
        {
            detail.push_str(", microphone on (nox mic off)");
        }
        t.row(Stat::Pass, "audio dom0", &detail);
    } else {
        t.row(Stat::Fail, "audio dom0", "no default sink (wpctl status)");
    }

    // pw-dump once, for the first VM that needs it
    let mut hosts: Option<Vec<String>> = None;
    for d in running.iter().filter(|d| d.audio) {
        let check = format!("audio {}", d.name);
        match probe(&d.name, "audio").as_str() {
            "idle" => t.row(
                Stat::Skip,
                &check,
                "pipewire not started yet (nothing played)",
            ),
            "no-sink" => t.row(
                Stat::Fail,
                &check,
                "pipewire runs without its tunnel sink nox-dom0",
            ),
            "ok" => {
                let hosts =
                    hosts.get_or_insert_with(|| pw_hosts(&output("timeout", &["5", "pw-dump"])));
                if hosts.contains(&d.domain) {
                    t.row(Stat::Pass, &check, "tunnel sink connected to dom0");
                } else {
                    t.row(
                        Stat::Fail,
                        &check,
                        &format!(
                            "tunnel sink, but no stream from {} in dom0 (nox-relay-{} pulse)",
                            d.domain, d.name
                        ),
                    );
                }
            }
            "" => t.row(Stat::Fail, &check, "no answer"),
            _ => t.row(
                Stat::Skip,
                &check,
                "the VM has no audio probe yet (restart it after the update)",
            ),
        }
    }
}

/// `node.description` in `wpctl inspect`
pub fn sink_name(inspect: &str) -> Option<&str> {
    inspect.lines().find_map(|l| {
        let rest = l
            .trim_start_matches([' ', '*'])
            .strip_prefix("node.description = ")?;
        Some(rest.trim().trim_matches('"'))
    })
}

/// `application.process.host` of every object in dom0's pipewire
/// (`pw-dump`): a VM's tunnel shows up as its client and stream
pub fn pw_hosts(dump: &str) -> Vec<String> {
    let Ok(serde_json::Value::Array(objects)) = serde_json::from_str::<serde_json::Value>(dump)
    else {
        return Vec::new();
    };
    objects
        .iter()
        .filter_map(|o| o["info"]["props"]["application.process.host"].as_str())
        .map(str::to_string)
        .collect()
}

/// Tor in the gateway (Whonix-Gateway, rpc `tor-status` of
/// modules/xen-image-domains.nix): its bootstrap and sdwdate, read only
fn tor(t: &mut Table, all: &[Domain], running: &[Domain]) {
    let gateways: Vec<&Domain> = all.iter().filter(|d| d.tor).collect();
    if gateways.is_empty() {
        t.row(Stat::Skip, "tor", "no Tor gateway on this machine");
    }
    for d in gateways {
        let check = format!("tor {}", d.name);
        if !running.iter().any(|r| r.name == d.name) {
            t.row(Stat::Skip, &check, "not running");
            continue;
        }
        match rpc("tor-status", &d.name, "10", b"").filter(|a| !a.is_empty()) {
            Some(answer) => {
                let (stat, detail) = tor_verdict(&answer);
                t.row(stat, &check, &detail);
            }
            None => t.row(
                Stat::Skip,
                &check,
                &format!(
                    "no tor-status answer (older guest store disk: systemctl restart {})",
                    d.unit
                ),
            ),
        }
    }
}

/// The gateway's answer: the state of tor@default, or "active <seconds
/// since Tor's start> <sdwdate yes|no> <last Bootstrapped line or ->".
/// 100 % with sdwdate synced is PASS; 100 % without is WARN (Tor once
/// reported 100 % from its saved state without a working circuit,
/// 2026-10-12); below 100 % WARN in the first 5 minutes, FAIL after
pub fn tor_verdict(answer: &str) -> (Stat, String) {
    let mut f = answer.splitn(4, ' ');
    let state = f.next().unwrap_or("");
    if state != "active" {
        let state = if state.is_empty() { "unknown" } else { state };
        return (Stat::Fail, format!("tor@default {state}"));
    }
    let age: u64 = f.next().and_then(|a| a.parse().ok()).unwrap_or(0);
    let synced = f.next() == Some("yes");
    let line = f.next().unwrap_or("-").trim();
    let pct: Option<u32> = line
        .strip_prefix("Bootstrapped ")
        .and_then(|r| r.split('%').next())
        .and_then(|p| p.parse().ok());
    let shown = if pct.is_some() {
        cut90(line)
    } else {
        "no bootstrap in Tor's log".to_string()
    };
    match pct {
        Some(100) if synced => (Stat::Pass, "Bootstrapped 100 %, sdwdate synced".into()),
        Some(100) => (
            Stat::Warn,
            "Bootstrapped 100 %, sdwdate not synced (yet): a working circuit is not proven".into(),
        ),
        _ if age < 300 => (Stat::Warn, format!("{shown}, Tor started {age} s ago")),
        Some(_) => (Stat::Fail, format!("{shown}, Tor running {age} s")),
        None => (
            Stat::Fail,
            format!("{shown}, Tor running {age} s (DisableNetwork 1? README Whonix)"),
        ),
    }
}

/// A device in sys-usb's `usb-helper list`: status 1 exported, 2 in use
/// (USB/IP), - in sys-usb
#[derive(Debug, PartialEq, Eq)]
pub struct UsbDev {
    pub busid: String,
    pub id: String,
    pub status: String,
    pub name: String,
}

/// `busid vendor:product status bluetooth name` per line
pub fn parse_usb_list(s: &str) -> Vec<UsbDev> {
    s.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            let [busid, id, status, _bt, name] = f.as_slice() else {
                return None;
            };
            Some(UsbDev {
                busid: busid.to_string(),
                id: id.to_string(),
                status: status.to_string(),
                name: name.to_string(),
            })
        })
        .collect()
}

/// vm-usb's assignments (/run/vm-usb/assign): (busid, vendor:product, vm);
/// vm `-`: detached by hand, stays in sys-usb
pub fn parse_assign(s: &str) -> Vec<(String, String, String)> {
    s.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            match f.as_slice() {
                [busid, id, vm, ..] => Some((busid.to_string(), id.to_string(), vm.to_string())),
                _ => None,
            }
        })
        .collect()
}

/// Where sys-usb's devices are vs. where the registry and vm-usb want them:
/// a device on a VM outside its allowedOwners, assigned to a running VM but
/// not in use there, exported without an assignment, or not on its running
/// defaultOwner VM
pub fn usb_problems(
    devs: &[UsbDev],
    assign: &[(String, String, String)],
    registry: &[UsbDevice],
    running: &[&str],
) -> Vec<String> {
    let mut out = Vec::new();
    for dev in devs {
        let reg = registry.iter().find(|r| r.id == dev.id);
        let name = reg.map_or(dev.name.as_str(), |r| r.name.as_str());
        let b = &dev.busid;
        let owner = assign
            .iter()
            .find(|a| a.0 == dev.busid && a.1 == dev.id)
            .map(|a| a.2.as_str());
        match owner {
            Some(vm) if vm != "-" => {
                if let Some(r) = reg {
                    if !r.allowed.is_empty() && !r.allowed.iter().any(|a| a == vm) {
                        out.push(format!("{name} ({b}) on {vm}, not in its allowedOwners"));
                    }
                }
                if running.contains(&vm) && dev.status != "2" {
                    out.push(format!(
                        "{name} ({b}) assigned to {vm}, not in use there (USB/IP link?)"
                    ));
                }
            }
            _ => {
                if dev.status == "1" || dev.status == "2" {
                    out.push(format!(
                        "{name} ({b}) exported over USB/IP without an assignment"
                    ));
                }
                let default_vm = reg
                    .map(|r| r.owner.as_str())
                    .filter(|o| !["", "host", "sys-usb"].contains(o));
                if let (None, Some(vm)) = (owner, default_vm) {
                    if running.contains(&vm) {
                        out.push(format!(
                            "{name} ({b}) not on {vm} (defaultOwner, vm-usb-auto)"
                        ));
                    }
                }
            }
        }
    }
    out
}

/// The input proxy's devices in dom0 (/proc/bus/input/devices):
/// `xen-input-proxy <vendor>-<product>-<eventN>` → `<vendor>-<product>-<eventN>`
pub fn proxied_inputs(devices: &str) -> Vec<String> {
    devices
        .lines()
        .filter_map(|l| l.strip_prefix("N: Name=\"xen-input-proxy "))
        .map(|n| n.trim_end_matches('"').to_string())
        .collect()
}

/// sys-usb's input devices (`eventN vendor:product busid` per line) that
/// may go to dom0 (registry owner `host`, or `nox usb allow-input`: lines
/// `busid vendor:product`) vs. the ones the proxy forwards: (how many
/// should be forwarded, problems)
pub fn input_problems(
    inputs: &str,
    whitelist: &[&str],
    allowed: &str,
    proxied: &[String],
) -> (usize, Vec<String>) {
    let mut want = Vec::new();
    for l in inputs.lines() {
        let f: Vec<&str> = l.split_whitespace().collect();
        let [ev, vp, busid] = f.as_slice() else {
            continue;
        };
        let ok = whitelist.contains(vp)
            || allowed
                .lines()
                .any(|a| a.split_whitespace().collect::<Vec<_>>() == [*busid, *vp]);
        if ok {
            want.push(format!("{}-{ev}", vp.replace(':', "-")));
        }
    }
    let mut out = Vec::new();
    for w in &want {
        if !proxied.contains(w) {
            out.push(format!("{w} not forwarded to dom0 (xen-input-proxy)"));
        }
    }
    for p in proxied {
        if !want.contains(p) {
            out.push(format!("{p} forwarded to dom0, but not allowed or gone"));
        }
    }
    (want.len(), out)
}

/// sys-usb's usb-helper over rpc (read-only commands only): the answer
/// without its last line `exit 0`, None on another exit or no answer
fn usb_helper(cmd: &str) -> Option<String> {
    let out = rpc("usb", "sys-usb", "10", format!("{cmd}\n").as_bytes())?;
    let (body, rc) = out.rsplit_once('\n').unwrap_or(("", out.as_str()));
    (rc == "exit 0").then(|| body.to_string())
}

/// USB: the controllers on pciback (sys-usb's, not back in dom0), sys-usb's
/// helper and dom0's two USB services, the assignments, the input proxy
fn usb(t: &mut Table, usb: Option<&Usb>, running: &[Domain]) {
    let Some(usb) = usb else {
        t.row(Stat::Skip, "usb", "no sys-usb on this machine");
        return;
    };
    // also with sys-usb stopped: after sys-usb-fallback/-rescue the
    // controllers are back on their USB driver in dom0
    if usb.pci.is_empty() {
        t.row(
            Stat::Skip,
            "usb controllers",
            "none in the registry (pciDevicePaths.usb)",
        );
    } else {
        let bad: Vec<String> = usb
            .pci
            .iter()
            .filter_map(|p| {
                let driver = fs::read_link(format!("/sys/bus/pci/devices/{p}/driver"))
                    .ok()
                    .and_then(|l| l.file_name().map(|n| n.to_string_lossy().into_owned()))
                    .unwrap_or_else(|| "no driver".into());
                (driver != "pciback").then(|| format!("{p} on {driver}"))
            })
            .collect();
        if bad.is_empty() {
            t.row(
                Stat::Pass,
                "usb controllers",
                &format!("{} on pciback (sys-usb)", usb.pci.len()),
            );
        } else {
            t.row(
                Stat::Fail,
                "usb controllers",
                &format!("{} in dom0 (sys-usb-fallback or -rescue?)", bad.join(", ")),
            );
        }
    }
    if !running.iter().any(|d| d.name == "sys-usb") {
        t.row(Stat::Skip, "usb sys-usb", "sys-usb not running");
        return;
    }
    let Some(list) = usb_helper("list") else {
        t.row(Stat::Fail, "usb sys-usb", "usb-helper list: no answer");
        return;
    };
    let devs = parse_usb_list(&list);
    let down: Vec<&str> = ["vm-usb-auto", "xen-input-proxy"]
        .into_iter()
        .filter(|u| !active(u))
        .collect();
    if down.is_empty() {
        t.row(
            Stat::Pass,
            "usb sys-usb",
            &format!("{} devices, vm-usb-auto and input proxy active", devs.len()),
        );
    } else {
        t.row(
            Stat::Fail,
            "usb sys-usb",
            &format!("{} not active", down.join(", ")),
        );
    }

    let up: Vec<&str> = running.iter().map(|d| d.name.as_str()).collect();
    match fs::read_to_string("/run/vm-usb/assign") {
        Ok(text) => {
            let assign = parse_assign(&text);
            let problems = usb_problems(&devs, &assign, &usb.devices, &up);
            let attached = assign.iter().filter(|a| a.2 != "-").count();
            bad_or_pass(
                t,
                "usb assignments",
                &problems,
                &format!("{attached} attached, all as the registry wants"),
            );
        }
        Err(_) => t.row(
            Stat::Skip,
            "usb assignments",
            "/run/vm-usb/assign unreadable",
        ),
    }

    match usb_helper("inputs") {
        Some(inputs) => {
            let whitelist: Vec<&str> = usb
                .devices
                .iter()
                .filter(|d| d.owner == "host")
                .map(|d| d.id.as_str())
                .collect();
            let allowed = fs::read_to_string("/run/vm-usb/input-allowed").unwrap_or_default();
            let proxied =
                proxied_inputs(&fs::read_to_string("/proc/bus/input/devices").unwrap_or_default());
            let (n, problems) = input_problems(&inputs, &whitelist, &allowed, &proxied);
            bad_or_pass(
                t,
                "usb input",
                &problems,
                &format!("{n} input device(s) forwarded to dom0"),
            );
        }
        None => t.row(Stat::Fail, "usb input", "usb-helper inputs: no answer"),
    }
}

/// FAIL with the first problem as detail and all of them below, else PASS
fn bad_or_pass(t: &mut Table, check: &str, problems: &[String], pass: &str) {
    match problems.first() {
        None => t.row(Stat::Pass, check, pass),
        Some(first) => {
            let detail = if problems.len() > 1 {
                format!("{} problems, first: {}", problems.len(), cut90(first))
            } else {
                first.clone()
            };
            t.row_more(Stat::Fail, check, &detail, problems);
        }
    }
}

/// kernel errors / xl dmesg: FAIL with every new line below it, PASS when
/// there are none or only known ones
fn errors_row(t: &mut Table, check: &str, new: &[String], old: &[String]) {
    let known = if old.is_empty() {
        String::new()
    } else {
        format!(" ({} known)", old.len())
    };
    if new.is_empty() {
        t.row_more(Stat::Pass, check, &format!("none new{known}"), old);
    } else {
        let mut more = new.to_vec();
        more.push("known noise of this machine? nox doctor --ack".into());
        t.row_more(
            Stat::Fail,
            check,
            &format!(
                "{} new{known}, last: {}",
                new.len(),
                cut90(new.last().map(String::as_str).unwrap_or(""))
            ),
            &more,
        );
    }
}

/// wprs pixels over grant-shared memory: the relay's broker socket, wprsc
/// started with it, wprsc's mappings of the guest's grants and grant
/// messages since wprsc and the relay started. WARN, never FAIL: wprs
/// falls back to the stream and keeps working
fn wprs_grants(t: &mut Table, vm: &str, wprsc: Option<&(&str, Vec<u8>)>) {
    let check = format!("wprs grants {vm}");
    let broker = format!("/run/nox-relay/{vm}-grants.sock");
    if fs::metadata(&broker).is_err() {
        t.row(
            Stat::Warn,
            &check,
            &format!("{broker} missing (nox-relay-{vm})"),
        );
        return;
    }
    let Some((pid, cmdline)) = wprsc else {
        t.row(Stat::Skip, &check, "no wprsc");
        return;
    };
    let arg = format!("--xen-grant-socket={broker}");
    if !cmdline.split(|b| *b == 0).any(|a| a == arg.as_bytes()) {
        t.row(
            Stat::Warn,
            &check,
            "wprsc runs without the broker (started before it): pixels over the stream",
        );
        return;
    }
    let maps = fs::read_to_string(format!("/proc/{pid}/maps")).unwrap_or_default();
    let mapped = gntdev_maps(&maps);
    let invocation = |user: bool, unit: &str| {
        let mut a = vec!["show", "-p", "InvocationID", "--value", unit];
        if user {
            a.insert(0, "--user");
        }
        output("systemctl", &a)
    };
    let journal = |user: bool, id: &str| {
        if id.is_empty() {
            return String::new();
        }
        let m = format!("_SYSTEMD_INVOCATION_ID={id}");
        let mut a = vec!["-q", "--no-pager", "-o", "cat", m.as_str()];
        if user {
            a.insert(0, "--user");
        }
        output("journalctl", &a)
    };
    let client = journal(true, &invocation(true, &format!("wprsc@{vm}")));
    let relay = journal(false, &invocation(false, &format!("nox-relay-{vm}")));
    let msgs = grant_messages(&client, &relay);
    if !msgs.is_empty() {
        t.row_more(
            Stat::Warn,
            &check,
            &format!(
                "{} grant message(s) since start, {mapped} mappings",
                msgs.len()
            ),
            &msgs,
        );
    } else if mapped == 0 {
        // No window, no buffers: nothing to map yet (tray-only VMs)
        match vm_windows(&output("nox-wm", &["windows"]), vm) {
            Some(0) => t.row(Stat::Pass, &check, "broker up, no window open"),
            Some(n) => t.row(
                Stat::Warn,
                &check,
                &format!("{n} window(s), but wprsc maps no grants: pixels over the stream"),
            ),
            None => t.row(
                Stat::Warn,
                &check,
                "wprsc maps no grants: pixels over the stream (or no window open)",
            ),
        }
    } else {
        t.row(
            Stat::Pass,
            &check,
            &format!("broker up, wprsc maps {mapped} grant region(s)"),
        );
    }
}

/// The VM's windows in `nox-wm windows` (app ids, one per line; wprsc's
/// prefix `[<vm>] `); None if the compositor hook gave no list
pub fn vm_windows(app_ids: &str, vm: &str) -> Option<usize> {
    if app_ids.trim().is_empty() {
        return None;
    }
    let prefix = format!("[{vm}] ");
    Some(app_ids.lines().filter(|a| a.starts_with(&prefix)).count())
}

/// wprsc's mappings of granted pages (/proc/<pid>/maps)
pub fn gntdev_maps(maps: &str) -> usize {
    maps.lines()
        .filter(|l| l.ends_with("/dev/xen/gntdev"))
        .count()
}

/// WARN/ERROR lines about grants or shared memory in wprsc's log (tracing,
/// with colors) and the relay's `grants:` lines
pub fn grant_messages(wprsc: &str, relay: &str) -> Vec<String> {
    let mut out: Vec<String> = wprsc
        .lines()
        .map(strip_ansi)
        .filter(|l| {
            let low = l.to_lowercase();
            (l.contains(" WARN ") || l.contains(" ERROR "))
                && ["grant", "shm", "gntdev"].iter().any(|k| low.contains(k))
        })
        .map(|l| format!("wprsc: {}", l.trim()))
        .collect();
    out.extend(
        relay
            .lines()
            .filter(|l| l.starts_with("grants:"))
            .map(|l| format!("relay: {l}")),
    );
    out
}

/// Drops ANSI color sequences (ESC [ … m)
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            for c in chars.by_ref() {
                if c.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// dom0 → VM → dom0 with a token; both clipboards restored afterwards
fn clipboard(t: &mut Table, vm: &str) {
    let dom0 = run("wl-paste", &["--no-newline", "--type", "text"], None);
    let saved_vm = clip_get(vm);
    let token = format!(
        "nox-doctor-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0)
    );
    clip_set(vm, &token);
    let got = clip_get(vm).unwrap_or_default();
    // wl-copy forks and keeps serving: never on our stdout
    wl_copy(Some(&got));
    let back = run("wl-paste", &["--no-newline", "--type", "text"], None).unwrap_or_default();
    match &dom0 {
        Some(text) => wl_copy(Some(text)),
        None => wl_copy(None),
    }
    if let Some(text) = &saved_vm {
        clip_set(vm, text);
    }
    if back == token {
        t.row(
            Stat::Pass,
            "clipboard round trip",
            &format!("dom0 -> {vm} -> dom0, both restored"),
        );
    } else {
        t.row(
            Stat::Fail,
            "clipboard round trip",
            &format!("dom0 -> {vm} -> dom0 lost the text"),
        );
    }
}

/// `wl-copy --type text/plain` with `text`, or `wl-copy --clear`
fn wl_copy(text: Option<&str>) {
    let mut cmd = Command::new("wl-copy");
    match text {
        Some(_) => cmd.args(["--type", "text/plain"]),
        None => cmd.arg("--clear"),
    };
    cmd.stdout(Stdio::null()).stderr(Stdio::null());
    cmd.stdin(if text.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    });
    let args: &[&str] = if text.is_some() {
        &["--type", "text/plain"]
    } else {
        &["--clear"]
    };
    let mut code = None;
    if let Ok(mut child) = cmd.spawn() {
        if let (Some(data), Some(mut stdin)) = (text, child.stdin.take()) {
            let _ = stdin.write_all(data.as_bytes());
        }
        code = child.wait().ok().and_then(|s| s.code());
    }
    trace("wl-copy", args, text.map(str::as_bytes), "", code);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_parses() {
        let reg: Registry = serde_json::from_str(
            r#"{"vms":["chat"],"doctor":{
            "domains":[{"name":"chat","unit":"microvm@chat","domain":"chat-vm",
            "wprs":true,"dbus":true,"audio":true,"tor":false,"uplink":"sys-firewall","clip":"allow"}],
            "usb":{"pci":["0000:03:00.3"],"devices":[{"id":"0408:5365","name":"webcam",
            "owner":"chat","allowed":["chat"]}]}}}"#,
        )
        .unwrap();
        let d = &reg.doctor.domains[0];
        assert_eq!(d.unit, "microvm@chat");
        assert!(d.wprs && d.dbus && d.audio && !d.tor);
        assert_eq!(d.uplink, "sys-firewall");
        let usb = reg.doctor.usb.as_ref().unwrap();
        assert_eq!(usb.pci, ["0000:03:00.3"]);
        assert_eq!(usb.devices[0].owner, "chat");
        // without sys-usb the module writes null; older registries have no field
        let reg: Registry =
            serde_json::from_str(r#"{"doctor":{"domains":[],"usb":null,"autostart":["x"]}}"#)
                .unwrap();
        assert!(reg.doctor.usb.is_none());
    }

    #[test]
    fn audio_parsers() {
        let inspect = "id 51, type PipeWire:Interface:Node\n    alsa.card = \"1\"\n  * node.description = \"Ryzen HD Audio Controller Speaker\"\n  * node.name = \"alsa_output\"";
        assert_eq!(
            sink_name(inspect),
            Some("Ryzen HD Audio Controller Speaker")
        );
        assert_eq!(sink_name("nothing"), None);
        let dump = r#"[{"id":0,"type":"PipeWire:Interface:Core","info":{"props":{}}},
            {"id":65,"type":"PipeWire:Interface:Client","info":{"props":{"application.process.host":"chat-vm"}}},
            {"id":33,"type":"PipeWire:Interface:Client","info":{"props":{"application.process.host":"hp"}}},
            {"id":7,"type":"PipeWire:Interface:Module","info":null}]"#;
        assert_eq!(pw_hosts(dump), ["chat-vm", "hp"]);
        assert!(pw_hosts("").is_empty());
    }

    #[test]
    fn tor_answers() {
        let (s, _) = tor_verdict("active 900 yes Bootstrapped 100% (done): Done");
        assert_eq!(s, Stat::Pass);
        let (s, _) = tor_verdict("active 900 no Bootstrapped 100% (done): Done");
        assert_eq!(s, Stat::Warn);
        let (s, d) = tor_verdict("active 60 no Bootstrapped 30% (loading_status): Loading");
        assert_eq!(s, Stat::Warn);
        assert!(d.contains("30%"), "{d}");
        let (s, _) = tor_verdict("active 900 no Bootstrapped 30% (loading_status): Loading");
        assert_eq!(s, Stat::Fail);
        let (s, d) = tor_verdict("active 900 no -");
        assert_eq!(s, Stat::Fail);
        assert!(d.contains("DisableNetwork"), "{d}");
        let (s, d) = tor_verdict("inactive");
        assert_eq!((s, d.as_str()), (Stat::Fail, "tor@default inactive"));
    }

    #[test]
    fn usb_consistency() {
        let devs = parse_usb_list(
            "1-3 0408:5365 - 0 HP_TrueVision_HD_Camera\n1-4 0bda:b00e - 1 Bluetooth_Radio_\n\
             3-2 093a:2533 - 0 SHARKFORCE_OpticalMouse\n3-5 1234:5678 2 0 Stick\nbad line",
        );
        assert_eq!(devs.len(), 4);
        assert_eq!(devs[0].status, "-");
        let reg = vec![
            UsbDevice {
                id: "0408:5365".into(),
                name: "webcam".into(),
                owner: "chat".into(),
                allowed: vec!["chat".into()],
            },
            UsbDevice {
                id: "0bda:b00e".into(),
                name: "bt".into(),
                owner: "sys-usb".into(),
                allowed: vec!["sys-usb".into(), "chat".into()],
            },
        ];
        // chat stopped, nothing assigned: consistent, except the stick in
        // use without an assignment
        let p = usb_problems(&devs, &[], &reg, &["sys-usb"]);
        assert_eq!(
            p,
            ["Stick (3-5) exported over USB/IP without an assignment"]
        );
        // chat runs: the webcam should be there
        let p = usb_problems(&devs[..1], &[], &reg, &["chat"]);
        assert_eq!(p, ["webcam (1-3) not on chat (defaultOwner, vm-usb-auto)"]);
        // detached by hand: stays in sys-usb
        let a = parse_assign("1-3 0408:5365 - -\n");
        assert!(usb_problems(&devs[..1], &a, &reg, &["chat"]).is_empty());
        // assigned, but not in use; and on a VM outside allowedOwners
        let a = parse_assign("1-3 0408:5365 chat 1a2b\n1-4 0bda:b00e disp 3c4d\n");
        let p = usb_problems(&devs[..2], &a, &reg, &["chat"]);
        assert_eq!(
            p,
            [
                "webcam (1-3) assigned to chat, not in use there (USB/IP link?)",
                "bt (1-4) on disp, not in its allowedOwners"
            ]
        );
    }

    #[test]
    fn input_proxy_consistency() {
        let proc =
            "I: Bus=0006\nN: Name=\"xen-input-proxy 093a-2533-event1\"\nN: Name=\"AT keyboard\"\n";
        let proxied = proxied_inputs(proc);
        assert_eq!(proxied, ["093a-2533-event1"]);
        let inputs = "event1 093a:2533 3-2\nevent2 093a:2533 3-2\nevent3 dead:beef 3-1";
        let (n, p) = input_problems(inputs, &["093a:2533"], "", &proxied);
        assert_eq!(n, 2);
        assert_eq!(
            p,
            ["093a-2533-event2 not forwarded to dom0 (xen-input-proxy)"]
        );
        // allowed by hand until unplugged
        let all = vec![
            "093a-2533-event1".to_string(),
            "093a-2533-event2".to_string(),
            "dead-beef-event3".to_string(),
        ];
        let (n, p) = input_problems(inputs, &["093a:2533"], "3-1 dead:beef\n", &all);
        assert_eq!((n, p.len()), (3, 0));
        let (_, p) = input_problems("", &[], "", &all[..1]);
        assert_eq!(
            p,
            ["093a-2533-event1 forwarded to dom0, but not allowed or gone"]
        );
    }

    #[test]
    fn registry_without_doctor() {
        let reg: Registry = serde_json::from_str(r#"{"vms":[]}"#).unwrap();
        assert!(reg.doctor.domains.is_empty());
    }

    #[test]
    fn domid_last_match() {
        let j = "Parsing config\nWaiting for domain chat-vm (domid 7) to die [pid 1]\n\
                 x\nWaiting for domain chat-vm (domid 12) to die [pid 2]\nfoo (domid ) bar\n";
        assert_eq!(domid_from_journal(j).as_deref(), Some("12"));
        assert_eq!(domid_from_journal("nothing"), None);
    }

    #[test]
    fn grants_from_maps_and_logs() {
        let maps = "7edd5162d000-7edd51daa000 r--s 00000000 00:07 442                        /dev/xen/gntdev\n\
                    7edd68478000-7edd68bf5000 r--p 00000000 00:00 0\n\
                    7edd68478000-7edd68bf5000 r--s 00000000 00:07 442                        /dev/xen/gntdev";
        assert_eq!(gntdev_maps(maps), 2);
        assert_eq!(gntdev_maps(""), 0);
        let windows = "[net] zen\n[netx] a\nfoot";
        assert_eq!(vm_windows(windows, "net"), Some(1));
        assert_eq!(vm_windows(windows, "chat"), Some(0));
        assert_eq!(vm_windows("", "net"), None);
        let wprsc = "\u{1b}[2m2026-10-29T13:42:54.641935Z\u{1b}[0m \u{1b}[31mERROR\u{1b}[0m ThreadId(01) \u{1b}[1mhandle_shm_buffer\u{1b}[0m: map failed\n\
                     \u{1b}[2m2026-10-29T13:42:54Z\u{1b}[0m \u{1b}[31mERROR\u{1b}[0m ThreadId(01) new_output: unknown\n\
                     running config: grant socket set";
        let relay = "peer connected\ngrants: map 3 pages: denied";
        let m = grant_messages(wprsc, relay);
        assert_eq!(m.len(), 2, "{m:?}");
        assert!(m[0].starts_with("wprsc: 2026-10-29T13:42:54.641935Z ERROR"));
        assert!(m[0].contains("handle_shm_buffer"));
        assert_eq!(m[1], "relay: grants: map 3 pages: denied");
    }

    #[test]
    fn backup_age() {
        assert_eq!(backup_days(0, 1_000_000), None);
        assert_eq!(backup_days(1_000_000 - 3 * 86400 - 5, 1_000_000), Some(3));
        assert_eq!(backup_last("1700000000\npartial\n"), (1_700_000_000, true));
        assert_eq!(backup_last("1700000000\nok\n"), (1_700_000_000, false));
        assert_eq!(backup_last("1700000000\n"), (1_700_000_000, false));
        assert_eq!(backup_last(""), (0, false));
    }

    #[test]
    fn error_lines_normalized() {
        let a =
            "Okt 28 23:21:29 host kernel: Bluetooth: hci0: FW download error recovery failed (-19)";
        let b =
            "Okt 29 08:02:11 host kernel: Bluetooth: hci0: FW download error recovery failed (-19)";
        assert_eq!(normalize(a), normalize(b));
        assert_eq!(
            normalize(a),
            "Bluetooth: hci#: FW download error recovery failed (-#)"
        );
        assert_eq!(
            normalize("(XEN) [  12.345678] AMD-Vi: IO_PAGE_FAULT at 0xffff88810abc"),
            normalize("(XEN) [ 999.000001] AMD-Vi: IO_PAGE_FAULT at 0xffff88820def")
        );
        let known = vec![normalize(a)];
        let (new, old) = split_known(
            vec![b.to_string(), "Okt 29 x kernel: nvme: timeout".into()],
            &known,
        );
        assert_eq!(old, [b]);
        assert_eq!(new, ["Okt 29 x kernel: nvme: timeout"]);
    }

    #[test]
    fn quiet_table_counts_everything() {
        let mut t = Table::default();
        t.row(Stat::Pass, "a", "");
        t.row_more(Stat::Fail, "b", "x", &["detail".into()]);
        assert_eq!((t.pass, t.fail, t.skip), (1, 1, 0));
        assert!(t.header);
        let mut q = Table::default();
        q.row(Stat::Pass, "a", "");
        assert!(!q.header);
    }

    #[test]
    fn warn_counts_on_its_own() {
        let mut t = Table::default();
        t.row(Stat::Pass, "a", "");
        t.row(Stat::Warn, "b", "");
        t.row(Stat::Skip, "c", "");
        t.row(Stat::Fail, "d", "");
        assert_eq!((t.pass, t.fail, t.warn, t.skip), (1, 1, 1, 1));
    }
}

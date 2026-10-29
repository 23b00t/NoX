//! `nox doctor` (also as `vm-doctor`): smoke test of the running system.
//!
//! Starts no VMs, checks only what runs: autostart domains, rpc and relay
//! per VM, network over sys-firewall (and the tunnel for sys-vpn clients),
//! app start by RPC, clipboard round trip, wprs, D-Bus, backup age, stale
//! runners, disk, failed units, kernel/Xen errors. Table of
//! PASS/FAIL/WARN/SKIP, exit 1 on any FAIL. The data per domain comes from
//! `/etc/nox/registry.json` (`doctor`), written by NoX's vm-doctor module;
//! the tools it asks (systemctl, nox-rpc, journalctl, xl, wl-clipboard, df)
//! run as processes.

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
    /// Units that start with the machine (microvm@… / xen-image@…)
    #[serde(default)]
    pub autostart: Vec<String>,
    #[serde(default)]
    pub domains: Vec<Domain>,
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
    #[serde(default)]
    pub dbus: bool,
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
/// row, 2 (`-vv`) every row with its details
#[derive(Default)]
pub struct Table {
    pub pass: u32,
    pub fail: u32,
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
            let _ = std::io::stdout().flush();
        }
        match stat {
            Stat::Pass => self.pass += 1,
            Stat::Fail => self.fail += 1,
            // as the shell version: WARN counts with the skipped ones
            Stat::Warn | Stat::Skip => self.skip += 1,
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
    let mut child = cmd.spawn().ok()?;
    if let Some(data) = input {
        let mut stdin = child.stdin.take()?;
        let _ = stdin.write_all(data);
    }
    let out = child.wait_with_output().ok()?;
    if !out.status.success() {
        return None;
    }
    let mut s = String::from_utf8_lossy(&out.stdout).into_owned();
    while s.ends_with('\n') {
        s.pop();
    }
    Some(s)
}

/// Like `run`, but the output also on failure (empty if it could not start)
fn output(prog: &str, args: &[&str]) -> String {
    Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim_end().to_string())
        .unwrap_or_default()
}

fn active(unit: &str) -> bool {
    Command::new("systemctl")
        .args(["is-active", "--quiet", &format!("{unit}.service")])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
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

/// `vm-doctor [-v|-vv] [--ack]` (the old name; nox doctor parses with clap)
pub fn main_args(args: &[String]) -> ExitCode {
    let mut verbose = 0;
    let mut ack = false;
    for a in args {
        match a.as_str() {
            "-v" => verbose += 1,
            "-vv" => verbose += 2,
            "--ack" => ack = true,
            _ => {
                eprintln!("usage: vm-doctor [-v|-vv] [--ack]   (checks the running system, starts nothing)");
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
    let dir = state_dir("vm-doctor");
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
    let data = match load(REGISTRY) {
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
    for u in &data.autostart {
        if active(u) {
            t.row(Stat::Pass, &format!("autostart {u}"), "running");
        } else {
            let state = output("systemctl", &["is-active", &format!("{u}.service")]);
            t.row(Stat::Fail, &format!("autostart {u}"), &state);
        }
    }
    let running: Vec<Domain> = data
        .domains
        .iter()
        .filter(|d| active(&d.unit))
        .cloned()
        .collect();

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
            direct_ip = probe(&d.name, "ip");
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
            let answer = out
                .map(|o| {
                    let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
                    s.push_str(&String::from_utf8_lossy(&o.stderr));
                    s.trim_end().to_string()
                })
                .unwrap_or_default();
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
        let n = wprsc
            .lines()
            .filter(|pid| {
                fs::read(format!("/proc/{pid}/cmdline"))
                    .map(|c| c.split(|b| *b == 0).any(|a| a == sock.as_bytes()))
                    .unwrap_or(false)
            })
            .count();
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

    // --- backup (nox backup records the last W1 run)
    let last: u64 = fs::read_to_string(state_dir("nox-backup").join("last"))
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);
    match backup_days(last, now()) {
        None => t.row(Stat::Warn, "backup", "none yet (nox backup)"),
        Some(age) if age > 7 => t.row(
            Stat::Warn,
            "backup",
            &format!("{age} days ago (nox backup)"),
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
    let dir = state_dir("vm-doctor");
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
    // password (read only), so it works where sudo asks for the rest (xmg)
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
    println!("{} passed, {} failed, {} skipped", t.pass, t.fail, t.skip);
    if t.fail == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
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

/// dom0 → VM → dom0 with a token; both clipboards restored afterwards
fn clipboard(t: &mut Table, vm: &str) {
    let dom0 = run("wl-paste", &["--no-newline", "--type", "text"], None);
    let saved_vm = clip_get(vm);
    let token = format!(
        "vm-doctor-{}-{}",
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
    if let Ok(mut child) = cmd.spawn() {
        if let (Some(data), Some(mut stdin)) = (text, child.stdin.take()) {
            let _ = stdin.write_all(data.as_bytes());
        }
        let _ = child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_parses() {
        let reg: Registry = serde_json::from_str(
            r#"{"vms":["chat"],"doctor":{"autostart":["microvm@sys-net"],
            "domains":[{"name":"chat","unit":"microvm@chat","domain":"chat-vm",
            "wprs":true,"dbus":true,"uplink":"sys-firewall","clip":"allow"}]}}"#,
        )
        .unwrap();
        assert_eq!(reg.doctor.autostart, ["microvm@sys-net"]);
        let d = &reg.doctor.domains[0];
        assert_eq!(d.unit, "microvm@chat");
        assert!(d.wprs && d.dbus);
        assert_eq!(d.uplink, "sys-firewall");
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
    fn backup_age() {
        assert_eq!(backup_days(0, 1_000_000), None);
        assert_eq!(backup_days(1_000_000 - 3 * 86400 - 5, 1_000_000), Some(3));
    }

    #[test]
    fn error_lines_normalized() {
        let a =
            "Okt 28 23:21:29 xmg kernel: Bluetooth: hci0: FW download error recovery failed (-19)";
        let b =
            "Okt 29 08:02:11 xmg kernel: Bluetooth: hci0: FW download error recovery failed (-19)";
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
    fn stats_count_like_the_script() {
        let mut t = Table::default();
        t.row(Stat::Pass, "a", "");
        t.row(Stat::Warn, "b", "");
        t.row(Stat::Skip, "c", "");
        t.row(Stat::Fail, "d", "");
        assert_eq!((t.pass, t.fail, t.skip), (1, 1, 2));
    }
}

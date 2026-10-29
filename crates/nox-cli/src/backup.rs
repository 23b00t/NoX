//! `nox backup` (formerly the vm-backup script; README "Backup", spec in
//! xen-migration.md "2. Backup"): backups onto an external LUKS disk that
//! hangs on the disposable disp-backup (USB/IP from sys-usb; NoX
//! nixos/vms/disp-backup has the disk side, its rpc service `backup`).
//! dom0 mounts no guest file system and has no SSH into the VMs:
//! - home: /home/user of NixOS VMs, one generation per run with hard links
//!   to the previous one (rsync in disp-backup against the VM's rpc
//!   services `backup-send` / `backup-recv`).
//! - full: whole disks (a VM's volumes, an image domain's raw image, dom0's
//!   ~/.ssh, the builder's key) as sparse tar + zstd streams from dom0 into
//!   disp-backup, one generation per run. A restore checks the checksum
//!   while it streams into a staging copy; the disk is replaced only then.
//!
//! Data: /etc/nox/registry.json `backup` (NoX nixos/dom0/tools/vm-backup.nix)
//! and `domains` (units). Rust orchestrates; tar, zstd, sha256sum, rsync
//! (in disp-backup) and nox-rpc do the bytes.
//! NOX_BACKUP_TEST_DISK=<file> (hidden, for tests on the hp): a disk image
//! file instead of the USB disk, formatted on first use.

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdout, Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde::Deserialize;

use crate::manage;
use crate::registry::{self, Domain};
use crate::sys;

/// What `nox backup …` asks for (main.rs builds it from the clap tree)
#[derive(Debug, PartialEq)]
pub enum Req {
    Home(Sel),
    Full {
        sel: Sel,
        level: u8,
    },
    Restore {
        full: bool,
        from: Option<String>,
        sel: Sel,
    },
    Disks(Sel),
    List,
    Prune {
        kind: String,
        keep: u32,
        dry_run: bool,
        targets: Vec<String>,
    },
}

/// Names or --all
#[derive(Debug, PartialEq)]
pub enum Sel {
    All,
    Names(Vec<String>),
}

/// registry.json `backup`
#[derive(Deserialize, Default, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Data {
    /// NixOS VMs home takes (all of this machine but disp-backup)
    #[serde(default)]
    pub home: Vec<String>,
    /// `--all` of home: registry `backup` (not sys-*, not disposables)
    #[serde(default)]
    pub home_default: Vec<String>,
    /// full targets in their order; `--all` = all of them
    #[serde(default)]
    pub full: Vec<Target>,
}

#[derive(Deserialize, Clone, Debug, PartialEq)]
pub struct Target {
    pub name: String,
    pub kind: Kind,
    /// Disks; dom0's (`ssh`) has no path (it is ~/.ssh)
    pub disks: Vec<Disk>,
    /// A disposable (sys-net, …): only its data volumes, stopping it loses
    /// its session
    #[serde(default)]
    pub disposable: bool,
}

#[derive(Deserialize, Clone, Debug, PartialEq)]
pub struct Disk {
    pub name: String,
    #[serde(default)]
    pub path: String,
}

#[derive(Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// a VM's volumes (disk = file name without .img)
    Vm,
    /// an image domain's raw image
    Image,
    /// dom0's ~/.ssh
    Dom0,
    /// the builder's signing key (over SSH)
    Builder,
}

// ---------- output: terminal + log ----------

static LOG: Mutex<Option<File>> = Mutex::new(None);

/// A line to stdout and to the log of the run
fn say(s: &str) {
    println!("{s}");
    log_line(s);
}

/// A line to stderr and to the log
fn warn(s: &str) {
    eprintln!("nox backup: {s}");
    log_line(&format!("nox backup: {s}"));
}

fn log_line(s: &str) {
    if let Ok(mut g) = LOG.lock() {
        if let Some(f) = g.as_mut() {
            let _ = writeln!(f, "{s}");
        }
    }
}

fn state_dir() -> PathBuf {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".local/state"));
    base.join("nox-backup")
}

fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

fn start_log(name: &str) -> PathBuf {
    let dir = state_dir();
    let _ = fs::create_dir_all(&dir);
    let path = dir.join(format!("{name}.log"));
    if let Ok(f) = OpenOptions::new().create(true).append(true).open(&path) {
        *LOG.lock().unwrap() = Some(f);
    }
    path
}

/// 1234567 → "1.2 MB" (SI, one decimal, like numfmt --to=si)
pub fn human(n: u64) -> String {
    let units = ["", "k", "M", "G", "T", "P"];
    let mut x = n as f64;
    let mut i = 0;
    while x >= 1000.0 && i + 1 < units.len() {
        x /= 1000.0;
        i += 1;
    }
    format!("{x:.1} {}B", units[i])
}

/// 75 → "1:15"
pub fn clock(secs: u64) -> String {
    format!("{}:{:02}", secs / 60, secs % 60)
}

fn hum_short(x: f64) -> String {
    if x >= 1e9 {
        format!("{:.1} GB", x / 1e9)
    } else if x >= 1e6 {
        format!("{:.1} MB", x / 1e6)
    } else {
        format!("{:.0} kB", x / 1e3)
    }
}

fn ask(q: &str) -> bool {
    eprint!("nox backup: {q} [y/N] ");
    let _ = io::stderr().flush();
    let mut a = String::new();
    if io::stdin().read_line(&mut a).is_err() {
        return false;
    }
    log_line(&format!("nox backup: {q} [y/N] {}", a.trim()));
    matches!(a.trim(), "y" | "Y")
}

fn prompt(q: &str) -> Option<String> {
    eprint!("{q}");
    let _ = io::stderr().flush();
    let mut a = String::new();
    io::stdin().read_line(&mut a).ok()?;
    Some(a.trim().to_string())
}

/// Reads a line without echo (stty -echo around it)
fn prompt_secret(q: &str) -> Option<String> {
    eprint!("{q}");
    let _ = io::stderr().flush();
    let tty = io::stdin().is_terminal();
    if tty {
        let _ = Command::new("stty").arg("-echo").status();
    }
    let mut a = String::new();
    let r = io::stdin().read_line(&mut a);
    if tty {
        let _ = Command::new("stty").arg("echo").status();
    }
    eprintln!();
    r.ok()?;
    Some(a.trim_end_matches(['\n', '\r']).to_string())
}

// ---------- interrupt ----------

static INTERRUPTED: AtomicBool = AtomicBool::new(false);

extern "C" fn on_sigint(_: i32) {
    INTERRUPTED.store(true, Ordering::SeqCst);
}

extern "C" {
    fn signal(signum: i32, handler: usize) -> usize;
}

/// Ctrl+C ends the current step (its tools get the signal too) and then the
/// run, with the summary and the disk locked; nox itself is not killed
fn catch_sigint() {
    const SIGINT: i32 = 2;
    // SAFETY: the handler only stores an atomic
    unsafe {
        signal(SIGINT, on_sigint as *const () as usize);
    }
}

fn interrupted() -> bool {
    INTERRUPTED.load(Ordering::SeqCst)
}

// ---------- sudo ----------

/// Asks for the sudo password once before the run (in a terminal, when
/// sudo has no cached ticket) and keeps the ticket fresh until nox ends:
/// a long restore otherwise asked again near its end (steam, 2.5 h)
fn sudo_keepalive() -> Result<(), String> {
    if Command::new("sudo")
        .args(["-n", "true"])
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
    {
        // NOPASSWD for everything or a fresh ticket; refresh it anyway
    } else if io::stdin().is_terminal() {
        eprintln!("nox backup: sudo password once for the whole run");
        if !Command::new("sudo")
            .arg("-v")
            .status()
            .is_ok_and(|s| s.success())
        {
            return Err("sudo failed".into());
        }
    } else {
        // no terminal (tests): the NOPASSWD rules must do
        return Ok(());
    }
    thread::spawn(|| loop {
        thread::sleep(Duration::from_secs(60));
        let _ = Command::new("sudo")
            .args(["-n", "-v"])
            .stderr(Stdio::null())
            .status();
    });
    Ok(())
}

// ---------- domains ----------

struct Doms(Vec<Domain>);

impl Doms {
    fn unit(&self, name: &str) -> String {
        registry::find(&self.0, name)
            .map(Domain::service)
            .unwrap_or_else(|| format!("microvm@{name}.service"))
    }
    fn running(&self, name: &str) -> bool {
        sys::is_active(&self.unit(name))
    }
    fn systemctl(&self, action: &str, name: &str) -> bool {
        let unit = self.unit(name);
        sys::run("sudo", ["systemctl", action, unit.as_str()]) == 0
    }
    /// Starts it again after a stop for the copy, with its tray apps and
    /// session windows like `nox restart` (vm-tray, vm-autostart)
    fn start_again(&self, name: &str) -> bool {
        if !self.systemctl("start", name) {
            return false;
        }
        manage::session_back(name);
        true
    }
}

fn wait_rpc(vm: &str) -> bool {
    for _ in 0..120 {
        if interrupted() {
            return false;
        }
        let ok = Command::new("timeout")
            .args(["5", "nox-rpc", "--dom0", "ping", vm])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .is_ok_and(|o| String::from_utf8_lossy(&o.stdout).trim() == "ok");
        if ok {
            return true;
        }
        thread::sleep(Duration::from_secs(1));
    }
    false
}

/// Starts <vm> if it is down (for a home backup); true in `started` means
/// it is stopped again afterwards
fn start_for(doms: &Doms, vm: &str) -> (bool, bool) {
    if doms.running(vm) {
        // a running VM may still be booting: wait for its rpc too
        return (wait_rpc(vm), false);
    }
    (doms.systemctl("start", vm) && wait_rpc(vm), true)
}

// ---------- disp-backup's service ----------

/// The answer of one call of disp-backup's `backup` service
#[derive(Default, Debug)]
struct Answer {
    /// `exit N`, the last line (None: no answer)
    rc: Option<i32>,
    /// rsync's "Total transferred file size"
    amount: Option<u64>,
    /// full-put: compressed size on the disk
    stored: Option<u64>,
    /// the other lines when captured
    text: Vec<String>,
}

impl Answer {
    fn ok(&self) -> bool {
        self.rc == Some(0)
    }
}

/// One record of the service's output (split at \r and \n)
#[derive(Debug, PartialEq)]
enum Rec {
    Exit(i32),
    /// rsync progress2: bytes, percent, rate, ETA
    Progress(u64, String, String, String),
    Amount(u64),
    Stored(u64),
    /// rsync's other statistics lines
    Skip,
    Text(String),
}

fn parse_rec(line: &str) -> Rec {
    if let Some(n) = line.strip_prefix("exit ") {
        if let Ok(n) = n.trim().parse() {
            return Rec::Exit(n);
        }
    }
    if let Some(n) = line.strip_prefix("stored-bytes ") {
        if let Ok(n) = n.trim().parse() {
            return Rec::Stored(n);
        }
    }
    if let Some(rest) = line.strip_prefix("Total transferred file size: ") {
        let digits: String = rest
            .split_whitespace()
            .next()
            .unwrap_or("")
            .chars()
            .filter(|c| *c != ',')
            .collect();
        if let Ok(n) = digits.parse() {
            return Rec::Amount(n);
        }
    }
    let w: Vec<&str> = line.split_whitespace().collect();
    if w.len() >= 4
        && w[0].chars().all(|c| c.is_ascii_digit() || c == ',')
        && w[1].ends_with('%')
        && w[1][..w[1].len() - 1].chars().all(|c| c.is_ascii_digit())
    {
        let b = w[0].replace(',', "").parse().unwrap_or(0);
        return Rec::Progress(b, w[1].into(), w[2].into(), w[3].into());
    }
    const STATS: [&str; 7] = [
        "Number of",
        "Total ",
        "Literal ",
        "Matched ",
        "File list",
        "sent ",
        "total size",
    ];
    if STATS.iter().any(|p| line.starts_with(p)) {
        return Rec::Skip;
    }
    Rec::Text(line.to_string())
}

fn rpc_backup() -> Command {
    let mut c = Command::new("nox-rpc");
    c.args(["--dom0", "backup", "disp-backup"]);
    c
}

/// Calls the service: `line` first, then `input` as its stdin. rsync's
/// progress is drawn in place under `label`; the other lines are printed
/// (or kept in `text` with `capture`)
fn call(line: &str, input: Option<Box<dyn Read + Send>>, label: &str, capture: bool) -> Answer {
    let mut child = match rpc_backup()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            warn(&format!("cannot run nox-rpc: {e}"));
            return Answer::default();
        }
    };
    let mut stdin = child.stdin.take().unwrap();
    let first = format!("{line}\n");
    let feeder = thread::spawn(move || {
        if stdin.write_all(first.as_bytes()).is_err() {
            return;
        }
        if let Some(mut r) = input {
            let _ = io::copy(&mut r, &mut stdin);
        }
    });
    let mut ans = Answer::default();
    let out = child.stdout.take().unwrap();
    let mut drawn = false;
    for rec in records(out) {
        match parse_rec(&rec) {
            Rec::Exit(n) => ans.rc = Some(n),
            Rec::Progress(b, pct, rate, eta) => {
                eprint!(
                    "\r\x1b[2K  {:<20} {:>9} {:>4} {:>11}  ETA {}",
                    label,
                    hum_short(b as f64),
                    pct,
                    rate,
                    eta
                );
                drawn = true;
            }
            Rec::Amount(n) => ans.amount = Some(n),
            Rec::Stored(n) => ans.stored = Some(n),
            Rec::Skip => {}
            Rec::Text(t) => {
                if drawn {
                    eprintln!();
                    drawn = false;
                }
                if capture {
                    ans.text.push(t);
                } else {
                    say(&t);
                }
            }
        }
    }
    if drawn {
        eprintln!();
    }
    let _ = feeder.join();
    let _ = child.wait();
    ans
}

/// Lines of a stream split at \r or \n (rsync redraws its progress with \r)
fn records(r: impl Read) -> impl Iterator<Item = String> {
    let mut r = BufReader::new(r);
    let mut buf = Vec::new();
    let mut done = false;
    std::iter::from_fn(move || loop {
        if done {
            return None;
        }
        let mut byte = [0u8; 1];
        match r.read(&mut byte) {
            Ok(1) if byte[0] == b'\n' || byte[0] == b'\r' => {
                if buf.is_empty() {
                    continue;
                }
                let s = String::from_utf8_lossy(&buf).into_owned();
                buf.clear();
                return Some(s);
            }
            Ok(1) => buf.push(byte[0]),
            _ => {
                done = true;
                if buf.is_empty() {
                    return None;
                }
                return Some(String::from_utf8_lossy(&std::mem::take(&mut buf)).into_owned());
            }
        }
    })
}

// ---------- session: disp-backup with the disk open ----------

struct Session {
    doms: Arc<Doms>,
}

impl Session {
    fn open(doms: Arc<Doms>) -> Result<Session, String> {
        warn("starting disp-backup");
        if !doms.systemctl("start", "disp-backup") {
            return Err("disp-backup does not start".into());
        }
        let s = Session { doms };
        if !wait_rpc("disp-backup") {
            return Err("disp-backup does not answer".into());
        }
        let mut open = "open";
        if let Some(disk) = std::env::var_os("NOX_BACKUP_TEST_DISK") {
            // Test disk: an image file as xvdz instead of the USB disk
            let disk = PathBuf::from(disk);
            if !disk.exists() {
                let ok = File::create(&disk).and_then(|f| f.set_len(4 << 30)).is_ok();
                if !ok {
                    return Err(format!("cannot create {}", disk.display()));
                }
            }
            let target = fs::canonicalize(&disk).unwrap_or(disk);
            let spec = format!("format=raw,vdev=xvdz,access=rw,target={}", target.display());
            if sys::run(
                "sudo",
                [
                    "/run/current-system/sw/bin/xl",
                    "block-attach",
                    "disp-backup-vm",
                    spec.as_str(),
                ],
            ) != 0
            {
                return Err("attach of the test disk failed".into());
            }
            open = "open-test";
        } else {
            // The backup disk by busid (it is not in the USB inventory)
            sys::run("vm-usb", ["list"]);
            let busid = prompt("busid of the backup disk: ").unwrap_or_default();
            if busid.is_empty()
                || sys::run("vm-usb", ["attach", busid.as_str(), "disp-backup"]) != 0
            {
                return Err(format!("attach of {busid} failed"));
            }
        }
        // Three tries; disp-backup answers 3 for a wrong passphrase
        for attempt in 1..=3 {
            let Some(pw) = prompt_secret("LUKS passphrase of the backup disk: ") else {
                return Err("no passphrase".into());
            };
            let input: Box<dyn Read + Send> = Box::new(io::Cursor::new(format!("{pw}\n")));
            let a = call(open, Some(input), "", false);
            match a.rc {
                Some(0) => return Ok(s),
                Some(3) if attempt < 3 => continue,
                _ => break,
            }
        }
        Err("could not open the backup disk".into())
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let closed = call("close", None, "", false).ok();
        self.doms.systemctl("stop", "disp-backup");
        if closed {
            warn("disk locked, disp-backup stopped");
        } else {
            // stopping disp-backup takes the disk away anyway, but unclean
            warn("disp-backup stopped, but the disk was not unmounted cleanly: check it (nox backup list) before relying on the last run");
        }
    }
}

// ---------- summary ----------

#[derive(Default)]
struct Summary {
    rows: Vec<(String, String, String, String)>,
}

impl Summary {
    fn note(&mut self, name: &str, stat: &str, amount: &str, time: &str) {
        self.rows
            .push((name.into(), stat.into(), amount.into(), time.into()));
    }
    /// The table, the run's duration, a notification; false if one failed
    fn print(&self, what: &str, gen: Option<&str>, log: &Path, t0: Instant) -> bool {
        let (mut ok, mut bad) = (0, 0);
        say("");
        say(&match gen {
            Some(g) => format!("{what}, generation {g}:"),
            None => format!("{what}:"),
        });
        for (name, stat, amount, time) in &self.rows {
            let short = stat.split(':').next().unwrap_or(stat);
            say(&format!("  {name:<28} {short:<7} {amount:>10} {time:>8}"));
            if stat == "OK" || stat.starts_with("SKIPPED") {
                ok += 1;
                if let Some((_, why)) = stat.split_once(": ") {
                    say(&format!("      {why}"));
                }
            } else {
                bad += 1;
                if let Some((_, why)) = stat.split_once(": ") {
                    say(&format!("      {why}"));
                }
            }
        }
        say(&format!("duration: {}", clock(t0.elapsed().as_secs())));
        say(&format!("log: {}", log.display()));
        sys::notify(
            &format!("{what} done"),
            &format!("{ok} OK, {bad} failed, {}", clock(t0.elapsed().as_secs())),
        );
        bad == 0
    }
}

// ---------- progress of a stream ----------

/// Two lines redrawn every second: this disk (done/size, rate, ETA) and the
/// whole run
struct Progress {
    bytes: Arc<AtomicU64>,
    stop: Arc<AtomicBool>,
    handle: Option<thread::JoinHandle<()>>,
}

#[derive(Clone)]
struct RunTotal {
    t0: Instant,
    total: u64,
}

impl Progress {
    fn start(label: String, size: u64, before: u64, run: RunTotal) -> Progress {
        let bytes = Arc::new(AtomicU64::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let (b2, s2) = (bytes.clone(), stop.clone());
        eprint!("\n\x1b[1A");
        let handle = thread::spawn(move || {
            let t_start = Instant::now();
            let (mut pb, mut pt, mut rate) = (0u64, Instant::now(), 0f64);
            loop {
                let finished = s2.load(Ordering::SeqCst);
                let mut b = b2.load(Ordering::SeqCst);
                let now = Instant::now();
                let dt = now.duration_since(pt).as_secs_f64();
                if dt > 0.5 {
                    let r = (b.saturating_sub(pb)) as f64 / dt;
                    rate = if rate > 0.0 { 0.7 * rate + 0.3 * r } else { r };
                    pb = b;
                    pt = now;
                }
                // Ended: done, even where the estimate was too big (the
                // builder key: 4 kB estimated, 101 bytes)
                if finished && b < size {
                    b = size;
                }
                let pct = (100 * b.min(size)).checked_div(size).unwrap_or(100);
                let eta = if b >= size {
                    "0:00".to_string()
                } else if rate > 0.0 {
                    clock(((size - b) as f64 / rate) as u64)
                } else {
                    "?".into()
                };
                let rate_s = if rate > 0.0 {
                    format!("{}/s", hum_short(rate))
                } else {
                    "-".into()
                };
                let l1 = format!(
                    "  {:<20} {:>9}/{:<9} {:>3}%  {:>11}  ETA {}",
                    label,
                    hum_short(b as f64),
                    hum_short(size as f64),
                    pct,
                    rate_s,
                    eta
                );
                let all = before + b;
                let el = run.t0.elapsed().as_secs_f64();
                let r = if el > 0.0 { all as f64 / el } else { 0.0 };
                let tpct = (100 * all.min(run.total))
                    .checked_div(run.total)
                    .unwrap_or(100);
                let teta = if r > 0.0 && run.total > all {
                    clock(((run.total - all) as f64 / r) as u64)
                } else if run.total <= all {
                    "0:00".into()
                } else {
                    "?".into()
                };
                let l2 = format!(
                    "  {:<20} {:>9}/{:<9} {:>3}%               ETA {}",
                    "total",
                    hum_short(all as f64),
                    hum_short(run.total as f64),
                    tpct,
                    teta
                );
                eprint!("\r\x1b[2K{l1}\n\x1b[2K{l2}\x1b[1A\r");
                let _ = io::stderr().flush();
                if finished {
                    eprint!("\n\n");
                    let _ = t_start;
                    return;
                }
                thread::sleep(Duration::from_millis(500));
            }
        });
        Progress {
            bytes,
            stop,
            handle: Some(handle),
        }
    }
    fn counter(&self) -> Arc<AtomicU64> {
        self.bytes.clone()
    }
}

impl Drop for Progress {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

/// Copies r → w and counts the bytes
fn copy_counting(mut r: impl Read, mut w: impl Write, n: &AtomicU64) -> io::Result<()> {
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let k = match r.read(&mut buf) {
            Ok(0) => return w.flush(),
            Ok(k) => k,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        w.write_all(&buf[..k])?;
        n.fetch_add(k as u64, Ordering::SeqCst);
    }
}

fn spawn(cmd: &mut Command) -> Result<Child, String> {
    cmd.spawn().map_err(|e| format!("cannot run {cmd:?}: {e}"))
}

fn waited_ok(c: &mut Child) -> bool {
    c.wait().is_ok_and(|s| s.success())
}

// ---------- targets ----------

fn target<'a>(data: &'a Data, name: &str) -> Option<&'a Target> {
    data.full.iter().find(|t| t.name == name)
}

/// "<target>[:<disk>,…]" → (target, disks); every name checked
pub fn expand(data: &Data, args: &[String]) -> Result<Vec<(String, Vec<String>)>, String> {
    let mut out = Vec::new();
    for a in args {
        let (name, disks) = match a.split_once(':') {
            Some((n, d)) => (n, Some(d)),
            None => (a.as_str(), None),
        };
        let Some(t) = target(data, name) else {
            return Err(format!(
                "unknown target: {name} (see nox backup disks --all)"
            ));
        };
        let disks: Vec<String> = match disks {
            None => t.disks.iter().map(|d| d.name.clone()).collect(),
            Some(list) => {
                let mut v = Vec::new();
                for d in list.split(',').filter(|d| !d.is_empty()) {
                    if !t.disks.iter().any(|x| x.name == d) {
                        return Err(format!(
                            "{name} has no disk {d} (see nox backup disks {name})"
                        ));
                    }
                    v.push(d.to_string());
                }
                v
            }
        };
        out.push((name.to_string(), disks));
    }
    Ok(out)
}

fn disk_path(t: &Target, d: &str) -> PathBuf {
    match t.kind {
        Kind::Dom0 => home().join(".ssh"),
        _ => PathBuf::from(
            t.disks
                .iter()
                .find(|x| x.name == d)
                .map(|x| x.path.as_str())
                .unwrap_or(""),
        ),
    }
}

/// Bytes of data (holes not counted)
fn used_of(t: &Target, d: &str) -> u64 {
    match t.kind {
        Kind::Builder => 4096,
        _ => {
            let p = disk_path(t, d);
            if !p.exists() {
                return 0;
            }
            sys::output("du", [OsArg::from("-sB1"), p.into_os_string()])
                .and_then(|o| o.split_whitespace().next().and_then(|n| n.parse().ok()))
                .unwrap_or(0)
        }
    }
}

type OsArg = std::ffi::OsString;

fn size_of(t: &Target, d: &str) -> u64 {
    match t.kind {
        Kind::Dom0 | Kind::Builder => used_of(t, d),
        _ => fs::metadata(disk_path(t, d)).map(|m| m.len()).unwrap_or(0),
    }
}

fn exists(t: &Target, d: &str) -> bool {
    match t.kind {
        Kind::Vm | Kind::Image => disk_path(t, d).exists(),
        _ => true,
    }
}

fn show_disks(data: &Data, names: &[String]) -> Result<(), String> {
    let mut total = 0;
    for n in names {
        let t =
            target(data, n).ok_or(format!("unknown target: {n} (see nox backup disks --all)"))?;
        let mut line = String::new();
        for d in &t.disks {
            if !exists(t, &d.name) {
                line += &format!("   {} (not created yet)", d.name);
                continue;
            }
            let used = used_of(t, &d.name);
            total += used;
            line += &format!(
                "   {} {} of {}",
                d.name,
                human(used),
                human(size_of(t, &d.name))
            );
        }
        println!("{:<20}{line}", t.name);
    }
    // What a full run of these targets reads (before compression)
    if names.len() > 1 {
        println!("{:<20}   {} used", "total", human(total));
    }
    Ok(())
}

// ---------- home ----------

fn home_names(data: &Data, sel: &Sel) -> Result<Vec<String>, String> {
    match sel {
        Sel::All => Ok(data.home_default.clone()),
        Sel::Names(v) => {
            for n in v {
                if !data.home.contains(n) {
                    return Err(format!(
                        "{n}: not a NixOS VM of this machine (home takes: {})",
                        data.home.join(" ")
                    ));
                }
            }
            Ok(v.clone())
        }
    }
}

fn home_run(doms: &Doms, vms: &[String], gen: &str, sum: &mut Summary) {
    for (i, vm) in vms.iter().enumerate() {
        if interrupted() {
            sum.note(vm, "SKIPPED: interrupted", "-", "-");
            continue;
        }
        say(&format!("[{}/{}] {vm}", i + 1, vms.len()));
        let t = Instant::now();
        let (up, started) = start_for(doms, vm);
        if !up {
            sum.note(vm, "FAILED: does not start or answer", "-", "-");
        } else {
            let a = call(&format!("home-backup {vm} {gen}"), None, vm, false);
            let time = clock(t.elapsed().as_secs());
            if a.ok() {
                let amount = a.amount.map(human).unwrap_or_else(|| "-".into());
                sum.note(vm, "OK", &amount, &time);
            } else {
                sum.note(vm, "FAILED: see the output above", "-", &time);
            }
        }
        if started {
            doms.systemctl("stop", vm);
        }
    }
}

// ---------- full ----------

/// File name of a disk on the backup disk
fn file_of(t: &Target, d: &str) -> String {
    match t.kind {
        Kind::Builder => "key.zst".into(),
        Kind::Dom0 => "ssh.tar.zst".into(),
        _ => format!("{d}.tar.zst"),
    }
}

/// The source stream of one disk (sparse tar; the builder's key over SSH)
fn source(t: &Target, d: &str) -> Command {
    let p = disk_path(t, d);
    match t.kind {
        Kind::Builder => {
            let mut c = Command::new("ssh");
            c.args(["builder", "sudo", "cat"]).arg(&p);
            c
        }
        Kind::Dom0 => {
            // the agent sockets in ~/.ssh/agent are skipped without a warning
            let mut c = Command::new("tar");
            c.arg("-C")
                .arg(home())
                .args(["-cS", "--warning=no-file-ignored", "-f", "-", ".ssh"]);
            c
        }
        _ => {
            // GNU tar finds the holes with SEEK_DATA: only data is read
            let mut c = Command::new("tar");
            c.arg("-C")
                .arg(p.parent().unwrap_or(Path::new("/")))
                .args(["-cS", "-f", "-"])
                .arg(p.file_name().unwrap_or_default());
            c
        }
    }
}

struct Put<'a> {
    gen: &'a str,
    level: u8,
    run: RunTotal,
}

/// One disk into disp-backup: source → count → zstd → nox-rpc
fn full_put_one(put: &Put, t: &Target, d: &str, used: u64, before: u64) -> Answer {
    let mut src = match spawn(source(t, d).stdout(Stdio::piped())) {
        Ok(c) => c,
        Err(e) => {
            warn(&e);
            return Answer::default();
        }
    };
    let mut z = match spawn(
        Command::new("zstd")
            .args(["-T0", "-q", &format!("-{}", put.level), "-c"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped()),
    ) {
        Ok(c) => c,
        Err(e) => {
            warn(&e);
            let _ = src.kill();
            return Answer::default();
        }
    };
    let progress = Progress::start(format!("{}:{d}", t.name), used, before, put.run.clone());
    let n = progress.counter();
    let src_out = src.stdout.take().unwrap();
    let z_in = z.stdin.take().unwrap();
    let pump = thread::spawn(move || copy_counting(src_out, z_in, &n));
    let z_out: ChildStdout = z.stdout.take().unwrap();
    let line = format!(
        "full-put {} {} {d} {} {used}",
        t.name,
        put.gen,
        file_of(t, d)
    );
    let mut a = call(&line, Some(Box::new(z_out)), "", false);
    let pumped = pump.join().is_ok_and(|r| r.is_ok());
    let src_ok = waited_ok(&mut src);
    let z_ok = waited_ok(&mut z);
    drop(progress);
    if !(pumped && src_ok && z_ok) {
        warn(&format!("{}:{d}: reading or compressing failed", t.name));
        a.rc = Some(1);
    }
    a
}

/// Running VMs/image domains among the targets get stopped for the copy:
/// one question for all; a running disposable (sys-net, …) is asked about
/// by itself, it loses its session; no: it is skipped
fn ask_stops(
    doms: &Doms,
    data: &Data,
    sel: &[(String, Vec<String>)],
    what: &str,
) -> Result<(Vec<String>, Vec<String>), String> {
    let mut up = Vec::new();
    let mut skip = Vec::new();
    for (name, _) in sel {
        let t = target(data, name).unwrap();
        if matches!(t.kind, Kind::Vm | Kind::Image) && doms.running(name) {
            if t.disposable {
                if ask(&format!(
                    "{name} is a running disposable: stopping it ends its session (windows, its empty home). Stop it for the {what}?"
                )) {
                    up.push(name.clone());
                } else {
                    skip.push(name.clone());
                }
            } else {
                up.push(name.clone());
            }
        }
    }
    let plain: Vec<&String> = up
        .iter()
        .filter(|n| !target(data, n).unwrap().disposable)
        .collect();
    if !plain.is_empty() {
        let list: Vec<&str> = plain.iter().map(|s| s.as_str()).collect();
        if !ask(&format!(
            "stops and restarts for the {what}: {}. Go on?",
            list.join(" ")
        )) {
            return Err("aborted".into());
        }
    }
    Ok((up, skip))
}

fn full_backup(
    doms: &Doms,
    data: &Data,
    sel: &[(String, Vec<String>)],
    gen: &str,
    level: u8,
    sum: &mut Summary,
) -> Result<(), String> {
    let (up, skip) = ask_stops(doms, data, sel, "copy")?;
    let mut total = 0;
    for (name, disks) in sel {
        if skip.contains(name) {
            continue;
        }
        let t = target(data, name).unwrap();
        total += disks.iter().map(|d| used_of(t, d)).sum::<u64>();
    }
    say(&format!(
        "full backup: {} to read (used blocks, stored compressed)",
        human(total)
    ));
    let put = Put {
        gen,
        level,
        run: RunTotal {
            t0: Instant::now(),
            total,
        },
    };
    let mut before = 0;
    for (i, (name, disks)) in sel.iter().enumerate() {
        let t = target(data, name).unwrap();
        if skip.contains(name) {
            sum.note(name, "SKIPPED: running disposable, not stopped", "-", "-");
            continue;
        }
        if interrupted() {
            sum.note(name, "SKIPPED: interrupted", "-", "-");
            continue;
        }
        say(&format!("[{}/{}] {name}", i + 1, sel.len()));
        let was_up = up.contains(name);
        if was_up && !doms.systemctl("stop", name) {
            sum.note(name, "FAILED: does not stop", "-", "-");
            continue;
        }
        // The builder's key is read over SSH: started for it if it is down
        let mut builder_started = false;
        if t.kind == Kind::Builder {
            let (ok, started) = start_for(doms, "builder");
            builder_started = started;
            if !ok {
                sum.note(name, "FAILED: does not start or answer", "-", "-");
                if started {
                    doms.systemctl("stop", "builder");
                }
                continue;
            }
        }
        let mut failed = false;
        let mut stored_any = false;
        for d in disks {
            let label = format!("{name}:{d}");
            if !exists(t, d) {
                sum.note(&label, "SKIPPED: not created yet", "-", "-");
                continue;
            }
            let tt = Instant::now();
            let used = used_of(t, d);
            let a = full_put_one(&put, t, d, used, before);
            let time = clock(tt.elapsed().as_secs());
            if a.ok() {
                // What lands on the disk (compressed), as `nox backup list` shows it
                let stored = a.stored.map(human).unwrap_or_else(|| "-".into());
                sum.note(&label, "OK", &stored, &time);
                stored_any = true;
            } else {
                sum.note(&label, "FAILED: see the output above", "-", &time);
                failed = true;
            }
            before += used;
            if interrupted() {
                failed = true;
                break;
            }
        }
        if failed {
            call(&format!("full-abort {name} {gen}"), None, "", false);
            say(&format!(
                "  {name}: nothing kept from this run (a disk failed)"
            ));
        } else if stored_any && !call(&format!("full-commit {name} {gen}"), None, "", false).ok() {
            sum.note(name, "FAILED: generation not committed", "-", "-");
        }
        // no disk existed yet: nothing to commit, the rows say SKIPPED
        if was_up && !doms.start_again(name) {
            sum.note(name, "FAILED: does not start again", "-", "-");
        }
        if builder_started {
            doms.systemctl("stop", "builder");
        }
    }
    Ok(())
}

/// One disk back from disp-backup. The stream goes into a staging copy and
/// through sha256sum at the same time (one read); the disk is replaced only
/// when the checksum matches
fn full_get_one(
    t: &Target,
    gen: &str,
    d: &str,
    used: u64,
    before: u64,
    run: &RunTotal,
) -> Result<(), String> {
    let p = disk_path(t, d);
    // Where it is unpacked first, and the command that unpacks it
    let (stage, mut sink, sudo): (PathBuf, Command, bool) = match t.kind {
        Kind::Builder => {
            // By hand: the builder's key is not overwritten from here
            let stage = home().join("nox-restore").join(gen);
            fs::create_dir_all(&stage).map_err(|e| e.to_string())?;
            let mut c = Command::new("sh");
            c.args(["-c", "umask 077; cat >\"$1\"", "sh"])
                .arg(stage.join("builder-signing-key"));
            (stage, c, false)
        }
        Kind::Dom0 => {
            // By hand: dom0's files are not overwritten from here
            let stage = home().join("nox-restore").join(gen).join("dom0");
            fs::create_dir_all(&stage).map_err(|e| e.to_string())?;
            let mut c = Command::new("tar");
            c.arg("-C").arg(&stage).args(["-xS", "-f", "-"]);
            (stage, c, false)
        }
        Kind::Vm | Kind::Image => {
            let dir = p.parent().unwrap_or(Path::new("/")).to_path_buf();
            let stage = dir.join(".nox-restore");
            // Missing folders (a new system, e.g. ~/vm-images/kali) belong
            // to the owner of the nearest existing parent, not to root
            if !dir.is_dir() {
                let mut parent = dir.clone();
                while !parent.is_dir() {
                    parent = parent.parent().unwrap_or(Path::new("/")).to_path_buf();
                }
                let (u, g) = owner(&parent);
                let ok = sys::run(
                    "sudo",
                    [
                        OsArg::from("-u"),
                        format!("#{u}").into(),
                        "-g".into(),
                        format!("#{g}").into(),
                        "mkdir".into(),
                        "-p".into(),
                        dir.clone().into_os_string(),
                    ],
                ) == 0;
                if !ok {
                    return Err(format!("cannot create {}", dir.display()));
                }
            }
            if sys::run(
                "sudo",
                [
                    OsArg::from("mkdir"),
                    "-p".into(),
                    stage.clone().into_os_string(),
                ],
            ) != 0
            {
                return Err(format!("cannot create {}", stage.display()));
            }
            let mut c = Command::new("sudo");
            c.arg("tar").arg("-C").arg(&stage).args(["-xS", "-f", "-"]);
            (stage, c, true)
        }
    };
    let cleanup = |stage: &Path| match t.kind {
        Kind::Builder => {
            let _ = fs::remove_file(stage.join("builder-signing-key"));
        }
        Kind::Dom0 => {
            let _ = fs::remove_dir_all(stage);
        }
        _ => {
            sys::run(
                "sudo",
                [
                    OsArg::from("rm"),
                    "-rf".into(),
                    stage.as_os_str().to_owned(),
                ],
            );
        }
    };
    let res = fetch(t, gen, d, used, before, run, &mut sink);
    if let Err(e) = res {
        cleanup(&stage);
        return Err(e);
    }
    match t.kind {
        Kind::Builder => {
            let key = stage.join("builder-signing-key");
            say(&format!(
                "  the builder's key is in {}; to put it back:",
                key.display()
            ));
            say("    nox start builder");
            say(&format!(
                "    nox ssh builder sudo tee {} <{} >/dev/null",
                p.display(),
                key.display()
            ));
        }
        Kind::Dom0 => {
            say(&format!(
                "  dom0's files are in {} (.ssh); copy back what you need, e.g.",
                stage.display()
            ));
            say(&format!("    cp -a {}/.ssh/. ~/.ssh/", stage.display()));
        }
        Kind::Vm | Kind::Image => {
            let base = p.file_name().unwrap_or_default();
            let staged = stage.join(base);
            let _ = sudo;
            if !sudo_test_e(&staged) {
                cleanup(&stage);
                return Err(format!("{d} missing in the backup"));
            }
            // the owner of the old disk, if there is one (a fresh system has none)
            if p.exists() {
                sys::run(
                    "sudo",
                    [
                        OsArg::from("chown"),
                        format!("--reference={}", p.display()).into(),
                        staged.clone().into_os_string(),
                    ],
                );
            }
            if sys::run(
                "sudo",
                [
                    OsArg::from("mv"),
                    "-f".into(),
                    staged.into_os_string(),
                    p.clone().into_os_string(),
                ],
            ) != 0
            {
                cleanup(&stage);
                return Err(format!("cannot move the restored {d} into place"));
            }
            cleanup(&stage);
        }
    }
    Ok(())
}

/// The staging dir is root's: test -e with sudo
fn sudo_test_e(p: &Path) -> bool {
    Command::new("sudo")
        .arg("test")
        .arg("-e")
        .arg(p)
        .status()
        .is_ok_and(|s| s.success())
}

fn owner(p: &Path) -> (u32, u32) {
    use std::os::unix::fs::MetadataExt;
    fs::metadata(p)
        .map(|m| (m.uid(), m.gid()))
        .unwrap_or((0, 0))
}

/// Streams a disk from disp-backup into `sink`'s stdin: first line `ok
/// <sha256>`, then the compressed file. It goes to sha256sum and to zstd -d
/// at once; the uncompressed bytes into `sink` with progress
fn fetch(
    t: &Target,
    gen: &str,
    d: &str,
    used: u64,
    before: u64,
    run: &RunTotal,
    sink: &mut Command,
) -> Result<(), String> {
    let mut rpc = spawn(rpc_backup().stdin(Stdio::piped()).stdout(Stdio::piped()))?;
    {
        let mut i = rpc.stdin.take().unwrap();
        let _ = writeln!(i, "full-get {} {gen} {d}", t.name);
    }
    let mut out = BufReader::new(rpc.stdout.take().unwrap());
    let mut first = String::new();
    let _ = out.read_line(&mut first);
    let first = first.trim_end();
    let Some(expect) = first.strip_prefix("ok ").map(str::to_string) else {
        let _ = io::copy(&mut out, &mut io::sink());
        let _ = rpc.wait();
        return Err(if first.is_empty() {
            "no answer from disp-backup".into()
        } else {
            first.to_string()
        });
    };
    let mut sha = spawn(
        Command::new("sha256sum")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped()),
    )?;
    let mut z = spawn(
        Command::new("zstd")
            .args(["-d", "-q", "-c"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped()),
    )?;
    let mut sk = spawn(sink.stdin(Stdio::piped()))?;
    let progress = Progress::start(format!("{}:{d}", t.name), used, before, run.clone());
    let n = progress.counter();
    // compressed: to sha256sum and zstd
    let mut sha_in = sha.stdin.take().unwrap();
    let mut z_in = z.stdin.take().unwrap();
    let tee = thread::spawn(move || -> io::Result<()> {
        let mut buf = vec![0u8; 1 << 20];
        loop {
            let k = match out.read(&mut buf) {
                Ok(0) => return Ok(()),
                Ok(k) => k,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            };
            sha_in.write_all(&buf[..k])?;
            z_in.write_all(&buf[..k])?;
        }
    });
    // uncompressed: counted into the sink
    let z_out = z.stdout.take().unwrap();
    let sk_in = sk.stdin.take().unwrap();
    let pumped = copy_counting(z_out, sk_in, &n).is_ok();
    let teed = tee.join().is_ok_and(|r| r.is_ok());
    let z_ok = waited_ok(&mut z);
    let sk_ok = waited_ok(&mut sk);
    let _ = rpc.wait();
    let got = sha
        .wait_with_output()
        .ok()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .split_whitespace()
                .next()
                .unwrap_or("")
                .to_string()
        })
        .unwrap_or_default();
    drop(progress);
    if !(pumped && teed && z_ok && sk_ok) {
        return Err(format!("{}:{d}: the stream broke off", t.name));
    }
    if got != expect {
        return Err(format!(
            "checksum of {}/{gen}/{d} wrong, not restored",
            t.name
        ));
    }
    Ok(())
}

fn full_restore(
    doms: &Doms,
    data: &Data,
    sel: &[(String, Vec<String>)],
    from: &str,
    sum: &mut Summary,
) -> Result<(), String> {
    // per target its generation, per disk its used bytes
    let mut gens: HashMap<String, String> = HashMap::new();
    let mut used: HashMap<String, u64> = HashMap::new();
    let mut list = Vec::new();
    let mut total = 0;
    for (name, disks) in sel {
        let a = call(&format!("full-info {name} {from}"), None, "", true);
        if !a.ok() {
            let what = if from == "latest" { "at all" } else { from };
            sum.note(
                name,
                &format!("FAILED: no full generation {what} of {name}"),
                "-",
                "-",
            );
            continue;
        }
        let Some(g) = a
            .text
            .iter()
            .find_map(|l| l.strip_prefix("gen ").map(str::to_string))
        else {
            sum.note(name, "FAILED: no answer from disp-backup", "-", "-");
            continue;
        };
        for d in disks {
            let u = a.text.iter().find_map(|l| {
                let w: Vec<&str> = l.split_whitespace().collect();
                (w.len() >= 4 && w[0] == "disk" && w[1] == d).then(|| w[3].parse().unwrap_or(0))
            });
            match u {
                Some(u) => {
                    used.insert(format!("{name}:{d}"), u);
                    total += u;
                    list.push(format!("{name}:{d}"));
                }
                None => sum.note(
                    &format!("{name}:{d}"),
                    &format!("FAILED: not in generation {g}"),
                    "-",
                    "-",
                ),
            }
        }
        gens.insert(name.clone(), g);
    }
    if list.is_empty() {
        return Ok(());
    }
    for (name, _) in sel {
        if let Some(g) = gens.get(name) {
            say(&format!("  {name}: generation {g}"));
        }
    }
    let restorable: Vec<(String, Vec<String>)> = sel
        .iter()
        .filter(|(n, _)| gens.contains_key(n))
        .cloned()
        .collect();
    if !ask(&format!(
        "replaces with the backup: {}. Sure?",
        list.join(" ")
    )) {
        return Err("aborted".into());
    }
    let (up, skip) = ask_stops(doms, data, &restorable, "restore")?;
    let run = RunTotal {
        t0: Instant::now(),
        total,
    };
    let mut before = 0;
    for (i, (name, disks)) in restorable.iter().enumerate() {
        let t = target(data, name).unwrap();
        let g = &gens[name];
        if skip.contains(name) {
            sum.note(name, "SKIPPED: running disposable, not stopped", "-", "-");
            continue;
        }
        if interrupted() {
            sum.note(name, "SKIPPED: interrupted", "-", "-");
            continue;
        }
        say(&format!("[{}] {name} (generation {g})", i + 1));
        let was_up = up.contains(name);
        if was_up && !doms.systemctl("stop", name) {
            sum.note(name, "FAILED: does not stop", "-", "-");
            continue;
        }
        for d in disks {
            let key = format!("{name}:{d}");
            let Some(&u) = used.get(&key) else { continue };
            let tt = Instant::now();
            match full_get_one(t, g, d, u, before, &run) {
                Ok(()) => sum.note(&key, "OK", &human(u), &clock(tt.elapsed().as_secs())),
                Err(e) => {
                    warn(&e);
                    sum.note(
                        &key,
                        "FAILED: see the output above; the old disk stays",
                        "-",
                        &clock(tt.elapsed().as_secs()),
                    );
                }
            }
            before += u;
            if interrupted() {
                break;
            }
        }
        if was_up && !doms.start_again(name) {
            sum.note(name, "FAILED: does not start again", "-", "-");
        }
    }
    Ok(())
}

// ---------- main ----------

fn generation_now() -> String {
    sys::output("date", ["+%Y-%m-%d_%H%M%S"])
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

fn fail(msg: &str) -> ExitCode {
    warn(msg);
    ExitCode::from(1)
}

pub fn main(req: Req) -> ExitCode {
    // a stream that breaks off must not kill nox before the disk is locked
    sys::ignore_sigpipe();
    let data: Data = match registry::section("backup") {
        Ok(d) => d,
        Err(e) => return fail(&format!("{e:#}")),
    };
    let doms = match registry::domains() {
        Ok(d) => Arc::new(Doms(d)),
        Err(e) => return fail(&format!("{e:#}")),
    };
    let gen = generation_now();
    let all_full: Vec<String> = data.full.iter().map(|t| t.name.clone()).collect();
    let pick_full = |sel: &Sel| match sel {
        Sel::All => expand(&data, &all_full),
        Sel::Names(v) => expand(&data, v),
    };
    match req {
        Req::Disks(sel) => {
            let names = match &sel {
                Sel::All => all_full.clone(),
                Sel::Names(v) => v.clone(),
            };
            match show_disks(&data, &names) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(&e),
            }
        }
        Req::List => run_session(&doms, &format!("{gen}-list"), |_, _| {
            call("list", None, "", false).ok()
        }),
        Req::Prune {
            kind,
            keep,
            dry_run,
            targets,
        } => {
            if keep == 0 && !dry_run {
                let whom = if targets.is_empty() {
                    "every VM".to_string()
                } else {
                    targets.join(" ")
                };
                if !ask(&format!(
                    "--keep 0 deletes all {kind} generations of {whom}. Sure?"
                )) {
                    return fail("aborted");
                }
            }
            let dry = if dry_run { "-n" } else { "-" };
            let line = format!("prune {kind} {keep} {dry} {}", targets.join(" "));
            run_session(&doms, &format!("{gen}-prune"), |_, _| {
                call(line.trim_end(), None, "", false).ok()
            })
        }
        Req::Home(sel) => {
            let vms = match home_names(&data, &sel) {
                Ok(v) => v,
                Err(e) => return fail(&e),
            };
            let st = run_session(&doms, &gen, |log, t0| {
                let mut sum = Summary::default();
                home_run(&doms, &vms, &gen, &mut sum);
                sum.print("home backup", Some(&gen), log, t0)
            });
            if st == ExitCode::SUCCESS {
                let _ = fs::write(
                    state_dir().join("last"),
                    format!(
                        "{}\n",
                        sys::output("date", ["+%s"]).unwrap_or_default().trim()
                    ),
                );
            }
            st
        }
        Req::Full { sel, level } => {
            let sel = match pick_full(&sel) {
                Ok(s) => s,
                Err(e) => return fail(&e),
            };
            run_session(&doms, &gen, |log, t0| {
                let mut sum = Summary::default();
                if let Err(e) = full_backup(&doms, &data, &sel, &gen, level, &mut sum) {
                    warn(&e);
                    return false;
                }
                sum.print("full backup", Some(&gen), log, t0)
            })
        }
        Req::Restore { full, from, sel } => {
            let from = from.unwrap_or_else(|| "latest".into());
            if full {
                let sel = match pick_full(&sel) {
                    Ok(s) => s,
                    Err(e) => return fail(&e),
                };
                run_session(&doms, &format!("{gen}-restore-full"), |log, t0| {
                    let mut sum = Summary::default();
                    if let Err(e) = full_restore(&doms, &data, &sel, &from, &mut sum) {
                        warn(&e);
                        return false;
                    }
                    sum.print("full restore", None, log, t0)
                })
            } else {
                let vms = match home_names(&data, &sel) {
                    Ok(v) => v,
                    Err(e) => return fail(&e),
                };
                run_session(&doms, &format!("{gen}-restore"), |log, t0| {
                    let mut sum = Summary::default();
                    home_run_restore(&doms, &vms, &from, &mut sum);
                    sum.print("home restore", None, log, t0)
                })
            }
        }
    }
}

fn home_run_restore(doms: &Doms, vms: &[String], from: &str, sum: &mut Summary) {
    for (i, vm) in vms.iter().enumerate() {
        if interrupted() {
            sum.note(vm, "SKIPPED: interrupted", "-", "-");
            continue;
        }
        say(&format!("[{}/{}] {vm}", i + 1, vms.len()));
        let t = Instant::now();
        let (up, started) = start_for(doms, vm);
        if !up {
            sum.note(vm, "FAILED: does not start or answer", "-", "-");
        } else if call(&format!("home-restore {vm} {from}"), None, vm, false).ok() {
            sum.note(vm, "OK", "-", &clock(t.elapsed().as_secs()));
        } else {
            sum.note(
                vm,
                "FAILED: see the output above",
                "-",
                &clock(t.elapsed().as_secs()),
            );
        }
        if started {
            doms.systemctl("stop", vm);
        }
    }
}

/// Log, sudo, Ctrl+C, the session around `work`; exit 1 if it fails
fn run_session(
    doms: &Arc<Doms>,
    log_name: &str,
    work: impl FnOnce(&Path, Instant) -> bool,
) -> ExitCode {
    let log = start_log(log_name);
    // the duration in the summary: the whole run, opening the disk included
    let t0 = Instant::now();
    if let Err(e) = sudo_keepalive() {
        return fail(&e);
    }
    catch_sigint();
    let ok = match Session::open(doms.clone()) {
        Ok(_session) => work(&log, t0),
        Err(e) => {
            // the session's Drop locks the disk; a failed open still stops
            // disp-backup
            warn(&e);
            doms.systemctl("stop", "disp-backup");
            false
        }
    };
    if ok {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data() -> Data {
        serde_json::from_str(
            r#"{"home":["nvim","chat","vanilla"],"homeDefault":["nvim","chat","vanilla"],
              "full":[
                {"name":"coding","kind":"vm","disks":[{"name":"home","path":"/var/lib/microvms/coding/home.img"},{"name":"var","path":"/var/lib/microvms/coding/var.img"}]},
                {"name":"sys-net","kind":"vm","disposable":true,"disks":[{"name":"networkmanager","path":"/var/lib/microvms/sys-net/networkmanager.img"}]},
                {"name":"kali","kind":"image","disks":[{"name":"image","path":"/home/nx/vm-images/kali/kali.qcow2"}]},
                {"name":"builder","kind":"builder","disks":[{"name":"key","path":"/var/lib/builder/signing-key"}]},
                {"name":"dom0","kind":"dom0","disks":[{"name":"ssh"}]}
              ]}"#,
        )
        .unwrap()
    }

    #[test]
    fn numbers() {
        assert_eq!(human(0), "0.0 B");
        assert_eq!(human(114), "114.0 B");
        assert_eq!(human(1_234_567), "1.2 MB");
        assert_eq!(human(192_500), "192.5 kB");
        assert_eq!(clock(75), "1:15");
        assert_eq!(clock(3600), "60:00");
    }

    #[test]
    fn targets_expand() {
        let d = data();
        let e = expand(&d, &["coding:var".into(), "dom0".into()]).unwrap();
        assert_eq!(e[0], ("coding".into(), vec!["var".into()]));
        assert_eq!(e[1], ("dom0".into(), vec!["ssh".into()]));
        assert_eq!(
            expand(&d, &["coding".into()]).unwrap()[0].1,
            ["home", "var"]
        );
        assert!(expand(&d, &["nope".into()])
            .unwrap_err()
            .contains("unknown target"));
        assert!(expand(&d, &["coding:etc".into()])
            .unwrap_err()
            .contains("no disk etc"));
        assert_eq!(file_of(target(&d, "builder").unwrap(), "key"), "key.zst");
        assert_eq!(file_of(target(&d, "dom0").unwrap(), "ssh"), "ssh.tar.zst");
        assert_eq!(file_of(target(&d, "coding").unwrap(), "var"), "var.tar.zst");
        assert!(target(&d, "sys-net").unwrap().disposable);
    }

    #[test]
    fn home_selection() {
        let d = data();
        assert_eq!(
            home_names(&d, &Sel::All).unwrap(),
            ["nvim", "chat", "vanilla"]
        );
        assert!(home_names(&d, &Sel::Names(vec!["steam".into()])).is_err());
        assert_eq!(
            home_names(&d, &Sel::Names(vec!["chat".into()])).unwrap(),
            ["chat"]
        );
    }

    #[test]
    fn service_records() {
        assert_eq!(parse_rec("exit 0"), Rec::Exit(0));
        assert_eq!(parse_rec("exit 23"), Rec::Exit(23));
        assert_eq!(parse_rec("stored-bytes 114"), Rec::Stored(114));
        assert_eq!(
            parse_rec("Total transferred file size: 1,234,567 bytes"),
            Rec::Amount(1_234_567)
        );
        assert_eq!(
            parse_rec("    5,000,000  42%   12.34MB/s    0:00:03"),
            Rec::Progress(
                5_000_000,
                "42%".into(),
                "12.34MB/s".into(),
                "0:00:03".into()
            )
        );
        assert_eq!(parse_rec("Number of files: 3"), Rec::Skip);
        assert_eq!(parse_rec("sent 1 bytes  received 2 bytes"), Rec::Skip);
        assert_eq!(
            parse_rec("opened /dev/xvdz"),
            Rec::Text("opened /dev/xvdz".into())
        );
        assert_eq!(parse_rec("exit x"), Rec::Text("exit x".into()));
    }

    #[test]
    fn split_records() {
        let r: Vec<String> = records("a\r b\r\nc\n\nd".as_bytes()).collect();
        assert_eq!(r, ["a", " b", "c", "d"]);
    }
}

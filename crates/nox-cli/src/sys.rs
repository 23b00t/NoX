//! Processes nox runs: systemd, notifications, exec of the tools that stay
//! programs (vm-gui, ssh, sudo).

use std::ffi::{OsStr, OsString};
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode, Stdio};

extern "C" {
    fn signal(signum: i32, handler: usize) -> usize;
}

/// SIGPIPE back to its default: `nox list | head` ends nox quietly like any
/// Unix tool, instead of a panic in println! (Rust ignores SIGPIPE)
pub fn default_sigpipe() {
    const SIGPIPE: i32 = 13;
    const SIG_DFL: usize = 0;
    // SAFETY: called once at the start of main, before any thread exists
    unsafe {
        signal(SIGPIPE, SIG_DFL);
    }
}

/// SIGPIPE ignored again (Rust's own default): for runs that write into
/// pipes of other processes (nox backup), a reader that ends early is an
/// error to report, not the end of nox
pub fn ignore_sigpipe() {
    const SIGPIPE: i32 = 13;
    const SIG_IGN: usize = 1;
    // SAFETY: called before the threads of the run start
    unsafe {
        signal(SIGPIPE, SIG_IGN);
    }
}

/// Replaces this process with `prog args…`; returns only if that fails.
pub fn exec<I, S>(prog: &str, args: I) -> ExitCode
where
    I: IntoIterator<Item = S>,
    S: Into<OsString>,
{
    let args: Vec<OsString> = args.into_iter().map(Into::into).collect();
    let err = Command::new(prog).args(&args).exec();
    eprintln!("nox: cannot run {prog}: {err}");
    ExitCode::from(127)
}

/// Runs `prog args…` with inherited output; its exit code (1 if it was
/// killed, 127 if it could not start)
pub fn run<I, S>(prog: &str, args: I) -> i32
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    match Command::new(prog).args(args).status() {
        Ok(s) => s.code().unwrap_or(1),
        Err(e) => {
            eprintln!("nox: cannot run {prog}: {e}");
            127
        }
    }
}

/// Stdout of `prog args…` (stderr dropped); None if it could not start
pub fn output<I, S>(prog: &str, args: I) -> Option<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    Command::new(prog)
        .args(args)
        .stderr(Stdio::null())
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
}

pub fn is_active(service: &str) -> bool {
    Command::new("systemctl")
        .args(["is-active", "--quiet", service])
        .status()
        .is_ok_and(|s| s.success())
}

/// A start/stop job of the unit is queued (e.g. autostart VMs at boot)
pub fn has_job(service: &str) -> bool {
    output("systemctl", ["list-jobs", "--no-legend", service]).is_some_and(|o| !o.trim().is_empty())
}

/// Desktop notification; failing is fine (no session, no daemon)
pub fn notify(summary: &str, body: &str) {
    let _ = Command::new("notify-send")
        .args([summary, body])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// `prog` is on PATH (bash `command -v`)
pub fn on_path(prog: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|p| {
        std::env::split_paths(&p).any(|d| {
            let f = d.join(prog);
            f.metadata().is_ok_and(|m| {
                m.is_file()
                    && std::os::unix::fs::PermissionsExt::mode(&m.permissions()) & 0o111 != 0
            })
        })
    })
}

/// Quotes one word for `sh -c` (bash's `printf %q`, in single quotes)
pub fn shell_quote(s: &str) -> String {
    let safe = |c: char| c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c);
    if !s.is_empty() && s.chars().all(safe) {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', r"'\''"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoting() {
        assert_eq!(shell_quote("htop"), "htop");
        assert_eq!(shell_quote("--max=3"), "--max=3");
        assert_eq!(shell_quote(""), "''");
        assert_eq!(shell_quote("a b"), "'a b'");
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
        assert_eq!(shell_quote("$(rm -rf ~)"), "'$(rm -rf ~)'");
        assert_eq!(shell_quote("a\nb"), "'a\nb'");
    }

    #[test]
    fn path_lookup() {
        assert!(on_path("sh"));
        assert!(!on_path("nox-surely-not-there"));
    }
}

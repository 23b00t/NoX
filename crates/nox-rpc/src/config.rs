//! nox-rpcd config, one rule per line (`#` starts a comment):
//!
//! ```text
//! source <domain> <socket>     # calls arriving here come from <domain>
//! target <domain> <socket>     # <domain>'s rpc-in socket
//! policy <service> <source|*> <target|*> allow|ask|warn|deny
//! ask-command <path>           # run for `ask`/`warn`: args service source
//!                              # target ask|warn [details…], exit 0 = allow
//! dom0-socket <path>           # dom0's own calls through the broker
//! copy-limit <bytes>           # most bytes one `copy` may carry
//! ```
//!
//! The first matching policy line decides; no match = deny. Calls to a
//! domain without a `target` line or to the caller itself are denied. The name
//! `dom0` is reserved for dom0's own calls and refused as a domain.
//!
//! `warn` is `ask` with a stronger question (the user types the target's
//! name). Calls dom0 makes itself count as the user's consent: `ask` becomes
//! `allow` for them, `warn` and `deny` stay.

use crate::{valid_name, DOM0};
use std::path::PathBuf;

/// Default for `copy-limit`: 10 GB
pub const COPY_LIMIT: u64 = 10_000_000_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Allow,
    Ask,
    Warn,
    Deny,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Policy {
    pub service: String,
    pub source: Option<String>,
    pub target: Option<String>,
    pub action: Action,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Config {
    pub sources: Vec<(String, PathBuf)>,
    pub targets: Vec<(String, PathBuf)>,
    pub policy: Vec<Policy>,
    pub ask_command: Option<PathBuf>,
    pub dom0_socket: Option<PathBuf>,
    pub copy_limit: u64,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            sources: Vec::new(),
            targets: Vec::new(),
            policy: Vec::new(),
            ask_command: None,
            dom0_socket: None,
            copy_limit: COPY_LIMIT,
        }
    }
}

impl Config {
    pub fn target_socket(&self, domain: &str) -> Option<&PathBuf> {
        self.targets
            .iter()
            .find(|(d, _)| d == domain)
            .map(|(_, p)| p)
    }

    pub fn decide(&self, service: &str, source: &str, target: &str) -> Action {
        if source == target || self.target_socket(target).is_none() {
            return Action::Deny;
        }
        let matches = |pat: &Option<String>, v: &str| pat.as_deref().is_none_or(|p| p == v);
        self.policy
            .iter()
            .find(|p| {
                p.service == service && matches(&p.source, source) && matches(&p.target, target)
            })
            .map_or(Action::Deny, |p| p.action)
    }

    /// A call dom0 makes itself, for `source` (a guest it acts for, e.g.
    /// `nox copy chat coding …`) or for itself (`None`: only rules with any
    /// source apply). dom0 asking is the user asking: `ask` becomes `allow`.
    pub fn decide_dom0(&self, service: &str, source: Option<&str>, target: &str) -> Action {
        let action = match source {
            Some(s) => self.decide(service, s, target),
            None if self.target_socket(target).is_none() => Action::Deny,
            None => self
                .policy
                .iter()
                .find(|p| {
                    p.service == service
                        && p.source.is_none()
                        && p.target.as_deref().is_none_or(|t| t == target)
                })
                .map_or(Action::Deny, |p| p.action),
        };
        match action {
            Action::Ask => Action::Allow,
            a => a,
        }
    }
}

fn domain_or_any(s: &str) -> Result<Option<String>, ()> {
    if s == "*" {
        Ok(None)
    } else if valid_name(s) && s != DOM0 {
        Ok(Some(s.to_string()))
    } else {
        Err(())
    }
}

pub fn parse(text: &str) -> Result<Config, String> {
    let mut cfg = Config::default();
    for (no, line) in text.lines().enumerate() {
        let err = |msg: &str| format!("line {}: {msg}", no + 1);
        let line = line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        let w: Vec<&str> = line.split_whitespace().collect();
        match w.as_slice() {
            ["source" | "target", domain, path] => {
                if !valid_name(domain) || *domain == DOM0 {
                    return Err(err("domain: 1-32 of [a-z0-9-], not dom0"));
                }
                if !path.starts_with('/') {
                    return Err(err("socket path must be absolute"));
                }
                let list = if w[0] == "source" {
                    &mut cfg.sources
                } else {
                    &mut cfg.targets
                };
                if list.iter().any(|(d, _)| d == domain) {
                    return Err(err("domain listed twice"));
                }
                list.push((domain.to_string(), path.into()));
            }
            ["policy", service, source, target, action] => {
                if !valid_name(service) {
                    return Err(err("service: 1-32 of [a-z0-9-]"));
                }
                let action = match *action {
                    "allow" => Action::Allow,
                    "ask" => Action::Ask,
                    "warn" => Action::Warn,
                    "deny" => Action::Deny,
                    _ => return Err(err("action: allow|ask|warn|deny")),
                };
                cfg.policy.push(Policy {
                    service: service.to_string(),
                    source: domain_or_any(source).map_err(|_| err("source: domain or *"))?,
                    target: domain_or_any(target).map_err(|_| err("target: domain or *"))?,
                    action,
                });
            }
            ["ask-command", path] if path.starts_with('/') => cfg.ask_command = Some(path.into()),
            ["dom0-socket", path] if path.starts_with('/') => cfg.dom0_socket = Some(path.into()),
            ["copy-limit", bytes] => {
                cfg.copy_limit = bytes.parse().map_err(|_| err("copy-limit: bytes"))?
            }
            _ => {
                return Err(err(
                    "expected source|target|policy|ask-command|dom0-socket|copy-limit",
                ))
            }
        }
    }
    Ok(cfg)
}

#[cfg(test)]
mod tests {
    use super::*;

    const CFG: &str = "
        source coding /run/nox-rpcd/coding.sock
        source chat /run/nox-rpcd/chat.sock
        target coding /run/nox-relay/coding-rpc-in.sock
        target chat /run/nox-relay/chat-rpc-in.sock
        target vault /run/nox-relay/vault-rpc-in.sock
        policy copy * vault deny   # vault only by its own rule
        policy copy coding chat allow
        policy copy * * ask
        ask-command /bin/ask
    ";

    #[test]
    fn decides_first_match() {
        let c = parse(CFG).unwrap();
        assert_eq!(c.decide("copy", "coding", "chat"), Action::Allow);
        assert_eq!(c.decide("copy", "chat", "coding"), Action::Ask);
        assert_eq!(c.decide("copy", "chat", "vault"), Action::Deny);
        assert_eq!(c.decide("print", "chat", "coding"), Action::Deny);
        assert_eq!(c.decide("copy", "coding", "coding"), Action::Deny);
        assert_eq!(c.decide("copy", "coding", "nvim"), Action::Deny);
        assert_eq!(
            c.ask_command.as_deref(),
            Some(std::path::Path::new("/bin/ask"))
        );
    }

    #[test]
    fn dom0_calls() {
        let c = parse(
            "
            target coding /c
            target vault /v
            target sys-net /n
            policy copy sys-net * deny
            policy copy * sys-net deny
            policy copy * vault warn
            policy copy * * ask
            dom0-socket /run/nox-rpcd/dom0.sock
            copy-limit 1000
        ",
        )
        .unwrap();
        // dom0 itself: ask -> allow, warn and deny stay
        assert_eq!(c.decide_dom0("copy", None, "coding"), Action::Allow);
        assert_eq!(c.decide_dom0("copy", None, "vault"), Action::Warn);
        assert_eq!(c.decide_dom0("copy", None, "sys-net"), Action::Deny);
        assert_eq!(c.decide_dom0("copy", None, "dom0"), Action::Deny);
        // for a guest: that guest's rules
        assert_eq!(
            c.decide_dom0("copy", Some("sys-net"), "coding"),
            Action::Deny
        );
        assert_eq!(c.decide_dom0("copy", Some("coding"), "vault"), Action::Warn);
        assert_eq!(
            c.decide_dom0("copy", Some("vault"), "coding"),
            Action::Allow
        );
        // the guest itself still gets asked
        assert_eq!(c.decide("copy", "vault", "coding"), Action::Ask);
        assert_eq!(c.copy_limit, 1000);
        assert_eq!(
            c.dom0_socket.as_deref(),
            Some(std::path::Path::new("/run/nox-rpcd/dom0.sock"))
        );
        assert_eq!(parse("").unwrap().copy_limit, COPY_LIMIT);
    }

    #[test]
    fn rejects_mistakes() {
        assert!(parse("copy-limit lots").is_err());
        assert!(parse("dom0-socket relative").is_err());
        assert!(parse("source Bad /x").is_err());
        assert!(parse("source a relative").is_err());
        assert!(parse("source a /x\nsource a /y").is_err());
        assert!(parse("source dom0 /x").is_err());
        assert!(parse("target dom0 /x").is_err());
        assert!(parse("policy copy dom0 * allow").is_err());
        assert!(parse("policy copy * * maybe").is_err());
        assert!(parse("policy copy ../x * allow").is_err());
        assert!(parse("ask-command relative").is_err());
        assert!(parse("frobnicate").is_err());
    }
}

//! Config file, one rule per line (`#` starts a comment):
//!
//! ```text
//! listen <service> <socket-path> [mode=0600] [owner=<uid>:<gid>]
//! serve  <service> <socket-path>
//! ```
//!
//! `listen`: create a local socket; each connection opens `<service>` at the
//! peer. `serve`: the peer may open `<service>`; it is connected to the local
//! socket. A peer can only reach services listed under `serve`.

use crate::proto::valid_service;
use std::path::PathBuf;

#[derive(Debug, PartialEq, Eq)]
pub struct Listen {
    pub service: String,
    pub path: PathBuf,
    pub mode: u32,
    pub owner: Option<(u32, u32)>,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Serve {
    pub service: String,
    pub path: PathBuf,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Config {
    pub listen: Vec<Listen>,
    pub serve: Vec<Serve>,
}

pub fn parse(text: &str) -> Result<Config, String> {
    let mut cfg = Config::default();
    for (no, line) in text.lines().enumerate() {
        let err = |msg: &str| format!("line {}: {msg}", no + 1);
        let line = line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        let words: Vec<&str> = line.split_whitespace().collect();
        let (kind, service, path) = match words.as_slice() {
            [k, s, p, ..] => (*k, *s, *p),
            _ => return Err(err("expected: listen|serve <service> <path> ...")),
        };
        if !valid_service(service.as_bytes()) {
            return Err(err("service: 1-32 of [a-z0-9-]"));
        }
        if !path.starts_with('/') {
            return Err(err("socket path must be absolute"));
        }
        let duplicate = match kind {
            "listen" => cfg.listen.iter().any(|l| l.service == service),
            _ => cfg.serve.iter().any(|s| s.service == service),
        };
        if duplicate {
            return Err(err("service listed twice"));
        }
        match kind {
            "listen" => {
                let mut rule = Listen {
                    service: service.into(),
                    path: path.into(),
                    mode: 0o600,
                    owner: None,
                };
                for opt in &words[3..] {
                    if let Some(m) = opt.strip_prefix("mode=") {
                        rule.mode = u32::from_str_radix(m, 8).map_err(|_| err("mode: octal"))?;
                    } else if let Some(o) = opt.strip_prefix("owner=") {
                        let (u, g) = o.split_once(':').ok_or_else(|| err("owner: <uid>:<gid>"))?;
                        let id = |s: &str| s.parse::<u32>().map_err(|_| err("owner: numeric ids"));
                        rule.owner = Some((id(u)?, id(g)?));
                    } else {
                        return Err(err("unknown option"));
                    }
                }
                cfg.listen.push(rule);
            }
            "serve" if words.len() == 3 => cfg.serve.push(Serve {
                service: service.into(),
                path: path.into(),
            }),
            "serve" => return Err(err("serve takes no options")),
            _ => return Err(err("expected listen or serve")),
        }
    }
    Ok(cfg)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_rules() {
        let cfg = parse(
            "# comment\nlisten github-agent /tmp/agent.sock mode=0660 owner=1000:100\n\nserve wprs /run/user/1000/wprsd.sock # gui\n",
        )
        .unwrap();
        assert_eq!(
            cfg.listen,
            vec![Listen {
                service: "github-agent".into(),
                path: "/tmp/agent.sock".into(),
                mode: 0o660,
                owner: Some((1000, 100)),
            }]
        );
        assert_eq!(
            cfg.serve,
            vec![Serve {
                service: "wprs".into(),
                path: "/run/user/1000/wprsd.sock".into()
            }]
        );
    }

    #[test]
    fn rejects_mistakes() {
        assert!(parse("listen Bad /x").is_err());
        assert!(parse("listen a relative").is_err());
        assert!(parse("serve a /x extra").is_err());
        assert!(parse("listen a /x\nlisten a /y").is_err());
        assert!(parse("connect a /x").is_err());
        assert!(parse("listen a /x mode=9").is_err());
    }
}

//! nox-rpc: qrexec-like calls between Xen domains, mediated by dom0.
//!
//! A guest connects to its RPC socket (relayed to dom0) and sends one header
//! line `<service> <target>`. dom0 (`nox-rpcd`) knows the source from the
//! socket the call came in on, checks the policy, answers `ok` or `denied`,
//! and connects to the target's `rpc-in` socket with the header
//! `<service> <source>`. From then on it only passes bytes in both directions.
//!
//! dom0 itself calls a guest directly on its `rpc-in` socket with the source
//! `dom0` (no policy, dom0 is trusted).

pub mod config;

use std::io::{self, BufRead, Read, Write};

/// Longest header line accepted (both directions).
pub const MAX_HEADER: usize = 256;

/// Source name of calls dom0 makes itself (`nox-rpc --dom0`, e.g. app
/// start); reserved, no guest may use it.
pub const DOM0: &str = "dom0";

/// Service and domain names: 1..=32 of [a-z0-9-].
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 32
        && name
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
}

/// Reads one `\n`-terminated line of at most `MAX_HEADER` bytes, byte by byte
/// (nothing after the newline is consumed, the rest belongs to the payload).
pub fn read_line<R: Read>(r: &mut R) -> io::Result<String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        if r.read(&mut byte)? == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "no header"));
        }
        if byte[0] == b'\n' {
            break;
        }
        line.push(byte[0]);
        if line.len() > MAX_HEADER {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "header too long",
            ));
        }
    }
    String::from_utf8(line)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "header not UTF-8"))
}

/// Parses `<a> <b>` with two valid names.
pub fn parse_pair(line: &str) -> Option<(&str, &str)> {
    let mut it = line.split(' ');
    let (a, b) = (it.next()?, it.next()?);
    (it.next().is_none() && valid_name(a) && valid_name(b)).then_some((a, b))
}

/// Copies until EOF, flushing as it goes (used for the byte pipes).
pub fn pipe<R: Read, W: Write>(mut from: R, mut to: W) -> io::Result<u64> {
    let mut buf = [0u8; 32 * 1024];
    let mut total = 0;
    loop {
        let n = match from.read(&mut buf) {
            Ok(0) => return Ok(total),
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        to.write_all(&buf[..n])?;
        to.flush()?;
        total += n as u64;
    }
}

/// What a `copy` announces before its tar stream: entries (files and
/// directories), their total size, and up to `MANIFEST_NAMES` names for the
/// question. Written by the sender, so untrusted: the broker shows it
/// sanitized and stops a stream that grows past what it announced.
#[derive(Debug, PartialEq, Eq)]
pub struct Manifest {
    pub entries: u64,
    pub bytes: u64,
    pub names: Vec<String>,
}

/// Most names a manifest carries (the question shows the first few).
pub const MANIFEST_NAMES: usize = 5;

impl Manifest {
    /// Wire form: `manifest <entries> <bytes> <k>` and k name lines.
    pub fn write<W: Write>(&self, w: &mut W) -> io::Result<()> {
        let names: Vec<String> = self
            .names
            .iter()
            .take(MANIFEST_NAMES)
            .map(|n| display_name(n))
            .collect();
        writeln!(
            w,
            "manifest {} {} {}",
            self.entries,
            self.bytes,
            names.len()
        )?;
        for n in names {
            writeln!(w, "{n}")?;
        }
        Ok(())
    }

    pub fn read<R: Read>(r: &mut R) -> io::Result<Manifest> {
        let bad = || io::Error::new(io::ErrorKind::InvalidData, "bad manifest");
        let line = read_line(r)?;
        let w: Vec<&str> = line.split(' ').collect();
        let ["manifest", entries, bytes, k] = w.as_slice() else {
            return Err(bad());
        };
        let (entries, bytes, k): (u64, u64, usize) = (
            entries.parse().map_err(|_| bad())?,
            bytes.parse().map_err(|_| bad())?,
            k.parse().map_err(|_| bad())?,
        );
        if k > MANIFEST_NAMES {
            return Err(bad());
        }
        let mut names = Vec::with_capacity(k);
        for _ in 0..k {
            names.push(display_name(&read_line(r)?));
        }
        Ok(Manifest {
            entries,
            bytes,
            names,
        })
    }

    /// Bytes the tar stream may take: the content plus tar's per-entry
    /// headers and padding (also long names) and its end/record blocks.
    pub fn allowance(&self) -> u64 {
        self.bytes
            .saturating_add(self.entries.saturating_mul(2048))
            .saturating_add(20480)
    }
}

/// A name as the user gets to see it: no control characters, at most 60
/// characters (60 chars of UTF-8 fit a header line).
pub fn display_name(name: &str) -> String {
    let clean: String = name
        .chars()
        .map(|c| if c.is_control() { '?' } else { c })
        .collect();
    if clean.chars().count() > 60 {
        clean.chars().take(59).collect::<String>() + "…"
    } else {
        clean
    }
}

/// Like `pipe`, but fails once more than `limit` bytes came (nothing past
/// the limit is written).
pub fn pipe_limited<R: Read, W: Write>(mut from: R, mut to: W, limit: u64) -> io::Result<u64> {
    let mut buf = [0u8; 32 * 1024];
    let mut total: u64 = 0;
    loop {
        let n = match from.read(&mut buf) {
            Ok(0) => return Ok(total),
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        if total + n as u64 > limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("more than the {limit} bytes allowed"),
            ));
        }
        to.write_all(&buf[..n])?;
        to.flush()?;
        total += n as u64;
    }
}

/// Reads a status line via a buffered reader (client side).
pub fn read_status<R: BufRead>(r: &mut R) -> io::Result<String> {
    let mut s = String::new();
    r.take(MAX_HEADER as u64).read_line(&mut s)?;
    Ok(s.trim_end().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert!(valid_name("copy"));
        assert!(valid_name("sys-print"));
        assert!(!valid_name(""));
        assert!(!valid_name("../x"));
        assert!(!valid_name("Copy"));
        assert!(!valid_name(&"a".repeat(33)));
    }

    #[test]
    fn pairs() {
        assert_eq!(parse_pair("copy coding"), Some(("copy", "coding")));
        assert_eq!(parse_pair("copy"), None);
        assert_eq!(parse_pair("copy coding extra"), None);
        assert_eq!(parse_pair("copy co ding"), None);
        assert_eq!(parse_pair("copy ../etc"), None);
    }

    #[test]
    fn manifest_round_trip() {
        let m = Manifest {
            entries: 3,
            bytes: 1234,
            names: vec!["a.txt".into(), "evil\x1b[31mname\n".into(), "c".into()],
        };
        let mut wire = Vec::new();
        m.write(&mut wire).unwrap();
        wire.extend_from_slice(b"TARDATA");
        let mut r: &[u8] = &wire;
        let back = Manifest::read(&mut r).unwrap();
        assert_eq!(back.entries, 3);
        assert_eq!(back.bytes, 1234);
        assert_eq!(back.names, ["a.txt", "evil?[31mname?", "c"]);
        assert_eq!(r, b"TARDATA");
        assert!(Manifest::read(&mut &b"manifest 1 2 9\n"[..]).is_err());
        assert!(Manifest::read(&mut &b"manifest x 2 0\n"[..]).is_err());
        assert!(Manifest::read(&mut &b"copy 1 2 0\n"[..]).is_err());
    }

    #[test]
    fn limited_pipe_stops() {
        let mut out = Vec::new();
        assert_eq!(pipe_limited(&b"12345"[..], &mut out, 5).unwrap(), 5);
        let mut out = Vec::new();
        assert!(pipe_limited(&b"123456"[..], &mut out, 5).is_err());
        assert!(out.is_empty());
    }

    #[test]
    fn header_stops_at_newline() {
        let mut data: &[u8] = b"copy coding\npayload";
        assert_eq!(read_line(&mut data).unwrap(), "copy coding");
        assert_eq!(data, b"payload");
        let mut long: &[u8] = &[b'a'; MAX_HEADER + 10];
        assert!(read_line(&mut long).is_err());
        let mut eof: &[u8] = b"no newline";
        assert!(read_line(&mut eof).is_err());
    }
}

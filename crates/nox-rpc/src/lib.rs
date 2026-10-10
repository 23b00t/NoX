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

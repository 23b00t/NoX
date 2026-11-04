//! `nox term-filter`: positive-list filter for untrusted terminal output
//! (stdin -> stdout), used by dom0-update for everything the builder prints.
//!
//! Keeps text (UTF-8 passes through), \n \r \t and the CSI sequences that
//! only draw: SGR (m), cursor movement (A-H), erase (J, K) and ?25h/?25l,
//! plus ?2026h/?2026l (synchronized output, nom wraps every redraw in it).
//! Drops OSC, DCS/APC/PM/SOS, every other CSI (above all the ones a terminal
//! answers, like n, c, t), other ESC sequences, C1 controls (UTF-8 encoded
//! U+0080-U+009F; raw bytes 0x80-0x9F are UTF-8 continuation bytes and pass)
//! and the other C0 controls. A state machine across read boundaries,
//! unbuffered: each read is written out right away (nom redraws without a
//! newline).

use std::io::{self, Read, Write};
use std::process::ExitCode;

#[derive(Clone, Copy, PartialEq)]
enum St {
    Ground,
    /// after 0xC2: the next byte decides whether it is a C1 control
    C2,
    Esc,
    EscInter,
    Csi,
    /// a CSI that is too long: dropped up to its final byte
    CsiDrop,
    /// OSC, DCS, APC, PM, SOS: dropped up to BEL or ST
    Str,
    StrEsc,
}

const CSI_MAX: usize = 64;

pub struct Filter {
    st: St,
    csi: [u8; CSI_MAX],
    len: usize,
}

impl Default for Filter {
    fn default() -> Self {
        Filter {
            st: St::Ground,
            csi: [0; CSI_MAX],
            len: 0,
        }
    }
}

impl Filter {
    /// Filters one chunk; the state carries over to the next one
    pub fn feed(&mut self, input: &[u8], out: &mut Vec<u8>) {
        for &b in input {
            self.byte(b, out);
        }
    }

    /// End of input: a pending 0xC2 was text
    pub fn finish(&mut self, out: &mut Vec<u8>) {
        if self.st == St::C2 {
            out.push(0xC2);
        }
        self.st = St::Ground;
    }

    fn byte(&mut self, b: u8, out: &mut Vec<u8>) {
        // CAN/SUB abort any sequence
        if !matches!(self.st, St::Ground | St::C2) && (b == 0x18 || b == 0x1A) {
            self.st = St::Ground;
            return;
        }
        match self.st {
            St::C2 => {
                self.st = St::Ground;
                if (0x80..=0x9F).contains(&b) {
                    return; // U+0080-U+009F
                }
                out.push(0xC2);
                self.ground(b, out);
            }
            St::Ground => self.ground(b, out),
            St::Esc => {
                self.st = match b {
                    b'[' => {
                        self.csi[0] = 0x1B;
                        self.csi[1] = b'[';
                        self.len = 2;
                        St::Csi
                    }
                    b']' | b'P' | b'_' | b'^' | b'X' => St::Str,
                    0x1B => St::Esc,
                    0x20..=0x2F => St::EscInter,
                    // final byte (or garbage) of a dropped ESC sequence
                    _ => St::Ground,
                };
            }
            St::EscInter => {
                if b == 0x1B {
                    self.st = St::Esc;
                } else if !(0x20..=0x2F).contains(&b) {
                    self.st = St::Ground;
                }
            }
            St::Csi | St::CsiDrop => match b {
                0x1B => self.st = St::Esc,
                0x40..=0x7E => {
                    if self.st == St::Csi {
                        self.csi[self.len] = b;
                        self.len += 1;
                        if self.csi_allowed() {
                            out.extend_from_slice(&self.csi[..self.len]);
                        }
                    }
                    self.st = St::Ground;
                }
                0x20..=0x3F => {
                    // one byte stays free for the final byte
                    if self.st == St::Csi && self.len < CSI_MAX - 1 {
                        self.csi[self.len] = b;
                        self.len += 1;
                    } else {
                        self.st = St::CsiDrop;
                    }
                }
                // C0 inside CSI: dropped, the sequence goes on
                0x00..=0x1F => {}
                // not a CSI byte: sequence dropped
                _ => self.st = St::Ground,
            },
            St::Str => {
                if b == 0x07 {
                    self.st = St::Ground; // BEL ends OSC
                } else if b == 0x1B {
                    self.st = St::StrEsc;
                }
            }
            St::StrEsc => {
                if b == b'\\' {
                    self.st = St::Ground; // ESC \ = ST
                } else {
                    // ESC ends the string and starts a new sequence
                    self.st = St::Esc;
                    self.byte(b, out);
                }
            }
        }
    }

    fn ground(&mut self, b: u8, out: &mut Vec<u8>) {
        if b == 0x1B {
            self.st = St::Esc;
        } else if b == 0xC2 {
            self.st = St::C2;
        } else if matches!(b, b'\n' | b'\r' | b'\t') || (b >= 0x20 && b != 0x7F) {
            out.push(b);
        }
    }

    fn csi_allowed(&self) -> bool {
        let s = &self.csi[..self.len];
        let f = s[s.len() - 1];
        let params = &s[2..s.len() - 1];
        if (params == b"?25" || params == b"?2026") && (f == b'h' || f == b'l') {
            return true;
        }
        // digits and ';' only, nothing else between "ESC [" and the final byte
        if !params.iter().all(|&c| c.is_ascii_digit() || c == b';') {
            return false;
        }
        matches!(f, b'm' | b'A'..=b'H' | b'J' | b'K')
    }
}

pub fn main() -> ExitCode {
    let mut stdin = io::stdin().lock();
    let mut stdout = io::stdout().lock();
    let mut f = Filter::default();
    let mut buf = [0u8; 4096];
    let mut out = Vec::with_capacity(buf.len() + CSI_MAX);
    loop {
        let n = match stdin.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        out.clear();
        f.feed(&buf[..n], &mut out);
        if put(&mut stdout, &out).is_err() {
            return ExitCode::FAILURE;
        }
    }
    out.clear();
    f.finish(&mut out);
    if put(&mut stdout, &out).is_err() {
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

/// stdout is line buffered: each chunk is flushed, nom redraws without \n
fn put(w: &mut impl Write, out: &[u8]) -> io::Result<()> {
    w.write_all(out)?;
    w.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(input: &[u8]) -> Vec<u8> {
        let mut f = Filter::default();
        let mut out = Vec::new();
        f.feed(input, &mut out);
        f.finish(&mut out);
        out
    }

    /// The same input byte by byte: state across read boundaries
    fn run_bytewise(input: &[u8]) -> Vec<u8> {
        let mut f = Filter::default();
        let mut out = Vec::new();
        for b in input {
            f.feed(std::slice::from_ref(b), &mut out);
        }
        f.finish(&mut out);
        out
    }

    /// What nom draws: colors, cursor up, erase, synchronized output, cursor
    /// hide/show, box drawing and UTF-8 text
    const NOM: &[u8] = b"\x1b[?2026h\x1b[?25l\x1b[1A\x1b[2K\x1b[1G\x1b[1;34m\xe2\x94\x83\x1b[0m \
        building \x1b[32mhello-2.12\x1b[0m \xc3\xa4\xc2\xa0\r\n\x1b[J\x1b[3;4H\x1b[K\x1b[?25h\x1b[?2026l\t";

    #[test]
    fn drawing_passes_unchanged() {
        assert_eq!(run(NOM), NOM);
        assert_eq!(run_bytewise(NOM), NOM);
    }

    #[test]
    fn injected_sequences_are_dropped() {
        let attacks: &[&[u8]] = &[
            b"\x1b]52;c;YmVmb3Jl\x07",   // OSC 52 write, BEL
            b"\x1b]52;c;?\x1b\\",        // OSC 52 read, ST
            b"\x1b]0;title\x07",         // window title
            b"\x1bP1$qm\x1b\\",          // DCS (DECRQSS)
            b"\x1b_apc\x1b\\",           // APC
            b"\x1b^pm\x1b\\",            // PM
            b"\x1bXsos\x1b\\",           // SOS
            b"\x1b[6n",                  // cursor position report
            b"\x1b[c",                   // device attributes
            b"\x1b[>c",                  // secondary DA
            b"\x1b[18t",                 // window size report
            b"\x1b[?2026$p",             // mode query
            b"\x1b[?1049h",              // alternate screen
            b"\x1b[1;2r",                // scroll region
            b"\x1b7\x1b8",               // save/restore cursor
            b"\x1b(0",                   // charset (ESC intermediate)
            b"\x1bc",                    // full reset
            b"\x07\x08\x0b\x0c\x0e\x7f", // other C0 and DEL
            b"\xc2\x9b6n",               // C1 CSI, UTF-8 encoded
            b"\xc2\x9d52;c;?\x07",       // C1 OSC: only the C1 byte goes
        ];
        for a in attacks {
            let mut input = b"before".to_vec();
            input.extend_from_slice(a);
            input.extend_from_slice(b"after");
            let out = run(&input);
            assert!(!out.contains(&0x1B), "ESC left in {:?}: {:?}", a, out);
            assert_eq!(run_bytewise(&input), out, "chunking changes {:?}", a);
            assert!(
                out.starts_with(b"before") && out.ends_with(b"after"),
                "{:?}",
                out
            );
        }
        // The C1 OSC's text after the C1 byte is plain text, no sequence
        assert_eq!(run(b"\xc2\x9d52;c;?\x07x"), b"52;c;?x");
    }

    #[test]
    fn mixed_stream_equals_the_drawing() {
        let mut input = Vec::new();
        for (i, chunk) in NOM.split(|&b| b == b' ').enumerate() {
            if i > 0 {
                input.extend_from_slice(b"\x1b]52;c;?\x07 \x1b[6n");
            }
            input.extend_from_slice(chunk);
        }
        assert_eq!(run(&input), NOM);
        assert_eq!(run_bytewise(&input), NOM);
    }

    #[test]
    fn can_sub_abort_and_esc_restarts() {
        assert_eq!(run(b"\x1b]52;c;\x18x"), b"x");
        assert_eq!(run(b"\x1b[31\x1ax"), b"x");
        // ESC inside a string ends it and starts a new sequence
        assert_eq!(run(b"\x1b]0;t\x1b[31mx"), b"\x1b[31mx");
        // ESC inside CSI starts a new one
        assert_eq!(run(b"\x1b[3\x1b[1mx"), b"\x1b[1mx");
        // C0 inside CSI is dropped, the CSI goes on
        assert_eq!(run(b"\x1b[3\x071mx"), b"\x1b[31mx");
    }

    #[test]
    fn overlong_csi_is_dropped() {
        let mut long = b"\x1b[".to_vec();
        long.extend(std::iter::repeat_n(b'1', 100));
        long.extend_from_slice(b"mx");
        assert_eq!(run(&long), b"x");
        // the longest one that still fits passes
        let mut fits = b"\x1b[".to_vec();
        fits.extend(std::iter::repeat_n(b'1', CSI_MAX - 3));
        fits.push(b'm');
        assert_eq!(run(&fits), fits);
    }

    #[test]
    fn pending_c2_at_eof_is_text() {
        assert_eq!(run(b"a\xc2"), b"a\xc2");
        assert_eq!(run(b"\xc2\x85"), b"");
        assert_eq!(run(b"\xc2\xa0"), b"\xc2\xa0");
    }
}

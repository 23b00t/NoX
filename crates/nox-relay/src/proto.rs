//! Framing on the vchan: many byte streams over one ring.
//!
//! Frame = header (stream id u32 LE, kind u8, payload length u32 LE) + payload.
//! The server side opens even stream ids, the client side odd ones, so both
//! can open streams without coordination. Flow control per stream: a sender
//! may have at most `WINDOW` unacknowledged bytes in flight; the receiver
//! returns credit once it has written data to the local socket.

pub const HEADER: usize = 9;
pub const MAX_PAYLOAD: usize = 32 * 1024;
pub const WINDOW: usize = 256 * 1024;
pub const MAGIC: &[u8] = b"NOX-RELAY/1";
pub const MAX_SERVICE: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    /// First frame from each side, payload `MAGIC`.
    Hello = 0,
    /// Open a stream to the peer's service (payload: service name).
    Open = 1,
    OpenOk = 2,
    OpenErr = 3,
    Data = 4,
    Close = 5,
    /// Payload: u32 LE, bytes the sender may send additionally.
    Credit = 6,
    /// The sender's local side is done writing (half-close); data in the
    /// other direction keeps flowing.
    Shutdown = 7,
}

impl Kind {
    fn from_u8(v: u8) -> Option<Kind> {
        Some(match v {
            0 => Kind::Hello,
            1 => Kind::Open,
            2 => Kind::OpenOk,
            3 => Kind::OpenErr,
            4 => Kind::Data,
            5 => Kind::Close,
            6 => Kind::Credit,
            7 => Kind::Shutdown,
            _ => return None,
        })
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct Frame {
    pub stream: u32,
    pub kind: Kind,
    pub payload: Vec<u8>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    UnknownKind(u8),
    TooLarge(usize),
}

pub fn encode(out: &mut Vec<u8>, stream: u32, kind: Kind, payload: &[u8]) {
    debug_assert!(payload.len() <= MAX_PAYLOAD);
    out.extend_from_slice(&stream.to_le_bytes());
    out.push(kind as u8);
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
}

/// Decodes one frame from the start of `buf`: `Ok(None)` if incomplete,
/// otherwise the frame and the number of bytes it used.
pub fn decode(buf: &[u8]) -> Result<Option<(Frame, usize)>, Error> {
    if buf.len() < HEADER {
        return Ok(None);
    }
    let stream = u32::from_le_bytes(buf[0..4].try_into().unwrap());
    let kind = Kind::from_u8(buf[4]).ok_or(Error::UnknownKind(buf[4]))?;
    let len = u32::from_le_bytes(buf[5..9].try_into().unwrap()) as usize;
    if len > MAX_PAYLOAD {
        return Err(Error::TooLarge(len));
    }
    if buf.len() < HEADER + len {
        return Ok(None);
    }
    let payload = buf[HEADER..HEADER + len].to_vec();
    Ok(Some((
        Frame {
            stream,
            kind,
            payload,
        },
        HEADER + len,
    )))
}

/// Service names: 1..=32 of [a-z0-9-].
pub fn valid_service(name: &[u8]) -> bool {
    !name.is_empty()
        && name.len() <= MAX_SERVICE
        && name
            .iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let mut buf = Vec::new();
        encode(&mut buf, 7, Kind::Data, b"hello");
        encode(&mut buf, 8, Kind::Close, b"");
        let (f, n) = decode(&buf).unwrap().unwrap();
        assert_eq!(
            f,
            Frame {
                stream: 7,
                kind: Kind::Data,
                payload: b"hello".to_vec()
            }
        );
        let (g, m) = decode(&buf[n..]).unwrap().unwrap();
        assert_eq!(g.kind, Kind::Close);
        assert_eq!(n + m, buf.len());
    }

    #[test]
    fn incomplete() {
        let mut buf = Vec::new();
        encode(&mut buf, 1, Kind::Data, b"abc");
        for cut in 0..buf.len() {
            assert_eq!(decode(&buf[..cut]), Ok(None));
        }
    }

    #[test]
    fn rejects_bad_frames() {
        let mut buf = vec![0, 0, 0, 0, 99, 0, 0, 0, 0];
        assert_eq!(decode(&buf), Err(Error::UnknownKind(99)));
        buf[4] = Kind::Data as u8;
        buf[5..9].copy_from_slice(&((MAX_PAYLOAD + 1) as u32).to_le_bytes());
        assert_eq!(decode(&buf), Err(Error::TooLarge(MAX_PAYLOAD + 1)));
    }

    #[test]
    fn service_names() {
        assert!(valid_service(b"github-agent"));
        assert!(!valid_service(b""));
        assert!(!valid_service(b"../etc"));
        assert!(!valid_service(&[b'a'; MAX_SERVICE + 1]));
    }
}

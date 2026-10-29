//! Grant broker for wprs' pixel buffers (config rule `grants`): a local
//! client gets the fd of Xen grant pages, but never the grant devices
//! themselves (whoever may open /dev/xen/gntdev in dom0 can map any grant of
//! any domain, whoever may open /dev/xen/gntalloc in a guest can share pages
//! with any domain).
//!
//! - guest (`--role server`): fresh pages, granted read-only to the peer
//!   (dom0) only, one gntalloc fd per request
//! - host (`--role client`): the peer's grants mapped, nothing else, one gntdev
//!   fd per request
//!
//! Closing the fd frees the grants or mappings, so they live exactly as long
//! as the client holds them, independent of the relay.
//!
//! Protocol on a stream socket, one reply per request, both `u32 LE length` +
//! body:
//! - `A` + u32 pages (guest) → `O` + u64 mmap offset + u32 refs[pages], fd
//! - `M` + u32 refs[n] (host) → `O` + u64 mmap offset, fd
//! - failure: `E` + message, no fd

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};

/// One 4K-1080p window's double buffer, with room to spare.
pub const MAX_PAGES: usize = 16384;
const PAGE: u64 = 4096;

// _IOC(_IOC_NONE, 'G', nr, size) from include/uapi/xen/gntalloc.h, gntdev.h
const fn ioc_none(nr: u64, size: u64) -> u64 {
    (size << 16) | ((b'G' as u64) << 8) | nr
}
// struct ioctl_gntalloc_alloc_gref: u16 domid, u16 flags, u32 count,
// u64 index, u32 gref_ids[1] (24 bytes)
const IOCTL_GNTALLOC_ALLOC_GREF: u64 = ioc_none(5, 24);
// struct ioctl_gntdev_map_grant_ref: u32 count, u32 pad, u64 index,
// { u32 domid, u32 ref } refs[1] (24 bytes)
const IOCTL_GNTDEV_MAP_GRANT_REF: u64 = ioc_none(0, 24);

pub struct Broker {
    listener: UnixListener,
    peer: u32,
    guest: bool,
}

impl Broker {
    pub fn new(listener: UnixListener, peer: u32, guest: bool) -> io::Result<Self> {
        listener.set_nonblocking(false)?;
        Ok(Broker {
            listener,
            peer,
            guest,
        })
    }

    /// Serves clients in threads of their own, independent of the vchan.
    pub fn spawn(self) {
        std::thread::spawn(move || {
            for conn in self.listener.incoming() {
                match conn {
                    Ok(conn) => {
                        let (peer, guest) = (self.peer, self.guest);
                        std::thread::spawn(move || serve(conn, peer, guest));
                    }
                    Err(e) => eprintln!("grants: accept: {e}"),
                }
            }
        });
    }
}

fn serve(mut conn: UnixStream, peer: u32, guest: bool) {
    loop {
        let req = match read_msg(&mut conn) {
            Ok(Some(r)) => r,
            Ok(None) => return,
            Err(e) => {
                eprintln!("grants: {e}");
                return;
            }
        };
        let reply = if guest {
            alloc(peer, &req)
        } else {
            map(peer, &req)
        };
        let sent = match reply {
            Ok((body, fd)) => send_msg(&conn, &body, Some(&fd)),
            Err(e) => {
                let mut body = b"E".to_vec();
                body.extend_from_slice(e.to_string().as_bytes());
                send_msg(&conn, &body, None)
            }
        };
        if let Err(e) = sent {
            eprintln!("grants: reply: {e}");
            return;
        }
    }
}

fn invalid(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, msg.to_string())
}

fn open(path: &str) -> io::Result<File> {
    OpenOptions::new().read(true).write(true).open(path)
}

fn ioctl(fd: &File, request: u64, arg: *mut u32) -> io::Result<()> {
    // SAFETY: arg points to a buffer of the layout the request expects
    if unsafe { libc::ioctl(fd.as_raw_fd(), request as _, arg) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Guest: `pages` fresh pages, granted read-only to the peer.
fn alloc(peer: u32, req: &[u8]) -> io::Result<(Vec<u8>, File)> {
    let pages = match req {
        [b'A', n @ ..] if n.len() == 4 => u32::from_le_bytes(n.try_into().unwrap()) as usize,
        _ => return Err(invalid("expected A <pages>")),
    };
    if pages == 0 || pages > MAX_PAGES {
        return Err(invalid("pages out of range"));
    }
    let dev = open("/dev/xen/gntalloc")?;
    // domid | flags << 16 (0: read-only), count, index (2 words), refs
    let mut arg = vec![0u32; 4 + pages];
    arg[0] = peer & 0xffff;
    arg[1] = pages as u32;
    ioctl(&dev, IOCTL_GNTALLOC_ALLOC_GREF, arg.as_mut_ptr())?;
    let mut body = b"O".to_vec();
    for w in &arg[2..] {
        body.extend_from_slice(&w.to_le_bytes());
    }
    Ok((body, dev))
}

/// Host: the peer's grants `refs`, mapped.
fn map(peer: u32, req: &[u8]) -> io::Result<(Vec<u8>, File)> {
    let refs = match req {
        [b'M', r @ ..] if !r.is_empty() && r.len() % 4 == 0 => r,
        _ => return Err(invalid("expected M <refs>")),
    };
    let count = refs.len() / 4;
    if count > MAX_PAGES {
        return Err(invalid("too many refs"));
    }
    let dev = open("/dev/xen/gntdev")?;
    // count, pad, index (2 words), { domid, ref }[count]
    let mut arg = vec![0u32; 4 + 2 * count];
    arg[0] = count as u32;
    for (i, r) in refs.as_chunks::<4>().0.iter().enumerate() {
        arg[4 + 2 * i] = peer;
        arg[5 + 2 * i] = u32::from_le_bytes(*r);
    }
    ioctl(&dev, IOCTL_GNTDEV_MAP_GRANT_REF, arg.as_mut_ptr())?;
    let index = u64::from(arg[2]) | (u64::from(arg[3]) << 32);
    debug_assert!(index % PAGE == 0);
    let mut body = b"O".to_vec();
    body.extend_from_slice(&index.to_le_bytes());
    Ok((body, dev))
}

fn read_msg(conn: &mut UnixStream) -> io::Result<Option<Vec<u8>>> {
    let mut len = [0u8; 4];
    match conn.read_exact(&mut len) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_le_bytes(len) as usize;
    if len > 1 + 4 * MAX_PAGES {
        return Err(invalid("request too large"));
    }
    let mut body = vec![0u8; len];
    conn.read_exact(&mut body)?;
    Ok(Some(body))
}

/// Length + body; the fd rides along with the first byte.
fn send_msg(conn: &UnixStream, body: &[u8], fd: Option<&File>) -> io::Result<()> {
    let mut msg = (body.len() as u32).to_le_bytes().to_vec();
    msg.extend_from_slice(body);
    let Some(fd) = fd else {
        return (&*conn).write_all(&msg);
    };
    let raw = fd.as_raw_fd();
    // SAFETY: CMSG_SPACE only computes a size
    let space = unsafe { libc::CMSG_SPACE(std::mem::size_of::<libc::c_int>() as u32) } as usize;
    let mut cbuf = vec![0u8; space];
    let mut iov = libc::iovec {
        iov_base: msg.as_ptr() as *mut libc::c_void,
        iov_len: msg.len(),
    };
    // SAFETY: zeroed msghdr is valid; pointers below outlive the call
    let mut hdr: libc::msghdr = unsafe { std::mem::zeroed() };
    hdr.msg_iov = &mut iov;
    hdr.msg_iovlen = 1;
    hdr.msg_control = cbuf.as_mut_ptr() as *mut libc::c_void;
    hdr.msg_controllen = space as _;
    // SAFETY: the control buffer has room for one fd (CMSG_SPACE above)
    unsafe {
        let cmsg = libc::CMSG_FIRSTHDR(&hdr);
        (*cmsg).cmsg_level = libc::SOL_SOCKET;
        (*cmsg).cmsg_type = libc::SCM_RIGHTS;
        (*cmsg).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<libc::c_int>() as u32) as _;
        std::ptr::copy_nonoverlapping(
            &raw as *const libc::c_int as *const u8,
            libc::CMSG_DATA(cmsg),
            std::mem::size_of::<libc::c_int>(),
        );
    }
    // SAFETY: hdr is fully initialised
    let n = unsafe { libc::sendmsg(conn.as_raw_fd(), &hdr, libc::MSG_NOSIGNAL) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    // The fd went with the first byte; the rest without
    (&*conn).write_all(&msg[n as usize..])
}

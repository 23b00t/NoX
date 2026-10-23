//! Minimal binding to libxenvchan (from the Xen tools), non-blocking mode,
//! and the one xenstore read the relay needs (is the peer domain still there).

use std::ffi::{c_char, c_int, c_void, CString};
use std::io;
use std::os::fd::RawFd;

#[repr(C)]
struct RawVchan {
    _private: [u8; 0],
}

#[link(name = "xenvchan")]
extern "C" {
    fn libxenvchan_server_init(
        logger: *mut c_void,
        domain: c_int,
        xs_path: *const c_char,
        read_min: usize,
        write_min: usize,
    ) -> *mut RawVchan;
    fn libxenvchan_client_init(
        logger: *mut c_void,
        domain: c_int,
        xs_path: *const c_char,
    ) -> *mut RawVchan;
    fn libxenvchan_close(ctrl: *mut RawVchan);
    fn libxenvchan_read(ctrl: *mut RawVchan, data: *mut c_void, size: usize) -> c_int;
    fn libxenvchan_write(ctrl: *mut RawVchan, data: *const c_void, size: usize) -> c_int;
    fn libxenvchan_wait(ctrl: *mut RawVchan) -> c_int;
    fn libxenvchan_fd_for_select(ctrl: *mut RawVchan) -> c_int;
    fn libxenvchan_is_open(ctrl: *mut RawVchan) -> c_int;
    fn libxenvchan_data_ready(ctrl: *mut RawVchan) -> c_int;
    fn libxenvchan_buffer_space(ctrl: *mut RawVchan) -> c_int;
}

#[link(name = "xenstore")]
extern "C" {
    fn xs_open(flags: std::ffi::c_ulong) -> *mut c_void;
    fn xs_close(h: *mut c_void);
    fn xs_read(h: *mut c_void, t: u32, path: *const c_char, len: *mut u32) -> *mut c_void;
}

/// State reported by `libxenvchan_is_open`.
#[derive(Debug, PartialEq, Eq)]
pub enum State {
    Closed,
    Open,
    /// Server only: no client has connected yet.
    Waiting,
}

pub struct Vchan(*mut RawVchan);

impl Vchan {
    /// Offer a vchan to `peer` under the xenstore path `path` (relative paths
    /// are below the caller's /local/domain/<id>).
    pub fn server(peer: u32, path: &str, ring: usize) -> io::Result<Self> {
        let path = c_path(path)?;
        // SAFETY: valid C string, NULL logger is accepted by libxenvchan
        let raw = unsafe {
            libxenvchan_server_init(
                std::ptr::null_mut(),
                peer as c_int,
                path.as_ptr(),
                ring,
                ring,
            )
        };
        Self::wrap(raw)
    }

    /// Connect to the vchan that domain `peer` offers under `path` (absolute).
    pub fn client(peer: u32, path: &str) -> io::Result<Self> {
        let path = c_path(path)?;
        // SAFETY: as above
        let raw =
            unsafe { libxenvchan_client_init(std::ptr::null_mut(), peer as c_int, path.as_ptr()) };
        Self::wrap(raw)
    }

    fn wrap(raw: *mut RawVchan) -> io::Result<Self> {
        if raw.is_null() {
            Err(io::Error::last_os_error())
        } else {
            Ok(Vchan(raw))
        }
    }

    /// Event channel fd: readable when the peer signalled (data, space, close).
    pub fn fd(&self) -> RawFd {
        // SAFETY: self.0 is a live handle
        unsafe { libxenvchan_fd_for_select(self.0) }
    }

    /// Consume a pending notification; call when `fd()` is readable.
    pub fn wait(&self) -> io::Result<()> {
        // SAFETY: as above
        if unsafe { libxenvchan_wait(self.0) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    pub fn state(&self) -> State {
        // SAFETY: as above
        match unsafe { libxenvchan_is_open(self.0) } {
            1 => State::Open,
            2 => State::Waiting,
            _ => State::Closed,
        }
    }

    pub fn data_ready(&self) -> usize {
        // SAFETY: as above
        unsafe { libxenvchan_data_ready(self.0) }.max(0) as usize
    }

    /// Free space in our ring to the peer.
    pub fn buffer_space(&self) -> usize {
        // SAFETY: as above
        unsafe { libxenvchan_buffer_space(self.0) }.max(0) as usize
    }

    pub fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        // SAFETY: buf is valid for buf.len() bytes
        let n = unsafe { libxenvchan_read(self.0, buf.as_mut_ptr().cast(), buf.len()) };
        if n < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(n as usize)
    }

    /// Writes as much as fits into the ring (possibly 0 bytes).
    pub fn write(&self, buf: &[u8]) -> io::Result<usize> {
        // SAFETY: buf is valid for buf.len() bytes
        let n = unsafe { libxenvchan_write(self.0, buf.as_ptr().cast(), buf.len()) };
        if n < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(n as usize)
    }
}

impl Drop for Vchan {
    fn drop(&mut self) {
        // SAFETY: handle is live and not used afterwards
        unsafe { libxenvchan_close(self.0) }
    }
}

/// A xenstore connection, to notice a peer domain that was destroyed without
/// closing the vchan (hard kill): its ring still looks open, but Xen removes
/// `/local/domain/<id>` with the domain.
pub struct Xenstore(*mut c_void);

impl Xenstore {
    pub fn open() -> io::Result<Self> {
        // SAFETY: plain library call, flags 0 = read/write connection
        let h = unsafe { xs_open(0) };
        if h.is_null() {
            Err(io::Error::last_os_error())
        } else {
            Ok(Xenstore(h))
        }
    }

    /// True only when xenstore says the domain's directory does not exist
    /// (ENOENT); other errors (a guest may not read dom0's directory) count
    /// as "still there".
    pub fn domain_gone(&self, domid: u32) -> bool {
        let path = CString::new(format!("/local/domain/{domid}")).expect("no NUL");
        let mut len = 0u32;
        // SAFETY: live handle, valid C string, len is a valid out pointer
        let v = unsafe { xs_read(self.0, 0, path.as_ptr(), &mut len) };
        if v.is_null() {
            return io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT);
        }
        // SAFETY: xs_read returns a malloc'd buffer owned by the caller
        unsafe { libc::free(v) };
        false
    }
}

impl Drop for Xenstore {
    fn drop(&mut self) {
        // SAFETY: handle is live and not used afterwards
        unsafe { xs_close(self.0) }
    }
}

fn c_path(path: &str) -> io::Result<CString> {
    CString::new(path)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in xenstore path"))
}

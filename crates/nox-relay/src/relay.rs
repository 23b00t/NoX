//! Event loop: one vchan to the peer, local Unix sockets on this side.

use crate::config::{Config, Listen};
use crate::proto::{self, Frame, Kind, MAGIC, MAX_PAYLOAD, WINDOW};
use crate::vchan::{State, Vchan};
use std::collections::HashMap;
use std::fs;
use std::io::{self, ErrorKind, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;

/// Stop reading local sockets while this much is queued for the vchan.
const VOUT_HIGH: usize = 1 << 20;
/// Stop reading the vchan while this much is queued for it: answers to the
/// peer's frames (OpenErr, Credit, ...) pile up when the peer does not read
/// its ring. Data is held at VOUT_HIGH, so a well-behaved peer never gets here.
const VOUT_LIMIT: usize = 4 << 20;
/// Return credit to the peer in steps of at least this size.
const CREDIT_STEP: usize = 32 * 1024;
const MAX_STREAMS: usize = 256;

#[derive(Debug, PartialEq, Eq)]
enum StreamState {
    /// We sent Open, waiting for OpenOk.
    Opening,
    Open,
    /// The peer closed; flush what is left, then drop.
    Closing,
}

struct Stream {
    sock: UnixStream,
    state: StreamState,
    /// From the peer, not yet written to the local socket.
    out: Vec<u8>,
    /// Bytes we may still send to the peer on this stream.
    window: usize,
    /// Written to the local socket, not yet credited to the peer.
    unacked: usize,
    /// The local socket reached EOF (we sent Shutdown).
    local_eof: bool,
    /// The peer sent Shutdown: shut our write side once `out` is flushed.
    peer_eof: bool,
}

impl Stream {
    fn new(sock: UnixStream, state: StreamState) -> Self {
        Stream {
            sock,
            state,
            out: Vec::new(),
            window: WINDOW,
            unacked: 0,
            local_eof: false,
            peer_eof: false,
        }
    }
}

pub struct Relay {
    vchan: Vchan,
    server: bool,
    listeners: Vec<(UnixListener, String)>,
    serve: HashMap<String, PathBuf>,
    streams: HashMap<u32, Stream>,
    next_id: u32,
    vin: Vec<u8>,
    vout: Vec<u8>,
}

impl Relay {
    pub fn new(vchan: Vchan, cfg: Config, server: bool) -> io::Result<Self> {
        let mut listeners = Vec::new();
        for rule in &cfg.listen {
            listeners.push((bind(rule)?, rule.service.clone()));
        }
        let mut vout = Vec::new();
        proto::encode(&mut vout, 0, Kind::Hello, MAGIC);
        Ok(Relay {
            vchan,
            server,
            listeners,
            serve: cfg.serve.into_iter().map(|s| (s.service, s.path)).collect(),
            streams: HashMap::new(),
            next_id: if server { 2 } else { 1 },
            vin: Vec::new(),
            vout,
        })
    }

    /// Runs until the peer closes the vchan (Ok) or breaks the protocol (Err).
    pub fn run(&mut self) -> io::Result<()> {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            self.pump_vchan(&mut buf)?;
            if self.vchan.state() == State::Closed {
                eprintln!("peer closed the vchan");
                return Ok(());
            }

            let ids: Vec<u32> = self.streams.keys().copied().collect();
            let mut fds = Vec::with_capacity(1 + self.listeners.len() + ids.len());
            fds.push(pollfd(self.vchan.fd(), libc::POLLIN));
            for (l, _) in &self.listeners {
                fds.push(pollfd(l.as_raw_fd(), libc::POLLIN));
            }
            for id in &ids {
                let s = &self.streams[id];
                let mut ev = 0;
                if s.state == StreamState::Open
                    && !s.local_eof
                    && s.window > 0
                    && self.vout.len() < VOUT_HIGH
                {
                    ev |= libc::POLLIN;
                }
                if !s.out.is_empty() {
                    ev |= libc::POLLOUT;
                }
                // Nothing to do on this socket now: leave it out (fd -1), or
                // a hang-up would wake us every round. Unread data and EOF
                // wait in the socket until we may read again.
                let fd = if ev == 0 { -1 } else { s.sock.as_raw_fd() };
                fds.push(pollfd(fd, ev));
            }
            // Short timeout while the ring is full: the peer's notification
            // when it frees space is the fast path, this is the fallback
            let timeout = if self.vout.is_empty() { 1000 } else { 20 };
            // SAFETY: fds is a valid array of pollfd
            if unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) } < 0 {
                let e = io::Error::last_os_error();
                if e.kind() == ErrorKind::Interrupted {
                    continue;
                }
                return Err(e);
            }

            if fds[0].revents != 0 {
                self.vchan.wait()?;
            }

            let mut accepted = Vec::new();
            for (i, (l, service)) in self.listeners.iter().enumerate() {
                if fds[1 + i].revents & libc::POLLIN != 0 {
                    while let Ok((sock, _)) = l.accept() {
                        accepted.push((sock, service.clone()));
                    }
                }
            }
            for (sock, service) in accepted {
                self.open_local(sock, &service);
            }

            let base = 1 + self.listeners.len();
            for (k, id) in ids.iter().enumerate() {
                let rev = fds[base + k].revents;
                if rev != 0 {
                    self.service_stream(*id, rev, &mut buf);
                }
            }
        }
    }

    fn pump_vchan(&mut self, buf: &mut [u8]) -> io::Result<()> {
        while self.vout.len() < VOUT_LIMIT {
            let ready = self.vchan.data_ready();
            if ready == 0 {
                break;
            }
            let len = ready.min(buf.len());
            let n = self.vchan.read(&mut buf[..len])?;
            if n == 0 {
                break;
            }
            self.vin.extend_from_slice(&buf[..n]);
        }
        loop {
            match proto::decode(&self.vin) {
                Ok(Some((frame, used))) => {
                    self.vin.drain(..used);
                    self.handle(frame)?;
                }
                Ok(None) => break,
                Err(e) => {
                    return Err(io::Error::new(
                        ErrorKind::InvalidData,
                        format!("bad frame from peer: {e:?}"),
                    ))
                }
            }
        }
        while !self.vout.is_empty() {
            let n = self.vchan.write(&self.vout)?;
            if n == 0 {
                break;
            }
            self.vout.drain(..n);
        }
        Ok(())
    }

    fn send(&mut self, stream: u32, kind: Kind, payload: &[u8]) {
        proto::encode(&mut self.vout, stream, kind, payload);
    }

    fn handle(&mut self, f: Frame) -> io::Result<()> {
        match f.kind {
            Kind::Hello => {
                if f.payload != MAGIC {
                    return Err(io::Error::new(
                        ErrorKind::InvalidData,
                        "peer speaks another protocol",
                    ));
                }
                eprintln!("peer connected");
            }
            Kind::Open => self.open_remote(f.stream, &f.payload),
            Kind::OpenOk => {
                if let Some(s) = self.streams.get_mut(&f.stream) {
                    if s.state == StreamState::Opening {
                        s.state = StreamState::Open;
                    }
                }
            }
            Kind::OpenErr => {
                if self.streams.remove(&f.stream).is_some() {
                    eprintln!("stream {}: peer refused the service", f.stream);
                }
            }
            Kind::Data => {
                let Some(s) = self.streams.get_mut(&f.stream) else {
                    return Ok(());
                };
                s.out.extend_from_slice(&f.payload);
                if s.out.len() > WINDOW {
                    // The peer ignored our window
                    eprintln!("stream {}: peer overran the window, closing", f.stream);
                    self.close(f.stream);
                } else {
                    self.flush(f.stream);
                }
            }
            Kind::Close => {
                if let Some(s) = self.streams.get_mut(&f.stream) {
                    if s.out.is_empty() {
                        self.streams.remove(&f.stream);
                    } else {
                        s.state = StreamState::Closing;
                    }
                }
            }
            Kind::Shutdown => {
                if let Some(s) = self.streams.get_mut(&f.stream) {
                    s.peer_eof = true;
                    self.flush(f.stream);
                }
            }
            Kind::Credit => {
                if let (Some(s), Ok(bytes)) = (
                    self.streams.get_mut(&f.stream),
                    <[u8; 4]>::try_from(f.payload.as_slice()),
                ) {
                    s.window = s
                        .window
                        .saturating_add(u32::from_le_bytes(bytes) as usize)
                        .min(WINDOW);
                }
            }
        }
        Ok(())
    }

    /// A local client connected to one of our listeners.
    fn open_local(&mut self, sock: UnixStream, service: &str) {
        if self.streams.len() >= MAX_STREAMS || sock.set_nonblocking(true).is_err() {
            return;
        }
        let id = self.next_id;
        self.next_id = self.next_id.wrapping_add(2);
        self.streams
            .insert(id, Stream::new(sock, StreamState::Opening));
        self.send(id, Kind::Open, service.as_bytes());
    }

    /// The peer wants one of our served services.
    fn open_remote(&mut self, id: u32, service: &[u8]) {
        // Peer-opened ids have the peer's parity: odd for a client peer
        let peer_parity = if self.server { 1 } else { 0 };
        if id % 2 != peer_parity
            || self.streams.contains_key(&id)
            || self.streams.len() >= MAX_STREAMS
        {
            self.send(id, Kind::OpenErr, b"");
            return;
        }
        let name = String::from_utf8_lossy(service).into_owned();
        let Some(path) = proto::valid_service(service)
            .then(|| self.serve.get(&name))
            .flatten()
        else {
            eprintln!("peer asked for unknown service {name:?}");
            self.send(id, Kind::OpenErr, b"");
            return;
        };
        match UnixStream::connect(path).and_then(|s| s.set_nonblocking(true).map(|_| s)) {
            Ok(sock) => {
                self.streams
                    .insert(id, Stream::new(sock, StreamState::Open));
                self.send(id, Kind::OpenOk, b"");
            }
            Err(e) => {
                eprintln!("service {name}: {}: {e}", path.display());
                self.send(id, Kind::OpenErr, b"");
            }
        }
    }

    fn service_stream(&mut self, id: u32, rev: libc::c_short, buf: &mut [u8]) {
        if rev & libc::POLLOUT != 0 {
            self.flush(id);
        }
        if rev & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) == 0 {
            return;
        }
        let Some(s) = self.streams.get_mut(&id) else {
            return;
        };
        let max = if s.state == StreamState::Open && !s.local_eof {
            s.window.min(MAX_PAYLOAD).min(buf.len())
        } else {
            0
        };
        if max == 0 {
            // Only polled for writing here; a write error closes the stream
            // in flush(). Reading waits for the window/OpenOk (a hang-up
            // must not drop data the client sent before it), and after EOF
            // there is nothing left to read.
            return;
        }
        match s.sock.read(&mut buf[..max]) {
            Ok(0) => {
                s.local_eof = true;
                self.send(id, Kind::Shutdown, b"");
                self.flush(id);
            }
            Ok(n) => {
                s.window -= n;
                self.send(id, Kind::Data, &buf[..n]);
            }
            Err(e) if e.kind() == ErrorKind::WouldBlock || e.kind() == ErrorKind::Interrupted => {}
            Err(_) => self.close(id),
        }
    }

    /// Write queued peer data to the local socket and return credit.
    fn flush(&mut self, id: u32) {
        let Some(s) = self.streams.get_mut(&id) else {
            return;
        };
        let mut failed = false;
        while !s.out.is_empty() {
            match s.sock.write(&s.out) {
                Ok(0) => break,
                Ok(n) => {
                    s.out.drain(..n);
                    s.unacked += n;
                }
                Err(e)
                    if e.kind() == ErrorKind::WouldBlock || e.kind() == ErrorKind::Interrupted =>
                {
                    break
                }
                Err(_) => {
                    failed = true;
                    break;
                }
            }
        }
        if failed {
            self.close(id);
            return;
        }
        let credit = if s.unacked >= CREDIT_STEP || (s.out.is_empty() && s.unacked > 0) {
            std::mem::take(&mut s.unacked)
        } else {
            0
        };
        if s.peer_eof && s.out.is_empty() {
            let _ = s.sock.shutdown(std::net::Shutdown::Write);
        }
        let done =
            s.out.is_empty() && (s.state == StreamState::Closing || (s.local_eof && s.peer_eof));
        if done {
            self.streams.remove(&id);
        } else if credit > 0 {
            self.send(id, Kind::Credit, &(credit as u32).to_le_bytes());
        }
    }

    fn close(&mut self, id: u32) {
        if self.streams.remove(&id).is_some() {
            self.send(id, Kind::Close, b"");
        }
    }
}

fn pollfd(fd: i32, events: libc::c_short) -> libc::pollfd {
    libc::pollfd {
        fd,
        events,
        revents: 0,
    }
}

fn bind(rule: &Listen) -> io::Result<UnixListener> {
    match fs::symlink_metadata(&rule.path) {
        Ok(m) if m.file_type().is_socket() => fs::remove_file(&rule.path)?,
        Ok(_) => {
            return Err(io::Error::new(
                ErrorKind::AlreadyExists,
                format!("{} exists and is no socket", rule.path.display()),
            ))
        }
        Err(e) if e.kind() == ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let l = UnixListener::bind(&rule.path)
        .map_err(|e| io::Error::new(e.kind(), format!("{}: {e}", rule.path.display())))?;
    l.set_nonblocking(true)?;
    fs::set_permissions(&rule.path, fs::Permissions::from_mode(rule.mode))?;
    if let Some((uid, gid)) = rule.owner {
        std::os::unix::fs::chown(&rule.path, Some(uid), Some(gid))?;
    }
    Ok(l)
}

# NoX – NixOS on Xen

Tools, NixOS modules and (later) VM templates for a Qubes-like NixOS on Xen:
dom0 without network access to the guests, driver domains for network and
USB, apps in isolated guests.

License: MIT.

Status: early. Today it contains `nox-relay`; the general dom0/guest modules
and VM templates move here from the author's nixos-config over time.

## nox-relay

Carries Unix socket connections between two Xen domains over a single vchan
(shared-memory ring, no network). The guest offers the vchan to dom0
(`--role server`), dom0 connects (`--role client`). Many connections share
the ring (framing with per-stream flow control and half-close, see
`crates/nox-relay/src/proto.rs`).

Each side has rules (`crates/nox-relay/src/config.rs`):

```text
listen <service> <socket-path> [mode=0600] [owner=<uid>:<gid>]
serve  <service> <socket-path>
```

`listen` creates a local socket; each connection opens `<service>` at the
peer. `serve` lets the peer open `<service>`, connected to a local socket.
A peer reaches nothing but the services in the other side's `serve` list.

Libraries: links against `libxenvchan`; `nox-vchan-libs` packages just the
six Xen libraries it needs, so guests do not pull in the Xen tools.

### NixOS module

```nix
# flake input: nox.url = "github:23b00t/NoX";
imports = [ inputs.nox.nixosModules.relay ];

# guest
services.nox-relay.guest = {
  enable = true;
  listen.github-agent = { path = "/tmp/ssh-github-agent.sock"; owner = "1000:100"; };
};

# dom0
services.nox-relay.host = {
  enable = true;
  guests.coding = {
    domain = "coding-vm";
    serve.github-agent = "/home/nx/.ssh/agent/github.sock";
  };
};
```

## nox-rpc

qrexec-like calls between guests, mediated by dom0 over nox-relay. A guest
runs `nox-rpc <service> <target>`; `nox-rpcd` in dom0 knows the caller from
the socket the call arrives on (one per guest, never from the guest's
words), checks the policy (first match wins, no match = deny, `ask` = a
notification with buttons) and pipes the bytes to the target, where systemd
starts the service's handler as the guest user. dom0 calls guests itself
with `nox-rpc --dom0 <service> <guest>` (source `dom0`, reserved).

Built-in services: `copy` (`vm-copy <target> <files>`, lands in
`~/Incoming/<source>/`) and `app` (dom0 starts programs in the guest,
argv NUL-separated on stdin, as transient user units).

```nix
imports = [ inputs.nox.nixosModules.relay inputs.nox.nixosModules.rpc ];

# guest
services.nox-rpc.guest = {
  enable = true;
  apps = { enable = true; environment.WAYLAND_DISPLAY = "wprs-0"; };
};

# dom0
services.nox-rpc.host = {
  enable = true;
  guests = [ "coding" "chat" ];
  policy = [ { service = "copy"; action = "ask"; } ];
};
```

## Development

```sh
nix develop -c cargo test
nix build .#nox-relay
nix build .#nox-rpc
```

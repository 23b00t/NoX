| `nox input to <vm> [--bt]`, `nox input back [vm]` | `input-to …`, `input-back …` |
# NoX – NixOS on Xen

Tools, NixOS modules and roles for a Qubes-like NixOS on Xen: dom0 without
network access to the guests, driver domains for network and USB, apps in
isolated guests.

License: MIT.

Status: early. dom0 (Xen, desktop, tools), the VM schema with roles and an
app catalog, and the infrastructure VMs live here; a config is NoX plus
the machine's hardware plus its own domains.

## A config

```sh
nix flake init -t github:23b00t/NoX
```

gives `flake.nix` (one call of `nox.lib.mkSystems`), `vms.nix` (the
domains: `nox.vms.<name>` with role, label, apps, resources) and
`machines/` (hardware data and the machine's NixOS module). Every option,
the roles, the app catalog and the infrastructure VMs:
[docs/options.md](docs/options.md) (generated: `nix build .#options-doc`).

Settings that are yours, not NoX's, go into your config, e.g. in
`vms.nix`:

```nix
nox = {
  # every dev VM: git identity and SSH commit signing
  roles.dev.module = {
    programs.git.config = {
      user = {
        name = "Your Name";
        email = "you@example.org";
        signingkey = "ssh-ed25519 AAAA… you@example.org";
      };
      gpg.format = "ssh";
      commit.gpgsign = true;
    };
    # your LazyVim config instead of the upstream starter
    services.ide.lazyvimRepo = "https://github.com/<you>/lazyvim.git";
  };
  # every VM: time zone and locale (NoX: UTC, en_US.UTF-8)
  vmModule.time.timeZone = "Europe/Berlin";
  # the builder (nox.infra.builder.enable): the repo it builds
  vms.builder.module.nox.builder.repoUrl = "https://github.com/<you>/<config>";
};
# dom0: niri's keyboard (NoX: us)
# nox.desktop.keyboard = { layout = "us"; variant = "altgr-intl"; };
```

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

## nox (CLI)

One command for dom0. For now a thin wrapper: each subcommand runs the
script that does the work (from the system configuration, on PATH) and
passes its output and exit code through.

| Command | Runs |
|---|---|
| `nox` | `manage-vms status --running` |
| `nox list\|ls [--running] [--stale] [--group g]` | `manage-vms status …` |
| `nox start\|stop\|restart [vm…] [--running] [--stale] [--group g]` | `manage-vms <action> …` |
| `nox start\|restart --fresh <vm…>` | `manage-vms <action> --fresh …`: disposable VMs (registry `disposable`) with their volume images set aside (`*.pre-fresh`) |
| `nox disp [cmd…]` | `vm-disp`: start the ad-hoc disposable `disp`, open `cmd` (default foot) in it |
| `nox backup <vm…>\|--all`, `--full [--level n] <target…>\|--all`, `restore [--full] [--from gen] …`, `disks`, `list`, `prune home\|full --keep n [-n] [vm…]` | `vm-backup …` (arguments checked by nox; external LUKS disk on `disp-backup`, `nox backup help`) |
| `nox run <vm> <program> [args]` | `vm-run <vm> …` (GUI over wprs) |
| `nox exec <vm> <cmd> [args]` | `vm-run -c <vm> …` (a terminal window in the VM runs the command and stays open; the builder: SSH in this terminal) |
| `nox ssh builder [ssh args]` | `ssh builder …` (only the builder has sshd; the other VMs: `nox exec`) |
| `nox clip copy\|paste` | `vm-clip copy\|paste` |
| `nox copy [-m] [-n] <vm> <paths…>` | `cp-vm …` |
| `nox update [--all] [--switch] [--machine m] [--branch b]` | `dom0-update …` (`--all`: `update-all …`) |
| `nox usb list\|attach\|detach\|allow-input …` | `vm-usb …` |
| `nox input to <vm> [--bt]`, `nox input back [vm]` | `input-to …`, `input-back …` |
| `nox doctor` | `vm-doctor` (smoke test of the running system) |
| `nox rollback <vm> [--gen n\|--reset]` | `vm-rollback …`: runner of an older system generation as the VM's `current` |
| `nox rollback --data <vm>`, `nox snapshot <vm>` | `vm-rollback --data`, `vm-snapshot` (copy of a stopped VM's images) |
| `nox gc [--keep n] [-n]` | `vm-gc …` (old system generations, then GC; default keeps 3) |

`nox help <command>`, `nox <command> --help` and `nox <command>… help` (e.g.
`nox backup restore help`) describe each one. Bash
completion knows the VM names from `/etc/nox/registry.json`:

```nix
imports = [ inputs.nox.nixosModules.cli ];
programs.nox = {
  enable = true;
  vms = [ "coding" "chat" ];
};
```

## Development

```sh
nix develop -c cargo test
nix build .#nox-relay
nix build .#nox-rpc
nix build .#nox-cli
```

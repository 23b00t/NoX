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
    # zsh (NoX: plain zsh with completion, suggestions, highlighting)
    services.zsh-env = {
      extraAliases.n = "nvim";
      plugins = [ "zsh-users/zsh-autosuggestions" ]; # antidote
      ohMyPoshTheme = "montys.omp.json";
    };
    # zellij (NoX: zellij's defaults): config.kdl, layouts/, plugins/;
    # `theme "nox"` in config.kdl follows the theme below
    services.zellij-env.configDir = ./zellij;
  };
  # every VM: time zone and locale (NoX: UTC, en_US.UTF-8)
  vmModule.time.timeZone = "Europe/Berlin";
  # the builder (nox.infra.builder.enable): the repo it builds; a private
  # repo by SSH with the builder's deploy key (cat its
  # /var/lib/builder/deploy-key.pub, add it at GitHub as a read-only deploy key)
  # vms.builder.module.nox.builder.repoUrl = "git@github.com:<you>/<config>.git";
  vms.builder.module.nox.builder.repoUrl = "https://github.com/<you>/<config>";
  # theme of dom0 and every VM (NoX: nox, organic logo, dark, moon and
  # stars; themes: nox, tokyo-night, catppuccin-mocha, dracula, black;
  # wallpaper and lock screen are rendered from branding/templates)
  # theme = { name = "tokyo-night"; flavor = "neon"; lock.decor = [ ]; };
  # trust labels (a VM's `label`): the border color of its windows in dom0;
  # labels dom0, unknown, sys, dev, personal, social, untrusted, vault, anon,
  # each theme has a color for every one, single ones can be overridden
  # theme.labels = { social = "d1bfff"; untrusted = "ff9e64"; };
};
# dom0: niri's keyboard (NoX: us)
# nox.desktop.keyboard = { layout = "us"; variant = "altgr-intl"; };
# dom0: own wallpaper on one output, the rendered one on the others
# (wpaperd's `any` section); an own lock image turns the lock ring back into
# the plain one (shown while typing, filled)
# nox.desktop.wpaperd.settings."DP-2".path = "${./wallpapers/mine.jpg}";
# nox.desktop.swaylock.image = ./wallpapers/lock.jpg;
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

## nox-hwcheck

Can a machine run NoX, and which devices go where? `nox-hwcheck` (in dom0,
or `nix run github:23b00t/NoX#nox-hwcheck` on a live system) prints a
report with traffic lights: VT-x/AMD-V and VT-d/AMD-Vi, UEFI, Secure Boot,
interrupt remapping, RAM (≥32 GB green, ≥16 orange), the largest disk
(≥500 GB green, ≥250 orange), IOMMU groups, GPUs (a second one for
passthrough), network cards for sys-net, USB controllers for sys-usb,
whether keyboard and mouse only come over USB, CPU threads and P/E cores,
shared interrupt lines and firmware warnings. It changes nothing.

`nox-hwcheck --nix` prints a block for the config's `machines/hardware.nix`
(format of `template/machines/hardware.nix`): profile, PCI paths, the
drivers dom0 must not load, the USB devices with a suggested policy.
Review it: `dom0Pv` and the owners are decisions, not hardware.

Run it with `sudo`. In a running dom0 under Xen it reads Xen's view (`xl
info`, `xl dmesg`); dom0 sees neither the IOMMU groups nor the P/E cores
nor the USB devices' classes (they are in sys-usb), so a live system gives
the complete picture.

## Installer

The installer ISO is a NixOS minimal live system with `nox-install`,
`nox-hwcheck`, disko, git/ssh, neovim/helix/nano, cryptsetup and
NetworkManager (`nmtui`); the kernel boots with the IOMMU on, so
`nox-hwcheck` sees the IOMMU groups. Build it one of two ways:

- **On a NoX machine** (dom0 builds nothing, the builder does):
  `nox update --iso <vm>`, e.g. `nox update --iso disp`. The builder
  builds the config's `installer-iso` (NoX as pinned in the config's
  flake.lock, from the branch's signed HEAD like a system; `--branch b` for
  another one) and streams it from its store through the broker straight
  to the VM, like `nox copy builder <vm>` (the VM is started if it is off
  and stays running): `~/Incoming/builder/nox-installer.iso` there.
  Nothing goes into dom0's store or onto a disk on the way, and the builder
  deletes the ISO once the VM has it (if the copy fails it stays in the
  builder's store until its GC, so another `--iso` doesn't build it again);
  the build inputs are left to the builder's GC. The builder's copy rule is
  `outgoing = "ask"`; dom0's own call needs no question.
- **On a plain NixOS (or any Nix) machine:**
  `nix build github:23b00t/NoX#installer-iso`, the ISO is in
  `result/iso/`.

Write it to a stick (`dd`, in the VM the stick is attached to), boot it,
then `sudo nox-install`. It guides through eight steps, Ctrl-C aborts any
time:

1. network (`nmtui` if there is none)
2. the `nox-hwcheck` report
3. the config: its git URL and branch; for an SSH URL a key from the stick
   or a new one, whose public part you register at GitHub before it clones
   to `/tmp/nixos-config`
4. the host: one of `machines/*`, or a new name: then it writes
   `machines/<host>/hardware-configuration.nix` (without file systems) and
   `machines/<host>/hwcheck.nix` (`nox-hwcheck --nix`), opens the editor
   (flake.nix, hardware.nix, `nox.disk.device`) and commits + pushes
   unsigned: sign it again later, else a builder doesn't take it
5. the disk from the host's `nox.disk.device`: type its name, disko erases
   it and asks the LUKS passphrase
6. `nixos-install` (builds the whole machine locally)
7. the user's password (`passwd` in the new system; none is in the config)
8. the config clone into `/home/<user>/nixos-config` (and, if you like, the
   SSH key), then reboot

`nox-install --dry-run` runs steps 1-4 and prints the commands of 5-8;
`--config URL`, `--branch B` and `--host H` skip those questions.

The disk layout is NoX's module `nox.disk`: `nox.disk.device =
"/dev/disk/by-id/…"` gives GPT, ESP 1 GB (`/boot`), the rest LUKS2 with
ext4 (`/`, waits for the passphrase without a timeout), no swap (zram).
disko derives `fileSystems` and the LUKS device from it, so set it only on a
machine installed this way and leave those out of its
hardware-configuration; without it nothing changes.

## nox (CLI)

One command for dom0. `doctor`, `backup`, `manage-vms` and `vm-run` are built in
(their old names are links to nox); the other subcommands run the script
that does the work (from the system configuration, on PATH) and pass its
output and exit code through. The built-in tools read their data from
`/etc/nox/registry.json`, which Nix writes.

| Command | Runs |
|---|---|
| `nox` | `manage-vms status --running` (built in: src/manage.rs) |
| `nox list\|ls [--running] [--stale] [--group g]` | `manage-vms status …` |
| `nox start\|stop\|restart [vm…] [--running] [--stale] [--group g]` | `manage-vms <action> …` |
| `nox start\|restart --fresh <vm…>` | `manage-vms <action> --fresh …`: disposable VMs (registry `disposable`) with their volume images set aside (`*.pre-fresh`) |
| `nox disp [--from <vm>] [cmd…]` | `vm-disp`: start the ad-hoc disposable `disp` (with `--from`: the VM's own disposable `disp-<vm>`, registry `hasDisposable`), open `cmd` (default foot) in it; a disposable that is down starts only if Xen has its boot memory free |
| `nox backup [--level n] <target…>\|--all`, `restore [--from gen] <target…>\|--all`, `disks`, `list`, `prune --keep n [-n] [target…]` (whole disks; `--all` = registry `backup` + dom0) | in nox (crates/nox-cli/src/backup.rs; external LUKS disk on `disp-backup`, `nox backup help`) |
| `nox run <vm> <program> [args]` | `vm-run <vm> …` (GUI over wprs; built in: src/run.rs) |
| `nox exec <vm> <cmd> [args]` | `vm-run -c <vm> …` (a terminal window in the VM runs the command and stays open; the builder: SSH in this terminal) |
| `nox ssh builder [ssh args]` | `ssh builder …` (only the builder has sshd; the other VMs: `nox exec`) |
| `nox clip copy\|paste` | `vm-clip copy\|paste` |
| `nox copy [-m] [-n] [--max b] [<from-vm>] <to-vm> <paths…>` | `nox-copy …` (lands in `~/Incoming/<source>` in the target, merging into folders already there; never overwrites) |
| `nox printers [--menu]` | `nox-printers`: IPP printers in the local network (sys-print scans what sys-net names); `--menu`: rofi, the chosen address to the clipboard |
| `nox update [--all] [--switch] [--machine m] [--branch b]` | `dom0-update …` (`--all`: `update-all …`) |
| `nox update --iso <vm> [--branch b]` | `dom0-update --iso <vm> …` (installer ISO from the builder straight to the VM, see "Installer") |
| `nox mic on\|off\|status` | dom0's microphone for the VMs with the registry field `microphone` (nox-pulse-mic, dom0/vm-audio.nix): on until `off` or the next boot, `off` ends running recordings; waybar shows "VM" in red while on |
| `nox usb list\|attach\|detach\|allow-input …` | `vm-usb …` |
| `nox input to <vm> [--bt]`, `nox input back [vm]` | `input-to …`, `input-back …` |
| `nox lab list\|attach\|detach [vm]` | `vm-lab status\|attach\|detach …`: a labTarget VM on sys-firewall's lab bridge while kali tests it |
| `nox doctor [-v\|-vv]` | built in (src/doctor.rs; `vm-doctor` is a link to nox): smoke test of the running system; prints the result line and the failures with their details, `-v` every check, `-vv` every check with details |
| `nox doctor --ack` | the kernel / `xl dmesg` errors the runs reported become known noise of this machine (no longer a failure; list in `~/.local/state/vm-doctor/errors-known`, delete a line to forget it) |
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

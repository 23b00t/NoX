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
niri is the default compositor; another one: [docs/compositor.md](docs/compositor.md).

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
  # /var/lib/builder/deploy-key.pub, add it at GitHub as a read-only deploy key);
  # `nox update` (new inputs) needs the SSH URL and the bump key: its
  # /var/lib/builder/bump-key.pub as a deploy key with write access and as
  # `builder-<machine> namespaces="git" <key>` in vms/builder/bump-signers;
  # it also needs `builderKeys = ./vms/builder;` in mkSystems (flake.nix),
  # that directory with at least `allowed-signers` (the keys whose signed
  # commits it builds). nox-install makes the builders' keys and writes
  # their public parts there (README "Installer", step 5)
  # vms.builder.module.nox.builder.repoUrl = "git@github.com:<you>/<config>.git";
  vms.builder.module.nox.builder.repoUrl = "https://github.com/<you>/<config>";
  # theme of dom0 and every VM (NoX: nox, organic logo, dark, moon and
  # stars; themes: nox, tokyo-night, catppuccin-mocha, dracula, black;
  # wallpaper and lock screen are rendered from branding/templates)
  # theme = { name = "tokyo-night"; flavor = "neon"; lock.decor = [ ]; };
  # trust labels (a VM's `label`): the border color of its windows in dom0;
  # labels dom0, unknown, sys, dev, personal, social, untrusted, vault, anon,
  # config (the config VM: your signing key),
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
    serve.github-agent = "/home/user/.ssh/agent/github.sock";
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

`nox-hwcheck --nix` prints the hardware of one machine (format of
`template/machines/nox/hardware.nix`; nox-install writes it there):
profile, PCI paths, the drivers dom0 must not load, the USB devices with a
suggested policy.
Review it: `dom0Pv` and the owners are decisions, not hardware.

Run it with `sudo`. In a running dom0 under Xen it reads Xen's view (`xl
info`, `xl dmesg`); dom0 sees neither the IOMMU groups nor the P/E cores
nor the USB devices' classes (they are in sys-usb), so a live system gives
the complete picture.

## Installer

The installer ISO is a NixOS minimal live system with `nox-install`,
`nox-hwcheck`, disko, git/ssh, neovim/helix/nano, cryptsetup,
NetworkManager (`nmcli`, `nmtui`) and lynx; the kernel boots with the IOMMU
on, so `nox-hwcheck` sees the IOMMU groups. If the live system hangs at
boot (seen with an NVIDIA GPU), start it with the GRUB entry „nomodeset“.
Build it one of two ways:

- **On a NoX machine** (dom0 builds nothing, the builder does):
  `nox rebuild --iso <vm>`, e.g. `nox rebuild --iso disp`. The builder
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

**Verify a release.** Releases are signed with the key `nox-release`
(`release/allowed-signers`; compare its fingerprint with the one outside
the repo, e.g. the maintainer's GitHub profile: a key that only stands in
the repo proves nothing). Until the first tag exists, `main` is the only
source. Either build from the signed tag:

```sh
git clone https://github.com/23b00t/NoX && cd NoX
git -c gpg.ssh.allowedSignersFile=release/allowed-signers verify-tag vX.Y.Z
nix build github:23b00t/NoX/vX.Y.Z#installer-iso
```

or take the ISO from GitHub Releases (with `SHA256SUMS` and
`SHA256SUMS.sig`, in one directory, `release/allowed-signers` from the tag):

```sh
ssh-keygen -Y verify -f release/allowed-signers -I nox-release -n nox-release -s SHA256SUMS.sig < SHA256SUMS
sha256sum -c SHA256SUMS
```

Maintainers: [docs/release.md](docs/release.md).

Write it to a stick (`dd`, in the VM the stick is attached to), boot it,
then `sudo nox-install`. It guides through nine steps, Ctrl-C aborts any
time:

1. network: the addresses (`ip -brief address`) and a test against
   github.com; with a connection (e.g. LAN) on, or a shell first (`ip a`,
   `ping`, `nmcli`; `exit` returns). Without one a WLAN by SSID (also a
   hidden one, `nmcli --ask device wifi connect <ssid> [hidden yes]`),
   `nmtui`, the shell, or on without
2. the `nox-hwcheck` report, paged with `less`
3. the config, cloned to `/tmp/nixos-config`, or a new one (below). Its
   git URL (or a path, e.g. a git bundle on the stick) and branch. A
   GitHub repo is cloned over https first (an SSH URL is rewritten), so a
   public config needs no key; only if that fails (private repo) a key
   from the stick or a new one, registered at GitHub as a deploy key (it
   offers GitHub's page in lynx; there is no copy and paste on the
   console: in lynx's "Key" field Ctrl-X i inserts a file, Ctrl-X e opens
   the field in the editor), and the clone over SSH. GitHub's host key is
   pinned in the installer, as in the builder.
   **Nothing of the clone runs before its HEAD is checked:** it shows the
   keys of the config's `allowed-signers` (principal and fingerprint), you
   confirm they are yours, and HEAD must be signed by one of them (or be a
   builder's flake.lock bump on top of such a commit, as the builder
   checks it). An unsigned HEAD stops the installation
4. the host: one of the machines (directories under `machines/` with a
   `hardware-configuration.nix`), or a new name: then it writes
   `machines/<host>/hardware-configuration.nix` (without file systems) and
   the `nox-hwcheck --nix` block: as `machines/<host>/hardware.nix` in the
   template's layout (flake.nix finds the machines itself, the
   configuration of another machine is copied as the start), else as
   `hwcheck.nix` for your own `machines/hardware.nix`; then the editor.
   Without `nox.disk.device` it lists the disks, asks for one and writes
   `machines/<host>/disk.nix` (the template imports it; else add it to the
   machine's imports)
5. the builders' keys (with a builder on the machine): made here instead
   of at the builders' first boot, so dom0 trusts its builder from the first
   boot on and the first `nox update` works. The public parts go into the
   config's `builderKeys` directory: `signing-key-<host>.pub`,
   `image-key-<host>.pub`, `image-key-<builder>-<host>.pub` (group builders),
   `ssh-key-<builder>-<host>.pub` (dom0's login key; a `hostSSHKey` in
   vms.nix would win, it asks you to delete it) and the `builder-<host>` line
   of `bump-signers`. One commit with the new machine and the keys, signed
   with your key (from the stick; without it unsigned: sign it later from
   your machine, `git commit --amend -S`, else the builder doesn't build
   it), pushed over SSH (a deploy key with write access). It shows the
   builder's deploy key (read, a private repo) and bump key (write, `nox
   update`) for GitHub and offers the page in lynx.
   If the config runs the Whonix-Gateway on this machine, it asks whether
   to fetch its image during the installation (step 8)
6. the disk from the host's `nox.disk.device`: type its name, disko erases
   it and asks the LUKS passphrase
7. the minimal system (`nox.install.minimal`): dom0, sys-net, sys-usb,
   sys-firewall, the builder and the group builders, the config VM (plus
   the Whonix-Gateway if wanted); every other domain is left out. Built
   into the new disk's store from `nixosConfigurations.<host>.noxInstall`,
   then `nixos-install --system`. Then the builders' state volumes
   (`/var/lib/microvms/<builder>/builder.img`, ext4 with their keys; the
   size from the VM's `microvm.volumes`) and dom0's login keys
   (`~/.ssh/<builder>-vm`), and the config as a git bundle in
   `/var/lib/nox/seed` (also when the push failed)
8. the Whonix-Gateway image, if wanted: the CLI archive of the current
   stable release (asked from whonix.org at install time: the version its
   KVM page downloads, wiki template `Version_KVM`). Its signature has to
   be good, by Whonix' signing key `916B8D99C38EAF5E8ADC7A2A8D66066A2EEACCDA`
   (`derivative.asc` is fetched, its fingerprint is pinned in NoX; an
   expired or revoked key stops it) and for this file name (notation
   `file@name`). The version must not be lower than `whonixMinVersion` in
   NoX (against a downgrade; raised at each release). Then the Gateway is
   converted to raw at the image path of the config (default
   `/home/<nox.user>/vm-images/whonix/`) and `xen-image-setup
   whonix-gateway` run in the new system. Tor still needs
   `DisableNetwork 0` after the first boot (see the Whonix steps of your
   config's README). If this step fails, the installer skips it and
   continues; set it up by hand later
9. the user's password (`passwd` in the new system; none is in the config),
   then reboot

After the first boot `nox update` builds and installs the rest on the
builder.

**A new config** (step 3 with an empty URL): from the template in the ISO,
NoX pinned in its flake.lock to the revision the ISO is built from, with
the nixpkgs and disko the ISO is built with (the template's nixpkgs
follows NoX's; `template/flake.lock` only pins microvm.nix and wprs, a
release refreshes it with `nix flake update` in `template/` and raises
`whonixMinVersion` to the current Whonix stable release). It
asks where the config lives: only on this machine in the config VM
(no account; `nox.builder.source = "local"`), on GitHub (an empty repo you
created; public: the builder fetches over https), or both (the config VM
pushes to GitHub); your name and email, and your signing key (from the
stick or a new one, into `allowed-signers`). In step 4 the host name, your
user name, the editor of the config VM, keyboard layout and time zone, and
the VMs as profiles: browser, vault, office, chat, media, dev, windows,
tor (Whonix), printing (sys-print), gaming (Steam, only with a second GPU,
in an own store image, see "Gaming"). The branch is named after the host
(dom0-update fetches that one). The first commit is signed with your key.

Every machine has exactly one config VM (role `config`, label `config`;
512 MB, up to 2 GB for a GUI editor, 2 GB home; the registry asserts it).
It gets the repo and the key at the first login: dom0's user unit
`nox-config-seed` copies `/var/lib/nox/seed` into it (dom0's own copy, no
question) and deletes it; in the VM `nox-config` takes them in
(`~/config`, `~/.ssh/nox-signing-key`). With GitHub it pushes through
dom0's GitHub agent (`githubAgent = true`), a local config has no network.

`nox-config` in the config VM: `status`, `diff`, `commit <message>`
(signed), `push` (to GitHub, if the config has a remote), `pull` (the
bundles dom0 copied in), `edit` (the editor of `nox.configVm.editor`: nano,
helix, nvim, or kate, gnome-text-editor, vscodium, zed as windows over
wprs). Every commit (also with lazygit) writes `~/outbox/config.bundle`.
With `nox.builder.source = "local"` `nox update` takes it from there (nox
pull's rpc, the config VM is started if it is off) and hands it to the
builder on stdin (`builder-build --bundle`); the builder checks the
signature as for a fetched repo. A flake.lock bump comes back the same way:
dom0 copies the builder's `bump.bundle` into the config VM, where
`nox-config` fast-forwards the branch.

`nox-install --dry-run` runs steps 1-5 (without commit and push) and
prints the commands of 6-9; `--config URL`, `--branch B` and `--host H`
skip those questions, `--whonix-from DIR` takes the Whonix files (archive,
`.asc`, `derivative.asc`) from DIR instead of downloading them (the version
is the archive's).

The disk layout is NoX's module `nox.disk`: `nox.disk.device =
"/dev/disk/by-id/…"` gives GPT, ESP 1 GB (`/boot`), the rest LUKS2 with
ext4 (`/`, waits for the passphrase without a timeout), no swap (zram).
disko derives `fileSystems` and the LUKS device from it, so set it only on a
machine installed this way and leave those out of its
hardware-configuration; without it nothing changes.

## Gaming

A VM with `role = "gaming"` runs Steam in a gamescope session on the
second GPU (`gpu = true`, the GPU from `hardware.nix`, which
`nox-hwcheck --nix` writes): an HVM guest (PCI passthrough with a PV dom0
needs it), its own base without common-config, the autologin on tty1
runs the session (`nox.gaming.session`, `gamescopeArgs`, `steamArgs`;
output in `~/session.log`). Sound over pipewire, Bluetooth for gamepads
(`nox exec <vm> pad-pair` pairs them without a keyboard), keyboard and
mouse over USB/IP from sys-usb (`nox usb attach <device> <vm>`). A
poweroff from inside Steam keeps the VM off. Steam is unfree, the role
allows it by name: the VM needs an own store image (`storeGroup = null`)
or an unfree store group.

`cpuPool = [ … ]` gives the VM its own CPUs while it runs: dom0 moves them
from Pool-0 into a cpupool named after the VM and back after the stop.
nox-install proposes the P-cores of a hybrid CPU, else the upper half;
check the numbers with `xl info -n` after the first boot.

The GPU driver is the config's, in the VM's module. NVIDIA, the tested
setup:

```nix
# vms/steam.nix
{ pkgs, config, ... }:
let
  # SeaBIOS must not run the card's VGA option ROM (it hangs there)
  optionRomExecOff = pkgs.runCommand "pci-optionrom-exec-0" { } "printf '\\000' > $out";
in
{
  nox.unfree = [ "nvidia-x11" "nvidia-settings" ];
  # The driver writes config space registers pciback filters otherwise
  microvm.xen.extraConfig = ''
    pci_permissive = 1
    device_model_args_hvm = [ "-fw_cfg", "name=etc/pci-optionrom-exec,file=${optionRomExecOff}" ]
  '';
  services.xserver.videoDrivers = [ "nvidia" ];
  boot = {
    kernelParams = [ "nvidia-drm.modeset=1" "pci=realloc=on" "pci=assign-busses" ];
    extraModprobeConfig = "options nvidia-drm modeset=1 fbdev=1";
    blacklistedKernelModules = [ "nouveau" ];
  };
  hardware.nvidia = {
    modesetting.enable = true;
    open = true; # Turing and newer
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    powerManagement.enable = false;
  };
  # gamescope picks the vendor library itself; with NVIDIA set it
  environment.sessionVariables.__GLX_VENDOR_LIBRARY_NAME = "nvidia";
}
```

AMD and Intel GPUs are untested; mesa comes with `hardware.graphics` (on
in the role), so they should need no driver module.

## nox (CLI)

One command for dom0. `doctor`, `backup`, `list`/`start`/`stop`/`restart` and
`run`/`exec` are built in; the other subcommands run the script
that does the work (from the system configuration, on PATH) and pass its
output and exit code through. The built-in tools read their data from
`/etc/nox/registry.json`, which Nix writes.

| Command | Runs |
|---|---|
| `nox` | `nox list --running` |
| `nox list\|ls [--running] [--stale] [--group g]` | built in (src/manage.rs): state of the VMs |
| `nox start\|stop\|restart [vm…] [--running] [--stale] [--group g]` | built in (src/manage.rs); a (re)started VM gets its tray apps and session windows again |
| `nox start\|restart --fresh <vm…>` | disposable VMs (registry `disposable`) with their volume images set aside (`*.pre-fresh`) |
| `nox disp [--from <vm>] [cmd…]` | `vm-disp`: start the ad-hoc disposable `disp` (with `--from`: the VM's own disposable `disp-<vm>`, registry `hasDisposable`), open `cmd` (default foot) in it; a disposable that is down starts only if Xen has its boot memory free |
| `nox backup [--level n] <target…>\|--all`, `restore [--from gen] <target…>\|--all`, `disks`, `list`, `prune --keep n [-n] [target…]` (whole disks; `--all` = registry `backup` + dom0) | in nox (crates/nox-cli/src/backup.rs; external LUKS disk on `disp-backup`, `nox backup help`) |
| `nox run <vm> <program> [args]` | built in (src/run.rs): GUI over wprs; a stopped VM is started first |
| `nox exec <vm> <cmd> [args]` | built in (src/run.rs): a terminal window in the VM runs the command and stays open; the builder: SSH in this terminal |
| `nox ssh builder [ssh args]` | `ssh builder …` (only the builder has sshd; the other VMs: `nox exec`) |
| `nox clip copy\|paste` | `vm-clip copy\|paste` |
| `nox copy [-m] [-n] [--max b] [<from-vm>] <to-vm> <paths…>` | `nox-copy …` (lands in `~/Incoming/<source>` in the target, merging into folders already there; never overwrites) |
| `nox printers [--menu]` | `nox-printers`: IPP printers in the local network (sys-print scans what sys-net names); `--menu`: rofi, the chosen address to the clipboard |
| `nox update [--all] [--switch] [--machine m] [--branch b]` | `dom0-update --bump …` (`--all`: `update-all --bump …`): the builder updates the flake inputs, commits flake.lock signed with its bump key and pushes it, then builds (nothing new: builds anyway) |
| `nox rebuild [--switch] [--machine m] [--branch b]` | `dom0-update …`: build the branch as it is |
| `nox rebuild --iso <vm> [--branch b]` | `dom0-update --iso <vm> …` (installer ISO from the builder straight to the VM, see "Installer") |
| `nox mic on\|off\|status` | dom0's microphone for the VMs with the registry field `microphone` (nox-pulse-mic, dom0/vm-audio.nix): on until `off` or the next boot, `off` ends running recordings; waybar shows "VM" in red while on |
| `nox usb list\|attach\|detach\|allow-input …` | `vm-usb …` |
| `nox input to <vm> [--bt]`, `nox input back [vm]` | `input-to …`, `input-back …` |
| `nox lab list\|attach\|detach [vm]` | `vm-lab status\|attach\|detach …`: a labTarget VM on sys-firewall's lab bridge while kali tests it |
| `nox doctor [-v\|-vv]` | built in (src/doctor.rs): smoke test of the running system (starts nothing and only reads, except the clipboard round trip, which restores both clipboards); prints the result line and the failures with their details, `-v` every check, `-vv` every check with details |
| `nox doctor --ack` | the kernel / `xl dmesg` errors the runs reported become known noise of this machine (no longer a failure; list in `~/.local/state/nox-doctor/errors-known`, delete a line to forget it) |
| `nox doctor --mark` | marks the kernel / `xl dmesg` errors shown so far as seen: only this run moves the marker, every other run (`-v` too) shows the errors since the last `--mark` (first run: since boot) |
| `nox rollback <vm> [--gen n\|mark \| --mark \| --unmark \| --reset]` | `vm-rollback …`: runner of an older system generation (or the VM's mark) as its `current`, VM restarted; holds over reboots until another system is activated (update, rebuild) or `--reset`. `--mark`: the VM's current runner as known good, one per VM, survives `nox gc`; `--unmark` drops it again (a rollback to the mark holds until `--reset`). `nox list` (ROLLBACK) and `nox doctor` (WARN) show rolled back VMs. Configuration only; data comes back with `nox backup restore` |
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

## Limits

NoX 0.1.0 does not protect against physical access to the machine ("evil
maid"). There is no Secure Boot and no measured boot, and the ESP (`/boot`:
systemd-boot, Xen, kernel, initrd) is not encrypted. Someone with brief access
can replace the kernel or initrd and capture the LUKS passphrase at the next
boot. `nox-hwcheck` accordingly asks you to switch Secure Boot off.

Not now, because Xen's [host EFI Secure Boot is only "experimental"][xen-support]
in its upstream support statement, and [lanzaboote's Xen support][lanza-xen] is
an open pull request, not part of a release. Until then: do not leave the
machine unattended where others have access, and shut it down instead of
suspending when it is out of your hands (the LUKS key is then not in RAM).

Planned after 0.1.0: measuring Xen, kernel and initrd with the TPM, in the
style of Qubes Anti Evil Maid.

The standard disk layout (`nox.disk`) opens LUKS with `allowDiscards = true`:
TRIM keeps the SSD fast, but whoever reads the raw disk can see which blocks
are in use (not their content). This is a deliberate trade-off. A damaged LUKS
header loses the whole disk even with the passphrase, so keep a header backup
off the machine: `sudo cryptsetup luksHeaderBackup
/dev/disk/by-partlabel/disk-main-root --header-backup-file <file on a stick>`.
Store it safely: with an old passphrase it still opens the disk after a
passphrase change.

[xen-support]: https://xenbits.xen.org/docs/unstable/SUPPORT.html
[lanza-xen]: https://github.com/nix-community/lanzaboote/pull/387

## Development

```sh
nix develop -c cargo test
nix build .#nox-relay
nix build .#nox-rpc
nix build .#nox-cli
```

### Checks of a config

`mkSystems` returns `checks.<system>` with two eval-only checks per
machine; the config's flake passes them on (`checks` next to
`nixosConfigurations` and `packages`, as in `template/flake.nix`). Neither
builds a system:

- `noxInstall-<host>`: the minimal installation nox-install installs
  (`nixosConfigurations.<host>.noxInstall { }`) evaluates; the check's
  output is its toplevel's drvPath.
- `registry-<host>`: the registry rules of `nixos/registry/rules.nix` hold
  for that machine: every domain has its own `index` (address, tap, MAC;
  dom0 has 254), short aliases are unique, and every VM's `uplink` runs on
  the machine. dom0 asserts the same rules, so a rebuild fails on them too;
  the check finds them in seconds without evaluating the system.

```sh
nix build .#checks.x86_64-linux.registry-<host>
nix build .#checks.x86_64-linux.noxInstall-<host>
```

`nix flake check` evaluates every check, and every system, in one process;
on a machine with little RAM build the checks one at a time.

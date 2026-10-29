# Xen dom0, shared by all machines (hp, xmg), on top of
# common-configuration.nix. Machine specifics come from the registry view
# (`hardware`, `hostProfile`) and machines/<name>/xen.nix.
# MicroVMs run as Xen PVH domUs via the microvm.nix fork (hypervisor = "xen").
{
  lib,
  pkgs,
  config,
  inputs,
  vmRegistry,
  ...
}:
let
  theme = import ../desktop/theme.nix {
    inherit lib;
    inherit (config.nox.desktop) theme;
  };
  nicPciPaths = vmRegistry.hardware.pci.devicePaths.nic or [ ];
  # NIC drivers blacklisted in dom0 (registry hostProfile), loaded again by
  # sys-net-rescue
  nicDrivers =
    (vmRegistry.hostProfile.blockedHostDrivers.nic or [ ])
    ++ (vmRegistry.hostProfile.blockedHostDrivers.wifi or [ ]);
  dom0TestAccess = vmRegistry.hostProfile.dom0TestAccess or null;
  # Kali image domain (machines/xmg/xen.nix), updated by update-all
  hasKali = config.services.xen-image-domains.domains ? kali;

  # Destroys the domain of MicroVM $1 if it is left behind: right away once
  # it is shut down (state `s`, e.g. `--ps--`: the guest is off, but the
  # domain still holds its PCI devices and memory, and the runner is gone;
  # sys-usb waited 30 s for nothing, xmg 2026-10-27), otherwise after 30 s
  destroyLeftoverDomain = pkgs.writeShellScript "destroy-leftover-domain" ''
    xl=${config.virtualisation.xen.package}/bin/xl
    dom="$1-vm"
    for _ in $(seq 60); do
      $xl domid "$dom" >/dev/null 2>&1 || exit 0
      case "$($xl list "$dom" 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR == 2 { print $5 }')" in
        *s*) break ;;
      esac
      sleep 0.5
    done
    echo "destroying leftover domain $dom: $($xl list "$dom" 2>/dev/null | tail -n 1)"
    $xl destroy "$dom" || true
  '';

  # Emergency exit if sys-net does not come up: give the WLAN card back to dom0
  sysNetRescue = pkgs.writeShellScriptBin "sys-net-rescue" ''
    set -u
    sudo systemctl stop microvm@sys-net
    # A domain left behind (e.g. paused/shut down) would keep the card
    if sudo xl domid sys-net-vm >/dev/null 2>&1; then
      sudo xl destroy sys-net-vm || true
    fi
    ${lib.concatMapStrings (path: ''
      sudo xl pci-assignable-remove -r ${path} || true
    '') nicPciPaths}
    # Blacklisted for autoloading only; an explicit modprobe works
    ${lib.concatMapStringsSep "\n" (m: "sudo ${pkgs.kmod}/bin/modprobe ${m}") nicDrivers}
    echo "WLAN is back in dom0, NetworkManager reconnects as before."
    echo "Start sys-net again later with: sudo systemctl start microvm@sys-net"
  '';

  # Copy rules of a VM (registry `copy`): sys-* VMs take files (e.g. a
  # WireGuard config for sys-vpn) but give none out
  copyRules = vm: {
    incoming = vm.copy.incoming or "ask";
    outgoing = vm.copy.outgoing or (if lib.hasPrefix "sys-" vm.name then "deny" else "ask");
  };

  # nox-rpcd's question (ask/warn) as a rofi dialog in the session: args
  # service source target ask|warn, for a copy also entries bytes names…
  # (from the sender, so escaped). warn: allowed only by typing the target's
  # name. No answer within 30 s = deny
  copyAsk = pkgs.writeShellScript "nox-ask" ''
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
    for s in "$XDG_RUNTIME_DIR"/wayland-*; do
      case "$s" in *.lock) continue ;; esac
      [ -S "$s" ] && export WAYLAND_DISPLAY="''${s##*/}" && break
    done
    esc() { ${pkgs.gnused}/bin/sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
    service="$1" source="$2" target="$3" mode="$4"
    shift 4
    msg="<b>$source</b> → <b>$target</b>: $service"
    if [ "$service" = copy ] && [ $# -ge 2 ]; then
      msg="$msg"$'\n'"$1 entries, $(${pkgs.coreutils}/bin/numfmt --to=iec "$2")B"
      shift 2
      for n in "$@"; do
        msg="$msg"$'\n'"  $(printf '%s' "$n" | esc)"
      done
    fi
    # The launcher theme has no message box: add one above the choices
    rofi() {
      timeout 30 ${pkgs.rofi}/bin/rofi -dmenu -theme /etc/xdg/rofi/config.rasi \
        -theme-str 'mainbox { children: [ "inputbar", "message", "listview" ]; }
          message { padding: 10px 14px; background-color: @main-bg; }
          textbox { horizontal-align: 0; background-color: @main-bg; text-color: @main-fg; }
          listview { lines: 2; }' \
        "$@"
    }
    if [ "$mode" = warn ]; then
      msg="<span foreground='${theme.color.urgent}'><b>$target is protected.</b></span>"$'\n'"$msg"$'\n'"Type <b>$target</b> to allow."
      answer="$(rofi -p "$target?" -mesg "$msg" </dev/null)" || exit 1
      [ "$answer" = "$target" ]
    else
      answer="$(printf 'Deny\nAllow\n' | rofi -i -no-custom -p "$service?" -mesg "$msg")" || exit 1
      [ "$answer" = Allow ]
    fi
  '';

  # Full system update, step 2 (step 1: `flake-bump` in nvim pushes new
  # inputs): dom0 from the builder, then the Debian systems inside the
  # Whonix images, which dom0-update does not touch (it only renews their
  # store disk). Domains that were off are started and stopped again.
  updateAll = pkgs.writeShellScriptBin "update-all" ''
    set -euo pipefail

    usage() {
      cat <<EOF >&2
    Usage: update-all [--switch] [--machine <name>] [--branch <branch>]

    Full update: dom0 from the builder (dom0-update with the same arguments;
    --switch activates right away), then the Whonix-Gateway and -Workstation
    (apt over Tor)${lib.optionalString hasKali ", then Kali (apt)"}. New flake inputs first with
    flake-bump in nvim. Only rebuild dom0: dom0-update.
    EOF
      exit 1
    }
    case "''${1:-}" in
      -h | --help) usage ;;
    esac

    # One password prompt for the whole run (dom0-update reuses it)
    if [ -t 0 ]; then
      sudo -v
      while sleep 60; do sudo -n -v 2>/dev/null || exit; done &
      keepalive=$!
    fi

    started=()
    cleanup() {
      local i
      for ((i = ''${#started[@]} - 1; i >= 0; i--)); do
        echo "update-all: stopping ''${started[i]} again" >&2
        sudo systemctl stop "xen-image@''${started[i]}" || true
      done
      [ -z "''${keepalive:-}" ] || kill "$keepalive" 2>/dev/null || true
    }
    trap cleanup EXIT

    dom0-update "$@"

    # Starts the domain if it is off (the Gateway waits for sys-firewall's uplink)
    ensure_running() {
      if ! systemctl is-active --quiet "xen-image@$1"; then
        echo "update-all: starting $1" >&2
        sudo systemctl start "xen-image@$1"
        started+=("$1")
      fi
    }

    # The domain's fixed rpc services (nox-rpc-in on the store disk; images
    # set up with xen-image-setup since the SSH removal)
    rpc_up() {
      [ "$(timeout 5 nox-rpc --dom0 ping "$1" </dev/null 2>/dev/null)" = ok ]
    }
    # Up to 2 min for a domain that is still booting (ensure_running just
    # started it: kali failed right away on the xmg, 2026-10-28)
    wait_rpc() {
      local t0=$SECONDS
      rpc_up "$1" && return 0
      echo "update-all: waiting for $1 to answer over rpc (boot)" >&2
      while [ $((SECONDS - t0)) -lt 120 ]; do
        sleep 2
        rpc_up "$1" && return 0
      done
      return 1
    }
    # apt-get --update full-upgrade as root in the guest, interactive
    apt_upgrade() {
      if ! wait_rpc "$1"; then
        echo "update-all: $1 does not answer over rpc after 2 min: look at its console (nox xen), or set up its rpc service once: xen-image-setup $1" >&2
        return 1
      fi
      nox-rpc --dom0 apt-upgrade "$1"
    }

    # sdwdate syncs only over working Tor; the Workstation's firewall stays
    # closed until then
    wait_tor() {
      echo "update-all: waiting for Tor in $1 (sdwdate)" >&2
      for _ in $(seq 60); do
        [ "$(timeout 10 nox-rpc --dom0 tor-ready "$1" </dev/null 2>/dev/null)" = ok ] && return 0
        sleep 5
      done
      echo "update-all: no Tor in $1 after 5 min" >&2
      return 1
    }

    # A running domain with a newer kernel on disk: offer a restart (pvgrub
    # boots the newest one); domains we started are stopped anyway
    offer_restart() {
      local newest="" running="" answer
      case " ''${started[*]} " in *" $1 "*) return 0 ;; esac
      read -r newest running < <(timeout 10 nox-rpc --dom0 kernel "$1" </dev/null 2>/dev/null)
      [ -n "$newest" ] && [ "$newest" != "$running" ] || return 0
      read -r -p "update-all: new kernel in $1, restart it now? [y/N] " answer
      case "$answer" in
        y | Y) sudo systemctl restart "xen-image@$1" ;;
      esac
    }

    ensure_running whonix-gateway
    wait_tor whonix-gateway
    echo "update-all: updating the Whonix-Gateway" >&2
    apt_upgrade whonix-gateway

    # The Workstation updates only in its sysmaint session (user/sysmaint
    # split, `user` has no sudo): boot that once, apt runs there, then
    # back to the normal session if it was running before (2026-10-15)
    ws=whonix-workstation
    ws_was_running=0
    if systemctl is-active --quiet "xen-image@$ws"; then
      ws_was_running=1
      echo "update-all: restarting $ws in its sysmaint session" >&2
      sudo systemctl stop "xen-image@$ws"
    else
      echo "update-all: starting $ws in its sysmaint session" >&2
    fi
    sudo install -d -m 0755 /run/xen-image
    sudo touch "/run/xen-image/$ws.sysmaint"
    sudo systemctl start "xen-image@$ws"
    [ "$ws_was_running" = 1 ] || started+=("$ws")
    wait_tor "$ws"
    echo "update-all: updating the Whonix-Workstation" >&2
    apt_upgrade "$ws"
    if [ "$ws_was_running" = 1 ]; then
      echo "update-all: back to the normal session of $ws" >&2
      sudo systemctl restart "xen-image@$ws"
    fi

    ${lib.optionalString hasKali ''
      # Kali (image domain, rolling): apt over sys-net, as root over rpc
      ensure_running kali
      echo "update-all: updating Kali" >&2
      apt_upgrade kali
      offer_restart kali
    ''}
    offer_restart whonix-gateway
    echo "update-all: done" >&2
  '';
  # Boot order (xen-migration.md, spec step 3): group 1 = the driver domains
  # that start at boot, started in parallel; every other domain waits for
  # nox-sys.target = each of them booted (its relay connected, NoX
  # --ready-file), at most 120 s. The Whonix-Gateway is not in group 1: it
  # waits up to 90 s for sys-net's uplink before it starts, which held every
  # app VM back (xmg 2026-10-26: 2 min); now it waits for group 1 like the
  # others, and the Workstation waits for the Gateway itself (its pre-start)
  imageDomains = config.services.xen-image-domains.domains;
  usbLinks = import ../vms/usb-links.nix { inherit lib vmRegistry; };
  sysGroup = {
    vms = builtins.filter (lib.hasPrefix "sys-") config.microvm.autostart;
    images = [ ];
  };
  sysUnits =
    map (n: "microvm@${n}.service") sysGroup.vms ++ map (n: "xen-image@${n}.service") sysGroup.images;
  sysReady = pkgs.writeShellScript "nox-sys-ready" ''
    for _ in $(${pkgs.coreutils}/bin/seq 240); do
      missing=""
      for n in ${lib.escapeShellArgs (sysGroup.vms ++ sysGroup.images)}; do
        [ -e "/run/nox-relay/$n.ready" ] || missing="$missing $n"
      done
      [ -n "$missing" ] || exit 0
      ${pkgs.coreutils}/bin/sleep 0.5
    done
    echo "not up after 120 s:$missing; starting the other domains anyway"
  '';
  afterSys = {
    # A drop-in, not a whole unit: xen-image@ is a template from this config,
    # a full instance unit would replace it (no ExecStart, "bad unit file
    # setting", hp 2026-10-18)
    overrideStrategy = "asDropin";
    wants = [ "nox-sys.target" ];
    after = [ "nox-sys.target" ];
  };
  # Disposable VMs (registry `disposable`) boot empty: home and store overlay
  # images go before start and after stop, the runner creates them anew;
  # other volumes (sys-net's NetworkManager, sys-usb's Bluetooth) are data
  # volumes and stay
  disposableImages = [
    "home.img"
    "nix-store-overlay.img"
    "nix-db.img"
  ];
  disposableUnits = lib.listToAttrs (
    map (
      vm:
      let
        wipe = pkgs.writeShellScript "disposable-wipe-${vm.name}" ''
          cd /var/lib/microvms/${vm.name} 2>/dev/null || exit 0
          rm -f ${lib.escapeShellArgs disposableImages}
        '';
      in
      {
        name = "microvm@${vm.name}";
        value.serviceConfig = {
          # "+": as root whatever User= the unit has (the images are root's)
          ExecStartPre = [ "+${wipe}" ];
          ExecStopPost = [ "+${wipe}" ];
        };
      }
    ) (builtins.filter (vm: (vm.disposable or false) && config.microvm.vms ? ${vm.name}) vmRegistry.vms)
  );
in
{
  imports = [
    ../modules/xen-memory.nix
    ../modules/dom0-update.nix
    ../modules/xen-usb.nix
    ../modules/xen-links.nix
    ../modules/xen-image-domains.nix
    ../modules/xen-vnc.nix
    ../modules/xen-lab.nix
    inputs.nox.nixosModules.relay
    inputs.nox.nixosModules.rpc
    inputs.nox.nixosModules.cli
  ];

  # A VM behind an image domain (irc: Whonix-Gateway, Tor only) talks through
  # it alone: every interface served by an image domain, no passed-through
  # PCI device, no USB device of the inventory pointing at it (usb-links.nix
  # keeps it out of USB/IP)
  assertions = lib.concatLists (
    lib.mapAttrsToList (
      name: vm:
      let
        g = vm.config.config;
        domains = map (d: d.domain) (lib.attrValues imageDomains);
        backends = g.microvm.xen.interfaceBackends or { };
        usbOwners = lib.concatMap (
          d: lib.optional (d ? defaultOwner) d.defaultOwner ++ d.allowedOwners or [ ]
        ) vmRegistry.hardware.usb.devices;
      in
      lib.optionals (usbLinks.viaImageDomain g) [
        {
          assertion = lib.all (i: lib.elem (backends.${i.id} or "dom0") domains) g.microvm.interfaces;
          message = "${name}: its network goes through an image domain (Tor), so every interface must be served by one; found ${
            toString (map (i: i.id) g.microvm.interfaces)
          } with backends ${builtins.toJSON backends}.";
        }
        {
          assertion = g.microvm.devices == [ ];
          message = "${name}: its network goes through an image domain (Tor); no PCI passthrough there (a NIC would bypass it).";
        }
        {
          assertion = !builtins.elem name usbOwners;
          message = "${name}: its network goes through an image domain (Tor) and gets no USB; remove it from defaultOwner/allowedOwners in the USB inventory.";
        }
      ]
    ) config.microvm.vms
  );

  virtualisation.xen = {
    enable = true;
    # Test phase: guest consoles are logged to /var/log/xen/console/
    trace = true;
    boot = {
      builderVerbosity = "info"; # report which Xen boot entries were created
      # PVH is the default; registry hostProfile.dom0Pv = true boots a PV dom0.
      # ucode=scan: Xen loads the CPU microcode from the initrd (boot.initrd.prepend);
      # a PV dom0 cannot (verify_patch "WTF family: 0x0"), so without it the
      # CPU ran the BIOS microcode (2026-10-15)
      params = [
        (if vmRegistry.hostProfile.dom0Pv or false then "dom0=pv" else "dom0=pvh")
        "ucode=scan"
      ];
    };
    dom0Resources = {
      # 4096 is too small to evaluate this flake on dom0 (swap thrashing)
      memory = 8192;
      maxVCPUs = 4;
    };
  };

  # dom0 keeps its memory: xl must not take it to start guests. The RAM
  # balancer only moves memory between ballooning MicroVMs.
  environment.etc."xen/xl.conf".source = lib.mkForce (
    pkgs.runCommand "xl.conf" { } ''
      cat ${config.virtualisation.xen.package}/etc/xen/xl.conf > $out
      echo 'autoballoon="off"' >> $out
    ''
  );

  services = {
    xen-memory-balancer.enable = true;

    # dom0 pulls its system from the builder VM (v2.4): `dom0-update [--switch]`;
    # only with a builder (nox.infra.builder)
    dom0-update.enable = vmRegistry.byName ? builder;

    # v2.6: both USB controllers belong to sys-usb; input devices come back via
    # the input proxy, the webcam goes to chat via USB/IP. `sys-usb-rescue`.
    xen-usb = {
      enable = true;
      inherit (config.nox) user;
    };

    # v2.8.1: re-attaches uplink and USB/IP vifs after a driver domain or VM
    # restart, releases USB/IP devices of VMs that went away
    xen-links.enable = true;

    # v2.8.4: sockets for Xen guests over vchan (NoX nox-relay) instead of SSH
    # forwards: GitHub agent (registry `allowGitHubAgent`), filtered session
    # bus (`enableHostDbusForward`), wprs for VMs with wprsd (`vm-gui`, the
    # wprsc socket is /run/nox-relay/<vm>-wprs.sock; apps get dom0's pulse),
    # SSH to the guests with sshd (only the builder: /run/nox-relay/builder-ssh.sock).
    # Guest side: vms/modules/vchan-relay.nix
    nox-relay.host = {
      enable = true;
      guests = lib.filterAttrs (_: g: g.serve != { } || g.listen != { }) (
        lib.mapAttrs (
          name: guest:
          let
            vm = vmRegistry.byName.${name} or { };
            wprs = guest.config.config.systemd.user.services ? wprsd;
          in
          {
            domain = "${name}-vm";
            serve =
              lib.optionalAttrs (vm.allowGitHubAgent or false) {
                github-agent = "/home/nx/.ssh/agent/github.sock";
              }
              // lib.optionalAttrs (vm.enableHostDbusForward or true) {
                dbus = "/run/user/1000/vm-session-bus.sock";
              }
              // lib.optionalAttrs wprs { pulse = "/run/user/1000/pulse/native"; };
            listen =
              lib.optionalAttrs wprs {
                wprs = {
                  path = "/run/nox-relay/${name}-wprs.sock";
                  owner = "1000:100";
                };
              }
              // lib.optionalAttrs guest.config.config.services.openssh.enable {
                # dom0's ssh to the guest (ProxyCommand in home/ssh.nix)
                ssh = {
                  path = "/run/nox-relay/${name}-ssh.sock";
                  owner = "1000:100";
                };
              };
          }
        ) (lib.filterAttrs (_: vm: vm.config.config.microvm.hypervisor == "xen") config.microvm.vms)
      );
    };
  };

  # Stage C: RPC between app VMs (NoX nox-rpc), mediated by dom0. Copying
  # (`vm-copy <vm> <files>` in a VM, `nox copy` in dom0) follows the registry
  # field `copy` (vms/registry.nix): deny rules first, then warn, then ask;
  # the question is a rofi dialog (copyAsk). Guest side:
  # vms/modules/vchan-relay.nix
  services.nox-rpc.host = {
    askCommand = copyAsk;
    enable = true;
    inherit (config.nox) user;
    # Every Xen guest that runs the rpc guest side (vms/modules/vchan-relay.nix)
    guests = builtins.filter (
      vm:
      let
        g = config.microvm.vms.${vm}.config.config;
      in
      g.microvm.hypervisor == "xen" && (g.services.nox-rpc.guest.enable or false)
    ) (builtins.attrNames config.microvm.vms);
    policy =
      let
        rules =
          action:
          lib.concatMap (
            vm:
            let
              c = copyRules vm;
            in
            lib.optional (c.outgoing == action) {
              service = "copy";
              source = vm.name;
              inherit action;
            }
            ++ lib.optional (c.incoming == action) {
              service = "copy";
              target = vm.name;
              inherit action;
            }
          ) vmRegistry.vms;
      in
      rules "deny"
      ++ rules "warn"
      # home backup (nox backup): only disp-backup reads /home/user of the
      # VMs and writes it back; any NixOS VM can be named (README "Backup")
      ++ lib.concatMap (
        vm:
        map
          (service: {
            inherit service;
            source = "disp-backup";
            target = vm.name;
            action = "allow";
          })
          [
            "backup-send"
            "backup-recv"
          ]
      ) (builtins.filter (vm: vm.name != "disp-backup") vmRegistry.vms)
      # sys-print is optional (nox.infra.sys-print.enable)
      ++ lib.optional (vmRegistry.byName ? sys-print) {
        service = "print";
        target = "sys-print";
        action = "ask";
      }
      ++ [
        {
          service = "copy";
          action = "ask";
        }
      ];
  };

  # v3: Whonix-Gateway from the upstream image (PVH, pvgrub2), not NixOS.
  # Outside: eth0 on sys-firewall's `vm-whx-ext` (10.0.2.15 via 10.0.2.2, as in the
  # image). Inside: it serves the vifs of irc/workstation itself on the bridge
  # `eth1` (Whonix' internal interface), so sys-firewall/sys-net only see Tor traffic.
  # Terminal: foot from the store disk over wprs (`vm-run -c wg …`). Image setup with
  # `xen-image-setup whonix-gateway` (xen-migration.md).
  services.xen-image-domains.domains.whonix-gateway = {
    # Test phase: the converted download; later /var/lib/xen-images
    image = "/home/nx/vm-images/whonix/whonix-gateway.raw";
    rootPartition = 3;
    memory = 1024;
    vcpus = 2;
    vifs = [
      {
        mac = "00:00:00:00:01:1b";
        bridge = "vm-whx-ext";
        # Behind sys-firewall (xen-migration.md step 4), which waits for sys-net
        backend = "sys-firewall-vm";
        waitForUplink = true;
      }
    ];
    ifupdownHotplug = [ "eth0" ];
    driverDomain = true;
    internalBridge = "eth1";
    # Terminal over wprs (the image has none), no SSH
    wprs = true;
    foot = true;
  };

  # v3: Whonix-Workstation (LXQt image), only network: the gateway's eth1.
  # Apps over wprs (`vm-run ww torbrowser`), audio over dom0's pulse.
  services.xen-image-domains.domains.whonix-workstation = {
    image = "/home/nx/vm-images/whonix/whonix-workstation.raw";
    rootPartition = 3;
    memory = 4096;
    vcpus = 2;
    vifs = [
      {
        mac = "00:00:00:00:01:1c";
        bridge = "eth1";
        backend = "whonix-gateway-vm";
      }
    ];
    ifupdownHotplug = [ "eth0" ];
    wprs = true;
    # Updates only in the sysmaint session (update-all boots it)
    sysmaintEntry = "PERSISTENT Mode | SYSMAINT Session | system maintenance tasks";
  };

  # dom0 swapped out ~470 MB with ~3 GB still available (page cache pushed
  # program pages out, xmg 2026-10-18). Swap only when memory is really short
  boot.kernel.sysctl."vm.swappiness" = 1;

  # v2.5: the WLAN card belongs to sys-net (registry `hardware.pci`, driver
  # blacklisted in dom0). `sys-net-rescue` hands it back in an emergency.
  environment.systemPackages = [
    sysNetRescue
    updateAll
  ];

  # `nox`: one command over manage-vms, vm-run, vm-clip, nox-copy, dom0-update,
  # update-all and vm-usb; the VM names feed its completion
  programs.nox = {
    enable = true;
    vms = map (vm: vm.name) (vmRegistry.vms ++ vmRegistry.imageDomains);
    # `nox nix`: besides NoX's list (formerly in home/resources/cmds)
    extraCommands = ''
      ## nix
      sudo nix-env --profile /nix/var/nix/profiles/system --delete-generations <n> <m> # Delete specific system generations (then GC)
      nix build ~/nixos-config#nixosConfigurations.<host>.config.system.build.toplevel --no-link --show-trace # Build with full trace
      dom0-update # Build on the builder VM and install (next boot)
    '';
  };

  systemd = {
    # nox-relay (root) creates the wprs sockets for dom0's wprsc here
    tmpfiles.rules = [ "d /run/nox-relay 0755 root root -" ];

    # Boot order barrier (see sysGroup above)
    targets.nox-sys = {
      description = "Driver domains and Whonix-Gateway up";
      wants = [ "nox-sys-ready.service" ];
      after = [ "nox-sys-ready.service" ];
    };
  };

  # Xen creates vifs as vif<domid>.<n> before renaming them to vm<N>
  networking.networkmanager.unmanaged = [ "interface-name:vif*" ];

  systemd = {
    services = lib.mkMerge [
      (
        {
          # The microvm@ services manage the domains. xendomains (no /etc/xen/auto)
          # falls back to `xl shutdown --all --wait` in parallel and hangs until
          # systemd's stop timeout (90 s) on every dom0 shutdown.
          xendomains.enable = false;
          # oxenstored ignores SIGTERM: every shutdown waited 90 s for the
          # SIGKILL. Its state only lives in RAM, nothing to save on the way down
          xenstored.serviceConfig.TimeoutStopSec = "5s";
          # A stopped VM can stay behind as a shut-down domain (state "s", its
          # qemu already gone) that still holds its PCI devices: pci-setup then
          # fails with "failed to quarantine" and the VM only started again after
          # a reboot (sys-net, 2026-10-10/11). On `systemctl restart` pci-setup
          # starts in the same second the old domain begins shutting down, so
          # wait for it to go away and destroy it if it doesn't. The VM itself
          # only starts after pci-setup, so no running domain is hit here.
          "microvm-pci-devices@".serviceConfig.ExecStartPre = [ "${destroyLeftoverDomain} %i" ];
          # The same after a stop: steam stayed behind as "--ps--" after
          # `systemctl stop microvm@steam` and kept its 16 GB (xmg, 2026-10-14).
          # Returns at once when the domain is gone.
          "microvm@".serviceConfig.ExecStopPost = [ "${destroyLeftoverDomain} %i" ];

          # steam: shutting it down from inside Steam must keep it off. Guest
          # poweroff and reboot both end `xl create -F` with exit code 0; steam
          # sets on_reboot = "restart" so xl handles reboots itself (vms/steam)
          "microvm@steam" = lib.mkIf (config.microvm.vms ? steam) {
            serviceConfig.Restart = "on-failure";
          };

          # CPU and memory of the whole machine (all domains) for waybar, which
          # only sees dom0 and must not need root for xl
          xen-stats = {
            description = "CPU and memory of all Xen domains for waybar";
            wantedBy = [ "multi-user.target" ];
            path = [
              config.virtualisation.xen.package
              pkgs.gawk
              pkgs.gnused
              pkgs.coreutils
            ];
            serviceConfig = {
              RuntimeDirectory = "xen-stats";
              RuntimeDirectoryMode = "0755";
              Restart = "always";
              RestartSec = 5;
            };
            script = ''
              out=/run/xen-stats
              write() { printf '%s\n' "$2" > "$out/$1.tmp" && mv "$out/$1.tmp" "$out/$1"; }
              ncpu=$(xl info | awk '/^nr_cpus/ { print $3 }')
              # CPU every 5 s, memory every 30 s (waybar intervals in
              # home/desktop/waybar.nix). Few processes per round: every fork
              # costs page-table hypercalls in a PV dom0 (2026-10-21: 3 s with
              # two awk per domain took ~5 % of a core on the hp)
              prev="" prev_t="" tick=0
              while :; do
                now=$EPOCHREALTIME
                list=$(xl list)
                # Sum of the CPU seconds of all domains (last column of xl list)
                read -r busy cpu < <(awk -v a="$prev" -v t0="$prev_t" -v t1="$now" -v n="$ncpu" \
                  'NR > 1 { s += $NF } END { p = -1; if (a != "") { p = (s - a) / ((t1 - t0) * n) * 100; if (p < 0) p = 0 }
                    printf "%.1f %d\n", s, (p < 0 ? -1 : p + 0.5) }' <<<"$list")
                if [ "$cpu" -ge 0 ]; then
                  write cpu "{\"text\":\"$cpu%\",\"tooltip\":\"CPU of all domains ($ncpu CPUs)\",\"percentage\":$cpu}"
                fi
                if [ $((tick % 6)) -eq 0 ]; then
                  # Per domain: memory it has now / its maximum (ballooning). Xen
                  # only sees what a guest was given, not what it uses inside
                  maxes=""
                  while read -r name id _; do
                    [ "$name" = Name ] && continue
                    maxes+="$id $(xenstore-read "/local/domain/$id/memory/static-max" 2>/dev/null || echo 0)"$'\n'
                  done <<<"$list"
                  mem=$({ printf '%s\n' "$maxes" | sed 's/^/max /'; printf '%s\n' "$list" | sed 's/^/dom /'; xl info; } |
                    awk '$1 == "max" { m[$2] = $3; next }
                      $1 == "dom" { if ($2 == "Name") next; n[++k] = $2; id[k] = $3; c[k] = $4; next }
                      /^total_memory/ { t = $3 } /^free_memory/ { f = $3 }
                      END {
                        for (i = 1; i <= k; i++) {
                          nm = n[i]; sub(/-vm$/, "", nm); if (nm == "Domain-0") nm = "dom0"
                          if (m[id[i]] > 0) d = d sprintf("\\n%s %.1f/%.1f GB", nm, c[i] / 1024, m[id[i]] / 1048576)
                          else d = d sprintf("\\n%s %.1f GB", nm, c[i] / 1024)
                        }
                        printf "{\"text\":\"%.1fG\",\"tooltip\":\"Given to domains: %.1f of %.1f GB (now/max)%s\",\"percentage\":%d}",
                          (t - f) / 1024, (t - f) / 1024, t / 1024, d, (t - f) * 100 / t }')
                  write mem "$mem"
                fi
                prev=$busy prev_t=$now tick=$((tick + 1))
                sleep 5
              done
            '';
          };
        }
        # VMs with `uplink = "sys-vpn"` (registry) start sys-vpn with them; their
        # preStart then waits for its data/backend-ready (vms/modules/net-config.nix)
        // lib.listToAttrs (
          map
            (vm: {
              name = "microvm@${vm.name}";
              value = {
                wants = [ "microvm@sys-vpn.service" ];
                after = [ "microvm@sys-vpn.service" ];
              };
            })
            (
              builtins.filter (
                vm: (vm.uplink or "sys-net") == "sys-vpn" && config.microvm.vms ? ${vm.name}
              ) vmRegistry.vms
            )
        )
        # The relay doesn't notice a domain that was killed hard (stop timeout)
        # and stays attached to it (Known Issues): stopping or restarting the VM
        # takes its relay along, starting the VM starts it again. After: on a
        # restart the relay comes back only once the old domain is gone (without
        # it, it looked up the old domain id and waited 30 s for it, 2026-10-17)
        // lib.mapAttrs' (
          name: _:
          lib.nameValuePair "nox-relay-${name}" {
            partOf = [ "microvm@${name}.service" ];
            after = [ "microvm@${name}.service" ];
            wantedBy = [ "microvm@${name}.service" ];
          }
        ) (lib.filterAttrs (name: _: config.microvm.vms ? ${name}) config.services.nox-relay.host.guests)
      )
      disposableUnits
      # VMs whose uplink backend is an image domain (irc: Whonix-Gateway) start
      # it with them; their preStart then waits for its data/backend-ready
      # (vms/modules/net-config.nix). Without it irc hung 3 min and looped.
      (lib.mapAttrs'
        (
          name: units:
          lib.nameValuePair "microvm@${name}" {
            wants = units;
            after = units;
          }
        )
        (
          lib.filterAttrs (_: units: units != [ ]) (
            lib.mapAttrs (
              _: vm:
              let
                backends = lib.attrValues (vm.config.config.microvm.xen.interfaceBackends or { });
              in
              lib.mapAttrsToList (n: _: "xen-image@${n}.service") (
                lib.filterAttrs (_: d: lib.elem d.domain backends) imageDomains
              )
            ) config.microvm.vms
          )
        )
      )
      # Boot order: the barrier and every domain outside group 1 after it
      (
        {
          nox-sys-ready = {
            description = "Wait until the driver domains are up";
            wants = sysUnits;
            after = sysUnits;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = sysReady;
            };
          };
        }
        // lib.mapAttrs' (n: _: lib.nameValuePair "microvm@${n}" afterSys) (
          lib.filterAttrs (n: _: !builtins.elem n sysGroup.vms) config.microvm.vms
        )
        // lib.mapAttrs' (n: _: lib.nameValuePair "xen-image@${n}" afterSys) (
          lib.filterAttrs (n: _: !builtins.elem n sysGroup.images) imageDomains
        )
      )
    ];

    network.networks =
      # Admin network: every VM port is isolated, so VMs reach dom0 (the
      # non-isolated bridge itself) but not each other. Their internet goes
      # through the uplink served by sys-net.
      lib.genAttrs (map (i: "30-vm${toString i}") (lib.genList (i: i + 1) 50) ++ [ "31-vm-router" ]) (_: {
        bridgeConfig.Isolated = true;
      })
      // {
        # dom0: default route via sys-net in the test phase (HTTPS/DNS/NTP
        # only, see vms/sys-net); without dom0TestAccess dom0 is offline
        "32-vm-internal" = {
          # High metric: after `sys-net-rescue` the WLAN route from
          # NetworkManager (metric 600) wins over the dead sys-net
          routes = lib.mkForce (
            lib.optional (dom0TestAccess != null) {
              Destination = "0.0.0.0/0";
              Gateway = "10.0.0.253";
              Metric = 2000;
            }
          );
          networkConfig.DNS = lib.mkIf (dom0TestAccess != null) [
            "9.9.9.9"
            "149.112.112.112"
          ];
        };
      };
  };
}

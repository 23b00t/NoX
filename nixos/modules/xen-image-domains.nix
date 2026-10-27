# Image domains (v3): guests from upstream disk images (Whonix), not NixOS
# and not run by microvm.nix. Per domain one xl config and the unit
# `xen-image@<name>`. PVH guests boot their own kernel with pvgrub2 (reads
# /boot/grub/grub.cfg from the guest disk), so the guest keeps updating it.
#
# Guest integration without Nix in the guest: a read-only store disk
# (squashfs of a Nix closure, mounted at /nix/store, stable entry point
# /nix/store/nox) carries nox-relay, dom0's rpc services (nox-rpc-in, no
# sshd), wprsd (+ foot) and, for driver domains, `xl devd` with the hotplug
# scripts. `xen-image-setup <name>` installs the systemd
# units into the stopped image once (debugfs, as the image owner); later
# store disks keep working with the same units.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.services.xen-image-domains;
  xen = config.virtualisation.xen.package;
  relayPackage = config.services.nox-relay.package;
  pvhgrub = "${pkgs.grub2_pvhgrub_image}/lib/grub-xen_pvh/grub-i386-xen_pvh.bin";

  quote = s: ''"${s}"'';
  xlList = items: "[ ${lib.concatMapStringsSep ", " quote items} ]";

  vifOpts = {
    options = {
      mac = lib.mkOption {
        type = lib.types.str;
        description = "MAC address of the guest interface.";
      };
      bridge = lib.mkOption {
        type = lib.types.str;
        description = "Bridge in the backend domain.";
      };
      backend = lib.mkOption {
        type = lib.types.str;
        default = "sys-net-vm";
        description = "Xen domain serving the vif (driver domain).";
      };
      waitForUplink = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Also wait until the backend reports a ready uplink (`data/uplink` = 1 in its xenstore, written by sys-net).";
      };
    };
  };

  relayRules = {
    listen = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Relay `listen` rules (see services.nox-relay).";
    };
    serve = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Relay `serve` rules (see services.nox-relay).";
    };
  };

  domainOpts =
    { name, ... }:
    {
      options = {
        domain = lib.mkOption {
          type = lib.types.str;
          default = "${name}-vm";
          description = "Xen domain name.";
        };
        image = lib.mkOption {
          type = lib.types.str;
          description = "Raw disk image (read-write, xvda).";
        };
        rootPartition = lib.mkOption {
          type = lib.types.ints.positive;
          description = "Partition of the image holding the root file system (ext4), for `xen-image-setup`.";
        };
        memory = lib.mkOption {
          type = lib.types.ints.positive;
          description = "Memory in MiB (fixed, no ballooning).";
        };
        vcpus = lib.mkOption {
          type = lib.types.ints.positive;
          default = 1;
          description = "Number of vCPUs.";
        };
        autostart = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Start the domain at boot.";
        };
        vifs = lib.mkOption {
          type = lib.types.listOf (lib.types.submodule vifOpts);
          default = [ ];
          description = "Network interfaces (eth0, eth1, … in order), re-attached by xen-links.";
        };
        driverDomain = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Serve vifs for other domains (`xl devd` in the guest).";
        };
        internalBridge = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Bridge the driver domain creates for its vifs; every port is isolated (clients reach the domain, not each other).";
        };
        ifupdownHotplug = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Interfaces ifupdown raises again when they reappear (vif re-attached after a backend restart).";
        };
        wprs = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "GUI apps over wprs (wprsd as user service, socket over the relay; `vm-gui` starts apps over rpc `app`) with dom0's pulse.";
        };
        foot = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "foot on the store disk (/nix/store/nox/bin/foot, own fonts) for images without a terminal (Whonix-Gateway); needs `wprs`.";
        };
        relay = {
          host = relayRules;
          guest = relayRules;
        };
        sysmaintEntry = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "PERSISTENT Mode | SYSMAINT Session | system maintenance tasks";
          description = ''
            GRUB menu entry of the guest's sysmaint session (Kicksecure
            user-sysmaint-split: updates only work there). When set, the next
            start boots this entry if /run/xen-image/<name>.sysmaint exists
            (removed on start), rpc calls run as `sysmaint` there, and the
            dom0 integration runs in sysmaint-boot.target too.
          '';
        };
        extraConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Extra xl.cfg lines.";
        };
      };
    };

  # Store disk: the closure of `env` as a squashfs, store paths at the top
  # level (mounted at /nix/store in the guest), plus the symlink `nox` -> env
  mkGuest =
    name: d:
    let
      wprsClipboard = import ./wprs-clipboard.nix { inherit pkgs; };

      # Same paths as in the NixOS VMs (vms/modules/vchan-relay.nix); the
      # user's group is 1000 in Debian
      relayRulesGuest = {
        listen =
          d.relay.guest.listen
          // lib.optionalAttrs d.wprs {
            pulse = {
              path = "/tmp/wprs-pulse";
              owner = "1000:1000";
            };
          };
        serve =
          d.relay.guest.serve
          // {
            rpc-in = "/run/nox-rpc-in.sock";
          }
          // lib.optionalAttrs d.wprs { wprs = "/run/user/1000/wprs.sock"; };
      };
      relayConfig = pkgs.writeText "nox-relay.conf" (
        lib.concatStrings (
          lib.mapAttrsToList (
            service: l:
            "listen ${service} ${l.path} mode=${l.mode or "0600"}"
            + lib.optionalString ((l.owner or null) != null) " owner=${l.owner}"
            + "\n"
          ) relayRulesGuest.listen
          ++ lib.mapAttrsToList (service: path: "serve ${service} ${path}\n") relayRulesGuest.serve
        )
      );

      # dom0's fixed services in the guest (xen-migration.md, spec rest of
      # step 2): one call per connection on /run/nox-rpc-in.sock (relay
      # `rpc-in`), first line "<service> <source>" as with nox-rpc. Runs as
      # root; only dom0 may call. ping; clip get|set and app as the account of
      # the booted session; apt-upgrade as root (with the user-sysmaint split
      # only in the sysmaint session), interactive over the stream
      appEnv = pkgs.writeShellScript "nox-app-env" ''
        for f in /etc/profile.d/*.sh; do
          [ -r "$f" ] && . "$f" >/dev/null 2>&1
        done
        exec env WAYLAND_DISPLAY=wprs-0 DISPLAY=:100 XDG_SESSION_TYPE=wayland \
          PULSE_SERVER=unix:/tmp/wprs-pulse "$@"
      '';
      rpcIn = pkgs.writeShellScript "nox-rpc-in" ''
        set -u
        PATH=/usr/sbin:/usr/bin:/sbin:/bin
        IFS=' ' read -r service source || exit 1
        if ! [[ "$service" =~ ^[a-z0-9-]{1,32}$ && "$source" =~ ^[a-z0-9-]{1,32}$ ]]; then
          echo "error bad header"
          exit 1
        fi
        if [ "$source" != dom0 ]; then
          echo "error: only dom0 calls here"
          exit 1
        fi
        sysmaint=0
        grep -qw boot-role=sysmaint /proc/cmdline && sysmaint=1
        if [ "$sysmaint" = 1 ]; then u=sysmaint; else u=user; fi
        uid="$(id -u "$u")"
        asuser() {
          runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            WAYLAND_DISPLAY=wprs-0 "$@"
        }
        case "$service" in
          ping)
            echo ok
            ;;
          # update-all: Tor's clock is set (Whonix), newest vs. running kernel
          tor-ready)
            [ -e /run/sdwdate/first_success ] && echo ok
            ;;
          kernel)
            echo "$(ls /boot/vmlinuz-* | sort -V | tail -n 1) /boot/vmlinuz-$(uname -r)"
            ;;
        ${lib.optionalString d.wprs ''
          # nox doctor's probe (home/vm-management/vm-doctor.nix); only wprsd
          # here, network checks run in the NixOS VMs
          doctor)
            IFS= read -r probe || exit 1
            case "$probe" in
              wprsd) asuser systemctl --user is-active wprsd ;;
              *) echo "error: probe wprsd only" ;;
            esac
            ;;
          clip)
            IFS= read -r action || exit 1
            case "$action" in
              get | set) asuser /nix/store/nox/bin/vm-clip-helper "$action" ;;
              *) echo "error: clip get|set"; exit 1 ;;
            esac
            ;;
          app)
            args=()
            while IFS= read -r -d "" arg; do
              args+=("$arg")
            done
            [ "''${#args[@]}" -gt 0 ] || { echo "error: no command"; exit 1; }
            # Right after boot the user manager (linger) may not be up yet:
            # systemd-run failed with "Failed to connect to user scope bus"
            # (Whonix-Workstation started by vm-gui, 2026-10-21)
            for _ in $(seq 60); do
              [ -S "/run/user/$uid/bus" ] && [ -S "/run/user/$uid/systemd/private" ] && break
              sleep 1
            done
            # Same token rule as NoX's app handler: a retried call doesn't
            # start the app twice
            unit=()
            if [ "''${args[0]}" = env ] && [[ "''${args[1]:-}" =~ ^NOX_APP_TOKEN=([0-9a-f]{8,32})$ ]]; then
              unit=(--unit="nox-app-''${BASH_REMATCH[1]}")
              if [ "$(asuser systemctl --user show -p LoadState --value "nox-app-''${BASH_REMATCH[1]}.service")" = loaded ]; then
                echo "ok: already started"
                exit 0
              fi
            fi
            # OOMPolicy=continue as in NoX's app handler (rpc.nix)
            if out="$(asuser systemd-run --user --collect --quiet "''${unit[@]}" --property=OOMPolicy=continue -- /nix/store/nox/bin/nox-app-env "''${args[@]}" 2>&1)"; then
              echo "ok: started ''${args[0]}"
            else
              echo "error: $out"
              exit 1
            fi
            ;;
        ''}
          apt-upgrade)
            exec 2>&1
            ${lib.optionalString (d.sysmaintEntry != null) ''
              if [ "$sysmaint" != 1 ]; then
                echo "error: updates only in the sysmaint session"
                exit 1
              fi
            ''}
            exec apt-get --update full-upgrade
            ;;
          *)
            echo "error unknown service $service"
            exit 1
            ;;
        esac
      '';

      # Default hotplug scripts, vif-bridge additionally isolates the port
      xenScripts = pkgs.runCommand "nox-xen-scripts" { } ''
        mkdir -p $out
        for f in ${xen}/etc/xen/scripts/*; do
          ln -s "$f" $out/
        done
        rm $out/vif-bridge
        cat > $out/vif-bridge <<'EOF'
        #!${pkgs.bash}/bin/bash
        # vif-bridge, then the port gets isolated: clients of this driver
        # domain reach it, not each other
        ${xen}/etc/xen/scripts/vif-bridge "$@" || exit
        case "$1" in
          online | add) ${pkgs.iproute2}/bin/ip link set dev "$vif" type bridge_slave isolated on ;;
        esac
        EOF
        chmod 0555 $out/vif-bridge
      '';

      env = pkgs.runCommand "nox-guest-${name}" { } ''
        mkdir -p $out/bin $out/etc
        ln -s ${relayPackage}/bin/nox-relay $out/bin/nox-relay
        ln -s ${rpcIn} $out/bin/nox-rpc-in
        ln -s ${appEnv} $out/bin/nox-app-env
        ln -s ${relayConfig} $out/etc/nox-relay.conf
        ${lib.optionalString d.foot ''
          # Own fonts (the image may have none) and a TERM Debian knows
          ln -s ${pkgs.writeShellScript "foot" ''
            export FONTCONFIG_FILE=${pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; }}
            exec ${pkgs.foot}/bin/foot -o term=xterm-256color "$@"
          ''} $out/bin/foot
        ''}
        ${lib.optionalString d.driverDomain ''
          ln -s ${xen}/bin/xl ${xen}/bin/xenstore-write ${xen}/bin/xenstore-rm $out/bin/
          mkdir -p $out/etc/xen
          ln -s ${xenScripts} $out/etc/xen/scripts
        ''}
        ${lib.optionalString d.wprs ''
          ln -s ${pkgs.wprs}/bin/xwayland-xdg-shell ${pkgs.xwayland}/bin/Xwayland \
            ${wprsClipboard.helper}/bin/vm-clip-helper $out/bin/
          # The wprsd unit lives in the image (rootTree), the arguments here:
          # no selection sync with dom0 (explicit copy/paste via vm-clip)
          ln -s ${pkgs.writeShellScript "wprsd" ''
            # Frame pacing as in the NixOS VMs (vms/modules/wprs.nix)
            exec ${pkgs.wprs}/bin/wprsd --framerate 120 --selection-sync false "$@"
          ''} $out/bin/wprsd
        ''}
      '';

      storeDisk =
        pkgs.runCommand "nox-store-${name}.squashfs"
          {
            nativeBuildInputs = [ pkgs.squashfsTools ];
            closure = pkgs.closureInfo { rootPaths = [ env ]; };
          }
          ''
            mksquashfs $(cat $closure/store-paths) $out \
              -keep-as-directory -all-root -root-mode 0755 -no-xattrs -comp zstd -mem 512M -quiet -no-progress \
              -p "nox s 0777 0 0 $(basename ${env})"
          '';

      unit = text: pkgs.writeText "unit" text;
      modules = [
        "xen-gntdev"
        "xen-gntalloc"
        "xen-evtchn"
        "squashfs"
      ]
      ++ lib.optionals d.driverDomain [
        "xen-netback"
        "xen-privcmd"
        "xenfs"
        "bridge"
      ];
      wants = [
        "nox-relay.service"
        "nox-rpc-in.socket"
      ]
      ++ lib.optional d.driverDomain "xendriverdomain.service"
      ++ lib.optional (d.internalBridge != null) "nox-bridge.service";

      # Installed into the guest's root by `xen-image-setup` (only static
      # entry points into /nix/store/nox, nothing that changes with the store disk)
      rootTree = pkgs.runCommand "nox-root-${name}" { } ''
        mkdir -p $out/nix/store $out/etc/systemd/system/multi-user.target.wants $out/etc/modules-load.d
        s=$out/etc/systemd/system
        cp ${unit ''
          [Unit]
          Description=Nix store disk (nox-relay, rpc${lib.optionalString d.driverDomain ", Xen tools"})

          [Mount]
          What=/dev/xvdb
          Where=/nix/store
          Type=squashfs
          Options=ro,nodev
        ''} $s/nix-store.mount
        cp ${unit ''
          [Unit]
          Description=dom0 integration (nox-relay, rpc over vchan${lib.optionalString d.driverDomain ", xl devd"})
          Wants=${toString wants}

          [Install]
          WantedBy=multi-user.target
        ''} $s/nox.target
        ln -s ../nox.target $s/multi-user.target.wants/nox.target
        ${lib.optionalString (d.sysmaintEntry != null) ''
          # sysmaint-boot.target does not pull in multi-user.target
          mkdir -p $s/sysmaint-boot.target.wants
          ln -s ../nox.target $s/sysmaint-boot.target.wants/nox.target
        ''}
        cp ${unit ''
          [Unit]
          Description=nox-relay (guest side)
          Requires=nix-store.mount
          After=nix-store.mount systemd-modules-load.service
          StartLimitIntervalSec=0

          [Service]
          ExecStart=/nix/store/nox/bin/nox-relay --role server --peer 0 --path data/nox-relay --config /nix/store/nox/etc/nox-relay.conf
          Restart=always
          RestartSec=1
        ''} $s/nox-relay.service
        cp ${unit ''
          [Unit]
          Description=Calls from dom0 (nox-rpc-in)
          Requires=nix-store.mount
          After=nix-store.mount

          [Socket]
          ListenStream=/run/nox-rpc-in.sock
          Accept=yes
          SocketMode=0600
        ''} $s/nox-rpc-in.socket
        cp ${unit ''
          [Unit]
          Description=Call from dom0 (one connection)

          [Service]
          ExecStart=-/nix/store/nox/bin/nox-rpc-in
          StandardInput=socket
          StandardOutput=socket
          StandardError=journal
        ''} $s/nox-rpc-in@.service
        printf '%s\n' ${lib.escapeShellArgs modules} > $out/etc/modules-load.d/nox.conf
        ${lib.optionalString d.driverDomain ''
          # One queue per vif: with several, part of the connections of
          # multi-queue clients stalled (Workstation, xmg 2026-10-11)
          mkdir -p $out/etc/modprobe.d
          echo "options xen_netback max_queues=1" > $out/etc/modprobe.d/nox-netback.conf
          cp ${unit ''
            [Unit]
            Description=Mount /proc/xen files
            ConditionPathExists=/proc/xen
            ConditionPathExists=!/proc/xen/capabilities
            After=systemd-modules-load.service

            [Mount]
            What=xenfs
            Where=/proc/xen
            Type=xenfs
          ''} $s/proc-xen.mount
          cp ${unit ''
            [Unit]
            Description=Xen driver domain device daemon
            Requires=proc-xen.mount nix-store.mount
            After=proc-xen.mount nix-store.mount${
              lib.optionalString (d.internalBridge != null) " nox-bridge.service"
            }

            [Service]
            Type=forking
            ExecStart=/nix/store/nox/bin/xl devd
            # Clients wait for it (uplink readiness, dom0 preStart)
            ExecStartPost=/nix/store/nox/bin/xenstore-write data/backend-ready 1
            ExecStopPost=-/nix/store/nox/bin/xenstore-rm data/backend-ready
            LogsDirectory=xen
            RuntimeDirectory=xen
            StateDirectory=xen
          ''} $s/xendriverdomain.service
          mkdir -p $out/etc/xen
          ln -s /nix/store/nox/etc/xen/scripts $out/etc/xen/scripts
        ''}
        ${lib.optionalString (d.internalBridge != null) ''
          cp ${unit ''
            [Unit]
            Description=Bridge ${d.internalBridge} for the vifs this domain serves
            DefaultDependencies=no
            After=systemd-modules-load.service
            Before=network-pre.target networking.service
            Wants=network-pre.target

            [Service]
            Type=oneshot
            RemainAfterExit=yes
            ExecStart=/usr/sbin/ip link add ${d.internalBridge} type bridge stp_state 0 forward_delay 0
          ''} $s/nox-bridge.service
        ''}
        ${lib.optionalString (d.ifupdownHotplug != [ ]) ''
          mkdir -p $out/etc/network/interfaces.d
          cp ${pkgs.writeText "ifupdown-hotplug" ''
            # nox: raise again when the vif is re-attached (backend restart)
            ${lib.concatMapStrings (i: "allow-hotplug ${i}\n") d.ifupdownHotplug}''} \
            $out/etc/network/interfaces.d/31_nox-hotplug
        ''}
        ${lib.optionalString d.wprs ''
          # wprsd runs without a login (linger), like in the NixOS VMs
          mkdir -p $out/etc/systemd/user/default.target.wants $out/var/lib/systemd/linger
          cp ${unit ''
            [Unit]
            Description=wprsd instance
            # The store disk is a system mount the user manager cannot order
            # against: retry until it is there
            StartLimitIntervalSec=0

            [Service]
            Environment=PATH=/nix/store/nox/bin:/usr/local/bin:/usr/bin:/bin
            Environment=RUST_BACKTRACE=1
            ExecStart=/nix/store/nox/bin/wprsd
            Restart=always
            RestartSec=2

            [Install]
            WantedBy=default.target
          ''} $out/etc/systemd/user/wprsd.service
          ln -s ../wprsd.service $out/etc/systemd/user/default.target.wants/wprsd.service
          touch $out/var/lib/systemd/linger/user
        ''}
      '';

      xlConfig = mkXlConfig pvhgrub;
      # pvgrub2 that boots the guest's sysmaint entry instead of its default
      xlConfigSysmaint = mkXlConfig "${
        pkgs.grub2_pvhgrub_image.overrideAttrs (old: {
          name = "grub2_xen_pvh_image_sysmaint";
          env = old.env // {
            GRUB_CONFIGS = pkgs.runCommand "pvhgrub-sysmaint-configs" { } ''
              mkdir $out
              cp ${old.env.GRUB_CONFIGS}/grub-bootstrap.cfg $out/
              cat > $out/grub.cfg <<'EOF'
              # Like the stock pvhgrub config, but the guest's menu is sourced
              # (its entries stay defined) and the sysmaint entry is booted
              if search -s -f /boot/grub/grub.cfg ; then
                source /boot/grub/grub.cfg
                set default="${d.sysmaintEntry}"
                set timeout=0
              fi
              EOF
            '';
          };
        })
      }/lib/grub-xen_pvh/grub-i386-xen_pvh.bin";

      # Boots the sysmaint entry once if /run/xen-image/<name>.sysmaint exists
      start = pkgs.writeShellScript "xen-image-${name}-start" ''
        cfg=/etc/xen/image-domains/${name}/xl.cfg
        ${lib.optionalString (d.sysmaintEntry != null) ''
          if [ -e /run/xen-image/${name}.sysmaint ]; then
            ${pkgs.coreutils}/bin/rm -f /run/xen-image/${name}.sysmaint
            echo "Booting the sysmaint session" >&2
            cfg=/etc/xen/image-domains/${name}/xl-sysmaint.cfg
          fi
        ''}
        exec ${xen}/bin/xl create -F "$cfg"
      '';

      mkXlConfig =
        kernel:
        pkgs.writeText "xl.cfg" ''
          name = ${quote d.domain}
          type = "pvh"
          kernel = ${quote kernel}
          memory = ${toString d.memory}
          vcpus = ${toString d.vcpus}
          on_poweroff = "destroy"
          on_reboot = "restart"
          on_crash = "destroy"
          disk = ${
            xlList [
              "format=raw, vdev=xvda, access=rw, target=${d.image}"
              "format=raw, vdev=xvdb, access=ro, target=${storeDisk}"
            ]
          }
          vif = ${xlList (map (v: "mac=${v.mac}, bridge=${v.bridge}, backend=${v.backend}") d.vifs)}
          ${lib.optionalString d.driverDomain "driver_domain = 1"}
          ${d.extraConfig}
        '';

      # The vif backends must be up, otherwise creating the vifs fails
      preStart = pkgs.writeShellScript "xen-image-${name}-pre-start" ''
        PATH=${
          lib.makeBinPath [
            xen
            pkgs.bash
            pkgs.coreutils
            pkgs.socat
          ]
        }
        if xl domid ${lib.escapeShellArg d.domain} >/dev/null 2>&1; then
          echo "Destroying leftover Xen domain ${d.domain}" >&2
          xl destroy ${lib.escapeShellArg d.domain}
        fi
        if [ ! -f ${lib.escapeShellArg d.image} ]; then
          echo "Disk image ${d.image} is missing" >&2
          exit 1
        fi
        # Backend ready: its driver domain wrote data/backend-ready after xl
        # devd started (common-config.nix, the guest's xendriverdomain here)
        reachable() {
          local be
          be="$(xl domid "$1" 2>/dev/null)" || return 1
          [ "$(xenstore-read "/local/domain/$be/data/backend-ready" 2>/dev/null)" = 1 ]
        }
        ${lib.concatMapStrings (v: ''
          for _ in $(seq 180); do
            reachable ${lib.escapeShellArg v.backend} && break
            sleep 1
          done
        '') (lib.unique d.vifs)}
        ${lib.concatMapStrings (v: ''
          # sys-net is ready before its uplink (DHCP); Tor that starts
          # without one marks its guards unreachable and does not recover
          # (Whonix-Gateway, 2026-10-12). Start anyway after 90 s.
          for i in $(seq 90); do
            be="$(xl domid ${lib.escapeShellArg v.backend} 2>/dev/null)" &&
              [ "$(xenstore-read "/local/domain/$be/data/uplink" 2>/dev/null)" = 1 ] && break
            [ "$i" = 90 ] && echo "No uplink in ${v.backend} after 90 s, starting anyway" >&2
            sleep 1
          done
        '') (lib.unique (builtins.filter (v: v.waitForUplink) d.vifs))}
      '';

      stop = pkgs.writeShellScript "xen-image-${name}-stop" ''
        PATH=${
          lib.makeBinPath [
            xen
            pkgs.coreutils
          ]
        }
        if xl domid ${lib.escapeShellArg d.domain} >/dev/null 2>&1; then
          timeout 60 xl shutdown -w ${lib.escapeShellArg d.domain} ||
            xl destroy ${lib.escapeShellArg d.domain}
          for _ in $(seq 20); do
            xl domid ${lib.escapeShellArg d.domain} >/dev/null 2>&1 || break
            sleep 0.5
          done
        fi
      '';
    in
    {
      inherit
        storeDisk
        rootTree
        xlConfig
        xlConfigSysmaint
        start
        preStart
        stop
        ;
      sysmaint = d.sysmaintEntry != null;
    };

  guests = lib.mapAttrs mkGuest cfg.domains;

  # `xen-image-setup <name>`: install the units into the stopped image
  setup = pkgs.writeShellScriptBin "xen-image-setup" ''
    set -euo pipefail
    PATH=${
      lib.makeBinPath [
        pkgs.e2fsprogs
        pkgs.util-linux
        pkgs.jq
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        config.systemd.package
      ]
    }
    case "''${1:-}" in
      ${lib.concatStrings (
        lib.mapAttrsToList (name: d: ''
          ${name}) image=${lib.escapeShellArg d.image} part=${toString d.rootPartition} tree=${guests.${name}.rootTree} ;;
        '') cfg.domains
      )}
      *)
        echo "usage: xen-image-setup <${lib.concatStringsSep "|" (lib.attrNames cfg.domains)}>" >&2
        exit 2
        ;;
    esac
    if systemctl is-active --quiet "xen-image@$1"; then
      echo "xen-image@$1 is running; stop it first" >&2
      exit 1
    fi
    start="$(sfdisk -J "$image" | jq -r --argjson n "$part" '.partitiontable.partitions[$n - 1].start')"
    fs="$image?offset=$((start * 512))"
    state="$(debugfs -R stats "$fs" 2>/dev/null | grep '^Filesystem state:' || true)"
    if [[ "$state" != *" clean" ]]; then
      echo "Root file system not cleanly unmounted ($state); boot and shut down the guest first" >&2
      exit 1
    fi
    exists() { debugfs -R "stat $1" "$fs" 2>/dev/null | grep -q '^Inode:'; }
    cmds="$(mktemp)"
    trap 'rm -f "$cmds"' EXIT
    cd "$tree"
    {
      # Units of earlier store disks (sshd over vchan, gone with the SSH removal)
      for old in sshd-vchan.socket sshd-vchan@.service nox-sshd-setup.service; do
        exists "/etc/systemd/system/$old" && echo "rm /etc/systemd/system/$old"
      done
      true
    } >"$cmds"
    while IFS= read -r p; do
      d="''${p#.}"
      if [ -L "$p" ]; then
        exists "$d" && echo "rm $d"
        echo "symlink $d $(readlink "$p")"
      elif [ -d "$p" ]; then
        exists "$d" && continue
        echo "mkdir $d"
        echo "sif $d mode 040755"
      else
        exists "$d" && echo "rm $d"
        echo "write $p $d"
        if [ -x "$p" ]; then echo "sif $d mode 0100755"; else echo "sif $d mode 0100644"; fi
      fi
      echo "sif $d uid 0"
      echo "sif $d gid 0"
    done < <(find . -mindepth 1 | sort) >>"$cmds"
    # debugfs echoes every command; show only what went wrong
    debugfs -w -f "$cmds" "$fs" 2>&1 | grep -vE '^(debugfs( [0-9]|: )|Allocated inode|$)' || true
    echo "Installed $(grep -c -E '^(write|symlink|mkdir) ' "$cmds") entries from $tree into $image (partition $part)"
  '';
in
{
  options.services.xen-image-domains = {
    domains = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule domainOpts);
      default = { };
      description = "Xen domains booted from upstream disk images.";
    };
  };

  config = lib.mkIf (cfg.domains != { }) {
    environment.systemPackages = [ setup ];

    environment.etc = lib.mkMerge (
      lib.mapAttrsToList (
        name: g:
        {
          "xen/image-domains/${name}/xl.cfg".source = g.xlConfig;
          "xen/image-domains/${name}/pre-start".source = g.preStart;
          "xen/image-domains/${name}/stop".source = g.stop;
          "xen/image-domains/${name}/start".source = g.start;
        }
        // lib.optionalAttrs g.sysmaint {
          "xen/image-domains/${name}/xl-sysmaint.cfg".source = g.xlConfigSysmaint;
        }
      ) guests
    );

    systemd.services = {
      "xen-image@" = {
        description = "Xen image domain %i";
        after = [
          "xenstored.service"
          "xenconsoled.service"
        ];
        requires = [ "xenstored.service" ];
        serviceConfig = {
          Type = "simple";
          ExecStartPre = "/etc/xen/image-domains/%i/pre-start";
          ExecStart = "/etc/xen/image-domains/%i/start";
          ExecStop = "/etc/xen/image-domains/%i/stop";
          TimeoutStartSec = 300;
          TimeoutStopSec = 90;
        };
      };
    }
    // lib.mapAttrs' (
      name: _:
      lib.nameValuePair "xen-image@${name}" {
        overrideStrategy = "asDropin";
        wantedBy = [ "multi-user.target" ];
      }
    ) (lib.filterAttrs (_: d: d.autostart) cfg.domains)
    # Relay follows the domain (see microvm@ in machines/xen-dom0.nix)
    // lib.mapAttrs' (
      name: _:
      lib.nameValuePair "nox-relay-${name}" {
        partOf = [ "xen-image@${name}.service" ];
        after = [ "xen-image@${name}.service" ];
        wantedBy = [ "xen-image@${name}.service" ];
      }
    ) cfg.domains;

    # dom0's side of the relay: rpc-in (nox-rpc --dom0), wprs, extras
    services.nox-relay.host.guests = lib.mapAttrs (name: d: {
      inherit (d) domain;
      serve = d.relay.host.serve // lib.optionalAttrs d.wprs { pulse = "/run/user/1000/pulse/native"; };
      listen =
        d.relay.host.listen
        // {
          # dom0's fixed services in the guest (nox-rpc-in on the store disk)
          rpc-in = {
            path = "/run/nox-relay/${name}-rpc-in.sock";
            owner = "1000:100";
          };
        }
        // lib.optionalAttrs d.wprs {
          # dom0's wprsc (vm-gui)
          wprs = {
            path = "/run/nox-relay/${name}-wprs.sock";
            owner = "1000:100";
          };
        };
    }) cfg.domains;

    # vifs come back after a backend restart
    services.xen-links.extraLinks = lib.concatLists (
      lib.mapAttrsToList (
        _: d:
        map (v: {
          inherit (d) domain;
          inherit (v)
            mac
            bridge
            backend
            ;
        }) d.vifs
      ) cfg.domains
    );
  };
}

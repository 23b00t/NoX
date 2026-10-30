# Guest side of nox-relay (v2.8.4, NoX flake input): sockets from dom0 over a
# vchan instead of SSH forwards. Xen VMs only, at the paths the SSH forwards
# used:
# - GitHub agent (registry `allowGitHubAgent`)
# - filtered session bus, notifications + tray (`enableHostDbusForward`)
# - SSH (VMs with sshd, only the builder): dom0's ssh reaches sshd -i (socket-activated per
#   connection) instead of the admin network (stage B, ProxyCommand in
#   home/ssh.nix); stage B2 drops the admin interface (except sys-net)
# - wprs (VMs with wprsd, vms/modules/wprs.nix): dom0's wprsc reaches wprsd,
#   sound: the VM's own pipewire, tunnels to dom0's pulse servers at
#   /tmp/wprs-pulse (playback) and /tmp/wprs-pulse-mic (registry
#   `microphone`), dom0 side: dom0/vm-audio.nix
# - RPC (stage C, app VMs): `vm-copy`, incoming files in ~/Incoming/<source>
# dom0 side: machines/hp/xen.nix
{
  lib,
  pkgs,
  config,
  options,
  inputs,
  vmRegistry,
  ...
}:
let
  vmName = lib.removeSuffix "-vm" (config.networking.hostName or "");
  vm = vmRegistry.byName.${vmName} or { };
  githubAgent = vm.allowGitHubAgent or false;
  dbus = vm != { } && (vm.enableHostDbusForward or true);
  wprs = config.systemd.user.services ? wprsd;
  # Pixels over grant-shared memory (registry `wprsSharedMemory`, vms/modules/wprs.nix)
  wprsGrants = wprs && (vm.wprsSharedMemory or true);
  # dom0's microphone (registry `microphone`, while `nox mic on` in dom0)
  microphone = wprs && (vm.microphone or false);
  ssh = config.services.openssh.enable;
  sshSocket = "/run/sshd-vchan.sock";
  # The fleet's theme: dark/light and the cursor of apps over RPC
  theme = import ../../desktop/theme.nix {
    inherit lib;
    inherit (vmRegistry) theme;
  };
  # uid/gid of `user` in the VMs
  owner = "1000:100";

  # `vm-print <printer-ip> <file>` (C2): the document goes to sys-print over
  # RPC (dom0 asks), which prints it on the given IPP Everywhere printer
  vmPrint = pkgs.writeShellScriptBin "vm-print" ''
    set -euo pipefail
    if [ $# -ne 2 ] || [ ! -f "$2" ]; then
      echo "usage: vm-print <printer-ip> <file>   (PDF, PostScript, image, text)" >&2
      exit 2
    fi
    answer="$( { printf '%s\n' "$1"; cat -- "$2"; } | ${config.services.nox-rpc.package}/bin/nox-rpc print sys-print)"
    echo "$answer"
    [[ "$answer" == ok* ]]
  '';
in
{
  imports = [
    inputs.nox.nixosModules.relay
    inputs.nox.nixosModules.rpc
  ];

  config = lib.mkIf (config.microvm.hypervisor == "xen" && (githubAgent || dbus || wprs || ssh)) (
    lib.mkMerge [
      {
        services.nox-relay.guest = {
          enable = true;
          listen =
            lib.optionalAttrs githubAgent {
              github-agent = {
                path = "/tmp/ssh-github-agent.sock";
                inherit owner;
              };
            }
            // lib.optionalAttrs dbus {
              dbus = {
                path = "/tmp/ssh_dbus.sock";
                inherit owner;
              };
            }
            // lib.optionalAttrs wprs {
              pulse = {
                path = "/tmp/wprs-pulse";
                inherit owner;
              };
            }
            // lib.optionalAttrs microphone {
              pulse-mic = {
                path = "/tmp/wprs-pulse-mic";
                inherit owner;
              };
            };
          serve =
            lib.optionalAttrs wprs { wprs = "/run/user/1000/wprs.sock"; }
            // lib.optionalAttrs ssh { ssh = sshSocket; };
          # wprsd gets pages granted read-only to dom0 here (nox-relay
          # grants.rs), never /dev/xen/gntalloc itself
          grants = lib.mkIf wprsGrants {
            path = "/run/wprs-grants.sock";
            inherit owner;
          };
        };

        # gntalloc's limit is 1024 pages (4 MB, not even one 1080p buffer).
        # Half of the VM's grant table (Xen's default 64 frames = 32768
        # grants): the rest stays for the vchans, net and disks. Beyond it
        # wprsd sends the pixels of further windows over the stream.
        boot.kernelParams = lib.mkIf wprsGrants [ "xen_gntalloc.limit=16384" ];

        # wprsd has to run without an SSH login (GUI over vchan)
        users.users.user.linger = lib.mkIf wprs true;
      }

      (lib.mkIf ssh {
        # One sshd -i per connection on the relay's socket (same config and
        # host keys as the network sshd)
        systemd.sockets.sshd-vchan = {
          description = "SSH over vchan (nox-relay)";
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = sshSocket;
            Accept = true;
            SocketMode = "0600";
          };
        };
        systemd.services."sshd-vchan@" = {
          description = "SSH over vchan (one connection)";
          serviceConfig = {
            ExecStart = "-${config.services.openssh.package}/bin/sshd -i -f /etc/ssh/sshd_config";
            StandardInput = "socket";
            StandardError = "journal";
          };
        };

        # Stage B2: dom0 reaches the guest over vchan only, no sshd on the
        # network. sys-net keeps its admin link: dom0's internet in the test
        # phase goes through it (xen-migration.md, SSH target picture)
        services.openssh.openFirewall = lib.mkIf (vmName != "sys-net") (lib.mkDefault false);
      })

      # RPC (stage C): app VMs call (`vm-copy <vm> <files>`, `vm-print`) and
      # receive (~/Incoming/<source>); sys-print only takes `print` (C2). The
      # driver domains and the builder take part too (dom0's calls replace
      # SSH, xen-migration.md spec SSH removal); copy rules: registry `copy`.
      # With wprs, dom0 starts GUI apps by RPC (`app`, C3, `vm-gui`) with the
      # environment the wprs launcher sets
      {
        environment.systemPackages = lib.mkIf (vmName != "sys-print") [ vmPrint ];
        services.nox-rpc.guest = {
          enable = true;
          handlers = {
            # dom0's vm-clip (home/vm-management/vm-gui.nix): first line get|set,
            # then the text (set) or the answer (get); only dom0 calls
            # Liveness for dom0 (vm-clip, nox doctor, update-all pick rpc over SSH)
            ping = "echo ok";

            # nox doctor's probes (home/vm-management/vm-doctor.nix), one per
            # call: first line net|ip|wprsd|dbus, the answer on stdout
            doctor = ''
              if [ "$source" != dom0 ]; then
                echo "error: only dom0"
                exit 1
              fi
              IFS= read -r probe || exit 1
              XDG_RUNTIME_DIR="/run/user/$(id -u)"
              export XDG_RUNTIME_DIR
              case "$probe" in
                net)
                  ${pkgs.getent}/bin/getent hosts cache.nixos.org >/dev/null &&
                    ${pkgs.curl}/bin/curl -sS -m 10 -o /dev/null -w "%{http_code}" https://cache.nixos.org/nix-cache-info
                  ;;
                ip) ${pkgs.curl}/bin/curl -sS -m 10 https://api.ipify.org ;;
                wprsd) ${pkgs.systemd}/bin/systemctl --user is-active wprsd ;;
                dbus)
                  ${pkgs.systemd}/bin/busctl --address=unix:path=/tmp/ssh_dbus.sock --timeout=3 call \
                    org.freedesktop.Notifications /org/freedesktop/Notifications \
                    org.freedesktop.Notifications GetServerInformation >/dev/null && echo ok
                  ;;
                *) echo "error: probe net|ip|wprsd|dbus"; exit 1 ;;
              esac
            '';

            # One-time copy into dom0 (dom0's `vm-pull` / `nox pull`, Qubes
            # `qvm-run --pass-io` model): only dom0 calls, only plain files
            # directly in ~/outbox. First line `list` (name<TAB>bytes per line)
            # or `get <name>` (answer `ok <bytes>`, then the file zstd-compressed:
            # sparse images like kali.raw would send their holes as zeros)
            pull = ''
              if [ "$source" != dom0 ]; then
                echo "error: only dom0"
                exit 1
              fi
              IFS= read -r line || exit 1
              dir="''${HOME:-/home/user}/outbox"
              case "$line" in
                list)
                  [ -d "$dir" ] || exit 0
                  ${pkgs.findutils}/bin/find "$dir" -mindepth 1 -maxdepth 1 -type f -printf '%f\t%s\n'
                  ;;
                "get "*)
                  name="''${line#get }"
                  if ! [[ "$name" =~ ^[A-Za-z0-9_+-][A-Za-z0-9._+-]*$ ]]; then
                    echo "error: bad name"
                    exit 1
                  fi
                  f="$dir/$name"
                  if [ -L "$f" ] || [ ! -f "$f" ]; then
                    echo "error: no file $name in ~/outbox"
                    exit 1
                  fi
                  echo "ok $(stat -c %s "$f")"
                  exec ${pkgs.zstd}/bin/zstd -q -c -T0 -3 <"$f"
                  ;;
                *) echo "error: list | get <name>"; exit 1 ;;
              esac
            '';

            clip = lib.mkIf wprs ''
              if [ "$source" != dom0 ]; then
                echo "error: only dom0"
                exit 1
              fi
              IFS= read -r action || exit 1
              case "$action" in
                get | set) exec /run/current-system/sw/bin/vm-clip-helper "$action" ;;
                *) echo "error: clip get|set"; exit 1 ;;
              esac
            '';
          };
          apps = lib.mkIf wprs {
            enable = true;
            after = [ "wprsd.service" ];
            environment = {
              WAYLAND_DISPLAY = "wprs-0";
              DISPLAY = ":100";
              XDG_SESSION_TYPE = "wayland";
              # the VM's own pipewire-pulse (vms/modules/wprs.nix)
              PULSE_SERVER = "unix:/run/user/1000/pulse/native";
              # Dark (nox.theme.dark): GTK3 by theme; libadwaita reads the
              # color scheme from the settings portal, which VMs lack
              # (dconf's default in common-config.nix did not reach Bottles
              # in win)
              GTK_THEME = if theme.dark then "Adwaita:dark" else "Adwaita";
              ADW_DEBUG_COLOR_SCHEME = if theme.dark then "prefer-dark" else "prefer-light";
              # nox.theme.cursor for apps that draw their own cursor (without
              # it they fell back to "default", smaller than dom0's); the
              # size comes from dom0 (vm-gui)
              XCURSOR_THEME = theme.cursor.name;
              # dom0's filtered bus where forwarded, else the VM's own
              # session bus: without one dconf can't save (Bottles closed
              # every bottle it opened, win 2026-10-16)
              DBUS_SESSION_BUS_ADDRESS =
                if dbus then "unix:path=/tmp/ssh_dbus.sock" else "unix:path=/run/user/1000/bus";
            };
          };
        };
      }

      # ... and no admin interface (only for VMs that use net-config)
      (lib.optionalAttrs (options.services ? net-config) {
        services.net-config.adminInterface = lib.mkDefault (vmName == "sys-net");
      })
    ]
  );
}

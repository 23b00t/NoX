# Guest side of nox-relay (v2.8.4, NoX flake input): sockets from dom0 over a
# vchan instead of SSH forwards. Xen VMs only, at the paths the SSH forwards
# used:
# - GitHub agent (registry `allowGitHubAgent`)
# - filtered session bus, notifications + tray (`enableHostDbusForward`)
# - SSH (VMs with sshd, only the builder): dom0's ssh reaches sshd -i (socket-activated per
#   connection) instead of the admin network (stage B, ProxyCommand in
#   home/ssh.nix); stage B2 drops the admin interface (except sys-net)
# - wprs (VMs with wprsd, vms/modules/wprs.nix): dom0's wprsc reaches wprsd,
#   apps get dom0's pulse socket at /tmp/wprs-pulse (`vm-gui` in dom0)
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
  ssh = config.services.openssh.enable;
  sshSocket = "/run/sshd-vchan.sock";
  # uid/gid of `user` in the VMs
  owner = "1000:100";

  # `check-rsync send|recv rsync --server …`: the rsync server command of a
  # home backup/restore (handlers backup-send/backup-recv below) may only
  # carry these words
  checkRsync = pkgs.writeShellScript "check-rsync" ''
    mode="$1"
    shift
    [ "$1" = rsync ] && [ "$2" = --server ] || exit 1
    shift 2
    if [ "$mode" = send ]; then
      [ "$1" = --sender ] || exit 1
      shift
    fi
    # The path part: exactly ". /home/user/"
    [ $# -ge 3 ] && [ "''${*: -2:1}" = . ] && [ "''${*: -1}" = /home/user/ ] || exit 1
    set -- "''${@:1:$#-2}"
    upd=0
    for w in "$@"; do
      case "$w" in
        -[A-Za-z]*)
          # Short flags plus rsync's capability string (after the dot)
          [[ "$w" =~ ^-[A-Za-z]+(\.[A-Za-z]*)?$ ]] || exit 1
          [[ "''${w%%.*}" == *u* ]] && upd=1
          ;;
        --numeric-ids | --no-msgs2stderr | --timeout=[0-9]* | --info=[A-Z0-9,]*) ;;
        *) exit 1 ;;
      esac
    done
    [ "$mode" = send ] || [ "$upd" = 1 ]
  '';

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
            };
          serve =
            lib.optionalAttrs wprs { wprs = "/run/user/1000/wprs.sock"; }
            // lib.optionalAttrs ssh { ssh = sshSocket; };
        };

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

            # home backup (dom0's vm-backup, README "Backup"): only disp-backup
            # calls (nox-rpcd policy too). First line: the rsync server command
            # its rsync sends, checked word by word: only known rsync options,
            # /home/user as the only path; send = read-only sender, recv must
            # be --update (-u: never deletes, newer files stay). A rejected
            # line answers with the reason (rsync then stops and shows it)
            # instead of failing silently (2026-10-21: rsync 3.5 sends
            # --info=STATS, the old check refused it and rsync hung)
            backup-send = ''
              if [ "$source" != disp-backup ]; then
                echo "error: only disp-backup"
                exit 1
              fi
              IFS= read -r line || exit 1
              read -ra args <<<"$line"
              if ! ${checkRsync} send "''${args[@]}"; then
                echo "error: backup-send refused: $line"
                exit 1
              fi
              cd /home/user && exec ${pkgs.rsync}/bin/rsync "''${args[@]:1}"
            '';

            backup-recv = ''
              if [ "$source" != disp-backup ]; then
                echo "error: only disp-backup"
                exit 1
              fi
              IFS= read -r line || exit 1
              read -ra args <<<"$line"
              if ! ${checkRsync} recv "''${args[@]}"; then
                echo "error: backup-recv refused: $line"
                exit 1
              fi
              cd /home/user && exec ${pkgs.rsync}/bin/rsync "''${args[@]:1}"
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
              PULSE_SERVER = "unix:/tmp/wprs-pulse";
              # Dark: GTK3 by theme; libadwaita reads the color scheme from
              # the settings portal, which VMs lack (dconf's default in
              # common-config.nix did not reach Bottles in win)
              GTK_THEME = "Adwaita:dark";
              ADW_DEBUG_COLOR_SCHEME = "prefer-dark";
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

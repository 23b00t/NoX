{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  vmScriptLib = import ./vm-script-lib.nix { };
  # Image domains (Whonix) run as xen-image@<name>, not microvm@<name>
  imageDomainNames = builtins.concatStringsSep " " (map (d: d.name) vmRegistry.imageDomains);
  # Image domains whose terminal is foot from the store disk (Whonix-Gateway)
  footImageNames = builtins.concatStringsSep " " (
    builtins.attrNames (
      lib.filterAttrs (_: d: d.foot or false) (config.services.xen-image-domains.domains or { })
    )
  );

  vmCases = vmScriptLib.vmCaseBlock {
    vms = vmRegistry.vms ++ vmRegistry.imageDomains;
    assignments = [
      {
        shellName = "FULL_NAME";
        attr = "name";
      }
      {
        shellName = "VM_USER";
        valueFrom = vmScriptLib.vmUser;
      }
      {
        shellName = "RELAY_GUI";
        valueFrom = vm: if relayListen vm ? wprs then 1 else 0;
      }
    ];
  };

  vmList = vmScriptLib.vmList (vmRegistry.vms ++ vmRegistry.imageDomains);
  # Xen guests with wprsd (nox-relay serves it): GUI apps and terminals over
  # vm-gui (wprs + app start by RPC)
  relayListen = vm: (config.services.nox-relay.host.guests or { }).${vm.name}.listen or { };

  vmRunner = pkgs.writeShellScriptBin "vm-run" ''
        #!/usr/bin/env bash
        set -eu

        CLI_MODE=0
        PRINT_USER=0
        EXTRA_SSH_ARGS=()

        usage() {
          echo "Usage: vm-run [-c] [-u] [-e <ssh-arg>]... <vm-name-or-short> <binary> [args...]" >&2
          echo "  -c: in a terminal of the VM (foot over wprs; the builder: SSH, -e for ssh)" >&2
          echo "       vm-run -u <vm-name-or-short>" >&2
          echo "Example: vm-run -c coding htop; vm-run -c -e -v builder uptime" >&2
          echo "Available VMs:" >&2
          cat <<EOF >&2
    ${vmList}
    EOF
          exit 1
        }

        while getopts ":cue:h" opt; do
          case "$opt" in
            c) CLI_MODE=1 ;;
            u) PRINT_USER=1 ;;
            e) EXTRA_SSH_ARGS+=("$OPTARG") ;;
            h) usage ;;
            :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
            \?) echo "Unknown option: -$OPTARG" >&2; usage ;;
          esac
        done
        shift $((OPTIND -1))

        if [ $# -lt 1 ]; then
          usage
        fi

        VM_KEY="$1"
        shift

        case "$VM_KEY" in
    ${vmCases}
          *)
            echo "Error: Unknown VM '$VM_KEY'" >&2
            exit 1
            ;;
        esac

        if [ "$PRINT_USER" -eq 1 ]; then
          echo "$VM_USER"
          exit 0
        fi

        if [ $# -lt 1 ]; then
          usage
        fi

        BINARY="$1"
        shift

        SERVICE="microvm@$FULL_NAME.service"
        # shellcheck disable=SC2194 # the list is filled in by Nix
        case " ${imageDomainNames} " in
          *" $FULL_NAME "*) SERVICE="xen-image@$FULL_NAME.service" ;;
        esac

        if ! systemctl is-active --quiet "$SERVICE"; then
          # At boot the autostart VMs wait for nox-sys.target with a queued start
          # job: wait for it instead of starting again (polkit asked for the
          # password once per VM at niri's autostart, xmg 2026-10-19)
          if [ -n "$(systemctl list-jobs --no-legend "$SERVICE")" ]; then
            ${pkgs.libnotify}/bin/notify-send "Waiting for VM: $FULL_NAME" "It is still starting..."
            for _ in $(seq 300); do
              [ -z "$(systemctl list-jobs --no-legend "$SERVICE")" ] && break
              sleep 1
            done
          else
            ${pkgs.libnotify}/bin/notify-send "Starting VM: $FULL_NAME" "Please wait..."
            systemctl start "$SERVICE"
          fi
        fi

        # -c (nox exec): no SSH into the guests (xen-migration.md, spec rest of
        # step 2): a terminal in the VM runs the command and stays open. Only
        # the builder keeps SSH (dom0-update)
        if [ "$CLI_MODE" -eq 1 ] && [ "$RELAY_GUI" -eq 1 ] && [ "$FULL_NAME" != builder ]; then
          cmd="$BINARY"
          [ $# -eq 0 ] || cmd="$cmd $(printf '%q ' "$@")"
          # shellcheck disable=SC2194 # the list is filled in by Nix
          case " ${footImageNames} " in
            *" $FULL_NAME "*) exec vm-gui "$FULL_NAME" /nix/store/nox/bin/foot --hold sh -c "$cmd" ;;
          esac
          # shellcheck disable=SC2194 # the list is filled in by Nix
          case " ${imageDomainNames} " in
            *" $FULL_NAME "*)
              exec vm-gui "$FULL_NAME" x-terminal-emulator -e sh -c "$cmd; echo; read -r -p 'Enter: close ' _"
              ;;
            *) exec vm-gui "$FULL_NAME" foot --hold sh -c "$cmd" ;;
          esac
        fi

        if [ "$RELAY_GUI" -eq 1 ] && [ "$CLI_MODE" -eq 0 ]; then
          # Xen guest: wprs over vchan, app started by RPC (stage C3), no SSH
          exec vm-gui "$FULL_NAME" "$BINARY" "$@"
        fi

        # Without wprs only the builder is reachable, by SSH over vchan (its
        # host entry and relay ProxyCommand: home/ssh.nix); the other domains
        # have no sshd (xen-migration.md, SSH removal)
        if [ "$FULL_NAME" != builder ]; then
          echo "vm-run: $FULL_NAME has no wprs and no SSH (emergency: sudo xl console $FULL_NAME-vm)" >&2
          exit 1
        fi
        if [ "$CLI_MODE" -eq 0 ]; then
          echo "vm-run: the builder runs no wprs, use vm-run -c builder <cmd> (SSH)" >&2
          exit 1
        fi
        exec ssh "''${EXTRA_SSH_ARGS[@]}" -t builder -- "$BINARY" "$@"
  '';
in
{
  environment.systemPackages = [ vmRunner ];
}

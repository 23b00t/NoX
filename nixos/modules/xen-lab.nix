# `vm-lab attach|detach <vm>`, `vm-lab status`: hangs a labTarget VM
# (registry) on sys-firewall's lab bridge vm-lab while kali tests its apps, and
# takes it off again. Only registry labTarget VMs; the vif is not persistent
# (gone after a restart of the VM or sys-firewall, attach again). Guest side:
# vms/modules/lab-target.nix, bridge and filter: vms/sys-firewall.
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  cfg = config.services.xen-lab;
  xen = config.virtualisation.xen.package;

  targets = builtins.filter (vm: vm.labTarget or false) vmRegistry.vms;
  octet = vm: lib.toInt (lib.last (lib.splitString "." vm.ip));
  mac = vm: "00:00:00:00:03:${lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString (octet vm)))}";

  # "name short mac address" per line
  table = lib.concatMapStrings (
    vm: "${vm.name} ${vm.short} ${mac vm} 10.5.0.${toString (octet vm)}\n"
  ) targets;

  vmLab = pkgs.writeShellScriptBin "vm-lab" ''
    set -euo pipefail
    PATH=${
      lib.makeBinPath [
        xen
        pkgs.coreutils
        pkgs.gnugrep
      ]
    }:/run/wrappers/bin

    usage() {
      echo "usage: vm-lab attach|detach <vm> | status   (targets: ${
        lib.concatMapStringsSep ", " (vm: vm.name) targets
      })" >&2
      exit 2
    }

    table='${table}'

    # name mac address of a target, by name or short name
    lookup() {
      local name short m addr
      while read -r name short m addr; do
        [ -n "$name" ] || continue
        if [ "$1" = "$name" ] || [ "$1" = "$short" ]; then
          echo "$name $m $addr"
          return 0
        fi
      done <<< "$table"
      echo "vm-lab: $1 is no lab target (registry labTarget)" >&2
      exit 1
    }

    attached() { sudo xl network-list "$1-vm" 2>/dev/null | grep -qi " $2 "; }

    case "''${1:-}" in
      attach | detach)
        [ $# -eq 2 ] || usage
        # set -e ends the script here when lookup fails
        entry="$(lookup "$2")"
        read -r name m addr <<< "$entry"
        sudo xl domid "$name-vm" >/dev/null 2>&1 || { echo "vm-lab: $name is not running" >&2; exit 1; }
        ;;
    esac

    case "''${1:-}" in
      attach)
        sudo xl domid sys-firewall-vm >/dev/null 2>&1 || { echo "vm-lab: sys-firewall is not running" >&2; exit 1; }
        if attached "$name" "$m"; then
          echo "vm-lab: $name is already on the lab bridge ($addr)"
          exit 0
        fi
        sudo xl network-attach "$name-vm" mac="$m" bridge=vm-lab backend=sys-firewall-vm
        echo "vm-lab: $name attached, reachable from kali at $addr"
        ;;
      detach)
        if ! attached "$name" "$m"; then
          echo "vm-lab: $name is not on the lab bridge"
          exit 0
        fi
        sudo xl network-detach "$name-vm" "$m"
        echo "vm-lab: $name detached"
        ;;
      status)
        while read -r name short m addr; do
          [ -n "$name" ] || continue
          if ! sudo xl domid "$name-vm" >/dev/null 2>&1; then
            state="not running"
          elif attached "$name" "$m"; then
            state="attached"
          else
            state="detached"
          fi
          printf '%-10s %-4s %-12s %s\n' "$name" "$short" "$addr" "$state"
        done <<< "$table"
        ;;
      *) usage ;;
    esac
  '';
in
{
  options.services.xen-lab.enable = lib.mkEnableOption "the `vm-lab` command (kali lab bridge in sys-firewall)";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ vmLab ];
  };
}

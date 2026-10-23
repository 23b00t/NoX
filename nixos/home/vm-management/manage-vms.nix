{ pkgs, vmRegistry, ... }:
let
  vmNames = builtins.concatStringsSep " " (map (vm: vm.name) vmRegistry.vms);
  # Image domains (Whonix, kali) run as xen-image@<name>, MicroVMs as
  # microvm@<name>; both are handled the same way here
  imageNames = builtins.concatStringsSep " " (map (d: d.name) vmRegistry.imageDomains);
  # registry `disposable`: only these take --fresh
  disposableNames = builtins.concatStringsSep " " (
    map (vm: vm.name) (builtins.filter (vm: vm.disposable or false) vmRegistry.vms)
  );
  # name=group pairs for VMs with a shared store image (registry `storeGroup`)
  vmGroups = builtins.concatStringsSep " " (
    map (vm: "[${vm.name}]=${vm.storeGroup}") (
      builtins.filter (vm: (vm.storeGroup or null) != null) vmRegistry.vms
    )
  );
in
pkgs.writeShellScriptBin "manage-vms" ''
  #!/usr/bin/env bash
  set -eu

  IMAGE_DOMAINS=( ${imageNames} )
  ALL_VMS=( ${vmNames} "''${IMAGE_DOMAINS[@]}" )
  declare -A STORE_GROUP=( ${vmGroups} )
  DISPOSABLE=( ${disposableNames} )
  FRESH=0
  STATE_DIR=/var/lib/microvms
  RUNNING_ONLY=0
  STALE_ONLY=0
  GROUP=""
  NAMES=()

  usage() {
    cat <<EOF >&2
Usage:
  manage-vms status [<vm>...] [--running] [--group <group>] [--stale]
  manage-vms <start|stop|restart|reload> [<vm>...] [--running] [--group <group>] [--stale]
  manage-vms <start|restart> --fresh <vm>...

  <vm>...          these VMs (default: all), narrowed by the filters
  --group <group>  only VMs of this store group (registry storeGroup)
  --stale          only running VMs whose store image differs from the
                   current one (e.g. after a group update)
  --fresh          disposable VMs only (registry disposable): stop, set all
                   their volume images aside (<image>.pre-fresh, needs sudo),
                   start with empty ones. Back: stop the VM, move the
                   .pre-fresh files back, start it

A VM that gets started or restarted gets its tray apps again (vm-tray).

Examples:
  manage-vms status
  manage-vms status --running
  manage-vms start chat
  manage-vms restart --running
  manage-vms restart --stale
  manage-vms restart --group desktop
EOF
    exit 1
  }

  # systemd unit of a VM or image domain
  unit_of() {
    case " ''${IMAGE_DOMAINS[*]} " in
      *" $1 "*) echo "xen-image@$1.service" ;;
      *) echo "microvm@$1.service" ;;
    esac
  }

  # Store image a runner boots from ("-" if it has none, e.g. virtiofs store)
  store_image() {
    local runner="$1"
    [ -e "$runner" ] || { echo "-"; return; }
    nix-store -qR "$runner" 2>/dev/null | grep -m1 -- '-microvm-store-disk\.' || echo "-"
  }

  # ok | stale | - (not running or no store image)
  image_state() {
    local vm="$1" booted current
    [ -e "$STATE_DIR/$vm/booted" ] || { echo "-"; return; }
    booted="$(store_image "$STATE_DIR/$vm/booted")"
    current="$(store_image "$STATE_DIR/$vm/current")"
    if [ "$booted" = "-" ]; then
      echo "-"
    elif [ "$booted" = "$current" ]; then
      echo "ok"
    else
      echo "stale"
    fi
  }

  resolve_targets() {
    local vm candidates=()
    TARGETS=()

    if [ "''${#NAMES[@]}" -gt 0 ]; then
      for vm in "''${NAMES[@]}"; do
        if [ "$RUNNING_ONLY" -eq 1 ] && ! systemctl is-active --quiet "$(unit_of "$vm")"; then
          continue
        fi
        candidates+=("$vm")
      done
    elif [ "$RUNNING_ONLY" -eq 1 ]; then
      while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        vm="''${unit#*@}"
        vm="''${vm%.service}"
        candidates+=("$vm")
      done < <(systemctl list-units --type=service --state=running --no-legend --no-pager \
        'microvm@*.service' 'xen-image@*.service' | awk '{print $1}')
    else
      candidates=("''${ALL_VMS[@]}")
    fi

    for vm in "''${candidates[@]}"; do
      if [ -n "$GROUP" ] && [ "''${STORE_GROUP[$vm]:-}" != "$GROUP" ]; then
        continue
      fi
      if [ "$STALE_ONLY" -eq 1 ] && [ "$(image_state "$vm")" != "stale" ]; then
        continue
      fi
      TARGETS+=("$vm")
    done
  }

  print_status_table() {
    local vm unit active substate enabled

    printf "%-14s %-10s %-12s %-10s %-9s %-6s\n" "VM" "ACTIVE" "SUBSTATE" "ENABLED" "GROUP" "IMAGE"
    printf "%-14s %-10s %-12s %-10s %-9s %-6s\n" "--------------" "----------" "------------" "----------" "---------" "------"

    for vm in "''${TARGETS[@]}"; do
      unit="$(unit_of "$vm")"

      active="$(systemctl is-active "$unit" 2>/dev/null || true)"
      [ -n "$active" ] || active="not-found"

      substate="$(systemctl show "$unit" -P SubState 2>/dev/null || true)"
      [ -n "$substate" ] || substate="-"

      enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
      [ -n "$enabled" ] || enabled="-"

      printf "%-14s %-10s %-12s %-10s %-9s %-6s\n" "$vm" "$active" "$substate" "$enabled" \
        "''${STORE_GROUP[$vm]:--}" "$(image_state "$vm")"
    done
  }

  # --fresh: stop each (disposable) target and set its volume images aside;
  # run_action then starts it with empty ones (the runner creates them)
  fresh_images() {
    local vm
    [ "''${#NAMES[@]}" -gt 0 ] || { echo "--fresh needs VM names" >&2; exit 1; }
    for vm in "''${TARGETS[@]}"; do
      case " ''${DISPOSABLE[*]} " in
        *" $vm "*) ;;
        *)
          echo "$vm is not disposable (registry), --fresh refused" >&2
          exit 1
          ;;
      esac
    done
    for vm in "''${TARGETS[@]}"; do
      echo "sudo systemctl stop $(unit_of "$vm")"
      sudo systemctl stop "$(unit_of "$vm")"
      # Image files are root's: sudo with password
      sudo sh -c 'cd "$1" || exit 0; for f in *.img; do [ -e "$f" ] || continue; mv -f "$f" "$f.pre-fresh" && echo "set aside: $1/$f.pre-fresh"; done' sh "$STATE_DIR/$vm"
    done
  }

  run_action() {
    local action="$1"
    local vm unit was rc=0

    for vm in "''${TARGETS[@]}"; do
      unit="$(unit_of "$vm")"
      was="$(systemctl is-active "$unit" 2>/dev/null || true)"
      echo "sudo systemctl $action $unit"
      # sudo: NOPASSWD for start/stop/restart of microvm@ and xen-image@ units
      sudo systemctl "$action" "$unit" || { rc=1; continue; }
      if command -v vm-tray >/dev/null &&
        { [ "$action" = restart ] || { [ "$action" = start ] && [ "$was" != active ]; }; }; then
        vm-tray "$vm"
      fi
    done
    return "$rc"
  }

  [ $# -ge 1 ] || usage

  COMMAND="$1"
  shift

  while [ $# -gt 0 ]; do
    case "$1" in
      --running)
        RUNNING_ONLY=1
        ;;
      --stale)
        STALE_ONLY=1
        ;;
      --fresh)
        FRESH=1
        ;;
      --group)
        [ $# -ge 2 ] || usage
        GROUP="$2"
        shift
        ;;
      -h|--help|help)
        usage
        ;;
      -*)
        echo "Unknown argument: $1" >&2
        usage
        ;;
      *)
        case " ''${ALL_VMS[*]} " in
          *" $1 "*) NAMES+=("$1") ;;
          *)
            echo "Unknown VM: $1" >&2
            exit 1
            ;;
        esac
        ;;
    esac
    shift
  done

  resolve_targets

  if [ "''${#TARGETS[@]}" -eq 0 ]; then
    echo "No matching VMs found."
    exit 0
  fi

  case "$COMMAND" in
    status)
      print_status_table
      ;;
    start|restart)
      [ "$FRESH" -eq 0 ] || fresh_images
      run_action "$COMMAND"
      ;;
    stop|reload)
      [ "$FRESH" -eq 0 ] || { echo "--fresh only with start or restart" >&2; exit 1; }
      run_action "$COMMAND"
      ;;
    *)
      echo "Unsupported command: $COMMAND" >&2
      usage
      ;;
  esac
''

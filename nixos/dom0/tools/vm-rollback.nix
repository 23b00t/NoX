# Rollback (`nox rollback|gc`, xen-migration.md "Konzept Rollback"):
# - vm-rollback <vm> [--gen n|mark | --mark | --reset]: a MicroVM's runner
#   from an older system generation (or its mark) as its `current`, VM
#   restarted. Configuration only, not data (that is `nox backup`)
# - vm-gc [--keep n] [--dry-run]: delete old system generations, then GC
#
# State in /var/lib/microvms/<vm> (root's):
# - `rollback`: the runner the VM is rolled back to (indirect GC root),
#   `rollback.info`: line 1 the system it was made under, line 2 the label
#   (generation number or "mark"). Holds over reboots of that system; the
#   activation of any other system (switch, update, rebuild, another boot
#   entry) drops it and sets `current` back to that system's runner
# - `mark`: one known-good runner per VM (indirect GC root): survives `nox gc`
{
  lib,
  pkgs,
  config,
  ...
}:
let
  microvms = builtins.attrNames (config.microvm.vms or { });

  common = ''
    state=/var/lib/microvms
    # Runner the install unit of a system links as `current`
    runner_of() { # <system> <vm>
      local unit="$1/etc/systemd/system/install-microvm-$2.service" exe
      [ -e "$unit" ] || return 1
      exe="$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$unit")"
      sed -n 's|^ln -sTf \(/nix/store/[^ ]*\) current$|\1|p' "$exe"
    }
  '';

  # Activation (switch and boot): a rollback made under another system is
  # dropped, `current` goes back to the new system's runner. A VM still
  # running the old runner shows as stale (nox doctor "runners current")
  rollbackSync = pkgs.writeShellScript "vm-rollback-sync" ''
    # The activation's PATH has no sed
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnused
      ]
    }:$PATH
    ${common}
    sys="$1"
    for info in "$state"/*/rollback.info; do
      [ -e "$info" ] || continue
      dir="''${info%/rollback.info}"
      vm="''${dir##*/}"
      [ "$(head -n1 "$info")" = "$sys" ] && continue
      if r="$(runner_of "$sys" "$vm")" && [ -n "$r" ]; then
        ln -sTf "$r" "$dir/current"
      fi
      rm -f "$dir/rollback" "$info"
      echo "vm-rollback: rollback of $vm dropped (new system)"
    done
  '';

  # Boot: the install units set `current` to the system's runner; a rollback
  # made under this system is put back before the VMs start
  rollbackRestore = pkgs.writeShellScript "vm-rollback-restore" ''
    PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
    ${common}
    sys="$(readlink -f /run/current-system)"
    for info in "$state"/*/rollback.info; do
      [ -e "$info" ] || continue
      dir="''${info%/rollback.info}"
      [ "$(head -n1 "$info")" = "$sys" ] || continue
      [ -e "$dir/rollback" ] || continue
      ln -sTf "$(readlink "$dir/rollback")" "$dir/current"
      echo "''${dir##*/}: rolled back ($(sed -n 2p "$info"))"
    done
  '';

  vmRollback = pkgs.writeShellScriptBin "vm-rollback" ''
    set -euo pipefail
    ${common}
    MICROVMS=" ${lib.concatStringsSep " " microvms} "
    usage() {
      cat >&2 <<EOF
    usage: vm-rollback <vm>             generations (and the mark) with a runner for <vm>
           vm-rollback <vm> --gen <n>   run <vm> from generation <n> (restarts it)
           vm-rollback <vm> --gen mark  run <vm> from its mark (restarts it)
           vm-rollback <vm> --mark      mark <vm>'s current runner as known good (one per VM)
           vm-rollback <vm> --reset     back to the running system's runner
    A rollback holds over reboots until another system is activated (update,
    rebuild) or --reset. The mark survives nox gc.
    --gen/--mark/--reset ask for sudo themselves: run vm-rollback as yourself, not with sudo
    EOF
      exit 2
    }

    restart() {
      echo "restarting $1"
      manage-vms restart "$1"
    }

    [ $# -ge 1 ] || usage
    vm="$1"
    shift
    [[ $MICROVMS == *" $vm "* ]] || { echo "$vm: not a MicroVM (image domains have no runner to roll back)" >&2; exit 2; }
    dir="$state/$vm"
    cur="$(readlink "$dir/current")"
    sys="$(runner_of /run/current-system "$vm")"
    mark="$(readlink "$dir/mark" 2>/dev/null || true)"

    when() { date -d "@$(stat -c %Y "$1")" '+%F %R'; }

    case "''${1:-}" in
      "")
        printf '%-6s %-20s %s\n' GEN DATE RUNNER
        running="$(readlink -f /run/current-system)" found=0
        for g in $(ls -d /nix/var/nix/profiles/system-*-link | sort -t- -k2 -n); do
          n="''${g##*/system-}"
          n="''${n%-link}"
          [ "$(readlink -f "$g")" = "$running" ] && found=1
          r="$(runner_of "$g" "$vm")" || continue
          [ -n "$r" ] || continue
          m=""
          [ "$r" = "$sys" ] && m+=" (running system)"
          [ "$r" = "$cur" ] && m+=" (current)"
          [ "$r" = "$mark" ] && m+=" (mark)"
          printf '%-6s %-20s %s%s\n' "$n" "$(when "$g")" "''${r#/nix/store/}" "$m"
        done
        # Activated without a generation (switch-to-configuration test)
        if [ "$found" = 0 ]; then
          m=" (running system)"
          [ "$sys" = "$cur" ] && m+=" (current)"
          [ "$sys" = "$mark" ] && m+=" (mark)"
          printf '%-6s %-20s %s%s\n' - "$(when /run/current-system)" "''${sys#/nix/store/}" "$m"
        fi
        if [ -n "$mark" ]; then
          m=""
          [ "$mark" = "$cur" ] && m=" (current)"
          printf '%-6s %-20s %s%s\n' mark "$(when "$dir/mark")" "''${mark#/nix/store/}" "$m"
        fi
        ;;
      --gen)
        [ $# -eq 2 ] || usage
        if [ "$2" = mark ]; then
          [ -n "$mark" ] || { echo "$vm has no mark (nox rollback $vm --mark)" >&2; exit 1; }
          r="$mark"
        else
          [[ $2 =~ ^[0-9]+$ ]] || usage
          g="/nix/var/nix/profiles/system-$2-link"
          [ -e "$g" ] || { echo "no generation $2" >&2; exit 1; }
          r="$(runner_of "$g" "$vm")"
          [ -n "$r" ] || { echo "generation $2 has no $vm" >&2; exit 1; }
        fi
        if [ "$r" = "$sys" ]; then
          echo "$vm: generation $2 has the running system's runner, use --reset" >&2
          exit 1
        fi
        # $state/<vm> belongs to the microvm user: the links need root.
        # rollback: GC root, the generation can be deleted (vm-gc) while
        # the rollback holds
        sudo nix-store --realise "$r" --add-root "$dir/rollback" >/dev/null
        printf '%s\n%s\n' "$(readlink -f /run/current-system)" "$2" | sudo tee "$dir/rollback.info" >/dev/null
        sudo ln -sTf "$r" "$dir/current"
        if [ "$2" = mark ]; then what=mark; else what="generation $2"; fi
        echo "$vm: current = $what (until another system is activated or --reset)"
        restart "$vm"
        ;;
      --mark)
        [ $# -eq 1 ] || usage
        sudo nix-store --realise "$cur" --add-root "$dir/mark" >/dev/null
        echo "$vm: mark = ''${cur#/nix/store/} (back to it with: nox rollback $vm --gen mark)"
        ;;
      --reset)
        [ $# -eq 1 ] || usage
        sudo ln -sTf "$sys" "$dir/current"
        sudo rm -f "$dir/rollback" "$dir/rollback.info"
        echo "$vm: current = running system"
        restart "$vm"
        ;;
      *) usage ;;
    esac
  '';

  vmGc = pkgs.writeShellScriptBin "vm-gc" ''
    set -euo pipefail
    keep=3 dry=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --keep) keep="$2"; shift ;;
        -n | --dry-run) dry=1 ;;
        *) echo "usage: vm-gc [--keep <n>] [--dry-run]   (default: keep 3 generations)" >&2; exit 2 ;;
      esac
      shift
    done
    [[ $keep =~ ^[1-9][0-9]*$ ]] || { echo "--keep: a number >= 1" >&2; exit 2; }
    mapfile -t gens < <(ls -d /nix/var/nix/profiles/system-*-link | sed 's|.*/system-\([0-9]*\)-link|\1|' | sort -n)
    old=("''${gens[@]:0:$(( ''${#gens[@]} > keep ? ''${#gens[@]} - keep : 0 ))}")
    running="$(readlink -f /run/current-system)"
    echo "generations: ''${gens[*]}"
    if [ "''${#old[@]}" -eq 0 ]; then
      echo "nothing to delete (keeping $keep)"
    else
      echo "deleting: ''${old[*]}"
    fi
    for g in "''${old[@]}"; do
      if [ "$(readlink -f "/nix/var/nix/profiles/system-$g-link")" = "$running" ]; then
        echo "generation $g is the running system: kept" >&2
        exit 1
      fi
    done
    if [ "$dry" = 1 ]; then
      # Store images outside the store (dom0/store-images.nix) the
      # deletion would free
      ! command -v nox-image >/dev/null || nox-image gc -n --drop "''${old[@]}"
      exit 0
    fi
    if [ "''${#old[@]}" -gt 0 ]; then
      sudo nix-env -p /nix/var/nix/profiles/system --delete-generations "''${old[@]}"
      # Boot menu without the deleted generations; the default entry stays the
      # profile's newest generation
      sudo "$(readlink -f /nix/var/nix/profiles/system)/bin/switch-to-configuration" boot
    fi
    sudo nix-store --gc
    # Store images no remaining generation, rollback or mark boots from
    ! command -v nox-image >/dev/null || sudo nox-image gc
  '';
in
{
  environment.systemPackages = [
    vmRollback
    vmGc
  ];

  # Runs on every switch and boot
  system.activationScripts.vmRollback = lib.mkIf (microvms != [ ]) ''
    ${rollbackSync} "$systemConfig"
  '';

  systemd.services.vm-rollback-restore = lib.mkIf (microvms != [ ]) {
    description = "Put back the VM rollbacks made under this system";
    after = map (n: "install-microvm-${n}.service") microvms;
    # Everything the install unit is before: set-booted, tap, pci, … read
    # `current` and must see the rollback runner
    before = lib.concatMap (
      n:
      map (u: "${u}@${n}.service") [
        "microvm"
        "microvm-set-booted"
        "microvm-tap-interfaces"
        "microvm-macvtap-interfaces"
        "microvm-pci-devices"
        "microvm-virtiofsd"
      ]
    ) microvms;
    wantedBy = [ "microvms.target" ];
    serviceConfig.Type = "oneshot";
    script = "${rollbackRestore}";
  };
}

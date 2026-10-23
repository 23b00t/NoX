# Rollback (`nox rollback|gc|snapshot`, xen-migration.md "Konzept Rollback"):
# - vm-rollback <vm> [--gen n | --reset]: a VM's runner from an older system
#   generation as its `current`, VM restarted. Holds until a switch installs
#   a changed runner for that VM (or --reset). Configuration only, not data
# - vm-rollback --data <vm>: the VM's images back from its snapshot
# - vm-snapshot <vm>: sparse copy of the VM's images (VM stopped), one per VM
# - vm-gc [--keep n] [--dry-run]: delete old system generations, then GC
{
  lib,
  pkgs,
  config,
  ...
}:
let
  imageDomains = config.services.xen-image-domains.domains or { };
  microvms = builtins.attrNames (config.microvm.vms or { });
  # Image domains: one disk image, unit xen-image@<name>
  imageCases = lib.concatStrings (
    lib.mapAttrsToList (n: d: "    ${n}) echo ${lib.escapeShellArg d.image} ;;\n") imageDomains
  );

  common = ''
    set -euo pipefail
    MICROVMS=" ${lib.concatStringsSep " " microvms} "
    state=/var/lib/microvms
    snapdir=/var/lib/microvms/.snapshots
    image_of() { # image domains: their disk image
      case "$1" in
    ${imageCases}    *) return 1 ;;
      esac
    }
    unit_of() {
      if [[ $MICROVMS == *" $1 "* ]]; then
        echo "microvm@$1.service"
      elif image_of "$1" >/dev/null; then
        echo "xen-image@$1.service"
      else
        echo "unknown VM: $1" >&2
        exit 2
      fi
    }
  '';

  vmRollback = pkgs.writeShellScriptBin "vm-rollback" ''
    ${common}
    usage() {
      cat >&2 <<EOF
    usage: vm-rollback <vm>             generations with another runner for <vm>
           vm-rollback <vm> --gen <n>   run <vm> from generation <n> (restarts it)
           vm-rollback <vm> --reset     back to the running system's runner
           vm-rollback --data <vm>      images back from the snapshot (vm-snapshot)
    EOF
      exit 2
    }

    # Runner the install unit of a system generation links as `current`
    runner_of() { # <system> <vm>
      local unit="$1/etc/systemd/system/install-microvm-$2.service" exe
      [ -e "$unit" ] || return 1
      exe="$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$unit")"
      sed -n 's|^ln -sTf \(/nix/store/[^ ]*\) current$|\1|p' "$exe"
    }

    restart() {
      echo "restarting $1"
      manage-vms restart "$1"
    }

    if [ "''${1:-}" = --data ]; then
      [ $# -eq 2 ] || usage
      vm="$2"
      unit="$(unit_of "$vm")"
      [ -d "$snapdir/$vm" ] || { echo "no snapshot of $vm (vm-snapshot $vm)" >&2; exit 1; }
      if systemctl is-active --quiet "$unit"; then
        echo "$vm is running: stop it first (nox stop $vm)" >&2
        exit 1
      fi
      echo "snapshot of $vm from $(cat "$snapdir/$vm/.taken")"
      read -r -p "replace the current images of $vm with it? [y/N] " a
      [ "$a" = y ] || exit 1
      for f in "$snapdir/$vm"/*; do
        dst="$(cat "$f.path" 2>/dev/null)" || continue
        echo "$dst"
        cp --sparse=always "$f" "$dst.rollback"
        chgrp kvm "$dst.rollback" && chmod 664 "$dst.rollback"
        mv "$dst.rollback" "$dst"
      done
      exit 0
    fi

    [ $# -ge 1 ] || usage
    vm="$1"
    shift
    [[ $MICROVMS == *" $vm "* ]] || { echo "$vm: not a MicroVM (image domains: --data only)" >&2; exit 2; }
    cur="$(readlink "$state/$vm/current")"
    sys="$(runner_of /run/current-system "$vm")"

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
          mark=""
          [ "$r" = "$sys" ] && mark+=" (running system)"
          [ "$r" = "$cur" ] && mark+=" (current)"
          printf '%-6s %-20s %s%s\n' "$n" "$(date -d "@$(stat -c %Y "$g")" '+%F %R')" "''${r#/nix/store/}" "$mark"
        done
        # Activated without a generation (switch-to-configuration test)
        if [ "$found" = 0 ]; then
          mark=" (running system)"
          [ "$sys" = "$cur" ] && mark+=" (current)"
          printf '%-6s %-20s %s%s\n' - "$(date -d "@$(stat -c %Y /run/current-system)" '+%F %R')" "''${sys#/nix/store/}" "$mark"
        fi
        ;;
      --gen)
        [ $# -eq 2 ] || usage
        g="/nix/var/nix/profiles/system-$2-link"
        [ -e "$g" ] || { echo "no generation $2" >&2; exit 1; }
        r="$(runner_of "$g" "$vm")"
        [ -n "$r" ] || { echo "generation $2 has no $vm" >&2; exit 1; }
        # GC root: the generation can be deleted (vm-gc) while the VM runs it
        root="''${XDG_STATE_HOME:-$HOME/.local/state}/vm-rollback"
        mkdir -p "$root"
        nix-store --realise "$r" --add-root "$root/$vm" >/dev/null
        ln -sTf "$r" "$state/$vm/current"
        echo "$vm: current = generation $2 (until a switch installs a new $vm or --reset)"
        restart "$vm"
        ;;
      --reset)
        [ $# -eq 1 ] || usage
        ln -sTf "$sys" "$state/$vm/current"
        rm -f "''${XDG_STATE_HOME:-$HOME/.local/state}/vm-rollback/$vm"
        echo "$vm: current = running system"
        restart "$vm"
        ;;
      *) usage ;;
    esac
  '';

  vmSnapshot = pkgs.writeShellScriptBin "vm-snapshot" ''
    ${common}
    [ $# -eq 1 ] || { echo "usage: vm-snapshot <vm>   (VM stopped; one snapshot per VM, replaces the last)" >&2; exit 2; }
    vm="$1"
    unit="$(unit_of "$vm")"
    if systemctl is-active --quiet "$unit"; then
      echo "$vm is running: stop it first (nox stop $vm)" >&2
      exit 1
    fi
    if img="$(image_of "$vm")"; then
      images=("$img")
    else
      # The VM's own volumes; the store overlay comes from the store
      images=()
      for f in "$state/$vm"/*.img; do
        case "''${f##*/}" in nix-store-overlay.img | log.img) continue ;; esac
        images+=("$f")
      done
    fi
    [ "''${#images[@]}" -gt 0 ] || { echo "$vm has no images" >&2; exit 1; }
    need=$(du -k --total "''${images[@]}" | tail -1 | cut -f1)
    free=$(df -k --output=avail "$state" | tail -1)
    if [ "$need" -gt $((free - 10 * 1024 * 1024)) ]; then
      echo "not enough space: $((need / 1024)) MB needed, $((free / 1024)) MB free (keeps 10 GB)" >&2
      exit 1
    fi
    tmp="$snapdir/.$vm.new"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    for f in "''${images[@]}"; do
      echo "$f ($(du -h "$f" | cut -f1))"
      cp --sparse=always "$f" "$tmp/''${f##*/}"
      echo "$f" >"$tmp/''${f##*/}.path"
    done
    date '+%F %R' >"$tmp/.taken"
    rm -rf "''${snapdir:?}/$vm"
    mv "$tmp" "$snapdir/$vm"
    echo "snapshot of $vm in $snapdir/$vm (back with: nox rollback --data $vm)"
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
    [ "$dry" = 0 ] || exit 0
    if [ "''${#old[@]}" -gt 0 ]; then
      sudo nix-env -p /nix/var/nix/profiles/system --delete-generations "''${old[@]}"
      # Boot menu without the deleted generations; the default entry stays the
      # profile's newest generation
      sudo "$(readlink -f /nix/var/nix/profiles/system)/bin/switch-to-configuration" boot
    fi
    sudo nix-store --gc
  '';
in
{
  environment.systemPackages = [
    vmRollback
    vmSnapshot
    vmGc
  ];
}

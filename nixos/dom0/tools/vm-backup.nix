# vm-backup (`nox backup`, README "Backup", spec in xen-migration.md
# "2. Backup"): backups onto an external LUKS disk that hangs on the
# disposable disp-backup (USB/IP from sys-usb; vms/disp-backup has the disk
# side). dom0 mounts no guest file system and has no SSH into the VMs:
# - home: /home/user of NixOS VMs, one generation per run with hard links to
#   the previous one (rsync in disp-backup against the VM's rpc services
#   `backup-send` / `backup-recv`, vms/modules/vchan-relay.nix).
# - full: whole disks (a VM's volumes, an image domain's raw image, dom0's
#   ~/.ssh, the builder's key) as sparse tar + zstd streams from dom0 into
#   disp-backup, one generation per run.
# NOX_BACKUP_TEST_DISK=<file> (hidden, for tests on the hp): a disk image
# file instead of the USB disk, formatted on first use.
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  vms = config.microvm.vms or { };
  imageDomains = config.services.xen-image-domains.domains or { };
  # home: every NixOS VM of this machine; `--all` = those with registry `backup`
  homeVms = builtins.filter (n: n != "disp-backup") (lib.attrNames vms);
  homeDefault = map (vm: vm.name) (
    builtins.filter (vm: builtins.elem vm.name homeVms) vmRegistry.backupVms
  );
  imageNames = lib.attrNames imageDomains;

  # full targets, one line each: "<target> <kind> <disk>=<path>…"; kind vm
  # (its volumes, disk = file name without .img), image (one raw file),
  # dom0 (only ~/.ssh: the images have their own targets, the rest comes
  # back from the config), builder (its signing key)
  fullTable = pkgs.writeText "vm-backup-full" (
    lib.concatStrings (
      lib.mapAttrsToList (
        name: vm:
        let
          disks = map (
            v:
            let
              path = if lib.hasPrefix "/" v.image then v.image else "/var/lib/microvms/${name}/${v.image}";
            in
            "${lib.removeSuffix ".img" (baseNameOf v.image)}=${path}"
          ) (vm.config.config.microvm.volumes or [ ]);
        in
        if name == "builder" then
          "builder builder key=/var/lib/builder/signing-key\n"
        else
          lib.optionalString (
            disks != [ ] && name != "disp-backup"
          ) "${name} vm ${lib.concatStringsSep " " disks}\n"
      ) vms
      ++ lib.mapAttrsToList (name: d: "${name} image image=${d.image}\n") imageDomains
    )
    + "dom0 dom0 ssh=/home/nx/.ssh\n"
  );

  vmBackup = pkgs.writeShellScriptBin "vm-backup" ''
    set -uo pipefail
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gawk
        pkgs.gnused
        pkgs.zstd
        pkgs.gnutar
        pkgs.pv
        pkgs.libnotify
      ]
    }:$PATH
    full=${fullTable}
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/nox-backup"
    level=3
    die() { echo "vm-backup: $*" >&2; exit 1; }
    usage() { # usage [exit code]: --help to stdout with 0, errors to stderr with 2
      local fd=2
      [ "''${1:-2}" = 0 ] && fd=1
      cat >&"$fd" <<'USAGE'
    nox backup (vm-backup): back up VMs onto the external LUKS backup disk
    (README "Backup" explains every case). Two kinds:
      home  /home/user of NixOS VMs
      full  whole disks: a VM's disks, an image domain's image, dom0's ~/.ssh,
            the builder's key
    Every run is a generation named by its start time, e.g. 2026-10-21_201500.

    home:
      nox backup <vm>...                    e.g. nox backup nvim chat
      nox backup --all                      the VMs with registry `backup`
      nox backup restore <vm>... | --all    newest generation; adds only, deletes nothing
      nox backup restore --from <gen> <vm>...
                                            a specific generation (names: nox backup list)
    full:
      nox backup disks <target>... | --all  the disks full can back up, with used space
      nox backup --full <target>...         e.g. nox backup --full coding nvim whonix-workstation
      nox backup --full coding:home,var     only these disks of coding
      nox backup --full dom0 builder        dom0's ~/.ssh, the builder's key
      nox backup --full --all               everything
      nox backup --full --level N ...       zstd level 1 (fast, big) .. 19 (slow, small), default 3
      nox backup restore --full <target>... | --all
                                            newest generation; replaces the disks (asks first)
      nox backup restore --full --from <gen> <target>...
                                            a specific generation
    disk:
      nox backup list                       all generations (home and full), free space
      nox backup prune home|full --keep N [<vm>...] [-n]
                                            delete all but the newest N per VM (-n: only show)
    USAGE
      exit "''${1:-2}"
    }
    ask() { local a; read -r -p "vm-backup: $1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; }
    # 1234567 → "1.2 MB" (no locale: decimal point)
    human() { LC_ALL=C numfmt --to=si --round=nearest --format=%.1f "''${1:-0}" | sed -E 's/([0-9])([kMGTP]?)$/\1 \2B/'; }
    clock() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

    # disp-backup's `backup` service: command on the first line (stdin of
    # call_in follows), its output, `exit <rc>` as the last line. The output
    # goes through `show` (rsync's progress drawn in place); the rc returns
    call() { call_in "$@" </dev/null; }
    call_in() { # call_in <command line> [label]
      local rcf rc
      rcf="$(mktemp)"
      { printf '%s\n' "$1"; cat; } | nox-rpc --dom0 backup disp-backup | show "''${2:-}" "$rcf"
      rc="$(cat "$rcf")"
      rm -f "$rcf"
      [[ "$rc" =~ ^[0-9]+$ ]] || { echo "vm-backup: no answer from disp-backup" >&2; return 1; }
      return "$rc"
    }
    # Output of a call: rsync's progress2 lines become one line "<label>
    # amount % rate ETA" redrawn in place, `exit N` goes to <rc file>,
    # "Total transferred file size" to $amountf, a full backup's "stored-bytes"
    # (compressed size on the disk) to $storedf, the rest is printed
    show() { # show <label> <rc file>
      gawk -v label="$1" -v rcf="$2" -v amountf="''${amountf:-/dev/null}" -v storedf="''${storedf:-/dev/null}" '
        function hum(x) { return x >= 1e9 ? sprintf("%.1f GB", x / 1e9) : x >= 1e6 ? sprintf("%.1f MB", x / 1e6) : sprintf("%.0f kB", x / 1e3) }
        BEGIN { RS = "[\r\n]+" }
        /^exit [0-9]+$/ { print $2 > rcf; next }
        /^ *[0-9,]+ +[0-9]+% / {
          # +0: a number, not a string (else "5000000" >= 1e9 compares as text)
          b = $1; gsub(",", "", b); b += 0
          printf "\r\033[2K  %-20s %9s %4s %11s  ETA %s", label, hum(b), $2, $3, $4
          drawn = 1; fflush(); next
        }
        /^Total transferred file size: / { t = $5; gsub(",", "", t); print t > amountf; next }
        /^stored-bytes [0-9]+$/ { print $2 > storedf; next }
        /^(Number of|Total |Literal |Matched |File list|sent |total size)/ { next }
        { if (drawn) { printf "\n"; drawn = 0 } print; fflush() }
        END { if (drawn) printf "\n" }
      '
    }
    # Progress of a stream: pv's byte counts (pv -n -b) → "<label> done/size %
    # rate ETA" and a total line over the run, both redrawn in place
    progress() { # progress <label> <size> <bytes before this one> <total bytes>
      gawk -v label="$1" -v size="$2" -v before="$3" -v total="$4" -v t0="$run_t0" '
        function hum(x) { return x >= 1e9 ? sprintf("%.1f GB", x / 1e9) : x >= 1e6 ? sprintf("%.1f MB", x / 1e6) : sprintf("%.0f kB", x / 1e3) }
        function eta(s) { s = int(s); return sprintf("%d:%02d", s / 60, s % 60) }
        function draw(b, now,   r, l1, l2, all) {
          if (now > ps) { r = (b - pb) / (now - ps); pb = b; ps = now; rate = rate ? 0.7 * rate + 0.3 * r : r }
          l1 = sprintf("  %-20s %9s/%-9s %3d%%  %11s  ETA %s", label, hum(b), hum(size), size ? 100 * b / size : 100, rate > 0 ? hum(rate) "/s" : "-", b >= size ? "0:00" : rate > 0 ? eta((size - b) / rate) : "?")
          all = before + b
          r = (now > t0) ? all / (now - t0) : 0
          l2 = sprintf("  %-20s %9s/%-9s %3d%%               ETA %s", "total", hum(all), hum(total), total ? 100 * all / total : 100, r > 0 ? eta((total - all) / r) : "?")
          printf "\r\033[2K%s\n\033[2K%s\033[1A\r", l1, l2
          fflush()
        }
        BEGIN { ps = systime(); pb = 0; printf "\n\033[1A" }
        { last = $1; draw($1, systime()) }
        # Stream ended: done, even where the estimate was too big (the
        # builder key: 4 kB estimated, 101 bytes); a failure shows in the summary
        END { if (last + 0 < size + 0) last = size; draw(last + 0, systime()); printf "\n\033[2K" }
      '
    }

    unit_of() {
      # shellcheck disable=SC2194 # the list is filled in by Nix
      case " ${lib.concatStringsSep " " imageNames} " in
        *" $1 "*) echo "xen-image@$1" ;;
        *) echo "microvm@$1" ;;
      esac
    }
    running() { systemctl is-active --quiet "$(unit_of "$1").service"; }
    wait_rpc() {
      for _ in $(seq 120); do
        [ "$(timeout 5 nox-rpc --dom0 ping "$1" </dev/null 2>/dev/null)" = ok ] && return 0
        sleep 1
      done
      return 1
    }

    session_open() {
      echo "vm-backup: starting disp-backup" >&2
      manage-vms start disp-backup >/dev/null || die "disp-backup does not start"
      trap session_close EXIT
      wait_rpc disp-backup || die "disp-backup does not answer"
      local open=open
      if [ -n "''${NOX_BACKUP_TEST_DISK:-}" ]; then
        # Test disk: an image file as xvdz instead of the USB disk
        [ -e "$NOX_BACKUP_TEST_DISK" ] || truncate -s 4G "$NOX_BACKUP_TEST_DISK" || die "cannot create $NOX_BACKUP_TEST_DISK"
        sudo /run/current-system/sw/bin/xl block-attach disp-backup-vm \
          "format=raw,vdev=xvdz,access=rw,target=$(realpath "$NOX_BACKUP_TEST_DISK")" || die "attach of the test disk failed"
        open="open-test"
      else
        # The backup disk by busid (it is not in the registry's USB inventory)
        vm-usb list
        read -r -p "busid of the backup disk: " busid
        vm-usb attach "$busid" disp-backup || die "attach of $busid failed"
      fi
      # Three tries; disp-backup answers 3 for a wrong passphrase
      local try rc
      for try in 1 2 3; do
        read -r -s -p "LUKS passphrase of the backup disk: " pw
        echo >&2
        rc=0
        printf '%s\n' "$pw" | call_in "$open" || rc=$?
        unset pw
        [ "$rc" = 0 ] && return 0
        [ "$rc" = 3 ] && [ "$try" -lt 3 ] && continue
        die "could not open the backup disk"
      done
    }
    session_close() {
      trap - EXIT
      rm -f "$sel_file"
      call close || echo "vm-backup: closing the disk failed, check before unplugging" >&2
      manage-vms stop disp-backup >/dev/null || true
      echo "vm-backup: disk locked, disp-backup stopped" >&2
    }

    # The whole output of a run also goes to $state/<name>.log
    start_log() {
      mkdir -p "$state"
      log="$state/$1.log"
      exec > >(tee -a "$log") 2>&1
    }

    # Summary: one row per element, then a notification; fails if one failed
    S_NAME=() S_STAT=() S_AMOUNT=() S_TIME=()
    note() { S_NAME+=("$1"); S_STAT+=("$2"); S_AMOUNT+=("$3"); S_TIME+=("$4"); }
    summary() { # summary <what> <generation or "">
      local i ok=0 bad=0
      echo
      echo "$1''${2:+, generation $2}:"
      for i in "''${!S_NAME[@]}"; do
        printf '  %-28s %-6s %10s %8s\n' "''${S_NAME[$i]}" "''${S_STAT[$i]%%:*}" "''${S_AMOUNT[$i]}" "''${S_TIME[$i]}"
        if [ "''${S_STAT[$i]}" = OK ] || [[ "''${S_STAT[$i]}" == SKIPPED* ]]; then ok=$((ok + 1)); else bad=$((bad + 1)); printf '      %s\n' "''${S_STAT[$i]#*: }"; fi
      done
      echo "log: $log"
      notify-send -a vm-backup "$1 done" "$ok OK, $bad failed" 2>/dev/null || true
      [ "$bad" = 0 ]
    }

    # Starts <vm> if it is down; `started` remembers it for `stop_again`
    start_for() { # start_for <vm>
      started=0
      # A running VM may still be booting: wait for its rpc too
      running "$1" && { wait_rpc "$1"; return; }
      started=1
      sudo systemctl start "$(unit_of "$1")" && wait_rpc "$1"
    }
    stop_again() { [ "$started" = 0 ] || sudo systemctl stop "$(unit_of "$1")"; }

    # ---------- home ----------
    home_backup() { # home_backup <vm>…
      local vm i=0 t amountf
      for vm in "$@"; do
        i=$((i + 1))
        echo "[$i/$#] $vm"
        t=$SECONDS
        if ! start_for "$vm"; then
          note "$vm" "FAILED: does not start or answer" - -
          stop_again "$vm"
          continue
        fi
        amountf="$(mktemp)"
        if amountf="$amountf" call "home-backup $vm $gen" "$vm"; then
          note "$vm" OK "$(human "$(cat "$amountf" 2>/dev/null)")" "$(clock $((SECONDS - t)))"
        else
          note "$vm" "FAILED: see the output above" - "$(clock $((SECONDS - t)))"
        fi
        rm -f "$amountf"
        stop_again "$vm"
      done
    }
    home_restore() { # home_restore <gen|latest> <vm>…
      local from="$1" vm i=0 t
      shift
      for vm in "$@"; do
        i=$((i + 1))
        echo "[$i/$#] $vm"
        t=$SECONDS
        if ! start_for "$vm"; then
          note "$vm" "FAILED: does not start or answer" - -
          stop_again "$vm"
          continue
        fi
        if call "home-restore $vm $from" "$vm"; then
          note "$vm" OK - "$(clock $((SECONDS - t)))"
        else
          note "$vm" "FAILED: see the output above" - "$(clock $((SECONDS - t)))"
        fi
        stop_again "$vm"
      done
    }

    # ---------- full ----------
    kind_of() { awk -v n="$1" '$1 == n { print $2 }' "$full"; }
    disks_of() { awk -v n="$1" '$1 == n { for (i = 3; i <= NF; i++) { split($i, a, "="); print a[1] } }' "$full"; }
    path_of() { awk -v n="$1" -v d="$2" '$1 == n { for (i = 3; i <= NF; i++) { split($i, a, "="); if (a[1] == d) print a[2] } }' "$full"; }
    # Bytes of data (holes not counted) of one disk
    used_of() { # used_of <target> <disk>
      case "$(kind_of "$1")" in
        dom0) du -sB1 "$HOME/.ssh" | cut -f1 ;;
        builder) echo 4096 ;;
        *) if [ -e "$(path_of "$1" "$2")" ]; then du -B1 "$(path_of "$1" "$2")" | cut -f1; else echo 0; fi ;;
      esac
    }
    size_of() { # size_of <target> <disk>: apparent size
      case "$(kind_of "$1")" in
        dom0 | builder) used_of "$1" "$2" ;;
        *) stat -c %s "$(path_of "$1" "$2")" 2>/dev/null || echo 0 ;;
      esac
    }
    # Targets "<target>[:<disk>,…]" → lines "<target> <disk>…"; dies on
    # unknown names (call it outside a subshell)
    expand_targets() {
      local t name disks d
      for t in "$@"; do
        name="''${t%%:*}"
        [ -n "$(kind_of "$name")" ] || die "unknown target: $name (see nox backup disks --all)"
        if [ "$t" = "$name" ]; then
          echo "$name $(disks_of "$name" | tr '\n' ' ')"
        else
          disks="''${t#*:}"
          for d in ''${disks//,/ }; do
            disks_of "$name" | grep -qx "$d" || die "$name has no disk $d (see nox backup disks $name)"
          done
          echo "$name ''${disks//,/ }"
        fi
      done
    }
    # One disk into disp-backup: the stream with its progress
    full_put_one() { # full_put_one <target> <disk> <used> <before> <total>
      local t="$1" d="$2" kind p file
      kind="$(kind_of "$t")"
      p="$(path_of "$t" "$d")"
      case "$kind" in
        builder) file=key.zst ;;
        dom0) file=ssh.tar.zst ;;
        *) file="$d.tar.zst" ;;
      esac
      {
        case "$kind" in
          builder) ssh builder sudo cat "$p" ;;
          # the agent sockets in ~/.ssh/agent are skipped without a warning
          dom0) tar -C "$HOME" -cS --warning=no-file-ignored -f - .ssh ;;
          # GNU tar finds the holes with SEEK_DATA: only data is read
          *) tar -C "$(dirname "$p")" -cS -f - "$(basename "$p")" ;;
        esac
      } | pv -f -n -b -i 1 2> >(progress "$t:$d" "$3" "$4" "$5" >&2) \
        | zstd -T0 -q -"$level" -c | call_in "full-put $t $gen $d $file $3"
    }
    full_backup() { # full_backup <line "<target> <disk>…">…
      local line t disks d total=0 before=0 used tt rc up=() i=0 storedf
      # Compressed size on the disk of each one (disp-backup, show)
      storedf="$(mktemp)"
      for line in "$@"; do
        t="''${line%% *}"
        for d in ''${line#* }; do total=$((total + $(used_of "$t" "$d"))); done
        case "$(kind_of "$t")" in vm | image) running "$t" && up+=("$t") ;; esac
      done
      if [ "''${#up[@]}" -gt 0 ]; then
        ask "stops and restarts for the copy: ''${up[*]}. Go on?" || die "aborted"
      fi
      echo "full backup: $(human "$total") to read (used blocks, stored compressed)"
      run_t0="$(date +%s)"
      for line in "$@"; do
        i=$((i + 1))
        t="''${line%% *}"
        disks="''${line#* }"
        echo "[$i/$#] $t"
        if printf '%s\n' "''${up[@]}" | grep -qx "$t"; then
          sudo systemctl stop "$(unit_of "$t")" || { note "$t" "FAILED: does not stop" - -; continue; }
        fi
        # The builder's key is read over SSH: started for it if it is down
        if [ "$(kind_of "$t")" = builder ] && ! start_for builder; then
          note "$t" "FAILED: does not start or answer" - -
          stop_again builder
          continue
        fi
        rc=0
        for d in $disks; do
          case "$(kind_of "$t")" in
            vm | image) [ -e "$(path_of "$t" "$d")" ] || { note "$t:$d" "SKIPPED: not created yet" - -; continue; } ;;
          esac
          tt=$SECONDS
          used="$(used_of "$t" "$d")"
          : >"$storedf"
          if full_put_one "$t" "$d" "$used" "$before" "$total"; then
            # What lands on the disk (compressed), as `nox backup list` shows it
            note "$t:$d" OK "$(human "$(cat "$storedf")")" "$(clock $((SECONDS - tt)))"
          else
            note "$t:$d" "FAILED: see the output above" - "$(clock $((SECONDS - tt)))"
            rc=1
          fi
          before=$((before + used))
        done
        if [ "$rc" = 0 ]; then
          call "full-commit $t $gen" || note "$t" "FAILED: generation not committed" - -
        else
          call "full-abort $t $gen"
          echo "  $t: nothing kept from this run (a disk failed)"
        fi
        if printf '%s\n' "''${up[@]}" | grep -qx "$t"; then
          sudo systemctl start "$(unit_of "$t")" || note "$t" "FAILED: does not start again" - -
        fi
        [ "$(kind_of "$t")" != builder ] || stop_again builder
      done
      rm -f "$storedf"
    }
    # Stream of one disk from disp-backup (checksum checked there first)
    fetch() { # fetch <target> <gen> <disk> <used> <before> <total>
      printf 'full-get %s %s %s\n' "$1" "$2" "$3" | nox-rpc --dom0 backup disp-backup | {
        IFS= read -r first
        if [ "$first" != ok ]; then
          echo "vm-backup: ''${first:-no answer from disp-backup}" >&2
          cat >/dev/null
          exit 1
        fi
        # The progress goes to stderr: stdout is the restored data
        zstd -d -q -c | pv -f -n -b -i 1 2> >(progress "$1:$3" "$4" "$5" "$6" >&2)
      }
    }
    full_get_one() { # full_get_one <target> <gen> <disk> <used> <before> <total>
      local t="$1" g="$2" d="$3" kind p dir stage parent
      kind="$(kind_of "$t")"
      p="$(path_of "$t" "$d")"
      case "$kind" in
        builder)
          # By hand: the builder's key is not overwritten from here
          stage="$HOME/nox-restore/$g"
          mkdir -p "$stage"
          fetch "$@" >"$stage/builder-signing-key" || return 1
          chmod 600 "$stage/builder-signing-key"
          echo "  the builder's key is in $stage/builder-signing-key; to put it back:"
          echo "    ssh builder sudo tee $p <$stage/builder-signing-key >/dev/null"
          ;;
        dom0)
          # By hand: dom0's files are not overwritten from here
          stage="$HOME/nox-restore/$g/dom0"
          mkdir -p "$stage"
          fetch "$@" | tar -C "$stage" -xS -f - || return 1
          echo "  dom0's files are in $stage (.ssh); copy back what you need, e.g."
          echo "    cp -a $stage/.ssh/. ~/.ssh/"
          ;;
        *)
          dir="$(dirname "$p")"
          stage="$dir/.nox-restore"
          # Missing folders (a new system, e.g. ~/vm-images/kali) belong to
          # the owner of the nearest existing parent, not to root
          if [ ! -d "$dir" ]; then
            parent="$dir"
            while [ ! -d "$parent" ]; do parent="$(dirname "$parent")"; done
            sudo -u "#$(stat -c %u "$parent")" -g "#$(stat -c %g "$parent")" mkdir -p "$dir" || return 1
          fi
          sudo mkdir -p "$stage" || return 1
          if ! fetch "$@" | sudo tar -C "$stage" -xS -f -; then
            sudo rm -rf "$stage"
            return 1
          fi
          [ -e "$stage/$(basename "$p")" ] || { echo "vm-backup: $d missing in the backup" >&2; sudo rm -rf "$stage"; return 1; }
          [ ! -e "$p" ] || sudo chown --reference="$p" "$stage/$(basename "$p")"
          sudo mv -f "$stage/$(basename "$p")" "$p" && sudo rm -rf "$stage"
          ;;
      esac
    }
    full_restore() { # full_restore <gen|latest> <line "<target> <disk>…">…
      local from="$1" line t g d info used tt total=0 before=0 up=() i=0 list="" k
      shift
      declare -A G=() U=()
      for line in "$@"; do
        t="''${line%% *}"
        if ! info="$(call "full-info $t $from")"; then
          note "$t" "FAILED: no full generation ''${from/latest/at all} of $t" - -
          continue
        fi
        g="$(awk '$1 == "gen" { print $2 }' <<<"$info")"
        G[$t]="$g"
        for d in ''${line#* }; do
          used="$(awk -v d="$d" '$1 == "disk" && $2 == d { print $4 }' <<<"$info")"
          if [ -z "$used" ]; then note "$t:$d" "FAILED: not in generation $g" - -; continue; fi
          U[$t:$d]="$used"
          total=$((total + used))
          list="$list $t:$d"
        done
        case "$(kind_of "$t")" in vm | image) running "$t" && up+=("$t") ;; esac
      done
      [ -n "$list" ] || return 1
      for k in "''${!G[@]}"; do echo "  $k: generation ''${G[$k]}"; done
      ask "replaces with the backup:$list''${up[*]:+ (stops and restarts: ''${up[*]})}. Sure?" || die "aborted"
      run_t0="$(date +%s)"
      for line in "$@"; do
        t="''${line%% *}"
        [ -n "''${G[$t]:-}" ] || continue
        i=$((i + 1))
        echo "[$i] $t (generation ''${G[$t]})"
        if printf '%s\n' "''${up[@]}" | grep -qx "$t"; then
          sudo systemctl stop "$(unit_of "$t")" || { note "$t" "FAILED: does not stop" - -; continue; }
        fi
        for d in ''${line#* }; do
          [ -n "''${U[$t:$d]:-}" ] || continue
          tt=$SECONDS
          if full_get_one "$t" "''${G[$t]}" "$d" "''${U[$t:$d]}" "$before" "$total"; then
            note "$t:$d" OK "$(human "''${U[$t:$d]}")" "$(clock $((SECONDS - tt)))"
          else
            note "$t:$d" "FAILED: see the output above; the old disk stays" - "$(clock $((SECONDS - tt)))"
          fi
          before=$((before + ''${U[$t:$d]}))
        done
        if printf '%s\n' "''${up[@]}" | grep -qx "$t"; then
          sudo systemctl start "$(unit_of "$t")" || note "$t" "FAILED: does not start again" - -
        fi
      done
    }
    show_disks() { # show_disks <target>…
      local t d line
      for t in "$@"; do
        [ -n "$(kind_of "$t")" ] || die "unknown target: $t (see nox backup disks --all)"
        line=""
        for d in $(disks_of "$t"); do
          case "$(kind_of "$t")" in
            vm | image) [ -e "$(path_of "$t" "$d")" ] || { line="$line   $d (not created yet)"; continue; } ;;
          esac
          line="$line   $d $(human "$(used_of "$t" "$d")") of $(human "$(size_of "$t" "$d")")"
        done
        printf '%-20s%s\n' "$t" "$line"
      done
    }

    # ---------- arguments ----------
    mapfile -t all_full < <(awk '{ print $1 }' "$full")
    home_all=( ${lib.concatStringsSep " " homeVms} )
    home_default=( ${lib.concatStringsSep " " homeDefault} )
    # Both write the chosen names/lines to $sel_file and die on bad names
    # (not in a subshell, so `die` ends the run)
    home_names() { # home_names <arg>…: --all or names, each a NixOS VM
      if [ "$1" = --all ]; then printf '%s\n' "''${home_default[@]}" >"$sel_file"; return; fi
      local v
      : >"$sel_file"
      for v in "$@"; do
        printf '%s\n' "''${home_all[@]}" | grep -qx "$v" \
          || die "$v: not a NixOS VM of this machine (home takes: ''${home_all[*]})"
        echo "$v" >>"$sel_file"
      done
    }
    full_args() { # full_args <arg>…: --all or targets
      if [ "$1" = --all ]; then expand_targets "''${all_full[@]}" >"$sel_file"; else expand_targets "$@" >"$sel_file"; fi
    }
    sel_file="$(mktemp)"
    trap 'rm -f "$sel_file"' EXIT

    [ $# -gt 0 ] || usage
    gen="$(date +%Y-%m-%d_%H%M%S)"
    case "$1" in
      -h | --help | help) usage 0 ;;
      disks)
        shift
        [ $# -gt 0 ] || usage
        if [ "$1" = --all ]; then show_disks "''${all_full[@]}"; else show_disks "$@"; fi
        ;;
      list)
        start_log "$gen-list"
        session_open
        call list
        ;;
      prune)
        shift
        kind="''${1:-}"
        [ "$kind" = home ] || [ "$kind" = full ] || usage
        [ "''${2:-}" = --keep ] && [[ "''${3:-}" =~ ^[0-9]+$ ]] && [ "$3" -ge 1 ] || usage
        keep="$3"
        shift 3
        dry=-
        sel=()
        for a in "$@"; do
          if [ "$a" = -n ]; then dry=-n; else sel+=("$a"); fi
        done
        start_log "$gen-prune"
        session_open
        call "prune $kind $keep $dry ''${sel[*]}"
        ;;
      restore)
        shift
        [ $# -gt 0 ] || usage
        what=home
        if [ "$1" = --full ]; then what=full; shift; fi
        from=latest
        if [ "''${1:-}" = --from ]; then
          from="''${2:-}"
          [[ "$from" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]] \
            || die "--from takes a generation like 2026-10-21_201500 (names: nox backup list)"
          shift 2
        fi
        [ $# -gt 0 ] || usage
        if [ "$what" = home ]; then
          home_names "$@"
          mapfile -t sel <"$sel_file"
          start_log "$gen-restore"
          session_open
          home_restore "$from" "''${sel[@]}"
          summary "home restore" ""
        else
          full_args "$@"
          mapfile -t sel <"$sel_file"
          start_log "$gen-restore-full"
          session_open
          full_restore "$from" "''${sel[@]}"
          summary "full restore" ""
        fi
        ;;
      --full)
        shift
        if [ "''${1:-}" = --level ]; then
          [[ "''${2:-}" =~ ^([1-9]|1[0-9])$ ]] || die "--level takes 1..19"
          level="$2"
          shift 2
        fi
        [ $# -gt 0 ] || usage
        full_args "$@"
        mapfile -t sel <"$sel_file"
        start_log "$gen"
        session_open
        full_backup "''${sel[@]}"
        summary "full backup" "$gen"
        ;;
      -*) [ "$1" = --all ] || usage ;&
      *)
        home_names "$@"
        mapfile -t sel <"$sel_file"
        start_log "$gen"
        session_open
        home_backup "''${sel[@]}"
        # exit status: 1 when an element failed
        summary "home backup" "$gen" && date +%s >"$state/last"
        ;;
    esac
  '';

  # Reminder: no home backup for 7 days (also a row in vm-doctor)
  reminder = pkgs.writeShellScript "vm-backup-reminder" ''
    last="$(cat "''${XDG_STATE_HOME:-$HOME/.local/state}/nox-backup/last" 2>/dev/null || echo 0)"
    if [ $(( $(${pkgs.coreutils}/bin/date +%s) - last )) -gt $((7 * 86400)) ]; then
      ${pkgs.libnotify}/bin/notify-send -a vm-backup "Backup" "Letztes Backup älter als 7 Tage: nox backup"
    fi
  '';
in
{
  environment.systemPackages = [ vmBackup ];

  systemd.user = {
    services.vm-backup-reminder = {
      description = "Remind of the backup after 7 days";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${reminder}";
      };
    };
    timers.vm-backup-reminder = {
      description = "Daily backup reminder";
      timerConfig = {
        OnStartupSec = "10min";
        OnUnitActiveSec = "1d";
      };
      wantedBy = [ "timers.target" ];
    };
  };
}

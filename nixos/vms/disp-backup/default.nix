# disp-backup: disposable for `nox backup` (README "Backup", spec in
# xen-migration.md "2. Backup"): holds the backup disk (USB/IP from sys-usb),
# no network, empty home on every start (registry `disposable`,
# nixos/dom0/xen-dom0.nix). dom0's nox backup (nox-cli src/backup.rs)
# drives it over the rpc service `backup` below; the disk is LUKS, opened
# with the passphrase dom0 sends. Layout on the disk, <gen> = start time
# YYYY-MM-DD_HHMMSS of the run, unfinished runs are <gen>.partial (removed
# on failure, never used):
#   nox/home/<vm>/<gen>/                      /home/user, hard links to the previous gen
#   nox/full/<target>/<gen>/<disk>.tar.zst    one disk (sparse tar), .sha256 and
#                                             .used (bytes of data) next to it;
#                                             the builder's key is key.zst
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  mnt = "/mnt/backup";
  noxRpc = "${config.services.nox-rpc.package}/bin/nox-rpc";
  # rsync's remote shell: `<rsh> <vm> rsync --server …` becomes a call of
  # the VM's backup-send/backup-recv with that command as the first line.
  # `cat` (rsync's data after that line) is killed when nox-rpc ends: it
  # would wait on rsync's stdin while rsync waits for this script to exit,
  # so every run hung after its last byte (hp, 2026-10-21 night)
  rsh =
    service:
    pkgs.writeShellScript "backup-rsh-${service}" ''
      host="$1"
      shift
      ${noxRpc} ${service} "$host" < <(printf '%s\n' "$*"; exec ${pkgs.coreutils}/bin/cat)
      rc=$?
      kill $! 2>/dev/null
      exit $rc
    '';
  # --timeout: rsync gives up after 120 s without data instead of hanging
  # (the first W1 test on the xmg hung forever, 2026-10-21);
  # --no-inc-recursive: progress2 knows the total before it starts; stats2:
  # "Total transferred file size" for the summary (stats1 lacks it);
  # --no-msgs2stderr: the VM's errors ("opendir … Permission denied") come
  # through the protocol, its stderr only reaches the VM's journal
  rsyncOpts = "-aHS --numeric-ids --timeout=120 --no-inc-recursive --no-msgs2stderr --info=progress2,stats2";

  # Root part of the service (sudo from the handler). Names are checked:
  # they end up in paths
  helper = pkgs.writeShellScript "backup-helper" ''
    set -uo pipefail
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
        pkgs.cryptsetup
        pkgs.e2fsprogs
        pkgs.rsync
        pkgs.findutils
        pkgs.gnugrep
        pkgs.gawk
        pkgs.gnused
        pkgs.procps
      ]
    }
    # rsync's numbers as dom0's nox backup parses them ("1,234,567", "0.00kB/s");
    # the VMs' LC_NUMERIC is German
    export LC_ALL=C
    name_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; }
    disk_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; }
    gen_ok() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]]; }
    home="${mnt}/nox/home"
    full="${mnt}/nox/full"
    # Generations of <dir>, oldest first (no .partial)
    gens() { find "$1" -mindepth 1 -maxdepth 1 -type d -regextype egrep -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}' -printf '%f\n' 2>/dev/null | sort; }
    # <gen> or `latest` of <dir> → the generation, or fail with a message
    resolve() {
      local g="$2"
      [ "$g" = latest ] && g="$(gens "$1" | tail -n 1)"
      gen_ok "$g" && [ -d "$1/$g" ] || { echo "error: no generation ''${2/latest/at all} in $1" >&2; return 1; }
      echo "$g"
    }
    human() { LC_ALL=C numfmt --to=si --round=nearest --format=%.1f "$1" | sed -E 's/([0-9])([kMGTP]?)$/\1 \2B/'; }

    case "$1" in
      open | open-test)
        # The disk is the only sd* here (own disks are xvd*); nox backup's
        # test disk (NOX_BACKUP_TEST_DISK) comes as xvdz. LUKS on the whole
        # disk or on any partition. Any LUKS volume can be the backup volume:
        # one listed in the registry (`backupLuksUuids`) is taken right away,
        # otherwise the one the passphrase opens (several with the same
        # passphrase: error listing them, list one in the registry)
        IFS= read -r pw || exit 1
        allowed=" ${lib.concatStringsSep " " vmRegistry.backupLuksUuids} "
        dev=""
        found=()
        seen=""
        for _ in $(seq 30); do
          found=()
          for d in /dev/sd?* /dev/xvdz*; do
            [ -b "$d" ] && cryptsetup isLuks "$d" 2>/dev/null || continue
            uuid="$(cryptsetup luksUUID "$d")"
            found+=("$d $uuid $(lsblk -dno SIZE "$d" | tr -d ' ')")
            # the test disk is always fine
            if { [ "$allowed" != "  " ] && [[ "$allowed" == *" $uuid "* ]]; } \
              || { [ "$1" = open-test ] && [[ "$d" == /dev/xvdz* ]]; }; then
              dev="$d"
              break 2
            fi
          done
          if [ "''${#found[@]}" -gt 0 ]; then
            # Partitions may still be coming up: decide on a second look
            [ -n "$seen" ] && break
            seen=1
          fi
          [ "$1" = open-test ] && [ -b /dev/xvdz ] && break
          sleep 1
        done
        if [ -z "$dev" ] && [ "''${#found[@]}" -eq 1 ]; then
          dev="''${found[0]%% *}"
        elif [ -z "$dev" ] && [ "''${#found[@]}" -gt 1 ] && [ "$1" = open ]; then
          matches=()
          for f in "''${found[@]}"; do
            if printf '%s' "$pw" | cryptsetup open --test-passphrase --key-file=- "''${f%% *}" 2>/dev/null; then
              matches+=("$f")
            fi
          done
          if [ "''${#matches[@]}" -eq 0 ]; then
            echo "wrong passphrase"
            exit 3
          elif [ "''${#matches[@]}" -gt 1 ]; then
            echo "error: the passphrase opens several LUKS volumes; list the backup volume in the registry (backupLuksUuids):"
            printf '  %s\n' "''${matches[@]}"
            exit 1
          fi
          dev="''${matches[0]%% *}"
        fi
        if [ -z "$dev" ] && [ "$1" = open-test ] && [ -b /dev/xvdz ]; then
          # Fresh test disk: format it like a real one (LUKS + ext4)
          echo "formatting the test disk"
          printf '%s' "$pw" | cryptsetup luksFormat -q --key-file=- /dev/xvdz || exit 1
          printf '%s' "$pw" | cryptsetup open --key-file=- /dev/xvdz noxbackup || exit 1
          mkfs.ext4 -q /dev/mapper/noxbackup || exit 1
          cryptsetup close noxbackup
          dev=/dev/xvdz
        fi
        [ -n "$dev" ] || { echo "error: no LUKS disk found (attached? formatted?)"; exit 1; }
        # cryptsetup exits 2 on a wrong passphrase: 3 tells nox backup to ask again
        printf '%s' "$pw" | cryptsetup open --key-file=- "$dev" noxbackup
        rc=$?
        if [ "$rc" = 2 ]; then
          echo "wrong passphrase"
          exit 3
        elif [ "$rc" != 0 ]; then
          echo "error: cryptsetup open failed ($rc)"
          exit 1
        fi
        mkdir -p ${mnt}
        mount /dev/mapper/noxbackup ${mnt} || { cryptsetup close noxbackup; exit 1; }
        mkdir -p "$home" "$full"
        echo "opened $dev"
        ;;
      close)
        sync
        # After Ctrl+C in dom0 an rsync here may still write: end it, retry
        for _ in $(seq 10); do
          mountpoint -q ${mnt} || break
          umount ${mnt} 2>/dev/null && break
          pkill -x rsync
          sleep 1
        done
        if mountpoint -q ${mnt}; then umount ${mnt} || exit 1; fi
        if [ -e /dev/mapper/noxbackup ]; then cryptsetup close noxbackup || exit 1; fi
        echo "closed"
        ;;
      home-backup) # <vm> <gen>
        name_ok "$2" && gen_ok "$3" || exit 2
        prev="$(gens "$home/$2" | tail -n 1)"
        mkdir -p "$home/$2"
        rm -rf "$home/$2/$3.partial"
        if rsync ${rsyncOpts} --exclude=/.cache --exclude=/lost+found \
          ''${prev:+--link-dest="$home/$2/$prev"} \
          -e ${rsh "backup-send"} "$2:/home/user/" "$home/$2/$3.partial/"; then
          mv "$home/$2/$3.partial" "$home/$2/$3"
        else
          rc=$?
          rm -rf "$home/$2/$3.partial"
          exit "$rc"
        fi
        ;;
      home-restore) # <vm> <gen|latest>
        name_ok "$2" || exit 2
        g="$(resolve "$home/$2" "$3")" || exit 1
        echo "generation $g"
        rsync ${rsyncOpts} --update \
          -e ${rsh "backup-recv"} "$home/$2/$g/" "$2:/home/user/"
        ;;
      full-put) # <target> <gen> <disk> <file name> <used bytes>; stdin = the stream
        name_ok "$2" && gen_ok "$3" && disk_ok "$4" && [[ "$5" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$6" =~ ^[0-9]+$ ]] || exit 2
        d="$full/$2/$3.partial"
        mkdir -p "$d"
        tee "$d/$5" | sha256sum | cut -d' ' -f1 >"$d/$4.sha256" || exit 1
        [ -s "$d/$5" ] || { echo "error: empty stream"; exit 1; }
        echo "$6" >"$d/$4.used"
        echo "stored-bytes $(stat -c %s "$d/$5")"
        ;;
      full-commit) # <target> <gen>
        name_ok "$2" && gen_ok "$3" || exit 2
        [ -d "$full/$2/$3.partial" ] || exit 1
        mv "$full/$2/$3.partial" "$full/$2/$3" && sync
        ;;
      full-abort) # <target> <gen>
        name_ok "$2" && gen_ok "$3" || exit 2
        rm -rf "$full/$2/$3.partial"
        ;;
      full-info) # <target> <gen|latest>: "gen <gen>" and "disk <name> <file> <used>" lines
        name_ok "$2" || exit 2
        g="$(resolve "$full/$2" "$3")" || exit 1
        echo "gen $g"
        for s in "$full/$2/$g"/*.sha256; do
          [ -e "$s" ] || continue
          n="$(basename "$s" .sha256)"
          f="$(cd "$full/$2/$g" && ls "$n".tar.zst "$n".zst 2>/dev/null | head -n 1)"
          echo "disk $n $f $(cat "$full/$2/$g/$n.used" 2>/dev/null || echo 0)"
        done
        ;;
      full-get) # <target> <gen> <disk>: first line `ok <sha256>` (or
        # `error: …`), then the stream, no status line. dom0 checks the
        # checksum while it unpacks (one read; checking here first read the
        # whole file silently before the first byte, steam looked hung)
        name_ok "$2" && gen_ok "$3" && disk_ok "$4" || { echo "error: bad arguments"; exit 2; }
        d="$full/$2/$3"
        f="$(cd "$d" 2>/dev/null && ls "$4".tar.zst "$4".zst 2>/dev/null | head -n 1)"
        [ -n "$f" ] || { echo "error: $2/$3 has no disk $4"; exit 1; }
        sum="$(cat "$d/$4.sha256" 2>/dev/null)"
        [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo "error: $2/$3/$4 has no checksum"; exit 1; }
        echo "ok $sum"
        exec cat "$d/$f"
        ;;
      list)
        echo "home - /home/user                 restore: nox backup restore [--from <generation>] <vm>"
        for d in "$home"/*/; do
          # none left (a failed run, prune --keep 0): no row
          [ -d "$d" ] && [ -n "$(gens "$d")" ] || continue
          printf '  %-10s %s (newest)\n' "$(basename "$d")" "$(gens "$d" | tr '\n' ' ' | sed 's/ $//')"
        done
        echo "full - whole disks                restore: nox backup restore --full [--from <generation>] <target>"
        for d in "$full"/*/; do
          [ -d "$d" ] || continue
          first=1
          for g in $(gens "$d"); do
            disks=""
            for s in "$d$g"/*.sha256; do
              [ -e "$s" ] || continue
              n="$(basename "$s" .sha256)"
              f="$(cd "$d$g" && ls "$n".tar.zst "$n".zst 2>/dev/null | head -n 1)"
              disks="$disks''${disks:+, }$n $(human "$(stat -c %s "$d$g/$f")")"
            done
            [ "$g" = "$(gens "$d" | tail -n 1)" ] && g="$g (newest)"
            if [ "$first" = 1 ]; then printf '  %-10s %s: %s\n' "$(basename "$d")" "$g" "$disks"; first=0
            else printf '  %-10s %s: %s\n' "" "$g" "$disks"; fi
          done
        done
        df -B1 --output=avail,size ${mnt} | tail -n 1 | while read -r a s; do
          echo "disk: $(human "$a") free of $(human "$s")"
        done
        ;;
      prune) # home|full <keep> -n|- [vm…]
        kind="$2" keep="$3" dry="$4"
        [ "$kind" = home ] || [ "$kind" = full ] || exit 2
        # keep 0: all of them (nox backup asks first)
        [[ "$keep" =~ ^[0-9]+$ ]] || exit 2
        base="${mnt}/nox/$kind"
        shift 4
        if [ $# -eq 0 ]; then
          mapfile -t dirs < <(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
          set -- "''${dirs[@]}"
        fi
        n=0
        for vm in "$@"; do
          name_ok "$vm" || exit 2
          for g in $(gens "$base/$vm" | head -n -"$keep"); do
            n=$((n + 1))
            if [ "$dry" = -n ]; then
              echo "would delete $kind $vm $g"
            else
              echo "delete $kind $vm $g"
              rm -rf "''${base:?}/''${vm:?}/''${g:?}"
            fi
          done
        done
        [ "$n" -gt 0 ] || echo "nothing to delete"
        ;;
      *) exit 2 ;;
    esac
  '';
in
{
  imports = [
    ../modules/net-config.nix
    ../modules/common-config.nix
  ];

  networking.hostName = "disp-backup-vm";

  microvm = {
    hypervisor = "xen";
    volumes = [
      {
        mountPoint = "/home/user";
        image = "home.img";
        size = 20000;
      }
    ];
    mem = 1024;
    vcpu = 2;
  };

  services = {
    net-config = {
      enable = true;
      index = 32;
      mac = "00:00:00:00:00:20";
    };

    common-config = {
      enable = true;
      withDefaultPkgs = false;
    };

    # dom0's nox backup: first line `<command> [args]`, the output, then
    # `exit <rc>`; full-get streams without a status line
    nox-rpc.guest.handlers.backup = ''
      if [ "$source" != dom0 ]; then
        echo "error: only dom0"
        exit 1
      fi
      IFS= read -r line || exit 1
      read -ra args <<<"$line"
      if [ "''${args[0]:-}" = full-get ]; then
        exec /run/wrappers/bin/sudo ${helper} "''${args[@]}"
      fi
      /run/wrappers/bin/sudo ${helper} "''${args[@]}" 2>&1
      echo "exit $?"
    '';
  };

  environment.systemPackages = with pkgs; [
    cryptsetup
    rsync
  ];

  system.stateVersion = "26.05";
}

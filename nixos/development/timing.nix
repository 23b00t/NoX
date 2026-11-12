# Boot and RAM timing of dom0 (nox.dev.timing): only journal lines,
# nothing waits on them.
#   nox-mem (system):         dom0 RAM (used = MemTotal - MemAvailable,
#                             available, cache, shmem), zram RAM, Xen free
#                             memory, PSI, swap and major-fault rates;
#                             every 10 s for the first 10 min after boot,
#                             then every 60 s
#   nox-timing (user):        "session start" with the niri session, then
#                             "window <app id>" per new window for 5 min;
#                             terminal-tabs adds "tabs: done"
#   nox-timing [-b N] [--mem] reads one boot: domain starts, relays
#                             connected, nox-sys.target, windows (+ RAM),
#                             seconds since boot and since session start
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.nox.dev.timing;
  xl = "${config.virtualisation.xen.package}/bin/xl";

  memSampler = pkgs.writeShellScript "nox-mem" ''
    PATH=${
      lib.makeBinPath [
        pkgs.gawk
        pkgs.coreutils
      ]
    }
    mib() { awk -v k="$1:" '$1 == k { printf "%d", $2 / 1024 }' /proc/meminfo; }
    vm() { awk -v k="$1" '$1 == k { print $2 }' /proc/vmstat; }
    avg10() { awk -v k="$2" '$1 == k { sub("avg10=", "", $2); print $2 }' "/proc/pressure/$1"; }
    pin=$(vm pswpin) pout=$(vm pswpout) pmaj=$(vm pgmajfault)
    while :; do
      in=$(vm pswpin) out=$(vm pswpout) maj=$(vm pgmajfault)
      xenfree=$(${xl} info 2>/dev/null | awk '$1 == "free_memory" { print $3 }')
      # zram's own RAM (compressed data + overhead), mm_stat field 3 in bytes
      zram=$(awk '{ printf "%d", $3 / 1048576 }' /sys/block/zram0/mm_stat 2>/dev/null)
      avail=$(mib MemAvailable)
      echo "used=$(( $(mib MemTotal) - avail ))M avail=''${avail}M" \
        "cache=$(mib Cached)M shmem=$(mib Shmem)M" \
        "swap=$(( $(mib SwapTotal) - $(mib SwapFree) ))M zram=''${zram:-?}M" \
        "xenfree=''${xenfree:-?}M" \
        "psi_mem=$(avg10 memory some)/$(avg10 memory full) psi_io=$(avg10 io some)" \
        "swapin=$((in - pin)) swapout=$((out - pout)) majflt=$((maj - pmaj))"
      pin=$in pout=$out pmaj=$maj
      up=$(cut -d. -f1 /proc/uptime)
      sleep $(( up < 600 ? 10 : 60 ))
    done
  '';

  windowLogger = pkgs.writeShellScript "nox-timing-windows" ''
    echo "session start"
    declare -A seen
    timeout 300 niri msg --json event-stream \
      | ${pkgs.jq}/bin/jq --unbuffered -r \
        '.WindowOpenedOrChanged.window // empty | "\(.id) \(.app_id // "")"' \
      | while read -r id app; do
        [ -z "''${seen[$id]+x}" ] || continue
        seen[$id]=1
        echo "window $app"
      done
  '';

  report = pkgs.writeShellScriptBin "nox-timing" ''
    set -u
    PATH=${
      lib.makeBinPath [
        pkgs.jq
        pkgs.gawk
        pkgs.coreutils
        config.systemd.package
      ]
    }:$PATH
    boot=0 mem=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -b) boot=$2; shift ;;
        --mem) mem=1 ;;
        -h|--help)
          echo "usage: nox-timing [-b N] [--mem]   (N: 0 = this boot, -1 = the one before)"
          exit 0 ;;
        *) echo "nox-timing: unknown argument $1" >&2; exit 2 ;;
      esac
      shift
    done
    fmt='"\(.__MONOTONIC_TIMESTAMP | tonumber / 1e6) \(
      (.UNIT // (.SYSLOG_IDENTIFIER | select(. == "nox-timing" or . == "nox-mem"))
        // ._SYSTEMD_USER_UNIT // ._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // "?")
      | sub("\\.service$"; "")) \(.MESSAGE | strings)"'
    # systemd logs the unit's description, not its name: pick by UNIT
    units='select((.UNIT // "") | test("^((microvm|xen-image)@|nox-sys\\.target)")) | '
    q() { journalctl -b "$boot" -o json --no-pager "$@" | jq -r "''${pre:-}$fmt"; }
    {
      pre=$units q _PID=1 --grep '^(Starting|Started|Reached target|Failed)'
      q -u 'nox-relay-*' --grep 'peer connected' 2>/dev/null
      q -u nox-sys-ready
      q -t nox-timing
      [ "$mem" -eq 0 ] || q -t nox-mem
    } | LC_ALL=C sort -n | awk '
      { line[NR] = $0; t[NR] = $1 }
      t0 == "" && /session start/ { t0 = $1 }
      END {
        print "  boot   session  source / message"
        for (i = 1; i <= NR; i++) {
          rest = line[i]; sub(/^[^ ]+ /, "", rest)
          rel = t0 == "" ? "" : sprintf("%+7.1f", t[i] - t0)
          printf "%6.1f  %7s  %s\n", t[i], rel, rest
        }
      }'
  '';
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ report ];

    systemd.services.nox-mem = {
      description = "NoX timing: dom0 memory samples";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = memSampler;
        SyslogIdentifier = "nox-mem";
        Nice = 10;
      };
    };

    systemd.user.services.nox-timing = {
      description = "NoX timing: session start and new windows";
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      unitConfig.ConditionEnvironment = "WAYLAND_DISPLAY";
      path = [
        config.programs.niri.package
        pkgs.coreutils
      ];
      serviceConfig = {
        ExecStart = windowLogger;
        SyslogIdentifier = "nox-timing";
      };
    };
  };
}

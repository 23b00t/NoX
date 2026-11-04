# Boot and RAM timing of dom0 (nox.development.timing): only journal lines,
# nothing waits on them.
#   nox-mem (system):         dom0 RAM, zram, Xen free memory, PSI, swap and
#                             major-fault rates; every 10 s for the first
#                             10 min after boot, then every 60 s
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
  cfg = config.nox.development.timing;
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
      echo "avail=$(mib MemAvailable)M cache=$(mib Cached)M" \
        "swap=$(( $(mib SwapTotal) - $(mib SwapFree) ))M xenfree=''${xenfree:-?}M" \
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
      (.UNIT // ._SYSTEMD_UNIT // ._SYSTEMD_USER_UNIT // .SYSLOG_IDENTIFIER // "?")
      | sub("\\.service$"; "")) \(.MESSAGE | strings)"'
    q() { journalctl -b "$boot" -o json --no-pager "$@" | jq -r "$fmt"; }
    {
      q _PID=1 --grep '^(Starting|Started|Reached target|Failed).*((microvm|xen-image)@|nox-sys)'
      q -u 'nox-relay-*' --grep 'peer connected' 2>/dev/null
      q -u nox-sys-ready
      q -t nox-timing
      [ "$mem" -eq 0 ] || q -t nox-mem
    } | sort -n | awk '
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
  options.nox.development.timing.enable = lib.mkEnableOption ''
    boot and RAM timing in the journal (nox-mem, nox-timing) and the
    `nox-timing` report; a development aid'';

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

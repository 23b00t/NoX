# Xen guest memory agent: reports the guest's memory usage to dom0 via
# xenstore (~/data/meminfo, guest-writable), where the RAM balancer
# (modules/xen-memory.nix) reads it. Active for Xen guests with ballooning.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.microvm;

  # Only the xenstore client from the Xen package (~130 KB instead of the
  # full Xen closure); `xenstore` is the multi-call binary behind xenstore-*
  xenstoreClient =
    pkgs.runCommand "xenstore-client"
      {
        nativeBuildInputs = [ pkgs.patchelf ];
      }
      ''
        mkdir -p $out/bin $out/lib
        cp -L ${pkgs.xen}/lib/libxenstore.so.4 ${pkgs.xen}/lib/libxentoolcore.so.1 $out/lib/
        cp ${pkgs.xen}/bin/xenstore $out/bin/xenstore
        chmod u+w $out/bin/xenstore $out/lib/*
        patchelf --set-rpath $out/lib $out/bin/xenstore $out/lib/libxenstore.so.4
        # Loads with only its own libs (prints usage, exits 1 without args)
        ($out/bin/xenstore 2>&1 || true) | grep -q Usage
      '';

  # Writes "MemTotal MemAvailable SwapTotal SwapFree" (MiB) whenever one of
  # them moved by at least 16 MiB
  agent = pkgs.writeShellScript "xen-meminfo-agent" ''
    last=""
    while true; do
      line="$(${pkgs.gawk}/bin/awk '
        /^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
        /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
        END { printf "%d %d %d %d", t / 1024, a / 1024, st / 1024, sf / 1024 }
      ' /proc/meminfo)"
      key="$(echo "$line" | ${pkgs.gawk}/bin/awk '{ printf "%d %d %d %d", $1 / 16, $2 / 16, $3 / 16, $4 / 16 }')"
      if [ "$key" != "$last" ]; then
        ${xenstoreClient}/bin/xenstore write data/meminfo "$line" && last="$key"
      fi
      sleep 2
    done
  '';
in
{
  config =
    lib.mkIf (cfg.guest.enable && cfg.hypervisor == "xen" && (cfg.balloon || cfg.hotplugMem != 0))
      {
        systemd.services.xen-meminfo = {
          description = "Report memory usage to dom0 via xenstore";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = agent;
            Restart = "always";
            RestartSec = 5;
            # root for /dev/xen/xenbus; nothing else needed
            PrivateNetwork = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            NoNewPrivileges = true;
            DevicePolicy = "closed";
            DeviceAllow = [ "/dev/xen/xenbus rw" ];
          };
        };
      };
}

# Xen RAM balancer (dom0): moves the memory of ballooning MicroVMs between
# their boot size and their ceiling, based on the usage each guest reports
# via xenstore (~/data/meminfo, written by vms/modules/xen-meminfo.nix).
#
# Per VM: target = used * (100 + overheadPercent) / 100 + bufferMB, clamped
# to [boot memory, maxmem]. Growing is immediate, only out of
# Xen's free memory minus reserveMB, higher registry `memPriority` first.
# Shrinking waits until the VM wanted less for shrinkDelay seconds.
# dom0 is never touched.
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  cfg = config.services.xen-memory-balancer;
  xen = config.virtualisation.xen.package;

  # Ballooning Xen MicroVMs, with the same memory mapping as the Xen runner
  managedVms = lib.concatLists (
    lib.mapAttrsToList (
      name: vm:
      let
        guest = vm.config.config;
        m = guest.microvm;
      in
      lib.optional (m.hypervisor == "xen" && (m.balloon || m.hotplugMem != 0)) {
        domain = guest.networking.hostName;
        min = if m.hotplugMem != 0 then m.mem + m.hotpluggedMem else m.mem - m.initialBalloonMem;
        max = if m.hotplugMem != 0 then m.mem + m.hotplugMem else m.mem;
        priority = vmRegistry.byName.${name}.memPriority or 0;
      }
    ) config.microvm.vms
  );

  # "domain min max priority" per line
  vmTable = pkgs.writeText "xen-memory-vms" (
    lib.concatMapStrings (
      vm: "${vm.domain} ${toString vm.min} ${toString vm.max} ${toString vm.priority}\n"
    ) managedVms
  );

  balancer = pkgs.writeShellScript "xen-memory-balancer" ''
    set -u
    PATH=${
      lib.makeBinPath [
        xen
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnugrep
      ]
    }

    # Shrinking waits until a VM wanted less for shrinkDelay seconds in a row,
    # then goes to the highest target seen in that time (bursty builds)
    declare -A low_since low_max

    while true; do
      grows=""
      now=$(date +%s)

      while read -r domain min max prio; do
        domid="$(xl domid "$domain" 2>/dev/null)" || continue

        # Guest-supplied, so untrusted: four plain numbers or nothing
        info="$(xenstore-read "/local/domain/$domid/data/meminfo" 2>/dev/null)" || continue
        echo "$info" | grep -Eqx '[0-9]{1,9} [0-9]{1,9} [0-9]{1,9} [0-9]{1,9}' || continue
        read -r total avail swaptotal swapfree <<< "$info"

        target_kb="$(xenstore-read "/local/domain/$domid/memory/target" 2>/dev/null)" || continue
        cur=$(( target_kb / 1024 ))

        used=$(( total - avail + swaptotal - swapfree ))
        (( used < 0 )) && used=0
        want=$(( used * (100 + ${toString cfg.overheadPercent}) / 100 + ${toString cfg.bufferMB} ))
        (( want < min )) && want=$min
        (( want > max )) && want=$max

        diff=$(( want - cur ))
        if (( ''${diff#-} < ${toString cfg.hysteresisMB} )); then
          unset "low_since[$domain]" "low_max[$domain]"
          continue
        fi

        if (( want < cur )); then
          if [ -z "''${low_since[$domain]:-}" ]; then
            low_since[$domain]=$now
            low_max[$domain]=$want
          fi
          (( want > low_max[$domain] )) && low_max[$domain]=$want
          if (( now - low_since[$domain] >= ${toString cfg.shrinkDelay} )); then
            new=''${low_max[$domain]}
            echo "$domain: $cur -> $new MiB (used $used, low for ${toString cfg.shrinkDelay}s)"
            timeout 30 xl mem-set "$domain" "''${new}m" || true
            unset "low_since[$domain]" "low_max[$domain]"
          fi
        else
          unset "low_since[$domain]" "low_max[$domain]"
          grows+="$prio $domain $cur $want $used"$'\n'
        fi
      done < ${vmTable}

      if [ -n "$grows" ]; then
        free="$(xl info free_memory 2>/dev/null)" || free=0
        budget=$(( free - ${toString cfg.reserveMB} ))
        while read -r prio domain cur want used; do
          [ -n "$domain" ] || continue
          (( budget <= 0 )) && break
          new=$want
          (( new - cur > budget )) && new=$(( cur + budget ))
          echo "$domain: $cur -> $new MiB (used $used, wants $want, prio $prio)"
          timeout 30 xl mem-set "$domain" "''${new}m" || true
          budget=$(( budget - (new - cur) ))
        done < <(printf '%s' "$grows" | sort -k1,1nr)
      fi

      sleep ${toString cfg.interval}
    done
  '';
in
{
  options.services.xen-memory-balancer = {
    enable = lib.mkEnableOption "Xen RAM balancer for ballooning MicroVMs";

    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Seconds between two balancing rounds.";
    };

    overheadPercent = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = "Headroom on top of the used memory, in percent of it.";
    };

    bufferMB = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 256;
      description = "Fixed headroom on top of the used memory (MiB).";
    };

    hysteresisMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 64;
      description = "Only change a VM's memory if its target moved by at least this much (MiB).";
    };

    shrinkDelay = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = "Seconds a VM must want less memory before it is shrunk (growing is immediate).";
    };

    reserveMB = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 2048;
      description = "Xen free memory kept back for starting VMs (MiB); growing never uses it.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.xen-memory-balancer = {
      description = "Balance RAM of ballooning Xen MicroVMs";
      wantedBy = [ "multi-user.target" ];
      after = [ "xenstored.service" ];
      requires = [ "xenstored.service" ];
      serviceConfig = {
        ExecStart = balancer;
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}

# Xen RAM balancer (dom0): moves the memory of ballooning MicroVMs between
# their boot size and their ceiling, based on the usage each guest reports
# via xenstore (~/data/meminfo, written by vms/modules/xen-meminfo.nix).
#
# Per VM: target = used * (100 + overheadPercent) / 100 + bufferMB, clamped
# to [boot memory, maxmem]. Growing is immediate, only out of
# Xen's free memory minus reserveMB, higher registry `memPriority` first.
# Shrinking waits until the VM wanted less for shrinkDelay seconds.
# dom0 is never touched.
#
# Event-driven: a xenstore watch marks a VM dirty when its guest reports, and
# only dirty VMs are evaluated. VMs with something pending (shrink waiting,
# growth cut short by the budget) stay dirty; a sweep of all domains every
# sweepSeconds catches whatever else was missed.
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
        # Booted with Xen's ceiling at the boot size (microvm.nix xen runner)
        hotplug = if m.hotplugMem != 0 then 1 else 0;
      }
    ) config.microvm.vms
  );

  # "domain min max priority hotplug" per line
  vmTable = pkgs.writeText "xen-memory-vms" (
    lib.concatMapStrings (
      vm:
      "${vm.domain} ${toString vm.min} ${toString vm.max} ${toString vm.priority} ${toString vm.hotplug}\n"
    ) managedVms
  );

  # Safety net of the event-driven loop, not a tunable
  sweepSeconds = 60;

  balancer = pkgs.writeShellScript "xen-memory-balancer" ''
    set -u
    PATH=${
      lib.makeBinPath [
        xen
        pkgs.coreutils
      ]
    }

    # Shrinking waits until a VM wanted less for shrinkDelay seconds in a row,
    # then goes to the highest target seen in that time (bursty builds)
    declare -A low_since low_max

    # domain -> "min max prio hotplug"; domid -> domain ("" = not managed);
    # domids to evaluate in the next round
    declare -A vm_row domain_of dirty
    # domids whose ceiling the balancer raised (hotplug VMs)
    declare -A raised

    while read -r domain min max prio hot; do
      vm_row[$domain]="$min $max $prio $hot"
    done < ${vmTable}

    balance() {
      local round=("''${!dirty[@]}") grows="" now=$EPOCHSECONDS
      dirty=()

      for domid in "''${round[@]}"; do
        if [ -z "''${domain_of[$domid]+x}" ]; then
          # Written by dom0, the guest cannot fake it
          name="$(xenstore-read "/local/domain/$domid/name" 2>/dev/null)" || continue
          domain_of[$domid]=""
          [ -z "''${vm_row[$name]+x}" ] || domain_of[$domid]=$name
        fi
        domain=''${domain_of[$domid]}
        [ -n "$domain" ] || continue
        read -r min max prio hot <<< "''${vm_row[$domain]}"

        # Guest-supplied, so untrusted: four plain numbers or nothing.
        # Unreadable means the domain is gone: forget it.
        if ! info="$(xenstore-read "/local/domain/$domid/data/meminfo" 2>/dev/null)" ||
          ! target_kb="$(xenstore-read "/local/domain/$domid/memory/target" 2>/dev/null)"; then
          unset "domain_of[$domid]" "raised[$domid]" "low_since[$domain]" "low_max[$domain]"
          continue
        fi
        [[ $info =~ ^[0-9]{1,9}\ [0-9]{1,9}\ [0-9]{1,9}\ [0-9]{1,9}$ ]] || continue
        read -r total avail swaptotal swapfree <<< "$info"
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
          else
            dirty[$domid]=1
          fi
        else
          unset "low_since[$domain]" "low_max[$domain]"
          grows+="$prio $domain $cur $want $used $domid $min $max $hot"$'\n'
        fi
      done

      if [ -n "$grows" ]; then
        free="$(xl info free_memory 2>/dev/null)" || free=0
        budget=$(( free - ${toString cfg.reserveMB} ))
        while read -r prio domain cur want used domid min max hot; do
          [ -n "$domain" ] || continue
          if (( budget <= 0 )); then
            dirty[$domid]=1
            continue
          fi
          new=$want
          if (( new - cur > budget )); then
            new=$(( cur + budget ))
            dirty[$domid]=1
          fi
          # Hotplug VMs boot with Xen's ceiling at their boot size: raised
          # before the guest's first target event, the guest would take it
          # as a permanent offset (microvm.nix lib/runners/xen.nix). A guest
          # reporting meminfo from userspace is long past that, so raise it
          # once per domid, before the first growth beyond the boot size.
          # Idempotent: after a restart of the balancer it is just raised
          # again.
          if [ "$hot" = 1 ] && (( new > min )) && [ -z "''${raised[$domid]:-}" ]; then
            if timeout 30 xl mem-max "$domain" "''${max}m"; then
              echo "$domain: ceiling raised to $max MiB"
              raised[$domid]=1
            else
              echo "$domain: could not raise the ceiling to $max MiB"
              dirty[$domid]=1
              continue
            fi
          fi
          echo "$domain: $cur -> $new MiB (used $used, wants $want, prio $prio)"
          timeout 30 xl mem-set "$domain" "''${new}m" || true
          budget=$(( budget - (new - cur) ))
        done < <(printf '%s' "$grows" | sort -k1,1nr)
      fi
    }

    # Domains already running sent their report before the watch existed, so
    # wait for the watch's initial event, then sweep. Domains that vanished
    # are in domain_of and get forgotten by their failing read.
    exec 3< <(exec xenstore-watch /local/domain)
    read -r -u 3 path || exit 1

    next_round=0
    next_sweep=0
    while true; do
      now=$EPOCHSECONDS
      if (( now >= next_sweep )); then
        for domid in "''${!domain_of[@]}" $(xenstore-list /local/domain 2>/dev/null); do
          dirty[$domid]=1
        done
        next_sweep=$(( now + ${toString sweepSeconds} ))
      fi

      if (( ''${#dirty[@]} > 0 && now >= next_round )); then
        balance
        next_round=$(( EPOCHSECONDS + ${toString cfg.interval} ))
        continue
      fi

      if (( ''${#dirty[@]} > 0 )); then
        wait=$(( next_round - now ))
      else
        wait=$(( next_sweep - now ))
      fi

      # 1 is EOF (the watch died, systemd restarts us), above 128 the timeout
      if read -r -t "$wait" -u 3 path; then
        if [[ $path =~ ^/local/domain/([0-9]+)/data/meminfo$ ]]; then
          domid=''${BASH_REMATCH[1]}
          if [ "''${domain_of[$domid]-x}" != "" ]; then
            # The first report opens a window, so VMs reporting at about the
            # same time are served together, by priority
            (( ''${#dirty[@]} > 0 )) || next_round=$(( EPOCHSECONDS + ${toString cfg.interval} ))
            dirty[$domid]=1
          fi
        fi
      elif (( $? <= 128 )); then
        echo "xenstore-watch ended"
        exit 1
      fi
    done
  '';
in
{
  options.services.xen-memory-balancer = {
    enable = lib.mkEnableOption "Xen RAM balancer for ballooning MicroVMs";

    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Minimum seconds between two balancing rounds.";
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

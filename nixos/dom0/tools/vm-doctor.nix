# vm-doctor (`nox doctor`): smoke test of the running system on demand.
# Starts no VMs, checks only what runs: autostart domains, rpc and relay per
# VM, network over sys-firewall (and the tunnel for sys-vpn clients), app start
# by RPC, clipboard round trip, wprs, D-Bus, stale runners, disk, failed
# units, kernel/Xen errors. Table of PASS/FAIL/SKIP, exit 1 on any FAIL.
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  relayed = config.services.nox-relay.host.guests or { };
  imageDomains = config.services.xen-image-domains.domains or { };
  microvms = config.microvm.vms or { };

  # Registry entries this machine runs
  hosts = builtins.filter (h: microvms ? ${h.name} || imageDomains ? ${h.name}) (
    vmRegistry.vms ++ vmRegistry.imageDomains
  );
  unitOf = name: if imageDomains ? ${name} then "xen-image@${name}" else "microvm@${name}";
  autostart =
    map (n: "microvm@${n}") (config.microvm.autostart or [ ])
    ++ map (n: "xen-image@${n}") (
      builtins.attrNames (lib.filterAttrs (_: d: d.autostart) imageDomains)
    );

  # Same rule as vm-clip (home/vm-management/vm-gui.nix)
  clipPolicy = vm: vm.clipboard or (if lib.hasPrefix "sys-" vm.name then "deny" else "allow");

  assoc =
    name: f:
    "declare -A ${name}=( "
    + lib.concatMapStrings (h: "[${h.name}]=${lib.escapeShellArg (toString (f h))} ") hosts
    + ")";
  flag = b: if b then "1" else "0";
  listen = h: relayed.${h.name}.listen or { };

  vmDoctor = pkgs.writeShellScriptBin "vm-doctor" ''
    set -u
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gawk
        pkgs.procps
        pkgs.wl-clipboard
      ]
    }:$PATH

    ${assoc "UNIT" (h: unitOf h.name)}
    ${assoc "DOMAIN" (h: if relayed ? ${h.name} then relayed.${h.name}.domain else "")}
    ${assoc "WPRS" (h: flag (listen h ? wprs))}
    ${assoc "DBUS" (h: flag ((relayed.${h.name}.serve or { }) ? dbus))}
    ${assoc "UPLINK" (h: if h.nat or false then h.uplink or "sys-firewall" else "")}
    ${assoc "CLIP" clipPolicy}
    VMS=( ${lib.concatMapStringsSep " " (h: h.name) hosts} )
    AUTOSTART=( ${lib.concatStringsSep " " autostart} )

    case "''${1:-}" in
      "") ;;
      *)
        echo "usage: vm-doctor   (checks the running system, starts nothing)" >&2
        exit 2
        ;;
    esac

    pass=0 fail=0 skip=0
    row() {
      printf '%-4s  %-26s %s\n' "$1" "$2" "$3"
      case "$1" in
        PASS) pass=$((pass + 1)) ;;
        FAIL) fail=$((fail + 1)) ;;
        *) skip=$((skip + 1)) ;;
      esac
    }

    printf '%-4s  %-26s %s\n' STAT CHECK DETAIL

    # --- domains
    for u in "''${AUTOSTART[@]}"; do
      if systemctl is-active --quiet "$u.service"; then
        row PASS "autostart $u" running
      else
        row FAIL "autostart $u" "$(systemctl is-active "$u.service" 2>/dev/null)"
      fi
    done

    RUNNING=()
    for vm in "''${VMS[@]}"; do
      systemctl is-active --quiet "''${UNIT[$vm]}.service" && RUNNING+=("$vm")
    done
    first() { # first running VM for which "$@" (with $vm set) holds
      local vm
      for vm in "''${RUNNING[@]}"; do
        if eval "$1"; then
          echo "$vm"
          return 0
        fi
      done
      return 1
    }

    # Probes over the VM's fixed rpc services (`ping`, `doctor`, `clip`), no
    # SSH
    rpcup() {
      [ "$(timeout 5 nox-rpc --dom0 ping "$1" </dev/null 2>/dev/null)" = ok ]
    }
    probe() { # probe <vm> <net|ip|wprsd|dbus>
      printf '%s\n' "$2" | timeout 20 nox-rpc --dom0 doctor "$1" 2>/dev/null
    }
    clip_get() {
      printf 'get\n' | timeout 20 nox-rpc --dom0 clip "$1"
    }
    clip_set() {
      { printf 'set\n'; cat; } | timeout 20 nox-rpc --dom0 clip "$1" >/dev/null
    }

    # --- rpc and relay per running VM
    for vm in "''${RUNNING[@]}"; do
      if rpcup "$vm"; then row PASS "rpc $vm" ok; else row FAIL "rpc $vm" "no answer"; fi
      dom="''${DOMAIN[$vm]}"
      [ -n "$dom" ] || continue
      pid="$(systemctl show -p MainPID --value "nox-relay-$vm.service")"
      peer="$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | awk 'p { print; exit } $0 == "--peer" { p = 1 }')"
      # The domain id from the unit's journal ("… (domid N) to die"), no
      # sudo needed; xl as a fallback where it may run
      inv="$(systemctl show -p InvocationID --value "''${UNIT[$vm]}.service")"
      domid="$(journalctl -q _SYSTEMD_INVOCATION_ID="$inv" -o cat --no-pager 2>/dev/null |
        sed -n 's/.*(domid \([0-9]*\)).*/\1/p' | tail -1)"
      [ -n "$domid" ] || domid="$(sudo -n xl domid "$dom" 2>/dev/null)"
      if [ -z "$domid" ]; then
        row SKIP "relay $vm" "no domid (journal of ''${UNIT[$vm]}, xl)"
      elif [ "$peer" = "$domid" ]; then
        row PASS "relay $vm" "domain $domid"
      else
        row FAIL "relay $vm" "relay on ''${peer:-none}, domain is $domid (systemctl restart nox-relay-$vm)"
      fi
    done

    # --- network
    direct_ip=""
    if vm="$(first '[ "''${UPLINK[$vm]}" = sys-firewall ] && [[ $vm != sys-* ]]')"; then
      code="$(probe "$vm" net)"
      if [ "$code" = 200 ]; then row PASS "net via sys-firewall ($vm)" "DNS + HTTPS"; else row FAIL "net via sys-firewall ($vm)" "''${code:-no DNS/connection}"; fi
      direct_ip="$(probe "$vm" ip)"
    else
      row SKIP "net via sys-firewall" "no running VM behind sys-firewall"
    fi
    for vm in "''${RUNNING[@]}"; do
      [ "''${UPLINK[$vm]}" = sys-vpn ] || continue
      code="$(probe "$vm" net)"
      ip="$(probe "$vm" ip)"
      if [ "$code" != 200 ]; then
        row FAIL "net via sys-vpn ($vm)" "''${code:-no DNS/connection}"
      elif [ -z "$direct_ip" ] || [ -z "$ip" ]; then
        row SKIP "net via sys-vpn ($vm)" "online, tunnel IP not compared"
      elif [ "$ip" != "$direct_ip" ]; then
        row PASS "net via sys-vpn ($vm)" "tunnel IP $ip"
      else
        row FAIL "net via sys-vpn ($vm)" "same public IP as sys-net ($ip)"
      fi
    done

    # --- GUI: app start by RPC, clipboard, wprs
    if vm="$(first '[ "''${WPRS[$vm]}" = 1 ] && [ -S "/run/nox-relay/$vm-rpc-in.sock" ]')"; then
      answer="$(printf '%s\0' true | timeout 20 nox-rpc --dom0 app "$vm" 2>&1)"
      if [[ $answer == ok* ]]; then row PASS "rpc app ($vm)" "$answer"; else row FAIL "rpc app ($vm)" "''${answer:-no answer}"; fi
    else
      row SKIP "rpc app" "no running VM with app RPC"
    fi

    if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
      row SKIP "clipboard round trip" "no Wayland session"
    elif vm="$(first '[ "''${WPRS[$vm]}" = 1 ] && [ "''${CLIP[$vm]}" = allow ]')"; then
      tmp="$(mktemp -d)"
      have0=0 havevm=0
      wl-paste --no-newline --type text >"$tmp/dom0" 2>/dev/null && have0=1
      clip_get "$vm" >"$tmp/vm" 2>/dev/null && havevm=1
      token="vm-doctor-$$-$RANDOM"
      printf %s "$token" | clip_set "$vm"
      got="$(clip_get "$vm" 2>/dev/null)"
      # wl-copy forks and keeps serving: not on our stdout (doctor | tail hung)
      printf %s "$got" | wl-copy --type text/plain >/dev/null 2>&1
      back="$(wl-paste --no-newline --type text 2>/dev/null)"
      if [ "$have0" = 1 ]; then wl-copy --type text/plain <"$tmp/dom0" >/dev/null 2>&1; else wl-copy --clear; fi
      [ "$havevm" = 1 ] && clip_set "$vm" <"$tmp/vm"
      rm -rf "$tmp"
      if [ "$back" = "$token" ]; then
        row PASS "clipboard round trip" "dom0 -> $vm -> dom0, both restored"
      else
        row FAIL "clipboard round trip" "dom0 -> $vm -> dom0 lost the text"
      fi
    else
      row SKIP "clipboard round trip" "no running wprs VM with clipboard allowed"
    fi

    for vm in "''${RUNNING[@]}"; do
      [ "''${WPRS[$vm]}" = 1 ] || continue
      state="$(probe "$vm" wprsd)"
      n=0
      for p in $(pgrep -x wprsc); do
        tr '\0' '\n' <"/proc/$p/cmdline" 2>/dev/null | grep -qxF -- "--socket=/run/nox-relay/$vm-wprs.sock" && n=$((n + 1))
      done
      if [ "$state" != active ]; then
        row FAIL "wprs $vm" "wprsd ''${state:-unknown}"
      elif [ "$n" -gt 1 ]; then
        row FAIL "wprs $vm" "$n wprsc in dom0 (one expected)"
      else
        row PASS "wprs $vm" "wprsd active, $n wprsc"
      fi
    done

    # --- D-Bus (filtered session bus over the relay)
    for vm in "''${RUNNING[@]}"; do
      [ "''${DBUS[$vm]}" = 1 ] || continue
      if [ ! -S /run/user/1000/vm-session-bus.sock ]; then
        row FAIL "dbus $vm" "dom0 proxy socket missing"
        continue
      fi
      if [ "$(probe "$vm" dbus)" = ok ]; then
        row PASS "dbus $vm" "notifications reachable"
      else
        row FAIL "dbus $vm" "org.freedesktop.Notifications not reachable"
      fi
    done

    # --- backup (vm-backup records the last W1 run)
    last="$(cat "''${XDG_STATE_HOME:-$HOME/.local/state}/nox-backup/last" 2>/dev/null || echo 0)"
    age=$(( ($(date +%s) - last) / 86400 ))
    if [ "$last" = 0 ]; then
      row WARN backup "none yet (nox backup)"
    elif [ "$age" -gt 7 ]; then
      row WARN backup "$age days ago (nox backup)"
    else
      row PASS backup "$age days ago"
    fi

    # --- system
    stale=()
    for vm in "''${RUNNING[@]}"; do
      d=/var/lib/microvms/$vm
      [ -e "$d/booted" ] || continue
      [ "$(readlink -f "$d/current")" = "$(readlink -f "$d/booted")" ] || stale+=("$vm")
    done
    if [ "''${#stale[@]}" -eq 0 ]; then row PASS "runners current" "no current != booted"; else row FAIL "runners current" "restart: ''${stale[*]}"; fi

    use="$(df --output=pcent / | tail -1 | tr -dc 0-9)"
    if [ "$use" -lt 90 ]; then row PASS "disk /" "$use % used"; else row FAIL "disk /" "$use % used"; fi

    failed="$(systemctl --failed --no-legend --plain | awk '{ print $1 }' | tr '\n' ' ')"
    ufailed="$(systemctl --user --failed --no-legend --plain | awk '{ print $1 }' | tr '\n' ' ')"
    if [ -z "$failed$ufailed" ]; then row PASS "failed units" none; else row FAIL "failed units" "$failed$ufailed"; fi

    # Errors since the last run (first run: since boot)
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/vm-doctor"
    mkdir -p "$state"
    boot="$(cat /proc/sys/kernel/random/boot_id)"
    since="-b"
    if [ -f "$state/last" ] && [ "$(head -1 "$state/last")" = "$boot" ]; then
      since="--since=@$(sed -n 2p "$state/last")"
    fi
    kerr="$(journalctl -k -p err -q --no-pager "$since" 2>/dev/null)"
    if [ -z "$kerr" ]; then
      row PASS "kernel errors" "none new"
    else
      row FAIL "kernel errors" "$(wc -l <<<"$kerr") new, last: $(tail -1 <<<"$kerr" | cut -c1-90)"
    fi
    xpat='^\(XEN\).*\b(err(or)?|fail(ed|ure)?|fault|panic)\b'
    if xd="$(sudo -n xl dmesg 2>/dev/null)"; then
      # Xen's own lines only: (dN) lines are guest consoles (guest_loglvl=all)
      xerr="$(grep -Eic "$xpat" <<<"$xd")"
      prev=0
      [ "$since" != -b ] && prev="$(sed -n 3p "$state/last")"
      if [ "$xerr" -le "''${prev:-0}" ]; then
        row PASS "xl dmesg" "no new errors"
      else
        row FAIL "xl dmesg" "$((xerr - ''${prev:-0})) new, last: $(grep -Ei "$xpat" <<<"$xd" | tail -1 | cut -c1-90)"
      fi
    else
      xerr=0
      row SKIP "xl dmesg" "xl needs sudo"
    fi
    printf '%s\n%s\n%s\n' "$boot" "$(date +%s)" "$xerr" >"$state/last"

    echo
    echo "$pass passed, $fail failed, $skip skipped"
    [ "$fail" -eq 0 ]
  '';
in
{
  environment.systemPackages = [ vmDoctor ];
}

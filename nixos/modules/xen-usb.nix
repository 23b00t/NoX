# dom0 side of sys-usb (v2.6, v2.8.3):
# - vm-usb: list the devices in sys-usb, attach/detach them to target VMs
#   over USB/IP (Qubes model), allow an input device for dom0 until it is
#   unplugged; vm-usb-auto keeps the assignments (defaultOwner, VM restarts,
#   unplugging). State in /run/vm-usb.
# - input proxy: input devices from the registry whitelist (owner `host`) or
#   allowed with `vm-usb allow-input` come back from sys-usb over RPC as raw
#   events (cat) into a filtering uinput receiver; others raise a notification
# - USB/IP links: kept connected by modules/xen-links.nix
# - fallback: if sys-usb is not reachable 120 s after its start, the USB
#   controllers go back to dom0 (needed on the XMG for keyboard/mouse)
# - sys-usb-rescue: the same by hand
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  cfg = config.services.xen-usb;
  links = import ../vms/usb-links.nix { inherit lib vmRegistry; };
  usbPciPaths = vmRegistry.hardware.pci.devicePaths.usb or [ ];
  xen = config.virtualisation.xen.package;
  stateDir = "/run/vm-usb";
  noxRpc = "${config.services.nox-rpc.package}/bin/nox-rpc";
  # dom0-only RPC services `usb` (sys-usb, vms/sys-usb) and `usbip` (target
  # VMs, vms/modules/usbip-client.nix): the command on the first line, the
  # answer, then `exit <rc>` as the last line. `rpc_cmd <vm> <service> <cmd…>`
  # prints the answer and returns the rc (1 if the VM does not answer)
  rpcLib = ''
    rpc_cmd() {
      local vm="$1" svc="$2" out rc
      shift 2
      out="$(printf '%s\n' "$*" | ${noxRpc} --dom0 "$svc" "$vm")" || return 1
      rc="''${out##*$'\n'}"
      [[ "$rc" =~ ^exit\ [0-9]+$ ]] || return 1
      [ "$out" = "$rc" ] || printf '%s\n' "''${out%$'\n'*}"
      return "''${rc#exit }"
    }
  '';

  # Target VMs on this host: "name short adminAddress linkAddress"
  targetVms = builtins.filter (
    vm: links.isTarget vm && config.microvm.vms.${vm}.config.config.microvm.hypervisor == "xen"
  ) (builtins.attrNames config.microvm.vms);
  targetsFile = pkgs.writeText "vm-usb-targets" (
    lib.concatMapStrings (
      vm:
      let
        r = vmRegistry.byName.${vm};
      in
      "${vm} ${if r.short or null == null then "-" else r.short} ${r.ip} ${links.addressOf vm}\n"
    ) targetVms
  );
  policyFile = pkgs.writeText "vm-usb-policy" links.policy;

  # Reads raw struct input_event from stdin (sys-usb: cat /dev/input/eventN)
  # and replays it on a uinput device whose capabilities are fixed here, not
  # taken from sys-usb: keyboard keys and mouse buttons/axes only, without
  # power/sleep/wakeup/suspend (logind), radio keys (rfkill) and SysRq (kernel).
  # Everything else (other types, codes, key repeats) is dropped.
  inputRecv = pkgs.writeCBin "xen-input-recv" ''
    #include <fcntl.h>
    #include <linux/uinput.h>
    #include <stdio.h>
    #include <string.h>
    #include <sys/ioctl.h>
    #include <unistd.h>

    static const int rels[] = { REL_X, REL_Y, REL_HWHEEL, REL_WHEEL,
                                REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES };

    static int key_allowed(int code)
    {
      if (code >= BTN_LEFT && code <= BTN_TASK)
        return 1;
      if (code < 1 || code > 255)
        return 0;
      switch (code) {
      case KEY_SYSRQ: case KEY_POWER: case KEY_SLEEP: case KEY_WAKEUP:
      case KEY_SUSPEND: case KEY_RFKILL: case KEY_BLUETOOTH: case KEY_WLAN:
      case KEY_UWB: case KEY_WWAN:
        return 0;
      }
      return 1;
    }

    static int rel_allowed(int code)
    {
      for (size_t i = 0; i < sizeof(rels) / sizeof(rels[0]); i++)
        if (rels[i] == code)
          return 1;
      return 0;
    }

    static int emit(int fd, int type, int code, int value)
    {
      struct input_event ev;
      memset(&ev, 0, sizeof(ev));
      ev.type = type;
      ev.code = code;
      ev.value = value;
      return write(fd, &ev, sizeof(ev)) == sizeof(ev) ? 0 : -1;
    }

    int main(int argc, char **argv)
    {
      struct uinput_setup setup;
      struct input_event ev;
      int fd, pending = 0;

      if (argc != 2) {
        fprintf(stderr, "usage: xen-input-recv <name>\n");
        return 2;
      }
      fd = open("/dev/uinput", O_WRONLY | O_CLOEXEC);
      if (fd < 0) {
        perror("open /dev/uinput");
        return 1;
      }
      ioctl(fd, UI_SET_EVBIT, EV_SYN);
      ioctl(fd, UI_SET_EVBIT, EV_KEY);
      ioctl(fd, UI_SET_EVBIT, EV_REL);
      for (int code = 0; code <= BTN_TASK; code++)
        if (key_allowed(code))
          ioctl(fd, UI_SET_KEYBIT, code);
      for (size_t i = 0; i < sizeof(rels) / sizeof(rels[0]); i++)
        ioctl(fd, UI_SET_RELBIT, rels[i]);

      memset(&setup, 0, sizeof(setup));
      setup.id.bustype = BUS_VIRTUAL;
      snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "xen-input-proxy %s", argv[1]);
      if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
        perror("uinput setup");
        return 1;
      }

      while (fread(&ev, sizeof(ev), 1, stdin) == 1) {
        int ok = 0;
        if (ev.type == EV_KEY)
          ok = key_allowed(ev.code) && (ev.value == 0 || ev.value == 1);
        else if (ev.type == EV_REL)
          ok = rel_allowed(ev.code);
        else if (ev.type == EV_SYN && ev.code == SYN_REPORT && pending) {
          if (emit(fd, EV_SYN, SYN_REPORT, 0) < 0)
            break;
          pending = 0;
        }
        if (ok) {
          if (emit(fd, ev.type, ev.code, ev.value) < 0)
            break;
          pending = 1;
        }
      }

      ioctl(fd, UI_DEV_DESTROY);
      close(fd);
      return 0;
    }
  '';

  inputProxy = pkgs.writeShellScript "xen-input-proxy" ''
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.libnotify
      ]
    }
    whitelist=" ${lib.concatMapStringsSep " " (d: "${d.vendorId}:${d.productId}") links.inputDevices} "
    ${rpcLib}
    declare -A pids notified
    while true; do
      if inputs="$(rpc_cmd sys-usb usb inputs)"; then
        allowed="$(cat ${stateDir}/input-allowed 2>/dev/null)"
        while read -r ev vp busid; do
          # Fields come from sys-usb: check them strictly
          [[ "$ev" =~ ^event[0-9]+$ && "$vp" =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ \
            && "$busid" =~ ^[0-9]+-[0-9]+(\.[0-9]+)*$ ]] || continue
          if [[ "$whitelist" != *" $vp "* ]] && ! grep -qxF "$busid $vp" <<<"$allowed"; then
            if [ -z "''${notified[$busid/$vp]:-}" ]; then
              echo "input device $vp at $busid is not allowed for dom0"
              DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" notify-send -u critical \
                "Neues Eingabegerät in sys-usb" \
                "$vp an $busid bleibt in sys-usb. Freigeben bis zum Abziehen: vm-usb allow-input $busid" || true
              notified[$busid/$vp]=1
            fi
            continue
          fi
          d="''${vp/:/-}-$ev"
          if [ -z "''${pids[$d]:-}" ] || ! kill -0 "''${pids[$d]}" 2>/dev/null; then
            echo "forwarding $d (busid $busid)"
            printf 'input %s\n' "$ev" | ${noxRpc} --dom0 usb sys-usb \
              | ${inputRecv}/bin/xen-input-recv "$d" &
            pids[$d]=$!
          fi
        done <<<"$inputs"
      fi
      sleep 3
    done
  '';

  vmUsb = pkgs.writeShellScriptBin "vm-usb" ''
    set -uo pipefail
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gawk
        pkgs.util-linux
        pkgs.systemd
      ]
    }
    state="''${VM_USB_STATE:-${stateDir}}"
    assign="$state/assign"        # busid vendor:product vm invocation (vm "-": detached by hand)
    inputs="$state/input-allowed" # busid vendor:product, forwarded to dom0
    policy=${policyFile}          # vendor:product name defaultOwner allowedOwner,...
    targets=${targetsFile}        # vm short adminAddress linkAddress
    ${rpcLib}

    die() { echo "vm-usb: $*" >&2; exit 1; }
    helper() { rpc_cmd sys-usb usb "$@"; }
    # sys-usb's device list, checked strictly: busids end up in commands for
    # the VMs
    list_devs() {
      helper list | awk 'NF == 5 && $1 ~ /^[0-9]+-[0-9]+(\.[0-9]+)*$/ \
        && $2 ~ /^[0-9a-f]{4}:[0-9a-f]{4}$/ && $3 ~ /^([0-9]+|-)$/ && $4 ~ /^[01]$/ \
        && $5 ~ /^[A-Za-z0-9._?-]+$/'
    }
    field() { awk -v v="$1" -v f="$2" '$1 == v { print $f }' "$targets"; }
    client() { local vm="$1"; shift; rpc_cmd "$vm" usbip "$@"; }
    resolve_vm() { awk -v v="$1" '$1 == v || $2 == v || $1 "-vm" == v { print $1; exit }' "$targets"; }
    # systemd invocation of the VM's microvm@ unit: changes on every start
    running() { systemctl is-active -q "microvm@$1" && systemctl show -p InvocationID --value "microvm@$1"; }
    assigned_vm() { awk -v b="$1" '$1 == b { print $3 }' "$assign"; }
    has_line() { awk -v b="$1" '$1 == b { f = 1 } END { exit !f }' "$2"; }
    drop_line() { awk -v b="$1" '$1 != b' "$2" > "$2.tmp"; mv "$2.tmp" "$2"; }
    set_line() { drop_line "$1" "$assign"; [ -z "''${2:-}" ] || echo "$2" >> "$assign"; }

    # Device by busid, vendor:product or registry name: "busid vp status bt name"
    resolve_dev() {
      local d="$1" vp
      vp="$(awk -v n="$d" '$2 == n { print $1; exit }' "$policy")"
      [ -z "$vp" ] || d="$vp"
      awk -v d="$d" '$1 == d || $2 == d { print; n++ } END { exit n == 1 ? 0 : 1 }' <<<"$devs"
    }

    # Registry devices only to their allowedOwners, unknown ones to any target
    may_attach() {
      local allowed
      allowed="$(awk -v vp="$1" '$1 == vp { print $4; exit }' "$policy")"
      [ -z "$allowed" ] || [[ ",$allowed," == *",$2,"* ]]
    }

    # usbipd accepts new connections only from VMs with an assignment
    sync_allowed() {
      local want have ip
      want="$(awk '$3 != "-" { print $3 }' "$assign" | sort -u | while read -r vm; do field "$vm" 4; done)"
      have="$(helper allowed)" || return 0
      for ip in $want; do grep -qxF "$ip" <<<"$have" || helper allow "$ip"; done
      for ip in $have; do grep -qxF "$ip" <<<"$want" || helper deny "$ip"; done
    }

    do_attach() { # busid bt vm
      if [ "$2" = 1 ]; then
        # Bluetooth adapter: sys-usb's pairings go along (one-way)
        { echo bt-import; echo bt-export | ${noxRpc} --dom0 usb sys-usb; } \
          | ${noxRpc} --dom0 usbip "$3" | tail -n 1 | grep -qx "exit 0" \
          || echo "vm-usb: pairings not copied to $3 (no bluez there?)" >&2
      fi
      helper bind "$1" && client "$3" attach "$1"
    }

    do_release() { # busid vm
      [ -z "$(running "$2")" ] || client "$2" detach "$1" || true
      helper unbind "$1" || true
    }

    # One pass of vm-usb-auto (under the lock)
    round() {
      local b vp vm inv st bt name def new=""
      devs="$(list_devs)" || return 0
      # Assignments: device unplugged, VM stopped or restarted, link lost
      while read -r b vp vm inv; do
        [ -n "$b" ] || continue
        st="$(awk -v b="$b" -v vp="$vp" '$1 == b && $2 == vp { print $3 }' <<<"$devs")"
        if [ -z "$st" ]; then
          echo "$b ($vp) unplugged"
          [ "$vm" = - ] || [ -z "$(running "$vm")" ] || client "$vm" detach "$b" || true
          continue
        fi
        if [ "$vm" != - ] && [ "$(running "$vm")" != "$inv" ]; then
          echo "$vm stopped or restarted: $b ($vp) back to sys-usb"
          helper unbind "$b" || true
          continue
        fi
        new+="$b $vp $vm $inv"$'\n'
      done < "$assign"
      printf '%s' "$new" > "$assign"
      sync_allowed
      while read -r b vp vm inv; do
        [ -n "$b" ] && [ "$vm" != - ] || continue
        st="$(awk -v b="$b" '$1 == b { print $3 }' <<<"$devs")"
        # 2 = in use; anything else after sys-usb or the link came back
        if [ "$st" != 2 ]; then
          bt="$(awk -v b="$b" '$1 == b { print $4 }' <<<"$devs")"
          do_attach "$b" "$bt" "$vm" && echo "re-attached $b ($vp) to $vm"
        fi
      done < "$assign"
      # Input devices allowed for dom0: until unplugged
      awk 'NR == FNR { have[$1 " " $2] = 1; next } ($1 " " $2) in have' <(printf '%s\n' "$devs") "$inputs" > "$inputs.tmp"
      mv "$inputs.tmp" "$inputs"
      # defaultOwner of devices without an assignment
      while read -r b vp st bt name; do
        [ -n "$b" ] && ! has_line "$b" "$assign" || continue
        def="$(awk -v vp="$vp" '$1 == vp { print $3; exit }' "$policy")"
        [ -n "$def" ] && [ -n "$(field "$def" 1)" ] || continue
        inv="$(running "$def")" || continue
        echo "attaching $b ($vp) to $def (defaultOwner)"
        echo "$b $vp $def $inv" >> "$assign"
        sync_allowed
        do_attach "$b" "$bt" "$def" || echo "attach of $b to $def failed, next round retries"
      done <<<"$devs"
    }

    usage() {
      cat >&2 <<USAGE
    usage: vm-usb list
           vm-usb attach <device> <vm>   device: busid, vendor:product or registry name
           vm-usb detach <device>
           vm-usb allow-input <busid>    input device for dom0, until unplugged
           vm-usb auto                   (service vm-usb-auto)
    USAGE
      exit 2
    }

    [ -d "$state" ] || die "$state missing"
    touch "$assign" "$inputs"
    exec 9>"$state/lock"
    devs=""

    case "''${1:-}" in
      list)
        devs="$(list_devs)" || die "sys-usb not reachable"
        printf '%-8s %-10s %-28s %s\n' BUSID ID NAME OWNER
        while read -r b vp st bt name; do
          [ -n "$b" ] || continue
          rname="$(awk -v vp="$vp" '$1 == vp { print $2; exit }' "$policy")"
          owner="$(awk -v b="$b" -v vp="$vp" '$1 == b && $2 == vp && $3 != "-" { print $3 }' "$assign")"
          if [ -z "$owner" ] && grep -qxF "$b $vp" "$inputs"; then owner="dom0 (allow-input)"; fi
          if [ -z "$owner" ] && [ "$(awk -v vp="$vp" '$1 == vp { print $3; exit }' "$policy")" = host ]; then
            owner="dom0 (input whitelist)"
          fi
          [ "$bt" = 1 ] && name="$name [bt]"
          printf '%-8s %-10s %-28s %s\n' "$b" "$vp" "''${rname:-$name}" "''${owner:-sys-usb}"
        done <<<"$devs"
        ;;
      attach)
        [ $# -eq 3 ] || usage
        flock 9
        devs="$(list_devs)" || die "sys-usb not reachable"
        line="$(resolve_dev "$2")" || die "unknown or ambiguous device: $2 (see vm-usb list)"
        read -r busid vp st bt name <<<"$line"
        vm="$(resolve_vm "$3")"
        [ -n "$vm" ] || die "not a VM that takes USB devices: $3"
        may_attach "$vp" "$vm" || die "$vp may not go to $vm (registry allowedOwners)"
        cur="$(assigned_vm "$busid")"
        if [ -n "$cur" ] && [ "$cur" != - ]; then
          [ "$cur" = "$vm" ] && [ "$st" = 2 ] && { echo "$busid is already attached to $vm"; exit 0; }
          [ "$cur" = "$vm" ] || die "$busid is attached to $cur, detach it first"
        fi
        inv="$(running "$vm")" || die "$vm is not running"
        set_line "$busid" "$busid $vp $vm $inv"
        drop_line "$busid" "$inputs"
        sync_allowed
        if do_attach "$busid" "$bt" "$vm"; then
          echo "attached $busid ($vp) to $vm"
        else
          do_release "$busid" "$vm"
          set_line "$busid"
          sync_allowed
          die "attach of $busid to $vm failed"
        fi
        ;;
      detach)
        [ $# -eq 2 ] || usage
        flock 9
        devs="$(list_devs)" || die "sys-usb not reachable"
        line="$(resolve_dev "$2")" || die "unknown or ambiguous device: $2 (see vm-usb list)"
        read -r busid vp st bt name <<<"$line"
        vm="$(assigned_vm "$busid")"
        [ -n "$vm" ] && [ "$vm" != - ] || die "$busid is not attached to a VM"
        do_release "$busid" "$vm"
        # Stays in sys-usb until unplugged, also with a defaultOwner
        set_line "$busid" "$busid $vp - -"
        sync_allowed
        echo "detached $busid ($vp) from $vm, back in sys-usb"
        ;;
      allow-input)
        [ $# -eq 2 ] || usage
        flock 9
        vp="$(helper inputs | awk -v b="$2" '$3 == b { print $2; exit }')"
        [ -n "$vp" ] || die "$2 is no input device in sys-usb"
        grep -qxF "$2 $vp" "$inputs" || echo "$2 $vp" >> "$inputs"
        echo "input device $2 ($vp) goes to dom0 until it is unplugged"
        ;;
      auto)
        while true; do
          flock 9
          round
          flock -u 9
          sleep 5
        done
        ;;
      *) usage ;;
    esac
  '';
  # Hand the input devices to a VM and back in one step (e.g. steam): the
  # registry's host-allow devices the VM may own, with --bt also the
  # vm-reserved devices it may take over from sys-usb (Bluetooth adapter)
  usb = vmRegistry.hardware.usb;
  allowedNames = vm: pred: map (d: d.name) (builtins.filter pred (usb.allowedForOwner vm));
  inputVms = builtins.filter (vm: allowedNames vm (d: d.policy == "host-allow") != [ ]) targetVms;
  btNames = map (d: d.name) (
    builtins.filter (
      d: (d.defaultOwner or null) == "sys-usb" && d.allowedOwners or [ ] != [ "sys-usb" ]
    ) usb.vmReserved
  );
  inputTo = pkgs.writeShellScriptBin "input-to" ''
    set -u
    usage() {
      echo "usage: input-to <vm> [--bt]   (${lib.concatStringsSep ", " inputVms})" >&2
      exit 2
    }
    [ $# -ge 1 ] && [ $# -le 2 ] || usage
    vm="$1"
    case "''${2:-}" in "") bt=0 ;; --bt) bt=1 ;; *) usage ;; esac
    devs="" btdevs=""
    case "$vm" in
    ${lib.concatMapStrings (vm: ''
      ${vm})
        devs="${lib.concatStringsSep " " (allowedNames vm (d: d.policy == "host-allow"))}"
        btdevs="${
          lib.concatStringsSep " " (
            allowedNames vm (d: d.policy == "vm-reserved" && builtins.elem d.name btNames)
          )
        }"
        ;;
    '') inputVms}
      *) echo "input-to: no input devices may go to $vm (registry allowedOwners)" >&2; exit 1 ;;
    esac
    [ "$bt" = 1 ] && devs="$devs $btdevs"
    present="$(${vmUsb}/bin/vm-usb list | awk 'NR > 1 { print $3 }')" || exit 1
    rc=0
    for d in $devs; do
      if ! grep -qxF "$d" <<<"$present"; then
        echo "$d: not plugged in, skipped"
        continue
      fi
      ${vmUsb}/bin/vm-usb attach "$d" "$vm" || rc=1
    done
    exit "$rc"
  '';
  # Back: every one of these devices that is attached to a VM (or only to <vm>)
  inputBack = pkgs.writeShellScriptBin "input-back" ''
    set -u
    [ $# -le 1 ] || { echo "usage: input-back [vm]" >&2; exit 2; }
    only="''${1:-}"
    names=" ${lib.concatStringsSep " " (lib.unique (map (d: d.name) usb.hostAllow ++ btNames))} "
    rc=0
    while read -r _ _ name owner _; do
      case "$names" in *" $name "*) ;; *) continue ;; esac
      case "$owner" in "" | dom0 | sys-usb) continue ;; esac
      [ -z "$only" ] || [ "$owner" = "$only" ] || continue
      ${vmUsb}/bin/vm-usb detach "$name" || rc=1
    done < <(${vmUsb}/bin/vm-usb list | tail -n +2)
    exit "$rc"
  '';

  # Give the USB controllers back to dom0
  releaseControllers = ''
    if xl domid ${links.domain} >/dev/null 2>&1; then
      xl destroy ${links.domain} || true
    fi
    ${lib.concatMapStrings (path: ''
      xl pci-assignable-remove -r ${path} || true
    '') usbPciPaths}
  '';

  sysUsbRescue = pkgs.writeShellScriptBin "sys-usb-rescue" ''
    set -u
    sudo systemctl stop microvm@sys-usb
    sudo ${pkgs.writeShellScript "sys-usb-release" ''
      PATH=${lib.makeBinPath [ xen ]}
      ${releaseControllers}
    ''}
    echo "USB controllers are back in dom0."
    echo "Start sys-usb again later with: sudo systemctl start microvm@sys-usb"
  '';
in
{
  options.services.xen-usb = {
    enable = lib.mkEnableOption "dom0 side of sys-usb (input proxy, fallback)";

    user = lib.mkOption {
      type = lib.types.str;
      default = "nx";
      description = "dom0 user that may use the rpc-in relay sockets (nox-rpc --dom0); runs the input proxy and vm-usb.";
    };

    fallbackTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = "Seconds sys-usb gets to become reachable before dom0 takes the USB controllers back.";
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.uinput.enable = true;

    environment.systemPackages = [
      sysUsbRescue
      vmUsb
      inputTo
      inputBack
    ];

    # vm-usb state (assignments), runtime only like the assignments themselves
    systemd.tmpfiles.rules = [ "d ${stateDir} 0750 ${cfg.user} users -" ];

    systemd.services = {
      xen-input-proxy = {
        description = "Forward input devices from sys-usb to dom0";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = inputProxy;
          User = cfg.user;
          SupplementaryGroups = [ "uinput" ];
          Restart = "always";
          RestartSec = 5;
        };
      };

      vm-usb-auto = {
        description = "Keep USB device assignments (defaultOwner, VM restarts, unplugging)";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${vmUsb}/bin/vm-usb auto";
          User = cfg.user;
          Restart = "always";
          RestartSec = 5;
        };
      };

      sys-usb-fallback = {
        description = "Take the USB controllers back if sys-usb does not come up";
        wantedBy = [ "microvm@sys-usb.service" ];
        after = [ "microvm@sys-usb.service" ];
        path = [
          xen
          pkgs.coreutils
          pkgs.bash
          pkgs.systemd
        ];
        serviceConfig = {
          Type = "oneshot";
          TimeoutStartSec = cfg.fallbackTimeout + 60;
        };
        script = ''
          # sys-usb's userland answers dom0's rpc ping (through nox-relay)
          for _ in $(seq ${toString cfg.fallbackTimeout}); do
            if [ "$(timeout 3 ${noxRpc} --dom0 ping sys-usb </dev/null 2>/dev/null)" = ok ]; then
              exit 0
            fi
            sleep 1
          done
          echo "sys-usb not reachable after ${toString cfg.fallbackTimeout} s, giving the USB controllers back to dom0"
          systemctl stop --no-block microvm@sys-usb.service
          sleep 5
          ${releaseControllers}
        '';
      };
    };
  };
}

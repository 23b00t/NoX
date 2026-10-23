# vm-gui (v2.8.4): GUI apps from Xen VMs over vchan. dom0's wprsc talks to
# the VM's wprsd through nox-relay (/run/nox-relay/<vm>-wprs.sock) instead
# of an SSH tunnel; one wprsc per VM. The app is started by RPC (stage C3,
# `nox-rpc --dom0 app <vm>`, handler in vms/modules/vchan-relay.nix, image
# domains: modules/xen-image-domains.nix). vm-run uses vm-gui for Xen
# guests with wprs over the relay.
{
  lib,
  pkgs,
  vmRegistry,
  ...
}:
let

  # Sandbox of dom0's wprsc (user unit wprsc@<vm>, xen-migration.md night
  # run 2026-10-21): no network (own namespace, only AF_UNIX), no home, no
  # /run except the system profile (icons), the compositor socket, its own
  # relay socket and its runtime dir (bound per call in start_wprsc), so no
  # session or system bus, no user manager, no other VM's relay sockets; own
  # PID namespace, no capabilities, seccomp, 1 GB at most (no swap). PID 1 in its
  # namespace ignores SIGTERM: stopped with SIGKILL (it keeps no state).
  # Tried on the hp: ProcSubset=pid together with PrivatePIDs makes wprsc
  # panic, so it is left out
  wprscSandbox = lib.concatMapStringsSep " " (p: "-p ${p}") [
    "PrivateUsers=yes"
    "PrivateNetwork=yes"
    "RestrictAddressFamilies=AF_UNIX"
    "ProtectHome=tmpfs"
    "ProtectSystem=strict"
    "PrivateTmp=yes"
    "PrivateDevices=yes"
    "PrivatePIDs=yes"
    "TemporaryFileSystem=/run:ro"
    "BindReadOnlyPaths=/run/current-system"
    "NoNewPrivileges=yes"
    "CapabilityBoundingSet="
    "SystemCallFilter=@system-service"
    "SystemCallArchitectures=native"
    "RestrictNamespaces=yes"
    "LockPersonality=yes"
    "MemoryDenyWriteExecute=yes"
    "ProtectProc=invisible"
    "ProtectKernelTunables=yes"
    "ProtectKernelModules=yes"
    "ProtectControlGroups=yes"
    "MemoryMax=1G"
    # without it, it swaps instead of being killed (3.8 GB swap in the test)
    "MemorySwapMax=0"
    "KillSignal=SIGKILL"
  ];

  vmCases = lib.concatMapStrings (
    vm:
    "  ${vm.name}${
        lib.optionalString (vm.short != null && vm.short != vm.name) "|${vm.short}"
      }) VM=${vm.name} ;;\n"
  ) (vmRegistry.vms ++ vmRegistry.imageDomains);

  vmGui = pkgs.writeShellScriptBin "vm-gui" ''
    set -eu
    if [ $# -lt 2 ]; then
      echo "usage: vm-gui <vm|short> <command> [args...]" >&2
      exit 2
    fi
    case "$1" in
    ${vmCases}
      *) echo "vm-gui: unknown VM: $1" >&2; exit 2 ;;
    esac
    shift

    fail() {
      echo "vm-gui: $1" >&2
      ${pkgs.libnotify}/bin/notify-send "vm-gui: $VM" "$1" || true
      exit 1
    }

    # The relay sockets appear once the VM's domain exists (VM just started)
    sock="/run/nox-relay/$VM-wprs.sock"
    rpc="/run/nox-relay/$VM-rpc-in.sock"
    for _ in $(seq 60); do
      [ -S "$sock" ] && break
      sleep 1
    done
    [ -S "$sock" ] || fail "$sock missing (does $VM run wprsd, is nox-relay-$VM up?)"

    run="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    unit="wprsc@$VM"
    case "''${WAYLAND_DISPLAY:-wayland-0}" in
      /*) wayland="$WAYLAND_DISPLAY" ;;
      *) wayland="$run/''${WAYLAND_DISPLAY:-wayland-0}" ;;
    esac
    # Locked: apps started together (niri spawn-at-startup) each saw no
    # wprsc and started their own (three for chat, 2026-10-15).
    # wprsc must not inherit the lock fd, it would hold the lock forever.
    # The app answer comes before wprsd listens at boot: the VM refuses the
    # stream and wprsc exits at once (nvim's foot missing for 3 min, hp
    # 2026-10-19), so start it again until it stays up.
    # wprsc runs as the user unit wprsc@<vm> (transient, gone when it ends;
    # log: journalctl --user -u wprsc@<vm>) in a sandbox: it parses what
    # the VM sends, so a hole in it must not reach dom0 (sandbox: let block
    # above)
    start_wprsc() {
      (
        ${pkgs.util-linux}/bin/flock 9
        for _ in $(seq 30); do
          systemctl --user is-active --quiet "$unit" && break
          # App id prefix: niri's border rule per trust label matches it
          # (home/desktop/niri.nix `labelRules`), the title prefix shows the VM.
          # Fullscreen only via niri's keybinding, never on the app's request
          systemd-run --user --quiet --collect --unit="$unit" \
            ${wprscSandbox} \
            -p BindReadOnlyPaths="$wayland" -p BindReadOnlyPaths="$sock" \
            -p RuntimeDirectory="wprsc/$VM" -p BindPaths="$run/wprsc/$VM" \
            -E WAYLAND_DISPLAY="$wayland" -E XDG_RUNTIME_DIR="$run" \
            -E XCURSOR_THEME -E XCURSOR_SIZE -E XCURSOR_PATH \
            ${pkgs.wprs}/bin/wprsc --socket="$sock" \
            --control-socket="$run/wprsc/$VM/ctrl.sock" \
            --title-prefix="[$VM] " --app-id-prefix="[$VM] " --deny-fullscreen true \
            9>&- || true
          sleep 1
        done
      ) 9>"$run/wprsc-$VM.lock"
    }

    # Same environment the wprs launcher sets for remote apps; over RPC the
    # VM sets it (apps.environment), only the cursor size comes from here
    cursor="XCURSOR_SIZE=''${XCURSOR_SIZE:-24}"
    [ -S "$rpc" ] || fail "$rpc missing (is nox-relay-$VM up?)"
    # wprsc first: an app that comes up before any wprsc is attached gets no
    # output from wprsd and ends (the first app after a VM boot never showed
    # with the sandboxed wprsc, which takes longer to start; hp 2026-10-22).
    # At boot wprsd may not listen yet: start_wprsc retries, and runs again
    # after the app start in case the boot took longer than its tries
    start_wprsc
    # Retry while the VM is still booting (the relay drops the call
    # without an answer); the handler answers "ok: ..." or "error: ...".
    # One token for all tries: a retry after a lost answer doesn't start
    # the app twice (NoX startApp; older handlers just get one more variable)
    token="$(${pkgs.coreutils}/bin/od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    answer=""
    for _ in $(seq 60); do
      answer="$(printf '%s\0' env "NOX_APP_TOKEN=$token" "$cursor" "$@" | nox-rpc --dom0 app "$VM" 2>/dev/null)" || true
      [ -n "$answer" ] && break
      sleep 1
    done
    [[ "$answer" == ok* ]] || fail "start of $1 failed: ''${answer:-no answer}"
    start_wprsc
  '';

  # Clipboard between domains (Qubes model): each VM keeps its own clipboard
  # (wprsd without selection sync, vms/modules/wprs.nix). `copy` takes the
  # text clipboard of the focused window's domain into a store in dom0,
  # `paste` hands it to the focused window's domain and empties the store.
  # Rules from the registry (`clipboard`); notifications never show content
  clipPolicy = vm: vm.clipboard or (if lib.hasPrefix "sys-" vm.name then "deny" else "allow");
  clipCases = lib.concatMapStrings (vm: "    ${vm.name}) echo ${clipPolicy vm} ;;\n") (
    vmRegistry.vms ++ vmRegistry.imageDomains
  );

  vmClip = pkgs.writeShellScriptBin "vm-clip" ''
    set -eu
    # The VM's fixed service `clip` (nox-rpc, only dom0 calls)
    clip_get() {
      printf 'get\n' | timeout 20 nox-rpc --dom0 clip "$1"
    }
    clip_set() {
      { printf 'set\n'; cat; } | timeout 20 nox-rpc --dom0 clip "$1" >/dev/null
    }
    notify() {
      ${pkgs.libnotify}/bin/notify-send -a vm-clip "Zwischenablage" "$1" || true
    }
    fail() {
      notify "$1"
      echo "vm-clip: $1" >&2
      exit 1
    }

    # Domain of the focused window: VM windows belong to dom0's wprsc for
    # that VM (vm-gui), everything else is dom0
    focused_domain() {
      local pid args dom
      pid="$(niri msg --json focused-window | ${pkgs.jq}/bin/jq -r '.pid // empty')"
      [ -n "$pid" ] || fail "Kein fokussiertes Fenster"
      args="$(tr '\0' '\n' <"/proc/$pid/cmdline")" || fail "Fensterprozess $pid nicht gefunden"
      case "$args" in
        */wprsc*)
          dom="$(sed -n 's|^--socket=/run/nox-relay/\(.*\)-wprs\.sock$|\1|p' <<<"$args")"
          [ -n "$dom" ] || fail "VM des Fensters unbekannt (wprsc ohne nox-relay)"
          ;;
        *) dom=dom0 ;;
      esac
      echo "$dom"
    }

    policy() {
      case "$1" in
        dom0) echo allow ;;
    ${clipCases}
        *) echo deny ;;
      esac
    }

    store="''${XDG_RUNTIME_DIR:?}/vm-clip"
    umask 077
    mkdir -p "$store"

    case "''${1:-}" in
      copy)
        src="$(focused_domain)"
        case "$(policy "$src")" in
          deny) fail "$src ist für die Zwischenablage gesperrt" ;;
          ask)
            answer="$(printf 'Nein\nJa\n' | rofi -dmenu -i -no-custom \
              -p "Zwischenablage aus $src kopieren?" \
              -theme /etc/xdg/rofi/config.rasi)" || answer=""
            [ "$answer" = Ja ] || fail "Kopieren aus $src abgebrochen"
            ;;
        esac
        if [ "$src" = dom0 ]; then
          ${pkgs.wl-clipboard}/bin/wl-paste --no-newline --type text >"$store/new" 2>/dev/null \
            || { rm -f "$store/new"; fail "dom0: keine Text-Zwischenablage"; }
        else
          clip_get "$src" >"$store/new" 2>/dev/null \
            || { rm -f "$store/new"; fail "$src: keine Text-Zwischenablage"; }
        fi
        mv "$store/new" "$store/data"
        echo "$src" >"$store/source"
        notify "Aus $src kopiert ($(wc -c <"$store/data") Bytes), einfügen mit Mod+Alt+V"
        ;;
      paste)
        [ -f "$store/data" ] || fail "Ablage leer, erst mit Mod+Alt+C kopieren"
        dst="$(focused_domain)"
        [ "$(policy "$dst")" != deny ] || fail "$dst ist für die Zwischenablage gesperrt"
        src="$(cat "$store/source")"
        size="$(wc -c <"$store/data")"
        if [ "$dst" = dom0 ]; then
          # wl-copy forks and keeps serving the selection
          ${pkgs.wl-clipboard}/bin/wl-copy --type text/plain <"$store/data" >/dev/null 2>&1
        else
          clip_set "$dst" <"$store/data" || fail "Einfügen in $dst fehlgeschlagen"
        fi
        rm -f "$store/data" "$store/source"
        notify "$src → $dst ($size Bytes), einfügen mit Strg+V"
        ;;
      *)
        echo "usage: vm-clip copy|paste" >&2
        exit 2
        ;;
    esac
  '';

  # One-time copy from a NixOS VM into dom0 (Qubes `qvm-run --pass-io`
  # model, e.g. the kali image from coding): dom0 asks, the VM's fixed
  # service `pull` (vms/modules/vchan-relay.nix) sends a file from its
  # ~/outbox, it lands in ~/Incoming/<vm>/ without exec bit and is never run.
  # The VM's answer is untrusted: names checked, control characters dropped
  pullCases = lib.concatMapStrings (
    vm:
    "  ${vm.name}${
        lib.optionalString (vm.short != null && vm.short != vm.name) "|${vm.short}"
      }) VM=${vm.name} ;;\n"
  ) vmRegistry.vms;

  vmPull = pkgs.writeShellScriptBin "vm-pull" ''
    set -euo pipefail
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
      echo "usage: vm-pull <vm|short> [<file in the VM's ~/outbox>]" >&2
      echo "  without a file: list the VM's ~/outbox" >&2
      exit 2
    fi
    case "$1" in
    ${pullCases}
      *) echo "vm-pull: unknown VM: $1" >&2; exit 2 ;;
    esac
    [ -S "/run/nox-relay/$VM-rpc-in.sock" ] || { echo "vm-pull: $VM is not running" >&2; exit 1; }
    name_re='^[A-Za-z0-9_+-][A-Za-z0-9._+-]*$'

    if [ $# -eq 1 ]; then
      printf 'list\n' | timeout 20 nox-rpc --dom0 pull "$VM" | while IFS=$'\t' read -r n s; do
        [[ "$n" =~ $name_re && "$s" =~ ^[0-9]+$ ]] || continue
        printf '%s\t%s\n' "$(${pkgs.coreutils}/bin/numfmt --to=iec "$s")" "$n"
      done
      exit 0
    fi

    name="$2"
    [[ "$name" =~ $name_re ]] || { echo "vm-pull: bad file name (only letters, digits, ._+-)" >&2; exit 2; }
    dest="$HOME/Incoming/$VM"
    out="$dest/$name"
    part="$out.partial"
    [ ! -e "$out" ] || { echo "vm-pull: $out exists" >&2; exit 1; }
    mkdir -p "$dest"

    exec 3< <(printf 'get %s\n' "$name" | nox-rpc --dom0 pull "$VM")
    IFS= read -r hdr <&3 || { echo "vm-pull: no answer from $VM" >&2; exit 1; }
    if ! [[ "$hdr" =~ ^ok\ ([0-9]+)$ ]]; then
      echo "vm-pull: $VM: ''${hdr//[^[:print:]]/?}" >&2
      exit 1
    fi
    size="''${BASH_REMATCH[1]}"
    printf 'Copy %s (%s) from %s to %s? [y/N] ' "$name" \
      "$(${pkgs.coreutils}/bin/numfmt --to=iec "$size")" "$VM" "$out"
    read -r yn </dev/tty
    case "$yn" in
      [yYjJ]*) ;;
      *) echo "aborted"; exit 1 ;;
    esac
    umask 022
    rm -f "$part"
    if ! ${pkgs.zstd}/bin/zstd -d -q -c <&3 \
      | dd of="$part" bs=1M iflag=fullblock conv=sparse status=progress; then
      rm -f "$part"
      echo "vm-pull: transfer failed" >&2
      exit 1
    fi
    got="$(stat -c %s "$part")"
    if [ "$got" != "$size" ]; then
      rm -f "$part"
      echo "vm-pull: got $got bytes, $VM announced $size" >&2
      exit 1
    fi
    mv -n "$part" "$out"
    echo "$out"
  '';
in
{
  environment.systemPackages = [
    vmGui
    vmClip
    vmPull
  ];
}

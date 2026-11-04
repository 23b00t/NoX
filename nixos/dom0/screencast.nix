# Screen sharing into VMs (registry `screenShare`, 2026-11-03): an app in
# such a VM asks its portal for a screen (vms/modules/screencast.nix), the
# portal opens the relay service `screencast` to dom0. Here one user socket
# per VM (/run/user/1000/nox-screencast/<vm>.sock, served to the relay in
# xen-dom0.nix) starts one service instance per share: it asks in rofi which
# window or output (`nox-wm cast-targets`), casts it (`nox-wm cast`; niri:
# org.gnome.Mutter.ScreenCast, no portal dialog), encodes it with VA-API
# H.264 and sends the stream back on that connection. The VM gets nothing
# but those pixels; the source VM takes no part. Stopping the instance
# (waybar, `systemctl --user stop 'nox-screencast-*@*'`) or the app closing
# the share ends it.
{
  lib,
  pkgs,
  vmRegistry,
  ...
}:
let
  vms = map (v: v.name) (builtins.filter (v: v.screenShare or false) vmRegistry.vms);

  gst = pkgs.gst_all_1;
  gstPlugins = lib.makeSearchPath "lib/gstreamer-1.0" [
    gst.gstreamer.out
    gst.gst-plugins-base
    # va (vapostproc, vah264enc), videoparsersbad (h264parse)
    gst.gst-plugins-bad
    # pipewiresrc
    pkgs.pipewire
  ];

  # One share; stdin/stdout = the connection from the VM (via the relay).
  # Protocol: `screencast <app id>` in, `ok window|monitor`, `cancel` or
  # `error <text>` out, after `ok` the H.264 byte stream
  serve = pkgs.writeShellScript "nox-screencast-serve" ''
    set -euo pipefail
    PATH=${
      lib.makeBinPath [
        gst.gstreamer.bin
        pkgs.coreutils
        pkgs.libnotify
        pkgs.rofi
      ]
    }:/run/current-system/sw/bin
    export GST_PLUGIN_SYSTEM_PATH_1_0=${gstPlugins}
    vm="$1"
    XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export XDG_RUNTIME_DIR
    if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
      for s in "$XDG_RUNTIME_DIR"/wayland-*; do
        case "$s" in *.lock) continue ;; esac
        [ -S "$s" ] && export WAYLAND_DISPLAY="''${s##*/}" && break
      done
    fi

    IFS= read -r -t 10 request || exit 0
    # `screencast <app id> [<types>]`, types: 1 screens, 2 windows, 3 both
    if ! [[ "$request" =~ ^screencast\ ([A-Za-z0-9._?-]{1,64})(\ ([1-3]))?$ ]]; then
      echo "error bad request"
      exit 0
    fi
    app="''${BASH_REMATCH[1]}"
    types="''${BASH_REMATCH[3]:-3}"

    # <kind>\t<id>\t<label>, only the kinds asked for; labels (window
    # titles) come from the VMs: printable only, no markup
    mapfile -t targets < <(nox-wm cast-targets | tr -d '\000-\010\013-\037\177' |
      while IFS= read -r t; do
        case "$t" in
          output$'\t'*) (( types & 1 )) && printf '%s\n' "$t" ;;
          window$'\t'*) (( types & 2 )) && printf '%s\n' "$t" ;;
        esac
      done || true)
    if [ "''${#targets[@]}" -eq 0 ]; then
      echo "error nothing to share"
      exit 0
    fi

    # Chromium asks twice in a row (its picker's preview, then the share):
    # the same app's second request within 15 s gets the pick it just had,
    # if that window or screen is still there
    last="$XDG_RUNTIME_DIR/nox-screencast/$vm.last"
    pick=""
    if [ -f "$last" ] && IFS=$'\t' read -r when lapp lkind lid <"$last" &&
      [ "$lapp" = "$app" ] && [ $(( $(date +%s) - when )) -le 15 ]; then
      for t in "''${targets[@]}"; do
        case "$t" in "$lkind"$'\t'"$lid"$'\t'*) pick="$t" ;; esac
      done
    fi
    rm -f "$last"
    if [ -z "$pick" ]; then
      if ! i="$(printf '%s\n' "''${targets[@]}" | cut -f3- |
        timeout 60 rofi -dmenu -i -no-custom -format i -theme /etc/xdg/rofi/config.rasi \
          -p "Share" -mesg "<b>$vm</b> ($app) wants to see a window or a screen" \
          -theme-str 'mainbox { children: [ "inputbar", "message", "listview" ]; }
            message { padding: 10px 14px; background-color: @main-bg; }
            textbox { horizontal-align: 0; background-color: @main-bg; text-color: @main-fg; }')" ||
        ! [[ "$i" =~ ^[0-9]+$ ]] || [ "$i" -ge "''${#targets[@]}" ]; then
        echo cancel
        exit 0
      fi
      pick="''${targets[$i]}"
    fi
    IFS=$'\t' read -r kind id label <<<"$pick"
    case "$kind" in
      window) type=window ;;
      output) type=monitor ;;
      *)
        echo "error bad target"
        exit 0
        ;;
    esac

    # The cast lives while this script holds its stdin (no exec below)
    coproc CAST { exec nox-wm cast "$kind" "$id"; }
    if ! read -r -t 10 node <&"''${CAST[0]}" || ! [[ "$node" =~ ^[0-9]+$ ]]; then
      echo "error cast failed"
      exit 0
    fi
    echo "ok $type"
    notify-send -a "Screen share" "Screen share" "$vm sees: $label"
    # niri sends a window's frames only on damage: an idle window gave one
    # frame, which stayed in the encoder, so the VM never got a first
    # picture and the app waited forever (2026-11-04). keepalive-time
    # repeats the last frame every 100 ms, b-frames=0 lets each one out
    gst-launch-1.0 -q pipewiresrc path="$node" keepalive-time=100 \
      ! 'video/x-raw(memory:DMABuf)' ! vapostproc ! 'video/x-raw,format=NV12' \
      ! vah264enc target-usage=7 b-frames=0 \
      ! h264parse config-interval=-1 \
      ! 'video/x-h264,stream-format=byte-stream,alignment=au' \
      ! fdsink fd=1 &
    gst=$!
    # The VM sends nothing after the request: EOF on stdin = the app ended
    # the share. A still picture writes nothing, so the broken pipe alone
    # would never come (the cast and the waybar icon stayed). Background
    # jobs get /dev/null as stdin, hence the explicit <&0
    { cat >/dev/null; kill "$gst" 2>/dev/null; } <&0 &
    wait "$gst" || true
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$app" "$kind" "$id" >"$last"
    notify-send -a "Screen share" "Screen share" "$vm no longer sees: $label"
  '';
in
{
  config = lib.mkIf (vms != [ ]) {
    systemd.user.sockets = lib.listToAttrs (
      map (
        vm:
        lib.nameValuePair "nox-screencast-${vm}" {
          description = "Screen share requests from ${vm}";
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = "%t/nox-screencast/${vm}.sock";
            Accept = true;
            SocketMode = "0600";
            # one share at a time per VM is plenty
            MaxConnections = 4;
          };
        }
      ) vms
    );
    systemd.user.services = lib.listToAttrs (
      map (
        vm:
        lib.nameValuePair "nox-screencast-${vm}@" {
          description = "Screen share to ${vm}";
          serviceConfig = {
            ExecStart = "${serve} ${vm}";
            StandardInput = "socket";
            StandardOutput = "socket";
            StandardError = "journal";
          };
        }
      ) vms
    );
  };
}

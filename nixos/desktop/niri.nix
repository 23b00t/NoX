{
  pkgs,
  lib,
  config,
  vmRegistry,
  ...
}:
let
  theme = import ./theme.nix {
    inherit lib;
    inherit (config.nox.desktop) theme;
  };
  # Shared with VMs that run their own niri (godot-gpu): input, layout, look,
  # window and workspace keys, generic window rules
  base = import ./niri-base.nix {
    inherit lib theme;
    inherit (config.nox.desktop) keyboard;
  };
  hostname = config.networking.hostName;
  login = config.nox.desktop.login;
  colorMath = import ../lib/color.nix { inherit lib; };
  # Default wallpaper and lock screen image: the NoX logo in the theme's
  # colors (nix/nox-branding.nix)
  branding =
    let
      t = config.nox.desktop.theme;
    in
    pkgs.callPackage ../../nix/nox-branding.nix {
      colors = theme.graphics;
      inherit (t) resolution;
      wallpaper = { inherit (t) flavor shade decor; };
      lock = { inherit (t.lock) flavor shade decor; };
    };

  # Trust label per VM (vms/registry.nix `label`, absent = untrusted): one
  # window rule per label on the "[<vm>] " app id prefix that dom0's wprsc
  # sets (`--app-id-prefix`, home/vm-management/vm-gui.nix, vm-run; "[<vm>]"
  # alone for windows without an app id). A VM cannot fake it: its own app
  # id only follows the prefix. dom0's color only for app ids that don't
  # start with "["; windows matching neither (a dom0 window without an app
  # id) keep the layout default `unknown`
  labelRule = label: appId: {
    "window-rule"._children = [
      { match._props."app-id" = appId; }
      {
        border = {
          "active-color" = theme.label.${label};
          "inactive-color" = theme.labelWithAlpha label theme.opacity.inactiveBorder;
        };
      }
      {
        "focus-ring" = {
          "active-color" = theme.label.${label};
          "inactive-color" = theme.labelWithAlpha label theme.opacity.inactiveRing;
        };
      }
    ];
  };
  labelRules = [
    (labelRule "dom0" "^[^\\[]")
  ]
  ++ lib.mapAttrsToList (
    label: vms: labelRule label "^\\[(${lib.concatMapStringsSep "|" (vm: vm.name) vms})\\]( |$)"
  ) (lib.groupBy (vm: vm.label or "untrusted") (vmRegistry.vms ++ vmRegistry.imageDomains));

  # Internal panel per machine. xmg: 2560x1600 at 60 Hz; at its preferred
  # 300 Hz the i915 cannot drive the two external monitors as well (the
  # third output stays disabled, page flips fail with EBUSY, 2026-10-14)
  edp =
    if hostname == "xmg" then
      {
        mode = "2560x1600@60.000";
        width = 2560;
      }
    else
      {
        mode = "1920x1080@60.001";
        width = 1920;
      };

  # Tray apps per VM, started with the session (spawn-at-startup) and again
  # by `vm-tray <vm>` after that VM is (re)started (manage-vms): the VMs'
  # apps with `tray = true` (registry `apps`; sys-net's nm-applet, too)
  trayOf =
    a:
    [ a.binary ] ++ (a.args or [ ]) ++ (a.trayArgs or [ ]) ++ lib.optional a.x11 "--ozone-platform=x11";
  trayApps = lib.listToAttrs (
    lib.concatMap (
      vm:
      let
        apps = lib.filter (a: a.tray) (vm.apps or [ ]);
      in
      lib.optional (apps != [ ]) {
        inherit (vm) name;
        value = map trayOf apps;
      }
    ) vmRegistry.vms
  );
  trayCommands = lib.concatLists (
    lib.mapAttrsToList (
      vm:
      map (
        app:
        [
          "vm-run"
          vm
        ]
        ++ app
      )
    ) trayApps
  );

  # Terminals at login (replaced kitty's startup session): dom0's foot (on
  # the hp with zellij, which stays there) and foot from nvim and coding
  # over wprs, zellij in the VM, as tabs of one column (Mod+1…3). All start
  # at once; niri's event stream reports each window as it opens (VMs may
  # still boot), it goes into the column right away, at its place in the
  # order dom0, nvim, coding; after 5 min the rest is given up. A VM's foot
  # could come twice at boot (xmg 2026-10-17, vm-run retried an app start
  # whose answer got lost): the first window stays, later ones (more zellij
  # clients of the same session) are closed when they appear. Terminals
  # that are already open are not started again (vm-autostart)
  vmZellij = [
    "zellij"
    "--layout"
    "tabs"
    "attach"
    "-c"
  ];
  # Mod+Q: terminals (foot in dom0 or from a VM, zellij sessions inside)
  # close only on a second Mod+Q within 3 s, the first one shows a
  # notification; other windows close right away
  closeGuard = pkgs.writeShellScriptBin "close-guard" ''
    w=$(niri msg --json focused-window)
    id=$(${pkgs.jq}/bin/jq -r '.id // empty' <<<"$w")
    app=$(${pkgs.jq}/bin/jq -r '.app_id // ""' <<<"$w")
    [ -n "$id" ] || exit 0
    # VM windows carry "[<vm>] " before the app id (wprsc --app-id-prefix)
    case "''${app#\[*\] }" in
      foot | footclient | term-*) ;;
      *) exec niri msg action close-window --id "$id" ;;
    esac
    mark="''${XDG_RUNTIME_DIR:-/tmp}/close-guard"
    now=$(date +%s)
    [ ! -r "$mark" ] || read -r last_id last_t <"$mark" || true
    if [ "''${last_id:-}" = "$id" ] && [ $((now - ''${last_t:-0})) -le 3 ]; then
      rm -f "$mark"
      exec niri msg action close-window --id "$id"
    fi
    echo "$id $now" >"$mark"
    ${pkgs.libnotify}/bin/notify-send -a niri -t 3000 "Close terminal?" "Press Mod+Q again within 3 s"
  '';

  # terminal-tabs [tab…] (default: all of nox.desktop.login.terminalTabs)
  terminalTabs = pkgs.writeShellScript "terminal-tabs" ''
    set -u
    jq=${pkgs.jq}/bin/jq
    [ $# -gt 0 ] || set -- ${lib.escapeShellArgs login.terminalTabs}
    order=(${lib.escapeShellArgs login.terminalTabs})
    app_of() { if [ "$1" = dom0 ]; then echo term-dom0; else echo "[$1] term-$1"; fi; }
    declare -A rank id_of expect
    for i in "''${!order[@]}"; do rank[$(app_of "''${order[$i]}")]=$i; done
    col=() # app ids of the column, in tab order

    # A new terminal: into the column on its left, then up past the tabs
    # that come after it in the order (move-window-up needs the focus, it
    # goes back afterwards)
    place() {
      local id=$1 app=$2 k=0 a prev n
      id_of[$app]=$id
      if [ ''${#col[@]} -eq 0 ]; then
        col=("$app")
        return
      fi
      niri msg action consume-or-expel-window-left --id "$id"
      for a in "''${col[@]}"; do
        [ "''${rank[$a]}" -le "''${rank[$app]}" ] || k=$((k + 1))
      done
      if [ "$k" -gt 0 ]; then
        prev=$(niri msg --json focused-window | $jq -r '.id // empty')
        niri msg action focus-window --id "$id"
        for _ in $(seq "$k"); do niri msg action move-window-up; done
        [ -z "$prev" ] || [ "$prev" = "$id" ] || niri msg action focus-window --id "$prev"
      fi
      n=$((''${#col[@]} - k))
      col=("''${col[@]:0:n}" "$app" "''${col[@]:n}")
    }

    # "init <id> <app id>" per open window (column order), "ready", then
    # "open <id> <app id>" per new or changed window
    coproc events {
      timeout 300 niri msg --json event-stream | $jq --unbuffered -r '
        if .WindowsChanged then
          (.WindowsChanged.windows
            | sort_by(.layout.pos_in_scrolling_layout[1] // 0)
            | .[] | "init \(.id) \(.app_id // "")"), "ready"
        elif .WindowOpenedOrChanged then
          .WindowOpenedOrChanged.window | "open \(.id) \(.app_id // "")"
        else empty end'
    }
    started=0 pending=0 done_at=""
    while :; do
      read -r -t 1 kind id app <&"''${events[0]}"
      rc=$?
      # All there: 5 s more for duplicates, then stop
      if [ -n "$done_at" ] && [ "$SECONDS" -ge "$done_at" ]; then break; fi
      [ "$rc" -le 128 ] || continue # no event within 1 s
      [ "$rc" -eq 0 ] || break # stream ended: time limit
      # (an empty app id is no array key)
      [ -n "$app" ] || [ "$kind" = ready ] || continue
      case "$kind" in
        init)
          # Already open (a second run): they are the column
          [ -n "''${rank[$app]+x}" ] && [ -z "''${id_of[$app]+x}" ] || continue
          id_of[$app]=$id
          col+=("$app")
          ;;
        ready)
          [ "$started" -eq 0 ] || continue
          started=1
          for t in "$@"; do
            a=$(app_of "$t")
            [ -z "''${id_of[$a]+x}" ] || continue
            expect[$a]=1
            pending=$((pending + 1))
            if [ "$t" = dom0 ]; then
              foot -a term-dom0 ${lib.escapeShellArgs login.dom0Command} &
            else
              vm-run "$t" foot -a "term-$t" ${lib.escapeShellArgs vmZellij} &
            fi
          done
          [ "$pending" -gt 0 ] || break
          ;;
        open)
          [ -n "''${expect[$app]+x}" ] || continue
          if [ -n "''${id_of[$app]+x}" ]; then
            [ "''${id_of[$app]}" = "$id" ] || niri msg action close-window --id "$id"
            continue
          fi
          place "$id" "$app"
          [ "$app" != term-dom0 ] || niri msg action focus-window --id "$id"
          pending=$((pending - 1))
          [ "$pending" -gt 0 ] || done_at=$((SECONDS + 5))
          ;;
      esac
    done
    kill "''${events_PID:-}" 2>/dev/null
    exit 0
  '';

  binds = base.binds // {
    # Replaces niri's built-in hotkey overlay (Mod+Shift+Slash)
    "Mod+Slash" = {
      _props."hotkey-overlay-title" = "Keybinding Viewer";
      "spawn-sh" = "pkill rofi || niri-binds";
    };

    "Mod+T" = {
      _props."hotkey-overlay-title" = "Open a Terminal: foot";
      spawn = [ "foot" ];
    };

    "Mod+A" = {
      _props."hotkey-overlay-title" = "Run an Application: rofi";
      "spawn-sh" =
        "pkill rofi || rofi -modi drun,filebrowser,window,run -show drun -theme /etc/xdg/rofi/config.rasi";
    };

    "Mod+B" = {
      _props."hotkey-overlay-title" = "Open Browser VM";
      "spawn-sh" = "vm-run net zen";
    };

    "Mod+Alt+L" = {
      _props."hotkey-overlay-title" = "Lock the Screen: swaylock";
      spawn = [
        "swaylock"
        "-C"
        "/etc/xdg/swaylock/config"
      ];
    };

    "Mod+Comma" = {
      _props."hotkey-overlay-title" = "Emoji Picker";
      "spawn-sh" =
        "rofimoji --max-recent 10 --action print --selector-args='-theme /etc/xdg/rofi/config.rasi' | vm-clip put";
    };

    "Mod+Alt+C" = {
      _props."hotkey-overlay-title" = "Copy Clipboard to the dom0 Store";
      spawn = [
        "vm-clip"
        "copy"
      ];
    };

    "Mod+Alt+V" = {
      _props."hotkey-overlay-title" = "Paste the dom0 Store into the Focused Window";
      spawn = [
        "vm-clip"
        "paste"
      ];
    };

    "Mod+E" = {
      _props."hotkey-overlay-title" = "Open Explorer";
      spawn = [ "explorer" ];
    };

    "Mod+P" = {
      _props."hotkey-overlay-title" = "Region Screenshot";
      screenshot = { };
    };

    "Mod+Shift+P" = {
      _props."hotkey-overlay-title" = "Fullscreen Screenshot";
      "screenshot-screen" = { };
    };

    "Mod+R" = {
      _props."hotkey-overlay-title" = "Region Recording";
      spawn = [ "screenrec-region" ];
    };

    "Mod+Shift+R" = {
      _props."hotkey-overlay-title" = "Fullscreen Recording";
      spawn = [ "screenrec-full" ];
    };

    "XF86AudioRaiseVolume" = {
      _props = {
        "hotkey-overlay-title" = "Volume Up";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+";
    };

    "XF86AudioLowerVolume" = {
      _props = {
        "hotkey-overlay-title" = "Volume Down";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-";
    };

    "XF86AudioMute" = {
      _props = {
        "hotkey-overlay-title" = "Mute Audio";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
    };

    "XF86AudioMicMute" = {
      _props = {
        "hotkey-overlay-title" = "Mute Microphone";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle";
    };

    "XF86MonBrightnessUp" = {
      _props = {
        "hotkey-overlay-title" = "Brightness Up";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "brightnessctl -d intel_backlight -e4 -n2 set 5%+";
    };

    "XF86MonBrightnessDown" = {
      _props = {
        "hotkey-overlay-title" = "Brightness Down";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "brightnessctl -d intel_backlight -e4 -n2 set 5%-";
    };

    # The same without Fn: Mod+PgUp/PgDn/Backspace volume, with Shift brightness
    "Mod+Page_Up" = {
      _props = {
        "hotkey-overlay-title" = "Volume Up";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+";
    };

    "Mod+Page_Down" = {
      _props = {
        "hotkey-overlay-title" = "Volume Down";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-";
    };

    "Mod+BackSpace" = {
      _props = {
        "hotkey-overlay-title" = "Mute Audio";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
    };

    "Mod+Shift+Page_Up" = {
      _props = {
        "hotkey-overlay-title" = "Brightness Up";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "brightnessctl -d intel_backlight -e4 -n2 set 5%+";
    };

    "Mod+Shift+Page_Down" = {
      _props = {
        "hotkey-overlay-title" = "Brightness Down";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "brightnessctl -d intel_backlight -e4 -n2 set 5%-";
    };

    "XF86AudioPlay" = {
      _props = {
        "hotkey-overlay-title" = "Play/Pause";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "playerctl play-pause";
    };

    "XF86AudioPause" = {
      _props = {
        "hotkey-overlay-title" = "Play/Pause";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "playerctl play-pause";
    };

    "XF86AudioPrev" = {
      _props = {
        "hotkey-overlay-title" = "Previous Track";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "playerctl previous";
    };

    "XF86AudioNext" = {
      _props = {
        "hotkey-overlay-title" = "Next Track";
        "allow-when-locked" = true;
      };
      "spawn-sh" = "playerctl next";
    };

    "Mod+Q" = {
      _props.repeat = false;
      _props."hotkey-overlay-title" = "Close Window (terminals: press twice)";
      spawn = [ "close-guard" ];
    };

    "Mod+Period" = {
      _props."hotkey-overlay-title" = "Glyph Picker (Nerd Font)";
      "spawn-sh" =
        "rofimoji --files nerd_font --max-recent 10 --action print --selector-args='-theme /etc/xdg/rofi/config.rasi' | vm-clip put";
    };

    Print.screenshot = { };
    "Ctrl+Print"."screenshot-screen" = { };
    "Alt+Print"."screenshot-window" = { };

  };

  # One viewer entry per action; keys sharing an action are merged
  bindEntries =
    let
      describe =
        name: arg:
        let
          words = lib.splitString "-" name;
          human = lib.concatStringsSep " " (
            [ (lib.toUpper (lib.substring 0 1 (lib.head words)) + lib.substring 1 (-1) (lib.head words)) ]
            ++ lib.tail words
          );
        in
        if arg == "" then human else "${human} ${arg}";
      entry =
        key: bind:
        let
          action = lib.head (lib.attrNames (removeAttrs bind [ "_props" ]));
          value = bind.${action};
          args =
            if lib.isList value then
              value
            else if lib.isAttrs value then
              [ ]
            else
              [ (toString value) ];
          title = bind._props."hotkey-overlay-title" or (describe action (lib.concatStringsSep " " args));
        in
        {
          inherit title;
          key = lib.replaceStrings [ "Mod+" ] [ "Super+" ] key;
          command =
            "niri msg action ${action}" + lib.optionalString (args != [ ]) " -- ${lib.escapeShellArgs args}";
        };
      grouped = lib.groupBy (e: e.command) (lib.mapAttrsToList entry binds);
    in
    lib.sortOn (e: lib.toLower e.line) (
      lib.mapAttrsToList (command: es: {
        inherit command;
        line = "${(lib.head es).title}   ${lib.concatMapStringsSep " / " (e: e.key) es}";
      }) grouped
    );
in
{
  environment.systemPackages = with pkgs; [
    wl-screenrec

    # Screen recording helper scripts
    (writeShellScriptBin "screenrec-region" ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      # Toggle: wenn schon läuft, Recording stoppen
      if pgrep -x wl-screenrec >/dev/null; then
        ${pkgs.libnotify}/bin/notify-send "Screen recording" "Region recording stopped"
        pkill -INT wl-screenrec
        exit 0
      fi

      OUTDIR="''${XDG_VIDEOS_DIR:-''$HOME/Videos}/ScreenRecordings"
      mkdir -p "$OUTDIR"
      FILE="$OUTDIR/region-$(date +'%Y-%m-%d_%H-%M-%S').mp4"

      ${pkgs.libnotify}/bin/notify-send "Screen recording" "Region recording started → $FILE"
      wl-screenrec -g "$(slurp)" -f "$FILE" --low-power=off
    '')

    (writeShellScriptBin "screenrec-full" ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      # Toggle: wenn schon läuft, Recording stoppen
      if pgrep -x wl-screenrec >/dev/null; then
        ${pkgs.libnotify}/bin/notify-send "Screen recording" "Fullscreen recording stopped"
        pkill -INT wl-screenrec
        exit 0
      fi

      OUTDIR="''${XDG_VIDEOS_DIR:-''$HOME/Videos}/ScreenRecordings"
      mkdir -p "$OUTDIR"
      FILE="$OUTDIR/full-$(date +'%Y-%m-%d_%H-%M-%S').mp4"

      MONITOR="$(${pkgs.niri}/bin/niri msg --json focused-output | ${pkgs.python3}/bin/python3 -c 'import json, sys; data = json.load(sys.stdin); print(data.get("name", "") if isinstance(data, dict) else "")')"

      if [[ -z "$MONITOR" ]]; then
        ${pkgs.libnotify}/bin/notify-send -u critical "Screen recording" "Focused output could not be determined"
        exit 1
      fi

      ${pkgs.libnotify}/bin/notify-send "Screen recording" "Fullscreen recording started on $MONITOR → $FILE"
      wl-screenrec -o "$MONITOR" -f "$FILE" --low-power=off
    '')

    rofimoji
    # Screenshots
    slurp
    satty
    adw-gtk3

    glib
    dconf
    gsettings-desktop-schemas

    # Mod+Q (on PATH: the keybinding viewer may not name store paths)
    closeGuard

    # Starts the tray apps of one VM again (after a restart the old ones are
    # gone); detached, vm-run waits for the VM itself
    (writeShellScriptBin "vm-tray" ''
      case "''${1:-}" in
      ${
        lib.concatStrings (
          lib.mapAttrsToList (
            vm: apps:
            "  ${vm})\n"
            + lib.concatMapStrings (
              app:
              "    setsid -f ${
                    lib.escapeShellArgs (
                      [
                        "vm-run"
                        vm
                      ]
                      ++ app
                    )
                  } >/dev/null 2>&1\n"
            ) apps
            + "    ;;\n"
          ) trayApps
        )
      }  *) exit 0 ;;
      esac
    '')

    # vm-autostart [vm…]: opens the login windows that are missing (niri IPC,
    # nox.desktop.login: terminal tabs, further windows). With VM names only
    # theirs (manage-vms after a (re)start, next to vm-tray); tray apps have
    # no window to check, that is vm-tray
    (writeShellScriptBin "vm-autostart" ''
      sel=" $* "
      pick() { [ "$sel" = "  " ] || [[ "$sel" == *" $1 "* ]]; }
      open=$(niri msg --json windows | ${pkgs.jq}/bin/jq -r '.[].app_id // empty')
      has() { grep -qxE "$1" <<<"$open"; }
      terms=()
      for t in ${lib.escapeShellArgs login.terminalTabs}; do
        pick "$t" && terms+=("$t")
      done
      [ ''${#terms[@]} -eq 0 ] || setsid -f ${terminalTabs} "''${terms[@]}" >/dev/null 2>&1
      ${lib.concatMapStrings (w: ''
        if pick ${w.vm} && ! has ${lib.escapeShellArg "\\[${w.vm}\\] (${w.appId})"}; then
          setsid -f vm-run ${w.vm} ${lib.escapeShellArgs w.command} >/dev/null 2>&1
        fi
      '') login.windows}
    '')

    # Keybinding viewer: every bind from `binds` above, searchable in rofi;
    # Enter runs the bind's action through niri
    (writeShellScriptBin "niri-binds" ''
      cmds=(${lib.escapeShellArgs (map (e: e.command) bindEntries)})
      i=$(rofi -dmenu -i -no-custom -p " " -format i \
        -theme /etc/xdg/rofi/config.rasi \
        -theme-str 'window { width: 60em; } listview { lines: 14; }' \
        < ${
          pkgs.writeText "niri-binds.txt" (lib.concatMapStrings (e: e.line + "\n") bindEntries)
        }) || exit 0
      eval "''${cmds[$i]}"
    '')
  ];

  nox = {
    desktop = {
      niri.settings = base.settings // {
        "screenshot-path" = "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png";

        inherit binds;

        _children = [
          {
            workspace = {
              _args = [ "terminal" ];
              "open-on-output" = "DP-2";
            };
          }
          {
            workspace = {
              _args = [ "browser" ];
              "open-on-output" = "DP-2";
            };
          }
          {
            workspace = {
              _args = [ "remote" ];
              "open-on-output" = "DP-1";
            };
          }
          {
            output = {
              _args = [ "eDP-1" ];
              inherit (edp) mode;
              scale = 1.0;
              position._props = {
                x = 0;
                y = 0;
              };
            };
          }
          {
            output = {
              _args = [ "DP-2" ];
              mode = "1920x1080@60.00";
              scale = 1.0;
              position._props = {
                x = edp.width;
                y = 0;
              };
            };
          }
          {
            output = {
              _args = [ "DP-1" ];
              mode = "1920x1080@60.00";
              scale = 1.0;
              position._props = {
                x = edp.width + 1920;
                y = 0;
              };
            };
          }
          {
            "spawn-at-startup"._args = [
              "systemctl"
              "--user"
              "restart"
              "wpaperd.service"
            ];
          }
          # Chat apps and zen at startup again: started with the session, wprsd
          # kept Super as pressed (apps got every key as Super+key); the wprs
          # modifier sync (our wprs fork, modules/wprs-overlay.nix) releases it
          # (xen-migration.md, Known Issues). The tray apps (`trayApps` above)
          # are appended after this list.
          # (login windows: nox.desktop.login, after this list)
          {
            "window-rule"._children = [
              {
                match._props = {
                  "app-id" = "^\\[irc\\] term-irc$";
                };
              }
              { "open-on-workspace" = "remote"; }
              { "default-column-width".proportion = 1.0; }
            ];
          }
          {
            "window-rule"._children = [
              {
                match._props = {
                  "app-id" = "^\\[[a-z0-9-]+\\] (zen|app\\.zen_browser\\.zen)$";
                };
              }
              { "open-on-workspace" = "browser"; }
              { "default-column-width".proportion = 1.0; }
            ];
          }
        ]
        ++ base.windowRules
        # The user's login windows (nox.desktop.login): the terminal tabs open as
        # tabs of one full-width column on the workspace "terminal"
        ++ lib.optionals (login.terminalTabs != [ ]) [
          {
            "window-rule"._children = [
              {
                match._props."app-id" = "^(${
                  lib.concatMapStringsSep "|" (
                    t: if t == "dom0" then "term-dom0" else "\\[${t}\\] term-${t}"
                  ) login.terminalTabs
                })$";
              }
              { "open-on-workspace" = "terminal"; }
              { "default-column-display" = "tabbed"; }
              { "default-column-width".proportion = 1.0; }
            ];
          }
          { "spawn-at-startup"._args = [ "${terminalTabs}" ]; }
        ]
        ++ map (w: {
          "spawn-at-startup"._args = [
            "vm-run"
            w.vm
          ]
          ++ w.command;
        }) login.windows
        ++ map (args: { "spawn-at-startup"._args = args; }) trayCommands
        ++ labelRules;
      };

      # Lock screen; PAM comes from security.pam.services.swaylock (system side).
      # The lock image (nix/nox-branding.nix) shows the logo without its o,
      # the gap on the screen center: swaylock's ring, always visible, is the
      # o as a neon tube (light core, glow-colored edges, the image draws its
      # glow). Radius and thickness match branding/gen.py's LOCK_RING. With an
      # own image (nox.desktop.swaylock.image) the ring is the plain one again:
      # shown while typing, filled, in the theme's colors
      swaylock = {
        enable = true;
        settings =
          with theme;
          let
            own = config.nox.desktop.swaylock.image != null;
            core = colorMath.mix graphics.glow "ffffff" 0.55;
            clear = "00000000";
            inside = if own then rawWithAlpha "bg" opacity.surface else clear;
            line = c: if own then clear else c;
            keyHl = if own then raw.fgActive else graphics.front;
          in
          {
            image = lib.mkDefault (
              if own then config.nox.desktop.swaylock.image else "${branding}/share/nox/lock.png"
            );
            scaling = "fill";
            color = raw.bg;
            font = font.family;
            font-size = font.lockSize;
            indicator-radius = if own then 100 else 70;
            indicator-thickness = if own then 8 else 7;
            indicator-idle-visible = !own;
            show-failed-attempts = true;
            ignore-empty-password = true;

            inside-color = inside;
            inside-clear-color = inside;
            inside-ver-color = inside;
            inside-wrong-color = inside;
            inside-caps-lock-color = inside;

            ring-color = if own then raw.accent else core;
            ring-clear-color = raw.info;
            ring-ver-color = if own then raw.accent2 else graphics.glow2;
            ring-wrong-color = raw.urgent;
            ring-caps-lock-color = raw.warn;

            key-hl-color = keyHl;
            bs-hl-color = raw.urgent;
            caps-lock-key-hl-color = keyHl;
            caps-lock-bs-hl-color = raw.urgent;

            text-color = if own then raw.fg else graphics.front;
            text-clear-color = raw.info;
            text-ver-color = if own then raw.accent2 else graphics.glow2;
            text-wrong-color = raw.urgent;
            text-caps-lock-color = raw.warn;

            line-color = line graphics.glow;
            line-clear-color = line raw.info;
            line-ver-color = line graphics.glow2;
            line-wrong-color = line raw.urgent;
            line-caps-lock-color = line raw.warn;
            separator-color = clear;
          };
      };

      # services.dunst = {
      #   enable = true;
      # };
    };

    desktop = {
      wpaperd = {
        enable = true;
        # Every output (the user's config adds per-output sections)
        settings.any.path = lib.mkDefault "${branding}/share/nox/wallpaper.png";
      };

      # Notifications; colors, sizes and fonts from theme.nix. The control
      # center (waybar bell) is a floating panel under the bar, full monitor
      # height: `control-center-height = -1` (fit to content) stays small in
      # swaync 0.12.6 once notifications of several apps pile up (hp
      # 2026-10-27: 12 apps, 1.5 visible)
      swaync = {
        enable = true;
        settings = {
          positionX = "right";
          positionY = "top";
          layer = "overlay";
          control-center-layer = "top";
          layer-shell = true;
          cssPriority = "application";
          fit-to-screen = true;
          control-center-width = theme.notifications.width;
          control-center-margin-top = theme.gap;
          control-center-margin-bottom = theme.gap;
          control-center-margin-right = theme.gap;
          control-center-margin-left = theme.gap;
          notification-2fa-action = true;
          notification-inline-replies = false;
          notification-icon-size = theme.notifications.iconSize;
          notification-body-image-height = 100;
          notification-body-image-width = 200;
          widgets = [
            "title"
            "dnd"
            "notifications"
          ];
          widget-config = {
            title = {
              text = "Notifications";
              clear-all-button = true;
              button-text = "Clear";
            };
            dnd.text = "Do not disturb";
          };
        };
        # swaync 0.12 loads its packaged CSS first; this overrides its variables
        style = with theme; ''
          :root {
            --cc-bg: alpha(${color.bgDark}, ${toString opacity.popup});
            --noti-border-color: ${color.border};
            --noti-bg-darker: ${color.bgDark};
            --noti-bg-hover: alpha(${color.border}, ${toString opacity.surface});
            --noti-bg-focus: alpha(${color.border}, 0.5);
            --noti-close-bg: ${color.border};
            --noti-close-bg-hover: ${color.accent};
            --text-color: #${palette.fg};
            --text-color-disabled: ${color.muted};
            --bg-selected: ${color.accent};
            --border-radius: ${toString radius}px;
            --notification-icon-size: ${toString notifications.iconSize}px;
            --notification-shadow:
              0 0 0 1px alpha(${color.shadow}, 0.3),
              0 1px 3px 1px alpha(${color.shadow}, 0.7),
              0 2px 6px 2px alpha(${color.shadow}, 0.3);
            --font-size-summary: ${toString notifications.summarySize}px;
            --font-size-body: ${toString notifications.bodySize}px;
          }

          * {
            font-family: "${font.family}";
          }

          .notification-row {
            outline: none;
          }

          .notification {
            margin: 6px 12px;
            padding: 0;
            box-shadow: var(--notification-shadow);
            background: alpha(${color.bg}, ${toString opacity.surface});
            color: ${color.fg};
          }

          .control-center {
            border: 1px solid ${color.border};
            box-shadow: 0 2px 8px alpha(${color.shadow}, ${toString opacity.shadow});
          }

          .control-center .notification {
            box-shadow: none;
          }

          .widget-title > label {
            font-size: ${toString notifications.summarySize}px;
            font-weight: bold;
            color: ${color.accent};
          }

          .widget-title > button,
          .widget-dnd switch {
            background: alpha(${color.border}, ${toString opacity.surface});
            color: var(--text-color);
            border: none;
            border-radius: ${toString radiusInner}px;
          }

          .widget-title > button:hover {
            background: ${color.accent2};
            color: ${color.bgDark};
          }

          .widget-dnd switch:checked {
            background: ${color.accent};
          }

          .widget-dnd switch slider {
            background: #${palette.fg};
            border-radius: ${toString radiusInner}px;
          }
        '';
      };
    };

  };

}

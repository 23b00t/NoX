# The compositor-independent part of dom0's desktop: lock screen, wallpaper,
# notifications, screenshot/recording tools, VM tray apps. The compositor
# module (desktop/niri.nix, nox.desktop.compositor) binds and starts them.
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

  trayApps = import ./tray-apps.nix { inherit lib vmRegistry; };
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

    rofimoji
    # Screenshots
    slurp
    satty
    adw-gtk3

    glib
    dconf
    gsettings-desktop-schemas

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

  ];

  nox.desktop = {
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

    wpaperd = {
      enable = true;
      # Every output (the user's config adds per-output sections)
      settings.any.path = lib.mkDefault "${branding}/share/nox/wallpaper.png";
    };

    # Notifications; colors, sizes and fonts from theme.nix. The control
    # center (waybar bell) is a floating panel under the bar, full monitor
    # height: `control-center-height = -1` (fit to content) stays small in
    # swaync 0.12.6 once notifications of several apps pile up
    # (2026-10-27: 12 apps, 1.5 visible)
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
}

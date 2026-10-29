# niri's base config, shared by dom0 (desktop/niri.nix) and VMs with their
# own niri desktop on a passed-through GPU (vms/modules/niri-vm.nix, godot):
# input, layout and look from the theme, and the keys for windows,
# columns, workspaces and monitors. dom0 adds its launchers, VM tools,
# window rules and autostarts on top.
{
  lib,
  theme,
  keyboard,
}:
{
  settings = {
    "prefer-no-csd" = { };
    "hotkey-overlay"."skip-at-startup" = { };

    # nox.theme.cursor. niri sets XCURSOR_THEME/SIZE for what it spawns
    # (wprsc too, which draws the VMs' shape cursors), "default" without this
    cursor = {
      "xcursor-theme" = theme.cursor.name;
      "xcursor-size" = theme.cursor.size;
    };

    # No hot corner (top left of each monitor opened the overview)
    gestures."hot-corners".off = { };

    input = {
      "mod-key" = "Super";

      keyboard = {
        # nox.desktop.keyboard, unset fields left out
        xkb = lib.filterAttrs (_: v: v != "") keyboard;

        numlock = { };
      };

      "focus-follows-mouse" = { };

      touchpad = {
        tap = { };
        "natural-scroll" = { };
      };
    };

    layout = {
      gaps = theme.gap;
      "center-focused-column" = "on-overflow";
      "always-center-single-column" = { };

      "preset-column-widths"._children = [
        { proportion = 0.33333; }
        { proportion = 0.5; }
        { proportion = 0.66667; }
      ];

      # New windows open full width (as after Mod+M); Mod+Alt+R cycles the
      # presets above
      "default-column-width".proportion = 1.0;

      # Tabbed columns (VM terminals): one segment per tab; inactive tabs
      # in the accent color, the focused one stronger (muted was too faint)
      "tab-indicator" = {
        "hide-when-single-tab" = { };
        "gaps-between-tabs" = 4;
        width = 6;
        "corner-radius" = 3;
        "active-color" = theme.color.accentStrong;
        "inactive-color" = theme.color.accent;
      };

      # Border in the trust label color (default `unknown` here; dom0 and the
      # VMs in `labelRules`): dimmed when unfocused, full plus a focus ring of
      # the same color when focused
      "focus-ring" = {
        width = 2;
        "active-color" = theme.label.unknown;
        "inactive-color" = theme.labelWithAlpha "unknown" theme.opacity.inactiveRing;
        "urgent-color" = theme.color.urgent;
      };

      border = {
        on = { };
        width = 3;
        "active-color" = theme.label.unknown;
        "inactive-color" = theme.labelWithAlpha "unknown" theme.opacity.inactiveBorder;
        "urgent-color" = theme.color.urgent;
      };

      shadow = {
        on = { };
        softness = 30;
        spread = 5;
        offset._props = {
          x = 0;
          y = 5;
        };
        color = theme.withAlpha "shadow" theme.opacity.shadow;
      };
    };
  };

  # Generic window rules (rounded corners, translucency, blur), after the
  # caller's own rules
  windowRules = [
    {
      "window-rule"._children = [
        { "geometry-corner-radius" = theme.radius; }
        { "clip-to-geometry" = true; }
        { "draw-border-with-background" = false; }
        # An app that asks to start maximized (LibreOffice remembers it) gets a
        # maximized column with its label border, not the edge-to-edge
        # maximize, which draws no border (xmg 2026-10-27)
        { "open-maximized-to-edges" = false; }
        { opacity = 0.85; }
        {
          "background-effect" = {
            blur = true;
            saturation = 2.0;
            noise = 0.03;
          };
        }
      ];
    }
    {
      "window-rule"._children = [
        {
          match._props = {
            "is-focused" = true;
          };
        }
        { opacity = 0.9; }
      ];
    }
  ];

  # Windows, columns, workspaces, monitors, sizes; leaving the session
  binds = {
    "Mod+O" = {
      _props.repeat = false;
      "toggle-overview" = { };
    };

    "Mod+Left"."focus-column-left" = { };
    "Mod+Down"."focus-window-down" = { };
    "Mod+Up"."focus-window-up" = { };
    "Mod+Right"."focus-column-right" = { };

    "Mod+Ctrl+Home"."move-column-to-first" = { };
    "Mod+Ctrl+End"."move-column-to-last" = { };

    # Monitors: Mod+H/J/K/L focus, with Shift the column (and its tabs) moves
    "Mod+H"."focus-monitor-left" = { };
    "Mod+J"."focus-monitor-down" = { };
    "Mod+K"."focus-monitor-up" = { };
    "Mod+L"."focus-monitor-right" = { };
    "Mod+Shift+H"."move-column-to-monitor-left" = { };
    "Mod+Shift+J"."move-column-to-monitor-down" = { };
    "Mod+Shift+K"."move-column-to-monitor-up" = { };
    "Mod+Shift+L"."move-column-to-monitor-right" = { };

    # Mod+Alt moves the window (left/right: into the neighbour column or out
    # of it as its own column), Mod+Ctrl the whole column
    "Mod+Alt+Left"."consume-or-expel-window-left" = { };
    "Mod+Alt+Down"."move-window-down" = { };
    "Mod+Alt+Up"."move-window-up" = { };
    "Mod+Alt+Right"."consume-or-expel-window-right" = { };
    "Mod+Ctrl+Left"."move-column-left" = { };
    "Mod+Ctrl+Right"."move-column-right" = { };

    "Mod+U"."focus-workspace-down" = { };
    "Mod+I"."focus-workspace-up" = { };
    "Mod+Shift+U"."move-column-to-workspace-down" = { };
    "Mod+Shift+I"."move-column-to-workspace-up" = { };

    # Tabs of the focused column (VM terminals) by number; workspaces are
    # reached with Mod+I/U, Mod+Ctrl+<n> still moves columns
    "Mod+1"."focus-window-in-column" = 1;
    "Mod+2"."focus-window-in-column" = 2;
    "Mod+3"."focus-window-in-column" = 3;
    "Mod+4"."focus-window-in-column" = 4;
    "Mod+5"."focus-window-in-column" = 5;
    "Mod+6"."focus-window-in-column" = 6;
    "Mod+7"."focus-window-in-column" = 7;
    "Mod+8"."focus-window-in-column" = 8;
    "Mod+9"."focus-window-in-column" = 9;
    "Mod+0"."focus-window-bottom" = { };

    "Mod+Ctrl+1"."move-column-to-workspace" = 1;
    "Mod+Ctrl+2"."move-column-to-workspace" = 2;
    "Mod+Ctrl+3"."move-column-to-workspace" = 3;
    "Mod+Ctrl+4"."move-column-to-workspace" = 4;
    "Mod+Ctrl+5"."move-column-to-workspace" = 5;
    "Mod+Ctrl+6"."move-column-to-workspace" = 6;
    "Mod+Ctrl+7"."move-column-to-workspace" = 7;
    "Mod+Ctrl+8"."move-column-to-workspace" = 8;
    "Mod+Ctrl+9"."move-column-to-workspace" = 9;
    "Mod+Ctrl+0"."move-column-to-workspace" = 10;

    "Mod+BracketLeft"."consume-or-expel-window-left" = { };
    "Mod+BracketRight"."consume-or-expel-window-right" = { };

    "Mod+Shift+Minus"."set-window-height" = "-10%";
    "Mod+Shift+Equal"."set-window-height" = "+10%";

    "Mod+Minus"."set-column-width" = "-10%";
    "Mod+Equal"."set-column-width" = "+10%";
    "Mod+Alt+R"."switch-preset-column-width" = { };
    "Mod+Alt+Shift+R"."switch-preset-column-width-back" = { };
    "Mod+Ctrl+Shift+R"."switch-preset-window-height" = { };
    "Mod+Ctrl+R"."reset-window-height" = { };

    "Mod+V"."toggle-window-floating" = { };
    "Mod+Shift+V"."switch-focus-between-floating-and-tiling" = { };
    "Mod+W"."toggle-column-tabbed-display" = { };

    "Mod+F"."fullscreen-window" = { };
    "Mod+Shift+F"."maximize-column" = { };
    "Mod+M"."maximize-column" = { };
    "Mod+Ctrl+F"."expand-column-to-available-width" = { };
    "Mod+C"."center-column" = { };
    "Mod+Ctrl+C"."center-visible-columns" = { };

    "Mod+Escape" = {
      _props."allow-inhibiting" = false;
      "toggle-keyboard-shortcuts-inhibit" = { };
    };

    "Mod+Shift+E".quit = { };
    "Ctrl+Alt+Delete".quit = { };
  };
}

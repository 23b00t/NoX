# Hyprland instead of niri: a starting point for docs/compositor.md, imported
# into a dom0 config (`imports = [ "${inputs.nox}/docs/examples/hyprland.nix" ];`
# or a copy). Hyprland ≥ 0.57 reads Lua (/etc/xdg/hypr/hyprland.lua). The
# flake check compositor-none evaluates it with a real dom0 and runs
# `Hyprland --verify-config` on the generated file.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  d = config.nox.desktop;
  jq = "${pkgs.jq}/bin/jq";
  hex = lib.removePrefix "#";
  # Lua long string: app id regexes contain backslashes
  lua = s: "[==[${s}]==]";
in
{
  nox.desktop.compositor = null;

  # Session: UWSM starts graphical-session.target, which waybar, swaync and
  # wpaperd need
  programs.hyprland = {
    enable = true;
    withUWSM = true;
  };
  services.displayManager.defaultSession = "hyprland-uwsm";

  nox.desktop.waybar.workspaces.module = "hyprland/workspaces";

  # The compositor hooks behind nox-wm (window id = Hyprland's address)
  nox.desktop.wm = {
    focusedWindow = ''
      hyprctl -j activewindow | ${jq} -r 'select(.address != null) | "\(.address)\t\(.pid // "")\t\(.class // "")"'
    '';
    windows = ''
      hyprctl -j clients | ${jq} -r '.[].class // empty'
    '';
    closeWindow = ''
      hyprctl dispatch "hl.dsp.window.close({ window = \"address:$1\" })"
    '';
    focusedOutput = ''
      hyprctl -j monitors | ${jq} -r '.[] | select(.focused) | .name'
    '';
    # The login terminals as plain windows (no tabs)
    openTerminals = ''
      for t in "$@"; do
        if [ "$t" = dom0 ]; then
          setsid -f foot -a term-dom0 ${lib.escapeShellArgs d.login.dom0Command}
        else
          setsid -f vm-run "$t" foot -a "term-$t" zellij --layout tabs attach -c
        fi
      done
    '';
  };

  environment.etc."xdg/hypr/hyprland.lua".text = ''
    hl.config({
      input = {
        kb_layout = "${d.keyboard.layout}",
        kb_variant = "${d.keyboard.variant}",
        kb_options = "${d.keyboard.options}",
      },
    })

    -- Login windows (nox.desktop.login); tray apps: `vm-tray <vm>` per VM
    -- with tray apps
    hl.on("hyprland.start", function()
      hl.exec_cmd("vm-autostart")
    end)

    -- NoX's commands (docs/compositor.md, keybinds)
    local mod = "SUPER"
    hl.bind(mod .. " + T", hl.dsp.exec_cmd("foot"))
    hl.bind(mod .. " + A", hl.dsp.exec_cmd("pkill rofi || rofi -modi drun,filebrowser,window,run -show drun -theme /etc/xdg/rofi/config.rasi"))
    hl.bind(mod .. " + Q", hl.dsp.exec_cmd("close-guard"))
    hl.bind(mod .. " + ALT + L", hl.dsp.exec_cmd("swaylock -C /etc/xdg/swaylock/config"))
    hl.bind(mod .. " + ALT + C", hl.dsp.exec_cmd("vm-clip copy"))
    hl.bind(mod .. " + ALT + V", hl.dsp.exec_cmd("vm-clip paste"))
    hl.bind(mod .. " + E", hl.dsp.exec_cmd("explorer"))
    hl.bind(mod .. " + R", hl.dsp.exec_cmd("screenrec-region"))
    hl.bind(mod .. " + SHIFT + R", hl.dsp.exec_cmd("screenrec-full"))
    hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
    hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { locked = true, repeating = true })
    hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true })
    hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"), { locked = true, repeating = true })
    hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"), { locked = true, repeating = true })

    -- Trust label colors (nox.desktop.labels): active and inactive border
    ${lib.concatMapStrings (l: ''
      hl.window_rule({
        name = "nox-label-${l.label}",
        match = { class = ${lua l.appId} },
        border_color = "rgb(${hex l.active}) rgba(${hex l.inactiveBorder})",
      })
    '') d.labels}'';
}

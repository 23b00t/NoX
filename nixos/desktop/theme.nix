# The desktop theme: colors, transparency, radii and fonts for niri, waybar,
# rofi, swaync, swaylock, foot and GTK/Qt, plus the colors of the NoX logo
# and wallpaper (`graphics`, nix/nox-branding.nix). The colors come from one
# data file per theme in ./themes; nox.desktop.theme picks it (`name`) and
# overrides single roles (`colors`, `graphics`).
# Usage: `theme = import ./theme.nix { inherit lib; inherit (config.nox.desktop) theme; };`
{
  lib,
  # nox.desktop.theme (only name, colors and graphics are read here)
  theme ? { },
}:
let
  name = theme.name or "nox";
  data = import (./themes + "/${name}.nix");

  # 0.0-1.0 -> two hex digits
  alphaHex =
    a: lib.toLower (lib.fixedWidthString 2 "0" (lib.toHexString (builtins.floor (a * 255 + 0.5))));
in
rec {
  inherit name;
  inherit (data) palette icons;

  # Semantic roles, hex without '#' (swaylock wants it that way)
  raw = data.raw // theme.colors or { };

  # Logo and wallpaper roles, hex without '#'; bg and bgDark are the
  # desktop's (branding/gen.py's palettes are the reference)
  graphics = {
    inherit (raw) bg bgDark;
  }
  // data.graphics raw
  // theme.graphics or { };

  # Trust labels (vms/registry.nix `label`): window border and focus ring per
  # VM in niri, hex without '#'; dom0 = titles not starting with "[" (VM
  # windows always carry wprsc's "[<vm>] " prefix), unknown = everything else
  # (e.g. a VM window without a title): never dom0's color
  labelRaw = data.labels;
  label = lib.mapAttrs (_: c: "#${c}") labelRaw;
  labelWithAlpha = l: a: "${label.${l}}${alphaHex a}";

  # Same roles as "#rrggbb" for CSS, KDL and rasi
  color = lib.mapAttrs (_: c: "#${c}") raw;

  # Transparency levels
  opacity = {
    surface = 0.8; # waybar modules, notifications
    popup = 0.9; # swaync control center
    launcher = 0.97; # all rofi menus; less see-through than popup
    bar = 0.1; # waybar background (on black)
    shadow = 0.44;
    inactiveRing = 0.8;
    inactiveBorder = 0.5; # label border of unfocused windows
  };

  # "#rrggbbaa" / "rrggbbaa" from a role name and an opacity
  withAlpha = role: a: "${color.${role}}${alphaHex a}";
  rawWithAlpha = role: a: "${raw.${role}}${alphaHex a}";

  # Corner radii in px; `radius` matches niri's geometry-corner-radius
  radius = 10;
  radiusInner = 6;

  # Gap between windows (niri) and around floating panels (swaync)
  gap = 10;

  font = {
    family = "FiraCode Nerd Font";
    barSize = 14; # px, waybar
    launcherSize = 11; # pt, rofi
    lockSize = 18; # px, swaylock: "Verifying" fits inside the ring (radius 70)
  };

  # swaync: popups and the control center (waybar bell)
  notifications = {
    width = 420; # px, control center
    iconSize = 64;
    summarySize = 16; # px
    bodySize = 15; # px
  };

  # foot (foot.ini sections); dom0 (desktop/foot.nix) and the VMs over wprs
  # (vms/modules/wprs.nix)
  foot = {
    # Medium: Regular looked thin in foot next to kitty (kitty thickens
    # glyphs, foot does not); bold set explicitly, foot derives it otherwise.
    # Fallback for symbols FiraCode lacks (desktop/symbols-font.nix) and
    # emoji (termusic's highlight symbols)
    main = {
      font = "${font.family}:style=Medium:size=11.5, Noto Sans Symbols 2:size=11.5, FreeMono:size=11.5, Noto Color Emoji:size=11.5";
      font-bold = "${font.family}:style=Bold:size=11.5, Noto Sans Symbols 2:size=11.5, FreeMono:size=11.5, Noto Color Emoji:size=11.5";
    };
    scrollback.lines = 2000;
    mouse.hide-when-typing = "yes";
    colors-dark = data.terminal;
  };
}

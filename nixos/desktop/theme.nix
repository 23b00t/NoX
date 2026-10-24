# Central desktop theme (Tokyo Night): colors, transparency, radii and fonts
# for niri, waybar, rofi, swaync and swaylock.
# Usage: `theme = import ./theme.nix { inherit lib; };`
{ lib }:
let
  # Tokyo Night palette, hex without '#'
  palette = {
    bg = "24283b"; # storm background
    bgDark = "1a1b26"; # night background
    fg = "c0caf5";
    comment = "565f89";
    border = "3b4261";
    blue = "7aa2f7";
    cyan = "7dcfff";
    teal = "b4f9f8";
    magenta = "bb9af7";
    lavender = "d1bfff";
    pink = "ff79c6";
    red = "f7768e";
    yellow = "e0af68";
    green = "9ece6a";
    black = "000000";
  };

  # 0.0-1.0 -> two hex digits
  alphaHex =
    a: lib.toLower (lib.fixedWidthString 2 "0" (lib.toHexString (builtins.floor (a * 255 + 0.5))));
in
rec {
  inherit palette;

  # Semantic roles, hex without '#' (swaylock wants it that way)
  raw = {
    inherit (palette) bg bgDark border;
    fg = palette.blue; # text everywhere, as waybar always had it
    fgActive = palette.teal; # text on accent backgrounds
    accent = palette.magenta; # focus ring, active workspace, selection
    accentStrong = palette.pink; # active tab indicator, stronger than accent
    accent2 = palette.blue; # second gradient stop, selection background
    muted = palette.comment;
    urgent = palette.red;
    warn = palette.yellow;
    ok = palette.green;
    info = palette.cyan;
    shadow = palette.black;
  };

  # Trust labels (vms/registry.nix `label`): window border and focus ring per
  # VM in niri, hex without '#'; dom0 = titles not starting with "[" (VM
  # windows always carry wprsc's "[<vm>] " prefix), unknown = everything else
  # (e.g. a VM window without a title): never dom0's color
  labelRaw = {
    dom0 = palette.fg;
    unknown = palette.comment;
    sys = palette.red;
    dev = palette.magenta;
    personal = palette.green;
    untrusted = palette.yellow;
    vault = palette.cyan;
    anon = palette.blue;
  };
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
    lockSize = 24; # px, swaylock
  };

  # swaync: popups and the control center (waybar bell)
  notifications = {
    width = 420; # px, control center
    iconSize = 64;
    summarySize = 16; # px
    bodySize = 15; # px
  };

  # Icon theme for GTK/Qt and rofi; package: tela-circle-icon-theme with this variant
  icons = {
    name = "Tela-circle-dracula";
    variant = "dracula";
  };

  # foot (foot.ini sections), font and colors as kitty had them; dom0
  # (home/home.nix) and the VMs over wprs (vms/modules/wprs.nix)
  foot = {
    # Medium: Regular looked thin in foot next to kitty (kitty thickens
    # glyphs, foot does not); bold set explicitly, foot derives it otherwise.
    # Fallback for symbols FiraCode lacks (home/desktop/symbols-font.nix) and
    # emoji (termusic's highlight symbols)
    main = {
      font = "${font.family}:style=Medium:size=11.5, Noto Sans Symbols 2:size=11.5, FreeMono:size=11.5, Noto Color Emoji:size=11.5";
      font-bold = "${font.family}:style=Bold:size=11.5, Noto Sans Symbols 2:size=11.5, FreeMono:size=11.5, Noto Color Emoji:size=11.5";
    };
    scrollback.lines = 2000;
    mouse.hide-when-typing = "yes";
    colors-dark = {
      background = "1e1f28";
      foreground = "f8f8f2";
      selection-background = "44475a";
      selection-foreground = "1e1f28";
      regular0 = "000000";
      regular1 = "ff5555";
      regular2 = "50fa7b";
      regular3 = "f0fa8b";
      regular4 = "bd92f8";
      regular5 = "ff78c5";
      regular6 = "8ae9fc";
      regular7 = "bbbbbb";
      bright0 = "545454";
      bright1 = "ff5454";
      bright2 = "50fa7b";
      bright3 = "f0fa8b";
      bright4 = "bd92f8";
      bright5 = "ff78c5";
      bright6 = "8ae9fc";
      bright7 = "ffffff";
    };
  };
}

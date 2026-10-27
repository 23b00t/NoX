# The desktop theme: colors, transparency, radii and fonts for niri,
# waybar, rofi, swaync, swaylock, foot and GTK/Qt, one file per theme in
# ./themes (`nox.desktop.theme` picks it; NoX ships tokyo-night).
# Usage: `theme = import ./theme.nix { inherit lib; name = config.nox.desktop.theme; };`
{
  lib,
  name ? "tokyo-night",
}:
import (./themes + "/${name}.nix") { inherit lib; }

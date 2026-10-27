# NoX logo, icon, wallpaper and lock screen image in the theme's colors:
# fills branding/templates (made by branding/gen.py) with the colors and
# renders them with resvg. No Python at build time.
# Output: share/nox/{wallpaper.png, lock.png, logo*.svg, icon.svg, icon-<n>.png}
{
  lib,
  runCommand,
  writeText,
  resvg,
  # Graphic roles, hex without '#': bgDark bg surface front edgeA edgeB glow
  # glow2 (desktop/theme.nix `graphics`)
  colors,
  # { flavor = "organic" | "neon" | "glitch"; shade = "normal" | "dark";
  #   decor = subset of [ "moon" "stars" ]; }
  wallpaper ? { },
  lock ? wallpaper,
  resolution ? "3840x2160",
}:
let
  color = import ../nixos/lib/color.nix { inherit lib; };
  templates = ../branding/templates;
  derived = builtins.fromJSON (builtins.readFile (templates + "/colors.json"));

  roles = [
    "bgDark"
    "bg"
    "surface"
    "front"
    "edgeA"
    "edgeB"
    "glow"
    "glow2"
  ];
  missing = lib.filter (r: !(colors ? ${r})) roles;

  withDefaults =
    v:
    {
      flavor = "organic";
      shade = "dark";
      decor = [
        "moon"
        "stars"
      ];
    }
    // v;

  # The dark shade pulls the background colors 45 % towards black
  shaded =
    shade:
    if shade == "dark" then
      colors // lib.genAttrs [ "bgDark" "bg" "surface" ] (k: color.mix colors.${k} "000000" 0.45)
    else
      colors;

  # Roles plus every derived color of colors.json (entries refer to roles,
  # hex literals or other entries; resolved lazily, so order doesn't matter)
  resolve =
    shade:
    let
      get = k: all.${k} or k;
      all = shaded shade // lib.mapAttrs (_: d: color.mix (get d.a) (get d.b) d.t) derived;
    in
    all;

  fill =
    shade: template:
    let
      c = resolve shade;
      svg = builtins.replaceStrings (map (n: "@${n}@") (lib.attrNames c)) (lib.attrValues c) (
        builtins.readFile (templates + "/${template}")
      );
    in
    assert lib.assertMsg (!lib.hasInfix "@" svg) "nox-branding: unfilled color in ${template}";
    writeText template svg;

  decorName =
    decor:
    let
      moon = lib.elem "moon" decor;
      stars = lib.elem "stars" decor;
    in
    if moon && stars then
      "moon-stars"
    else if moon then
      "moon"
    else if stars then
      "stars"
    else
      "plain";

  # kind: "wallpaper", or "lock" (the logo without its o, the gap on the
  # screen center: swaylock's ring is the o, see desktop/niri.nix)
  imageSvg =
    kind: v:
    let
      o = withDefaults v;
    in
    fill o.shade "${kind}-${o.flavor}-${decorName o.decor}-${resolution}.svg";

  logos = [
    "logo"
    "logo-flat"
    "logo-mono"
    "logo-neon"
    "logo-glitch"
    "icon"
  ];
  iconSizes = [
    16
    24
    32
    48
    64
    128
    256
  ];
in
assert lib.assertMsg (missing == [ ]) "nox-branding: colors lack ${toString missing}";
runCommand "nox-branding" { nativeBuildInputs = [ resvg ]; } ''
  d=$out/share/nox
  mkdir -p $d
  resvg ${imageSvg "wallpaper" wallpaper} $d/wallpaper.png
  resvg ${imageSvg "lock" lock} $d/lock.png
  ${lib.concatMapStrings (l: ''
    cp ${fill "normal" "${l}.svg"} $d/${l}.svg
  '') logos}
  ${lib.concatMapStrings (n: ''
    resvg -w ${toString n} -h ${toString n} $d/icon.svg $d/icon-${toString n}.png
  '') iconSizes}
''

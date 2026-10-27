# Type of nox.desktop.theme (dom0) and services.niri-vm.theme (VMs with their
# own niri): which theme (desktop/themes/<name>.nix), single color overrides,
# and the look of the generated wallpaper and lock screen
# (nix/nox-branding.nix, templates from branding/gen.py).
{ lib }:
let
  inherit (lib) mkOption types;

  # flavor, shade and decor; with a parent (the lock screen) they default to
  # the parent's values, except those set in `own`
  look =
    parent: own:
    let
      option =
        name: default: type: description:
        let
          inherits = parent != null && !(own ? ${name});
        in
        mkOption {
          inherit type description;
          default = own.${name} or (if parent == null then default else parent.${name});
        }
        // lib.optionalAttrs inherits {
          defaultText = lib.literalExpression "theme.${name}";
        };
    in
    {
      flavor = option "flavor" "organic" (types.enum [
        "organic"
        "neon"
        "glitch"
      ]) "Logo style: organic (glossy 3D), neon (glowing tubes) or glitch.";
      shade =
        option "shade" "dark"
          (types.enum [
            "normal"
            "dark"
          ])
          "Background of the graphics: the theme's colors (normal) or pulled 45 % towards black (dark). The desktop colors stay as they are.";
      decor =
        option "decor"
          [
            "moon"
            "stars"
          ]
          (types.listOf (
            types.enum [
              "moon"
              "stars"
            ]
          ))
          "Sky behind the logo: a crescent moon, stars, both or none.";
    };
in
types.submodule (
  { config, ... }:
  {
    options = look null { } // {
      name = mkOption {
        type = types.enum (map (lib.removeSuffix ".nix") (builtins.attrNames (builtins.readDir ./themes)));
        default = "nox";
        description = "Theme (desktop/themes/<name>.nix): colors for niri, waybar, rofi, swaync, swaylock, foot, GTK/Qt, logo and wallpaper; icon theme.";
      };
      colors = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          accent = "ff9e64";
        };
        description = "Overrides of the theme's semantic roles (hex without '#'): bg, bgDark, border, fg, fgActive, accent, accentStrong, accent2, muted, urgent, warn, ok, info, shadow. Logo and wallpaper colors follow them where the theme derives them from roles.";
      };
      graphics = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = {
          glow = "ff9e64";
        };
        description = "Overrides of the logo and wallpaper colors (hex without '#'): front, surface, edgeA, edgeB, glow, glow2 (bg and bgDark follow `colors`).";
      };
      resolution = mkOption {
        type = types.enum [
          "3840x2160"
          "2560x1600"
        ];
        default = "3840x2160";
        description = "Size of the rendered wallpaper and lock screen image (scaled to each output).";
      };
      lock = mkOption {
        # neon: swaylock's ring (desktop/niri.nix) is the logo's o, a tube
        type = types.submodule { options = look config { flavor = "neon"; }; };
        default = { };
        description = "Look of the lock screen image (the logo without its o: swaylock's ring takes its place). flavor defaults to neon, shade and decor to the wallpaper's.";
      };
    };
  }
)

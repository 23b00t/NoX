# Eval check for nox.desktop.compositor = null: a dom0 with the Hyprland
# example (docs/examples/hyprland.nix) instead of niri evaluates to a
# system, and Hyprland accepts the generated config. Builds nothing of the
# system itself (its drvPath only). `dom0`: a nixosConfiguration of a NoX
# dom0, e.g. from the user's flake checks.
{ pkgs, dom0 }:
let
  inherit (dom0.extendModules { modules = [ ../../docs/examples/hyprland.nix ]; }) config;
in
pkgs.runCommand "compositor-none"
  {
    toplevel = builtins.unsafeDiscardStringContext config.system.build.toplevel.drvPath;
    hyprlandConfig = config.environment.etc."xdg/hypr/hyprland.lua".source;
    nativeBuildInputs = [ config.programs.hyprland.package ];
  }
  ''
    export HOME=$TMPDIR XDG_RUNTIME_DIR=$TMPDIR
    Hyprland --verify-config --config "$hyprlandConfig"
    echo "$toplevel" >$out
  ''

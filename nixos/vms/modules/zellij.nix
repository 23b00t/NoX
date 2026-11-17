{
  config,
  lib,
  pkgs,
  vmRegistry,
  ...
}:

# zellij in the VM. NoX brings no config of its own: without `configDir`
# zellij runs with its defaults; the user's config dir (config.kdl, optional
# layouts/tabs.swap.kdl and plugins/) comes from the user's config, wasm
# plugins built with Nix from `plugins`. The tab layout `tabs` defaults to a
# neutral one (home tab, compact bar). The theme `nox` (themes/nox.kdl)
# follows the fleet's nox.theme: `theme "nox"` in config.kdl
let
  cfg = config.services.zellij-env;
  # `zellij terminal` (the built-in GUI terminal, winit + EGL) dlopens
  # wayland, xkbcommon, EGL and fontconfig by soname, but nixpkgs' zellij has
  # none of them in its RUNPATH ("The wayland library could not be loaded").
  # Added the way nixpkgs does it for alacritty. Drop this once nixpkgs'
  # zellij ships these libs. `zellij terminal` additionally needs an EGL
  # driver in the VM, i.e. registry `mesa = true`.
  zellij = pkgs.zellij-unwrapped.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      patchelf --add-rpath "${
        lib.makeLibraryPath [
          pkgs.fontconfig
          pkgs.libglvnd
          pkgs.libxkbcommon
          pkgs.wayland
        ]
      }" $out/bin/zellij
    '';
  });
  dir = cfg.configDir;
  has = sub: dir != null && builtins.pathExists (dir + "/${sub}");

  # /etc/zellij/plugins: the files of configDir/plugins plus the built
  # plugins (`plugins`), one link per file
  pluginFiles =
    lib.optionalAttrs (has "plugins") (
      lib.mapAttrs (name: _: dir + "/plugins/${name}") (builtins.readDir (dir + "/plugins"))
    )
    // lib.mapAttrs' (name: wasm: lib.nameValuePair "${name}.wasm" wasm) cfg.plugins;

  theme = import ../../desktop/theme.nix {
    inherit lib;
    inherit (vmRegistry) theme;
  };
  term = theme.foot.colors-dark;
  # zellij's legacy theme format: green is its active frame and tab, orange
  # its key hints; they take the desktop's accents, the rest the terminal
  # colors
  themeKdl = ''
    themes {
        nox {
            fg "#${theme.raw.fg}"
            bg "#${theme.raw.border}"
            black "#${term.regular0}"
            red "#${term.regular1}"
            green "#${theme.raw.accent}"
            yellow "#${term.regular3}"
            blue "#${term.regular4}"
            magenta "#${term.regular5}"
            cyan "#${term.regular6}"
            white "#${term.regular7}"
            orange "#${theme.raw.accentStrong}"
        }
    }
  '';
in
{
  options.services.zellij-env = {
    enable = lib.mkEnableOption "Zellij terminal multiplexer setup";

    user = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "Target user for Zellij config and tmpfiles rules";
    };

    configDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "The user's zellij config directory (config.kdl, optional layouts/tabs.swap.kdl and plugins/); null: zellij's defaults.";
    };

    plugins = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = lib.literalExpression ''{ my-plugin = "''${pkgs.my-plugin}/bin/my-plugin.wasm"; }'';
      description = "Wasm plugins built with Nix, as /etc/zellij/plugins/<name>.wasm (in config.kdl: \"file:/etc/zellij/plugins/<name>.wasm\").";
    };

    tabsKdlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = ./zellij/layouts/tabs.kdl;
      description = "Optional override for zellij/layouts/tabs.kdl file.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment = {
      systemPackages = [ zellij ];
      etc = {
        "zellij/config.kdl" = lib.mkIf (dir != null) { source = dir + "/config.kdl"; };
        "zellij/layouts/tabs.swap.kdl" = lib.mkIf (has "layouts/tabs.swap.kdl") {
          source = dir + "/layouts/tabs.swap.kdl";
        };
        "zellij/layouts/tabs.kdl" = lib.mkIf (cfg.tabsKdlFile != null) { source = cfg.tabsKdlFile; };
        "zellij/themes/nox.kdl".text = themeKdl;
      }
      // lib.mapAttrs' (
        name: source: lib.nameValuePair "zellij/plugins/${name}" { inherit source; }
      ) pluginFiles;
    };

    systemd.tmpfiles.rules = [
      "d /home/${cfg.user}/.config/zellij 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/.config/zellij/layouts 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/.config/zellij/themes 0755 ${cfg.user} users -"
      "L+ /home/${cfg.user}/.config/zellij/themes/nox.kdl - - - - /etc/zellij/themes/nox.kdl"
    ]
    ++ lib.optional (
      dir != null
    ) "L+ /home/${cfg.user}/.config/zellij/config.kdl - - - - /etc/zellij/config.kdl"
    ++ lib.optional (
      pluginFiles != { }
    ) "L+ /home/${cfg.user}/.config/zellij/plugins - - - - /etc/zellij/plugins"
    ++ lib.optional (has "layouts/tabs.swap.kdl") "L+ /home/${cfg.user}/.config/zellij/layouts/tabs.swap.kdl - - - - /etc/zellij/layouts/tabs.swap.kdl"
    ++ lib.optional (
      cfg.tabsKdlFile != null
    ) "L+ /home/${cfg.user}/.config/zellij/layouts/tabs.kdl - - - - ${cfg.tabsKdlFile}";
  };
}

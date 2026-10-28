{
  config,
  lib,
  pkgs,
  vmRegistry,
  ...
}:

# zellij in the VM. NoX brings no config of its own: without `configDir`
# zellij runs with its defaults; the user's config dir (config.kdl, optional
# layouts/tabs.swap.kdl and plugins/) comes from the user's config. The tab
# layout `tabs` defaults to a neutral one (home tab, compact bar). The theme
# `nox` (themes/nox.kdl) follows the fleet's nox.theme: `theme "nox"` in
# config.kdl
let
  cfg = config.services.zellij-env;
  dir = cfg.configDir;
  has = sub: dir != null && builtins.pathExists (dir + "/${sub}");

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

    tabsKdlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = ./zellij/layouts/tabs.kdl;
      description = "Optional override for zellij/layouts/tabs.kdl file.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment = {
      systemPackages = [ pkgs.zellij ];
      etc = {
        "zellij/config.kdl" = lib.mkIf (dir != null) { source = dir + "/config.kdl"; };
        "zellij/plugins" = lib.mkIf (has "plugins") { source = dir + "/plugins"; };
        "zellij/layouts/tabs.swap.kdl" = lib.mkIf (has "layouts/tabs.swap.kdl") {
          source = dir + "/layouts/tabs.swap.kdl";
        };
        "zellij/layouts/tabs.kdl" = lib.mkIf (cfg.tabsKdlFile != null) { source = cfg.tabsKdlFile; };
        "zellij/themes/nox.kdl".text = themeKdl;
      };
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
    ++ lib.optional (has "plugins") "L+ /home/${cfg.user}/.config/zellij/plugins - - - - /etc/zellij/plugins"
    ++ lib.optional (has "layouts/tabs.swap.kdl") "L+ /home/${cfg.user}/.config/zellij/layouts/tabs.swap.kdl - - - - /etc/zellij/layouts/tabs.swap.kdl"
    ++ lib.optional (
      cfg.tabsKdlFile != null
    ) "L+ /home/${cfg.user}/.config/zellij/layouts/tabs.kdl - - - - ${cfg.tabsKdlFile}";
  };
}

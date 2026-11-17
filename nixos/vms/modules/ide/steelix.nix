# ide editor: steelix, Helix with Steel (Scheme) plugins (command `hx`,
# replaces a plain helix). Its config (config.toml, init.scm, helix.scm)
# can be pulled from a git remote into ~/.config/helix.
#
# smith.hx (plugin manager) comes from Nix, no `forge pkg install` needed:
# Steel resolves a require in $STEEL_HOME/cogs first, then in
# STEEL_SEARCH_PATHS, where a pinned smith.hx lies. smith installs the
# plugins itself with forge (pkgs.steel). `:smith-self-update` would put a
# forge copy into $STEEL_HOME/cogs, which then wins over this one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ide = config.services.ide;
  cfg = ide.steelix;

  smith = pkgs.fetchFromGitHub {
    owner = "kn66";
    repo = "smith.hx";
    rev = "a5ddb240aad6999b7c095ceb352b90a12167034e";
    hash = "sha256-ccLoMI9E3v8BLPLKtrjg1c0UK5VgdBH6L/d59HaQ4yg=";
  };
  # (require "smith.hx/smith.scm")
  cogs = pkgs.linkFarm "steelix-cogs" [
    {
      name = "smith.hx";
      path = smith;
    }
  ];
in
{
  options.services.ide.steelix = {
    enable = lib.mkEnableOption "steelix (Helix with Steel plugins)";

    configRepo = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://github.com/<you>/helix-config.git";
      description = "Git URL of the steelix config repository, synced into ~/.config/helix; null: no sync.";
    };
  };

  config = lib.mkIf (ide.enable && cfg.enable) {
    services.ide.editors.steelix = {
      command = "hx";
      desktop = "Helix.desktop";
    };

    environment = {
      systemPackages = with pkgs; [
        steelix
        steel
        ec
      ];
      sessionVariables.STEEL_SEARCH_PATHS = "${cogs}";
    };

    systemd.services = lib.mkIf (cfg.configRepo != null) (
      import ./config-sync.nix {
        inherit pkgs;
        inherit (ide) user;
        name = "steelix";
        repo = cfg.configRepo;
        dir = "/home/${ide.user}/.config/helix";
      }
    );
  };
}

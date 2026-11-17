# lazygit with NoX's defaults (/etc/lazygit/config.yml) under the user's
# own ~/.config/lazygit/config.yml
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.lazygit;
in
{
  options.services.lazygit = {
    enable = lib.mkEnableOption "lazygit with NoX's defaults";
    user = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "User whose ~/.config/lazygit/config.yml is layered over the defaults.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment = {
      systemPackages = [ pkgs.lazygit ];

      # NoX's lazygit defaults first, then the user's own config (later
      # files win; each listed file must exist, tmpfiles below)
      variables.LG_CONFIG_FILE = "/etc/lazygit/config.yml,$HOME/.config/lazygit/config.yml";

      # No background fetch: every fetch signs with the GitHub agent, and dom0
      # asks to confirm each use (2026-11-02: a lazygit asked every minute)
      etc."lazygit/config.yml".text = ''
        git:
          autoFetch: false
      '';
    };

    # ~/.config itself: common-config
    systemd.tmpfiles.rules = [
      "d /home/${cfg.user}/.config/lazygit 0755 ${cfg.user} users -"
      "f /home/${cfg.user}/.config/lazygit/config.yml 0644 ${cfg.user} users -"
    ];
  };
}

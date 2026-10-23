{ lib, config, ... }:

with lib;

let
  cfg = config.services.rdp;
in
{
  options.services.rdp = {
    enable = mkEnableOption "Enable the RDP (xrdp + fluxbox) module";
    user = mkOption {
      type = types.str;
      default = "user";
      description = "Username for the RDP session";
    };
    password = mkOption {
      type = types.str;
      default = "trash";
      description = "Password for the RDP user";
    };
  };

  config = mkIf cfg.enable {
    networking.firewall = {
      allowedTCPPorts = [ 3389 ];
      allowedUDPPorts = [ 3389 ];
    };
    services = {
      xrdp = {
        enable = true;
        audio.enable = true;
      };
      xserver.enable = true;
      xserver.windowManager.fluxbox.enable = true;
      pipewire.enable = false;
      pulseaudio.enable = true;
    };

    users.users.${cfg.user} = {
      password = cfg.password;
      extraGroups = lib.mkAfter [ "video" ];
    };
  };
}

# NOTE: Working Xfce4 + xrdp setup
# services.xrdp.enable = true;
# services.xrdp.defaultWindowManager = "xfce4-session";
# services.xserver.enable = true;
# services.xserver.displayManager.lightdm.enable = true;
# services.xserver.desktopManager.xfce.enable = true;

# dom0's user: the account (wheel, a trusted Nix user), the desktop session
# logged in automatically at boot (the LUKS passphrase is the login; Mod+Alt+L
# locks); the input proxy, the nox-rpc questions and the VNC sockets
# (xen-dom0.nix) run as this user.
{ config, lib, ... }:
let
  inherit (config.nox) user;
in
{
  options.nox.user = lib.mkOption {
    type = lib.types.str;
    default = "user";
    description = "dom0's user: its account (wheel, trusted Nix user), autologin into niri, input proxy (xen-usb), nox-rpc questions, VNC sockets.";
  };

  config = {
    users.users.${user} = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    nix.settings.trusted-users = [ user ];

    services.displayManager = {
      autoLogin = {
        enable = lib.mkDefault true;
        user = lib.mkDefault user;
      };
      # The session autologin starts
      defaultSession = lib.mkDefault "niri";
    };
  };
}

# This machine: hardware (nixos-generate-config), Xen dom0, user, locale,
# keyboard. Everything else of dom0 comes from NoX (dom0 base, desktop,
# tools).
{ inputs, ... }:
{
  imports = [
    # `nixos-generate-config --show-hardware-config > hardware-configuration.nix`
    ./hardware-configuration.nix
    inputs.nox.nixosModules.xen-dom0
  ];

  networking.hostName = "nox";

  # dom0's user: NoX creates it (wheel, autologin), default "user"
  # nox.user = "user";

  # The disk nox-install installs to (GPT, ESP, LUKS2 + ext4; NoX README
  # "Installer"): nox-install asks for it and writes disk.nix next to this
  # file (`nox.disk.device = "/dev/disk/by-id/…";`). Leave it out on a
  # machine installed by hand

  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";
  services.xserver.xkb.layout = "us";

  # RAM of dom0 in MB (the rest is for the VMs)
  # virtualisation.xen.dom0Resources.memory = 8192;

  system.stateVersion = "26.05";
}

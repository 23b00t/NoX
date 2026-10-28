# The NoX installer (packages.installer-iso): NixOS minimal live system with
# nox-install, nox-hwcheck, disko, git/ssh, editors and NetworkManager. Boot it,
# then `sudo nox-install`.
{
  lib,
  pkgs,
  modulesPath,
  disko,
  nox-hwcheck,
  nox-install,
  ...
}:
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  isoImage.isoBaseName = lib.mkForce "nox-installer";

  # IOMMU groups (and shared interrupts) for nox-hwcheck; the unknown
  # vendor's parameter is ignored
  boot.kernelParams = [
    "intel_iommu=on"
    "amd_iommu=on"
  ];

  # nmtui/nmcli instead of wpa_supplicant
  networking.networkmanager.enable = true;
  networking.wireless.enable = lib.mkForce false;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.variables.EDITOR = "nvim";
  environment.systemPackages = [
    nox-install
    nox-hwcheck
    disko
    pkgs.git
    pkgs.openssh
    pkgs.neovim
    pkgs.helix
    pkgs.nano
    pkgs.cryptsetup
    pkgs.pciutils
    pkgs.usbutils
  ];

  system.stateVersion = lib.trivial.release;
}

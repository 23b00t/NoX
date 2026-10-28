# disp: ad-hoc disposable (`nox disp`). Same setup as vanilla (only
# common-config, software imperatively with `nix profile install` / `nix
# shell` in the store overlay, GUI over wprs), but every start begins empty:
# dom0 deletes home and overlay images before start and after stop
# (registry `disposable`, machines/xen-dom0.nix).
{ pkgs, ... }:
{
  imports = [
    ../modules/net-config.nix
    ../modules/common-config.nix
    ../modules/persistent-store-overlay.nix
    # yazi and bashmount (removable media, LUKS), with the udisks2 polkit rule
    ../modules/yazi-config.nix
  ];

  networking.hostName = "disp-vm";

  microvm = {
    # Own closure valid in the Nix DB, so a GC in the overlay never deletes it
    # (as in vanilla)
    registerClosure = true;
    hypervisor = "xen";
    volumes = [
      {
        mountPoint = "/home/user";
        image = "home.img";
        size = 20000;
      }
    ];
    # Boots with 2048 MB, the RAM balancer grows it up to 4096 MB
    mem = 4096;
    balloon = true;
    initialBalloonMem = 2048;
    vcpu = 2;
  };

  services = {
    persistentStoreOverlay.enable = true;

    net-config = {
      enable = true;
      index = 31;
      mac = "00:00:00:00:00:1f";
    };

    common-config.enable = true;

    # Disks attached via vm-usb: gnome-disks / udisksctl (format, LUKS)
    udisks2.enable = true;

    # Phone transfers (Bluetooth adapter via `nox usb attach <busid> disp`,
    # pairings come along from sys-usb): blueman-manager sends files,
    # blueman-applet accepts incoming ones (OBEX agent); bluez itself comes
    # from usbip-client.nix (registry allowedOwners)
    blueman.enable = true;
  };

  environment.systemPackages = [
    # Phones over USB cable (MTP): android-file-transfer (GUI), or
    # `aft-mtp-mount ~/phone` / `fusermount -u ~/phone`
    pkgs.android-file-transfer
    # Partition table, LUKS and file system in one dialog
    pkgs.gnome-disk-utility
  ];

  system.stateVersion = "26.05";
}

# nox.disk: the standard disk layout of a NoX machine, set up by `nox-install`
# (disko): GPT, ESP 1 GB (/boot), the rest LUKS2 with ext4 (/). No swap
# partition (zram, dom0/base.nix), so one passphrase at boot. disko also
# generates fileSystems and the LUKS device from it, so a machine sets this
# only when it was installed with it (its hardware-configuration then has no
# fileSystems/LUKS entries); without `device` nothing changes.
{ self }:
{ config, lib, ... }:
let
  cfg = config.nox.disk;
in
{
  imports = [ self.inputs.disko.nixosModules.disko ];

  options.nox.disk.device = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S7HDNU0YA17855X";
    description = "The disk `nox-install` partitions (GPT, ESP 1 GB, LUKS2 + ext4) and the machine boots from; null: fileSystems come from the hardware-configuration.";
  };

  config = lib.mkIf (cfg.device != null) {
    disko.devices.disk.main = {
      type = "disk";
      inherit (cfg) device;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [
                "fmask=0077"
                "dmask=0077"
              ];
            };
          };
          root = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              settings.allowDiscards = true;
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
                # Wait for the passphrase as long as it takes (default: ~90 s,
                # then the emergency shell)
                mountOptions = [ "x-systemd.device-timeout=0" ];
              };
            };
          };
        };
      };
    };
  };
}

# Role gaming: a VM for games with the GPU passed through (`gpu = true`);
# input devices come over USB/IP from sys-usb. Steam itself is unfree: the
# VM's `apps` brings it.
{ lib, ... }:
{
  imports = [ ../vms/modules/usbip-client.nix ];

  hardware.graphics = {
    enable = lib.mkDefault true;
    enable32Bit = lib.mkDefault true;
  };
}

# Role windows: Windows programs under wine (Bottles); 3D for DXVK over the
# software renderer, the Windows core fonts are unfree and stay out (the
# VM's module may add them).
{ lib, ... }:
{
  hardware.graphics = {
    enable = lib.mkDefault true;
    enable32Bit = lib.mkDefault true;
  };
}

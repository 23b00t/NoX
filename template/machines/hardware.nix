# Hardware of the machines for NoX (NoX nixos/registry/machine.nix). Find
# the values with `lspci -nn` and `lsusb`.
{
  nox = {
    profile = {
      cpuVendor = "intel"; # or "amd"
      # PV dom0 (true) or PVH (false, the default)
      dom0Pv = false;
      # A second GPU that dom0 never drives, for passthrough (gpu = true):
      # "nvidia" blacklists nouveau/nvidia in dom0
      # dGpuVendor = "nvidia";
      # Drivers dom0 never loads: the network cards belong to sys-net
      blockedHostDrivers = {
        nic = [ ]; # e.g. "r8169"
        wifi = [ ]; # e.g. "iwlwifi"
      };
    };
    # Passed-through PCI devices (`lspci -D`): network cards -> sys-net,
    # USB controllers -> sys-usb, GPU (+ audio function) -> VMs with gpu = true
    pciDevicePaths = {
      nic = [ ]; # e.g. "0000:00:14.3"
      usb = [ ]; # e.g. "0000:00:14.0"
      # gpu = [ "0000:02:00.0" "0000:02:00.1" ];
    };
    pciDeviceIds.nic = [ ];
    # USB inventory: host-allow = input devices for dom0 (over the input
    # proxy), vm-reserved = stays in sys-usb or goes to a VM (vm-usb attach)
    usbDevices = [
      # {
      #   name = "keyboard";
      #   vendorId = "1209";
      #   productId = "2303";
      #   policy = "host-allow";
      #   defaultOwner = "host";
      #   allowedOwners = [ "host" ];
      #   microvmUsbPath = "vendorid=0x1209,productid=0x2303";
      # }
    ];
  };
}

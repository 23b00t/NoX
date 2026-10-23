# USB from sys-usb to other VMs (v2.8.3, Qubes model), derived from the
# registry USB inventory. Used by sys-usb (vms/sys-usb), the target VMs
# (vms/modules/usbip-client.nix) and dom0 (modules/xen-usb.nix, xen-links).
#
# - Every device lands in sys-usb. dom0's `vm-usb attach <device> <vm>` gives
#   it to a VM over USB/IP (bridge `vm-usbip` in sys-usb, 10.2.0.0/24);
#   `defaultOwner` = automatic attach while that VM runs.
# - Registry devices only go to their `allowedOwners`; unknown devices to any
#   target VM (never dom0, driver domains or the builder).
# - Devices owned by `host`: input devices, forwarded to dom0 by the input proxy
{ lib, vmRegistry }:
let
  devices = vmRegistry.hardware.usb.devices;

  # Last octet of the VM's admin IP, also used on the USB/IP link
  indexOf = name: lib.toInt (lib.last (lib.splitString "." vmRegistry.byName.${name}.ip));
  hex = i: lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString i));
in
rec {
  domain = "sys-usb-vm";
  # sys-usb's admin address, used by dom0 to reach it
  adminAddress = vmRegistry.byName.sys-usb.ip;
  bridge = "vm-usbip";
  network = "10.2.0.0";
  serverAddress = "10.2.0.254";
  prefixLength = 24;
  port = 3240;

  # VMs that never get USB devices from sys-usb
  noTarget = [
    "sys-net"
    "sys-usb"
    "sys-vpn"
    "sys-firewall"
    "builder"
  ];
  isTarget = name: vmRegistry.byName ? ${name} && !builtins.elem name noTarget;

  inputDevices = builtins.filter (d: (d.defaultOwner or null) == "host") devices;

  # Target VMs allowed to own a registry Bluetooth adapter: they run bluez
  bluetoothVms = lib.unique (
    lib.concatMap (d: builtins.filter isTarget (d.allowedOwners or [ ])) (
      builtins.filter (d: d.bluetooth or false) devices
    )
  );

  # For dom0's vm-usb, one line per registry device:
  # "vendor:product name defaultOwner allowedOwner,..."
  policy = lib.concatMapStrings (
    d:
    lib.concatStringsSep " " [
      "${d.vendorId}:${d.productId}"
      (lib.replaceStrings [ " " ] [ "_" ] d.name)
      (d.defaultOwner or "-")
      (lib.concatStringsSep "," (d.allowedOwners or [ "-" ]))
    ]
    + "\n"
  ) devices;

  addressOf = name: "10.2.0.${toString (indexOf name)}";
  macOf = name: "00:00:00:00:02:${hex (indexOf name)}";
}

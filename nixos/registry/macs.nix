# MAC addresses of a domain's interfaces, as NoX hands them out, by the
# domain's index (last octet of its IP): the admin interface (tap vm<index>,
# sys-net: vm-router) 00:00:00:00:00:<index as hex>, the uplink interface
# 00:00:00:00:01:<hex>, the USB/IP link to sys-usb (vms/usb-links.nix)
# 00:00:00:00:02:<hex>, the lab link to sys-firewall (modules/xen-lab.nix)
# 00:00:00:00:03:<hex>. net-config.nix takes its defaults from here, the
# registry rules (rules.nix) check them. The image domains' vifs are set in
# dom0/xen-dom0.nix (services.xen-image-domains).
{ lib }:
rec {
  hex = i: lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString i));
  admin = index: "00:00:00:00:00:${hex index}";
  uplink = index: "00:00:00:00:01:${hex index}";
  usbip = index: "00:00:00:00:02:${hex index}";
  lab = index: "00:00:00:00:03:${hex index}";
}

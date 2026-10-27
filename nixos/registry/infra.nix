# NoX's infrastructure VMs (driver domains and helpers, modules in
# ../vms/<name>): sys-net, sys-usb and sys-firewall come with every NoX
# machine, the others when the user enables them (`nox.infra.<name>.enable`).
# Their entries in nox.vms are defaults (mkDefault): the user's vms.nix
# overrides any field. They have no role; definitions.nix gives them their
# NoX module.
{ config, lib, ... }:
let
  cfg = config.nox.infra;
  noCopy = {
    incoming = "deny";
    outgoing = "deny";
  };
  vms = {
    sys-net = {
      index = 253;
      short = "sn";
      label = "sys";
      storeGroup = "sys";
      autostart = true;
      uplink = null;
      disposable = true;
      # network applet in the tray (and in the app menu)
      apps.nm-applet.tray = true;
      # paste in (e.g. a WLAN key from vault) without a question, copying
      # out asks
      clipboard = "ask";
    };
    sys-usb = {
      index = 23;
      short = "su";
      label = "sys";
      storeGroup = "sys";
      uplink = null;
      disposable = true;
      explorer = true;
    };
    # Firewall between the VMs and sys-net (Qubes model, driver domain):
    # serves `vm-fw` for every VM with the default uplink; routed to sys-net
    # without NAT; isolation, egress lists, DNS resolver
    sys-firewall = {
      index = 33;
      short = "sf";
      label = "sys";
      storeGroup = "sys";
      autostart = true;
      uplink = "sys-net";
      disposable = true;
      githubAgent = false;
      dbus = false;
    };
    # VPN gateway (killswitch) for VMs with `uplink = "sys-vpn"`; its own
    # uplink goes to sys-firewall. Provider configs come in by vm-copy
    sys-vpn = {
      index = 30;
      short = "sv";
      label = "sys";
      storeGroup = "sys";
      disposable = true;
      githubAgent = false;
    };
    # Print driver domain: CUPS with driverless queues, PDFs come in over RPC
    # (`vm-print`), network only to LAN printers (its rule lives in sys-net)
    sys-print = {
      index = 26;
      short = "sp";
      label = "sys";
      storeGroup = "sys";
      uplink = "sys-net";
      # holds no user data: print jobs only
      copy = noCopy;
      githubAgent = false;
      dbus = false;
    };
    # Ad-hoc disposable (`nox disp`): empty on every start
    disp = {
      index = 31;
      short = "d";
      disposable = true;
      githubAgent = false;
      dbus = false;
    };
    # Disposable for `nox backup`: holds the backup disk, no network
    disp-backup = {
      index = 32;
      short = "db";
      label = "sys";
      storeGroup = "sys";
      uplink = null;
      disposable = true;
      githubAgent = false;
      dbus = false;
      clipboard = "deny";
      copy = noCopy;
    };
    # Remote builder for dom0-update; dom0 logs in with the user's key
    # (`hostSSHKey` in the user's vms.nix)
    builder = {
      index = 25;
      short = "b";
      label = "sys";
      githubAgent = false;
      dbus = false;
      memPriority = 10;
      # nothing in or out by nox-rpc copy (the build VM sees untrusted code)
      copy = noCopy;
    };
  };
  core = [
    "sys-net"
    "sys-usb"
    "sys-firewall"
  ];
in
{
  options.nox.infra = lib.mapAttrs (name: _: {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = builtins.elem name core;
      description = "NoX's ${name} VM (module nixos/vms/${name}).";
    };
  }) vms;

  config.nox.vms = lib.mapAttrs (
    name: fields: lib.mkIf cfg.${name}.enable (lib.mapAttrsRecursive (_: lib.mkDefault) fields)
  ) vms;
}

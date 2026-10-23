# Lab target (registry `labTarget`): kali tests this VM's apps over sys-firewall's
# lab bridge vm-lab. dom0 hangs the vif on only while needed (`vm-lab attach
# <vm>`, MAC 00:00:00:00:03:<last octet as hex>); until then the interface
# simply does not exist. Address 10.5.0.<last octet>/24, no gateway. Apps
# must listen on 0.0.0.0 or this address; ports open globally in the VM's
# firewall are open here too.
{
  lib,
  config,
  vmRegistry,
  ...
}:
let
  cfg = config.services.lab-target;
  vmName = lib.removeSuffix "-vm" (config.networking.hostName or "");
  currentVm = vmRegistry.byName.${vmName} or { };
  octet = lib.toInt (lib.last (lib.splitString "." (currentVm.ip or "0.0.0.0")));
  mac = "00:00:00:00:03:${lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString octet))}";
in
{
  options.services.lab-target = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = currentVm.labTarget or false;
      defaultText = lib.literalExpression "registry `labTarget`";
      description = "Configure the lab interface (lab0) that dom0 attaches with `vm-lab attach`.";
    };
    ports = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "TCP ports opened only on the lab interface (in addition to the VM's global firewall ports).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.network = {
      links."10-lab" = {
        matchConfig.MACAddress = mac;
        linkConfig.Name = "lab0";
      };
      networks."22-lab" = {
        matchConfig.MACAddress = mac;
        address = [ "10.5.0.${toString octet}/24" ];
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = false;
          LinkLocalAddressing = "no";
        };
        linkConfig.RequiredForOnline = "no";
      };
    };

    networking.firewall.interfaces.lab0.allowedTCPPorts = cfg.ports;
  };
}

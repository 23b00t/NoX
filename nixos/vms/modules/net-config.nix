{
  lib,
  config,
  vmRegistry,
  ...
}:

with lib;

let
  cfg = config.services.net-config;
  hostName = config.networking.hostName or "";
  vmName = removeSuffix "-vm" hostName;
  currentVm = vmRegistry.byName.${vmName} or { };

  defaultTapId = if cfg.index == null then null else "vm${toString cfg.index}";
  effectiveTapId = if cfg.tapId != null then cfg.tapId else defaultTapId;
  effectiveAddress4 =
    if cfg.address4 != null then
      cfg.address4
    else if cfg.index != null then
      "10.0.0.${toString cfg.index}/24"
    else
      null;
  effectiveGateway4 = cfg.gateway4;
  needsOnLinkGatewayRoute = effectiveAddress4 != null && hasSuffix "/32" effectiveAddress4;

  indexHex = fixedWidthString 2 "0" (toLower (toHexString cfg.index));

  # Backend of the uplink by registry field `uplink` (default sys-firewall). The
  # backends are driver domains serving `bridge`; the VM gets `<net>.<index>`
  # there, `<net>.254` is the backend's address (gateway).
  uplinkBackends = {
    sys-net = {
      backend = "sys-net-vm";
      bridge = "vm-uplink";
      net = "10.1.0";
    };
    # Firewall between the VMs and sys-net (vms/sys-firewall), routed without
    # NAT; DNS only through its resolver
    sys-firewall = {
      backend = "sys-firewall-vm";
      bridge = "vm-fw";
      net = "10.6.0";
      dns = [ "10.6.0.254" ];
    };
    # VPN gateway with killswitch (vms/sys-vpn); DNS only through the tunnel,
    # served by sys-vpn itself
    sys-vpn = {
      backend = "sys-vpn-vm";
      bridge = "vm-vpn";
      net = "10.4.0";
      dns = [ "10.4.0.254" ];
    };
  };
  uplinkName = currentVm.uplink or (if currentVm.nat or false then "sys-firewall" else "sys-net");
  uplinkBackend = uplinkBackends.${uplinkName};

  hostPkgs = config.microvm.vmHostPackages;
in
{
  options.services.net-config = {
    enable = mkEnableOption "Enable the VM network configuration module";

    index = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Legacy VM index used to derive tap id and IPv4 address.";
    };

    tapId = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional explicit host-side tap id.";
    };

    mac = mkOption {
      type = types.str;
      description = "MAC address for the guest interface.";
    };

    interfaceName = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional stable guest interface name.";
    };

    address4 = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional explicit IPv4 address with prefix length.";
    };

    gateway4 = mkOption {
      type = types.nullOr types.str;
      # Xen: the admin network never has a default route (internet only via
      # the uplink, and only for `nat = true`)
      default = if config.microvm.hypervisor == "xen" then null else "10.0.0.253";
      defaultText = literalExpression ''if microvm.hypervisor == "xen" then null else "10.0.0.253"'';
      description = "IPv4 default gateway. Set to null to disable.";
    };

    dns = mkOption {
      type = types.listOf types.str;
      default =
        uplinkBackend.dns or [
          "9.9.9.9"
          "149.112.112.112"
          "2620:fe::fe"
          "2620:fe::9"
        ];
      defaultText = literalExpression "the uplink backend's DNS (sys-firewall: 10.6.0.254, sys-vpn: 10.4.0.254), else Quad9";
      description = "DNS servers for the guest.";
    };

    adminInterface = mkOption {
      type = types.bool;
      default = true;
      description = "Give the VM the admin interface (tap on dom0's vm-internal bridge). Xen guests that dom0 reaches over vchan do without it (stage B2, vms/modules/vchan-relay.nix).";
    };

    # Xen (v2.5): second interface served by sys-net (driver domain), the VM's
    # default route. The admin interface above stays for dom0 only.
    uplink = {
      enable = mkOption {
        type = types.bool;
        default = (currentVm.nat or false) && config.microvm.hypervisor == "xen";
        defaultText = literalExpression ''registry `nat` && microvm.hypervisor == "xen"'';
        description = "Give the VM an uplink interface with sys-net as backend.";
      };

      mac = mkOption {
        type = types.str;
        default = "00:00:00:00:01:${indexHex}";
        defaultText = literalExpression ''"00:00:00:00:01:<index as hex>"'';
        description = "MAC address of the uplink interface.";
      };

      address4 = mkOption {
        type = types.str;
        default = "${uplinkBackend.net}.${toString cfg.index}/24";
        defaultText = literalExpression ''"10.1.0.<index>/24" (sys-net), "10.4.0.<index>/24" (sys-vpn)'';
        description = "IPv4 address of the uplink interface.";
      };

      gateway4 = mkOption {
        type = types.str;
        default = "${uplinkBackend.net}.254";
        defaultText = literalExpression ''"10.1.0.254" (sys-net), "10.4.0.254" (sys-vpn)'';
        description = "Default gateway on the uplink (the backend).";
      };

      backend = mkOption {
        type = types.str;
        default = uplinkBackend.backend;
        defaultText = literalExpression ''"<registry uplink>-vm" (default "sys-net-vm")'';
        description = "Xen domain serving the uplink (driver domain).";
      };

      bridge = mkOption {
        type = types.str;
        default = uplinkBackend.bridge;
        defaultText = literalExpression ''"vm-uplink" (sys-net), "vm-vpn" (sys-vpn)'';
        description = "Bridge in the backend domain.";
      };
    };
  };

  config = mkIf cfg.enable {
    networking.useNetworkd = true;

    assertions = [
      {
        assertion = effectiveAddress4 != null;
        message = "services.net-config requires either index or address4.";
      }
      {
        assertion = !cfg.uplink.enable || (cfg.index != null && config.microvm.hypervisor == "xen");
        message = "services.net-config.uplink needs an index and microvm.hypervisor = \"xen\".";
      }
      {
        assertion = uplinkBackends ? ${uplinkName};
        message = "registry: unknown uplink \"${uplinkName}\" for ${vmName} (${concatStringsSep ", " (attrNames uplinkBackends)})";
      }
      {
        assertion = uplinkName == "sys-net" || (currentVm.nat or false);
        message = "registry: uplink = \"${uplinkName}\" for ${vmName} needs nat = true";
      }
    ];

    microvm = {
      interfaces =
        optional (effectiveTapId != null && cfg.adminInterface) {
          id = effectiveTapId;
          type = "tap";
          inherit (cfg) mac;
        }
        ++ optional cfg.uplink.enable {
          id = "uplink";
          type = "bridge";
          inherit (cfg.uplink) mac bridge;
        };

      xen.interfaceBackends = mkIf cfg.uplink.enable {
        uplink = cfg.uplink.backend;
      };

      # Runs in dom0 before the domain is created: the uplink backend (xl devd
      # in sys-net) must be up, otherwise creating the vif fails. The driver
      # domain writes data/backend-ready once xl devd runs (common-config.nix,
      # Whonix-Gateway: modules/xen-image-domains.nix).
      preStart = mkIf cfg.uplink.enable ''
        for _ in $(${hostPkgs.coreutils}/bin/seq 180); do
          be="$(${config.microvm.xen.package}/bin/xl domid ${cfg.uplink.backend} 2>/dev/null)" || be=""
          if [ -n "$be" ] && [ "$(${config.microvm.xen.package}/bin/xenstore-read "/local/domain/$be/data/backend-ready" 2>/dev/null)" = 1 ]; then
            break
          fi
          ${hostPkgs.coreutils}/bin/sleep 1
        done
      '';
    };

    systemd.network.links = mkIf (cfg.interfaceName != null && cfg.adminInterface) {
      "10-net-config-link" = {
        matchConfig.MACAddress = cfg.mac;
        linkConfig.Name = cfg.interfaceName;
      };
    };

    systemd.network.networks = {
      "20-net-config" = mkIf cfg.adminInterface {
        matchConfig.MACAddress = cfg.mac;
        address = [ effectiveAddress4 ];
        routes =
          optional (effectiveGateway4 != null && needsOnLinkGatewayRoute) {
            Destination = "${effectiveGateway4}/32";
            Scope = "link";
          }
          ++ optional (effectiveGateway4 != null) {
            Destination = "0.0.0.0/0";
            Gateway = effectiveGateway4;
          };
        networkConfig.DNS = mkIf (!cfg.uplink.enable) cfg.dns;
      };

      "21-net-config-uplink" = mkIf cfg.uplink.enable {
        matchConfig.MACAddress = cfg.uplink.mac;
        address = [ cfg.uplink.address4 ];
        routes = [
          {
            Destination = "0.0.0.0/0";
            Gateway = cfg.uplink.gateway4;
          }
        ];
        networkConfig.DNS = cfg.dns;
      };
    };
  };
}

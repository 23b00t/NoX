# sys-vpn: VPN gateway, in the routing like the Whonix-Gateway. Driver domain
# serving the bridge `vm-vpn` (10.4.0.254/24) for the uplink vifs of the VMs
# with registry `uplink = "sys-vpn"`; its own uplink goes to sys-net.
# Providers are NetworkManager connections configured in the VM (WireGuard,
# OpenVPN), stored on a volume, never in the repo. Killswitch: clients only
# reach the outside through a tunnel interface (wg*/tun*), DNS only through
# the tunnel's resolver (vms/modules/vpn-killswitch.nix, tested by
# tests/sys-vpn-killswitch.nix). Plan: xen-migration.md "Phase 4: Neue VMs".
{
  lib,
  pkgs,
  config,
  ...
}:
{
  imports = [
    # First: same merge order (tmpfiles.d) as before it was split out
    ../modules/vpn-killswitch.nix
    ../modules/net-config.nix
    ../modules/common-config.nix
  ];

  networking.hostName = "sys-vpn-vm";

  services = {
    # Uplink to sys-net from the registry (`nat = true`), no admin link (vchan)
    net-config = {
      enable = true;
      index = 30;
      mac = "00:00:00:00:00:1e";
    };

    common-config = {
      enable = true;
      withDefaultPkgs = false;
    };

    vpn-killswitch = {
      enable = true;
      interface = "vm-vpn";
      clientNet = "10.4.0.0/24";
    };
  };

  users.users.user.extraGroups = lib.mkAfter [ "networkmanager" ];

  systemd = {
    services = {
      NetworkManager-wait-online.enable = false;

      # As in sys-net, but "ready" means a tunnel is up: ~/data/uplink = 1 in
      # xenstore while a wg*/tun* interface is up
      xen-uplink-state = {
        description = "Report tunnel readiness to dom0 via xenstore";
        wantedBy = [ "multi-user.target" ];
        path = [
          pkgs.iproute2
          pkgs.gnugrep
          config.microvm.xen.package
        ];
        script = ''
          last=""
          while true; do
            if ip -o link show up | grep -qE '^[0-9]+: (wg|tun)'; then state=1; else state=0; fi
            if [ "$state" != "$last" ]; then
              xenstore-write data/uplink "$state" && last="$state"
            fi
            sleep 1
          done
        '';
        serviceConfig = {
          Restart = "always";
          RestartSec = 5;
          ProtectSystem = "strict";
          ProtectHome = true;
          NoNewPrivileges = true;
          DevicePolicy = "closed";
          DeviceAllow = [ "/dev/xen/xenbus rw" ];
        };
      };
    };

    # Client bridge; the vif-bridge hotplug script (xl devd) adds the clients' vifs
    network = {
      netdevs."20-vm-vpn".netdevConfig = {
        Name = "vm-vpn";
        Kind = "bridge";
      };
      networks = {
        "30-vm-vpn" = {
          matchConfig.Name = "vm-vpn";
          address = [ "10.4.0.254/24" ];
          networkConfig.ConfigureWithoutCarrier = true;
          linkConfig.RequiredForOnline = "no";
        };
        # Bridge membership of the vifs is up to the hotplug script
        "10-vif" = {
          matchConfig.Name = "vif*";
          linkConfig.Unmanaged = true;
        };
      };
    };
  };

  networking = {
    networkmanager = {
      enable = true;
      plugins = [ pkgs.networkmanager-openvpn ];
      # NetworkManager only runs the tunnels; uplink (networkd, net-config)
      # and client bridge stay out of its hands
      unmanaged = [
        "interface-name:vm-vpn"
        "interface-name:vif*"
        "mac:${config.services.net-config.uplink.mac}"
      ];
    };
    # Clients reach sys-vpn and (through it) the tunnel, never each other
    nftables.tables.client-isolation = {
      family = "bridge";
      content = ''
        chain forward {
          # priority 0 would be skipped: br_netfilter re-injects after its own hook (prio 0)
          type filter hook forward priority filter; policy accept;
          iifname "vif*" oifname "vif*" drop
        }
      '';
    };
  };

  # One queue per vif: with several (backend with >1 vCPU) part of the
  # connections of multi-queue guests stalled (sys-net, xmg 2026-10-11)
  boot.extraModprobeConfig = ''
    options xen_netback max_queues=1
  '';

  microvm = {
    hypervisor = "xen";
    # No PCI devices, so PVH (the default) instead of HVM like sys-net;
    # untested whether the fork's driver domains work as PVH (fallback:
    # xen.type = "hvm")
    xen.driverDomain = true;
    # Disposable (registry): no home volume (provider configs come in by
    # vm-copy to the tmpfs home and are imported in the same session), only
    # the NetworkManager profiles stay
    volumes = [
      {
        mountPoint = "/etc/NetworkManager/system-connections";
        image = "networkmanager.img";
        size = 512;
      }
    ];
    mem = 1024;
    vcpu = 2;
  };

  environment.systemPackages = with pkgs; [
    networkmanager
    networkmanagerapplet
    wireguard-tools
    iproute2
    dnsutils
    tcpdump
    nftables
  ];

  system.stateVersion = "26.05";
}

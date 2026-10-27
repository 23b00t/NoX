# sys-net (v2.5): Xen HVM driver domain owning the WLAN card. Serves the
# uplink bridge `vm-uplink` (10.1.0.254/24) as backend for sys-firewall and
# sys-print, routes sys-firewall's client nets back to it and NATs to the
# WLAN; Tails has its own bridge. dom0 is only on the admin network (vm-lan).
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  nicPciPaths = vmRegistry.hardware.pci.devicePaths.nic or [ ];
  mkPciDevice = path: {
    bus = "pci";
    inherit path;
  };
  dom0 = "10.0.0.254";
  dom0TestAccess = vmRegistry.hostProfile.dom0TestAccess or null;
  # sys-print (C2, optional) on the uplink: 10.1.0.<last octet of its
  # registry IP>; printers in the local network (IPP), nothing else
  sysPrint = "10.1.0.${lib.last (lib.splitString "." vmRegistry.byName.sys-print.ip)}";
  printRules = lib.optionalString (vmRegistry.byName ? sys-print) ''
    # sys-print (C2): printers in the local network (IPP), nothing else
    iifname "vm-uplink" ip saddr ${sysPrint} oifname != { "vm-uplink", "vm-lan", "vm-tails" } ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport 631 accept
    iifname "vm-uplink" ip saddr ${sysPrint} reject with icmpx type admin-prohibited
  '';
  # sys-firewall on the uplink: its client nets are routed there (no NAT)
  sysFirewall = "10.1.0.${lib.last (lib.splitString "." vmRegistry.byName.sys-firewall.ip)}";
in
{
  imports = [
    ../modules/net-config.nix
    ../modules/common-config.nix
  ];

  networking = {
    hostName = "sys-net-vm";

    # RTL8821CE (rtw88): the firmware got stuck in power save ("firmware failed
    # to leave lps state", "failed to send h2c command"), downloads at ~10 KB/s
    # (2026-10-10). No power save, no deep LPS, no ASPM.
    networkmanager.wifi.powersave = false;
  };

  services = {
    net-config = {
      enable = true;
      tapId = "vm-router";
      interfaceName = "vm-lan";
      address4 = "10.0.0.253/24";
      gateway4 = null;
      mac = "00:00:00:00:00:11";
    };

    common-config = {
      enable = true;
      withDefaultPkgs = false;
    };

    # dom0's `nox printers`: the local networks (CIDR per line, without the
    # VM bridges), which sys-print then scans for IPP printers
    nox-rpc.guest.handlers.lan = lib.mkIf (vmRegistry.byName ? sys-print) ''
      if [ "$source" != dom0 ]; then
        echo "error: only dom0"
        exit 1
      fi
      ${pkgs.iproute2}/bin/ip -4 -o route show proto kernel scope link |
        while read -r net _ dev _; do
          case "$dev" in vm-*) ;; *) echo "$net" ;; esac
        done
    '';
  };

  users.users.user.extraGroups = lib.mkAfter [ "networkmanager" ];

  # nm-applet's "Edit connections": nm-connection-editor registers its app id
  # on the session bus, which dom0's filtered bus refuses ("Failed to
  # register: … ServiceUnknown", xmg 2026-10-27). It only needs
  # NetworkManager on the VM's system bus, so it runs on the VM's own session
  # bus (uid 1000 as in vchan-relay.nix). Wrapped inside the package: nm-applet
  # calls it by its store path; binary wrapper (wrapGAppsHook), so --set
  nixpkgs.overlays = [
    (_: prev: {
      networkmanagerapplet = prev.networkmanagerapplet.overrideAttrs (old: {
        postFixup = (old.postFixup or "") + ''
          wrapProgram $out/bin/nm-connection-editor \
            --set DBUS_SESSION_BUS_ADDRESS unix:path=/run/user/1000/bus
        '';
      });
    })
  ];

  systemd = {
    # Uplink bridge; the vif-bridge hotplug script (xl devd) adds the VMs' vifs
    network = {
      # RTL8125 (r8169, xmg): hardware TX checksums broke forwarded (NATed)
      # packets from the VMs: uploads from VMs at ~20 KB/s, sys-net itself at
      # 4.8 MB/s; Tor circuits and the builder stalled. With TX checksum
      # offload and TSO/GSO off VMs upload at 4.9 MB/s (2026-10-11).
      # Scatter-gather must be off too: the kernel no longer drops it with TX
      # checksums; SG on alone brought VM uploads back to ~20 KB/s and stalled
      # Tor in the Whonix-Gateway (2026-10-14). Applied by udev,
      # NetworkManager still manages the link.
      links."10-r8169-no-tx-offload" = {
        matchConfig.Driver = "r8169";
        linkConfig = {
          # Only the first matching .link applies: keep 99-default.link's naming
          NamePolicy = "keep kernel database onboard slot path";
          AlternativeNamesPolicy = "database onboard slot path mac";
          MACAddressPolicy = "persistent";
          TransmitChecksumOffload = false;
          TCPSegmentationOffload = false;
          TCP6SegmentationOffload = false;
          GenericSegmentationOffload = false;
          ScatterGather = false;
        };
      };

      netdevs = {
        "20-vm-uplink".netdevConfig = {
          Name = "vm-uplink";
          Kind = "bridge";
        };
        # Tails (HVM): DHCP from sys-net, nothing else on this bridge
        "20-vm-tails".netdevConfig = {
          Name = "vm-tails";
          Kind = "bridge";
        };
      };
      networks = {
        "30-vm-uplink" = {
          matchConfig.Name = "vm-uplink";
          address = [ "10.1.0.254/24" ];
          routes =
            map
              (net: {
                Destination = net;
                Gateway = sysFirewall;
              })
              [
                "10.6.0.0/24"
                "10.0.2.0/24"
              ];
          networkConfig.ConfigureWithoutCarrier = true;
          linkConfig.RequiredForOnline = "no";
        };
        "30-vm-tails" = {
          matchConfig.Name = "vm-tails";
          address = [ "10.3.0.1/24" ];
          networkConfig = {
            ConfigureWithoutCarrier = true;
            DHCPServer = true;
          };
          dhcpServerConfig = {
            PoolOffset = 100;
            PoolSize = 50;
            # Tails resolves through Tor, no DNS from here
            EmitDNS = false;
          };
          linkConfig.RequiredForOnline = "no";
        };
        # Bridge membership of the vifs is up to the hotplug script
        "10-vif" = {
          matchConfig.Name = "vif*";
          linkConfig.Unmanaged = true;
        };
      };
    };

    services.NetworkManager-wait-online.enable = false;

    # Tells dom0 whether the uplink is ready (default route) via xenstore
    # (~/data/uplink, guest-writable); the Whonix-Gateway waits for it
    # (modules/xen-image-domains.nix, waitForUplink)
    services.xen-uplink-state = {
      description = "Report uplink readiness to dom0 via xenstore";
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.iproute2
        pkgs.gnugrep
        config.microvm.xen.package
      ];
      script = ''
        last=""
        while true; do
          if ip -4 route show default | grep -q .; then state=1; else state=0; fi
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

  networking = {
    networkmanager = {
      enable = true;
      unmanaged = [
        "interface-name:vm-lan"
        "interface-name:vm-uplink"
        "interface-name:vm-tails"
        "interface-name:vif*"
      ];
    };
    nftables = {
      enable = true;
      tables = {
        # VMs on the uplink reach sys-net and the outside, never each other
        uplink-isolation = {
          family = "bridge";
          content = ''
            chain forward {
              # priority 0 would be skipped: br_netfilter re-injects after its own hook (prio 0)
              type filter hook forward priority filter; policy accept;
              iifname "vif*" oifname "vif*" drop
            }
          '';
        };
      }
      // lib.optionalAttrs (dom0TestAccess != null) {
        # Test phase: SSH from the LAN to dom0
        dom0-ssh = {
          family = "ip";
          content = ''
            chain prerouting {
              type nat hook prerouting priority dstnat; policy accept;
              iifname "wl*" ip saddr ${dom0TestAccess.lan} tcp dport 22 dnat to ${dom0}:22
            }
          '';
        };
      };
    };
    firewall = {
      enable = true;
      # DHCP for Tails (it takes its address only by DHCP)
      interfaces.vm-tails.allowedUDPPorts = [ 67 ];
      filterForward = true;
      extraForwardRules = ''
        ${printRules}# VMs and sys-firewall (its clients routed: 10.6.0.0/24, Whonix-Gateway
        # 10.0.2.0/24) -> outside only (not into the admin network, not to Tails)
        iifname "vm-uplink" oifname != { "vm-uplink", "vm-lan", "vm-tails" } accept
        # Tails -> outside only (it only speaks Tor itself)
        iifname "vm-tails" oifname != { "vm-uplink", "vm-lan", "vm-tails" } accept
      ''
      + lib.optionalString (dom0TestAccess != null) ''
        # Test phase: dom0 -> outside, HTTPS/DNS/NTP/ICMP only (as on the XMG),
        # never into the uplink network
        iifname "vm-lan" ip saddr ${dom0} oifname { "vm-uplink", "vm-tails" } reject with icmpx type admin-prohibited
        iifname "vm-lan" ip saddr ${dom0} meta l4proto icmp accept
        iifname "vm-lan" ip saddr ${dom0} tcp dport { 22, 80, 443 } accept
        iifname "vm-lan" ip saddr ${dom0} udp dport { 53, 123 } accept
        iifname "vm-lan" ip saddr ${dom0} tcp dport 53 accept
        iifname "vm-lan" ip saddr ${dom0} reject with icmpx type admin-prohibited
        # Test phase: LAN -> dom0 SSH (port forward above)
        iifname "wl*" oifname "vm-lan" ip saddr ${dom0TestAccess.lan} ip daddr ${dom0} tcp dport 22 ct status dnat accept
      ''
      + ''
        ct state established,related accept
      '';
    };
    nat = {
      enable = true;
      internalInterfaces = [
        "vm-uplink"
        "vm-tails"
      ]
      ++ lib.optional (dom0TestAccess != null) "vm-lan";
    };
  };

  boot = {
    kernel.sysctl."net.ipv4.ip_forward" = 1;

    # Loaded at runtime (first bridge rule, iptables-nft) these deadlocked with
    # xenwatch attaching new vifs after `mr sys-net` (xmg, 2026-10-16, Known
    # Issues): load them at boot
    kernelModules = [
      "nft_meta_bridge"
      "br_netfilter"
      "nft_compat"
    ];

    # MSI under a PV dom0 (hp WLAN, xmg Ethernet: online, restarts work,
    # 2026-10-12). With a PVH dom0 MSI-X mapping fails for passthrough (v2.1;
    # xmg: no network), INTx (pci=nomsi) works there
    kernelParams = lib.optional (!(vmRegistry.hostProfile.dom0Pv or false)) "pci=nomsi";

    # One queue per vif: with several (backend with >1 vCPU) part of the
    # connections of multi-queue guests (Whonix-Gateway) stalled, Tor circuits
    # timed out (xmg, 2026-10-11)
    extraModprobeConfig = ''
      options rtw88_core disable_lps_deep=y
      options rtw88_pci disable_aspm=y
      options xen_netback max_queues=1
    '';
  };

  hardware.enableRedistributableFirmware = true;

  microvm = {
    hypervisor = "xen";
    xen = {
      # PCI passthrough with a PVH dom0 only works for HVM guests
      type = "hvm";
      driverDomain = true;
    };
    volumes = [
      {
        mountPoint = "/etc/NetworkManager/system-connections";
        image = "networkmanager.img";
        size = 512;
      }
    ];
    devices = map mkPciDevice nicPciPaths;
    mem = 1024;
    # One vCPU served the NIC interrupts (INTx), NAT and all bridges; on xmg
    # the RTL8125 dropped ~1.5 % of the received packets (2026-10-11)
    vcpu = 2;
  };

  environment.systemPackages = with pkgs; [
    networkmanager
    networkmanagerapplet
    iw
    ethtool
    iproute2
    wirelesstools
    wpa_supplicant
    dnsutils
    tcpdump
    nftables
    iftop
  ];

  system.stateVersion = "26.05";
}

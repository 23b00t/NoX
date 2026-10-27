# sys-firewall (xen-migration.md, spec step 4, Qubes model): PVH driver
# domain between the VMs and sys-net. Serves
# - `vm-fw` (10.6.0.254/24): uplink of every VM with `nat` (registry default
#   `uplink`), sys-vpn and kali's internet vif
# - `vm-whx-ext` (10.0.2.2/24): external side of the Whonix-Gateway (its
#   eth0 is fixed to 10.0.2.15 via 10.0.2.2 in the image)
# - `vm-lab` (pure L2, only where kali runs): kali and the labTarget VMs
# Routed to sys-net without NAT (sys-net routes 10.6.0.0/24 and 10.0.2.0/24
# back here and NATs to the WLAN). Clients reach the outside, never each
# other; registry `egress` narrows what a VM may send; DNS only through the
# resolver here. Disposable, no volume.
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  vmNet = "10.6.0";
  # VMs behind this firewall (registry uplink default) with an egress list:
  # "<their vm-fw address>" -> [ { to; ports; } ]
  fwVms = builtins.filter (
    vm: (vm.nat or false) && (vm.uplink or "sys-firewall") == "sys-firewall" && vm ? egress
  ) vmRegistry.vms;
  octet = vm: lib.last (lib.splitString "." vm.ip);
  egressRules = lib.concatMapStrings (
    vm:
    let
      src = "${vmNet}.${octet vm}";
    in
    lib.concatMapStrings (
      e:
      "iifname \"vm-fw\" ip saddr ${src} ip daddr ${e.to}"
      +
        lib.optionalString ((e.ports or [ ]) != [ ])
          " meta l4proto { tcp, udp } th dport { ${lib.concatMapStringsSep ", " toString e.ports} }"
      + " accept\n"
    ) vm.egress
    + "iifname \"vm-fw\" ip saddr ${src} reject with icmpx type admin-prohibited\n"
  ) fwVms;
  # Lab bridge (kali tests the registry's labTarget VMs), only where kali
  # runs. kali's lab vif: 00:00:00:00:03:<last octet of its IP as hex>
  kali = lib.findFirst (d: d.name == "kali") null vmRegistry.imageDomains;
  lab = kali != null;
  kaliLabMac = "00:00:00:00:03:${
    lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString (lib.toInt (octet kali))))
  }";
  clientBridges = [
    "vm-fw"
    "vm-whx-ext"
  ]
  ++ lib.optional lab "vm-lab";
  notClients = "{ ${lib.concatMapStringsSep ", " (b: ''"${b}"'') clientBridges} }";
in
{
  imports = [
    ../modules/net-config.nix
    ../modules/common-config.nix
  ];

  networking.hostName = "sys-firewall-vm";

  services = {
    # Uplink to sys-net (registry `uplink = "sys-net"`), no admin link (vchan)
    net-config = {
      enable = true;
      index = 33;
      mac = "00:00:00:00:00:21";
    };

    common-config = {
      enable = true;
      withDefaultPkgs = false;
    };

    # Resolver for the clients on vm-fw (forwards to Quad9 through sys-net)
    dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        interface = "vm-fw";
        bind-dynamic = true;
        no-resolv = true;
        no-hosts = true;
        server = [
          "9.9.9.9"
          "149.112.112.112"
        ];
        cache-size = 1000;
      };
    };
  };

  systemd = {
    services = {
      # As in sys-net, but "ready" means sys-net's uplink answers: ~/data/uplink
      # = 1 in xenstore once a DNS query to Quad9 goes through (the
      # Whonix-Gateway waits for it, modules/xen-image-domains.nix)
      xen-uplink-state = {
        description = "Report uplink readiness to dom0 via xenstore";
        wantedBy = [ "multi-user.target" ];
        path = [
          pkgs.dnsutils
          config.microvm.xen.package
        ];
        script = ''
          last=""
          while true; do
            if dig +time=2 +tries=1 @9.9.9.9 . NS >/dev/null 2>&1; then state=1; else state=0; fi
            if [ "$state" != "$last" ]; then
              xenstore-write data/uplink "$state" && last="$state"
            fi
            if [ "$state" = 1 ]; then sleep 30; else sleep 2; fi
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

    # Client bridges; the vif-bridge hotplug script (xl devd) adds the vifs
    network = {
      # Routed (not NATed) twice over Xen vifs, the clients' TCP left sys-net
      # with broken checksums: ICMP passed, TCP handshakes hung (hp
      # 2026-10-18). With scatter-gather and segmentation/receive offloads
      # off on the uplink (netfront) and the clients' vifs (netback) the
      # kernel finishes the checksums here. Only the first matching .link
      # applies: keep 99-default.link's naming
      links =
        lib.genAttrs
          [
            "10-uplink-no-offload"
            "10-vif-no-offload"
          ]
          (name: {
            matchConfig =
              if name == "10-uplink-no-offload" then
                { MACAddress = config.services.net-config.uplink.mac; }
              else
                { OriginalName = "vif*"; };
            linkConfig = {
              NamePolicy = "keep kernel database onboard slot path";
              AlternativeNamesPolicy = "database onboard slot path mac";
              MACAddressPolicy = "persistent";
              ScatterGather = false;
              TransmitChecksumOffload = false;
              TCPSegmentationOffload = false;
              TCP6SegmentationOffload = false;
              GenericSegmentationOffload = false;
              GenericReceiveOffload = false;
            };
          });

      netdevs = {
        "20-vm-fw".netdevConfig = {
          Name = "vm-fw";
          Kind = "bridge";
        };
        "20-vm-whx-ext".netdevConfig = {
          Name = "vm-whx-ext";
          Kind = "bridge";
        };
      }
      // lib.optionalAttrs lab {
        "20-vm-lab".netdevConfig = {
          Name = "vm-lab";
          Kind = "bridge";
        };
      };
      networks = {
        "30-vm-fw" = {
          matchConfig.Name = "vm-fw";
          address = [ "${vmNet}.254/24" ];
          networkConfig.ConfigureWithoutCarrier = true;
          linkConfig.RequiredForOnline = "no";
        };
        "30-vm-whx-ext" = {
          matchConfig.Name = "vm-whx-ext";
          address = [ "10.0.2.2/24" ];
          networkConfig.ConfigureWithoutCarrier = true;
          linkConfig.RequiredForOnline = "no";
        };
        # Bridge membership of the vifs is up to the hotplug script
        "10-vif" = {
          matchConfig.Name = "vif*";
          linkConfig.Unmanaged = true;
        };
      }
      // lib.optionalAttrs lab {
        # Lab: kali and the attached labTarget VMs (10.5.0.0/24), pure L2,
        # no address here, nothing routed in or out
        "30-vm-lab" = {
          matchConfig.Name = "vm-lab";
          networkConfig = {
            ConfigureWithoutCarrier = true;
            LinkLocalAddressing = "no";
          };
          linkConfig.RequiredForOnline = "no";
        };
      };
    };
  };

  networking = {
    nftables = {
      enable = true;
      # Clients reach sys-firewall and (through it) the outside, never each
      # other (from sys-net, where they were before)
      tables.client-isolation = {
        family = "bridge";
        content = ''
          chain forward {
            # priority 0 would be skipped: br_netfilter re-injects after its own hook (prio 0)
            type filter hook forward priority filter; policy accept;
            ${lib.optionalString lab ''
              # Lab: only frames from or to kali; the targets never reach
              # each other (ARP passes, IP does not). By MAC: the targets
              # are own VMs. No conntrack on the bridge, so a target could
              # also open connections to kali (kali offers no services)
              meta ibrname "vm-lab" ether type arp accept
              meta ibrname "vm-lab" ether saddr ${kaliLabMac} accept
              meta ibrname "vm-lab" ether daddr ${kaliLabMac} accept
              meta ibrname "vm-lab" drop
            ''}
            iifname "vif*" oifname "vif*" drop
          }
        '';
      };
    };
    firewall = {
      enable = true;
      # The resolver, for the VMs only
      interfaces.vm-fw = {
        allowedUDPPorts = [ 53 ];
        allowedTCPPorts = [ 53 ];
      };
      filterForward = true;
      extraForwardRules = ''
        # DNS only through the resolver here
        iifname "vm-fw" meta l4proto { tcp, udp } th dport 53 reject with icmpx type admin-prohibited
        # Registry `egress`: only the listed nets/ports, nothing else
        ${egressRules}
        # VMs -> outside only (not into the other client bridges)
        iifname "vm-fw" oifname != ${notClients} accept
        # Whonix-Gateway -> outside only (Tor); nothing gets in, see ct state below
        iifname "vm-whx-ext" oifname != ${notClients} accept
      ''
      + lib.optionalString lab ''
        # Lab: bridged frames stay on vm-lab (policy in the bridge table
        # above); only matters if br_netfilter hands them to this chain
        iifname "vm-lab" oifname "vm-lab" accept
        iifname "vm-lab" reject with icmpx type admin-prohibited
      ''
      + ''
        ct state established,related accept
      '';
    };
  };

  boot = {
    kernel.sysctl."net.ipv4.ip_forward" = 1;

    # Loaded at runtime (first bridge rule) these deadlocked with xenwatch
    # attaching new vifs in sys-net (xmg, 2026-10-16, Known Issues): load them
    # at boot
    kernelModules = [
      "nft_meta_bridge"
      "br_netfilter"
    ];

    # One queue per vif: with several (backend with >1 vCPU) part of the
    # connections of multi-queue guests stalled (sys-net, xmg 2026-10-11)
    extraModprobeConfig = ''
      options xen_netback max_queues=1
    '';
  };

  microvm = {
    hypervisor = "xen";
    # No PCI devices: PVH like sys-vpn
    xen.driverDomain = true;
    # Disposable (registry), no volume
    volumes = [ ];
    mem = 512;
    vcpu = 2;
  };

  environment.systemPackages = with pkgs; [
    iproute2
    dnsutils
    tcpdump
    nftables
  ];

  system.stateVersion = "26.05";
}

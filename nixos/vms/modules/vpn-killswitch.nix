# VPN killswitch (sys-vpn): clients behind `interface` reach the outside only
# through a tunnel interface (wg*/tun*), DNS only through the tunnel's
# resolver (dnsmasq). Tunnels are NetworkManager connections; a dispatcher
# script hands the tunnel's DNS servers to dnsmasq on up and takes them away
# on down. Tested by tests/sys-vpn-killswitch.nix.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.services.vpn-killswitch;

  # dnsmasq forwards only to the servers in this file: the tunnel's DNS,
  # written on tunnel up, emptied on tunnel down (no tunnel, no DNS)
  dnsServers = "/run/sys-vpn/dns-servers";

  # NetworkManager dispatcher: WireGuard connections are devices (up/down),
  # OpenVPN connections VPNs (vpn-up/vpn-down). Tunnel interfaces must be
  # named wg*/tun* (the killswitch rules below only forward to those).
  tunnelDns = pkgs.writeShellScript "sys-vpn-tunnel-dns" ''
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        config.systemd.package
      ]
    }
    iface="$1"
    action="$2"
    case "$iface" in
      wg* | tun*) ;;
      *) exit 0 ;;
    esac
    case "$action" in
      up | vpn-up)
        tmp="$(mktemp -p /run/sys-vpn)"
        for ns in ''${IP4_NAMESERVERS:-} ''${VPN_IP4_NAMESERVERS:-}; do
          echo "server=$ns@$iface"
        done > "$tmp"
        # mktemp makes it 0600; dnsmasq reads it as user dnsmasq
        chmod 0644 "$tmp"
        mv "$tmp" ${dnsServers}
        ;;
      down | vpn-down)
        : > ${dnsServers}
        ;;
      *) exit 0 ;;
    esac
    # dnsmasq re-reads its servers-file on SIGHUP
    systemctl kill -s HUP dnsmasq.service
  '';
in
{
  options.services.vpn-killswitch = {
    enable = lib.mkEnableOption "the VPN killswitch (clients only through wg*/tun*)";
    interface = lib.mkOption {
      type = lib.types.str;
      example = "vm-vpn";
      description = "Interface the clients come in on.";
    };
    clientNet = lib.mkOption {
      type = lib.types.str;
      example = "10.4.0.0/24";
      description = "Client network, masqueraded into the tunnels.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Resolver for the clients: only the tunnel's DNS servers, nothing from
    # the uplink
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        inherit (cfg) interface;
        bind-dynamic = true;
        no-resolv = true;
        no-hosts = true;
        servers-file = dnsServers;
      };
    };

    systemd.tmpfiles.rules = [
      "d /run/sys-vpn 0755 root root -"
      "f ${dnsServers} 0644 root root -"
    ];

    networking = {
      networkmanager = {
        enable = true;
        dispatcherScripts = [
          {
            source = tunnelDns;
            type = "basic";
          }
        ];
      };
      nftables = {
        enable = true;
        # Masquerade only into the tunnels; there is no NAT to the uplink
        tables.tunnel-nat = {
          family = "ip";
          content = ''
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              ip saddr ${cfg.clientNet} oifname "wg*" masquerade
              ip saddr ${cfg.clientNet} oifname "tun*" masquerade
            }
          '';
        };
      };
      firewall = {
        enable = true;
        # DNS for the clients (dnsmasq)
        interfaces.${cfg.interface} = {
          allowedUDPPorts = [ 53 ];
          allowedTCPPorts = [ 53 ];
        };
        filterForward = true;
        # Killswitch: clients -> tunnel only; without a tunnel nothing goes out
        extraForwardRules = ''
          iifname "${cfg.interface}" oifname "wg*" accept
          iifname "${cfg.interface}" oifname "tun*" accept
          iifname "${cfg.interface}" reject with icmpx type admin-prohibited
          ct state established,related accept
        '';
      };
    };

    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  };
}

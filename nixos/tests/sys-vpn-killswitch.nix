# Killswitch of sys-vpn (vms/modules/vpn-killswitch.nix) in a NixOS test:
# - server: stands in for the provider (Proton): WireGuard endpoint, DNS on
#   the tunnel, and the "internet" (10.99.0.1, also reachable directly)
# - gateway: the killswitch, uplink eth1 (vlan 1), clients on eth2 (vlan 2),
#   the tunnel is a NetworkManager WireGuard connection like in sys-vpn
# - client: default route and DNS via the gateway
# Tunnel up: client online with DNS; tunnel down: offline and no DNS,
# although the gateway itself still reaches 10.99.0.1 over its uplink.
# WireGuard keys are generated at test time.
# Run: nix build .#checks.x86_64-linux.sys-vpn-killswitch (TCG without KVM:
# slow)
{
  name = "sys-vpn-killswitch";

  nodes = {
    server =
      { pkgs, ... }:
      {
        virtualisation.vlans = [ 1 ];
        environment.systemPackages = [ pkgs.wireguard-tools ];
        networking.firewall.enable = false;
        services.nginx = {
          enable = true;
          virtualHosts.default = {
            default = true;
            locations."/".return = "200 'online'";
          };
        };
        # DNS of the provider: only on the tunnel address
        services.dnsmasq = {
          enable = true;
          resolveLocalQueries = false;
          settings = {
            listen-address = "10.66.0.1";
            bind-dynamic = true;
            no-resolv = true;
            address = "/internet.test/10.99.0.1";
          };
        };
      };

    gateway =
      { pkgs, ... }:
      {
        imports = [ ../vms/modules/vpn-killswitch.nix ];
        virtualisation.vlans = [
          1
          2
        ];
        services.vpn-killswitch = {
          enable = true;
          interface = "eth2";
          clientNet = "192.168.2.0/24";
        };
        # NetworkManager only runs the tunnel, like in sys-vpn
        networking.networkmanager.unmanaged = [
          "interface-name:eth0"
          "interface-name:eth1"
          "interface-name:eth2"
        ];
        # Default route over the uplink, like sys-vpn's via sys-net: the
        # killswitch, not a missing route, has to keep the clients off it.
        # The tunnel (AllowedIPs 0.0.0.0/0) takes over the default route
        networking.defaultGateway = {
          address = "192.168.1.3";
          interface = "eth1";
        };
        environment.systemPackages = [
          pkgs.wireguard-tools
          pkgs.curl
        ];
      };

    client =
      { pkgs, ... }:
      {
        virtualisation.vlans = [ 2 ];
        networking = {
          firewall.enable = false;
          defaultGateway = {
            address = "192.168.2.2";
            interface = "eth1";
          };
          nameservers = [ "192.168.2.2" ];
        };
        environment.systemPackages = [
          pkgs.curl
          pkgs.dnsutils
        ];
      };
  };

  testScript = ''
    start_all()
    for m in (server, gateway, client):
        m.wait_for_unit("multi-user.target")
    server.wait_for_unit("nginx.service")
    gateway.wait_for_unit("NetworkManager.service")
    gateway.wait_for_unit("dnsmasq.service")

    # Node addresses (alphabetical): client .1, gateway .2, server .3. The
    # "internet" (networking.interfaces.lo did not get it in the test VM)
    server.succeed("ip addr add 10.99.0.1/32 dev lo")
    # Route back to the clients: without the killswitch they would get out
    # over the uplink (checked by breaking the forward rules once, 2026-10-17)
    server.succeed("ip route add 192.168.2.0/24 via 192.168.1.2")
    gateway.succeed("ping -c1 -W5 192.168.1.3")
    gateway.succeed("curl -sf -m 5 http://10.99.0.1/ | grep -q online")
    client.succeed("ping -c1 -W5 192.168.2.2")

    # WireGuard: keys at test time, server by hand, gateway by NetworkManager
    server.succeed("wg genkey > /root/key && wg pubkey < /root/key > /root/pub")
    gateway.succeed("wg genkey > /root/key && wg pubkey < /root/key > /root/pub")
    server_pub = server.succeed("cat /root/pub").strip()
    gateway_pub = gateway.succeed("cat /root/pub").strip()
    server.succeed(
        "ip link add wg0 type wireguard",
        f"wg set wg0 private-key /root/key listen-port 51820 peer {gateway_pub} allowed-ips 10.66.0.2/32",
        "ip addr add 10.66.0.1/24 dev wg0",
        "ip link set wg0 up",
    )
    server.wait_until_succeeds("ss -lun | grep -q '10.66.0.1:53'")
    gateway.succeed(
        "printf '[Interface]\\nPrivateKey = %s\\nAddress = 10.66.0.2/24\\nDNS = 10.66.0.1\\n"
        f"[Peer]\\nPublicKey = {server_pub}\\nEndpoint = 192.168.1.3:51820\\nAllowedIPs = 0.0.0.0/0\\n"
        "PersistentKeepalive = 5\\n' \"$(cat /root/key)\" > /root/wg0.conf",
        "nmcli connection import type wireguard file /root/wg0.conf",
    )

    def tunnel_up():
        gateway.succeed("nmcli connection up wg0")
        gateway.wait_until_succeeds("grep -q 'server=10.66.0.1@wg0' /run/sys-vpn/dns-servers")

    def tunnel_down():
        gateway.succeed("nmcli connection down wg0")
        gateway.wait_until_succeeds("! test -s /run/sys-vpn/dns-servers")

    with subtest("tunnel up: client online, DNS through the tunnel"):
        tunnel_up()
        client.wait_until_succeeds("curl -sf -m 5 http://10.99.0.1/ | grep -q online", timeout=60)
        client.succeed("dig +short +time=3 +tries=1 internet.test @192.168.2.2 | grep -qx 10.99.0.1")

    with subtest("tunnel down: client offline and without DNS"):
        tunnel_down()
        # the gateway itself still reaches the internet over its uplink
        gateway.succeed("curl -sf -m 5 http://10.99.0.1/ | grep -q online")
        client.fail("curl -sf -m 5 http://10.99.0.1/")
        client.fail("dig +short +time=3 +tries=1 internet.test @192.168.2.2 | grep -q .")

    with subtest("tunnel up again: client online again"):
        tunnel_up()
        client.wait_until_succeeds("curl -sf -m 5 http://10.99.0.1/ | grep -q online", timeout=60)
  '';
}

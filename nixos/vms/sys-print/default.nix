# sys-print (C2, xen-migration.md "Drucken neu"): print driver domain without
# user data. App VMs send a document over RPC (`vm-print <printer> <file>`,
# vms/modules/vchan-relay.nix); dom0 asks, the `print` handler here creates a
# driverless queue (IPP Everywhere) for the given printer on first use and
# hands the job to CUPS. Network: uplink via sys-net, which only lets this VM
# reach private addresses on TCP 631 (vms/sys-net). Started on demand.
{ lib, pkgs, ... }:
let
  # First line of the stream: the printer's private IPv4 address, then the
  # document (PDF, PostScript, images, text: CUPS converts)
  printHandler = ''
    IFS= read -r printer || exit 1
    if ! [[ "$printer" =~ ^(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      echo "error: printer must be a private IPv4 address"
      exit 1
    fi
    queue="ipp-''${printer//./-}"
    if ! ${pkgs.cups}/bin/lpstat -p "$queue" >/dev/null 2>&1; then
      if ! out="$(${pkgs.cups}/bin/lpadmin -p "$queue" -E -v "ipp://$printer/ipp/print" -m everywhere 2>&1)"; then
        echo "error: no IPP Everywhere printer at $printer: $out"
        exit 1
      fi
    fi
    if out="$(${pkgs.cups}/bin/lp -d "$queue" -t "from $source" - 2>&1)"; then
      echo "ok: $out"
    else
      echo "error: $out"
      exit 1
    fi
  '';
in
{
  imports = [
    ../modules/net-config.nix
    ../modules/common-config.nix
  ];

  networking.hostName = "sys-print-vm";

  services = {
    net-config = {
      enable = true;
      index = 26;
      mac = "00:00:00:00:00:1a";
    };

    common-config = {
      enable = true;
      withDefaultPkgs = false;
    };

    # Local only: no sharing, no browsing (no mDNS, no cups-browsed)
    printing = {
      enable = true;
      listenAddresses = [ "localhost:631" ];
      browsing = false;
      defaultShared = false;
    };

    # Only `print`, no `copy` into this VM (vms/modules/vchan-relay.nix
    # enables the guest side)
    nox-rpc.guest.handlers = lib.mkForce { print = printHandler; };
  };

  # The handler runs as `user` and manages queues (CUPS SystemGroup)
  users.users.user.extraGroups = [ "lpadmin" ];

  microvm = {
    hypervisor = "xen";
    mem = 512;
    vcpu = 1;
  };

  system.stateVersion = "26.05";
}

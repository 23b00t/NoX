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

  # dom0's `nox printers`: stdin the networks to scan (CIDR per line, /22 to
  # /30, from sys-net's `lan`); every host with TCP 631 open (the only port
  # sys-net lets through) is asked for its IPP attributes. Answer `ok <n>`,
  # then one line per printer: address, name, model (tab-separated)
  printersHandler = ''
    if [ "$source" != dom0 ]; then
      echo "error: only dom0"
      exit 1
    fi
    PATH=${
      lib.makeBinPath [
        pkgs.bash
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnused
        pkgs.cups
      ]
    }
    hosts() {
      local a b c d len n size base i x
      [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 0
      a=''${BASH_REMATCH[1]} b=''${BASH_REMATCH[2]} c=''${BASH_REMATCH[3]} d=''${BASH_REMATCH[4]}
      len=''${BASH_REMATCH[5]}
      [ "$len" -ge 22 ] && [ "$len" -le 30 ] || return 0
      n=$(((a << 24) | (b << 16) | (c << 8) | d))
      size=$((1 << (32 - len)))
      base=$((n & ~(size - 1) & 0xffffffff))
      for ((i = 1; i < size - 1; i++)); do
        x=$((base + i))
        echo "$((x >> 24 & 255)).$((x >> 16 & 255)).$((x >> 8 & 255)).$((x & 255))"
      done
    }
    open="$(while IFS= read -r net; do hosts "$net"; done |
      xargs -r -P 64 -I {} bash -c 'timeout 1 bash -c "</dev/tcp/$0/631" 2>/dev/null && echo "$0"' {} |
      sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n)"
    attr() { sed -n "s/^ *$1 ([^)]*) = //p" <<<"$attrs" | head -n 1; }
    rows=()
    for ip in $open; do
      attrs="$(ipptool -T 3 -tv "ipp://$ip/ipp/print" \
        ${pkgs.cups}/share/cups/ipptool/get-printer-attributes.test 2>/dev/null)" || attrs=""
      name="$(attr printer-info)"
      [ -n "$name" ] || name="$(attr printer-name)"
      model="$(attr printer-make-and-model)"
      [ -n "$attrs" ] || model="(port 631 open, no IPP at /ipp/print)"
      rows+=("$(printf '%s\t%s\t%s' "$ip" "''${name:--}" "''${model:--}")")
    done
    echo "ok ''${#rows[@]}"
    [ "''${#rows[@]}" -eq 0 ] || printf '%s\n' "''${rows[@]}"
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

    # Only `print` (and dom0's `printers` scan and liveness `ping`), no
    # `copy` into this VM (vms/modules/vchan-relay.nix enables the guest side)
    nox-rpc.guest.handlers = lib.mkForce {
      print = printHandler;
      printers = printersHandler;
      ping = "echo ok";
    };
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

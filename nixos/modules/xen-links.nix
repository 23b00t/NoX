# Keeps the vifs served by driver domains connected (v2.8.1):
# - uplinks (backend sys-net, from each VM's net-config) and USB/IP links
#   (backend sys-usb, vms/usb-links.nix)
# - a vif is (re)attached when it is missing, hangs on an old backend domid
#   (driver domain restarted), reports hotplug errors, or is not connected
#   for `graceRounds` rounds
# - USB/IP links go to every Xen target VM (vms/usb-links.nix); which devices
#   a VM gets is up to vm-usb (modules/xen-usb.nix)
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  cfg = config.services.xen-links;
  usbLinks = import ../vms/usb-links.nix { inherit lib vmRegistry; };
  xen = config.virtualisation.xen.package;

  uplinks = lib.concatLists (
    lib.mapAttrsToList (
      _: vm:
      let
        guest = vm.config.config;
        net = guest.services.net-config or { };
      in
      lib.optional (guest.microvm.hypervisor == "xen" && (net.enable or false) && net.uplink.enable) {
        domain = guest.networking.hostName;
        inherit (net.uplink)
          mac
          bridge
          backend
          ;
      }
    ) config.microvm.vms
  );

  usbipLinks =
    map
      (vm: {
        domain = "${vm}-vm";
        mac = usbLinks.macOf vm;
        inherit (usbLinks) bridge;
        backend = usbLinks.domain;
      })
      (
        builtins.filter (
          vm: usbLinks.isTarget vm && config.microvm.vms.${vm}.config.config.microvm.hypervisor == "xen"
        ) (builtins.attrNames config.microvm.vms)
      );

  # "domain mac bridge backend" per line
  linkTable = pkgs.writeText "xen-links" (
    lib.concatMapStrings (l: "${l.domain} ${l.mac} ${l.bridge} ${l.backend}\n") (
      uplinks ++ usbipLinks ++ cfg.extraLinks
    )
  );

  xenLinks = pkgs.writeShellScript "xen-links" ''
    PATH=${
      lib.makeBinPath [
        xen
        pkgs.coreutils
        pkgs.gawk
      ]
    }
    declare -A notconnected

    while true; do
      while read -r dom mac bridge backend <&3; do
        key="$dom/$mac"
        domid="$(xl domid "$dom" 2>/dev/null)" || domid=""

        [ -n "$domid" ] || continue
        # Only domains that run: one being shut down or destroyed (state s,
        # c or d; `xl domid` still finds it) loses its vifs on the way, and
        # attaching new ones to it took the whole xmg down (steam with the
        # passed-through GPU, 2026-10-24)
        domstate="$(xl list "$dom" 2>/dev/null </dev/null | awk 'NR == 2 { print $5 }')"
        case "$domstate" in *s* | *c* | *d* | "") continue ;; esac
        bedomid="$(xl domid "$backend" 2>/dev/null)" || continue

        # Idx BE Mac handle state ...; state 4 = connected
        idx="" be="" state="" hotplug=""
        read -r idx be state < <(xl network-list "$dom" 2>/dev/null </dev/null \
          | awk -v mac="$mac" '$3 == mac { print $1, $2, $5 }')
        if [ -n "$idx" ]; then
          # The backend's hotplug script (vif-bridge there) reports here
          hotplug="$(xenstore-read "/local/domain/$be/backend/vif/$domid/$idx/hotplug-status" 2>/dev/null)"
        fi
        if [ -n "$idx" ] && [ "$state" = 4 ] && [ "$be" = "$bedomid" ] && [ "$hotplug" != error ]; then
          notconnected[$key]=0
          continue
        fi

        # Something to fix: the backend must be up (its bridge exists only
        # once its network is configured), otherwise the hotplug script
        # there fails. It writes data/backend-ready once xl devd runs.
        [ "$(xenstore-read "/local/domain/$bedomid/data/backend-ready" 2>/dev/null)" = 1 ] || continue

        if [ -n "$idx" ]; then
          if [ "$state" = 4 ]; then
            notconnected[$key]=0
          else
            notconnected[$key]=$(( ''${notconnected[$key]:-0} + 1 ))
          fi
          if [ "$be" != "$bedomid" ] || [ "$hotplug" = error ] \
            || [ "''${notconnected[$key]}" -ge ${toString cfg.graceRounds} ]; then
            echo "$dom: detaching stale vif $mac (backend $be, state $state, hotplug $hotplug)"
            timeout 30 xl network-detach "$dom" "$idx" </dev/null || true
            idx=""
          fi
        fi
        if [ -z "$idx" ]; then
          echo "$dom: attaching vif $mac (bridge $bridge, backend $backend)"
          timeout 30 xl network-attach "$dom" mac="$mac" bridge="$bridge" backend="$backend" </dev/null || true
          notconnected[$key]=0
        fi
      done 3< ${linkTable}
      sleep 5
    done
  '';
in
{
  options.services.xen-links = {
    enable = lib.mkEnableOption "keeping uplink and USB/IP vifs connected to their driver domains";

    graceRounds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 12;
      description = "Rounds (5 s each) a vif may stay unconnected before it is re-attached (guest boot).";
    };

    extraLinks = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.str);
      default = [ ];
      example = [
        {
          domain = "whonix-gateway-vm";
          mac = "00:00:00:00:02:1b";
          bridge = "vm-whx-ext";
          backend = "sys-net-vm";
        }
      ];
      description = "Further vifs to keep connected (domains not run by microvm.nix, see xen-image-domains).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.xen-links = {
      description = "Keep uplink and USB/IP vifs connected to their driver domains";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = xenLinks;
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}

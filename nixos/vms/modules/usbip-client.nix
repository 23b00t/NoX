# USB/IP client (v2.6, v2.8.3): every Xen target VM (vms/usb-links.nix) has
# the link to sys-usb (interface hot-plugged by dom0's xen-links) and
# `usbip-client`, which dom0's `vm-usb` calls over RPC to attach/detach the
# devices it assigns. VMs allowed to own a registry Bluetooth adapter get
# bluez and take over sys-usb's pairings on attach.
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  links = import ../usb-links.nix { inherit lib vmRegistry; };
  vmName = lib.removeSuffix "-vm" (config.networking.hostName or "");
  enable = links.isTarget vmName && config.microvm.hypervisor == "xen";
  bluetooth = builtins.elem vmName links.bluetoothVms;
  usbip = config.boot.kernelPackages.usbip;

  # Firmware of common USB Bluetooth adapters only (Realtek, Qualcomm, Intel,
  # MediaTek, Broadcom) instead of all of linux-firmware
  bluetoothFirmware = pkgs.runCommand "bluetooth-firmware" { } ''
    cd ${pkgs.linux-firmware}/lib/firmware
    mkdir -p $out/lib/firmware
    for f in rtl_bt qca intel/ibt-* mediatek/*BT* mediatek/*bt* brcm/*.hcd; do
      if [ -e "$f" ]; then cp -dR --no-preserve=mode --parents "$f" $out/lib/firmware/; fi
    done
  '';

  # `usbip port` lists imported devices as "... -> usbip://<server>:<port>/<busid>"
  # below their "Port NN:" line
  usbipClient = pkgs.writeShellScriptBin "usbip-client" ''
    set -u
    PATH=${
      lib.makeBinPath [
        usbip
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnutar
        pkgs.systemd
      ]
    }
    busid_ok() { [[ "$1" =~ ^[0-9]+-[0-9]+(\.[0-9]+)*$ ]]; }
    port_of() {
      usbip port 2>/dev/null | awk -v b="$1" '
        /^Port [0-9]+:/ { p = $2; sub(":", "", p) }
        /-> usbip:\/\// { n = split($NF, a, "/"); if (a[n] == b) print p }'
    }

    case "''${1:-}" in
      attach)
        # dom0 only asks when sys-usb has the device unused: an old port for
        # it is stale (sys-usb restarted)
        busid_ok "''${2:-}" || exit 2
        for p in $(port_of "$2"); do usbip detach -p "$p"; done
        usbip attach -r ${links.serverAddress} -b "$2"
        ;;
      detach)
        busid_ok "''${2:-}" || exit 2
        for p in $(port_of "$2"); do usbip detach -p "$p"; done
        ;;
      list)
        usbip port 2>/dev/null | awk '/-> usbip:\/\// { n = split($NF, a, "/"); print a[n] }'
        ;;
      ${lib.optionalString bluetooth ''
        bt-import)
          # sys-usb's pairings (tar on stdin), before the adapter arrives.
          # The archive comes from the driver domain: only directories and
          # regular files (no device nodes, links), no setuid bits
          tmp="$(mktemp)"
          trap 'rm -f "$tmp"' EXIT
          cat >"$tmp"
          if tar -tvf "$tmp" | awk 'substr($1, 1, 1) !~ /^[-d]$/ { bad = 1 } END { exit !bad }'; then
            echo "bt-import: archive holds other file types, refused" >&2
            exit 1
          fi
          install -d -m 0700 /var/lib/bluetooth
          # --skip-old-files: only devices the VM doesn't know yet; its own (newer)
          # pairing of a device is never overwritten by sys-usb's older one
          tar -C /var/lib/bluetooth --no-same-owner --no-same-permissions --skip-old-files -xf "$tmp" || exit 1
          systemctl restart bluetooth
          ;;
      ''}
      *)
        echo "usage: usbip-client attach|detach <busid> | list${lib.optionalString bluetooth " | bt-import"}" >&2
        exit 2
        ;;
    esac
  '';
in
{
  config = lib.mkIf enable (
    lib.mkMerge [
      {
        boot.kernelModules = [ "vhci-hcd" ];

        systemd.network.networks."22-usbip-link" = {
          matchConfig.MACAddress = links.macOf vmName;
          address = [ "${links.addressOf vmName}/${toString links.prefixLength}" ];
          networkConfig.ConfigureWithoutCarrier = true;
          linkConfig.RequiredForOnline = "no";
        };

        environment.systemPackages = [
          usbip
          usbipClient
        ];

        # dom0's vm-usb (modules/xen-usb.nix), no SSH: first line
        # `<usbip-client command> [busid]`, then `exit <rc>`; for `bt-import`
        # the rest of the stream is sys-usb's tar
        services.nox-rpc.guest.handlers.usbip = ''
          if [ "$source" != dom0 ]; then
            echo "error: only dom0"
            exit 1
          fi
          IFS= read -r line || exit 1
          read -ra args <<<"$line"
          if [ "''${args[0]:-}" = bt-import ]; then
            /run/wrappers/bin/sudo ${usbipClient}/bin/usbip-client bt-import
          else
            /run/wrappers/bin/sudo ${usbipClient}/bin/usbip-client "''${args[@]}" </dev/null
          fi
          echo "exit $?"
        '';
      }
      (lib.mkIf bluetooth {
        hardware.bluetooth.enable = true;
        hardware.firmware = [ bluetoothFirmware ];
        # dom0's waybar icon opens it where the adapter is (bt-manager,
        # modules/xen-usb.nix)
        services.blueman.enable = lib.mkDefault true;
        # Pairings survive a restart (steam: a gamepad knows one host and its
        # key, a pairing on tmpfs broke after every restart, 2026-10-26);
        # disposable VMs boot empty on purpose. sys-usb has its own volume
        microvm.volumes = lib.mkIf (!(vmRegistry.byName.${vmName}.disposable or false)) [
          {
            mountPoint = "/var/lib/bluetooth";
            image = "bluetooth.img";
            size = 64;
          }
        ];
      })
    ]
  );
}

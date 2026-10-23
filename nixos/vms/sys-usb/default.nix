# sys-usb (v2.6, v2.8.3): Xen HVM driver domain owning all USB controllers.
# Every device lands here; dom0's `vm-usb` exports single devices to VMs via
# USB/IP on the link bridge `vm-usbip` (usb-helper below), and the input
# proxy reads input devices from here (vms/usb-links.nix, modules/xen-usb.nix).
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  links = import ../usb-links.nix { inherit lib vmRegistry; };
  usbPciPaths = vmRegistry.hardware.pci.devicePaths.usb or [ ];
  mkPciDevice = path: {
    bus = "pci";
    inherit path;
  };
  usbip = config.boot.kernelPackages.usbip;

  # `usb-helper <command>`, called by dom0's vm-usb and input proxy over RPC
  # (as `user`, with sudo where root is needed). Arguments are checked
  # strictly; dom0 is the only caller.
  usbHelper = pkgs.writeShellScriptBin "usb-helper" ''
    set -u
    PATH=${
      lib.makeBinPath [
        usbip
        pkgs.coreutils
        pkgs.kmod
        pkgs.nftables
        pkgs.gnutar
        pkgs.gnugrep
      ]
    }
    busid_ok() { [[ "$1" =~ ^[0-9]+-[0-9]+(\.[0-9]+)*$ ]] && [ -f "/sys/bus/usb/devices/$1/idVendor" ]; }
    addr_ok() { [[ "$1" =~ ^10\.2\.0\.[0-9]{1,3}$ ]]; }

    case "''${1:-}" in
      list)
        # busid vendor:product status bluetooth name; status = usbip_status
        # (1 exported, 2 in use) or - (in sys-usb)
        for dev in /sys/bus/usb/devices/*; do
          b="''${dev##*/}"
          busid_ok "$b" || continue
          [ "$(<"$dev/bDeviceClass")" = 09 ] && continue # hubs
          status=-
          [ -f "$dev/usbip_status" ] && status="$(<"$dev/usbip_status")"
          bt=0
          for c in "$dev/bDeviceClass" "$dev/$b":*/bInterfaceClass; do
            [ "$(cat "$c" 2>/dev/null)" = e0 ] && bt=1
          done
          name="$(tr -c 'A-Za-z0-9._\n-' _ 2>/dev/null <"$dev/product")"
          echo "$b $(<"$dev/idVendor"):$(<"$dev/idProduct") $status $bt ''${name:-?}"
        done
        ;;
      bind)
        busid_ok "''${2:-}" || exit 2
        dev="/sys/bus/usb/devices/$2"
        [ -f "$dev/usbip_status" ] && exit 0
        # A UAS disk: uas has switched its interface to the UAS alternate
        # setting, usbip-host would pass it on like that, and the target VM
        # can only use usb-storage on alt 0 (vhci_hcd has no streams):
        # endpoint stalls, resets in a loop, 0 B (Samsung T7, 2026-10-22).
        # So ignore UAS for it from now on and let it come up again (alt 0,
        # usb-storage) before usbip-host takes it
        for i in "$dev/$2":*; do
          [ "$(basename "$(readlink -f "$i/driver" 2>/dev/null)")" = uas ] || continue
          vp="$(<"$dev/idVendor"):$(<"$dev/idProduct")"
          q=/sys/module/usb_storage/parameters/quirks
          modprobe usb-storage
          case ",$(<"$q")," in
            *",$vp:u,"*) ;;
            ",,") echo "$vp:u" >"$q" ;;
            *) echo "$(<"$q"),$vp:u" >"$q" ;;
          esac
          echo 0 >"$dev/authorized"
          sleep 1
          echo 1 >"$dev/authorized"
          # Wait until usb-storage has set it up (its block device is there):
          # taken away mid-setup, the disk's bulk-only state is broken and the
          # VM sees stalls again (bound after 26 ms, hp 2026-10-22)
          for _ in $(seq 40); do
            # (no compgen: this bash lacks programmable completion)
            blk=("$dev/$2":*/host*/target*/*/block/*)
            [ -e "''${blk[0]}" ] && break
            sleep 0.5
          done
          sleep 1
          break
        done
        usbip bind -b "$2"
        ;;
      unbind)
        # Also frees a device still "in use" by a vanished client
        busid_ok "''${2:-}" || exit 2
        if [ -f "/sys/bus/usb/devices/$2/usbip_status" ]; then
          usbip unbind -b "$2"
        fi
        ;;
      allow)
        addr_ok "''${2:-}" || exit 2
        nft add element inet usbip clients "{ $2 }"
        ;;
      deny)
        addr_ok "''${2:-}" || exit 2
        nft delete element inet usbip clients "{ $2 }" 2>/dev/null || true
        ;;
      allowed)
        nft list set inet usbip clients | grep -oE '10\.2\.0\.[0-9]+' || true
        ;;
      inputs)
        # eventN vendor:product busid of USB input devices (dom0's input proxy)
        for ev in /sys/class/input/event*; do
          p="$(readlink -f "$ev/device")"
          while [ -n "$p" ] && [ ! -f "$p/idVendor" ]; do p="''${p%/*}"; done
          [ -n "$p" ] || continue
          echo "''${ev##*/} $(<"$p/idVendor"):$(<"$p/idProduct") ''${p##*/}"
        done
        ;;
      bt-export)
        # Pairings, copied along with a Bluetooth adapter (one-way)
        tar -C /var/lib/bluetooth --exclude=./lost+found -cf - .
        ;;
      *)
        echo "usage: usb-helper list | bind|unbind <busid> | allow|deny <addr> | allowed | inputs | bt-export" >&2
        exit 2
        ;;
    esac
  '';

  # All USB input devices are readable by `user`; dom0's input proxy decides
  # what it forwards (registry whitelist or `vm-usb allow-input`)
  inputProxyRules = ''
    SUBSYSTEM=="input", KERNEL=="event*", SUBSYSTEMS=="usb", GROUP="input-proxy", MODE="0640"
  '';
in
{
  imports = [
    ../modules/net-config.nix
    ../modules/common-config.nix
    ../modules/yazi-config.nix
  ];

  networking.hostName = "sys-usb-vm";

  services = {
    net-config = {
      enable = true;
      index = 23;
      mac = "00:00:00:00:00:fc";
      interfaceName = "vm-lan";
    };

    common-config = {
      enable = true;
      withDefaultPkgs = false;
    };

    udev.extraRules = inputProxyRules;

    # dom0's vm-usb and input proxy (modules/xen-usb.nix), no SSH: first line
    # `<usb-helper command> [arg]`, answer on stdout, then `exit <rc>`;
    # `input eventN` streams the raw events, `bt-export` the tar (no status)
    nox-rpc.guest.handlers.usb = ''
      if [ "$source" != dom0 ]; then
        echo "error: only dom0"
        exit 1
      fi
      IFS= read -r line || exit 1
      read -ra args <<<"$line"
      case "''${args[0]:-}" in
        input)
          [[ "''${args[1]:-}" =~ ^event[0-9]+$ ]] || exit 2
          exec ${pkgs.coreutils}/bin/cat "/dev/input/''${args[1]}"
          ;;
        bt-export) exec /run/wrappers/bin/sudo ${usbHelper}/bin/usb-helper bt-export ;;
        *)
          /run/wrappers/bin/sudo ${usbHelper}/bin/usb-helper "''${args[@]}" </dev/null
          echo "exit $?"
          ;;
      esac
    '';

    dbus.enable = true;
    blueman.enable = true;
    pulseaudio = {
      enable = true;
      package = pkgs.pulseaudioFull;
      extraConfig = ''
        load-module module-switch-on-connect
      '';
    };
  };

  users.groups.input-proxy = { };
  users.users.user.extraGroups = lib.mkAfter [ "input-proxy" ];

  boot = {
    kernelModules = [
      "btusb"
      "btintel"
      "usbip-host"
    ];
    # MSI under a PV dom0 (as sys-net, 2026-10-12); with a PVH dom0 MSI-X
    # mapping fails for passthrough (v2.1), INTx (pci=nomsi) works there
    kernelParams = lib.optional (!(vmRegistry.hostProfile.dom0Pv or false)) "pci=nomsi";
  };

  # USB/IP link: VMs' vifs are added by the hotplug script (xl devd)
  systemd.network = {
    netdevs."20-${links.bridge}".netdevConfig = {
      Name = links.bridge;
      Kind = "bridge";
    };
    networks = {
      "30-${links.bridge}" = {
        matchConfig.Name = links.bridge;
        address = [ "${links.serverAddress}/${toString links.prefixLength}" ];
        networkConfig.ConfigureWithoutCarrier = true;
        linkConfig.RequiredForOnline = "no";
      };
      "10-vif" = {
        matchConfig.Name = "vif*";
        linkConfig.Unmanaged = true;
      };
    };
  };

  systemd.services.usbipd = {
    description = "USB/IP server (devices exported to other VMs)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${usbip}/bin/usbipd -4";
      Restart = "always";
    };
  };

  networking = {
    nftables = {
      enable = true;
      # VMs on the USB/IP link reach sys-usb, never each other
      tables.usbip-isolation = {
        family = "bridge";
        content = ''
          chain forward {
            # priority 0 would be skipped: br_netfilter re-injects after its own hook (prio 0)
            type filter hook forward priority filter; policy accept;
            iifname "vif*" oifname "vif*" drop
          }
        '';
      };
      # usbipd: new connections only from VMs that currently have a device
      # (set filled by dom0's vm-usb via usb-helper allow/deny)
      tables.usbip = {
        family = "inet";
        content = ''
          set clients {
            type ipv4_addr
          }
          chain input {
            type filter hook input priority filter - 10; policy accept;
            iifname "${links.bridge}" tcp dport ${toString links.port} ct state new ip saddr != @clients drop
          }
        '';
      };
    };
    firewall = {
      enable = true;
      # Narrowed further by table usbip
      extraInputRules = ''
        iifname "${links.bridge}" ip saddr ${links.network}/${toString links.prefixLength} tcp dport ${toString links.port} accept
      '';
    };
  };

  microvm = {
    hypervisor = "xen";
    xen = {
      # PCI passthrough with a PVH dom0 only works for HVM guests
      type = "hvm";
      driverDomain = true;
    };
    # Disposable (registry): no home volume, only the data volume below
    volumes = [
      {
        # Bluetooth pairings (vm-usb attach copies them to the target VM)
        mountPoint = "/var/lib/bluetooth";
        image = "bluetooth.img";
        size = 64;
      }
    ];
    devices = map mkPciDevice usbPciPaths;
    mem = 1024;
    vcpu = 1;
  };

  environment.systemPackages = with pkgs; [
    blueman
    bluez
    bluez-tools
    dbus
    dosfstools
    exfatprogs
    exfat
    ntfs3g
    parted
    udisks2
    usbutils
    util-linux
    usbip
    usbHelper
  ];

  security.polkit.enable = true;
  programs.dconf.enable = true;

  hardware.enableRedistributableFirmware = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Experimental = true;
        FastConnectable = true;
        Enable = "Source,Sink,Media,Socket";
      };
      Policy = {
        AutoEnable = true;
      };
    };
  };

  system.stateVersion = "26.05";
}

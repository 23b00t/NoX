# Role gaming: Steam in a gamescope session on the GPU passed through
# (`gpu = true`; PCI passthrough with a PV dom0 needs an HVM guest). Its own
# base, no common-config: the autologin on tty1 runs the session
# (nox.gaming.session, output in ~/session.log), sound over pipewire,
# Bluetooth for gamepads (`pad-pair`), keyboard and mouse over USB/IP from
# sys-usb (`nox usb attach <device> <vm>`). A registry `cpuPool` gives the VM
# its own CPUs while it runs (dom0/xen-dom0.nix).
#
# Steam is unfree: allowed here by name, so the VM needs an own store image
# or an unfree store group (roles/vm.nix asserts it). The GPU driver is the
# config's (NoX README "Gaming": the NVIDIA example).
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.nox.gaming;

  # Pairs gamepads without a keyboard (dom0: `nox exec <vm> pad-pair`). A
  # controller that paired with a console in between has lost its bond with
  # this machine: forget the controllers that are not connected, then pair
  # everything in pairing mode for 60 s (Just Works, no PIN; Steam's own
  # agent stays the only one)
  padPair = pkgs.writeShellApplication {
    name = "pad-pair";
    runtimeInputs = with pkgs; [
      bluez
      gawk
      gnugrep
    ];
    text = ''
      # DualShock 4, DualSense (and Xbox) controllers announce themselves so
      pads() { bluetoothctl devices | awk 'index($0, "Wireless Controller") { print $2 }'; }

      bluetoothctl power on >/dev/null
      for mac in $(pads); do
        if ! bluetoothctl info "$mac" | grep 'Connected: yes' >/dev/null; then
          bluetoothctl remove "$mac" >/dev/null
        fi
      done

      echo "pad-pair: hold PS + Share/Create until the light flashes (60 s, Ctrl+C ends)"
      bluetoothctl --timeout 60 scan on >/dev/null &
      scan=$!
      trap 'kill "$scan" 2>/dev/null || true' EXIT
      paired=0
      while kill -0 "$scan" 2>/dev/null; do
        for mac in $(pads); do
          bluetoothctl info "$mac" | grep 'Paired: yes' >/dev/null && continue
          echo "pad-pair: pairing $mac"
          if bluetoothctl --agent NoInputNoOutput pair "$mac" >/dev/null &&
            bluetoothctl trust "$mac" >/dev/null &&
            bluetoothctl connect "$mac" >/dev/null; then
            paired=$((paired + 1))
            echo "pad-pair: $mac connected"
          fi
        done
        sleep 1
      done
      echo "pad-pair: $paired controller(s) paired"
    '';
  };

  # The autologin is faster than the GPU's connectors (the driver comes up
  # ~2 s later): wait up to 15 s for a connected output, then gamescope
  # with Steam on it
  session = pkgs.writeShellScript "nox-gaming-session" ''
    for _ in $(seq 30); do
      for s in /sys/class/drm/card*-*/status; do
        [ "$(cat "$s" 2>/dev/null)" = connected ] && break 2
      done
      sleep 0.5
    done
    exec gamescope ${lib.escapeShellArgs cfg.gamescopeArgs} -- steam ${lib.escapeShellArgs cfg.steamArgs}
  '';
in
{
  options.nox.gaming = {
    session = lib.mkOption {
      type = lib.types.path;
      default = session;
      defaultText = lib.literalMD "gamescope with `gamescopeArgs`, then Steam with `steamArgs`, once an output is connected";
      description = "What the autologin on tty1 runs (output in ~/session.log). An own script e.g. for a profile per display (HDR on the TV).";
    };
    gamescopeArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "--steam"
        "--backend"
        "drm"
        "--adaptive-sync"
        "--mangoapp"
        "--immediate-flips"
      ];
      description = "gamescope's arguments in the default session.";
    };
    steamArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "-steamdeck"
        "-steamos3"
      ];
      description = "Steam's arguments in the default session (the Steam Deck UI).";
    };
  };

  config = {
    nox.unfree = [
      "steam"
      "steam-unwrapped"
    ];

    microvm.xen = {
      type = "hvm";
      # xl restarts the domain itself on a guest reboot, so a poweroff from
      # inside Steam ends the unit for good (dom0: Restart=on-failure for
      # gaming VMs, dom0/xen-dom0.nix)
      extraConfig = ''
        on_reboot = "restart"
      '';
    };

    # Keyboards come over USB/IP: Ctrl+Alt+Del meant for dom0 must not
    # reboot the VM (as in common-config)
    systemd.ctrlAltDelUnit = "/dev/null";

    boot.loader = {
      systemd-boot.enable = lib.mkDefault true;
      efi.canTouchEfiVariables = lib.mkDefault true;
      grub.enable = lib.mkForce false;
    };

    services = {
      # Its own base: the gamescope session on tty1
      common-config.enable = false;
      getty.autologinUser = "user";
      seatd = {
        enable = true;
        group = "seat";
      };
      dbus.enable = true;
      upower.enable = true;
      # No blueman: gamepads pair in Steam's own Bluetooth dialog (its agent;
      # blueman-applet would register a second one) or with pad-pair
      blueman.enable = false;
      pulseaudio.enable = false;
      pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
      };
    };

    hardware = {
      graphics = {
        enable = lib.mkDefault true;
        enable32Bit = lib.mkDefault true;
      };
      bluetooth = {
        enable = lib.mkDefault true;
        settings.General = {
          AutoEnable = true;
          FastConnectable = true;
        };
      };
    };

    programs = {
      gamescope.enable = true;
      steam = {
        enable = true;
        remotePlay.openFirewall = lib.mkDefault true;
        localNetworkGameTransfers.openFirewall = lib.mkDefault true;
        gamescopeSession.enable = true;
      };
      gamemode.enable = true;
    };

    security = {
      # Steam's pressure-vessel runtime
      wrappers.bwrap = {
        source = "${pkgs.bubblewrap}/bin/bwrap";
        owner = "root";
        group = "root";
        setuid = true;
      };
      sudo = {
        enable = true;
        wheelNeedsPassword = false;
      };
      rtkit.enable = true;
    };

    environment = {
      loginShellInit = ''
        if [[ "$(tty)" = "/dev/tty1" ]]; then
          exec ${cfg.session} &> "$HOME/session.log"
        fi
      '';
      systemPackages = with pkgs; [
        mangohud
        pciutils
        btop
        padPair
      ];
      etc."MangoHud/MangoHud.conf".text = ''
        fps
        frametime
        frame_timing
        gpu_stats
        gpu_temp
        gpu_power
        vram
        position=top-left
        font_size=24
        background_alpha=0.35
      '';
    };

    systemd.tmpfiles.rules = [
      "d /home/user/.config 0755 user users - -"
      "d /home/user/.config/MangoHud 0755 user users - -"
      "L+ /home/user/.config/MangoHud/MangoHud.conf - - - - /etc/MangoHud/MangoHud.conf"
    ];

    networking.networkmanager = {
      enable = true;
      settings.main.no-auto-default = "*";
    };

    users = {
      groups.users = { };
      groups.seat = { };
      users.user = {
        isNormalUser = true;
        group = "users";
        extraGroups = [
          "wheel"
          "video"
          "render"
          "input"
          "seat"
        ];
      };
    };
  };
}

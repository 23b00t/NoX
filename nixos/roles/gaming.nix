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
  vmRegistry,
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
    exec gamescope ${lib.escapeShellArgs cfg.gamescopeArgs} -- nox-gaming-splash steam ${lib.escapeShellArgs cfg.steamArgs}
  '';

  # The fleet's theme (registry nox.theme), the same as dom0's desktop
  theme = import ../desktop/theme.nix {
    inherit lib;
    inherit (vmRegistry) theme;
  };

  # Steam's start can take minutes (self-update, unpacking) and the session
  # shows nothing meanwhile: `nox-gaming-splash steam …` runs Steam with its
  # output in ~/session.log and shows a fullscreen xterm with the phases and
  # the update progress until Steam's window is there. The screen reads a log
  # file, not a FIFO: without a reader a FIFO would kill Steam with SIGPIPE.
  # Without DISPLAY (no gamescope) it just runs the command.
  splash = pkgs.writeShellApplication {
    name = "nox-gaming-splash";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      procps
      xterm
      xwininfo
    ];
    text = ''
      export SPLASH_BG=${theme.raw.bgDark} SPLASH_FG=${theme.raw.fg}
      export SPLASH_ACCENT=${theme.raw.accent} SPLASH_ACCENT2=${theme.raw.accent2}
      export SPLASH_MUTED=${theme.raw.muted} SPLASH_OK=${theme.raw.ok}
      export SPLASH_WARN=${theme.raw.warn} SPLASH_URGENT=${theme.raw.urgent}

      # nox-gaming-splash <steam command...>
      # Runs the command (Steam) with its output in ~/session.log and in a private
      # log, and shows a fullscreen xterm with progress until Steam's window is up.
      # Colors come in as SPLASH_* hex values (the fleet theme), without '#'.

      rgb() { printf '\033[38;2;%d;%d;%dm' "0x''${1:0:2}" "0x''${1:2:2}" "0x''${1:4:2}"; }

      # ---------------------------------------------------------------- the screen
      ui() {
        local dir=$1 log=$1/steam.log
        local c_fg c_acc c_acc2 c_mut c_ok c_warn c_err rst=$'\033[0m' bold=$'\033[1m'
        c_fg=$(rgb "$SPLASH_FG")
        c_acc=$(rgb "$SPLASH_ACCENT")
        c_acc2=$(rgb "$SPLASH_ACCENT2")
        c_mut=$(rgb "$SPLASH_MUTED")
        c_ok=$(rgb "$SPLASH_OK")
        c_warn=$(rgb "$SPLASH_WARN")
        c_err=$(rgb "$SPLASH_URGENT")

        # phase state: 0 = waiting, 1 = running, 2 = done
        local -a names=("Display" "Network" "Steam update" "Unpacking" "Steam starts")
        local -a st=(2 0 0 0 0)
        local pct=-1 kb_done="" kb_total="" last="" lines_seen=0
        local started=$SECONDS up_since=-1 failed=0 final=""
        local -a spin=("|" "/" "-" "\\") tail_buf=("" "" "")
        local i=0 line

        # Steam's lines end in \r or \n, depending on the stage
        exec 3< <(tail -n +1 -F "$log" 2>/dev/null | stdbuf -o0 tr '\r' '\n')

        advance() { # phase index: everything before is done, this one runs
          local n=$1 k
          for ((k = 0; k < n; k++)); do st[k]=2; done
          ((st[n] == 2)) || st[n]=1
        }

        parse() {
          local l=$1 num
          [[ -n "''${l//[[:space:]]/}" ]] || return 0
          last=$l
          lines_seen=$((lines_seen + 1))
          tail_buf=("''${tail_buf[1]}" "''${tail_buf[2]}" "$l")
          if [[ $l =~ \[\ *([0-9]+)%\] ]]; then
            pct=''${BASH_REMATCH[1]}
          fi
          if [[ $l =~ \(([0-9][0-9,.\ ]*)\ of\ ([0-9][0-9,.\ ]*)\ ?[Kk][Bb]\) ]]; then
            num=''${BASH_REMATCH[1]//[^0-9]/}
            kb_done=$num
            num=''${BASH_REMATCH[2]//[^0-9]/}
            kb_total=$num
          fi
          case ''${l,,} in
            *"checking for available"*) advance 1 ;;
            *"downloading update"* | *"verifying installation"* | *"downloading"*)
              advance 2
              ;;
            *"extracting"* | *"installing"* | *"unpacking"*) advance 3 ;;
            *"update complete"* | *"verification complete"* | *"launching steam"* | *"running steam"*)
              advance 4
              ;;
          esac
        }

        # The window: steamwebhelper runs and an X window named Steam exists, or
        # steamwebhelper has run for 15 s (the window's name is not known for sure)
        window_up() {
          pgrep -x steamwebhelper >/dev/null || return 1
          if ((up_since < 0)); then up_since=$SECONDS; fi
          if xwininfo -root -tree 2>/dev/null | grep -E '^ +0x[0-9a-f]+ "(Steam|Steam Big Picture Mode|Steam Deck)[^"]*"' >/dev/null; then
            return 0
          fi
          ((SECONDS - up_since >= 15))
        }

        bar() { # width pct
          local w=$1 p=$2 f k out=""
          f=$((w * p / 100))
          for ((k = 0; k < w; k++)); do
            if ((k < f)); then out+="█"; else out+="░"; fi
          done
          printf '%s' "$out"
        }

        local -a logo=(
          "███╗   ██╗ ██████╗ ██╗  ██╗"
          "████╗  ██║██╔═══██╗╚██╗██╔╝"
          "██╔██╗ ██║██║   ██║ ╚███╔╝ "
          "██║╚██╗██║██║   ██║ ██╔██╗ "
          "██║ ╚████║╚██████╔╝██╔╝ ██╗"
          "╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝"
        )
        local -a pad=(
          "   ______________   "
          "  /  _  .  ( )   \\  "
          " |  (_) +  (_)  _  | "
          " |_/ \\_______/ \\_|  "
        )

        local cols margin k mark col elapsed text w spinch out lm
        printf '\033[?25l\033[2J'
        trap 'printf "\033[?25h\033[0m"' EXIT

        while :; do
          # read what Steam printed since the last round (200 ms at most)
          while IFS= read -r -t 0.2 -u 3 line; do parse "$line"; done || true

          if [[ -e $dir/status ]]; then
            # drain once more, then stay on the screen
            while IFS= read -r -t 0.3 -u 3 line; do parse "$line"; done || true
            failed=1
            final="Steam ended (exit $(cat "$dir/status"))"
          elif ((SECONDS - started >= 2)) && window_up; then
            st=(2 2 2 2 2)
            final="ok"
          fi
          if ((st[4] == 0)) && pgrep -x steamwebhelper >/dev/null; then advance 4; fi

          read -r _ cols < <(stty size 2>/dev/null || echo "40 120")
          margin=$(((cols - 40) / 2))
          ((margin < 2)) && margin=2
          w=$((cols - 2 * margin))
          ((w > 70)) && w=70
          ((w < 20)) && w=20
          elapsed=$((SECONDS - started))
          spinch=''${spin[i % 4]}
          i=$((i + 1))

          out=$'\033[H'
          emit() { out+=$'\033[K'"$1"$'\n'; }
          sp() { printf '%*s' "$1" ""; }
          lm=$(sp $(((cols - 28) / 2)))
          emit ""
          emit ""
          for k in 0 1 2 3 4 5; do emit "$lm$bold$c_acc''${logo[k]}$rst"; done
          emit "$lm$c_acc2//$rst $c_fg''${bold}s t e a m$rst"
          emit ""
          lm=$(sp $(((cols - 22) / 2)))
          for k in 0 1 2 3; do emit "$lm$c_mut''${pad[k]}$rst"; done
          emit ""
          lm=$(sp $margin)
          for k in 0 1 2 3 4; do
            case ''${st[k]} in
              2) mark="''${c_ok}✔$rst"; col=$c_fg ;;
              1) mark="''${c_warn}''${spin[i % 4]}$rst"; col=$bold$c_fg ;;
              *) mark="''${c_mut}·$rst"; col=$c_mut ;;
            esac
            if ((failed && st[k] == 1)); then mark="''${c_err}✘$rst"; fi
            emit "$lm $mark  $col''${names[k]}$rst"
          done
          emit ""
          if ((pct >= 0)); then
            text="$pct %"
            [[ -n $kb_total ]] && text+="   $((kb_done / 1024)) of $((kb_total / 1024)) MB"
            emit "$lm$c_acc$(bar "$w" "$pct")$rst"
            emit "$lm$c_fg$text$rst"
          else
            emit "$lm$c_mut$(bar "$w" 0)$rst"
            emit "$lm''${c_mut}waiting for Steam ...$rst"
          fi
          emit ""
          if ((failed)); then
            emit "$lm$bold$c_err$final$rst"
            emit "$lm''${c_mut}Last lines of Steam (full log: ~/session.log), Ctrl+C closes this screen:$rst"
            for k in 0 1 2; do emit "$lm$c_fg''${tail_buf[k]:0:$w}$rst"; done
          else
            emit "$lm$c_acc2$spinch$rst  ''${c_fg}''${elapsed} s$rst"
            emit "$lm$c_mut''${last:0:$w}$rst"
          fi
          printf '%s\033[J' "$out"

          if [[ $final == ok ]]; then break; fi
          if ((failed)); then
            # stay until a key (the pad's keyboard) or 10 minutes
            read -r -n1 -t 600 || true
            break
          fi
        done
      }

      # ------------------------------------------------------------------ wrapper
      if [[ ''${1:-} == --ui ]]; then
        ui "$2"
        exit 0
      fi

      if (($# == 0)); then
        echo "usage: nox-gaming-splash <command> [args...]" >&2
        exit 2
      fi

      dir=$(mktemp -d "''${XDG_RUNTIME_DIR:-/tmp}/nox-splash.XXXXXX")
      trap 'rm -rf "$dir"' EXIT
      : >"$dir/steam.log"

      # Steam: stdout/stderr go to our own stdout (~/session.log) and to the log
      # the screen reads. A file instead of a FIFO: when the screen is gone, a
      # FIFO's writer would die of SIGPIPE (and Steam with it).
      {
        set +e
        "$@" 2>&1
        echo $? >"$dir/status"
      } | tee -a "$dir/steam.log" &
      steam=$!

      xpid=""
      if [[ -n ''${DISPLAY:-} ]]; then
        xterm -fullscreen -T "nox-gaming-splash" -fa monospace -fs "''${SPLASH_FONT_SIZE:-26}" \
          -bg "#$SPLASH_BG" -fg "#$SPLASH_FG" -b 0 +sb -xrm 'XTerm*cursorBlink: false' \
          -e "$0" --ui "$dir" &
        xpid=$!
      fi

      wait "$steam" || true
      if [[ -n $xpid ]]; then wait "$xpid" || true; fi
      exit "$(cat "$dir/status" 2>/dev/null || echo 1)"
    '';
  };
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

    # The splash screen's xterm needs a font
    fonts.packages = [ pkgs.dejavu_fonts ];

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
        splash
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

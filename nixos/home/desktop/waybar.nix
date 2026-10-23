{
  pkgs,
  lib,
  config,
  ...
}:
let
  theme = import ./theme.nix { inherit lib; };

  # Taskbar icons for VM windows: their app ids carry "[<vm>] " (wprsc
  # --app-id-prefix), which the taskbar can't resolve. Map the known apps
  # back, from the desktop entries `vm-run <vm> <binary>`
  # (home/vm-management/desktop-entries.nix): "[<vm>] <binary>" → its icon,
  # plus the VM terminals "[<vm>] term-<vm>". Other apps get the default icon
  appIdMapping = lib.listToAttrs (
    lib.concatLists (
      lib.mapAttrsToList (
        _: entry:
        let
          words = lib.splitString " " (entry.exec or "");
          vm = builtins.elemAt words 1;
          binary = baseNameOf (builtins.elemAt words 2);
          icon = if entry.icon or null != null then toString entry.icon else binary;
        in
        lib.optionals (builtins.length words >= 3 && builtins.head words == "vm-run") (
          map (id: lib.nameValuePair "[${vm}] ${id}" icon) (
            lib.unique [
              binary
              (lib.toLower binary)
            ]
          )
          ++ [ (lib.nameValuePair "[${vm}] term-${vm}" "foot") ]
        )
      ) config.xdg.desktopEntries
    )
    # Xwayland windows: the X11 class is the app id (our wprs fork); Burp
    # in kali (Java: main class, StartupWMClass of Kali's desktop entry)
    ++ [ (lib.nameValuePair "[kali] burp-StartBurp" "kali-burpsuite") ]
  );
in
{
  home.packages = with pkgs; [
    waybar # system bar
  ];

  home.file = {
    ".config/waybar/style.css" = {
      text = ''
        /* Colors from home/desktop/theme.nix */
        @define-color bar-bg alpha(${theme.color.shadow}, ${toString theme.opacity.bar});
        @define-color main-bg alpha(${theme.color.bg}, ${toString theme.opacity.surface});
        @define-color main-fg ${theme.color.fg};
        @define-color wb-act-bg ${theme.color.accent};
        @define-color wb-act-fg ${theme.color.fgActive};
        @define-color wb-hvr-bg ${theme.color.accent2};
        @define-color popup-bg ${theme.color.bgDark};
        @define-color popup-br ${theme.color.border};
        @define-color urgent ${theme.color.urgent};
        @define-color warn ${theme.color.warn};
        @define-color ok ${theme.color.ok};
        @define-color muted ${theme.color.muted};

        * {
          font-family: "${theme.font.family}", "Symbols Nerd Font";
          font-size: ${toString theme.font.barSize}px;
          font-weight: 500;
          border-radius: ${toString theme.radiusInner}px;
          min-height: 0;
        }

        window#waybar {
          background-color: @bar-bg;
          color: @main-fg;
          border-radius: ${toString theme.radius}px;
        }

        window#waybar.hidden {
          opacity: 0.0;
        }

        #workspaces {
          margin: 0 4px;
        }

        #workspaces button {
          padding: 0 8px;
          margin: 0 2px;
          background-color: alpha(@main-fg, 0.10);
          color: @main-fg;
          border-radius: ${toString theme.radiusInner}px;
          transition: background-color 0.2s ease, color 0.2s ease;
        }

        #workspaces button.active,
        #workspaces button.focused {
          background: linear-gradient(135deg, @wb-hvr-bg, @wb-act-bg);
          color: @wb-act-fg;
        }

        #workspaces button.urgent {
          background-color: @urgent;
          color: @main-bg;
        }

        #clock,
        #battery,
        #pulseaudio,
        #pulseaudio.microphone,
        #custom-xen-mem,
        #custom-xen-cpu,
        #backlight,
        #tray,
        #custom-bluetooth,
        #custom-swaync,
        #custom-cputemp {
          padding: 0 10px;
          margin: 0 1px;
          background-color: @main-bg;
          color: @main-fg;
          border-radius: ${toString theme.radiusInner}px;
        }

        #tray menu {
          background-color: @popup-bg;
          color: @main-fg;
          border-radius: ${toString theme.radiusInner}px;
          border: 1px solid @popup-br;
        }

        #battery.charging,
        #battery.plugged {
          color: @ok;
        }

        #battery.warning {
          color: @warn;
        }

        #battery.critical {
          color: @urgent;
        }

        #pulseaudio.muted {
          color: @muted;
        }

        tooltip {
          background: @popup-bg;
          color: @main-fg;
          border-radius: ${toString theme.radiusInner}px;
          border: 1px solid @popup-br;
        }

        tooltip label {
          padding: 4px 8px;
        }
      '';
      force = true;
    };

    # CPU-Temp-Script
    ".config/waybar/scripts/cputemp.sh" = {
      text = ''
        #!/usr/bin/env bash
        # CPU sensor from sysfs: coretemp (Intel, temp1 = package) or k10temp
        # (AMD); under a PV dom0 coretemp may be missing, then the ACPI zone
        temp_int=""
        for want in coretemp k10temp zenpower acpitz; do
          for h in /sys/class/hwmon/hwmon*; do
            if [[ "$(cat "$h/name" 2>/dev/null)" == "$want" && -r "$h/temp1_input" ]]; then
              temp_int=$(( $(cat "$h/temp1_input") / 1000 ))
              break 2
            fi
          done
        done
        if [[ -z "$temp_int" ]]; then
          echo "?"
          exit 0
        fi
        temp="$temp_int"
        if [[ $temp_int -ge 85 ]]; then
          color="${theme.color.urgent}"
        elif [[ $temp_int -ge 76 ]]; then
          color="${theme.color.warn}"
        else
          color="${theme.color.fg}"
        fi
        echo "<span color=\"$color\">$temp°C</span>"
      '';
      executable = true;
      force = true;
    };

    # Battery notification script
    ".config/waybar/scripts/battery-notify.sh" = {
      text = ''
        #!/usr/bin/env bash

        bat_dir=""
        for candidate in /sys/class/power_supply/BAT*; do
          if [[ -r "$candidate/capacity" && -r "$candidate/status" ]]; then
            bat_dir="$candidate"
            break
          fi
        done

        [[ -n "$bat_dir" ]] || exit 0

        capacity=$(<"$bat_dir/capacity")
        status=$(<"$bat_dir/status")

        # Exit if not discharging
        if [[ "$status" != "Discharging" ]]; then
          exit 0
        fi

        if [[ "$capacity" -le 20 ]]; then
          notify-send -u critical "Battery critical" "Battery level is $capacity%. Please plug in."
        elif [[ "$capacity" -le 40 ]]; then
          notify-send -u normal "Battery low" "Battery level is $capacity%."
        fi
      '';
      executable = true;
      force = true;
    };

    ".config/waybar/config.jsonc" = {
      text = ''
        {
          // Global bar options
          "layer": "top",
          "position": "top",
          "height": 30,
          "margin-left": 8,
          "margin-right": 8,
          "margin-top": 4,
          "spacing": 6,
          "reload_style_on_change": true,

          // Layout without external JSONC modules/includes
          "modules-left": [
            "wlr/taskbar"
          ],
          "modules-center": [
            "custom/xen-mem",
            "custom/xen-cpu",
            "custom/cputemp",
            "clock"
          ],
          "modules-right": [
            "backlight",
            "tray",
            "custom/bluetooth",
            "pulseaudio",
            "pulseaudio#microphone",
            "battery",
            "custom/swaync",
          ],

          "wlr/taskbar": {
            "format": "{icon}",
            "icon-size": 16,
            "markup": false,
            "on-click": "activate",
            "on-click-middle": "close",
            "ignore-list": [],
            "app_ids-mapping": ${builtins.toJSON appIdMapping}
          },

          "clock": {
            "format": "{:%H:%M   %a, %d.%m.%y}",
            "format-alt": "{:%H:%M}",
            "tooltip-format": "<tt><small>{calendar}</small></tt>",
            "calendar": {
              "mode"          : "year",
              "mode-mon-col"  : 3,
              "weeks-pos"     : "right",
              "on-scroll"     : 1,
              "on-click-right": "mode",
              "format": {
                "months":     "<span color='${theme.color.accent}'><b>{}</b></span>",
                "days":       "<span color='${theme.color.fg}'><b>{}</b></span>",
                "weeks":      "<span color='${theme.color.fgActive}'><b>W{}</b></span>",
                "weekdays":   "<span color='${theme.color.warn}'><b>{}</b></span>",
                "today":      "<span color='${theme.color.urgent}'><b><u>{}</u></b></span>"
              }
            },
            "actions": {
              "on-click-right": "mode",
              "on-click-forward": "tz_up",
              "on-click-backward": "tz_down",
              "on-scroll-up": "shift_up",
              "on-scroll-down": "shift_down"
            }
          },

          // Whole machine (all Xen domains), from the xen-stats service in dom0
          "custom/xen-mem": {
            "format": " {}",
            "return-type": "json",
            "exec": "cat /run/xen-stats/mem",
            "interval": 30
          },

          "custom/xen-cpu": {
            "format": " {}",
            "return-type": "json",
            "exec": "cat /run/xen-stats/cpu",
            "interval": 5
          },

          "backlight": {
            "format": " {percent}%",
            "on-scroll-up": "brightnessctl set +5%",
            "on-scroll-down": "brightnessctl set 5%-"
          },

          "pulseaudio": {
            "format": "{icon} {volume}%",
            "format-muted": " mute",
            "on-click": "pavucontrol",
            "scroll-step": 5,
            "format-icons": {
              "default": ["", "", ""]
            }
          },

          "pulseaudio#microphone": {
            "format": "{format_source}",

            "format-source": "{volume}%",
            "format-source-muted": " mute",
          },

          "battery": {
            "states": {
              "good": 80,
              "warning": 40,
              "critical": 20
            },
            "format": "{icon} {capacity}%",
            "format-charging": " {capacity}%",
            "format-plugged": " {capacity}%",
            "format-alt": "{time} remaining",
            "interval": 30,
            "tooltip": true,
            "format-icons": ["", "", "", "", ""],
            "events": {
              "on-discharging-warning": "~/.config/waybar/scripts/battery-notify.sh",
              "on-discharging-critical": "~/.config/waybar/scripts/battery-notify.sh"
            }
          },

          "tray": {
            "icon-size": 16,
            "spacing": 8
          },

          "custom/bluetooth": {
            "format": "",
            "tooltip": false,
            "exec": "echo ",
            "interval": 3600,
            "on-click": "vm-run su dbus-run-session -- blueman-manager"
          },


          "custom/swaync": {
            "format": "",
            "tooltip": "Notifications",
            "on-click": "swaync-client -t"
          },

          "custom/cputemp": {
            "format": " {}",
            "tooltip": true,
            "exec": "~/.config/waybar/scripts/cputemp.sh",
            "interval": 5,
          },
        }
      '';
      force = true;
    };
  };
}

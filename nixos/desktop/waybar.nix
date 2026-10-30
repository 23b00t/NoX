{
  pkgs,
  lib,
  config,
  ...
}:
let
  theme = import ./theme.nix {
    inherit lib;
    inherit (config.nox.desktop) theme;
  };
in
{
  environment.systemPackages = with pkgs; [
    waybar # system bar
  ];

  environment.etc = {
    "xdg/waybar/style.css" = {
      text = ''
        /* Colors from desktop/theme.nix */
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
        #custom-xen-mem,
        #custom-xen-cpu,
        #backlight,
        #tray,
        #custom-bluetooth,
        #custom-vm-mic,
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

        /* the VMs may record (nox mic on) */
        #custom-vm-mic.on {
          color: @urgent;
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
    };

    # CPU-Temp-Script
    "xdg/waybar/scripts/cputemp.sh" = {
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
      mode = "0755";
    };

    # Battery notification script
    "xdg/waybar/scripts/battery-notify.sh" = {
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
      mode = "0755";
    };

    "xdg/waybar/config.jsonc" = {
      text = ''
        {
          // Global bar options
          "layer": "top",
          "position": "top",
          "height": 28,
          "margin-left": 8,
          "margin-right": 8,
          "margin-top": 4,
          "spacing": 6,
          "reload_style_on_change": true,

          // Layout without external JSONC modules/includes
          "modules-left": [
            "niri/workspaces"
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
            "custom/vm-mic",
            "battery",
            "custom/swaync",
          ],

          // Workspaces instead of one icon per window; empty ones stay hidden.
          // Numbers only, also for named ones (the terminal workspace)
          "niri/workspaces": {
            "format": "{index}"
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

          // Whether the VMs may record (nox mic, NoX dom0/vm-audio.nix); click: off
          "custom/vm-mic": {
            "return-type": "json",
            "exec": "systemctl --user is-active --quiet nox-pulse-mic.service && echo '{\"text\": \" VM\", \"class\": \"on\", \"tooltip\": \"VMs may record: click to stop (nox mic off)\"}' || echo '{\"text\": \" off\", \"tooltip\": \"VMs may not record (nox mic on)\"}'",
            "interval": 3,
            "on-click": "nox mic off"
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
              "on-discharging-warning": "/etc/xdg/waybar/scripts/battery-notify.sh",
              "on-discharging-critical": "/etc/xdg/waybar/scripts/battery-notify.sh"
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
            "on-click": "bt-manager"
          },


          "custom/swaync": {
            "format": "",
            "tooltip": "Notifications",
            "on-click": "swaync-client -t"
          },

          "custom/cputemp": {
            "format": " {}",
            "tooltip": true,
            "exec": "/etc/xdg/waybar/scripts/cputemp.sh",
            "interval": 5,
          },
        }
      '';
    };
  };

  # waybar as a user service of the graphical session (niri), not niri's
  # spawn-at-startup: `systemctl --user restart waybar` reloads it, and it
  # comes back after a crash
  systemd.user.services.waybar = {
    description = "Waybar (status bar)";
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    # The modules' on-click/on-scroll commands (brightnessctl,
    # swaync-client, pavucontrol, bt-manager) come from the system profile;
    # a NixOS unit's PATH would only hold coreutils & co.
    path = [
      "/run/wrappers"
      "/run/current-system/sw"
    ];
    serviceConfig = {
      ExecStart = "${pkgs.waybar}/bin/waybar";
      Restart = "on-failure";
      RestartSec = 1;
    };
  };
}

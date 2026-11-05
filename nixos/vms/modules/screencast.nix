# VM side of screen sharing (registry `screenShare`, wprs VMs; dom0 side:
# dom0/screencast.nix). Apps ask xdg-desktop-portal for a screen; the
# ScreenCast backend `nox` (nox-screencast-portal) asks dom0 over the relay
# service `screencast` (socket below, vchan-relay.nix), dom0 picks in rofi
# and sends H.264; the receiver offers it as a PipeWire video source, whose
# node the app gets.
#
# Portals hand over file descriptors, which dom0's relayed bus can't carry:
# the apps use the VM's own session bus (vchan-relay.nix), and
# nox-bus-bridge passes notifications and the tray between it and dom0's
# filtered bus (/tmp/ssh_dbus.sock; dom0's xdg-dbus-proxy still decides
# what passes).
{
  lib,
  pkgs,
  config,
  inputs,
  vmRegistry,
  ...
}:
let
  vmName = lib.removeSuffix "-vm" (config.networking.hostName or "");
  vm = vmRegistry.byName.${vmName} or { };
  enabled = vm.screenShare or false;
  # dom0's filtered bus (registry `dbus`), else nothing to bridge
  bridge = enabled && (vm.enableHostDbusForward or true);
  package = inputs.nox.packages.${pkgs.stdenv.hostPlatform.system}.nox-screencast;
  socket = "/run/nox-screencast.sock";

  gst = pkgs.gst_all_1;
  # H.264 from dom0 on stdin -> a PipeWire video source (prints its node
  # id); GStreamer only decodes
  receiver = pkgs.writeShellScript "nox-screencast-receive" ''
    export GST_PLUGIN_SYSTEM_PATH_1_0=${
      lib.makeSearchPath "lib/gstreamer-1.0" [
        gst.gstreamer.out
        # videoconvert, appsink
        gst.gst-plugins-base
        # h264parse
        gst.gst-plugins-bad
        # avdec_h264
        gst.gst-libav
      ]
    }
    exec ${package}/bin/nox-screencast-receive "nox-screencast-$$"
  '';

  busName = "org.freedesktop.impl.portal.desktop.nox";
  # The backend's portal file and D-Bus activation
  portal = pkgs.runCommand "nox-screencast-portal-files" { } ''
    mkdir -p $out/share/xdg-desktop-portal/portals $out/share/dbus-1/services
    cat > $out/share/xdg-desktop-portal/portals/nox.portal <<EOF
    [portal]
    DBusName=${busName}
    Interfaces=org.freedesktop.impl.portal.ScreenCast
    EOF
    cat > $out/share/dbus-1/services/${busName}.service <<EOF
    [D-BUS Service]
    Name=${busName}
    Exec=/run/current-system/sw/bin/false
    SystemdService=nox-screencast-portal.service
    EOF
  '';
in
{
  config = lib.mkIf enabled {
    xdg.portal = {
      enable = true;
      extraPortals = [ portal ];
      config.common."org.freedesktop.impl.portal.ScreenCast" = [ "nox" ];
    };

    systemd.user.services = {
      nox-screencast-portal = {
        description = "Screen sharing portal backend (dom0 picks, nox-screencast)";
        serviceConfig = {
          Type = "dbus";
          BusName = busName;
          ExecStart = "${package}/bin/nox-screencast-portal --socket ${socket} --receiver ${receiver}";
        };
      };
      nox-bus-bridge = lib.mkIf bridge {
        description = "Notifications and tray between the VM's session bus and dom0";
        wantedBy = [ "default.target" ];
        after = [ "dbus.socket" ];
        requires = [ "dbus.socket" ];
        serviceConfig = {
          ExecStart = "${package}/bin/nox-bus-bridge --local unix:path=%t/bus --remote unix:path=/tmp/ssh_dbus.sock";
          # dom0's side comes and goes with the relay
          Restart = "always";
          RestartSec = 2;
        };
      };

      # xdg-desktop-portal requires graphical-session.target; the VM's
      # graphical session is wprsd (nothing else here is wanted by the target)
      nox-wprs-session = {
        description = "wprsd as the graphical session (for the portals)";
        wantedBy = [ "default.target" ];
        bindsTo = [ "wprsd.service" ];
        after = [ "wprsd.service" ];
        wants = [ "graphical-session.target" ];
        before = [ "graphical-session.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };

      # On the own bus the apps also find the other portals (gtk: file
      # chooser, settings) and prefer them: the gtk backend draws over wprs
      # like an app, the user manager has no display of its own
      xdg-desktop-portal-gtk.environment = config.services.nox-rpc.guest.apps.environment;
    };

    # Apps started from dom0 wait for the bridge (their tray and
    # notifications go through it)
    services.nox-rpc.guest.apps.after = lib.mkIf bridge [ "nox-bus-bridge.service" ];
  };
}

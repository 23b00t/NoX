{ pkgs, ... }:
# NOTE: Debug with: busctl --user list | grep -E 'StatusNotifier|Notifications|NetworkManager'
# busctl --user monitor org.freedesktop.DBus
# --log \
# --see=org.gtk.Settings \
# --talk=org.gtk.Settings \
let
  # Electron >= 43 owns org.{freedesktop,kde}.StatusNotifierItem-<pid>-<n> for
  # its tray icon; upstream --own only knows exact names and "org.foo.*", the
  # patch adds "org.foo.Bar-*" (string prefix).
  xdg-dbus-proxy = pkgs.xdg-dbus-proxy.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./xdg-dbus-proxy-own-prefix.patch ];
  });
in
{
  systemd.user.services.vm-session-bus-proxy = {
    description = "Filtered host D-Bus proxy for VMs";
    wantedBy = [ "default.target" ];

    script = ''
      ${pkgs.coreutils}/bin/rm -f "$XDG_RUNTIME_DIR/vm-session-bus.sock"

      exec ${xdg-dbus-proxy}/bin/xdg-dbus-proxy \
        "unix:path=$XDG_RUNTIME_DIR/bus" \
        "$XDG_RUNTIME_DIR/vm-session-bus.sock" \
        --filter \
        --see=org.freedesktop.Notifications \
        --talk=org.freedesktop.Notifications \
        --see=org.kde.StatusNotifierWatcher \
        --talk=org.kde.StatusNotifierWatcher \
        --see=org.freedesktop.StatusNotifierWatcher \
        --talk=org.freedesktop.StatusNotifierWatcher \
        --own=org.freedesktop.network-manager-applet \
        "--own=org.freedesktop.StatusNotifierItem-*" \
        "--own=org.kde.StatusNotifierItem-*" \
        --broadcast=org.kde.StatusNotifierWatcher=/StatusNotifierWatcher,org.kde.StatusNotifierWatcher,* \
        --broadcast=org.freedesktop.StatusNotifierWatcher=/StatusNotifierWatcher,org.freedesktop.StatusNotifierWatcher,*
    '';

    serviceConfig = {
      Restart = "on-failure";
      RestartSec = 1;
    };
  };
}

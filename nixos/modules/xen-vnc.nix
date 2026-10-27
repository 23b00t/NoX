# Display of HVM domains whose qemu runs in a Linux stubdomain (Tails): the
# stubdomain exports qemu's VNC socket over a vchan
# (device-model/<domid>/vnc-vchan, pkgs/xen-stubdom-linux in the microvm.nix
# fork). Per domain a socket /run/xen-vnc/<domain>.sock for nx; each
# connection runs the vchan client (needs root) for that one connection.
# `xen-vnc <domain>` opens it in a VNC viewer. qemu's VNC stays inside the
# stubdomain, dom0 only relays bytes.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.services.xen-vnc;
  xen = config.virtualisation.xen.package;

  connect = pkgs.writeShellScript "xen-vnc-connect" ''
    set -eu
    PATH=${lib.makeBinPath [ xen ]}
    target="$(xl domid "$1")"
    stubdom="$(xl domid "$1-dm")"
    exec vchan-socket-proxy --mode=client "$stubdom" \
      "/local/domain/$stubdom/device-model/$target/vnc-vchan" -
  '';

  viewer = pkgs.writeShellScriptBin "xen-vnc" ''
    if [ $# -ne 1 ] || [ ! -S "/run/xen-vnc/$1.sock" ]; then
      echo "usage: xen-vnc <${lib.concatStringsSep "|" cfg.domains}>" >&2
      exit 2
    fi
    exec ${pkgs.tigervnc}/bin/vncviewer "/run/xen-vnc/$1.sock"
  '';
in
{
  options.services.xen-vnc.domains = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Xen domains (with a Linux stubdomain exporting VNC) to view with `xen-vnc`.";
  };

  config = lib.mkIf (cfg.domains != [ ]) {
    environment.systemPackages = [ viewer ];

    systemd.sockets = lib.listToAttrs (
      map (
        domain:
        lib.nameValuePair "xen-vnc-${domain}" {
          description = "VNC of Xen domain ${domain}";
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = "/run/xen-vnc/${domain}.sock";
            Accept = true;
            SocketUser = config.nox.user;
            SocketMode = "0600";
            DirectoryMode = "0755";
          };
        }
      ) cfg.domains
    );

    systemd.services = lib.listToAttrs (
      map (
        domain:
        lib.nameValuePair "xen-vnc-${domain}@" {
          description = "VNC of Xen domain ${domain} (one connection)";
          serviceConfig = {
            ExecStart = "${connect} ${domain}";
            StandardInput = "socket";
            StandardOutput = "socket";
            StandardError = "journal";
          };
        }
      ) cfg.domains
    );
  };
}

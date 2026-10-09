# nox-relay: Unix sockets between dom0 and guests over one vchan per guest.
#
# - guest: offers the vchan to dom0 (server side, xenstore path below its own
#   /local/domain/<id>), runs as root (needs the Xen grant/event devices)
# - host (dom0): one client per guest, reconnects when the guest restarts
#   (new domain id)
#
# Rules per side: `listen.<service>` creates a local socket whose connections
# open <service> at the peer; `serve.<service>` lets the peer open <service>,
# connected to a local socket. A peer reaches nothing but its `serve` list.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nox-relay;

  listenOpts = {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        description = "Socket to create on this side.";
      };
      mode = lib.mkOption {
        type = lib.types.strMatching "[0-7]{3,4}";
        default = "0600";
        description = "Socket permissions (octal).";
      };
      owner = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[0-9]+:[0-9]+");
        default = null;
        example = "1000:100";
        description = "Numeric uid:gid of the socket.";
      };
    };
  };

  rulesOpts = {
    listen = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule listenOpts);
      default = { };
      description = "Services this side opens at the peer, by local socket.";
    };
    serve = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Services the peer may open, mapped to local sockets.";
    };
  };

  configFile =
    name: rules:
    pkgs.writeText "nox-relay-${name}.conf" (
      lib.concatStrings (
        lib.mapAttrsToList (
          service: l:
          "listen ${service} ${l.path} mode=${l.mode}"
          + lib.optionalString (l.owner != null) " owner=${l.owner}"
          + "\n"
        ) rules.listen
        ++ lib.mapAttrsToList (service: path: "serve ${service} ${path}\n") rules.serve
      )
    );

  exe = "${cfg.package}/bin/nox-relay";
in
{
  options.services.nox-relay = {
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.nox-relay;
      defaultText = lib.literalExpression "nox.packages.\${system}.nox-relay";
      description = "nox-relay package.";
    };

    guest = {
      enable = lib.mkEnableOption "the guest side of nox-relay";
      peer = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = "Domain id allowed to connect (dom0).";
      };
      path = lib.mkOption {
        type = lib.types.str;
        default = "data/nox-relay";
        description = "Xenstore path of the vchan, relative to /local/domain/<own id>.";
      };
    }
    // rulesOpts;

    host = {
      enable = lib.mkEnableOption "the dom0 side of nox-relay";
      xenPackage = lib.mkOption {
        type = lib.types.package;
        default = config.virtualisation.xen.package;
        defaultText = lib.literalExpression "config.virtualisation.xen.package";
        description = "Xen tools providing `xl` (domain id lookup).";
      };
      guests = lib.mkOption {
        default = { };
        description = "Guests to connect to, by name.";
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = {
                domain = lib.mkOption {
                  type = lib.types.str;
                  default = name;
                  description = "Xen domain name of the guest.";
                };
                path = lib.mkOption {
                  type = lib.types.str;
                  default = "data/nox-relay";
                  description = "The guest's `guest.path`.";
                };
              }
              // rulesOpts;
            }
          )
        );
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.guest.enable {
      boot.kernelModules = [
        "xen-gntdev"
        "xen-gntalloc"
        "xen-evtchn"
      ];
      systemd.services.nox-relay = {
        description = "nox-relay (guest side)";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-modules-load.service" ];
        # Exits when dom0's side goes away; a fresh ring for the next client
        serviceConfig = {
          ExecStart = "${exe} --role server --peer ${toString cfg.guest.peer} --path ${cfg.guest.path} --config ${configFile "guest" cfg.guest}";
          Restart = "always";
          RestartSec = 1;
        };
        unitConfig.StartLimitIntervalSec = 0;
      };
    })

    (lib.mkIf cfg.host.enable {
      systemd.services = lib.mapAttrs' (
        name: g:
        lib.nameValuePair "nox-relay-${name}" {
          description = "nox-relay to ${g.domain}";
          wantedBy = [ "multi-user.target" ];
          path = [ cfg.host.xenPackage ];
          # The domain id changes with every guest start: look it up each time
          script = ''
            until domid="$(xl domid ${lib.escapeShellArg g.domain} 2>/dev/null)"; do
              sleep 3
            done
            exec ${exe} --role client --peer "$domid" \
              --path "/local/domain/$domid/${g.path}" --config ${configFile name g}
          '';
          serviceConfig = {
            Restart = "always";
            RestartSec = 2;
          };
          unitConfig.StartLimitIntervalSec = 0;
        }
      ) cfg.host.guests;
    })
  ];
}

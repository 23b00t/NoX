# nox-rpc: qrexec-like calls between guests, mediated by dom0 over nox-relay.
#
# - guest: `nox-rpc <service> <target>` (and `vm-copy <target> <files>`) talk
#   to dom0 through the relay service `rpc`; incoming calls arrive on the
#   relay service `rpc-in`, where systemd starts one handler per call as the
#   guest user (`guest.handlers.<service>`, stdin/stdout = the stream)
# - host (dom0): nox-rpcd learns the source from the socket a call arrives
#   on (one per guest), checks `host.policy` (first match wins, default deny,
#   `ask` = notification with buttons) and pipes the bytes to the target
#
# Needs services.nox-relay on both sides (relay.nix).
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nox-rpc;
  exe = name: "${cfg.package}/bin/${name}";
  nameType = lib.types.strMatching "[a-z0-9-]{1,32}";

  # Guest: one call per connection; first line is "<service> <source>"
  dispatch = pkgs.writeShellScript "nox-rpc-in" ''
    set -u
    IFS=' ' read -r service source || exit 1
    if ! [[ "$service" =~ ^[a-z0-9-]{1,32}$ && "$source" =~ ^[a-z0-9-]{1,32}$ ]]; then
      echo "error bad header"
      exit 1
    fi
    case "$service" in
    ${lib.concatStrings (
      lib.mapAttrsToList (service: script: ''
        ${service})
        ${script}
        ;;
      '') cfg.guest.handlers
    )}
      *)
        echo "error unknown service $service"
        exit 1
        ;;
    esac
  '';

  vmCopy = pkgs.writeShellScriptBin "vm-copy" ''
    set -euo pipefail
    if [ $# -lt 2 ]; then
      echo "usage: vm-copy <target-vm> <file|dir>..." >&2
      exit 2
    fi
    target="$1"
    shift
    # The target answers "ok: ..." or "error: ..."
    answer="$(${pkgs.gnutar}/bin/tar -cf - -- "$@" | ${exe "nox-rpc"} copy "$target")"
    echo "$answer"
    [[ "$answer" == ok* ]]
  '';

  # Host: `ask` policy, args service source target; exit 0 = allow
  ask = pkgs.writeShellScript "nox-rpc-ask" ''
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    export DBUS_SESSION_BUS_ADDRESS
    choice="$(timeout ${toString (cfg.host.askTimeout + 5)} ${pkgs.libnotify}/bin/notify-send \
      -u critical -t ${toString (cfg.host.askTimeout * 1000)} --wait \
      -A allow=Erlauben -A deny=Ablehnen \
      "RPC: $1" "$2 möchte $1 an $3")" || exit 1
    [ "$choice" = allow ]
  '';

  rpcdConfig = pkgs.writeText "nox-rpcd.conf" (
    lib.concatMapStrings (g: ''
      source ${g} /run/nox-rpcd/${g}.sock
      target ${g} /run/nox-relay/${g}-rpc-in.sock
    '') cfg.host.guests
    + lib.concatMapStrings (
      p: "policy ${p.service} ${p.source} ${p.target} ${p.action}\n"
    ) cfg.host.policy
    + "ask-command ${ask}\n"
  );
in
{
  options.services.nox-rpc = {
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.nox-rpc;
      defaultText = lib.literalExpression "nox.packages.\${system}.nox-rpc";
      description = "nox-rpc package.";
    };

    guest = {
      enable = lib.mkEnableOption "nox-rpc in a guest";
      user = lib.mkOption {
        type = lib.types.str;
        default = "user";
        description = "Guest user that may call and that runs the handlers.";
      };
      owner = lib.mkOption {
        type = lib.types.strMatching "[0-9]+:[0-9]+";
        default = "1000:100";
        description = "Numeric uid:gid of `user` (owner of the call socket).";
      };
      handlers = lib.mkOption {
        type = lib.types.attrsOf lib.types.lines;
        description = "Shell code per service; `$source` is the calling domain, stdin/stdout the stream.";
        default.copy = ''
          dir="$HOME/Incoming/$source"
          mkdir -p "$dir"
          if ${pkgs.gnutar}/bin/tar -x --no-same-owner --no-same-permissions -C "$dir" -f -; then
            echo "ok: in ~/Incoming/$source"
          else
            echo "error: extracting failed"
          fi
        '';
      };
    };

    host = {
      enable = lib.mkEnableOption "nox-rpcd in dom0";
      user = lib.mkOption {
        type = lib.types.str;
        default = "nx";
        description = "dom0 user running nox-rpcd (shows the `ask` notifications).";
      };
      owner = lib.mkOption {
        type = lib.types.strMatching "[0-9]+:[0-9]+";
        default = "1000:100";
        description = "Numeric uid:gid of `host.user` (owner of the rpc-in sockets).";
      };
      guests = lib.mkOption {
        type = lib.types.listOf nameType;
        default = [ ];
        description = "Guests (names in services.nox-relay.host.guests) that take part.";
      };
      policy = lib.mkOption {
        default = [ ];
        description = "Rules, first match wins, no match = deny.";
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              service = lib.mkOption { type = nameType; };
              source = lib.mkOption {
                type = lib.types.either nameType (lib.types.enum [ "*" ]);
                default = "*";
              };
              target = lib.mkOption {
                type = lib.types.either nameType (lib.types.enum [ "*" ]);
                default = "*";
              };
              action = lib.mkOption {
                type = lib.types.enum [
                  "allow"
                  "ask"
                  "deny"
                ];
              };
            };
          }
        );
      };
      askTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Seconds to answer an `ask` notification before it counts as deny.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.guest.enable {
      services.nox-relay.guest = {
        enable = true;
        listen.rpc = {
          path = "/run/nox-rpc.sock";
          inherit (cfg.guest) owner;
        };
        serve.rpc-in = "/run/nox-rpc-in.sock";
      };

      systemd.sockets.nox-rpc-in = {
        description = "Incoming nox-rpc calls (from dom0)";
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          ListenStream = "/run/nox-rpc-in.sock";
          Accept = true;
          SocketMode = "0600";
        };
      };
      systemd.services."nox-rpc-in@" = {
        description = "nox-rpc call (one connection)";
        serviceConfig = {
          ExecStart = dispatch;
          User = cfg.guest.user;
          StandardInput = "socket";
          StandardOutput = "socket";
          StandardError = "journal";
        };
      };

      environment.systemPackages = [
        cfg.package
        vmCopy
      ];
    })

    (lib.mkIf cfg.host.enable {
      services.nox-relay.host.guests = lib.genAttrs cfg.host.guests (name: {
        serve.rpc = "/run/nox-rpcd/${name}.sock";
        listen.rpc-in = {
          path = "/run/nox-relay/${name}-rpc-in.sock";
          inherit (cfg.host) owner;
        };
      });

      systemd.services.nox-rpcd = {
        description = "nox-rpc broker (policy, pipes between guests)";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${exe "nox-rpcd"} --config ${rpcdConfig}";
          User = cfg.host.user;
          RuntimeDirectory = "nox-rpcd";
          Restart = "always";
          RestartSec = 2;
        };
      };
    })
  ];
}

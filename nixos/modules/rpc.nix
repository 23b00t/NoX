# nox-rpc: qrexec-like calls between guests, mediated by dom0 over nox-relay.
#
# - guest: `nox-rpc <service> <target>` (and `vm-copy <target> <files>`) talk
#   to dom0 through the relay service `rpc`; incoming calls arrive on the
#   relay service `rpc-in`, where systemd starts one handler per call as the
#   guest user (`guest.handlers.<service>`, stdin/stdout = the stream)
# - host (dom0): nox-rpcd learns the source from the socket a call arrives
#   on (one per guest), checks `host.policy` (first match wins, default deny,
#   `ask`/`warn` = a question, `host.askCommand`) and pipes the bytes to the
#   target; dom0's own calls (`nox-rpc --dom0 <service> <guest>`, e.g. `app`)
#   go straight to the guest's `rpc-in` with the source `dom0`, or through
#   the broker (`nox-rpc --broker`, `nox-copy`) when the policy should apply
# - copy: `nox-pack` sends a manifest and a tar stream; the broker asks with
#   the manifest and cuts off a stream larger than announced or than
#   `host.copyLimit`; the target unpacks files and directories only into
#   ~/Incoming/<source>, never overwriting. `nox-copy` in dom0 copies dom0's
#   files or, through the guest service `send`, a guest's files
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

  # Guest handler `app`: only dom0 may start programs. Transient user units
  # outlive the call, get the user manager's environment (PATH, HOME as
  # working directory) and log to the journal.
  runArgs = lib.escapeShellArgs (
    lib.mapAttrsToList (n: v: "--setenv=${n}=${v}") cfg.guest.apps.environment
    ++ map (u: "--property=After=${u}") cfg.guest.apps.after
  );
  startApp = ''
    if [ "$source" != dom0 ]; then
      echo "error: only dom0 starts apps"
      exit 1
    fi
    args=()
    while IFS= read -r -d "" arg; do
      args+=("$arg")
    done
    if [ "''${#args[@]}" -eq 0 ]; then
      echo "error: no command"
      exit 1
    fi
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    PATH="/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin"
    export XDG_RUNTIME_DIR PATH
    # Early in the guest's boot the user manager may not be up yet; wait
    # for its bus (a file test, no delay once it runs)
    for _ in $(seq 30); do
      [ -S "$XDG_RUNTIME_DIR/bus" ] && break
      sleep 1
    done
    # dom0 retries a call whose answer got lost (early boot) with the same
    # token (`env NOX_APP_TOKEN=<hex> …`): the app runs as its unit, a
    # repeated call doesn't start it twice (xmg 2026-10-17: foot came twice)
    unit=()
    if [ "''${args[0]}" = env ] && [[ "''${args[1]:-}" =~ ^NOX_APP_TOKEN=([0-9a-f]{8,32})$ ]]; then
      unit=(--unit="nox-app-''${BASH_REMATCH[1]}")
      if [ "$(systemctl --user show -p LoadState --value "nox-app-''${BASH_REMATCH[1]}.service")" = loaded ]; then
        echo "ok: already started"
        exit 0
      fi
    fi
    if out="$(systemd-run --user --collect --quiet "''${unit[@]}" ${runArgs} -- "''${args[@]}" 2>&1)"; then
      echo "ok: started ''${args[0]}"
    else
      echo "error: $out"
      exit 1
    fi
  '';

  # Both sides: manifest (entries, bytes, first names; nox-rpcd shows it in
  # the question and holds the stream to it) and the tar stream of the
  # paths, each stored under its own name. -l: only what would be sent, for
  # people
  noxPack = pkgs.writeShellScriptBin "nox-pack" ''
    set -euo pipefail
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gawk
        pkgs.gnutar
      ]
    }
    list=0
    if [ "''${1:-}" = -l ]; then
      list=1
      shift
    fi
    if [ $# -eq 0 ]; then
      echo "usage: nox-pack [-l] <path>..." >&2
      exit 2
    fi
    entries=0
    bytes=0
    names=()
    tarargs=()
    for p in "$@"; do
      if ! [ -e "$p" ] && ! [ -L "$p" ]; then
        echo "nox-pack: $p: not found" >&2
        exit 1
      fi
      p="''${p%/}"
      entries=$((entries + $(find "$p" | wc -l)))
      bytes=$((bytes + $(find "$p" -type f -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')))
      # One line each, printable, at most 60 characters
      b="$(basename -- "$p")"
      [ "''${#names[@]}" -ge 5 ] ||
        names+=("$(printf '%s' "$b" | tr '\000-\037\177' '?' | LC_ALL=C.UTF-8 awk '{ print substr($0, 1, 60) }')")
      tarargs+=(-C "$(dirname -- "$p")" "./$b")
    done
    if [ "$list" = 1 ]; then
      echo "$entries entries, $(numfmt --to=iec "$bytes")B: ''${names[*]}$([ $# -le 5 ] || echo " …")"
      exit 0
    fi
    printf 'manifest %s %s %s\n' "$entries" "$bytes" "''${#names[@]}"
    printf '%s\n' "''${names[@]}"
    tar -cf - "''${tarargs[@]}"
  '';

  vmCopy = pkgs.writeShellScriptBin "vm-copy" ''
    set -euo pipefail
    usage() {
      echo "usage: vm-copy [-m] [-n] <target-vm> <file|dir>..." >&2
      echo "  -m  move: remove the sources after the copy" >&2
      echo "  -n  only show what would be sent" >&2
      exit 2
    }
    move=0
    dry=0
    while getopts ":mn" o; do
      case "$o" in
        m) move=1 ;;
        n) dry=1 ;;
        *) usage ;;
      esac
    done
    shift $((OPTIND - 1))
    [ $# -ge 2 ] || usage
    target="$1"
    shift
    if [ "$dry" = 1 ]; then
      ${noxPack}/bin/nox-pack -l "$@"
      echo "-> $target (nothing sent)"
      exit 0
    fi
    # The target answers "ok: ..." or "error: ..."
    answer="$(${noxPack}/bin/nox-pack "$@" | ${exe "nox-rpc"} copy "$target")" || true
    echo "$answer"
    [[ "$answer" == ok* ]] || exit 1
    [ "$move" = 0 ] || rm -rf -- "$@"
  '';

  # Guest handler `copy`: unpack into a scratch directory first (bsdtar
  # refuses absolute and `..` paths and writing through symlinks), keep only
  # files and directories, then move them into ~/Incoming/<source> without
  # overwriting anything (a taken name gets a suffix). A stream cut off by
  # the broker fails in bsdtar and leaves nothing.
  copyHandler = ''
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.libarchive
      ]
    }
    dir="$HOME/Incoming/$source"
    mkdir -p "$dir"
    tmp="$(mktemp -d "$HOME/Incoming/.nox-copy.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    if ! err="$(bsdtar -x -f - -C "$tmp" --no-same-owner --no-xattrs --no-acls --no-fflags 2>&1)"; then
      echo "error: extracting failed: $(head -c 200 <<<"$err")"
      exit 1
    fi
    dropped="$(find "$tmp" -mindepth 1 ! -type f ! -type d -print -delete | wc -l)"
    n=0
    for e in "$tmp"/* "$tmp"/.[!.]* "$tmp"/..?*; do
      [ -e "$e" ] || continue
      name="''${e##*/}"
      dest="$dir/$name"
      i=1
      while [ -e "$dest" ] || [ -L "$dest" ]; do
        dest="$dir/$name.$i"
        i=$((i + 1))
      done
      mv -T -- "$e" "$dest"
      n=$((n + 1))
    done
    msg="ok: $n in ~/Incoming/$source"
    [ "$dropped" = 0 ] || msg="$msg ($dropped links or special files dropped)"
    echo "$msg"
  '';

  # Guest handler `send` (dom0 only): `nox copy <from> <to> …` reads the
  # files from here. stdin: a mode line (list|pack|remove), then the paths,
  # NUL-terminated, relative to the home or absolute inside it
  sendHandler = ''
    if [ "$source" != dom0 ]; then
      echo "error: only dom0 asks for files"
      exit 1
    fi
    IFS= read -r mode
    paths=()
    while IFS= read -r -d "" p; do
      case "$p" in
        /*) ;;
        *) p="$HOME/$p" ;;
      esac
      case "$(realpath -m -- "$p")/" in
        "$HOME"/?*) paths+=("$p") ;;
        *)
          echo "error: $p is outside the home"
          exit 1
          ;;
      esac
      if [ "$mode" != remove ] && ! [ -e "$p" ] && ! [ -L "$p" ]; then
        echo "error: $p not found"
        exit 1
      fi
    done
    [ "''${#paths[@]}" -gt 0 ] || { echo "error: no paths"; exit 1; }
    case "$mode" in
      list) exec ${noxPack}/bin/nox-pack -l "''${paths[@]}" ;;
      pack) exec ${noxPack}/bin/nox-pack "''${paths[@]}" ;;
      remove) rm -rf -- "''${paths[@]}" && echo "ok: removed" ;;
      *) echo "error: mode list|pack|remove" ;;
    esac
  '';

  # Host: `nox copy` / `nox-copy`: from dom0 (its files) or, for a guest,
  # out of that guest; through the broker's dom0 socket, so the policy
  # applies (dom0's own request: no question unless `warn`)
  noxCopy = pkgs.writeShellScriptBin "nox-copy" ''
    set -euo pipefail
    guests=(${lib.escapeShellArgs cfg.host.guests})
    usage() {
      cat >&2 <<EOF
    usage: nox-copy [-m] [-n] [--max <bytes>] [<from-vm>] <to-vm> <path>...
      without <from-vm>: dom0's files; with it (the first two arguments are
      VMs): paths in <from-vm>, relative to its home
      -m  move (remove the sources after the copy)
      -n  only show what would be sent
      --max <bytes>  allow more than the copy limit
    EOF
      exit 2
    }
    is_guest() { case " ''${guests[*]} " in *" $1 "*) return 0 ;; esac; return 1; }
    move=0
    dry=0
    opts=()
    pos=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -m) move=1 ;;
        -n) dry=1 ;;
        --max)
          [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || usage
          opts+=("max=$2")
          shift
          ;;
        -h | --help) usage ;;
        --) shift; pos+=("$@"); break ;;
        -*) usage ;;
        *) pos+=("$1") ;;
      esac
      shift
    done
    [ "''${#pos[@]}" -ge 2 ] || usage
    from=""
    if [ "''${#pos[@]}" -ge 3 ] && is_guest "''${pos[0]}" && is_guest "''${pos[1]}"; then
      from="''${pos[0]}"
      pos=("''${pos[@]:1}")
    fi
    to="''${pos[0]}"
    paths=("''${pos[@]:1}")
    is_guest "$to" || { echo "nox-copy: $to: no such VM" >&2; exit 2; }

    request() { printf '%s\n' "$1"; shift; printf '%s\0' "$@"; }
    # What would be sent; from a guest also checks its paths first, so its
    # error ("outside the home", "not found") shows instead of a broken copy
    if [ -z "$from" ]; then
      summary="$(${noxPack}/bin/nox-pack -l "''${paths[@]}")"
    else
      summary="$(request list "''${paths[@]}" | ${exe "nox-rpc"} --dom0 send "$from" 2>&1)" || true
      if [[ "$summary" != *" entries, "* ]]; then
        echo "nox-copy: $from: ''${summary:-no answer}" >&2
        exit 1
      fi
    fi
    if [ "$dry" = 1 ]; then
      echo "$summary -> $to (nothing sent)"
      exit 0
    fi
    if [ -z "$from" ]; then
      answer="$(${noxPack}/bin/nox-pack "''${paths[@]}" |
        ${exe "nox-rpc"} --broker copy "$to" "''${opts[@]}")" || true
    else
      answer="$(request pack "''${paths[@]}" | ${exe "nox-rpc"} --dom0 send "$from" |
        ${exe "nox-rpc"} --broker copy "$to" "as=$from" "''${opts[@]}")" || true
    fi
    echo "$answer"
    [[ "$answer" == ok* ]] || exit 1
    if [ "$move" = 1 ]; then
      if [ -z "$from" ]; then
        rm -rf -- "''${paths[@]}"
      else
        request remove "''${paths[@]}" | ${exe "nox-rpc"} --dom0 send "$from"
      fi
    fi
  '';

  # Host: `ask`/`warn` question, args service source target ask|warn and,
  # for a copy, entries bytes names…; exit 0 = allow. A notification with
  # buttons (no typing: `warn` only words it more strongly); replace it with
  # `host.askCommand`
  ask = pkgs.writeShellScript "nox-rpc-ask" ''
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    export DBUS_SESSION_BUS_ADDRESS
    body="$2 wants to $1 to $3"
    if [ "$1" = copy ] && [ $# -ge 6 ]; then
      body="$body: $5 entries, $(${pkgs.coreutils}/bin/numfmt --to=iec "$6")B: ''${*:7}"
    fi
    [ "$4" != warn ] || body="CAREFUL, $3 is protected. $body"
    choice="$(timeout ${toString (cfg.host.askTimeout + 5)} ${pkgs.libnotify}/bin/notify-send \
      -u critical -t ${toString (cfg.host.askTimeout * 1000)} --wait \
      -A allow=Allow -A deny=Deny \
      "RPC: $1" "$body")" || exit 1
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
    + ''
      ask-command ${if cfg.host.askCommand != null then cfg.host.askCommand else ask}
      dom0-socket /run/nox-rpcd/dom0.sock
      copy-limit ${toString cfg.host.copyLimit}
    ''
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
        default = { };
        description = ''
          Shell code per service; `$source` is the calling domain (`dom0` for
          dom0's own calls), stdin/stdout the stream. Built in: `copy`, and
          `app` with `apps.enable`.
        '';
      };
      apps = {
        enable = lib.mkEnableOption ''
          the `app` service: dom0 starts programs in the guest
          (`nox-rpc --dom0 app <guest>`, stdin = argv, each argument
          NUL-terminated) as transient units of `user`'s systemd instance
          (needs linger)'';
        environment = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          example = {
            WAYLAND_DISPLAY = "wprs-0";
          };
          description = "Environment for started programs, on top of the user manager's.";
        };
        after = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "wprsd.service" ];
          description = "User units started programs wait for (e.g. the display server).";
        };
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
                  "warn"
                  "deny"
                ];
                description = "`warn`: `ask` with a stronger question (askCommand decides how).";
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
      askCommand = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Program for `ask`/`warn` instead of the notification. Args: service
          source target ask|warn, for a copy also entries bytes names…; runs
          as `host.user`; exit 0 = allow.
        '';
      };
      copyLimit = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 10000000000;
        description = "Most bytes one copy may carry (dom0's `nox-copy --max` raises it per call).";
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

      services.nox-rpc.guest.handlers = {
        copy = lib.mkDefault copyHandler;
        send = lib.mkDefault sendHandler;
        app = lib.mkIf cfg.guest.apps.enable (lib.mkDefault startApp);
      };

      environment.systemPackages = [
        cfg.package
        noxPack
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

      environment.systemPackages = [
        cfg.package
        noxPack
        noxCopy
      ];

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

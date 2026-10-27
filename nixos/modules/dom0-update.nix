# dom0-update (v2.4): dom0 pulls its system from the builder VM instead of
# evaluating and building itself. The builder signs the whole closure; dom0's
# nix-daemon only accepts it with a valid signature from the builder key
# (registry `builderKeys`/signing-key-<machine>.pub: every machine has its own builder
# VM and key). Pull only: the builder never gets access to dom0.
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  cfg = config.services.dom0-update;
  builderIp = vmRegistry.byName.builder.ip;
  keyFile = vmRegistry.builderKeys + "/signing-key-${config.networking.hostName}.pub";
  keyText = if builtins.pathExists keyFile then lib.trim (builtins.readFile keyFile) else "";
  # An empty file (e.g. from a failed `ssh … > signing-key.pub`) counts as no key
  builderKey = if keyText != "" then keyText else null;

  dom0Update = pkgs.writeShellScriptBin "dom0-update" ''
    set -euo pipefail

    usage() {
      cat <<EOF >&2
    Usage: dom0-update [--switch] [--machine <name>] [--branch <branch>]

    Builds the system on the builder VM, copies the signed closure and
    activates it for the next boot (default) or right away (--switch).
    Defaults: --machine ${cfg.machine} --branch ${cfg.branch}
    EOF
      exit 1
    }

    action=boot
    machine=${lib.escapeShellArg cfg.machine}
    branch=${lib.escapeShellArg cfg.branch}
    while [ $# -gt 0 ]; do
      case "$1" in
        --switch) action=switch ;;
        --machine) [ $# -ge 2 ] || usage; machine="$2"; shift ;;
        --branch) [ $# -ge 2 ] || usage; branch="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
      esac
      shift
    done

    ${lib.optionalString (builderKey == null) ''
      echo "dom0-update: vms/builder/signing-key-${config.networking.hostName}.pub is missing, dom0 does not trust the builder yet" >&2
      exit 1
    ''}

    # Ask for the sudo password now, not after the build, and keep the
    # timestamp fresh meanwhile. Without a terminal (unattended runs) rely on
    # NOPASSWD rules for the commands below.
    if [ -t 0 ]; then
      sudo -v
      while sleep 60; do sudo -n -v 2>/dev/null || exit; done &
      keepalive=$!
      trap 'kill "$keepalive" 2>/dev/null' EXIT
    fi

    # The builder doesn't autostart: start it and wait for SSH (over vchan).
    # Started here = stopped again after a successful update.
    started_builder=0
    if ! systemctl is-active --quiet microvm@builder; then
      echo "dom0-update: starting the builder VM" >&2
      sudo systemctl start microvm@builder
      started_builder=1
    fi
    for _ in $(seq 120); do
      ssh -o ConnectTimeout=5 ${builderIp} true 2>/dev/null && break
      sleep 2
    done

    # Runs as the calling user (ssh config/key for ${builderIp}); the nix-daemon
    # verifies the builder signature when the paths are added
    out="$(ssh ${builderIp} builder-build "$machine" "$branch" | tail -n 1)"
    case "$out" in
      /nix/store/*-nixos-system-*) ;;
      *) echo "dom0-update: unexpected builder output: $out" >&2; exit 1 ;;
    esac

    echo "dom0-update: copying $out" >&2
    ${config.nix.package}/bin/nix copy --from ssh-ng://${builderIp} "$out"

    sudo ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --set "$out"
    sudo "$out/bin/switch-to-configuration" "$action"
    echo "dom0-update: $action done ($out)" >&2

    if [ "$started_builder" = 1 ]; then
      echo "dom0-update: stopping the builder VM again" >&2
      sudo systemctl stop microvm@builder
    fi
  '';
in
{
  options.services.dom0-update = {
    enable = lib.mkEnableOption "pulling the dom0 system from the builder VM";

    machine = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "nixosConfiguration the builder builds for this dom0.";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = cfg.machine;
      defaultText = lib.literalExpression "config.services.dom0-update.machine";
      description = "Git branch the builder fetches.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ dom0Update ];

    # Additive while dom0 still has internet (until v2.5): the existing
    # substituters stay, the builder key is trusted on top
    nix.settings.trusted-public-keys = lib.optional (builderKey != null) builderKey;
  };
}

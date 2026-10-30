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
    Usage: dom0-update [--bump] [--switch] [--machine <name>] [--branch <branch>]
           dom0-update --iso <vm> [--branch <branch>]

    Builds the system on the builder VM, copies the signed closure and
    activates it for the next boot (default) or right away (--switch).
    --bump: the builder updates the flake inputs first and pushes
    flake.lock as a signed commit "update" (nox update).
    --iso <vm>: builds the config's installer ISO instead and copies it
    from the builder straight to <vm> (~/Incoming/builder/nox-installer.iso
    there; started if it is off), nothing goes through dom0's store.
    Defaults: --machine ${cfg.machine} --branch ${cfg.branch}
    EOF
      exit 1
    }

    action=boot
    bump=()
    iso_vm=""
    machine=${lib.escapeShellArg cfg.machine}
    branch=${lib.escapeShellArg cfg.branch}
    while [ $# -gt 0 ]; do
      case "$1" in
        --switch) action=switch ;;
        --bump) bump=(--bump) ;;
        --iso) [ $# -ge 2 ] || usage; action=iso; iso_vm="$2"; shift ;;
        --machine) [ $# -ge 2 ] || usage; machine="$2"; shift ;;
        --branch) [ $# -ge 2 ] || usage; branch="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
      esac
      shift
    done
    # The ISO is built from the branch as it is
    [ "$action" != iso ] || [ "''${#bump[@]}" = 0 ] || usage

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
    # The ISO's target VM: started now, so it boots while the builder builds;
    # it stays running afterwards (the ISO is in it)
    if [ "$action" = iso ] && ! systemctl is-active --quiet "microvm@$iso_vm"; then
      echo "dom0-update: starting $iso_vm" >&2
      sudo systemctl start "microvm@$iso_vm"
    fi
    for _ in $(seq 120); do
      ssh -o ConnectTimeout=5 ${builderIp} true 2>/dev/null && break
      sleep 2
    done

    # The installer ISO: built in the builder's store, streamed from there
    # through the broker to the VM like `nox copy builder <vm>` (dom0's own
    # call: the copy policy doesn't ask), then deleted in the builder. The
    # broker gives the manifest 10 s, so the stream starts only after the build
    if [ "$action" = iso ]; then
      out="$(ssh ${builderIp} builder-build --iso "$branch" | tail -n 1)"
      case "$out" in
        /nix/store/*-nox-installer.iso) ;;
        *) echo "dom0-update: unexpected builder output: $out" >&2; exit 1 ;;
      esac
      # The VM may still be booting: wait until its rpc side answers (a
      # side-effect-free `send list` of a missing path answers "error: …
      # not found"; while booting the relay drops the call without one)
      for _ in $(seq 120); do
        [ -n "$(printf 'list\n%s\0' .nox-ready | nox-rpc --dom0 send "$iso_vm" 2>/dev/null)" ] && break
        sleep 1
      done
      echo "dom0-update: copying the ISO to $iso_vm" >&2
      answer="$(ssh ${builderIp} "nox-pack $out/iso/*.iso" |
        nox-rpc --broker copy "$iso_vm" as=builder)" || true
      echo "$answer"
      if [[ "$answer" != ok* ]]; then
        echo "dom0-update: copy to $iso_vm failed; the ISO stays in the builder's store until its GC (another --iso doesn't build it again)" >&2
        exit 1
      fi
      ssh ${builderIp} nix store delete "$out" 2>/dev/null ||
        echo "dom0-update: could not delete $out in the builder, its GC takes it" >&2
      echo "dom0-update: ISO in $iso_vm: ~/Incoming/builder/nox-installer.iso" >&2
    else
      # Runs as the calling user (ssh config/key for ${builderIp}); the nix-daemon
      # verifies the builder signature when the paths are added
      out="$(ssh ${builderIp} builder-build "''${bump[@]}" "$machine" "$branch" | tail -n 1)"
      case "$out" in
        /nix/store/*-nixos-system-*) ;;
        *) echo "dom0-update: unexpected builder output: $out" >&2; exit 1 ;;
      esac

      echo "dom0-update: copying $out" >&2
      ${config.nix.package}/bin/nix copy --from ssh-ng://${builderIp} "$out"

      sudo ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --set "$out"
      sudo "$out/bin/switch-to-configuration" "$action"
      echo "dom0-update: $action done ($out)" >&2
    fi

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

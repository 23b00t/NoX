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
  # The sys builder's key name (builder-vm-1): marks its own builds
  signKeyName =
    if builderKey != null then lib.head (lib.splitString ":" builderKey) else "builder-vm-1";
  # The image key (signs the store image manifest, ssh-keygen -Y)
  imageKeyFile = vmRegistry.builderKeys + "/image-key-${config.networking.hostName}.pub";
  imageKeys = cfg.imageKeys // lib.optionalAttrs (cfg.imageKey != null) { builder = cfg.imageKey; };

  # Builder output (nom on stderr) reaches dom0's terminal only through this
  # positive-list filter: colors and cursor movement stay; OSC 52
  # (clipboard), titles and queries (the terminal's answer would go back to
  # the builder) are dropped (nox-cli src/term_filter.rs)
  termFilter = "${config.programs.nox.package}/bin/nox term-filter";

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

    unexpected() {
      printf 'dom0-update: unexpected builder output: %q\n' "$1" >&2
      exit 1
    }
    # stdout of a builder command: its last line; its stderr goes to the
    # terminal through the filter
    from_builder() {
      { ssh ${builderIp} "$@" 2>&1 >&3 3>&- |
        ${termFilter} >&2 3>&-; } 3>&1 | tail -n 1
    }

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
      ssh -o ConnectTimeout=5 ${builderIp} true >/dev/null 2>&1 && break
      sleep 2
    done

    # The installer ISO: built in the builder's store, streamed from there
    # through the broker to the VM like `nox copy builder <vm>` (dom0's own
    # call: the copy policy doesn't ask), then deleted in the builder. The
    # broker gives the manifest 10 s, so the stream starts only after the build
    if [ "$action" = iso ]; then
      out="$(from_builder builder-build --iso "$branch")"
      [[ "$out" =~ ^/nix/store/[0-9a-z]{32}-nox-installer\.iso$ ]] || unexpected "$out"
      # The VM may still be booting: wait until its rpc side answers (a
      # side-effect-free `send list` of a missing path answers "error: …
      # not found"; while booting the relay drops the call without one)
      for _ in $(seq 120); do
        [ -n "$(printf 'list\n%s\0' .nox-ready | nox-rpc --dom0 send "$iso_vm" 2>/dev/null)" ] && break
        sleep 1
      done
      echo "dom0-update: copying the ISO to $iso_vm" >&2
      answer="$(ssh ${builderIp} "nox-pack $out/iso/*.iso" 2> >(${termFilter} >&2) |
        nox-rpc --broker copy "$iso_vm" as=builder)" || true
      echo "$answer"
      if [[ "$answer" != ok* ]]; then
        echo "dom0-update: copy to $iso_vm failed; the ISO stays in the builder's store until its GC (another --iso doesn't build it again)" >&2
        exit 1
      fi
      ssh ${builderIp} nix store delete "$out" >/dev/null 2>&1 ||
        echo "dom0-update: could not delete $out in the builder, its GC takes it" >&2
      echo "dom0-update: ISO in $iso_vm: ~/Incoming/builder/nox-installer.iso" >&2
    else
      # Runs as the calling user (ssh config/key for ${builderIp}); the nix-daemon
      # verifies the builder signature when the paths are added
      # Duration of each step on stderr and in the journal
      # (journalctl -t dom0-update); the builder's own steps are in its
      # journal (journalctl -t builder-build)
      t0=$SECONDS
      t_start=$SECONDS
      timing() {
        local now=$SECONDS
        echo "dom0-update: timing $1 $((now - t0)) s" >&2
        ${pkgs.util-linux}/bin/logger -t dom0-update "timing $machine $1 $((now - t0)) s" || true
        t0=$now
      }
      out="$(from_builder builder-build "''${bump[@]}" "$machine" "$branch")"
      [[ "$out" =~ ^/nix/store/[0-9a-z]{32}-nixos-system-[A-Za-z0-9._+-]+$ ]] || unexpected "$out"
      timing builder

      echo "dom0-update: copying $out" >&2
      # stderr carries the builder's nix-daemon output too: filtered
      ${config.nix.package}/bin/nix copy --from ssh-ng://${builderIp} "$out" \
        2> >(${termFilter} >&2)
      timing copy

      # What only the builder vouches for (no Hydra signature): own builds,
      # Cachix paths, the store images. Summary and the largest here, the
      # whole list in ~/.cache/nox/builder-only-paths
      list="''${XDG_CACHE_HOME:-$HOME/.cache}/nox/builder-only-paths"
      mkdir -p "''${list%/*}"
      ${config.nix.package}/bin/nix path-info -r -s --sigs "$out" |
        ${pkgs.gawk}/bin/awk '!/cache\.nixos\.org-1:/ { print $2 "\t" $1 }' |
        sort -rn > "$list"
      ${pkgs.gawk}/bin/awk -F '\t' '
        { n++; s += $1; if ($2 ~ /-microvm-store-disk\./) { i++; is += $1 } }
        END { printf "dom0-update: %d paths without a Hydra signature, %.2f GiB (%d store images, %.2f GiB)\n", n, s / 2^30, i, is / 2^30 }
      ' "$list" | tee >(${pkgs.util-linux}/bin/logger -t dom0-update) >&2
      ${pkgs.gawk}/bin/awk -F '\t' '$2 !~ /-microvm-store-disk\./ && n++ < 15 { printf "  %8.1f MiB  %s\n", $1 / 2^20, $2 }' "$list" >&2
      echo "dom0-update: full list in $list" >&2

      # Store images as files (dom0/store-images.nix): the new system's
      # nox-image fetches the ones it expects and dom0 doesn't have yet,
      # each from its own builder, checked against that builder's signed
      # manifest and their sha256. dom0's nix-daemon never sees them
      ni="$out/sw/bin/nox-image"
      n="$("$ni" missing "$out" | wc -l)"
      "$ni" fetch "$out" builder "$machine"
      timing "images of the builder"

      # Images of other builders (nox.storeGroups.<g>.builder, variant B):
      # their derivations come from the sys builder (it evaluated them) and
      # go to that builder, which builds without a checkout or evaluation
      # (builder-trust.md 3.2, 3.6). Derivations are content-addressed: no
      # signature needed. The sys builder's own builds (non-Hydra paths of
      # the new system, signed by it) go along, so the app builder doesn't
      # build them again (3.7)
      mapfile -t others < <("$ni" missing "$out" | ${pkgs.gawk}/bin/awk '$3 != "builder" { print $3 }' | sort -u)
      declare -A handover=()
      for b in "''${others[@]}"; do
        [[ $b =~ ^[a-z0-9-]+$ ]] || unexpected "$b"
        mapfile -t pairs < <("$ni" drvs "$out" "$b")
        handover[$b]="''${pairs[*]}"
        ${config.nix.package}/bin/nix copy --derivation --from ssh-ng://builder-vm \
          "''${pairs[@]#*=}" 2> >(${termFilter} >&2)
      done
      if [ "$started_builder" = 1 ] && [ "''${#others[@]}" -gt 0 ]; then
        # RAM for the app builders
        sudo systemctl stop microvm@builder
        started_builder=0
      fi
      for b in "''${others[@]}"; do
        read -r -a pairs <<< "''${handover[$b]}"
        started_b=0
        if ! systemctl is-active --quiet "microvm@$b"; then
          echo "dom0-update: starting $b" >&2
          sudo systemctl start "microvm@$b"
          started_b=1
        fi
        for _ in $(seq 120); do
          ssh -o ConnectTimeout=5 "$b-vm" true >/dev/null 2>&1 && break
          sleep 2
        done
        ${config.nix.package}/bin/nix copy --derivation --to "ssh-ng://$b-vm" \
          "''${pairs[@]#*=}" 2> >(${termFilter} >&2)
        # Only paths with the sys builder's signature: $b trusts that key, a
        # single path without it would abort the whole copy
        cut -f2 "$list" | xargs -r ${config.nix.package}/bin/nix path-info --sigs |
          ${pkgs.gawk}/bin/awk -v k=${lib.escapeShellArg "${signKeyName}:"} 'index($0, k) { print $1 }' |
          xargs -r ${config.nix.package}/bin/nix copy --to "ssh-ng://$b-vm" \
          2> >(${termFilter} >&2) ||
          echo "dom0-update: could not hand the builder's own builds to $b, it builds them itself" >&2
        { ssh "$b-vm" builder-images "$machine" "''${pairs[@]}" 2>&1 >&3 3>&- |
          ${termFilter} >&2 3>&-; } 3>&1 | tail -n 1 >/dev/null
        "$ni" fetch "$out" "$b" "$machine"
        timing "images of $b"
        if [ "$started_b" = 1 ]; then
          sudo systemctl stop "microvm@$b"
        fi
      done
      echo "dom0-update: $n new store images" >&2

      sudo ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --set "$out"
      sudo "$out/bin/switch-to-configuration" "$action"
      timing "$action"
      t0=$t_start
      timing total
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

    imageKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default =
        if builtins.pathExists imageKeyFile then lib.trim (builtins.readFile imageKeyFile) else null;
      defaultText = lib.literalExpression "vms/builder/image-key-<host>.pub";
      example = "ssh-ed25519 AAAA… builder-vm-image";
      description = "Public part of the builder's image key (/var/lib/builder/image-key.pub): dom0-update only takes the builder's store images listed in a manifest signed with it (namespace nox-image). Same as `imageKeys.builder`.";
    };

    imageKeys = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        builder-apps = "ssh-ed25519 AAAA… builder-apps-image";
      };
      description = "Image keys of further builders (nox.storeGroups.<g>.builder), by builder VM name: dom0 takes an image only with the key of the builder its group names.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ dom0Update ];

    # Additive while dom0 still has internet (until v2.5): the existing
    # substituters stay, the builder key is trusted on top
    nix.settings.trusted-public-keys = lib.optional (builderKey != null) builderKey;

    # ssh-keygen allowed signers for the image manifests (nox-image fetch):
    # one principal per builder VM, its name
    environment.etc."nox/image-signers" = lib.mkIf (imageKeys != { }) {
      text = lib.concatStrings (
        lib.mapAttrsToList (name: key: "${name} namespaces=\"nox-image\" ${key}\n") imageKeys
      );
    };
  };
}

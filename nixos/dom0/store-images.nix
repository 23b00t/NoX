# Store images outside dom0's store (builder-trust.md 3.1, plan step 3):
# with `nox.storeImages.asFiles` every runner boots from /var/lib/nox/images/<dir>/<hash>-<name>
# (vms/store-groups.nix imageFileModuleFor), dom0's closure holds no image.
# - /etc/nox/images: the images this system expects, one "<dir> <store path>
#   <builder> <drv>" per line (no string context: listing them doesn't pull
#   them in). <builder>: the builder VM that builds it (nox.storeGroups.<g>.builder)
# - system.build.builderOutputs: what the (sys) builder builds for this
#   machine, `system` (the toplevel) and `images/<dir>/<file>` of its own
#   images; dom0-update copies the toplevel through Nix and the images as
#   files with a signed manifest. Images of another builder (builder-apps)
#   are built there from the derivations dom0 hands over
# - nox-image: list/missing/drvs (anyone), fetch (as the user, sudo for
#   put), put/install-local/gc (root)
{
  lib,
  pkgs,
  config,
  ...
}:
let
  root = "/var/lib/nox/images";

  vmImages = lib.filter (i: i != null) (
    lib.mapAttrsToList (_: vm: vm.config.config.nox.storeImage or null) (config.microvm.vms or { })
  );
  # One entry per image (group members share it)
  byFile = lib.listToAttrs (
    map (i: {
      name = "${i.dir}/${builtins.unsafeDiscardStringContext (baseNameOf i.image)}";
      value = i;
    }) vmImages
  );

  expected = lib.concatStrings (
    lib.mapAttrsToList (
      _: i:
      "${i.dir} ${builtins.unsafeDiscardStringContext i.image.outPath} ${i.builder} ${builtins.unsafeDiscardStringContext i.image.drvPath}\n"
    ) byFile
  );
  ownImages = lib.filterAttrs (_: i: i.builder == "builder") byFile;

  noxImage = pkgs.writeShellScriptBin "nox-image" ''
    set -euo pipefail
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.findutils
        pkgs.gawk
        config.nix.package
      ]
    }:$PATH
    root=${root}

    usage() {
      cat >&2 <<EOF
    usage: nox-image list [<system>]       expected store images, present or missing
           nox-image missing [<system>]    only the missing ones ("<dir> <store path> <builder> <drv>")
           nox-image drvs <system> <builder>
                                          the missing ones of <builder> as "<dir>=<drv>"
           nox-image fetch <system> <builder> <machine>
                                          fetch the missing ones of <builder> (the builder VM's
                                          name) from it (as yourself; sudo for put)
           nox-image install-local [<system>]
                                          copy missing images from dom0's own store (root)
           nox-image put --system <system> <dir> <store path> <sha256> < image
                                          check and store one image (root)
           nox-image gc                    delete images no system, rollback or mark needs (root)
           nox-image gc -n [--drop <gen>…] only list them (as if generations <gen>… were deleted)
    <system> defaults to /run/current-system.
    EOF
      exit 2
    }

    expected() { # <system>: "<dir> <store path> <builder> <drv>" lines
      [ ! -r "$1/etc/nox/images" ] || cat "$1/etc/nox/images"
    }
    file_of() { # <dir> <store path>
      echo "$root/$1/''${2##*/}"
    }
    valid() { # <dir> <store path>
      [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]] &&
        [[ $2 =~ ^/nix/store/[0-9a-z]{32}-microvm-store-disk\.(erofs|squashfs)$ ]]
    }
    # Copy into place: a temporary name first, so a VM never sees half a file
    place() { # <dir> <store path> <tmp file>
      chmod 0444 "$3"
      mkdir -p "$root/$1"
      mv -fT "$3" "$(file_of "$1" "$2")"
    }

    cmd="''${1:-}"
    [ $# -eq 0 ] || shift
    case "$cmd" in
      list | missing)
        sys="''${1:-/run/current-system}"
        while read -r dir path rest; do
          f="$(file_of "$dir" "$path")"
          if [ -e "$f" ]; then
            [ "$cmd" = missing ] || printf 'present  %s\n' "$f"
          elif [ "$cmd" = missing ]; then
            printf '%s %s %s\n' "$dir" "$path" "$rest"
          else
            printf 'MISSING  %s\n' "$f"
          fi
        done < <(expected "$sys")
        ;;
      drvs)
        [ $# -eq 2 ] || usage
        "$0" missing "$1" | awk -v b="$2" '$3 == b { print $1 "=" $4 }'
        ;;
      fetch)
        # The builder's manifest (builder-build, builder-images): "<dir>
        # <store path> <sha256>" per image, signed with its image key; the
        # keys this system trusts are in <system>/etc/nox/image-signers
        # (dom0-update imageKeys), one per builder, and only the key of
        # the image's own builder counts. Each image streams through put,
        # which checks it is expected and its sha256
        [ $# -eq 3 ] || usage
        sys="$1" builder="$2" machine="$3"
        [[ $builder =~ ^[a-z0-9-]+$ && $machine =~ ^[a-z0-9-]+$ ]] || usage
        mapfile -t need < <("$0" missing "$sys" | awk -v b="$builder" '$3 == b { print $1 " " $2 }')
        [ "''${#need[@]}" -gt 0 ] || exit 0
        signers="$sys/etc/nox/image-signers"
        [ -r "$signers" ] || {
          echo "nox-image: no image keys in $sys (services.dom0-update.imageKeys)" >&2
          exit 1
        }
        mdir="$(mktemp -d)"
        trap 'rm -rf "$mdir"' EXIT
        ssh "$builder-vm" cat "/var/lib/builder/images/$machine.manifest" > "$mdir/manifest"
        ssh "$builder-vm" cat "/var/lib/builder/images/$machine.manifest.sig" > "$mdir/manifest.sig"
        if ! ${pkgs.openssh}/bin/ssh-keygen -Y verify -f "$signers" -I "$builder" \
          -n nox-image -s "$mdir/manifest.sig" < "$mdir/manifest" >/dev/null; then
          echo "nox-image: $builder's image manifest has no valid signature of its image key: rejected" >&2
          exit 1
        fi
        for e in "''${need[@]}"; do
          dir="''${e%% *}" path="''${e#* }"
          valid "$dir" "$path" || { echo "nox-image: invalid entry $e" >&2; exit 1; }
          sha="$(awk -v d="$dir" -v p="$path" '$1 == d && $2 == p { print $3 }' "$mdir/manifest")"
          [ -n "$sha" ] || {
            echo "nox-image: $dir $path is not in $builder's manifest: rejected" >&2
            exit 1
          }
          echo "nox-image: fetching $dir/''${path##*/} from $builder" >&2
          ssh "$builder-vm" cat "$path" | sudo "$0" put --system "$sys" "$dir" "$path" "$sha"
        done
        ;;
      install-local)
        sys="''${1:-/run/current-system}"
        mkdir -p "$root/.incoming"
        rc=0
        while read -r dir path _; do
          valid "$dir" "$path" || { echo "nox-image: invalid entry $dir $path" >&2; exit 1; }
          if [ ! -e "$path" ]; then
            echo "nox-image: $path is not in dom0's store" >&2
            rc=1
            continue
          fi
          tmp="$root/.incoming/''${path##*/}.$$"
          cp --sparse=always "$path" "$tmp"
          place "$dir" "$path" "$tmp"
          echo "nox-image: $(file_of "$dir" "$path") (from the local store)" >&2
        done < <("$0" missing "$sys")
        exit "$rc"
        ;;
      put)
        [ "''${1:-}" = --system ] && [ $# -eq 5 ] || usage
        sys="$2" dir="$3" path="$4" sha="$5"
        valid "$dir" "$path" || { echo "nox-image: invalid entry $dir $path" >&2; exit 1; }
        [[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "nox-image: invalid sha256 $sha" >&2; exit 1; }
        expected "$sys" | awk -v d="$dir" -v p="$path" '$1 == d && $2 == p { f = 1 } END { exit !f }' ||
          { echo "nox-image: $sys doesn't expect $dir $path" >&2; exit 1; }
        mkdir -p "$root/.incoming"
        tmp="$root/.incoming/''${path##*/}.$$"
        trap 'rm -f "$tmp"' EXIT
        cat > "$tmp"
        got="$(sha256sum "$tmp" | cut -d' ' -f1)"
        if [ "$got" != "$sha" ]; then
          echo "nox-image: $path: sha256 $got, the manifest says $sha: rejected" >&2
          exit 1
        fi
        place "$dir" "$path" "$tmp"
        trap - EXIT
        echo "nox-image: $(file_of "$dir" "$path")" >&2
        ;;
      gc)
        dry=0
        declare -A drop=()
        [ "''${1:-}" != -n ] || { dry=1; shift; }
        # --drop <gen>…: count as if these generations were deleted (the
        # dry run of nox gc, before it deletes them)
        if [ "''${1:-}" = --drop ]; then
          [ "$dry" = 1 ] || usage
          shift
          for g in "$@"; do drop["/nix/var/nix/profiles/system-$g-link"]=1; done
        fi
        # Kept: what any system generation (and the running and booted
        # system) expects, and what a VM's current, booted, rollback or
        # mark runner boots from
        declare -A keep=()
        for s in /nix/var/nix/profiles/system-*-link /run/current-system /run/booted-system; do
          [ -e "$s" ] || continue
          [ -z "''${drop[$s]:-}" ] || continue
          while read -r dir path _; do
            keep["$(file_of "$dir" "$path")"]=1
          done < <(expected "$s")
        done
        for l in /var/lib/microvms/*/{current,booted,rollback,mark}; do
          [ -e "$l" ] || continue
          for c in $(nix-store -qR "$l" 2>/dev/null | grep -- '-xl\.cfg$' || true); do
            for f in $(grep -ho "$root/[^\", ]*" "$c" || true); do
              keep["$f"]=1
            done
          done
        done
        [ -d "$root" ] || exit 0
        freed=0
        while IFS= read -r -d "" f; do
          [ -z "''${keep[$f]:-}" ] || continue
          sz="$(du -m --apparent-size "$f" | cut -f1)"
          freed=$((freed + sz))
          if [ "$dry" = 1 ]; then
            echo "would delete $f ($sz MB)"
          else
            rm -f "$f"
            echo "deleted $f ($sz MB)"
          fi
        done < <(find "$root" -mindepth 2 -maxdepth 2 -type f -print0)
        if [ "$dry" = 0 ]; then
          find "$root" -mindepth 1 -maxdepth 1 -type d -empty -delete
        fi
        echo "nox-image gc: $freed MB$([ "$dry" = 0 ] || echo ' would be') freed" >&2
        ;;
      *) usage ;;
    esac
  '';
  cfg = config.nox.storeImages;
in
{
  options.nox.storeImages.asFiles = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Boot the VMs from copies of their store images in /var/lib/nox/images
      instead of the store paths: dom0's closure then holds no image, and
      dom0-update takes them from the builder as files with a signed
      manifest (builder-trust.md 3.1). Needs the builder's image key
      (`services.dom0-update.imageKey`). Turn it on only after one update
      with it off, so the builder runs a builder-build that delivers images
      and has generated its key. A local build (nixos-rebuild) brings no
      images: build `system.build.builderOutputs` and run
      `sudo nox-image install-local <system>` before switching.
    '';
  };

  config = {
    environment.etc."nox/images".text = lib.optionalString cfg.asFiles expected;

    # A switch to a system whose images are missing: its VMs won't start
    system.activationScripts.noxImages = lib.mkIf cfg.asFiles ''
      if missing="$(${noxImage}/bin/nox-image missing "$systemConfig")" && [ -n "$missing" ]; then
        echo "warning: store images missing in ${root}, VMs using them won't start:" >&2
        echo "$missing" >&2
        echo "(dom0-update fetches them; after a local build: nox-image install-local)" >&2
      fi
    '';

    system.build.builderOutputs = pkgs.linkFarm "nox-builder-${config.networking.hostName}" (
      [
        {
          name = "system";
          path = config.system.build.toplevel;
        }
      ]
      ++ lib.mapAttrsToList (name: i: {
        name = "images/${name}";
        path = i.image;
      }) ownImages
    );

    environment.systemPackages = [ noxImage ];

    systemd.tmpfiles.rules = [ "d ${root} 0755 root root -" ];
  };
}

# Store images outside dom0's store (builder-trust.md 3.1, plan step 3):
# with `nox.storeImages.asFiles` every runner boots from /var/lib/nox/images/<dir>/<hash>-<name>
# (vms/store-groups.nix imageFileModuleFor), dom0's closure holds no image.
# - /etc/nox/images: the images this system expects, one "<dir> <store path>
#   <builder> <drv>" per line (no string context: listing them doesn't pull
#   them in). <builder>: the builder VM that builds it (nox.storeGroups.<g>.builder)
# - system.build.builderOutputs: what the (sys) builder builds for this
#   machine, `system` (the toplevel) and `images/<dir>/<file>` of its own
#   images; dom0-update copies the toplevel through Nix and the images as
#   files with a signed manifest. Images of a group builder (nox.builders)
#   are built there from the derivations dom0 hands over
# - nox-image: list/missing/drvs (anyone), fetch (as the user, sudo for
#   put), put/install-local/gc (root)
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  root = "/var/lib/nox/images";
  groupBuilders = vmRegistry.storeGroupBuilders or { };
  sysBuilder = groupBuilders.sys or "builder";

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
  # VMs with an image of their own (no store group)
  standalone = lib.unique (map (i: i.dir) (lib.filter (i: !(groupBuilders ? ${i.dir})) vmImages));

  # Free space put leaves on dom0's disk, whatever a builder sends
  reserveMB = 10240;
  reserveBytes = reserveMB * 1024 * 1024;
  # Builder stderr only through the terminal filter (modules/dom0-update.nix)
  termFilter =
    if config.programs ? nox then "${config.programs.nox.package}/bin/nox term-filter" else "cat";

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
           nox-image put --system <system> --builder <builder> --manifest <file> --sig <file>
                         <dir> <store path> < image
                                          check and store one image of <builder>'s signed
                                          manifest (root)
           nox-image pending [-d] <system> mark <system> as being fetched (dom0-update), so gc
                                          keeps its images; -d: drop the mark (root)
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
    valid_system() { # <system>
      [[ $1 =~ ^/nix/store/[0-9a-z]{32}-nixos-system-[A-Za-z0-9._+-]+$ || $1 == /run/current-system ]]
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
        # <store path> <sha256> <size>" per image, signed with its image key; the
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
        # The builder's stderr only through the terminal filter (OSC 52,
        # titles, queries dropped; modules/dom0-update.nix)
        ssh "$builder-vm" cat "/var/lib/builder/images/$machine.manifest" \
          > "$mdir/manifest" 2> >(${termFilter} >&2)
        ssh "$builder-vm" cat "/var/lib/builder/images/$machine.manifest.sig" \
          > "$mdir/manifest.sig" 2> >(${termFilter} >&2)
        if ! ${pkgs.openssh}/bin/ssh-keygen -Y verify -f "$signers" -I "$builder" \
          -n nox-image -s "$mdir/manifest.sig" < "$mdir/manifest" >/dev/null; then
          echo "nox-image: $builder's image manifest has no valid signature of its image key: rejected" >&2
          exit 1
        fi
        for e in "''${need[@]}"; do
          dir="''${e%% *}" path="''${e#* }"
          valid "$dir" "$path" || { echo "nox-image: invalid entry $e" >&2; exit 1; }
          awk -v d="$dir" -v p="$path" '$1 == d && $2 == p { f = 1 } END { exit !f }' "$mdir/manifest" || {
            echo "nox-image: $dir $path is not in $builder's manifest: rejected" >&2
            exit 1
          }
          echo "nox-image: fetching $dir/''${path##*/} from $builder" >&2
          # put checks the manifest again itself (as root)
          ssh "$builder-vm" cat "$path" 2> >(${termFilter} >&2) |
            sudo "$0" put --system "$sys" --builder "$builder" \
              --manifest "$mdir/manifest" --sig "$mdir/manifest.sig" "$dir" "$path"
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
        # Trusts its caller for nothing (builder-trust.md 13 "Härtung"):
        # the system is a NixOS system in the store, the image is one it
        # expects from <builder>, sha256 and size come from <builder>'s
        # manifest, checked here against that builder's image key
        [ $# -eq 10 ] && [ "$1" = --system ] && [ "$3" = --builder ] &&
          [ "$5" = --manifest ] && [ "$7" = --sig ] || usage
        sys="$2" builder="$4" dir="$9" path="''${10}"
        valid_system "$sys" || { echo "nox-image: $sys is not a system in /nix/store" >&2; exit 1; }
        [[ $builder =~ ^[a-z0-9-]+$ ]] || usage
        valid "$dir" "$path" || { echo "nox-image: invalid entry $dir $path" >&2; exit 1; }
        expected "$sys" | awk -v d="$dir" -v p="$path" -v b="$builder" '$1 == d && $2 == p && $3 == b { f = 1 } END { exit !f }' ||
          { echo "nox-image: $sys doesn't expect $dir $path from $builder" >&2; exit 1; }
        # Own copies (the caller's files may change after the check)
        mdir="$(mktemp -d)"
        tmp=""
        trap 'rm -rf "$mdir" ''${tmp:+"$tmp"}' EXIT
        head -c 1048576 < "$6" > "$mdir/manifest"
        head -c 65536 < "$8" > "$mdir/manifest.sig"
        if ! ${pkgs.openssh}/bin/ssh-keygen -Y verify -f "$sys/etc/nox/image-signers" -I "$builder" \
          -n nox-image -s "$mdir/manifest.sig" < "$mdir/manifest" >/dev/null; then
          echo "nox-image: $builder's image manifest has no valid signature of its image key: rejected" >&2
          exit 1
        fi
        # sha256 and size (bytes; missing in manifests of older builders)
        sha="" size=""
        read -r sha size < <(awk -v d="$dir" -v p="$path" '$1 == d && $2 == p { print $3, $4; exit }' "$mdir/manifest") || true
        [ -n "$sha" ] || { echo "nox-image: $dir $path is not in $builder's manifest: rejected" >&2; exit 1; }
        [[ $sha =~ ^[0-9a-f]{64}$ ]] || { echo "nox-image: invalid sha256 $sha" >&2; exit 1; }
        [[ -z $size || $size =~ ^[0-9]{1,15}$ ]] || { echo "nox-image: invalid size $size" >&2; exit 1; }
        mkdir -p "$root/.incoming"
        # Never more than the free space minus a reserve, never more than
        # the size the manifest names: a builder can't fill dom0's disk
        # (builder-trust.md 13.5)
        avail="$(df --output=avail -B1 "$root/.incoming" | tail -n 1 | tr -d ' ')"
        max=$((avail - ${toString reserveBytes}))
        if [ -n "$size" ]; then
          [ "$size" -le "$max" ] || {
            echo "nox-image: $path: $((size >> 20)) MB, only $((max > 0 ? max >> 20 : 0)) MB free above the reserve of ${toString reserveMB} MB: rejected" >&2
            exit 1
          }
          max=$size
        fi
        [ "$max" -gt 0 ] || { echo "nox-image: $root: less than ${toString reserveMB} MB free: rejected" >&2; exit 1; }
        tmp="$root/.incoming/''${path##*/}.$$"
        # One byte more than allowed: tells a longer stream from an exact one.
        # The sha256 on the way in, not by reading the file again (13 "Härtung")
        got="$(head -c "$((max + 1))" | tee "$tmp" | sha256sum | cut -d' ' -f1)"
        got_size="$(stat -c %s "$tmp")"
        if [ "$got_size" -gt "$max" ]; then
          echo "nox-image: $path: more than $max bytes: rejected" >&2
          exit 1
        fi
        if [ -n "$size" ] && [ "$got_size" != "$size" ]; then
          echo "nox-image: $path: $got_size bytes, the manifest says $size: rejected" >&2
          exit 1
        fi
        if [ "$got" != "$sha" ]; then
          echo "nox-image: $path: sha256 $got, the manifest says $sha: rejected" >&2
          exit 1
        fi
        place "$dir" "$path" "$tmp"
        echo "nox-image: $(file_of "$dir" "$path")" >&2
        ;;
      pending)
        # A mark per system whose images dom0-update is fetching: it isn't a
        # generation yet (the profile is set only once all images are
        # here), gc keeps its images all the same
        del=0
        [ "''${1:-}" != -d ] || { del=1; shift; }
        [ $# -eq 1 ] || usage
        valid_system "$1" || { echo "nox-image: $1 is not a system in /nix/store" >&2; exit 1; }
        if [ "$del" = 1 ]; then
          rm -f "$root/.pending/''${1##*/}"
        else
          mkdir -p "$root/.pending"
          ln -sfn "$1" "$root/.pending/''${1##*/}"
        fi
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
        # mark runner boots from; and what a system expects whose images an
        # update is fetching (pending). A pending mark older than a day is
        # left over from an update that ended without dropping it: ignored,
        # and deleted by a real gc
        declare -A keep=()
        pending=()
        if [ -d "$root/.pending" ]; then
          mapfile -t pending < <(find "$root/.pending" -mindepth 1 -maxdepth 1 -type l -mmin -1440)
          [ "$dry" = 1 ] || find "$root/.pending" -mindepth 1 -maxdepth 1 -type l -mmin +1440 -delete
        fi
        for s in /nix/var/nix/profiles/system-*-link /run/current-system /run/booted-system "''${pending[@]}"; do
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
        # Not in .incoming (fetches still running) nor .pending
        done < <(find "$root" -mindepth 2 -maxdepth 2 -type f -not -path "$root/.*" -print0)
        if [ "$dry" = 0 ]; then
          find "$root" -mindepth 1 -maxdepth 1 -type d -empty -not -name ".*" -delete
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
    # builder-trust.md 3.8: every group's builder exists; the builder VMs'
    # image comes from the builder (no group builder runs on an image it
    # built); the sys builder builds no other group
    assertions = lib.optionals cfg.asFiles (
      lib.mapAttrsToList (g: b: {
        assertion = b == "builder" || builtins.any (vm: vm.name == b) vmRegistry.vms;
        message = "nox.storeGroups.${g}.builder: no builder VM ${b} on this machine (nox.builders, nox.vms.${b}.enable)";
      }) groupBuilders
      ++ [
        {
          assertion = (groupBuilders.builders or "builder") == "builder";
          message = "nox.storeGroups.builders.builder must stay \"builder\": a group builder may not build the builders' image";
        }
        {
          assertion =
            sysBuilder == "builder"
            || lib.all (g: g == "sys" || groupBuilders.${g} != sysBuilder) (lib.attrNames groupBuilders);
          message = "nox.storeGroups: ${sysBuilder} builds sys and may build no other group";
        }
        # An own image (storeGroup = null) is built by the builder VM, which
        # builds dom0: with group builders that is someone else's code there
        # (builder-trust.md 13 "Härtung")
        {
          assertion = lib.all (b: b == "builder") (lib.attrValues groupBuilders) || standalone == [ ];
          message = "nox.storeImages.asFiles with group builders (nox.builders): ${lib.concatStringsSep ", " standalone} without a store group would be built by the builder VM; give them one (nox.vms.<name>.storeGroup)";
        }
      ]
    );

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

    # Store images and VM volumes hang in dom0 as loop devices with content
    # dom0 doesn't trust (a group builder's image, a VM's home.img): no
    # blkid on them, so no /dev/disk/by-label|by-uuid links, and LVM, bcache
    # and md, which go by blkid's ID_FS_TYPE, never look at them
    # (builder-trust.md 13.3). Before 60-persistent-storage.rules
    services.udev.packages = [
      (pkgs.writeTextDir "lib/udev/rules.d/59-nox-vm-volumes.rules" ''
        SUBSYSTEM=="block", KERNEL=="loop[0-9]*", ACTION!="remove", ATTR{loop/backing_file}=="${root}/*|/var/lib/microvms/*", ENV{UDEV_DISABLE_PERSISTENT_STORAGE_RULES_FLAG}="1"
      '')
    ];
  };
}

# Group builder builder-<name> (nox.builders, builder-trust.md 3.6/3.8,
# variants B/C/C+): builds the store images of the groups with
# `nox.storeGroups.<g>.builder = "builder-<name>"` from derivations dom0
# hands over (the builder evaluated them), signs a manifest with its own
# image key; dom0 takes these images only with this key. No checkout, no
# deploy key, no evaluation: it never reads the config repo. dom0 may push
# paths signed by the builder (its Rust builds) in before the build (3.7):
# this builder trusts that key on top of Hydra's.
{
  lib,
  pkgs,
  config,
  vmRegistry,
  builderName,
  builderSettings,
  ...
}:
let
  stateDir = "/var/lib/builder";
  reg = lib.findFirst (vm: vm.name == builderName) vmRegistry.byName.${builderName} vmRegistry.vms;
  index = lib.toInt (lib.last (lib.splitString "." reg.ip));
  hex = lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString index));
  sysKeyFile = vmRegistry.builderKeys + "/signing-key-${vmRegistry.host or ""}.pub";
  sysKey =
    if vmRegistry.host or null != null && builtins.pathExists sysKeyFile then
      lib.trim (builtins.readFile sysKeyFile)
    else
      null;

  # builder-images <machine> <dir>=<drv>…: builds the images, deletes the
  # ones no longer asked for, writes and signs images/<machine>.manifest
  # ("<dir> <store path> <sha256> <size>", like builder-build), prints its path
  builderImages = pkgs.writeShellScriptBin "builder-images" ''
    set -euo pipefail
    nix=${config.nix.package}/bin
    # --max-jobs/--cores: for this run only, instead of nix.settings
    # (dom0-update --max-jobs/--cores)
    jobs=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --max-jobs)
          [[ ''${2:-} =~ ^[1-9][0-9]{0,2}$ ]] || { echo "builder-images: --max-jobs needs a number 1-999" >&2; exit 2; }
          jobs+=(--max-jobs "$2"); shift 2 ;;
        --cores)
          [[ ''${2:-} =~ ^[0-9]{1,3}$ ]] || { echo "builder-images: --cores needs a number 0-999" >&2; exit 2; }
          jobs+=(--cores "$2"); shift 2 ;;
        *) break ;;
      esac
    done
    machine="''${1:?usage: builder-images [--max-jobs <n>] [--cores <n>] <machine> <dir>=<drv>…}"
    shift
    [[ $machine =~ ^[a-z0-9-]+$ ]] || { echo "builder-images: bad machine $machine" >&2; exit 2; }
    imagekey="${stateDir}/image-key"
    [ -r "$imagekey" ] || { echo "builder-images: image key $imagekey missing" >&2; exit 1; }
    timing() {
      local now=$SECONDS
      echo "builder-images: timing $1 $((now - t0)) s" >&2
      ${pkgs.util-linux}/bin/logger -t builder-images "timing $machine $1 $((now - t0)) s" || true
      t0=$now
    }
    t0=$SECONDS
    t_start=$SECONDS

    roots="${stateDir}/images/roots-$machine"
    rm -rf "$roots"
    mkdir -p "$roots" ${stateDir}/image-sha
    manifest="${stateDir}/images/$machine.manifest"
    : > "$manifest.new"
    for a in "$@"; do
      dir="''${a%%=*}" drv="''${a#*=}"
      [[ $dir =~ ^[a-z0-9][a-z0-9-]*$ && $drv =~ ^/nix/store/[0-9a-z]{32}-microvm-store-disk\.(erofs|squashfs)\.drv$ ]] ||
        { echo "builder-images: bad argument $a" >&2; exit 2; }
      out="$( {
        $nix/nix build --print-out-paths --out-link "$roots/$dir" "''${jobs[@]}" \
          --log-format internal-json -v "$drv^*" \
          2>&1 1>&3 | ${pkgs.nix-output-monitor}/bin/nom --json >&2
      } 3>&1 )"
      el="$($nix/nix log "$drv" 2>/dev/null | grep -o '[0-9:.]*elapsed' | tail -n 1 || true)"
      timing "build $dir (mkfs ''${el:-cached}, $(du -m --apparent-size "$out" | cut -f1) MB)"
      c="${stateDir}/image-sha/''${out##*/}"
      [ -s "$c" ] || sha256sum "$out" | cut -d' ' -f1 > "$c"
      echo "$dir $out $(cat "$c") $(stat -L -c %s "$out")" >> "$manifest.new"
    done
    mv -f "$manifest.new" "$manifest"
    rm -f "$manifest.sig"
    ${pkgs.openssh}/bin/ssh-keygen -q -Y sign -n nox-image -f "$imagekey" "$manifest"
    timing "manifest ($# store images)"

    # Images no longer asked for (an older generation): delete them now
    mapfile -t dead < <($nix/nix-store --gc --print-dead 2>/dev/null |
      grep -E -- '-microvm-store-disk\.(erofs|squashfs)$' || true)
    [ "''${#dead[@]}" -eq 0 ] || $nix/nix-store --delete "''${dead[@]}" >/dev/null 2>&1 || true
    for c in ${stateDir}/image-sha/*; do
      [ ! -e "$c" ] || [ -e "/nix/store/''${c##*/}" ] || rm -f "$c"
    done
    t0=$t_start
    timing total
    echo "$manifest"
  '';
in
{
  imports = [
    ../modules/net-config.nix
    ../modules/common-config.nix
    ../modules/persistent-store-overlay.nix
  ];

  networking.hostName = "${builderName}-vm";

  services = {
    net-config = {
      enable = true;
      inherit index;
      mac = "00:00:00:00:00:${hex}";
    };
    common-config = {
      enable = true;
      withDefaultPkgs = false;
    };
    persistentStoreOverlay = {
      enable = true;
      overlaySize = reg.storeSize;
      # GC by min-free only, like the sys builder
      gcTimer = false;
    };
  };

  microvm = {
    registerClosure = true;
    hypervisor = "xen";
    volumes = [
      {
        # Image key, manifests, out-links, build directories
        image = "builder.img";
        mountPoint = stateDir;
        size = 20000;
      }
      {
        image = "log.img";
        mountPoint = "/var/log";
        size = 2048;
      }
    ];
    mem = reg.memoryMax;
    balloon = true;
    initialBalloonMem = reg.memory;
    vcpu = 8;
  };

  systemd = {
    tmpfiles.rules = [
      "d ${stateDir} 0755 user users -"
      "d ${stateDir}/images 0755 user users -"
      "d ${stateDir}/build 0755 root root -"
    ];
    services.builder-image-key = {
      description = "Generate the app builder's image key";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      unitConfig.RequiresMountsFor = [ stateDir ];
      serviceConfig = {
        Type = "oneshot";
        User = "user";
        UMask = "0077";
      };
      path = [ pkgs.openssh ];
      script = ''
        if [ ! -e ${stateDir}/image-key ]; then
          ssh-keygen -q -t ed25519 -N "" -C ${builderName}-image -f ${stateDir}/image-key
          chmod 644 ${stateDir}/image-key.pub
        fi
      '';
    };
  };
  systemd.sockets.nix-daemon.unitConfig.RequiresMountsFor = [ stateDir ];

  nix.settings = {
    # nox.builders.<name>.maxJobs/cores; default one job per 8 GB, at least 2
    max-jobs =
      if builderSettings.maxJobs != null then
        builderSettings.maxJobs
      else
        lib.max 2 (reg.memoryMax / 8192);
    cores = lib.mkIf (builderSettings.cores != null) builderSettings.cores;
    build-dir = "${stateDir}/build";
    # Builds derivations only; it never evaluates
    allow-import-from-derivation = false;
    http2 = false;
    # Paths dom0 pushes in (built by the sys builder, 3.7)
    trusted-public-keys = lib.optional (sysKey != null) sysKey;
  };

  zramSwap = {
    enable = true;
    memoryPercent = 200;
  };

  environment.systemPackages = [ builderImages ];

  system.stateVersion = "26.05";
}

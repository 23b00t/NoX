# Shared read-only store images per trust group (registry field `storeGroup`).
# Each group image holds the union of the store closures of its members; every
# member boots its own toplevel from it. VMs without a group keep their own image.
# Only VMs that boot from a store disk count (Xen); VMs with the host's
# /nix/store as virtiofs share are left alone.
#
# vmSystems: VM name -> evaluated NixOS system of that VM (needs `.config`).
# The members' `microvm.storeDiskContents` don't depend on `microvm.storeDisk`,
# so passing the very systems that use the images is fine (no eval cycle).
{
  lib,
  buildStoreDisk,
  vmRegistry,
  vmSystems,
}:
let
  # The machine's entries (`vms`): `byName` is evaluated without a host, so
  # a per-machine storeGroup (`if host == …`) is only right in `vms`
  hostByName = lib.listToAttrs (map (vm: lib.nameValuePair vm.name vm) vmRegistry.vms);
  groupOf = name: (hostByName.${name} or vmRegistry.byName.${name} or { }).storeGroup or null;

  members = builtins.filter (
    vm:
    groupOf vm.name != null && vmSystems ? ${vm.name} && vmSystems.${vm.name}.config.microvm.storeOnDisk
  ) vmRegistry.vms;

  byGroup = lib.groupBy (vm: vm.storeGroup) members;

  mkImage =
    group: vms:
    let
      systems = map (vm: vmSystems.${vm.name}) vms;
      first = (builtins.head systems).config.microvm;
      sameAsFirst =
        system:
        let
          cfg = system.config.microvm;
        in
        cfg.storeDiskType == first.storeDiskType
        && cfg.storeDiskErofsFlags == first.storeDiskErofsFlags
        && cfg.storeDiskSquashfsFlags == first.storeDiskSquashfsFlags;
    in
    if !builtins.all sameAsFirst systems then
      throw "storeGroup ${group}: all members need the same storeDiskType and storeDisk flags"
    else
      buildStoreDisk {
        inherit (builtins.head systems) pkgs;
        type = first.storeDiskType;
        erofsFlags = first.storeDiskErofsFlags;
        squashfsFlags = first.storeDiskSquashfsFlags;
        contents = contentsOf vms ++ lib.optional (groupInfos ? ${group}) groupInfos.${group};
      };

  contentsOf = builtins.concatMap (vm: vmSystems.${vm.name}.config.microvm.storeDiskContents);

  # A member with a writable store overlay (registerClosure) registers only
  # its own closure: the nix GC in it would delete the other members' paths
  # in the image (one whiteout each in its persistent upper; builder-trust.md
  # 3.0). For such groups the image carries a registration of all its
  # contents and the list of their roots; nix-db-restore
  # (persistent-store-overlay.nix) loads it from /nix/.ro-store and roots
  # them on every boot (kernel parameter noxStoreGroup)
  groupInfos = lib.mapAttrs (
    group: vms:
    let
      inherit (vmSystems.${(builtins.head vms).name}) pkgs;
      contents = contentsOf vms;
      reg = pkgs.closureInfo { rootPaths = contents; };
    in
    pkgs.runCommand "nox-store-group-${group}"
      {
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
        roots = map (p: builtins.unsafeDiscardStringContext (toString p)) contents;
      }
      ''
        mkdir $out
        cp ${reg}/registration $out/registration
        printf '%s\n' "''${roots[@]}" > $out/roots
      ''
  ) (lib.filterAttrs (_: vms: builtins.any registers vms) byGroup);

  registers = vm: vmSystems.${vm.name}.config.microvm.registerClosure;

  images = builtins.mapAttrs mkImage byGroup;
in
{
  inherit images;

  # Module for VM `name`: boot from its group's image (no-op for standalone VMs
  # and for VMs not on this machine, whose closure is not in the image)
  # Also for every VM: register the store closure in the Nix DB at boot
  # (`nix-store --load-db`) only with a writable store overlay. On the
  # read-only store nix can't build or fetch anyway, and the load failed
  # (`.links`: read-only) and cost seconds of every boot (nvim, 2026-10-17)
  moduleFor =
    name:
    { config, ... }:
    {
      microvm = {
        registerClosure = lib.mkDefault (config.services.persistentStoreOverlay.enable or false);
        # Plain lz4 + tailpacking: ~30-40 % faster mkfs than the fork's
        # default (lz4hc + fragments), ~7 % larger (builder-trust.md N4).
        # Here, because both evaluations of a VM (nixosConfigurations.<vm>
        # and dom0's microvm.vms) take this module; equal in every group
        storeDiskErofsFlags = [
          "-zlz4"
          "-Eztailpacking"
        ];
      }
      // lib.optionalAttrs (groupOf name != null && builtins.any (vm: vm.name == name) vmRegistry.vms) {
        storeDisk = lib.mkIf config.microvm.storeOnDisk images.${groupOf name};
        # The group's registration (groupInfos above), read from the image
        # itself: no string context, dom0's closure doesn't need it
        kernelParams = lib.mkIf (
          config.microvm.storeOnDisk && config.microvm.registerClosure && groupInfos ? ${groupOf name}
        ) [ "noxStoreGroup=${builtins.unsafeDiscardStringContext groupInfos.${groupOf name}.outPath}" ];
      };
    };

  # dom0 only (on top of moduleFor): with `asFiles` (nox.storeImages.asFiles)
  # the runner boots from a copy of the image outside the store,
  # /var/lib/nox/images/<dir>/<hash>-<name>, so dom0's closure holds no
  # store image (builder-trust.md 3.1). <dir> is the group, or the VM for
  # one with an image of its own. The path has no string context: dom0's
  # nix-daemon never sees the image. The image itself is `nox.storeImage`
  # (built by the builder, delivered as a file, dom0/store-images.nix)
  imageFileModuleFor =
    asFiles: name:
    {
      config,
      pkgs,
      ...
    }:
    let
      cfg = config.microvm;
      group = groupOf name;
      inGroup = group != null && builtins.any (vm: vm.name == name) vmRegistry.vms;
      # Same derivation as the microvm module's default storeDisk
      image =
        if inGroup then
          images.${group}
        else
          buildStoreDisk {
            inherit pkgs;
            type = cfg.storeDiskType;
            erofsFlags = cfg.storeDiskErofsFlags;
            squashfsFlags = cfg.storeDiskSquashfsFlags;
            contents = cfg.storeDiskContents;
          };
      dir = if inGroup then group else name;
      # nox.storeGroups.<g>.builder; own images: the (sys) builder
      builder = if inGroup then vmRegistry.storeGroupBuilders.${group} or "builder" else "builder";
      file = "/var/lib/nox/images/${dir}/${builtins.unsafeDiscardStringContext (baseNameOf image)}";
    in
    {
      options.nox.storeImage = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        default = null;
        internal = true;
        description = "The VM's store image: `dir` under /var/lib/nox/images, `image` (the derivation), `file` (where the runner expects it), `builder` (the builder VM that builds it).";
      };
      config = lib.mkIf cfg.storeOnDisk {
        nox.storeImage = {
          inherit
            dir
            image
            file
            builder
            ;
        };
        microvm.storeDisk = lib.mkIf asFiles (lib.mkForce file);
      };
    };
}

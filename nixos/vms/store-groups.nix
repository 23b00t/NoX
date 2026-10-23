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
  groupOf = name: vmRegistry.byName.${name}.storeGroup or null;

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
        contents = builtins.concatMap (system: system.config.microvm.storeDiskContents) systems;
      };

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
      }
      // lib.optionalAttrs (groupOf name != null && builtins.any (vm: vm.name == name) vmRegistry.vms) {
        storeDisk = lib.mkIf config.microvm.storeOnDisk images.${groupOf name};
      };
    };
}

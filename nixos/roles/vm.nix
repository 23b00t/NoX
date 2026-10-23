# What every VM with a role has, from its entry in nox.vms (definitions.nix):
# host name, network (index, MAC), home volume, RAM and vCPUs, its apps and
# the unfree rule. The entry is the module argument `noxVm` for the role
# modules and the VM's own module.
#
# Unfree: packages are allowed by name only (apps marked `unfree`, the VM's
# `unfree` list), never with `allowUnfree`, and only in an own store image or
# a store group marked unfree, so no proprietary package lands in the store
# image of, e.g., vault or office.
{
  name,
  vm,
  apps,
  groupUnfree,
}:
{ lib, pkgs, ... }:
let
  enabledApps = lib.filter (a: a.enable && a.package != null) (lib.attrValues apps);
  appPackage = a: lib.getAttrFromPath (lib.splitString "." a.package) pkgs;
  unfreeNames =
    map (a: lib.getName (appPackage a)) (lib.filter (a: a.unfree or false) enabledApps)
    ++ (if vm.unfree == null then [ ] else vm.unfree);
  unfreeAllowed = vm.storeGroup == null || groupUnfree;
  hex = lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString vm.index));
in
{
  imports = [
    ../vms/modules/net-config.nix
    ../vms/modules/common-config.nix
  ];

  _module.args.noxVm = vm // {
    inherit name;
  };

  networking.hostName = "${name}-vm";

  services = {
    net-config = {
      enable = true;
      inherit (vm) index;
      mac = "00:00:00:00:00:${hex}";
    };
    common-config.enable = true;
  };

  microvm = {
    hypervisor = "xen";
    volumes = lib.optional (vm.home.size != null) {
      mountPoint = "/home/user";
      image = "home.img";
      inherit (vm.home) size;
    };
  }
  // lib.optionalAttrs (vm.vcpu != null) { inherit (vm) vcpu; }
  // lib.optionalAttrs (vm.memoryMax != null) {
    # Boots with `memory`, the RAM balancer grows it up to `memoryMax`
    mem = vm.memoryMax;
    balloon = true;
    initialBalloonMem = vm.memory;
  }
  // lib.optionalAttrs (vm.memoryMax == null && vm.memory != null) { mem = vm.memory; };

  environment.systemPackages = map appPackage enabledApps;

  nixpkgs.config.allowUnfreePredicate = lib.mkIf (unfreeNames != [ ]) (
    pkg: builtins.elem (lib.getName pkg) unfreeNames
  );

  assertions = [
    {
      assertion = unfreeNames == [ ] || unfreeAllowed;
      message = "nox.vms.${name}: unfree packages (${lib.concatStringsSep ", " unfreeNames}) in store group `${toString vm.storeGroup}`, which is not marked `unfree` (nox.storeGroups); use an unfree group (prop) or an own image (storeGroup = null).";
    }
  ];

  system.stateVersion = lib.mkDefault "26.05";
}

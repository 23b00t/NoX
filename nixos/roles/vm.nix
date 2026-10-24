# What every VM with a role has, from its entry in nox.vms (definitions.nix):
# host name, network (index, MAC), home volume, RAM and vCPUs, its apps and
# the unfree rule. The entry is the module argument `noxVm` for the role
# modules and the VM's own module.
#
# Unfree: packages are allowed by name only (`nox.unfree`, set by the module
# that adds the package; apps marked `unfree` add theirs), never with
# `allowUnfree`, and only in an own store image or a store group marked
# unfree, so no proprietary package lands in the store image of, e.g., vault
# or office.
{
  name,
  vm,
  apps,
  groupUnfree,
}:
{
  config,
  lib,
  pkgs,
  vmRegistry,
  ...
}:
let
  enabledApps = lib.filter (a: a.enable && a.package or null != null && a.install or null != false) (
    lib.attrValues apps
  );
  appPackage = a: lib.getAttrFromPath (lib.splitString "." a.package) pkgs;
  unfree = config.nox.unfree;
  unfreeAllowed = vm.storeGroup == null || groupUnfree;
  hex = lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString vm.index));
in
{
  imports = [
    ../vms/modules/net-config.nix
    ../vms/modules/common-config.nix
  ];

  options.nox.unfree = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "claude-code" ];
    description = "Unfree packages (pname) allowed in this VM. Set it in the module that adds the package; only allowed in an own store image or a store group marked unfree.";
  };

  config = {
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
      # Off only for VMs that bring their own base (steam: gamescope session)
      common-config.enable = lib.mkDefault true;
    };

    microvm = {
      hypervisor = "xen";
      # Further volumes of the VM's module: lib.mkAfter, so home stays in front
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
    // lib.optionalAttrs (vm.memoryMax == null && vm.memory != null) { mem = vm.memory; }
    // lib.optionalAttrs (vm.gpu == true) {
      # The machine's GPU (hardware config) passed through
      devices = map (path: {
        bus = "pci";
        inherit path;
      }) (vmRegistry.hardware.pci.devicePaths.gpu or [ ]);
    };

    environment.systemPackages = map appPackage enabledApps;

    # Names from the attribute paths, not from the packages: nixpkgs.config
    # must not depend on pkgs
    nox.unfree = map (a: lib.last (lib.splitString "." a.package)) (
      lib.filter (a: a.unfree or null == true) enabledApps
    );

    nixpkgs.config = lib.mkIf (unfree != [ ]) {
      allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfree;
    };

    assertions = [
      {
        assertion = unfree == [ ] || unfreeAllowed;
        message = "nox.vms.${name}: unfree packages (${lib.concatStringsSep ", " unfree}) in store group `${toString vm.storeGroup}`, which is not marked `unfree` (nox.storeGroups); use an unfree group or an own image (storeGroup = null).";
      }
      {
        assertion = !(config.nixpkgs.config.allowUnfree or false) || unfreeAllowed;
        message = "nox.vms.${name}: nixpkgs.config.allowUnfree in store group `${toString vm.storeGroup}`, which is not marked `unfree`; name the unfree packages in `nox.unfree` instead.";
      }
    ];

    system.stateVersion = lib.mkDefault "26.05";
  };
}

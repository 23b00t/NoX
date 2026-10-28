# nox.lib.mkSystems: the flake glue of a NoX config (NoX modules step 4,
# formerly in the user's flake.nix and vms/registry.nix). Builds one
# nixosConfiguration per machine (dom0 with its VMs) and one per VM, the
# VMs' runners and the shared store images.
#
#   inputs          the config's flake inputs: nixpkgs, microvm, nox, and
#                   whatever the modules use (`inputs` special argument)
#   vms             module with the domains: nox.vms, nox.images, nox.infra,
#                   nox.apps, nox.roles, nox.storeGroups (evaluated per
#                   machine, special argument `host`)
#   modules         NixOS modules of every machine (after NoX's dom0 base)
#   machines.<host> { modules; hardware = { profile; usbDevices;
#                   pciDeviceIds; pciDevicePaths; }; } (registry/machine.nix)
#   vmView          machine whose registry the standalone VM outputs see
#   backupLuksUuids LUKS volumes `nox backup` takes right away (others: by passphrase)
#   builderKeys     directory with the builder's signing keys and allowed
#                   commit signers (dom0-update), null without a builder
#
# Returns { nixosConfigurations; packages; registry; vmSystems; }:
# `packages` holds the VMs' runners (packages.<system>.<vm>) and NoX's
# installer-iso, so the builder builds it from the config (dom0-update --iso).
{ self }:
{
  inputs,
  vms,
  machines,
  vmView,
  modules ? [ ],
  backupLuksUuids ? [ ],
  builderKeys ? null,
  system ? "x86_64-linux",
}:
let
  inherit (inputs) nixpkgs;
  inherit (nixpkgs) lib;

  registry = import ../registry/machine.nix {
    inherit lib backupLuksUuids builderKeys;
    vmsModule = vms;
    machines = lib.mapAttrs (_: m: m.hardware or { }) machines;
  };
  # Standalone VM outputs (nixosConfigurations.<vm>, packages) see the
  # registry like `vmView`; each machine gets its own view in mkMachine
  vmRegistry = registry.forHost vmView;
  # Every VM's definition (module, specialArgs, packages): roles with the
  # user's own modules, the infrastructure VMs
  vmDefinitions = registry.definitions;

  mkMachine =
    host: machine:
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs vmDefinitions;
        vmRegistry = registry.forHost host;
      };
      modules = [
        self.nixosModules.dom0-base
        self.nixosModules.disk
      ]
      ++ modules
      ++ (machine.modules or [ ]);
    };

  mkVmSystem =
    name:
    let
      vmDefinition = vmDefinitions.${name};
    in
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs vmRegistry;
      }
      // (vmDefinition.specialArgs or { });
      modules = [
        inputs.microvm.nixosModules.microvm
        vmDefinition.module
        (storeGroups.moduleFor name)
      ];
    };

  vmSystems = builtins.mapAttrs (name: _: mkVmSystem name) vmDefinitions;

  # Group store images, built from the same systems that boot from them
  storeGroups = import ../vms/store-groups.nix {
    inherit lib vmRegistry vmSystems;
    inherit (inputs.microvm.lib) buildStoreDisk;
  };
in
{
  inherit registry vmSystems;
  nixosConfigurations = vmSystems // lib.mapAttrs mkMachine machines;
  packages.${system} =
    builtins.mapAttrs (_: vmSystem: vmSystem.config.microvm.declaredRunner) vmSystems
    // {
      inherit (self.packages.${system}) installer-iso;
    };
}

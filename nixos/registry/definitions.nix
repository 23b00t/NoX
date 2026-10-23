# The VMs with a role as VM definitions (name -> { module, specialArgs,
# packages }, the format of the user's vms/definitions.nix): what every VM
# has (../roles/vm.nix), its role's module and its own module (`module`).
# VMs without a role are not in here; their definitions stay the user's.
{ lib }:
cfg:
let
  # A VM's apps with the catalog's fields under its own (non-null) ones
  appsOf =
    vm:
    lib.mapAttrs (
      id: a:
      let
        own = lib.filterAttrs (_: v: v != null) a;
      in
      (cfg.apps.${id} or { }) // own
    ) vm.apps;

  mkDefinition = name: vm: {
    module = {
      imports = [
        (import ../roles/vm.nix {
          inherit name vm;
          apps = appsOf vm;
          groupUnfree = vm.storeGroup != null && (cfg.storeGroups.${vm.storeGroup}.unfree or false);
        })
        cfg.roles.${vm.role}.module
      ]
      ++ lib.optional (vm.module != null) vm.module;
    };
    specialArgs = { };
    packages = _: { };
  };
in
{
  inherit appsOf;
  definitions = lib.mapAttrs mkDefinition (lib.filterAttrs (_: vm: vm.role != null) cfg.vms);
}

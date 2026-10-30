# The VMs with a role as VM definitions (name -> { module, specialArgs,
# packages }, the format of the user's vms/definitions.nix): what every VM
# has (../roles/vm.nix), its role's module and its own module (`module`).
# Enabled infrastructure VMs (infra.nix) get their NoX module. Other VMs
# without a role are not in here; their definitions stay the user's.
{ lib }:
cfg:
let
  # Every NoX VM (role and infrastructure): fstrim 5 min after each boot
  # gives blocks freed in the VM back to dom0, whose images are sparse files
  # (steam's home.img held 150 GB of deleted data, 2026-10-28). NixOS'
  # weekly calendar timer never ran: the stamp of Persistent= lives on the
  # tmpfs root, so only a VM running at Monday 00:00 trimmed
  vmBase = {
    services.fstrim.enable = true;
    systemd.timers.fstrim.timerConfig = {
      # "" clears all timers of util-linux' unit (OnCalendar=weekly), also
      # those set before it: it has to come first, in this option
      OnCalendar = lib.mkForce [ ];
      OnBootSec = [
        ""
        "5min"
      ];
    };
  };
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
        vmBase
        cfg.vmModule
      ]
      ++ lib.optional (vm.module != null) vm.module;
    };
    specialArgs = { };
    packages = _: { };
  };

  # NoX's module plus the user's own (`module`, e.g. the builder's repoUrl)
  mkInfraDefinition = name: _: {
    module = {
      imports = [
        (../vms + "/${name}")
        vmBase
        cfg.vmModule
      ]
      ++ lib.optional (cfg.vms.${name}.module != null) cfg.vms.${name}.module;
    };
    specialArgs = { };
    packages = _: { };
  };
  infra = lib.filterAttrs (name: i: i.enable && cfg.vms.${name}.role == null) cfg.infra;
in
{
  inherit appsOf;
  definitions =
    lib.mapAttrs mkInfraDefinition infra
    // lib.mapAttrs mkDefinition (lib.filterAttrs (_: vm: vm.role != null) cfg.vms);
}

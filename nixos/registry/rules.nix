# Registry rules the modules rely on but nothing else asserts, as NixOS
# assertions over one machine's registry (machine.nix `forHost`): dom0
# asserts them (dom0/base.nix), and mkSystems' `checks.<system>.registry-<host>`
# evaluates them without the system (seconds instead of minutes).
#
# Asserted elsewhere, not repeated here: uplink name and nat
# (vms/modules/net-config.nix), unfree only in an own image or an unfree
# store group (roles/vm.nix), group builders exist (dom0/store-images.nix),
# hasDisposable (disposables.nix), unknown role (vms.nix), Tor VMs without
# NIC or USB (dom0/xen-dom0.nix).
{ lib }:
vmRegistry:
let
  inherit (vmRegistry) host;
  domains = vmRegistry.vms ++ vmRegistry.imageDomains;
  names = map (d: d.name) vmRegistry.vms;
  # dom0 holds .254 of the admin net (nox.network.adminPrefix)
  octet = d: lib.last (lib.splitString "." d.ip);
  withDom0 = domains ++ [
    {
      name = "dom0";
      ip = ".254";
    }
  ];
  # Values used by more than one domain: { value = [ names ]; }
  shared =
    key: list:
    lib.mapAttrs (_: map (d: d.name)) (
      lib.filterAttrs (_: ds: builtins.length ds > 1) (lib.groupBy key list)
    );
  describe =
    what: set:
    lib.concatStringsSep "; " (
      lib.mapAttrsToList (v: ns: "${what} ${v}: ${lib.concatStringsSep ", " ns}") set
    );
  sameIndex = shared octet withDom0;
  sameShort = shared (d: d.short) (builtins.filter (d: d.short or null != null) domains);
  # The domain serving a VM's uplink (legacy.nix: sys-firewall is written as
  # null, nat = uplink != null); its preStart waits for that domain
  uplinkOf = vm: vm.uplink or (if vm.nat or false then "sys-firewall" else null);
  missingUplink = builtins.filter (
    vm: uplinkOf vm != null && !builtins.elem (uplinkOf vm) names
  ) vmRegistry.vms;
  # Every machine has exactly one config VM (role config): the config repo
  # and the signing key live there, dom0-update and nox-install rely on it
  configVms = map (vm: vm.name) (builtins.filter (vm: (vm.role or null) == "config") vmRegistry.vms);
in
[
  {
    # address, tap vm<index> and MAC …:<index hex> follow from it
    assertion = sameIndex == { };
    message = "registry (${host}): every domain needs its own index (address, tap, MAC; dom0 is 254): ${describe "index" sameIndex}";
  }
  {
    assertion = sameShort == { };
    message = "registry (${host}): short aliases must be unique: ${describe "short" sameShort}";
  }
  {
    assertion = missingUplink == [ ];
    message = "registry (${host}): the uplink must run on this machine: ${
      lib.concatMapStringsSep ", " (vm: "${vm.name} -> ${uplinkOf vm}") missingUplink
    } (nox.vms.<uplink>.enable, nox.infra.<uplink>.enable)";
  }
  {
    assertion = builtins.length configVms == 1;
    message = "registry (${host}): exactly one VM needs role = \"config\" (the config repo and your signing key; nox-install adds it), found: ${
      if configVms == [ ] then "none" else lib.concatStringsSep ", " configVms
    }";
  }
]

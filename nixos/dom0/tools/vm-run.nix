# vm-run and manage-vms (`nox run|exec|list|start|stop|restart`): the work
# lives in nox-cli (crates/nox-cli/src/run.rs, manage.rs); this module gives
# it its data (/etc/nox/registry.json `domains`: every VM and image domain of
# the registry with unit, short alias, user, wprs, terminal, store group,
# disposable) and the old names (links to nox, which picks the tool by
# argv[0]).
{
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  inherit (vmRegistry) imageDomains;
  isImage = vm: builtins.elem vm.name (map (d: d.name) imageDomains);
  # Image domains whose terminal is foot from the store disk (Whonix-Gateway)
  footImage =
    vm: ((config.services.xen-image-domains.domains or { }).${vm.name} or { }).foot or false;
  # Xen guests with wprsd (nox-relay serves it): GUI apps and terminals over
  # vm-gui (wprs + app start by RPC)
  relayListen = vm: (config.services.nox-relay.host.guests or { }).${vm.name}.listen or { };
in
{
  programs.nox.registry.domains = map (vm: {
    inherit (vm) name;
    short = if vm.short != null && vm.short != vm.name then vm.short else null;
    unit = if isImage vm then "xen-image@${vm.name}" else "microvm@${vm.name}";
    user = vm.user or "user";
    image = isImage vm;
    wprs = relayListen vm ? wprs;
    footImage = footImage vm;
    storeGroup = vm.storeGroup or null;
    disposable = vm.disposable or false;
    # boot memory in MiB: nox disp checks Xen's free memory before a start
    memory = vm.memory or null;
  }) (vmRegistry.vms ++ imageDomains);

  environment.systemPackages = [
    (pkgs.runCommand "vm-run" { } ''
      mkdir -p $out/bin
      ln -s ${config.programs.nox.package}/bin/nox $out/bin/vm-run
      ln -s ${config.programs.nox.package}/bin/nox $out/bin/manage-vms
    '')
    # vm-run's "Starting VM" notification
    pkgs.libnotify
  ];
}

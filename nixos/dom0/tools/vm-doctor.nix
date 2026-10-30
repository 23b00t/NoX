# vm-doctor (`nox doctor`): smoke test of the running system on demand.
# The checks live in nox-cli (crates/nox-cli/src/doctor.rs); this module
# gives it its data (/etc/nox/registry.json `doctor`: per domain the unit,
# relay domain, wprs and its grants, D-Bus, uplink, clipboard rule; the
# autostart units), the tools it calls and the old name `vm-doctor` (a link
# to nox, which picks the tool by argv[0]).
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  relayed = config.services.nox-relay.host.guests or { };
  imageDomains = config.services.xen-image-domains.domains or { };
  microvms = config.microvm.vms or { };

  # Registry entries this machine runs
  hosts = builtins.filter (h: microvms ? ${h.name} || imageDomains ? ${h.name}) (
    vmRegistry.vms ++ vmRegistry.imageDomains
  );
  unitOf = name: if imageDomains ? ${name} then "xen-image@${name}" else "microvm@${name}";

  # Same rule as vm-clip (home/vm-management/vm-gui.nix)
  clipPolicy = vm: vm.clipboard or (if lib.hasPrefix "sys-" vm.name then "deny" else "allow");
  listen = h: relayed.${h.name}.listen or { };
in
{
  programs.nox.registry.doctor = {
    autostart =
      map (n: "microvm@${n}") (config.microvm.autostart or [ ])
      ++ map (n: "xen-image@${n}") (
        builtins.attrNames (lib.filterAttrs (_: d: d.autostart) imageDomains)
      );
    domains = map (h: {
      inherit (h) name;
      unit = unitOf h.name;
      domain = if relayed ? ${h.name} then relayed.${h.name}.domain else "";
      wprs = listen h ? wprs;
      # wprs pixels over grant-shared memory (registry wprsSharedMemory)
      grants = (relayed.${h.name}.grants or null) != null;
      dbus = (relayed.${h.name}.serve or { }) ? dbus;
      uplink = if h.nat or false then h.uplink or "sys-firewall" else "";
      clip = clipPolicy h;
    }) hosts;
  };

  environment.systemPackages = [
    (pkgs.runCommand "vm-doctor" { } ''
      mkdir -p $out/bin
      ln -s ${config.programs.nox.package}/bin/nox $out/bin/vm-doctor
    '')
    # what nox doctor calls besides systemd, journalctl, sudo/xl and nox-rpc
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.procps
    pkgs.wl-clipboard
  ];

  # Two read-only xl calls of nox without a password for the wheel group,
  # exactly these: Xen's log for the doctor's check `xl dmesg`, the free
  # memory nox disp checks before a start. The rest of xl still asks where
  # sudo asks (xmg)
  security.sudo.extraRules = [
    {
      groups = [ "wheel" ];
      commands =
        map
          (command: {
            inherit command;
            options = [ "NOPASSWD" ];
          })
          [
            "/run/current-system/sw/bin/xl dmesg"
            "/run/current-system/sw/bin/xl info free_memory"
          ];
    }
  ];
}

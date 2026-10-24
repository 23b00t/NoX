{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  # VMs and image domains of this machine (registry `hosts`)
  domains = vmRegistry.vms ++ vmRegistry.imageDomains;
  onHost = vm: builtins.any (d: d.name == vm) domains;

  # Helper für Desktop-Entries: VM-Name aus registry.nix, Anzeige "App (vm)";
  # Einträge für VMs, die auf dieser Maschine nicht laufen, entfallen
  mkVmEntry =
    {
      name,
      vm,
      binary,
      genericName ? name,
      categories ? [ ],
      mimeType ? [ ],
      icon ? null,
      args ? "",
    }:
    lib.optionalAttrs (onHost vm) {
      "nox-${vm}-${lib.toLower (lib.strings.sanitizeDerivationName name)}" = {
        name = "${name} (${vm})";
        inherit
          genericName
          categories
          mimeType
          icon
          ;
        exec = if args == "" then "vm-run ${vm} ${binary} %U" else "vm-run ${vm} ${binary} ${args} %U";
        terminal = false;
        type = "Application";
      };
    };

  # One terminal per domain with a GUI over wprs: foot in the NixOS VMs
  # (wprsd, vms/modules/wprs.nix), the image's default terminal in the
  # Debian image domains (`wprs = true`), foot from the store disk where the
  # image has none (`foot = true`, Whonix-Gateway)
  terminalOf =
    vm:
    if (config.microvm.vms.${vm.name}.config.config.systemd.user.services or { }) ? wprsd then
      "foot"
    else if config.services.xen-image-domains.domains.${vm.name}.foot or false then
      "/nix/store/nox/bin/foot"
    else if config.services.xen-image-domains.domains.${vm.name}.wprs or false then
      "x-terminal-emulator"
    else
      null;
  terminalEntries = map (
    vm:
    lib.optionalAttrs (terminalOf vm != null) {
      "nox-${vm.name}-terminal" = {
        name = "Terminal (${vm.name})";
        genericName = "Terminal";
        exec = "vm-run ${vm.name} ${terminalOf vm}";
        icon = "utilities-terminal";
        categories = [
          "System"
          "TerminalEmulator"
        ];
        terminal = false;
        type = "Application";
      };
    }
  ) domains;

  # The apps of the VMs and image domains (registry `apps`, catalog fields
  # filled in by registry/legacy.nix): one entry each, except apps that only
  # run in the tray (`menu = false`)
  appEntries = lib.concatMap (
    vm:
    map (
      a:
      mkVmEntry (
        {
          inherit (a) name binary;
          vm = vm.name;
          args = lib.concatStringsSep " " ((a.args or [ ]) ++ lib.optional a.x11 "--ozone-platform=x11");
        }
        // lib.optionalAttrs (a ? genericName) { inherit (a) genericName; }
        // lib.optionalAttrs (a ? icon) { inherit (a) icon; }
        // lib.optionalAttrs (a ? categories) { inherit (a) categories; }
        // lib.optionalAttrs (a ? mimeType) { inherit (a) mimeType; }
      )
    ) (lib.filter (a: a.menu or true) (vm.apps or [ ]))
  ) domains;
in
{
  options.nox.desktopEntries = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
    default = { };
    description = "Desktop entries in dom0: file id → fields as in home-manager's xdg.desktopEntries (name, genericName, exec, icon, categories, mimeType, terminal, type, noDisplay). Also the source of waybar's app id → icon mapping.";
  };

  # Hidden entries (noDisplay) replace a package's own entry of the same name
  config.environment.systemPackages = lib.mapAttrsToList (
    id: e:
    (if e.noDisplay or false then lib.hiPrio else lib.id) (
      pkgs.makeDesktopItem (
        {
          name = id;
          desktopName = e.name;
          inherit (e) exec;
          terminal = e.terminal or false;
          type = e.type or "Application";
          noDisplay = e.noDisplay or false;
        }
        // lib.optionalAttrs (e ? genericName) { inherit (e) genericName; }
        // lib.optionalAttrs ((e.icon or null) != null) { icon = toString e.icon; }
        // lib.optionalAttrs ((e.categories or [ ]) != [ ]) { inherit (e) categories; }
        // lib.optionalAttrs ((e.mimeType or [ ]) != [ ]) { mimeTypes = e.mimeType; }
      )
    )
  ) config.nox.desktopEntries;

  config.nox.desktopEntries = lib.mkMerge (terminalEntries ++ appEntries);
}

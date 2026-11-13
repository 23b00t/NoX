# The registry the modules read (`vmRegistry`), as one machine sees it: the
# user's domains (nox.vms / nox.images, evaluated for that machine) plus the
# machine's hardware (PCI/USB inventory, host profile). Moved from the
# user's vms/registry.nix (NoX modules step 4); used by lib/systems.nix.
#
# machines.<host> = {
#   profile        cpuVendor, dom0Pv, dGpuVendor, blockedHostDrivers, dom0TestAccess
#   usbDevices     USB inventory: name, vendorId, productId, policy
#                  (host-allow | vm-reserved), defaultOwner, allowedOwners, …
#   pciDeviceIds   { nic = [ "vendor:device" … ]; gpu; gpuAudio; } (vfio ids)
#   pciDevicePaths { nic; usb; gpu; } (passed-through devices per kind)
# }
{
  lib,
  vmsModule,
  machines,
  backupLuksUuids ? [ ],
  builderKeys ? null,
}:
let
  # nox.* of one machine (host null: all definitions, for the VM definitions)
  # `extra`: modules on top of the user's (nox-install's minimal variant)
  noxFor =
    extra: host:
    let
      nox =
        (lib.evalModules {
          modules = [
            ./vms.nix
            vmsModule
          ]
          ++ extra;
          specialArgs = { inherit host; };
        }).config.nox;
    in
    # plus the disposables of VMs with `hasDisposable` (disp-<vm>)
    nox // { vms = nox.vms // import ./disposables.nix { inherit lib; } nox; };
  # … in the registry's entry format
  domainsFor = extra: host: import ./legacy.nix { inherit lib; } (noxFor extra host);

  # Lookups by name cover all VMs (IPs, keys, store groups), also those not on
  # the current machine; the lists per machine come from `forHost` below.
  # Built from the machine's own evaluation, so `if host == …` in a field
  # holds there too (a VM reads its own entry here, e.g. hostSSHKey)
  mkByName =
    vms:
    builtins.listToAttrs (
      map (vm: {
        inherit (vm) name;
        value = vm;
      }) vms
    );

  mkByShort =
    vms:
    builtins.listToAttrs (
      map (vm: {
        name = vm.short;
        value = vm;
      }) (builtins.filter (vm: vm.short != null) vms)
    );

  mkHardware =
    host:
    let
      usbDevices = machines.${host}.usbDevices or [ ];
      pciDeviceIds = machines.${host}.pciDeviceIds or { nic = [ ]; };
    in
    {
      pci = {
        deviceIds = pciDeviceIds;
        devicePaths = machines.${host}.pciDevicePaths or { };
        vfioIds = (pciDeviceIds.gpu or [ ]) ++ (pciDeviceIds.gpuAudio or [ ]) ++ pciDeviceIds.nic or [ ];
      };
      usb = {
        devices = usbDevices;
        byName = builtins.listToAttrs (
          map (device: {
            inherit (device) name;
            value = device;
          }) usbDevices
        );
        hostAllow = builtins.filter (device: device.policy == "host-allow") usbDevices;
        vmReserved = builtins.filter (device: device.policy == "vm-reserved") usbDevices;
        defaultForOwner =
          owner: builtins.filter (device: (device.defaultOwner or null) == owner) usbDevices;
        allowedForOwner =
          owner: builtins.filter (device: builtins.elem owner (device.allowedOwners or [ ])) usbDevices;
      };
    };

  # dom0's login key for a builder VM from `builderKeys`/ssh-key-<vm>-<host>.pub
  # when vms.nix sets no `hostSSHKey` (nox-install writes that file)
  withLoginKey =
    host: vm:
    let
      file = builderKeys + "/ssh-key-${vm.name}-${host}.pub";
      isBuilder = vm.name == "builder" || lib.hasPrefix "builder-" vm.name;
    in
    if vm ? hostSSHKey || builderKeys == null || !isBuilder || !builtins.pathExists file then
      vm
    else
      vm // { hostSSHKey = lib.trim (builtins.readFile file); };

  # The registry as one machine sees it: `vms`/`imageDomains` and everything
  # derived from them only hold what runs there (nox.vms.<name>.enable);
  # `extra`: see noxFor
  forHostWith =
    extra: host:
    let
      domains = domainsFor extra host;
      allVms = map (withLoginKey host) domains.vms;
      hostVms = map (withLoginKey host) domains.vmsOnHost;
    in
    {
      byName = mkByName allVms;
      byShort = mkByShort allVms;
      inherit
        host
        backupLuksUuids
        ;
      # Read by dom0-update and the builders only: without it a clear error
      # instead of "cannot coerce null to a string"
      builderKeys =
        if builderKeys != null then
          builderKeys
        else
          throw "NoX: the builder (nox.infra.builder) needs `builderKeys` in mkSystems: the directory with its keys, at least `allowed-signers` (NoX template/flake.nix)";
      vms = hostVms;
      imageDomains = domains.imagesOnHost;
      natIPs = map (vm: vm.ip) (builtins.filter (vm: vm.nat or false) hostVms);
      autostartNames = map (vm: vm.name) (builtins.filter (vm: vm.autostart or false) hostVms);
      dbusForwardParticipants = builtins.filter (vm: vm.enableHostDbusForward or true) hostVms;
      # nox backup --all takes these; field `backup`, default false
      # for sys-* and disposables
      backupVms = builtins.filter (
        vm: vm.backup or (!(builtins.substring 0 4 vm.name == "sys-" || (vm.disposable or false)))
      ) hostVms;
      vmHasFeature = feature: builtins.filter (vm: builtins.elem feature (vm.features or [ ])) hostVms;
      globalExtraSSH = [ ];
      # Store group -> the builder VM that builds its image (nox.storeGroups.<g>.builder)
      storeGroupBuilders = lib.mapAttrs (_: g: g.builder) (noxFor extra host).storeGroups;
      hardware = mkHardware host;
      hostProfile = machines.${host}.profile or { };
      # nox.theme: the same on every machine (VMs share store images), so
      # dom0 and its VMs look alike
      inherit (noxFor [ ] null) theme;
    };
in
{
  inherit forHostWith;
  forHost = forHostWith [ ];
  # Every VM's definition (module, specialArgs, packages)
  inherit ((import ./definitions.nix { inherit lib; }) (noxFor [ ] null)) definitions;
}

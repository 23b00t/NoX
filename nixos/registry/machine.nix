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
  # nox.* of one machine (host null: all definitions, for the lookups by name)
  noxFor =
    host:
    let
      nox =
        (lib.evalModules {
          modules = [
            ./vms.nix
            vmsModule
          ];
          specialArgs = { inherit host; };
        }).config.nox;
    in
    # plus the disposables of VMs with `hasDisposable` (disp-<vm>)
    nox // { vms = nox.vms // import ./disposables.nix { inherit lib; } nox; };
  # … in the registry's entry format
  domainsFor = host: import ./legacy.nix { inherit lib; } (noxFor host);
  all = domainsFor null;
  inherit (all) vms;

  # Lookups by name cover all VMs (IPs, keys, store groups), also those not on
  # the current machine; the lists per machine come from `forHost` below.
  byName = builtins.listToAttrs (
    map (vm: {
      inherit (vm) name;
      value = vm;
    }) vms
  );

  byShort = builtins.listToAttrs (
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

  # The registry as one machine sees it: `vms`/`imageDomains` and everything
  # derived from them only hold what runs there (nox.vms.<name>.enable)
  forHost =
    host:
    let
      domains = domainsFor host;
      hostVms = domains.vmsOnHost;
    in
    {
      inherit
        host
        byName
        byShort
        backupLuksUuids
        builderKeys
        ;
      vms = hostVms;
      imageDomains = domains.imagesOnHost;
      natIPs = map (vm: vm.ip) (builtins.filter (vm: vm.nat or false) hostVms);
      autostartNames = map (vm: vm.name) (builtins.filter (vm: vm.autostart or false) hostVms);
      dbusForwardParticipants = builtins.filter (vm: vm.enableHostDbusForward or true) hostVms;
      # W1 backup (nox backup --all) takes these; field `backup`, default false
      # for sys-* and disposables
      backupVms = builtins.filter (
        vm: vm.backup or (!(builtins.substring 0 4 vm.name == "sys-" || (vm.disposable or false)))
      ) hostVms;
      vmHasFeature = feature: builtins.filter (vm: builtins.elem feature (vm.features or [ ])) hostVms;
      globalExtraSSH = [ ];
      hardware = mkHardware host;
      hostProfile = machines.${host}.profile or { };
      # nox.theme: the same on every machine (VMs share store images), so
      # dom0 and its VMs look alike
      inherit (noxFor null) theme;
    };
in
{
  inherit forHost;
  # Every VM's definition (module, specialArgs, packages)
  inherit ((import ./definitions.nix { inherit lib; }) (noxFor null)) definitions;
}

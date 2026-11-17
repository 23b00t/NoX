# Registry rules the modules rely on but nothing else asserts, as NixOS
# assertions over one machine's registry (machine.nix `forHost`): dom0
# asserts them (dom0/base.nix), and mkSystems' `checks.<system>.registry-<host>`
# evaluates them without the system (seconds instead of minutes).
#
# Asserted here: indexes, names and short aliases, MACs, store groups,
# USB owners, GitHub agent on infrastructure VMs, uplinks, the config VM.
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
  # One namespace: VMs and image domains share relay sockets
  # (/run/nox-relay/<name>-…), Xen names and the CLI (nox-cli registry.rs
  # `find`: the first domain in this order whose name OR short matches wins)
  sameName = shared (d: d.name) domains;
  shortIsName = builtins.filter (
    d: d.short or null != null && d.short != d.name && builtins.elem d.short (map (o: o.name) domains)
  ) domains;
  # Every MAC a domain gets (macs.nix); image domains set theirs in
  # services.xen-image-domains (dom0), the registry does not know them
  macs = import ./macs.nix { inherit lib; };
  indexOf = d: lib.toInt (octet d);
  macOwners = lib.concatMap (
    vm:
    [
      {
        inherit (vm) name;
        mac = macs.admin (indexOf vm);
      }
    ]
    ++ lib.optional (vm.nat or false) {
      inherit (vm) name;
      mac = macs.uplink (indexOf vm);
    }
  ) vmRegistry.vms;
  sameMac = shared (x: x.mac) macOwners;
  # Store groups: every VM that is defined (also disabled ones)
  allVms = builtins.attrValues vmRegistry.byName;
  declaredGroups = builtins.attrNames vmRegistry.storeGroupBuilders;
  undeclaredGroup = builtins.filter (
    vm: vm.storeGroup or null != null && !builtins.elem vm.storeGroup declaredGroups
  ) allVms;
  # USB inventory owners: "host" or a domain that is defined, enabled here or not
  unknownOwner = lib.concatMap (
    dev:
    map (o: "${dev.name}: ${o}") (
      builtins.filter (o: o != "host" && !builtins.elem o vmRegistry.definedNames) (
        lib.unique (
          lib.optional (dev.defaultOwner or null != null) dev.defaultOwner ++ dev.allowedOwners or [ ]
        )
      )
    )
  ) vmRegistry.hardware.usb.devices;
  # Driver domains, builders and disposables must not hold the GitHub agent
  agentOnInfra = builtins.filter (
    vm: (vm.allowGitHubAgent or false) && builtins.elem vm.name vmRegistry.infraNames
  ) allVms;
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
  {
    assertion = sameName == { };
    message = "registry (${host}): a domain name may be used once, VMs and image domains share relay sockets, Xen names and the CLI: ${describe "name" sameName} (nox.vms, nox.images)";
  }
  {
    assertion = shortIsName == [ ];
    message = "registry (${host}): a short alias may not be another domain's name (`nox <name>` would find the wrong domain): ${
      lib.concatMapStringsSep ", " (d: "${d.name} has short ${d.short}") shortIsName
    }";
  }
  {
    assertion = sameMac == { };
    message = "registry (${host}): every interface needs its own MAC (00:00:00:00:00:<index hex>, uplink 00:00:00:00:01:<index hex>): ${describe "MAC" sameMac}";
  }
  {
    assertion = undeclaredGroup == [ ];
    message = "registry (${host}): the store group is not declared in nox.storeGroups (a typo makes a group of its own, whose image the main builder builds): ${
      lib.concatMapStringsSep ", " (vm: "${vm.name} -> ${vm.storeGroup}") undeclaredGroup
    } (declared: ${lib.concatStringsSep ", " declaredGroups}; storeGroup = null for an own image)";
  }
  {
    assertion = unknownOwner == [ ];
    message = "registry (${host}): the USB inventory names a domain that is not defined in nox.vms or nox.images (\"host\" is allowed): ${lib.concatStringsSep ", " unknownOwner} (machines/hardware.nix: defaultOwner, allowedOwners)";
  }
  {
    assertion = agentOnInfra == [ ];
    message = "registry (${host}): the GitHub agent is forbidden for driver domains, builders and disposables (githubAgent = false): ${
      lib.concatMapStringsSep ", " (vm: vm.name) agentOnInfra
    }";
  }
]

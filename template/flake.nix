{
  description = "NoX config (NixOS on Xen): dom0 with its VMs";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # microvm.nix with the Xen hypervisor
    microvm = {
      url = "github:23b00t/microvm.nix/xen";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nox = {
      url = "github:23b00t/NoX";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # wprs with NoX's fixes (GUI of the VMs in dom0)
    wprs = {
      url = "github:23b00t/wprs/nox";
      flake = false;
    };
  };

  outputs =
    { nixpkgs, ... }@inputs:
    let
      hardware = import ./machines/hardware.nix;
    in
    {
      # nixosConfigurations.nox (this machine) and one per VM, packages.<vm>
      # (the VMs' runners): `sudo nixos-rebuild switch --flake .#nox`
      inherit
        (inputs.nox.lib.mkSystems {
          inherit inputs;
          # The domains: VMs with role and apps, infrastructure, images
          vms = ./vms.nix;
          machines.nox = {
            modules = [ ./machines/nox/configuration.nix ];
            hardware = hardware.nox;
          };
          vmView = "nox";
          # LUKS volumes `nox backup` may open (cryptsetup luksUUID); empty:
          # the only LUKS volume on the attached disk
          backupLuksUuids = [ ];
        })
        nixosConfigurations
        packages
        ;
    };
}

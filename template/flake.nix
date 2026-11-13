{
  description = "NoX config (NixOS on Xen): dom0 with its VMs";

  inputs = {
    nox.url = "github:23b00t/NoX";
    # nixpkgs as NoX pins it (tested with NoX; a new NoX brings its nixpkgs,
    # nox-install pins NoX to the ISO's revision, so the system matches it)
    nixpkgs.follows = "nox/nixpkgs";
    # microvm.nix with the Xen hypervisor
    microvm = {
      url = "github:23b00t/microvm.nix/xen";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # wprs with NoX's fixes (GUI of the VMs in dom0)
    wprs = {
      url = "github:23b00t/wprs/nox";
      flake = false;
    };
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;
      # The machines: every directory under machines/ with a
      # configuration.nix (NixOS settings of dom0) and a hardware.nix
      # (`nox-hwcheck --nix`), optionally disk.nix (nox.disk.device, written
      # by nox-install). A new machine is a new directory
      hosts = lib.attrNames (
        lib.filterAttrs (
          name: type: type == "directory" && builtins.pathExists (./machines + "/${name}/configuration.nix")
        ) (builtins.readDir ./machines)
      );
      machines = lib.genAttrs hosts (host: {
        modules = [
          (./machines + "/${host}/configuration.nix")
        ]
        ++ lib.optional (builtins.pathExists (./machines + "/${host}/disk.nix")) (
          ./machines + "/${host}/disk.nix"
        );
        hardware = import (./machines + "/${host}/hardware.nix");
      });
    in
    {
      # nixosConfigurations.<host> (each machine) and one per VM,
      # packages.<vm> (the VMs' runners); checks (eval-only):
      # `nix build .#checks.x86_64-linux.registry-<host>`
      inherit
        (inputs.nox.lib.mkSystems {
          inherit inputs machines;
          # The domains: VMs with role and apps, infrastructure, images
          vms = ./vms.nix;
          # The machine whose view the standalone VM outputs see
          vmView = lib.head hosts;
          # LUKS volumes `nox backup` may open (cryptsetup luksUUID); empty:
          # the only LUKS volume on the attached disk
          backupLuksUuids = [ ];
          # The builder's keys: `allowed-signers` (ssh-keygen format: the
          # keys whose signed commits it builds); per machine nox-install
          # adds signing-key-<host>.pub, image-key-<host>.pub, the login
          # keys ssh-key-<builder>-<host>.pub and bump-signers (nox update)
          builderKeys = ./vms/builder;
        })
        nixosConfigurations
        packages
        checks
        ;
    };
}

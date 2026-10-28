{
  description = "NoX (NixOS on Xen): tools, modules and VM templates for a Qubes-like NixOS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # Partitioning of a machine with nox.disk (and the installer)
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
    }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules = {
        relay = import ./nixos/modules/relay.nix { inherit self; };
        rpc = import ./nixos/modules/rpc.nix { inherit self; };
        cli = import ./nixos/modules/cli.nix { inherit self; };
        # dom0 (step 1 of the NoX modules: moved unchanged from the user's
        # config, still fed by its `vmRegistry`/`vmDefinitions`/`inputs`
        # specialArgs): base (machines/common-configuration.nix) and the Xen
        # part (machines/xen-dom0.nix)
        dom0-base = ./nixos/dom0/base.nix;
        xen-dom0 = ./nixos/dom0/xen-dom0.nix;
        # nox.disk: standard disk layout (disko), set by machines installed
        # with nox-install
        disk = import ./nixos/modules/disk.nix { inherit self; };
        default = self.nixosModules.relay;
      };

      # The rest of the former config tree, as paths (step 1): `vms` holds
      # the infrastructure VMs (vms/<name>), the VM building blocks
      # (vms/modules/<module>.nix), store-groups.nix and usb-links.nix;
      # `tests`
      # the NixOS tests
      lib = {
        vms = ./nixos/vms;
        # The VM schema (nox.vms, nox.images) and its adapter to the registry
        registry = ./nixos/registry;
        tests = ./nixos/tests;
        # The flake glue of a NoX config (nixosConfigurations of the
        # machines and VMs, runners, store images): nixos/lib/systems.nix
        mkSystems = import ./nixos/lib/systems.nix { inherit self; };
      };

      # `nix flake init -t github:23b00t/NoX`: a machine with the core
      # infrastructure and two app VMs
      templates.default = {
        path = ./template;
        description = "NoX config: one machine (hardware), the domains in vms.nix";
      };

      overlays.default = final: _prev: {
        nox-vchan-libs = final.callPackage ./nix/vchan-libs.nix { };
        nox-relay = final.callPackage ./nix/nox-relay.nix { vchan-libs = final.nox-vchan-libs; };
        nox-rpc = final.callPackage ./nix/nox-rpc.nix { };
        nox-cli = final.callPackage ./nix/nox-cli.nix { };
      };

      packages = forAllSystems (
        pkgs:
        let
          nox = pkgs.extend self.overlays.default;
          inherit (pkgs.stdenv.hostPlatform) system;
          nox-hwcheck = pkgs.callPackage ./nix/nox-hwcheck.nix { };
          nox-install = pkgs.callPackage ./nix/nox-install.nix {
            inherit nox-hwcheck;
            inherit (disko.packages.${system}) disko;
          };
        in
        {
          inherit (nox)
            nox-vchan-libs
            nox-relay
            nox-rpc
            nox-cli
            ;
          options-doc = pkgs.callPackage ./nix/options-doc.nix { };
          # Hardware check for a NoX machine (report, --nix: machines/hardware.nix)
          inherit nox-hwcheck;
          # Guided installation from the installer ISO (sudo nox-install)
          inherit nox-install;
          # Installer ISO: NixOS minimal live system with nox-install
          installer-iso =
            (nixpkgs.lib.nixosSystem {
              inherit system;
              specialArgs = {
                inherit nox-hwcheck nox-install;
                inherit (disko.packages.${system}) disko;
              };
              modules = [ ./nixos/installer/iso.nix ];
            }).config.system.build.isoImage;
          # Logo, icon, wallpaper and lock screen of the default theme (nox,
          # organic, dark, moon and stars); a config builds its own from
          # nox.desktop.theme
          nox-branding = pkgs.callPackage ./nix/nox-branding.nix {
            colors = (import ./nixos/desktop/theme.nix { inherit (pkgs) lib; }).graphics;
          };
          default = nox.nox-relay;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            cargo
            rustc
            clippy
            rustfmt
          ];
          buildInputs = [ (pkgs.callPackage ./nix/vchan-libs.nix { }) ];
        };
      });
    };
}

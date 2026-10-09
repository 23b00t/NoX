{
  description = "NoX (NixOS on Xen): tools, modules and VM templates for a Qubes-like NixOS";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules = {
        relay = import ./nixos/modules/relay.nix { inherit self; };
        rpc = import ./nixos/modules/rpc.nix { inherit self; };
        default = self.nixosModules.relay;
      };

      overlays.default = final: _prev: {
        nox-vchan-libs = final.callPackage ./nix/vchan-libs.nix { };
        nox-relay = final.callPackage ./nix/nox-relay.nix { vchan-libs = final.nox-vchan-libs; };
        nox-rpc = final.callPackage ./nix/nox-rpc.nix { };
      };

      packages = forAllSystems (
        pkgs:
        let
          nox = pkgs.extend self.overlays.default;
        in
        {
          inherit (nox) nox-vchan-libs nox-relay nox-rpc;
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

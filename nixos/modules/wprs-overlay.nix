# wprs from our fork (flake input `wprs`, branch nox) instead of patches on
# nixpkgs' wprs: dom0 (machines/common-configuration.nix) and the VMs
# (vms/modules/wprs.nix) get the same build. The fork's Cargo.lock differs from
# nixpkgs' revision (seccompiler for the xen feature), so the dependencies are
# vendored from it instead of nixpkgs' cargoHash.
{ inputs }:
final: prev: {
  wprs = prev.wprs.overrideAttrs {
    src = inputs.wprs;
    cargoDeps = final.rustPlatform.importCargoLock {
      lockFile = "${inputs.wprs}/Cargo.lock";
    };
    # Pixels through Xen grant-shared memory (wprs src/xen_shm.rs), switched
    # on per VM by the registry field `wprsSharedMemory`
    cargoBuildFeatures = [ "xen" ];
  };
}

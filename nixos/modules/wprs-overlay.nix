# wprs from our fork (flake input `wprs`, branch nox) instead of patches on
# nixpkgs' wprs: dom0 (machines/common-configuration.nix) and the VMs
# (vms/modules/wprs.nix) get the same build. Cargo.lock is unchanged against
# nixpkgs' revision, so its vendored dependencies still fit.
{ inputs }:
_final: prev: {
  wprs = prev.wprs.overrideAttrs {
    src = inputs.wprs;
  };
}

# Development tools for NoX itself: measuring and debugging, not part of
# the product. Everything here is off by default (nox.dev.*, options.nix)
{ lib, ... }:
{
  imports = [
    ./options.nix
    ./timing.nix
    # Old name (until 2026-11)
    (lib.mkRenamedOptionModule
      [ "nox" "development" "timing" "enable" ]
      [ "nox" "dev" "timing" "enable" ]
    )
  ];
}

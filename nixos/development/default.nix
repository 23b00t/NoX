# Development tools for NoX itself: measuring and debugging, not part of
# the product. Everything here is off by default (nox.dev.*, options.nix)
{
  imports = [
    ./options.nix
    ./timing.nix
  ];
}

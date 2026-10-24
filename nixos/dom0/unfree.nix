# Unfree packages in dom0: by name only (nox.unfree, read by base.nix's pkgs),
# never allowUnfree. NoX's dom0 itself needs none.
{ lib, ... }:
{
  options.nox.unfree = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "claude-code" ];
    description = "Unfree packages (pname) allowed in dom0; set where the package is added.";
  };
}

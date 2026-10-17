# nox: one command for the NoX tools in dom0 (thin wrapper over the
# scripts it calls, which come from the system configuration).
#
# `vms` only feeds the shell completion (/etc/nox/registry.json).
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.nox;
in
{
  options.programs.nox = {
    enable = lib.mkEnableOption "the nox command (dom0)";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.nox-cli;
      defaultText = lib.literalExpression "nox.packages.\${system}.nox-cli";
      description = "nox-cli package.";
    };
    vms = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "coding"
        "chat"
      ];
      description = "VM names offered by the shell completion.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    environment.etc."nox/registry.json".text = builtins.toJSON cfg.vms;
  };
}

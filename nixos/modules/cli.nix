# nox: one command for the NoX tools in dom0 (thin wrapper over the
# scripts it calls, which come from the system configuration).
#
# /etc/nox/registry.json: `vms` (names for the shell completion) plus
# `registry` (data of the tools nox runs itself, e.g. `doctor`);
# `commandsFile` + `extraCommands` are the lists of `nox xen|nix|root`
# (/etc/nox/commands).
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
    commandsFile = lib.mkOption {
      type = lib.types.path;
      default = ../commands;
      description = "Command lists for `nox xen`, `nox nix` and `nox root`: sections `## <group>`, lines `cmd # description`.";
    };
    extraCommands = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = "## nix\nnix flake update nox # Update NoX";
      description = "Entries appended to `commandsFile`; a section may repeat a group.";
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
    registry = lib.mkOption {
      type = lib.types.attrsOf (pkgs.formats.json { }).type;
      default = { };
      description = "Data of the tools that run inside nox (e.g. `doctor`, from the vm-doctor module), next to `vms` in /etc/nox/registry.json.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment = {
      systemPackages = [ cfg.package ];
      etc."nox/registry.json".text = builtins.toJSON ({ inherit (cfg) vms; } // cfg.registry);
      etc."nox/commands".text = builtins.readFile cfg.commandsFile + "\n" + cfg.extraCommands;
    };
  };
}

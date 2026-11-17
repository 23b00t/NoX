# Role dev: software development. Editors (ide), lazygit, zsh, zellij,
# yazi; the GitHub agent follows the VM's `githubAgent`. Languages,
# databases, docker and the tab layout come from the VM's own module.
{ lib, noxVm, ... }:
{
  imports = [
    ../vms/modules/yazi-config.nix
    ../vms/modules/ide
    ../vms/modules/lazygit.nix
    ../vms/modules/zsh.nix
    ../vms/modules/zellij.nix
  ];

  services = {
    ide = {
      enable = lib.mkDefault true;
      githubAgent.enable = lib.mkDefault (noxVm.githubAgent or false);
    };
    lazygit.enable = lib.mkDefault true;
    zsh-env.enable = lib.mkDefault true;
    zellij-env.enable = lib.mkDefault true;
  };
}

# Role terminal: text-mode work in zellij (irc, mail, chat clients in the
# terminal). The tab layout (`services.zellij-env.tabsKdlFile`) comes from
# the VM's own module.
{ lib, ... }:
{
  imports = [ ../vms/modules/zellij.nix ];

  services.zellij-env.enable = lib.mkDefault true;
}

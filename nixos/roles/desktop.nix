# Role desktop: GUI apps over wprs (common-config) with a file manager
# (yazi). Which apps run here is the VM's `apps`, never the role's.
_: {
  imports = [ ../vms/modules/yazi-config.nix ];
}

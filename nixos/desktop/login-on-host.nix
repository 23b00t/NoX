# nox.desktop.login without the VMs this machine does not run (the registry
# leaves them out, e.g. in the minimal installation, nox.install): their
# terminal tabs and login windows are dropped instead of failing at login
{ vmRegistry }:
login:
let
  names = map (v: v.name) (vmRegistry.vms ++ vmRegistry.imageDomains);
  onHost = vm: vm == "dom0" || builtins.elem vm names;
in
login
// {
  terminalTabs = builtins.filter onHost login.terminalTabs;
  windows = builtins.filter (w: onHost w.vm) login.windows;
}

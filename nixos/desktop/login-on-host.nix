# nox.desktop.login without the VMs this machine does not run (the registry
# leaves them out, e.g. in the minimal installation, nox.install): their
# terminal tabs and login windows are dropped instead of failing at login.
# Also the fixed app tokens of the login windows: a VM runs an app as the
# unit nox-app-<token> and refuses a second start while it lives (NOX_APP_TOKEN
# of `nox run`, dom0/tools/vm-gui.nix), so a token per window is the dedup
{ vmRegistry }:
login:
let
  names = map (v: v.name) (vmRegistry.vms ++ vmRegistry.imageDomains);
  onHost = vm: vm == "dom0" || builtins.elem vm names;
  token = key: builtins.substring 0 16 (builtins.hashString "sha256" key);
in
login
// {
  terminalTabs = builtins.filter onHost login.terminalTabs;
  # The token follows the entry's place in nox.desktop.login.windows
  windows = builtins.filter (w: onHost w.vm) (
    builtins.genList (
      i:
      let
        w = builtins.elemAt login.windows i;
      in
      w // { token = token "nox-login-${w.vm}-${toString i}"; }
    ) (builtins.length login.windows)
  );
  # Token of a VM's login terminal (one per VM)
  termToken = vm: token "nox-term-${vm}";
}

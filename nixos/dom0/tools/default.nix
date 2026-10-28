# dom0 tools (NoX modules step 2: out of home-manager): vm-run and
# manage-vms (links to nox), vm-gui,
# vm-doctor, vm-backup, vm-rollback, nox printers, the desktop entries for VM apps, the
# GitHub agent, explorer and vm-disp, all in the
# system profile.
{ pkgs, vmRegistry, ... }:
{
  imports = [
    ./vm-run.nix
    ./vm-gui.nix
    ./vm-doctor.nix
    ./vm-backup.nix
    ./vm-rollback.nix
    ./printers.nix
    ./desktop-entries.nix
    ./github-agent-forward.nix
    ./ssh.nix
  ];

  environment.systemPackages = [
    # nox disp: start the ad-hoc disposable (empty on every start, registry
    # `disposable`) and open a program in it, foot by default; `nox stop
    # disp` throws it away
    (pkgs.writeShellScriptBin "vm-disp" ''
      set -eu
      [ $# -gt 0 ] || set -- foot
      manage-vms start disp
      # A fresh disp needs its volumes made and a boot: wait for its relay
      for _ in $(seq 240); do
        [ -e /run/nox-relay/disp.ready ] && break
        sleep 0.5
      done
      exec vm-run disp "$@"
    '')
    (import ./explorer.nix { inherit pkgs vmRegistry; })
    (import ./github-agent.nix { inherit pkgs; })
    # nox-hwcheck: hardware report (and machines/hardware.nix block, --nix)
    (pkgs.callPackage ../../../nix/nox-hwcheck.nix { })
  ];
}

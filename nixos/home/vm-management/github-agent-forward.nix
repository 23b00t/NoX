# dom0's dedicated GitHub SSH agent. VMs with registry `allowGitHubAgent`
# reach it over vchan (nox-relay, vms/modules/vchan-relay.nix); the SSH
# remote forwards that used to carry it are gone (SSH removal, 2026-10-21)
{ pkgs, ... }:
let
  githubAgentBin = import ./github-agent.nix { inherit pkgs; };
in
{
  systemd.user.services.github-agent = {
    Unit = {
      Description = "Ensure dedicated GitHub SSH agent is running";
      After = [ "default.target" ];
      Wants = [ "default.target" ];
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${githubAgentBin}/bin/github-agent";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}

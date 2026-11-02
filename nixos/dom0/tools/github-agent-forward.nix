# dom0's dedicated GitHub SSH agent. VMs with registry `allowGitHubAgent`
# reach it over vchan (nox-relay, vms/modules/vchan-relay.nix); the SSH
# remote forwards that used to carry it are gone (SSH removal, 2026-10-21)
{
  lib,
  pkgs,
  config,
  ...
}:
let
  githubAgentBin = import ./github-agent.nix { inherit pkgs; };
  # Guests the relay serves the agent to, with their socket (xen-dom0.nix)
  agentSockets = lib.mapAttrs (_: g: g.serve.github-agent) (
    lib.filterAttrs (_: g: g.serve ? github-agent) (config.services.nox-relay.host.guests or { })
  );
in
{
  # Each guest's relay connects to its own socket; every connection runs
  # github-agent-from-<vm>@… while it lasts and is passed on to the agent.
  # The confirmation (github-agent-askpass) names the VM from these units
  systemd.user.sockets = lib.mapAttrs' (
    name: path:
    lib.nameValuePair "github-agent-from-${name}" {
      description = "GitHub agent socket for ${name}";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = path;
        Accept = true;
        SocketMode = "0600";
        DirectoryMode = "0700";
      };
    }
  ) agentSockets;

  systemd.user.services =
    lib.mapAttrs' (
      name: _:
      lib.nameValuePair "github-agent-from-${name}@" {
        description = "GitHub agent connection from ${name}";
        serviceConfig = {
          ExecStart = "${pkgs.socat}/bin/socat STDIO UNIX-CONNECT:%h/.ssh/agent/github.sock";
          StandardInput = "socket";
        };
      }
    ) agentSockets
    // {
      github-agent = {
        description = "Ensure dedicated GitHub SSH agent is running";
        after = [ "default.target" ];
        wants = [ "default.target" ];
        wantedBy = [ "default.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${githubAgentBin}/bin/github-agent";
        };
      };
    };
}

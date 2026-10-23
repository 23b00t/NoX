{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  # Xen guests dom0 reaches over vchan (nox-relay, stage B): ssh goes through
  # the relay socket instead of the admin network; also for connections by IP
  relayed = config.services.nox-relay.host.guests or { };
  relaySsh = name: (relayed.${name}.listen or { }).ssh.path or null;

  # ProxyCommand: waits until the guest's sshd answers through the relay
  # socket (a VM that was just started), then connects. Fails at once if the
  # VM's unit is not running
  sshWait = pkgs.writeShellScript "ssh-relay-wait" ''
    unit="$1" sock="$2"
    socat=${pkgs.socat}/bin/socat
    # Running for more than 2 min: connect straight away (the probe below
    # costs ~0.5 s)
    since=$(systemctl show -p ActiveEnterTimestampMonotonic --value "$unit")
    now=$(awk '{ printf "%d", $1 * 1000000 }' /proc/uptime)
    if [ "''${since:-0}" -gt 0 ] && [ $((now - since)) -gt 120000000 ] && [ -S "$sock" ]; then
      exec "$socat" - UNIX-CONNECT:"$sock"
    fi
    for i in $(seq 120); do
      if ! systemctl is-active --quiet "$unit"; then
        echo "$unit is not running" >&2
        exit 1
      fi
      if [ -S "$sock" ] &&
        [ "$(timeout 3 "$socat" -T 0.5 -u UNIX-CONNECT:"$sock" - 2>/dev/null | head -c 4)" = SSH- ]; then
        exec "$socat" - UNIX-CONNECT:"$sock"
      fi
      [ "$i" = 3 ] && echo "waiting for $unit (sshd)..." >&2
      sleep 1
    done
    echo "$unit: no sshd after 120 s" >&2
    exit 1
  '';

  # Only guests dom0 still logs into (registry `hostSSHKey`: the builder,
  # xen-migration.md SSH removal). Image domains have no admin link: SSH
  # only through the relay
  hosts = builtins.filter (h: h ? hostSSHKey) (vmRegistry.vms ++ vmRegistry.imageDomains);
  imageDomainNames = map (d: d.name) vmRegistry.imageDomains;
  githubAgentSocket = "%d/.ssh/agent/github.sock";

  # Extra options from the registry (extraSSH, globalExtraSSH), if any
  hostStrings = builtins.concatStringsSep "\n" (
    lib.concatMap (
      h:
      let
        allExtra = (h.extraSSH or [ ]) ++ (vmRegistry.globalExtraSSH or [ ]);
      in
      lib.optional (allExtra != [ ]) ("Host ${h.name}-vm\n  " + builtins.concatStringsSep "\n  " allExtra)
    ) hosts
  );

  # `ssh <name>-vm`, `ssh <name>`, `ssh <short>` and the registry IP all
  # reach the same guest
  mkSettingsBlock = h: {
    "${lib.concatStringsSep " " (
      lib.unique (
        [
          "${h.name}-vm"
          h.name
        ]
        ++ lib.optional ((h.short or null) != null) h.short
        ++ [ h.ip ]
      )
    )}" =
    {
      User = "user";
      IdentityFile = "~/.ssh/${h.name}-vm";
      IdentitiesOnly = true;
      # The guests generate new host keys on every boot (no persistent
      # /etc/ssh), so known_hosts cannot pin them; the vchan relay socket
      # already ties the connection to that domain. LogLevel ERROR drops the
      # "Permanently added" warning on every connection
      StrictHostKeyChecking = "no";
      UserKnownHostsFile = "/dev/null";
      LogLevel = "ERROR";
    }
    // lib.optionalAttrs (relaySsh h.name != null) {
      ProxyCommand = "${sshWait} ${
        if lib.elem h.name imageDomainNames then "xen-image@${h.name}" else "microvm@${h.name}"
      } ${relaySsh h.name}";
    }
    # Debian images (Whonix) may lack the terminfo of dom0's terminal
    // lib.optionalAttrs (lib.elem h.name imageDomainNames) {
      SetEnv.TERM = "xterm-256color";
    };
  };

  settings = builtins.foldl' (acc: h: acc // mkSettingsBlock h) {
    # Goes to dom0's own agent (SSH_AUTH_SOCK), never to the GitHub agent
    # that VMs get (home.nix)
    "*" = {
      AddKeysToAgent = "yes";
    };
    "github.com" = {
      IdentityAgent = githubAgentSocket;
      IdentitiesOnly = true;
    };
  } hosts;

  # ssh_config text: "Host …" blocks sorted, "*" last (first match wins),
  # options sorted; booleans yes/no, SetEnv as K=V
  render =
    v:
    if builtins.isBool v then
      (if v then "yes" else "no")
    else if builtins.isAttrs v then
      lib.concatStringsSep " " (lib.mapAttrsToList (k: x: "${k}=${toString x}") v)
    else
      toString v;
  block =
    pattern: opts:
    "Host ${pattern}\n" + lib.concatStrings (lib.mapAttrsToList (k: v: "  ${k} ${render v}\n") opts);
  patterns = lib.filter (p: p != "*") (builtins.attrNames settings) ++ [ "*" ];
in
{
  # System-wide (/etc/ssh/ssh_config): was home-manager's ~/.ssh/config
  programs.ssh.extraConfig = lib.concatStringsSep "\n" (
    lib.optional (hostStrings != "") hostStrings ++ map (p: block p settings.${p}) patterns
  );
}

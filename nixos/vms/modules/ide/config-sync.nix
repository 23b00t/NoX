# An editor config pulled from a git remote: systemd service
# ide-<name>-config clones `repo` into `dir` and fast-forwards it on every
# boot. Used by the editor submodules (nvim.nix, steelix.nix, …).
{
  pkgs,
  user,
  name,
  repo,
  dir,
}:
let
  # Runs once per boot; waits for GitHub itself instead of systemd restarts:
  # the VM's network-online comes long before the uplink through
  # sys-firewall/sys-net works (2026-10-27: "Could not resolve host" for
  # ~5 min after a restart of the sys VMs, then the restart limit hit)
  script = pkgs.writeShellScript "ide-${name}-sync" ''
    set -eu
    git=${pkgs.git}/bin/git

    CONFIG_DIR="${dir}"
    REPO_URL="${repo}"
    # Fetched over HTTPS: an SSH origin (git@github.com, for pushing) needs
    # ssh and the forwarded GitHub agent, neither exists at boot
    case "$REPO_URL" in
      git@github.com:*) FETCH_URL="https://github.com/''${REPO_URL#git@github.com:}" ;;
      *) FETCH_URL="$REPO_URL" ;;
    esac

    # GitHub reachable (DNS and HTTPS), at most 5 minutes
    for i in $(seq 60); do
      "$git" ls-remote -q "$FETCH_URL" HEAD >/dev/null 2>&1 && break
      if [ "$i" = 60 ]; then
        echo "GitHub not reachable after 5 minutes, no sync this boot"
        exit 0
      fi
      sleep 5
    done

    if [ ! -d "$CONFIG_DIR/.git" ]; then
      mkdir -p "$(dirname "$CONFIG_DIR")"
      "$git" clone "$FETCH_URL" "$CONFIG_DIR"
      "$git" -C "$CONFIG_DIR" remote set-url origin "$REPO_URL"
      exit 0
    fi
    cd "$CONFIG_DIR"
    # Local changes (e.g. lazy-lock.json after a plugin update) win: no pull
    # until they are committed or reverted
    if [ -n "$("$git" status --porcelain)" ]; then
      echo "Local changes in $CONFIG_DIR, not pulling:"
      "$git" status --short
      exit 0
    fi
    "$git" pull --ff-only "$FETCH_URL" "$("$git" rev-parse --abbrev-ref HEAD)"
  '';
in
{
  "ide-${name}-config" = {
    description = "Clone/update the ${name} config into ${dir}";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    requires = [ "network-online.target" ];
    # The script waits for GitHub itself (up to 5 min); exec, not oneshot,
    # so multi-user.target does not wait for it
    serviceConfig = {
      Type = "exec";
      User = user;
      Group = "users";
      ExecStart = script;
    };
  };
}

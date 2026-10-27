{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.ide;
  # Path where the agent socket will be available in the VM (matches SSH RemoteForward)
  githubAgentSocket = "/tmp/ssh-github-agent.sock";
  # Runs once per boot; waits for GitHub itself instead of systemd restarts:
  # the VM's network-online comes long before the uplink through
  # sys-firewall/sys-net works (xmg 2026-10-27: "Could not resolve host" for
  # ~5 min after a restart of the sys VMs, then the restart limit hit)
  lazyvimSyncScript = pkgs.writeShellScript "ide-lazyvim-sync" ''
    set -eu
    git=${pkgs.git}/bin/git

    NVIM_DIR="/home/${cfg.user}/.config/nvim"
    REPO_URL="${cfg.lazyvimRepo}"
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

    if [ ! -d "$NVIM_DIR/.git" ]; then
      mkdir -p "$(dirname "$NVIM_DIR")"
      "$git" clone "$FETCH_URL" "$NVIM_DIR"
      "$git" -C "$NVIM_DIR" remote set-url origin "$REPO_URL"
      exit 0
    fi
    cd "$NVIM_DIR"
    # Local changes (e.g. lazy-lock.json after a plugin update) win: no pull
    # until they are committed or reverted
    if [ -n "$("$git" status --porcelain)" ]; then
      echo "Local changes in $NVIM_DIR, not pulling:"
      "$git" status --short
      exit 0
    fi
    "$git" pull --ff-only "$FETCH_URL" "$("$git" rev-parse --abbrev-ref HEAD)"
  '';
in
{
  options.services.ide = {
    enable = lib.mkEnableOption "IDE stack (nvim, git, etc.)";
    user = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "Target user for IDE-related configuration";
    };

    githubAgent.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Expose the dedicated forwarded GitHub SSH agent/socket inside this VM.";
    };

    lazyvimRepo = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/LazyVim/starter";
      description = "Git URL of the LazyVim config repository (default: the upstream starter)";
    };
  };

  config = lib.mkIf cfg.enable {
    environment = {
      systemPackages = with pkgs; [
        gnupg
        pinentry-curses
        git
        gh
        openssl

        python3
        fd
        zip
        xz
        unzip

        gcc
        gnumake
        # rustc
        # cargo
        # rust-analyzer
        watchexec
        statix
        tree-sitter
        # vectorcode
        nodejs
        # nodePackages.npm
        watchman
        icu

        ripgrep
        fzf

        lazygit
        # (pkgs.writeShellScriptBin "lazygit" ''
        #   export GPG_TTY=$(tty)
        #   ${pkgs.gnupg}/bin/gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1
        #   exec ${pkgs.lazygit}/bin/lazygit "$@"
        # '')
      ];

      variables = {
        EDITOR = "nvim";
        VISUAL = "nvim";
      }
      // lib.optionalAttrs cfg.githubAgent.enable {
        # Set SSH_AUTH_SOCK for all environments to the correct agent socket path
        SSH_AUTH_SOCK = githubAgentSocket;
      };

      etc."gpg-agent.conf".text = ''
        pinentry-program /run/current-system/sw/bin/pinentry-tty
      '';
    };

    programs = {
      # für statisch gelinkte Binaries in nvim
      nix-ld.enable = true;

      nix-ld.libraries = with pkgs; [ icu ];

      neovim = {
        enable = true;
        defaultEditor = true;
        withNodeJs = true;
        withPython3 = true;
      };

      git = {
        enable = true;
        config = {
          help.autocorrect = 1;
          push.default = "simple";
          pull.rebase = false;
          "branch \"main\"".mergeoptions = "--no-edit";
          init.defaultBranch = "main";
          # Identity and signing (user.name, user.email, signing key) come
          # from the user's config (NoX docs/options.md, "git identity")
        };
      };

      ssh = lib.mkIf cfg.githubAgent.enable {
        # DO NOT set "IdentitiesOnly yes" for github.com if you rely on agent forwarding!
        # This disables forwarded keys and allows only explicit local IdentityFile-entries.
        # To use agent forwarding, simply let ssh's default handle it.
        extraConfig = ''
          Host github.com
            # IdentityAgent can be set if you need a nonstandard socket (usually not required)
            # IdentityAgent ${githubAgentSocket}
        '';
      };
    };

    systemd.tmpfiles.rules = [
      "d /home/${cfg.user}/.config 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/.gnupg 0700 ${cfg.user} users -"
      "L+ /home/${cfg.user}/.gnupg/gpg-agent.conf - - - - /etc/gpg-agent.conf"
    ];

    systemd.services.ide-lazyvim-config = {
      description = "Clone/update LazyVim config into ~/.config/nvim";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      requires = [ "network-online.target" ];
      # The script waits for GitHub itself (up to 5 min); exec, not oneshot,
      # so multi-user.target does not wait for it
      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = "users";
        ExecStart = lazyvimSyncScript;
      };
    };
  };
}

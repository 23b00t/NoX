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
  lazyvimSyncScript = pkgs.writeShellScript "ide-lazyvim-sync" ''
    set -e

    NVIM_DIR="/home/${cfg.user}/.config/nvim"
    REPO_URL="${cfg.lazyvimRepo}"

    if [ ! -d "$NVIM_DIR/.git" ]; then
      mkdir -p "$(dirname "$NVIM_DIR")"
      ${pkgs.git}/bin/git clone "$REPO_URL" "$NVIM_DIR"
    else
      cd "$NVIM_DIR"
      # Over HTTPS: the origin is SSH (git@github.com, for pushing), but at
      # boot there is neither ssh in PATH nor the forwarded GitHub agent
      ${pkgs.git}/bin/git pull --ff-only "$REPO_URL" "$(${pkgs.git}/bin/git rev-parse --abbrev-ref HEAD)"
    fi
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
    environment.systemPackages = with pkgs; [
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

    # für statisch gelinkte Binaries in nvim
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = with pkgs; [ icu ];

    programs.neovim = {
      enable = true;
      defaultEditor = true;
      withNodeJs = true;
      withPython3 = true;
    };

    programs.git = {
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

    programs.ssh = lib.mkIf cfg.githubAgent.enable {
      # DO NOT set "IdentitiesOnly yes" for github.com if you rely on agent forwarding!
      # This disables forwarded keys and allows only explicit local IdentityFile-entries.
      # To use agent forwarding, simply let ssh's default handle it.
      extraConfig = ''
        Host github.com
          # IdentityAgent can be set if you need a nonstandard socket (usually not required)
          # IdentityAgent ${githubAgentSocket}
      '';
    };

    environment.variables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
    }
    // lib.optionalAttrs cfg.githubAgent.enable {
      # Set SSH_AUTH_SOCK for all environments to the correct agent socket path
      SSH_AUTH_SOCK = githubAgentSocket;
    };

    systemd.tmpfiles.rules = [
      "d /home/${cfg.user}/.config 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/.gnupg 0700 ${cfg.user} users -"
      "L+ /home/${cfg.user}/.gnupg/gpg-agent.conf - - - - /etc/gpg-agent.conf"
    ];

    environment.etc."gpg-agent.conf".text = ''
      pinentry-program /run/current-system/sw/bin/pinentry-tty
    '';

    systemd.services.ide-lazyvim-config = {
      description = "Clone/update LazyVim config into ~/.config/nvim";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      requires = [ "network-online.target" ];
      # The uplink (sys-net) can come up after network-online in the VM
      startLimitBurst = 10;
      startLimitIntervalSec = 600;
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = "users";
        ExecStart = lazyvimSyncScript;
        Restart = "on-failure";
        RestartSec = 30;
      };
    };
  };
}

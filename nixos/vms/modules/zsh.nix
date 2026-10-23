{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.zsh-env;
  ohMyPoshThemes = pkgs.fetchFromGitHub {
    owner = "JanDeDobbeleer";
    repo = "oh-my-posh";
    rev = "28f4cc417a19d90c1cd297631207b2c64c63e2d4";
    sha256 = "sha256-YYlRi3nt0VLnBSiGqiuerJJFrkjFt2m2VeZHht/aRsg=";
  };
in
{
  options.services.zsh-env = {
    enable = lib.mkEnableOption "zsh shell environment with plugins";

    user = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "Target user for zsh config";
    };

    ohMyPoshTheme = lib.mkOption {
      type = lib.types.str;
      default = "montys.omp.json";
      description = "oh-my-posh theme file name located in ~/.cache/oh-my-posh/themes/";
    };

    extraAliases = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra or overriding zsh aliases for this host.";
    };

    extraShellInit = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra shellInit code appended for this host.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;

      shellAliases =
        {
          ll = "ls -l";
          la = "ls -la";
          sc = "systemctl";
          n = "nvim";
          y = "yazi";
          cd = "z";
        }
        // cfg.extraAliases;

      histSize = 10000;
      histFile = "$HOME/.zsh_history";

      shellInit = ''
        if [[ $- != *i* ]]; then
          return
        fi
        export HISTIGNORE="rm *:cp *"
        setopt HIST_IGNORE_ALL_DUPS
        export GPG_TTY=$(tty)

        eval "$(zoxide init zsh)"

        export ANTIDOTE_HOME="$HOME/.cache/antidote"
        mkdir -p "$ANTIDOTE_HOME"
        source ${pkgs.antidote}/share/antidote/antidote.zsh

        antidote bundle < ~/.zsh_plugins.txt > ~/.zsh_plugins.zsh
        antidote load

        if command -v oh-my-posh >/dev/null 2>&1; then
          eval "$(oh-my-posh init zsh --config "$HOME/.cache/oh-my-posh/themes/${cfg.ohMyPoshTheme}")"
        fi

        export SSL_CERT_DIR=/etc/ssl/certs
        export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
      '' + cfg.extraShellInit;
    };

    environment.systemPackages = with pkgs; [
      antidote
      oh-my-posh
      eza
      zoxide
    ];

    users.defaultUserShell = pkgs.zsh;
    users.users.${cfg.user}.shell = pkgs.zsh;

    environment.etc."zsh_plugins.txt".text = ''
      zsh-users/zsh-autosuggestions
      zap-zsh/supercharge
      zsh-users/zsh-syntax-highlighting
      atoftegaard-git/zsh-omz-autocomplete
      MichaelAquilina/zsh-you-should-use
      zap-zsh/magic-enter
      chivalryq/git-alias
      zap-zsh/vim
      zap-zsh/sudo
      wintermi/zsh-oh-my-posh
    '';

    systemd.tmpfiles.rules = [
      "L+ /home/${cfg.user}/.zshrc - - - - /etc/zshrc"
      "L+ /home/${cfg.user}/.zsh_plugins.txt - - - - /etc/zsh_plugins.txt"

      "d /home/${cfg.user}/.cache 0755 ${cfg.user} users -"
      "d /home/${cfg.user}/.cache/oh-my-posh 0755 ${cfg.user} users -"

      "z /home/${cfg.user}/.cache/oh-my-posh/themes - - - - -"
      "L+ /home/${cfg.user}/.cache/oh-my-posh/themes - - - - ${ohMyPoshThemes}/themes"
    ];
  };
}

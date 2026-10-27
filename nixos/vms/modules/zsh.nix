{
  config,
  lib,
  pkgs,
  ...
}:
# zsh in the VM: a neutral base (completion, autosuggestions, syntax
# highlighting, history, zoxide). Plugins (antidote), the oh-my-posh prompt
# and own aliases come from the user's config
let
  cfg = config.services.zsh-env;
  ohMyPoshThemes = pkgs.fetchFromGitHub {
    owner = "JanDeDobbeleer";
    repo = "oh-my-posh";
    rev = "28f4cc417a19d90c1cd297631207b2c64c63e2d4";
    sha256 = "sha256-YYlRi3nt0VLnBSiGqiuerJJFrkjFt2m2VeZHht/aRsg=";
  };
  withPlugins = cfg.plugins != [ ];
  withPrompt = cfg.ohMyPoshTheme != null;
in
{
  options.services.zsh-env = {
    enable = lib.mkEnableOption "zsh shell environment with plugins";

    user = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "Target user for zsh config";
    };

    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "zsh-users/zsh-autosuggestions" ];
      description = "antidote plugins (GitHub owner/repo), loaded at shell start; empty: no antidote.";
    };

    ohMyPoshTheme = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "montys.omp.json";
      description = "oh-my-posh theme file name located in ~/.cache/oh-my-posh/themes/; null: no oh-my-posh prompt.";
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

      shellAliases = {
        ll = "ls -l";
        la = "ls -la";
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

      ''
      + lib.optionalString withPlugins ''
        export ANTIDOTE_HOME="$HOME/.cache/antidote"
        mkdir -p "$ANTIDOTE_HOME"
        source ${pkgs.antidote}/share/antidote/antidote.zsh

        antidote bundle < ~/.zsh_plugins.txt > ~/.zsh_plugins.zsh
        antidote load

      ''
      + lib.optionalString withPrompt ''
        if command -v oh-my-posh >/dev/null 2>&1; then
          eval "$(oh-my-posh init zsh --config "$HOME/.cache/oh-my-posh/themes/${cfg.ohMyPoshTheme}")"
        fi

      ''
      + ''
        export SSL_CERT_DIR=/etc/ssl/certs
        export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
      ''
      + cfg.extraShellInit;
    };

    environment.systemPackages =
      lib.optional withPlugins pkgs.antidote
      ++ lib.optional withPrompt pkgs.oh-my-posh
      ++ [
        pkgs.eza
        pkgs.zoxide
      ];

    users.defaultUserShell = pkgs.zsh;
    users.users.${cfg.user}.shell = pkgs.zsh;

    environment.etc."zsh_plugins.txt" = lib.mkIf withPlugins {
      text = lib.concatMapStrings (p: p + "\n") cfg.plugins;
    };

    systemd.tmpfiles.rules = [
      "L+ /home/${cfg.user}/.zshrc - - - - /etc/zshrc"
    ]
    ++ lib.optional withPlugins "L+ /home/${cfg.user}/.zsh_plugins.txt - - - - /etc/zsh_plugins.txt"
    ++ [ "d /home/${cfg.user}/.cache 0755 ${cfg.user} users -" ]
    ++ lib.optionals withPrompt [
      "d /home/${cfg.user}/.cache/oh-my-posh 0755 ${cfg.user} users -"

      "z /home/${cfg.user}/.cache/oh-my-posh/themes - - - - -"
      "L+ /home/${cfg.user}/.cache/oh-my-posh/themes - - - - ${ohMyPoshThemes}/themes"
    ];
  };
}

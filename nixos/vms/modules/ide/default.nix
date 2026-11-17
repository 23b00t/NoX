# IDE stack: what every editor shares (git, search tools, the forwarded
# GitHub agent) plus one submodule per editor.
# Several editors can be enabled side by side; `defaultEditor` picks
# EDITOR/VISUAL.
#
# A new editor: one file ./<editor>.nix with `services.ide.<editor>.enable`,
# its packages, `services.ide.editors.<editor> = { command; desktop; }` and,
# if its config lives in a git remote, a `configRepo` synced with
# ./config-sync.nix; plus one entry in `imports` below.
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
  editors = lib.attrNames cfg.editors;
  defaultEditor =
    cfg.editors.${if cfg.defaultEditor != null then cfg.defaultEditor else lib.head editors};
in
{
  imports = [
    ./nvim.nix
    ./steelix.nix
  ];

  options.services.ide = {
    enable = lib.mkEnableOption "IDE stack (git, tools and the enabled editors)";
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

    defaultEditor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "steelix";
      description = "Enabled editor that becomes EDITOR/VISUAL (e.g. nvim, steelix); null: the alphabetically first enabled one.";
    };

    editors = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            command = lib.mkOption {
              type = lib.types.str;
              description = "Command that opens a file (EDITOR).";
            };
            desktop = lib.mkOption {
              type = lib.types.str;
              description = "Desktop entry that opens text files (xdg-open).";
            };
          };
        }
      );
      default = { };
      internal = true;
      description = "Every enabled editor, set by the editor submodules.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.defaultEditor == null || cfg.editors ? ${cfg.defaultEditor};
        message = "services.ide.defaultEditor = \"${toString cfg.defaultEditor}\" is not an enabled editor (enabled: ${lib.concatStringsSep ", " editors}).";
      }
    ];

    environment = {
      # Search tools for the editors' pickers (and yazi's search)
      systemPackages = with pkgs; [
        git
        fd
        ripgrep
        fzf
      ];

      # Session variables, so they win over vim's default
      # (common-config, programs.vim.defaultEditor)
      sessionVariables = lib.mkIf (editors != [ ]) {
        EDITOR = defaultEditor.command;
        VISUAL = defaultEditor.command;
      };

      variables = lib.optionalAttrs cfg.githubAgent.enable {
        # Set SSH_AUTH_SOCK for all environments to the correct agent socket path
        SSH_AUTH_SOCK = githubAgentSocket;
      };
    };

    programs = {
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

    # Text files open in the default editor (common-config: vim)
    xdg.mime.defaultApplications = lib.mkIf (editors != [ ]) (
      lib.genAttrs [ "text/plain" "text/markdown" ] (_: defaultEditor.desktop)
    );
  };
}

# ide editor: Neovim with a LazyVim config pulled from a git remote
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ide = config.services.ide;
  cfg = ide.nvim;
in
{
  options.services.ide.nvim = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = ide.enable;
      defaultText = lib.literalExpression "config.services.ide.enable";
      description = "Neovim with the LazyVim config from `configRepo`.";
    };

    configRepo = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/LazyVim/starter";
      description = "Git URL of the LazyVim config repository, synced into ~/.config/nvim (default: the upstream starter).";
    };
  };

  config = lib.mkIf (ide.enable && cfg.enable) {
    services.ide.editors.nvim = {
      command = "nvim";
      desktop = "nvim.desktop";
    };

    # LazyVim: nvim-treesitter compiles parsers (gcc), telescope-fzf-native
    # is built with make, mason unpacks with unzip and installs Python tools
    environment.systemPackages = with pkgs; [
      gcc
      gnumake
      unzip
      python3
      tree-sitter
      nodejs
      watchman
      icu
    ];

    programs = {
      # für statisch gelinkte Binaries in nvim
      nix-ld.enable = true;
      nix-ld.libraries = with pkgs; [ icu ];

      neovim = {
        enable = true;
        withNodeJs = true;
        withPython3 = true;
      };
    };

    systemd.services = import ./config-sync.nix {
      inherit pkgs;
      inherit (ide) user;
      name = "nvim";
      repo = cfg.configRepo;
      dir = "/home/${ide.user}/.config/nvim";
    };
  };
}

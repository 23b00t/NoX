# Role config: the VM that holds the config repo (~/config) and the user's
# signing key, with git, lazygit and an editor (nox.configVm.editor). Who
# controls this VM signs configs that dom0 runs: no browser, no foreign
# code here.
#
# `nox-config` (in the VM): status, diff, commit (signed), push (to the
# remote, if there is one), pull (the bundles dom0 copied in). Every commit
# also refreshes ~/outbox/config.bundle: with `nox.builder.source = "local"`
# dom0-update fetches it from there (nox pull) and hands it to the builder.
# Bundles in ~/Incoming/dom0 (nox-install's seed at the first start, the
# builder's flake.lock bumps after `nox update`) are taken in right away.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.nox.configVm;
  editors = {
    nano = pkgs.nano;
    helix = pkgs.helix;
    nvim = pkgs.neovim;
    kate = pkgs.kdePackages.kate;
    gnome-text-editor = pkgs.gnome-text-editor;
    vscodium = pkgs.vscodium;
    zed = pkgs.zed-editor;
  };
  # The command that opens a file or the repo
  editorCommand = {
    nano = "nano";
    helix = "hx";
    nvim = "nvim";
    kate = "kate";
    gnome-text-editor = "gnome-text-editor";
    vscodium = "codium";
    zed = "zeditor";
  };
  editor = editorCommand.${cfg.editor};

  # After every commit: the bundle dom0 fetches (nox.builder.source = "local")
  postCommit = pkgs.writeShellScript "post-commit" ''
    mkdir -p "$HOME/outbox"
    ${pkgs.git}/bin/git bundle create --quiet "$HOME/outbox/config.bundle.new" --branches 2>/dev/null &&
      mv -f "$HOME/outbox/config.bundle.new" "$HOME/outbox/config.bundle"
  '';
  hooks = pkgs.runCommand "nox-config-hooks" { } ''
    mkdir -p $out
    ln -s ${postCommit} $out/post-commit
  '';

  noxConfig = pkgs.writeShellApplication {
    name = "nox-config";
    runtimeInputs = [
      pkgs.git
      pkgs.openssh
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      repo="$HOME/config"
      inbox="$HOME/Incoming/dom0"
      key="$HOME/.ssh/nox-signing-key"

      usage() {
        cat <<EOF
      usage: nox-config status|diff|commit <message>|push|pull|edit
        status   git status of ~/config
        diff     what changed since the last commit
        commit   commit everything, signed with your key (~/.ssh/nox-signing-key);
                 refreshes ~/outbox/config.bundle for dom0
        push     push to the remote (GitHub), if the config has one
        pull     take in the bundles dom0 copied to ~/Incoming/dom0 (the seed of
                 nox-install, the builder's flake.lock bumps)
        edit     open ~/config in ${editor}
      EOF
        exit 2
      }

      # The repo's git settings: signed commits with the user's key, the
      # bundle hook
      setup() {
        git -C "$repo" config core.hooksPath ${hooks}
        if [ -e "$key" ]; then
          git -C "$repo" config gpg.format ssh
          git -C "$repo" config user.signingkey "$key"
          git -C "$repo" config commit.gpgsign true
        fi
      }

      pull() {
        local b
        [ -d "$inbox" ] || return 0
        if [ -e "$inbox/signing-key" ]; then
          install -d -m 700 "$HOME/.ssh"
          install -m 600 "$inbox/signing-key" "$key"
          ssh-keygen -y -f "$key" >"$key.pub"
          rm -f "$inbox/signing-key"
          echo "nox-config: signing key in $key"
        fi
        for b in "$inbox"/*.bundle; do
          [ -e "$b" ] || continue
          git bundle verify --quiet "$b" >/dev/null 2>&1 || { echo "nox-config: $b is no git bundle, left there" >&2; continue; }
          if [ ! -d "$repo/.git" ]; then
            git clone --quiet "$b" "$repo"
            git -C "$repo" remote remove origin
            # The remote nox-install pushed to (GitHub), if any
            if [ -s "$inbox/remote" ]; then
              git -C "$repo" remote add origin "$(head -n 1 "$inbox/remote")"
              rm -f "$inbox/remote"
            fi
            echo "nox-config: ~/config from $(basename "$b")"
          else
            # Only fast-forwards: a bump commit on top of what is here
            br="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
            if git -C "$repo" fetch --quiet "$b" "refs/heads/$br" &&
              git -C "$repo" merge --quiet --ff-only FETCH_HEAD; then
              echo "nox-config: $br updated from $(basename "$b")"
            else
              echo "nox-config: $(basename "$b") is not a fast-forward of $br, left there" >&2
              continue
            fi
          fi
          rm -f "$b"
          setup
          ${postCommit}
        done
      }

      cmd="''${1:-status}"
      [ $# -eq 0 ] || shift
      case "$cmd" in
        pull) pull; exit 0 ;;
        -h | --help | help) usage ;;
      esac
      [ -d "$repo/.git" ] || { echo "nox-config: no ~/config yet (nox-config pull, after dom0 copied the seed)" >&2; exit 1; }
      setup
      case "$cmd" in
        status) git -C "$repo" status ;;
        diff) git -C "$repo" diff HEAD ;;
        commit)
          [ $# -gt 0 ] || usage
          [ -e "$key" ] || { echo "nox-config: no signing key ($key)" >&2; exit 1; }
          git -C "$repo" add -A
          git -C "$repo" commit -S -m "$*"
          ;;
        push)
          if [ -z "$(git -C "$repo" remote)" ]; then
            echo "nox-config: no remote (a local config: dom0 fetches ~/outbox/config.bundle)" >&2
            exit 1
          fi
          git -C "$repo" push
          ;;
        edit) cd "$repo" && exec ${editor} . ;;
        *) usage ;;
      esac
    '';
  };
in
{
  imports = [ ../vms/modules/yazi-config.nix ];

  options.nox.configVm.editor = lib.mkOption {
    type = lib.types.enum (lib.attrNames editors);
    default = "nano";
    description = "Editor of the config VM (`nox-config edit`); the GUI ones (kate, gnome-text-editor, vscodium, zed) show up in dom0 over wprs.";
  };

  config = {
    environment.systemPackages = [
      noxConfig
      pkgs.git
      pkgs.lazygit
      editors.${cfg.editor}
    ];
    # over vim from common-config (programs.vim.defaultEditor)
    environment.variables.EDITOR = lib.mkForce editor;

    # The bundles dom0 copies in: taken in as they arrive
    users.users.user.linger = true;
    systemd.user = {
      paths.nox-config-pull = {
        description = "Bundles from dom0 for ~/config";
        wantedBy = [ "default.target" ];
        pathConfig = {
          # nox copy writes into this directory (dom0 as the source)
          PathChanged = "%h/Incoming/dom0";
          MakeDirectory = true;
        };
      };
      services.nox-config-pull = {
        description = "Take the bundles from dom0 into ~/config";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${noxConfig}/bin/nox-config pull";
        };
      };
    };
  };
}

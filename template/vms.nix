# The domains of this config (schema: NoX nixos/registry/vms.nix, docs in
# NoX docs/options.md). A VM is one entry: its role (the kind of work: base
# software and defaults), trust label, apps and resources. With `{ host,
# ... }:` (the machine) `enable = host == "<name>"` runs a VM only there.
#
# sys-net, sys-usb and sys-firewall come with NoX; more infrastructure
# with `nox.infra.<name>.enable` (sys-vpn, sys-print, disp, disp-backup,
# builder).
_: {
  nox = {
    infra = {
      disp.enable = true;
      # The builder VM builds and signs dom0's system (`nox update`, `nox
      # rebuild`); its keys are in vms/builder (`builderKeys` in flake.nix),
      # the repo it builds below
      builder.enable = true;
    };

    vms = {
      # The repo the builder builds (a private one by SSH with the
      # builder's deploy key, NoX README "Builder"). dom0 logs in with the
      # key in vms/builder/ssh-key-builder-<host>.pub (nox-install)
      builder.module.nox.builder.repoUrl = "https://github.com/<you>/<config>";
      # The config repo (~/config), your signing key and an editor
      # (nox-config; every machine has exactly one); pushes to GitHub
      # through dom0's GitHub agent
      config = {
        role = "config";
        index = 2;
        short = "cfg";
        label = "config";
        githubAgent = true;
        module = ./vms/config.nix;
      };
      # Passwords; no network
      vault = {
        role = "desktop";
        index = 3;
        short = "v";
        label = "vault";
        uplink = null;
        clipboard = "deny";
        apps.keepassxc = { };
      };
      # Browsing
      net = {
        role = "browser";
        index = 4;
        short = "n";
        label = "untrusted";
        apps.firefox = { };
      };
      # Development: editor, zsh, zellij, yazi
      dev = {
        role = "dev";
        index = 5;
        short = "dv";
        label = "dev";
        # module = ./vms/dev.nix;   # the VM's own NixOS settings
      };
    };
  };
}

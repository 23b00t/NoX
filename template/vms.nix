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
      # The builder VM builds and signs dom0's system (`nox update`); it
      # needs `builderKeys` in flake.nix and the repo it builds, below
      # builder.enable = true;
    };

    vms = {
      # With nox.infra.builder: the repo it builds (a private one by SSH
      # with the builder's deploy key, NoX README) and the key dom0 logs in
      # with (private part: dom0's ~/.ssh/builder-vm)
      # builder = {
      #   module.nox.builder.repoUrl = "https://github.com/<you>/<config>";
      #   hostSSHKey = "ssh-ed25519 AAAA… builder-vm";
      # };
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

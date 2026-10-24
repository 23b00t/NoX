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
    };

    vms = {
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

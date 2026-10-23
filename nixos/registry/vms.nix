# The VM schema (NoX modules step 3): `nox.vms.<name>` for NixOS guests,
# `nox.images.<name>` for image domains (Whonix, Kali). Evaluated with
# lib.evalModules on its own (not inside a NixOS system), with `host` (the
# machine) as special argument, so the same definitions serve dom0 and the
# standalone VM outputs. `legacy.nix` turns the result into the registry
# the modules read today (vmRegistry).
#
# Optional fields are null by default: null means NoX's default, which the
# modules apply (given in each description).
{ lib, ... }:
let
  inherit (lib) mkOption types;

  copyType = types.submodule {
    options = {
      incoming = mkOption {
        type = types.nullOr (
          types.enum [
            "ask"
            "warn"
            "deny"
          ]
        );
        default = null;
        description = "Files into the VM: ask, warn (ask, the user types the VM's name) or deny. Default: ask.";
      };
      outgoing = mkOption {
        type = types.nullOr (
          types.enum [
            "ask"
            "warn"
            "deny"
          ]
        );
        default = null;
        description = "Files out of the VM. Default: deny for sys-* VMs, else ask.";
      };
    };
  };

  # Fields VMs and image domains share
  common = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether this machine runs the domain (the definition is kept either way).";
    };
    index = mkOption {
      type = types.ints.between 1 254;
      description = "Last octet of the domain's addresses (admin net, uplink, USB/IP link), its tap and MAC.";
    };
    short = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Short alias for the command line tools.";
    };
    label = mkOption {
      type = types.nullOr (
        types.enum [
          "sys"
          "dev"
          "personal"
          "untrusted"
          "vault"
          "anon"
        ]
      );
      default = null;
      description = "Trust label: the window border color in dom0. Default: untrusted.";
    };
  };

  vmOptions = common // {
    autostart = mkOption {
      type = types.bool;
      default = false;
      description = "Start with dom0.";
    };
    uplink = mkOption {
      type = types.nullOr types.str;
      default = "sys-firewall";
      description = "Driver domain that serves the VM's uplink (sys-firewall, sys-vpn, sys-net); null: offline.";
    };
    egress = mkOption {
      type = types.nullOr (
        types.listOf (
          types.submodule {
            options = {
              to = mkOption {
                type = types.str;
                description = "Destination net (CIDR).";
              };
              ports = mkOption {
                type = types.listOf types.port;
                default = [ ];
                description = "Ports; empty: all ports to that net.";
              };
            };
          }
        )
      );
      default = null;
      description = "Outgoing traffic the VM may send through sys-firewall; null: everything. DNS always through sys-firewall's resolver.";
    };
    disposable = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Boots empty every time (home and store overlay images are deleted before start and after stop). Default: false.";
    };
    memPriority = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "RAM balancer priority (higher grows first). Default: 0.";
    };
    storeGroup = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Shared read-only store image (nox.storeGroups); null: an image of its own.";
    };
    clipboard = mkOption {
      type = types.nullOr (
        types.enum [
          "allow"
          "ask"
          "deny"
        ]
      );
      default = null;
      description = "Copy/paste through dom0. Default: deny for sys-* VMs, else allow.";
    };
    copy = mkOption {
      type = types.nullOr copyType;
      default = null;
      description = "Files between domains over nox-rpc (vm-copy, nox copy).";
    };
    backup = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "/home in the home backup (nox backup --all). Default: true except sys-* VMs and disposables.";
    };
    dbus = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Filtered session bus to dom0 (notifications, tray). Default: true.";
    };
    githubAgent = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "dom0's GitHub-only SSH agent in the VM. Default: false.";
    };
    labTarget = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "kali may test this VM's apps over the lab bridge (vm-lab attach). Default: false.";
    };
    # Transitional (step 3): replaced by the VM's modules/apps
    features = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      internal = true;
      description = "Tags for the tools (\"yazi\": nox explorer); goes away with `apps`.";
    };
    hostSSHKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      internal = true;
      description = "Public key dom0 logs in with over SSH; only the builder (dom0-update).";
    };
  };
in
{
  options.nox = {
    vms = mkOption {
      type = types.attrsOf (types.submodule { options = vmOptions; });
      default = { };
      description = "NixOS guests (microvm.nix on Xen).";
    };
    images = mkOption {
      type = types.attrsOf (types.submodule { options = common; });
      default = { };
      description = "Image domains (upstream disk images: Whonix, Kali); manual steps in the docs.";
    };
    network.adminPrefix = mkOption {
      type = types.str;
      default = "10.0.0";
      description = "First three octets of the admin net (dom0 .254, sys-net .253); a domain's address is <prefix>.<index>.";
    };
  };
}

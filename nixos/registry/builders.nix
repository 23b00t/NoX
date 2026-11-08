# Group builders (builder-trust.md 3.8, variants B/C/C+): `nox.builders.<name>`
# makes the VM builder-<name> (module ../vms/builder-group). It builds the
# images of the store groups with `nox.storeGroups.<g>.builder =
# "builder-<name>"` from the derivations dom0 hands over: no checkout, no
# evaluation. Its system is built by the builder (dom0's builder, which
# evaluates everything): all builders share the store image of the group
# `builders`, so a group builder never runs on an image it built itself.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.nox.builders;
  noCopy = {
    incoming = "deny";
    outgoing = "deny";
  };
in
{
  options.nox.builders = mkOption {
    type = types.attrsOf (
      types.submodule {
        options = {
          index = mkOption {
            type = types.ints.between 1 252;
            description = "Last octet of the VM's addresses (like `nox.vms.<name>.index`).";
          };
          short = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Short alias for the command line tools.";
          };
          hostSSHKey = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "ssh-ed25519 AAAA… builder-desktop-vm";
            description = "Public key dom0 logs in with (dom0-update; private part ~/.ssh/builder-<name>-vm).";
          };
          memory = mkOption {
            type = types.int;
            default = 4096;
            description = "Boot memory in MB: it only builds and runs mkfs.erofs, no evaluation.";
          };
          memoryMax = mkOption {
            type = types.int;
            default = 8192;
            description = "Memory it may grow to (balloon) in MB; max-jobs follows it.";
          };
          maxJobs = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "Nix `max-jobs` of the builder. Default: one job per 8 GB of `memoryMax`, at least 2. `nox update --max-jobs` overrides it for one run.";
          };
          cores = mkOption {
            type = types.nullOr types.ints.unsigned;
            default = null;
            description = "Nix `cores` per job (0: all). Default: Nix's (all). `nox update --cores` overrides it for one run.";
          };
          storeSize = mkOption {
            type = types.int;
            default = 60000;
            description = "Size of its store overlay in MB (`nox.vms.<name>.store.size`).";
          };
        };
      }
    );
    default = { };
    example = {
      desktop = {
        index = 41;
        hostSSHKey = "ssh-ed25519 AAAA… builder-desktop-vm";
      };
    };
    description = "Group builders: `<name>` makes the VM `builder-<name>`, which builds the images of the store groups that name it (`nox.storeGroups.<g>.builder`). dom0 takes their images only with the builder's image key (`services.dom0-update.imageKeys`, `nox.storeImages.asFiles`). Declare them for every machine; per machine `nox.vms.builder-<name>.enable` (the VM definitions are evaluated without a host).";
  };

  config = lib.mkIf (cfg != { }) {
    nox.vms =
      lib.mapAttrs' (
        name: b:
        lib.nameValuePair "builder-${name}" (
          lib.mapAttrsRecursive (_: lib.mkDefault) {
            inherit (b) index short;
            label = "sys";
            storeGroup = "builders";
            githubAgent = false;
            dbus = false;
            # a build VM sees untrusted code and has no GUI
            clipboard = "deny";
            copy = noCopy;
            memPriority = 10;
            inherit (b) memory memoryMax;
            store.size = b.storeSize;
          }
          // {
            inherit (b) hostSSHKey;
          }
        )
      ) cfg
      # The builder shares the image with the group builders (3.4), where
      # one of them runs
      // {
        builder.storeGroup = lib.mkIf (lib.any (n: config.nox.vms."builder-${n}".enable) (
          lib.attrNames cfg
        )) (lib.mkDefault "builders");
      };

    nox.storeGroups.builders.description = "The builder VMs, built by the builder";
  };
}

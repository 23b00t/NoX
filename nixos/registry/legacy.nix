# nox.vms / nox.images (vms.nix) → the registry entries the modules read
# today (vmRegistry: name, ip, nat, uplink, allowGitHubAgent, …). Fields
# left at null stay absent, so the modules keep applying their defaults.
# Lists sorted by name; `onHost` only the enabled ones.
{ lib }:
cfg:
let
  clean = lib.filterAttrs (_: v: v != null);
  ip = index: "${cfg.network.adminPrefix}.${toString index}";
  byName = lib.sort (a: b: a.name < b.name);

  vmEntry =
    name: v:
    clean {
      inherit name;
      inherit (v)
        short
        label
        autostart
        storeGroup
        clipboard
        disposable
        memPriority
        backup
        labTarget
        features
        hostSSHKey
        egress
        ;
      ip = ip v.index;
      nat = v.uplink != null;
      # sys-firewall is the modules' default
      uplink = if v.uplink == "sys-firewall" then null else v.uplink;
      allowGitHubAgent = v.githubAgent;
      enableHostDbusForward = v.dbus;
      copy =
        if v.copy == null then
          null
        else
          clean {
            inherit (v.copy) incoming outgoing;
          };
    };

  imageEntry =
    name: v:
    clean {
      inherit name;
      inherit (v) short label;
      ip = ip v.index;
    };

  entries = mk: set: byName (lib.mapAttrsToList mk set);
  enabled = lib.filterAttrs (_: v: v.enable);
in
{
  vms = entries vmEntry cfg.vms;
  images = entries imageEntry cfg.images;
  vmsOnHost = entries vmEntry (enabled cfg.vms);
  imagesOnHost = entries imageEntry (enabled cfg.images);
}

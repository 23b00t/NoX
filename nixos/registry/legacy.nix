# nox.vms / nox.images (vms.nix) → the registry entries the modules read
# today (vmRegistry: name, ip, nat, uplink, allowGitHubAgent, …). Fields
# left at null stay absent, so the modules keep applying their defaults.
# Lists sorted by name; `onHost` only the enabled ones.
#
# `apps` (enabled ones, catalog fields filled in) is what dom0 derives the
# desktop entries, waybar icons and tray starts from; the VM's own module and
# its role are not in the entries (definitions.nix).
{ lib }:
cfg:
let
  clean = lib.filterAttrs (_: v: v != null);
  ip = index: "${cfg.network.adminPrefix}.${toString index}";
  byName = lib.sort (a: b: a.name < b.name);
  inherit (import ./definitions.nix { inherit lib; } cfg) appsOf;

  appEntry = id: a: {
    inherit id;
    name = if a.name or null != null then a.name else id;
    binary = if a.binary or null != null then a.binary else id;
    args = a.args or null;
    x11 = a.x11 or null == true;
    # only `false` is written (the default stays absent)
    menu = if a.menu or null == false then false else null;
    tray = a.tray or null == true;
    trayArgs = a.trayArgs or null;
    genericName = a.genericName or null;
    icon = a.icon or null;
    categories = a.categories or null;
    mimeType = a.mimeType or null;
  };
  appsEntry =
    v:
    let
      apps = lib.mapAttrsToList appEntry (lib.filterAttrs (_: a: a.enable) (appsOf v));
    in
    if apps == [ ] then null else map clean apps;

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
        hostSSHKey
        egress
        role
        memory
        memoryMax
        vcpu
        gpu
        bluetooth
        ;
      homeSize = v.home.size;
      storeSize = v.store.size;
      storeMinFree = v.store.minFree;
      storeMaxFree = v.store.maxFree;
      # explorer (dom0) lists the VMs with the "yazi" feature
      features = if v.explorer == true then [ "yazi" ] else null;
      # a disposable (disposables.nix) has its base's apps installed, but no
      # desktop entries, tray starts or icons of its own
      apps = if v.disposableOf or null != null then null else appsEntry v;
      disposableOf = v.disposableOf or null;
      ip = ip v.index;
      nat = v.uplink != null;
      # sys-firewall is the modules' default
      uplink = if v.uplink == "sys-firewall" then null else v.uplink;
      allowGitHubAgent = v.githubAgent;
      enableHostDbusForward = v.dbus;
      inherit (v) wprsSharedMemory microphone;
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
      apps = appsEntry v;
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

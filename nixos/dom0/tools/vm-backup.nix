# nox backup (README "Backup", spec in xen-migration.md "2. Backup"): the
# work lives in nox-cli (crates/nox-cli/src/backup.rs); this module gives it
# its data (/etc/nox/registry.json `backup`: the VMs home takes and its
# `--all`, the full targets with their disks), the tools it runs and the
# 7-day reminder. disp-backup (vms/disp-backup) is the disk side.
{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:
let
  vms = config.microvm.vms or { };
  imageDomains = config.services.xen-image-domains.domains or { };
  # home: every NixOS VM of this machine; `--all` = those with registry `backup`
  homeVms = builtins.filter (n: n != "disp-backup") (lib.attrNames vms);
  homeDefault = map (vm: vm.name) (
    builtins.filter (vm: builtins.elem vm.name homeVms) vmRegistry.backupVms
  );

  regByName = lib.listToAttrs (map (vm: lib.nameValuePair vm.name vm) vmRegistry.vms);
  # What the start/stop of a disposable deletes (xen-dom0.nix
  # disposableImages): never backed up; a disposable with nothing else
  # (disp, disp-<vm>) is no full target
  wiped = [
    "home.img"
    "nix-store-overlay.img"
    "nix-db.img"
  ];

  # full targets: kind vm (its volumes, disk = file name without .img),
  # image (one raw file), dom0 (only ~/.ssh: the images have their own
  # targets, the rest comes back from the config), builder (its signing key)
  vmTargets = lib.concatLists (
    lib.mapAttrsToList (
      name: vm:
      let
        disposable = regByName.${name}.disposable or false;
        volumes = builtins.filter (v: !(disposable && builtins.elem (baseNameOf v.image) wiped)) (
          vm.config.config.microvm.volumes or [ ]
        );
        disks = map (v: {
          name = lib.removeSuffix ".img" (baseNameOf v.image);
          path = if lib.hasPrefix "/" v.image then v.image else "/var/lib/microvms/${name}/${v.image}";
        }) volumes;
      in
      if name == "builder" then
        [
          {
            inherit name;
            kind = "builder";
            disks = [
              {
                name = "key";
                path = "/var/lib/builder/signing-key";
              }
            ];
          }
        ]
      else
        lib.optional (disks != [ ] && name != "disp-backup") {
          inherit name disks disposable;
          kind = "vm";
        }
    ) vms
  );

  # Reminder: no home backup for 7 days (also a row in vm-doctor)
  reminder = pkgs.writeShellScript "vm-backup-reminder" ''
    last="$(cat "''${XDG_STATE_HOME:-$HOME/.local/state}/nox-backup/last" 2>/dev/null || echo 0)"
    if [ $(( $(${pkgs.coreutils}/bin/date +%s) - last )) -gt $((7 * 86400)) ]; then
      ${pkgs.libnotify}/bin/notify-send -a vm-backup "Backup" "Letztes Backup älter als 7 Tage: nox backup"
    fi
  '';
in
{
  programs.nox.registry.backup = {
    home = homeVms;
    inherit homeDefault;
    full =
      vmTargets
      ++ lib.mapAttrsToList (name: d: {
        inherit name;
        kind = "image";
        disks = [
          {
            name = "image";
            path = d.image;
          }
        ];
      }) imageDomains
      ++ [
        {
          name = "dom0";
          kind = "dom0";
          disks = [ { name = "ssh"; } ];
        }
      ];
  };

  # what nox backup runs besides nox-rpc, sudo, ssh and vm-usb
  environment.systemPackages = [
    pkgs.zstd
    pkgs.gnutar
    pkgs.coreutils
    pkgs.libnotify
  ];

  systemd.user = {
    services.vm-backup-reminder = {
      description = "Remind of the backup after 7 days";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${reminder}";
      };
    };
    timers.vm-backup-reminder = {
      description = "Daily backup reminder";
      timerConfig = {
        OnStartupSec = "10min";
        OnUnitActiveSec = "1d";
      };
      wantedBy = [ "timers.target" ];
    };
  };
}

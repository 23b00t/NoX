{
  lib,
  pkgs,
  config,
  inputs,
  vmRegistry,
  ...
}:
let
  vmName = lib.removeSuffix "-vm" (config.networking.hostName or "");
  # Window pixels through grant-shared memory from nox-relay's broker
  # (vms/modules/vchan-relay.nix), registry `wprsSharedMemory`
  grants =
    config.microvm.hypervisor == "xen" && (vmRegistry.byName.${vmName}.wprsSharedMemory or true);
  # The fleet's theme (registry nox.theme), the same as dom0's desktop
  theme = import ../../desktop/theme.nix {
    inherit lib;
    inherit (vmRegistry) theme;
  };
  # vm-clip-helper: explicit copy/paste via dom0's vm-clip, the selection
  # itself is not synced with dom0 (wprsd --selection-sync false)
  clipboard = import ../../modules/wprs-clipboard.nix { inherit pkgs; };
in
{
  # wprs from our fork, the same build as dom0 (modules/wprs-overlay.nix)
  nixpkgs.overlays = [ (import ../../modules/wprs-overlay.nix { inherit inputs; }) ];

  systemd.user.services.wprsd = {
    description = "wprsd instance";
    after = [ "network.target" ];
    serviceConfig = {
      Type = "simple";
      Environment = [
        "PATH=/run/current-system/sw/bin"
        "RUST_BACKTRACE=1"
      ];
      # Frame callbacks come from a wprsd timer (1/framerate - 2 ms after each
      # commit, default 60): Firefox got ~50 fps and dropped a third of a
      # 60 fps video; with 120 about 10-20 % (xmg 2026-10-18, README Known issues)
      # No clipboard sync with dom0, explicit copy/paste via vm-clip
      ExecStart =
        "/run/current-system/sw/bin/wprsd --framerate 120 --selection-sync false"
        + lib.optionalString grants " --xen-grant-socket /run/wprs-grants.sock";
    };
    wantedBy = [ "default.target" ];
  };

  environment.systemPackages = [
    pkgs.wprs
    pkgs.xwayland
    clipboard.helper
    # Real wl-copy/wl-paste against wprsd (nvim, yazi, ...); replaces the old
    # fake that wrote to /tmp/fake-clipboard
    pkgs.wl-clipboard
    # Terminal for `vm-run <vm> foot`, configured like dom0's foot
    pkgs.foot
  ];

  # An old copy of the unit in the home (chat, from before it was a system
  # unit) shadowed this one, without the clipboard isolation (2026-10-16)
  systemd.tmpfiles.rules = [
    "r /home/user/.config/systemd/user/default.target.wants/wprsd.service"
    "r /home/user/.config/systemd/user/wprsd.service"
  ];

  environment.etc."xdg/foot/foot.ini".text = lib.generators.toINI { } theme.foot;

  # The fonts foot.ini names (theme.nix), also in VMs without common-config
  # (steam: foot fell back to DejaVu Sans, not monospace)
  fonts.packages = [
    pkgs.nerd-fonts.fira-code
    (import ../../desktop/symbols-font.nix { inherit pkgs; })
    pkgs.noto-fonts-color-emoji
  ];
}

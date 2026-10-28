# Boot splash: plymouth with the NoX theme (nix/nox-plymouth.nix: the
# wallpaper of nox.desktop.theme, the passphrase field, the boot in short
# form; Esc shows the full messages). Under Xen dom0 also has the Xen console
# hvc0, which plymouth takes for a serial console and then forces its text
# mode (hp 2026-10-27): ignored. The console stays quiet before and after the
# splash, and the splash stays until the display manager takes the screen.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  theme = import ./theme.nix {
    inherit lib;
    inherit (config.nox.desktop) theme;
  };
  t = config.nox.desktop.theme;
  # The same rendering as the desktop's wallpaper (desktop/niri.nix)
  branding = pkgs.callPackage ../../nix/nox-branding.nix {
    colors = theme.graphics;
    inherit (t) resolution;
    wallpaper = { inherit (t) flavor shade decor; };
    lock = { inherit (t.lock) flavor shade decor; };
  };
in
{
  boot = {
    plymouth = {
      theme = lib.mkDefault "nox";
      themePackages = [
        (pkgs.callPackage ../../nix/nox-plymouth.nix {
          inherit branding;
          colors = theme.raw;
        })
      ];
      font = lib.mkDefault "${pkgs.nerd-fonts.fira-code}/share/fonts/truetype/NerdFonts/FiraCode/FiraCodeNerdFont-Regular.ttf";
    };
    kernelParams = [
      "plymouth.ignore-serial-consoles"
      "rd.udev.log_level=3"
      "udev.log_priority=3"
      "vt.global_cursor_default=0"
    ];
    consoleLogLevel = lib.mkDefault 3;
  };

  # Keep the last splash frame until sddm draws (no text console in between)
  systemd.services.plymouth-quit.serviceConfig.ExecStart = [
    ""
    "${config.boot.plymouth.package}/bin/plymouth quit --retain-splash"
  ];
}

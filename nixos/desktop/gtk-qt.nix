# GTK/Qt theme, cursor, default applications and session variables of dom0
# (was home-manager's gtk, qt, dconf, xdg.mimeApps; now /etc and the system
# dconf database). Dark and cursor follow nox.theme.dark / nox.theme.cursor
{
  pkgs,
  lib,
  config,
  ...
}:
let
  theme = import ./theme.nix {
    inherit lib;
    inherit (config.nox.desktop) theme;
  };
  inherit (theme) cursor dark;
  iconTheme = pkgs.tela-circle-icon-theme.override { colorVariants = [ theme.icons.variant ]; };
  gtkTheme = if dark then "adw-gtk3-dark" else "adw-gtk3";
  preferDark = if dark then "1" else "0";
  video = "chromium-browser.desktop";
in
{
  environment = {
    systemPackages = [
      pkgs.adw-gtk3
      iconTheme
      (theme.cursorPackage pkgs)
    ];

    etc = {
      "xdg/gtk-3.0/settings.ini".text = ''
        [Settings]
        gtk-application-prefer-dark-theme=${preferDark}
        gtk-icon-theme-name=${theme.icons.name}
        gtk-theme-name=${gtkTheme}
        gtk-cursor-theme-name=${cursor.name}
        gtk-cursor-theme-size=${toString cursor.size}
      '';
      "xdg/gtk-4.0/settings.ini".text = ''
        [Settings]
        gtk-application-prefer-dark-theme=${preferDark}
        gtk-icon-theme-name=${theme.icons.name}
        gtk-cursor-theme-name=${cursor.name}
        gtk-cursor-theme-size=${toString cursor.size}
      '';
      "gtk-2.0/gtkrc".text = ''
        gtk-icon-theme-name = "${theme.icons.name}"
        gtk-theme-name = "${gtkTheme}"
        gtk-cursor-theme-name = "${cursor.name}"
        gtk-cursor-theme-size = ${toString cursor.size}
      '';
    };

    sessionVariables = {
      GTK2_RC_FILES = "/etc/gtk-2.0/gtkrc";
      QT_QPA_PLATFORMTHEME = "gtk3";
      XCURSOR_THEME = cursor.name;
      XCURSOR_SIZE = toString cursor.size;
      LESSHISTFILE = "/tmp/less-hist";
      PARALLEL_HOME = "$HOME/.config/parallel";

      XDG_DESKTOP_DIR = "$HOME/Desktop";
      XDG_DOCUMENTS_DIR = "$HOME/Documents";
      XDG_DOWNLOAD_DIR = "$HOME/Downloads";
      XDG_MUSIC_DIR = "$HOME/Music";
      XDG_PICTURES_DIR = "$HOME/Pictures";
      XDG_PUBLICSHARE_DIR = "$HOME/Public";
      XDG_TEMPLATES_DIR = "$HOME/Templates";
      XDG_VIDEOS_DIR = "$HOME/Videos";
    };

    # GTK apps started from a shell: Adwaita (dark unless nox.theme.dark is
    # false). Login shells only, as under home-manager: in the session
    # (systemd user units) GTK_THEME overrides swaync's style.css with
    # Adwaita's opaque background
    loginShellInit = ''
      export GTK_THEME=${if dark then "Adwaita:dark" else "Adwaita"}
    '';
  };

  programs.dconf.profiles.user.databases = [
    {
      settings."org/gnome/desktop/interface" = {
        color-scheme = if dark then "prefer-dark" else "default";
        gtk-theme = gtkTheme;
        icon-theme = theme.icons.name;
        cursor-theme = cursor.name;
        cursor-size = lib.gvariant.mkInt32 cursor.size;
      };
    }
  ];

  # /etc/xdg/mimeapps.list
  xdg.mime.defaultApplications = {
    # Images
    "image/png" = "satty.desktop";
    "image/jpeg" = "satty.desktop";
    "image/jpg" = "satty.desktop";
    "image/webp" = "satty.desktop";
    "image/gif" = "satty.desktop";

    # Videos
    "video/mp4" = video;
    "video/webm" = video;
    "video/x-matroska" = video;
    "video/ogg" = video;
    "video/quicktime" = video;
    "video/x-msvideo" = video;
    "video/x-flv" = video;
    "video/x-ms-wmv" = video;
    "video/mpeg" = video;
    "video/3gpp" = video;
    "video/3gpp2" = video;

    # Text: vim (in a terminal)
    "text/plain" = "vim.desktop";
    "text/markdown" = "vim.desktop";
  };

  xdg.portal.xdgOpenUsePortal = true;

}

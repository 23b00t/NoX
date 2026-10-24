# App catalog (nox.apps): known apps with the switches they need under NoX.
# A VM lists an app by its id (`apps.element.tray = true;`) and gets these
# fields; its own fields win one by one. Free software only: unfree apps
# (`unfree = true`) are defined in the user's config (`nox.apps.<id>`), allowed
# by name only and only in an own store image or a store group marked unfree.
{ lib, ... }:
let
  app = lib.mapAttrs (_: lib.mkDefault);
  chat = [
    "Network"
    "InstantMessaging"
    "Chat"
  ];
  browser = [
    "Network"
    "WebBrowser"
  ];
  webMime = [
    "text/html"
    "application/xhtml+xml"
    "application/xml"
    "application/pdf"
    "application/x-xpinstall"
  ];
in
{
  nox.apps = {
    # Chat
    vesktop = app {
      package = "vesktop";
      name = "Vesktop";
      genericName = "Discord Client";
      icon = "discord";
      categories = chat;
      trayArgs = [ "-m" ];
    };
    element = app {
      package = "element-desktop";
      name = "Element";
      genericName = "Element Matrix Client";
      binary = "element-desktop";
      icon = "element-desktop";
      # Tray show/hide needs XWayland under wprs
      x11 = true;
      categories = chat;
      mimeType = [ "x-scheme-handler/web+msteams" ];
      trayArgs = [ "--hidden" ];
    };
    telegram = app {
      package = "telegram-desktop";
      name = "Telegram";
      genericName = "Telegram Desktop";
      binary = "Telegram";
      icon = "telegram";
      categories = chat;
      mimeType = [ "x-scheme-handler/tg" ];
      trayArgs = [ "-startintray" ];
    };

    # Browsers
    firefox = app {
      package = "firefox";
      name = "Firefox";
      genericName = "Web Browser";
      icon = "firefox";
      categories = browser;
      mimeType = webMime;
    };
    # Installed by NoX vms/modules/zen-firefox.nix (the zen-browser flake)
    zen = app {
      name = "Zen";
      genericName = "Web Browser";
      icon = "zen-browser";
      categories = browser;
      mimeType = webMime;
    };
    chromium = app {
      package = "chromium";
      name = "Chromium";
      genericName = "Web Browser";
      icon = "chromium";
      categories = browser;
    };

    # Office and media
    libreoffice = app {
      package = "libreoffice";
      name = "LibreOffice";
      genericName = "LibreOffice Suite";
      icon = "libreoffice";
      categories = [
        "Office"
        "WordProcessor"
        "Spreadsheet"
        "Presentation"
      ];
      mimeType = [
        "application/vnd.oasis.opendocument.text"
        "application/vnd.oasis.opendocument.spreadsheet"
        "application/vnd.oasis.opendocument.presentation"
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        "application/vnd.openxmlformats-officedocument.presentationml.presentation"
      ];
    };
    gimp = app {
      package = "gimp";
      name = "GIMP";
      genericName = "GNU Image Manipulation Program";
      icon = "gimp";
      categories = [
        "Graphics"
        "2DGraphics"
        "RasterGraphics"
      ];
      mimeType = [
        "image/jpeg"
        "image/png"
        "image/tiff"
        "image/webp"
      ];
    };
    inkscape = app {
      package = "inkscape";
      name = "Inkscape";
      genericName = "Vector Graphics Editor";
      # Its own session bus
      binary = "dbus-run-session";
      args = [ "inkscape" ];
      icon = "inkscape";
      categories = [
        "Graphics"
        "VectorGraphics"
      ];
      mimeType = [
        "image/svg+xml"
        "application/pdf"
      ];
    };
    vlc = app {
      package = "vlc";
      name = "VLC";
      genericName = "Media Player";
      icon = "vlc";
      categories = [
        "AudioVideo"
        "Player"
        "Recorder"
      ];
    };
    pinta = app {
      package = "pinta";
      name = "Pinta";
      genericName = "Image Editor";
      icon = "pinta";
      categories = [
        "Graphics"
        "2DGraphics"
      ];
    };
    pdfarranger = app {
      package = "pdfarranger";
      name = "PDF Arranger";
      genericName = "PDF Arranger";
      icon = "pdfarranger";
      categories = [ "Office" ];
      mimeType = [ "application/pdf" ];
    };

    # Passwords
    keepassxc = app {
      package = "keepassxc";
      name = "KeePassXC";
      genericName = "Password Manager";
      icon = "keepassxc";
      categories = [ "Utility" ];
      mimeType = [
        "application/x-keepass2"
        "application/x-keepass"
      ];
    };

    # Development
    dbeaver = app {
      package = "dbeaver-bin";
      name = "DBeaver";
      genericName = "Database Manager";
      icon = "dbeaver";
      categories = [
        "Development"
        "Database"
      ];
    };

    # Windows
    bottles = app {
      name = "Bottles";
      genericName = "Windows Apps";
      icon = "com.usebottles.bottles";
      categories = [ "Utility" ];
    };

    # Driver domains
    nm-applet = app {
      package = "networkmanagerapplet";
      name = "Network";
      trayArgs = [ "--indicator" ];
      menu = false;
    };
  };
}

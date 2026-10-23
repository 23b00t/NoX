# App catalog (nox.apps): known apps with the switches they need under NoX.
# A VM lists an app by its id (`apps.element.tray = true;`) and gets these
# fields; its own fields win one by one. `unfree` apps are allowed by name
# only and only in an own store image or a store group marked unfree.
{ lib, ... }:
let
  app = lib.mapAttrs (_: lib.mkDefault);
in
{
  nox.apps = {
    # Chat
    vesktop = app {
      package = "vesktop";
      name = "Vesktop";
      genericName = "Discord Client";
      icon = "discord";
      categories = [
        "Network"
        "InstantMessaging"
        "Chat"
      ];
      trayArgs = [ "-m" ];
    };
    element = app {
      package = "element-desktop";
      name = "Element";
      genericName = "Element Matrix Client";
      binary = "element-desktop";
      icon = "element-desktop";
      x11 = true;
      categories = [
        "Network"
        "InstantMessaging"
        "Chat"
      ];
      trayArgs = [ "--hidden" ];
    };
    telegram = app {
      package = "telegram-desktop";
      name = "Telegram";
      genericName = "Telegram Desktop";
      binary = "Telegram";
      icon = "telegram";
      categories = [
        "Network"
        "InstantMessaging"
        "Chat"
      ];
      mimeType = [ "x-scheme-handler/tg" ];
      trayArgs = [ "-startintray" ];
    };
    slack = app {
      package = "slack";
      name = "Slack";
      icon = "slack";
      categories = [
        "Network"
        "InstantMessaging"
        "Chat"
      ];
      mimeType = [ "x-scheme-handler/slack" ];
      unfree = true;
    };

    # Browsers
    firefox = app {
      package = "firefox";
      name = "Firefox";
      genericName = "Web Browser";
      icon = "firefox";
      categories = [
        "Network"
        "WebBrowser"
      ];
      mimeType = [
        "text/html"
        "x-scheme-handler/http"
        "x-scheme-handler/https"
      ];
    };
    chromium = app {
      package = "chromium";
      name = "Chromium";
      genericName = "Web Browser";
      icon = "chromium";
      categories = [
        "Network"
        "WebBrowser"
      ];
    };
    chrome = app {
      package = "google-chrome";
      name = "Chrome";
      genericName = "Web Browser";
      binary = "google-chrome-stable";
      icon = "google-chrome";
      categories = [
        "Network"
        "WebBrowser"
      ];
      unfree = true;
    };

    # Office and media
    libreoffice = app {
      package = "libreoffice";
      name = "LibreOffice";
      genericName = "LibreOffice Suite";
      icon = "libreoffice";
      categories = [ "Office" ];
    };
    gimp = app {
      package = "gimp";
      name = "GIMP";
      genericName = "GNU Image Manipulation Program";
      icon = "gimp";
      categories = [ "Graphics" ];
    };
    inkscape = app {
      package = "inkscape";
      name = "Inkscape";
      genericName = "Vector Graphics Editor";
      # Its own session bus: without one it hangs at start under wprs
      binary = "dbus-run-session";
      args = [ "inkscape" ];
      icon = "inkscape";
      categories = [ "Graphics" ];
    };
    vlc = app {
      package = "vlc";
      name = "VLC";
      genericName = "Media Player";
      icon = "vlc";
      categories = [
        "AudioVideo"
        "Player"
      ];
    };
    pinta = app {
      package = "pinta";
      name = "Pinta";
      genericName = "Image Editor";
      icon = "pinta";
      categories = [ "Graphics" ];
    };
    pdfarranger = app {
      package = "pdfarranger";
      name = "PDF Arranger";
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
      mimeType = [ "application/x-keepass2" ];
    };

    # Development
    postman = app {
      package = "postman";
      name = "Postman";
      genericName = "API Client";
      icon = "postman";
      categories = [ "Development" ];
      unfree = true;
    };
    dbeaver = app {
      package = "dbeaver-bin";
      name = "DBeaver";
      genericName = "Database Manager";
      icon = "dbeaver";
      categories = [ "Development" ];
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
    };
  };
}

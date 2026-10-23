{
  lib,
  osConfig ? { },
  vmRegistry,
  ...
}:
let
  # VMs and image domains of this machine (registry `hosts`)
  domains = vmRegistry.vms ++ vmRegistry.imageDomains;
  onHost = vm: builtins.any (d: d.name == vm) domains;

  # Helper für Desktop-Entries: VM-Name aus registry.nix, Anzeige "App (vm)";
  # Einträge für VMs, die auf dieser Maschine nicht laufen, entfallen
  mkVmEntry =
    {
      name,
      vm,
      binary,
      genericName ? name,
      categories ? [ ],
      mimeType ? [ ],
      icon ? null,
      args ? "",
    }:
    lib.optionalAttrs (onHost vm) {
      "nox-${vm}-${lib.toLower (lib.strings.sanitizeDerivationName name)}" = {
        name = "${name} (${vm})";
        inherit
          genericName
          categories
          mimeType
          icon
          ;
        exec = if args == "" then "vm-run ${vm} ${binary} %U" else "vm-run ${vm} ${binary} ${args} %U";
        terminal = false;
        type = "Application";
      };
    };

  # One terminal per domain with a GUI over wprs: foot in the NixOS VMs
  # (wprsd, vms/modules/wprs.nix), the image's default terminal in the
  # Debian image domains (`wprs = true`), foot from the store disk where the
  # image has none (`foot = true`, Whonix-Gateway)
  terminalOf =
    vm:
    if (osConfig.microvm.vms.${vm.name}.config.config.systemd.user.services or { }) ? wprsd then
      "foot"
    else if osConfig.services.xen-image-domains.domains.${vm.name}.foot or false then
      "/nix/store/nox/bin/foot"
    else if osConfig.services.xen-image-domains.domains.${vm.name}.wprs or false then
      "x-terminal-emulator"
    else
      null;
  terminalEntries = map (
    vm:
    lib.optionalAttrs (terminalOf vm != null) {
      "nox-${vm.name}-terminal" = {
        name = "Terminal (${vm.name})";
        genericName = "Terminal";
        exec = "vm-run ${vm.name} ${terminalOf vm}";
        icon = "utilities-terminal";
        categories = [
          "System"
          "TerminalEmulator"
        ];
        terminal = false;
        type = "Application";
      };
    }
  ) domains;

  # dom0 runs no foot server: hide foot's client and server entries
  hidden = name: {
    inherit name;
    exec = "false";
    noDisplay = true;
  };
in
{
  xdg.desktopEntries = lib.mkMerge (
    terminalEntries
    ++ [
      {
        footclient = hidden "Foot Client";
        foot-server = hidden "Foot Server";
      }
      # --- Chat VM ---
      (mkVmEntry {
        name = "Vesktop";
        genericName = "Discord Client";
        vm = "chat";
        binary = "vesktop";
        icon = "discord";
        categories = [
          "Network"
          "InstantMessaging"
          "Chat"
        ];
      })

      (mkVmEntry {
        name = "Telegram";
        genericName = "Telegram Desktop";
        vm = "chat";
        binary = "Telegram";
        icon = "telegram";
        categories = [
          "Network"
          "InstantMessaging"
          "Chat"
        ];
        mimeType = [ "x-scheme-handler/tg" ];
      })

      (mkVmEntry {
        name = "Slack";
        genericName = "Slack";
        vm = "chat";
        binary = "slack";
        icon = "slack";
        categories = [
          "Network"
          "InstantMessaging"
          "Chat"
        ];
        mimeType = [ "x-scheme-handler/slack" ];
      })

      (mkVmEntry {
        name = "Chrome";
        genericName = "Web Browser";
        vm = "chat";
        binary = "google-chrome-stable";
        icon = "google-chrome";
        categories = [
          "Network"
          "WebBrowser"
        ];
      })

      (mkVmEntry {
        name = "Element";
        genericName = "Element Matrix Client";
        vm = "chat";
        binary = "element-desktop";
        # Tray show/hide needs XWayland under wprs (see niri.nix)
        args = "--ozone-platform=x11";
        icon = "element-desktop";
        categories = [
          "Network"
          "InstantMessaging"
          "Chat"
        ];
        mimeType = [ "x-scheme-handler/web+msteams" ];
      })

      # --- Office VM ---
      (mkVmEntry {
        name = "GIMP";
        genericName = "GNU Image Manipulation Program";
        vm = "office";
        binary = "gimp";
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
      })

      (mkVmEntry {
        name = "LibreOffice";
        genericName = "LibreOffice Suite";
        vm = "office";
        binary = "libreoffice";
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
      })

      (mkVmEntry {
        name = "Inkscape";
        genericName = "Vector Graphics Editor";
        vm = "office";
        binary = "dbus-run-session";
        args = "inkscape";
        icon = "inkscape";
        categories = [
          "Graphics"
          "VectorGraphics"
        ];
        mimeType = [
          "image/svg+xml"
          "application/pdf"
        ];
      })

      (mkVmEntry {
        name = "VLC";
        genericName = "Media Player";
        vm = "office";
        binary = "vlc";
        icon = "vlc";
        categories = [
          "AudioVideo"
          "Player"
          "Recorder"
        ];
      })

      (mkVmEntry {
        name = "Pinta";
        genericName = "Image Editor";
        vm = "office";
        binary = "pinta";
        icon = "pinta";
        categories = [
          "Graphics"
          "2DGraphics"
        ];
      })

      (mkVmEntry {
        name = "PDF Arranger";
        genericName = "PDF Arranger";
        vm = "office";
        binary = "pdfarranger";
        icon = "pdfarranger";
        categories = [ "Office" ];
        mimeType = [ "application/pdf" ];
      })

      # --- Net VM ---
      (mkVmEntry {
        name = "Firefox";
        genericName = "Web Browser";
        vm = "net";
        binary = "firefox";
        icon = "firefox";
        categories = [
          "Network"
          "WebBrowser"
        ];
        mimeType = [
          "text/html"
          "application/xhtml+xml"
          "application/xml"
          "application/pdf"
          "application/x-xpinstall"
        ];
      })

      (mkVmEntry {
        name = "Zen";
        genericName = "Web Browser";
        vm = "net";
        binary = "zen";
        icon = "zen-browser";
        categories = [
          "Network"
          "WebBrowser"
        ];
        mimeType = [
          "text/html"
          "application/xhtml+xml"
          "application/xml"
          "application/pdf"
          "application/x-xpinstall"
        ];
      })

      # ---- Vault VM ---
      (mkVmEntry {
        name = "KeePassXC";
        genericName = "Password Manager";
        vm = "vault";
        binary = "keepassxc";
        icon = "keepassxc";
        categories = [
          "Utility"
        ];
        mimeType = [
          "application/x-keepass2"
          "application/x-keepass"
        ];
      })

      # ---- Coding VM ---
      (mkVmEntry {
        name = "Postman";
        genericName = "API Client";
        vm = "coding";
        binary = "postman";
        icon = "postman";
        categories = [
          "Development"
          "Utility"
        ];
      })

      (mkVmEntry {
        name = "DBeaver";
        genericName = "Database Manager";
        vm = "coding";
        binary = "dbeaver";
        icon = "dbeaver";
        categories = [
          "Development"
          "Database"
        ];
      })

      (mkVmEntry {
        name = "Firefox";
        genericName = "Web Browser";
        vm = "coding";
        binary = "firefox";
        icon = "firefox";
        categories = [
          "Network"
          "WebBrowser"
        ];
        mimeType = [
          "text/html"
          "application/xhtml+xml"
          "application/xml"
          "application/pdf"
          "application/x-xpinstall"
        ];
      })

      # --- win VM (Windows apps) ---
      (mkVmEntry {
        name = "Bottles";
        genericName = "Windows Apps";
        vm = "win";
        binary = "bottles";
        icon = "com.usebottles.bottles";
        categories = [ "Utility" ];
      })

      # --- PHP VM: browsers for testing (no MIME types: dom0's defaults stay) ---
      (mkVmEntry {
        name = "Firefox";
        genericName = "Web Browser";
        vm = "php";
        binary = "firefox";
        icon = "firefox";
        categories = [
          "Network"
          "WebBrowser"
        ];
      })

      (mkVmEntry {
        name = "Chromium";
        genericName = "Web Browser";
        vm = "php";
        binary = "chromium";
        icon = "chromium";
        categories = [
          "Network"
          "WebBrowser"
        ];
      })

      # --- Kali (image domain, wprs over vchan) ---
      (mkVmEntry {
        name = "Burp Suite";
        genericName = "Web Security Testing";
        vm = "kali";
        binary = "burpsuite";
        icon = "kali-burpsuite";
        categories = [
          "Network"
          "Security"
        ];
      })

      (mkVmEntry {
        name = "Firefox";
        genericName = "Web Browser";
        vm = "kali";
        binary = "firefox-esr";
        icon = "firefox";
        categories = [
          "Network"
          "WebBrowser"
        ];
      })

      # --- Whonix-Workstation (image domain, wprs over vchan) ---
      (mkVmEntry {
        name = "Tor Browser";
        genericName = "Web Browser";
        vm = "whonix-workstation";
        binary = "torbrowser";
        icon = "web-browser";
        categories = [
          "Network"
          "WebBrowser"
        ];
      })
    ]
  );
}

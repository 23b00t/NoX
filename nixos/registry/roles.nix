# NoX's roles (nox.roles) and store groups (nox.storeGroups). A role is the
# kind of work in a VM: its NixOS module (../roles/<name>.nix, free software
# only) and defaults for the VM's fields. Trust (`label`), network (`uplink`,
# `egress`) and hardware are never part of a role. Everything here is a
# default: change a role's defaults or add roles in the user's config like
# any module option.
{ lib, ... }:
let
  role = description: module: defaults: {
    description = lib.mkDefault description;
    inherit module;
    defaults = lib.mapAttrsRecursive (_: lib.mkDefault) defaults;
  };
in
{
  nox.roles = {
    minimal =
      role "Base system only; software comes in imperatively or from the VM's module."
        ../roles/minimal.nix
        {
          memory = 1024;
          memoryMax = 2048;
          home.size = 4096;
        };
    terminal = role "Text-mode work in zellij." ../roles/terminal.nix {
      memory = 1024;
      home.size = 1024;
      storeGroup = "desktop";
    };
    dev = role "Software development: editor, language tooling, zsh, zellij, yazi." ../roles/dev.nix {
      memory = 2048;
      memoryMax = 8192;
      vcpu = 2;
      home.size = 20000;
      storeGroup = "dev";
      githubAgent = true;
      explorer = true;
    };
    desktop = role "GUI apps over wprs with a file manager." ../roles/desktop.nix {
      memory = 2048;
      memoryMax = 4096;
      vcpu = 2;
      home.size = 10000;
      storeGroup = "desktop";
      explorer = true;
    };
    browser = role "Browsing." ../roles/browser.nix {
      memory = 2048;
      memoryMax = 6144;
      vcpu = 4;
      home.size = 10000;
      storeGroup = "desktop";
      explorer = true;
    };
    windows = role "Windows programs under wine (Bottles)." ../roles/windows.nix {
      memory = 2048;
      memoryMax = 6144;
      vcpu = 4;
      home.size = 40000;
      dbus = false;
    };
    gaming = role "Games with the GPU passed through." ../roles/gaming.nix {
      memory = 16384;
      vcpu = 8;
      home.size = 200000;
      gpu = true;
      backup = false;
      dbus = false;
    };
  };

  nox.storeGroups = {
    sys.description = lib.mkDefault "Driver domains and infrastructure (NoX).";
    dev.description = lib.mkDefault "Development tools from nixpkgs.";
    desktop.description = lib.mkDefault "Free desktop apps from nixpkgs.";
    prop = {
      description = lib.mkDefault "Proprietary apps.";
      unfree = lib.mkDefault true;
    };
  };
}

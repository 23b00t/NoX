# The VM schema (NoX modules step 3): `nox.vms.<name>` for NixOS guests,
# `nox.images.<name>` for image domains (Whonix, Kali), `nox.roles` (what
# kind of work a VM does, roles.nix), `nox.apps` (the app catalog, apps.nix)
# and `nox.storeGroups`. Evaluated with lib.evalModules on its own (not
# inside a NixOS system), with `host` (the machine) as special argument, so
# the same definitions serve dom0 and the standalone VM outputs. `legacy.nix`
# turns the result into the registry the modules read today (vmRegistry),
# `definitions.nix` builds the NixOS modules of the VMs that have a role.
#
# Optional fields are null by default: null means NoX's default, which the
# modules apply (given in each description). A VM's role sets defaults for
# its fields (mkDefault), so everything written in vms.nix wins.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  roles = config.nox.roles;

  copyType = types.submodule {
    options = {
      incoming = mkOption {
        type = types.nullOr (
          types.enum [
            "ask"
            "warn"
            "deny"
          ]
        );
        default = null;
        description = "Files into the VM: ask, warn (ask, the user types the VM's name) or deny. Default: ask.";
      };
      outgoing = mkOption {
        type = types.nullOr (
          types.enum [
            "ask"
            "warn"
            "deny"
          ]
        );
        default = null;
        description = "Files out of the VM. Default: deny for sys-* VMs, else ask.";
      };
    };
  };

  # An app in a VM, and the same fields for an entry of the catalog
  # (nox.apps): the VM's entry overrides the catalog's field by field. Only
  # strings and lists, no packages: the registry stays plain data, the VM
  # resolves `package` against its own pkgs.
  appOptions = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Install the app and derive its desktop entry, waybar icon and tray start.";
    };
    package = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "element-desktop";
      description = "Attribute path in the VM's pkgs; null: the VM's own module installs it.";
    };
    install = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Install `package`; false: the VM's own module installs the app (a wrapped build, `programs.firefox`). Default: true.";
    };
    name = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Display name of the desktop entry (\"<name> (<vm>)\"). Default: the app id.";
    };
    genericName = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Generic name of the desktop entry.";
    };
    binary = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Command run in the VM. Default: the app id.";
    };
    args = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = "Arguments for every start (desktop entry and tray).";
    };
    x11 = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Electron app over XWayland (`--ozone-platform=x11`): a Wayland Electron window hidden to the tray can't come back under wprs. Default: false.";
    };
    menu = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Desktop entry in dom0's app menu; false for apps that only run in the tray (nm-applet). Default: true.";
    };
    tray = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Start into the tray with the session and after the VM (re)starts (vm-tray). Default: false.";
    };
    trayArgs = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      example = [ "--hidden" ];
      description = "Extra arguments for the tray start.";
    };
    icon = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Icon name (desktop entry, waybar).";
    };
    categories = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = "Desktop entry categories.";
    };
    mimeType = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = "MIME types the desktop entry opens.";
    };
    unfree = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Package is unfree: allowed in this VM by name only, and only in an own store image or a store group marked `unfree`. Default: false.";
    };
  };
  appType = types.submodule { options = appOptions; };

  # Fields VMs and image domains share
  common = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether this machine runs the domain (the definition is kept either way).";
    };
    index = mkOption {
      type = types.ints.between 1 254;
      description = "Last octet of the domain's addresses (admin net, uplink, USB/IP link), its tap and MAC.";
    };
    short = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Short alias for the command line tools.";
    };
    label = mkOption {
      type = types.nullOr (
        types.enum [
          "sys"
          "dev"
          "personal"
          "social"
          "untrusted"
          "vault"
          "anon"
        ]
      );
      default = null;
      description = "Trust label: the window border color in dom0. Default: untrusted.";
    };
  };

  vmOptions = common // {
    role = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "dev";
      description = "Kind of work in the VM (nox.roles): its base software and the defaults of the fields below. null: no role, the VM's module comes from the user's own definitions.";
    };
    # Not `config`: a submodule definition with a `config` key would be read
    # as a module of its own
    module = mkOption {
      type = types.nullOr types.deferredModule;
      default = null;
      example = lib.literalExpression "./vms/php.nix";
      description = "NixOS module with what is the VM's own (packages, files, services), on top of its role.";
    };
    apps = mkOption {
      type = types.attrsOf appType;
      default = { };
      example = lib.literalExpression "{ element.tray = true; vesktop.enable = false; }";
      description = "Apps of the VM; an id from the catalog (nox.apps) takes its fields from there.";
    };
    memory = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "RAM at boot in MB.";
    };
    memoryMax = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "RAM the balancer may grow the VM to, in MB; null: fixed at `memory`.";
    };
    vcpu = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Virtual CPUs. Default: 1.";
    };
    home.size = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Size of the /home/user volume in MB.";
    };
    home.image = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/var/lib/microvms/godot/home.img";
      description = "Image of the /home/user volume; null: home.img in the VM's state directory. An absolute path shares another VM's home (two starts of one VM that never run together; set `backup = false` on the second).";
    };
    gpu = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Passes the machine's GPU (hardware config) through to the VM. Default: false.";
    };
    bluetooth = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "bluez in the VM (adapter over USB/IP from sys-usb). Default: false.";
    };
    autostart = mkOption {
      type = types.bool;
      default = false;
      description = "Start with dom0.";
    };
    uplink = mkOption {
      type = types.nullOr types.str;
      default = "sys-firewall";
      description = "Driver domain that serves the VM's uplink (sys-firewall, sys-vpn, sys-net); null: offline.";
    };
    egress = mkOption {
      type = types.nullOr (
        types.listOf (
          types.submodule {
            options = {
              to = mkOption {
                type = types.str;
                description = "Destination net (CIDR).";
              };
              ports = mkOption {
                type = types.listOf types.port;
                default = [ ];
                description = "Ports; empty: all ports to that net.";
              };
            };
          }
        )
      );
      default = null;
      description = "Outgoing traffic the VM may send through sys-firewall; null: everything. DNS always through sys-firewall's resolver.";
    };
    disposable = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Boots empty every time (home and store overlay images are deleted before start and after stop). Default: false.";
    };
    memPriority = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "RAM balancer priority (higher grows first). Default: 0.";
    };
    storeGroup = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Shared read-only store image (nox.storeGroups); null: an image of its own.";
    };
    clipboard = mkOption {
      type = types.nullOr (
        types.enum [
          "allow"
          "ask"
          "deny"
        ]
      );
      default = null;
      description = "Copy/paste through dom0 (vm-clip): allow, ask (pasting in is free, copying out asks) or deny. Default: deny for sys-* VMs, else allow.";
    };
    copy = mkOption {
      type = types.nullOr copyType;
      default = null;
      description = "Files between domains over nox-rpc (vm-copy, nox copy).";
    };
    backup = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "/home in the home backup (nox backup --all). Default: true except sys-* VMs and disposables.";
    };
    dbus = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Filtered session bus to dom0 (notifications, tray). Default: true.";
    };
    githubAgent = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "dom0's GitHub-only SSH agent in the VM. Default: false.";
    };
    labTarget = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "kali may test this VM's apps over the lab bridge (vm-lab attach). Default: false.";
    };
    explorer = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "The VM has yazi (roles dev, desktop, browser): `explorer` in dom0 offers it. Default: false.";
    };
    hostSSHKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      internal = true;
      description = "Public key dom0 logs in with over SSH; only the builder (dom0-update).";
    };
  };

  # A VM: its options plus the defaults of its role (mkDefault, so what
  # vms.nix sets wins). The attribute names of `config` must not depend on
  # the role (that would be an infinite recursion through `config.role`):
  # every defaultable field is listed, each with an mkIf.
  defaultable = lib.attrNames (
    removeAttrs vmOptions [
      "enable"
      "index"
      "role"
      "module"
      "apps"
      "home"
    ]
  );
  vmType = types.submodule (
    { config, name, ... }:
    let
      defaults =
        if config.role == null then
          { }
        else if roles ? ${config.role} then
          roles.${config.role}.defaults
        else
          throw "nox.vms.${name}: unknown role `${config.role}` (nox.roles: ${lib.concatStringsSep ", " (lib.attrNames roles)})";
      fromRole = field: lib.mkIf (defaults ? ${field}) (lib.mkDefault defaults.${field});
    in
    {
      options = vmOptions;
      config = lib.genAttrs defaultable fromRole // {
        home.size = lib.mkIf (defaults ? home.size) (lib.mkDefault defaults.home.size);
      };
    }
  );
in
{
  imports = [
    ./roles.nix
    ./apps.nix
    ./infra.nix
  ];

  options.nox = {
    vms = mkOption {
      type = types.attrsOf vmType;
      default = { };
      description = "NixOS guests (microvm.nix on Xen).";
    };
    images = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = common // {
            inherit (vmOptions) apps;
          };
        }
      );
      default = { };
      description = "Image domains (upstream disk images: Whonix, Kali); manual steps in the docs. Their `apps` only give dom0's desktop entries (`package` and `install` are not used, the image brings the software).";
    };
    theme = mkOption {
      type = import ../desktop/theme-type.nix { inherit lib; };
      default = { };
      example = lib.literalExpression ''{ name = "tokyo-night"; flavor = "neon"; }'';
      description = "Desktop theme of the whole fleet: dom0's desktop (nox.desktop.theme takes it as its default) and every VM (foot over wprs, the own niri of e.g. godot-gpu). Set it here, not per machine, so the VMs follow dom0; options in nox.desktop.theme.";
    };
    vmModule = mkOption {
      type = types.deferredModule;
      default = { };
      example = lib.literalExpression "{ time.timeZone = \"Europe/Berlin\"; }";
      description = "NixOS module of every NoX VM (role and infrastructure VMs, not image domains): settings for the whole fleet such as time zone and locale.";
    };
    roles = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            description = mkOption {
              type = types.str;
              default = "";
              description = "What kind of work the role is for.";
            };
            module = mkOption {
              type = types.deferredModule;
              default = { };
              description = "NixOS module of the role in the VM: the NoX building blocks its kind of work needs. Free software only; apps come from the VM.";
            };
            defaults = mkOption {
              type = types.attrsOf types.anything;
              default = { };
              example = {
                memory = 2048;
                home.size = 10000;
              };
              description = "Defaults for the fields of the VMs with this role.";
            };
          };
        }
      );
      default = { };
      description = "Roles a VM can have (`nox.vms.<name>.role`); NoX brings minimal, terminal, dev, desktop, browser, windows and gaming, more can be added or extended like any module.";
    };
    apps = mkOption {
      type = types.attrsOf appType;
      default = { };
      description = "App catalog: known apps with the right switches; a VM's `apps.<id>` takes these fields and overrides single ones.";
    };
    storeGroups = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            description = mkOption {
              type = types.str;
              default = "";
              description = "Where the group's software comes from.";
            };
            unfree = mkOption {
              type = types.bool;
              default = false;
              description = "Members may bring unfree packages; in any other group the VM's build fails on one.";
            };
          };
        }
      );
      default = { };
      description = "Shared read-only store images (`storeGroup` of a VM): trust in the software, not in the VM.";
    };
    network.adminPrefix = mkOption {
      type = types.str;
      default = "10.0.0";
      description = "First three octets of the admin net (dom0 .254, sys-net .253); a domain's address is <prefix>.<index>.";
    };
  };
}

# Desktop of dom0: the compositor (nox.desktop.compositor, niri by default),
# waybar, rofi, swaync, wpaperd, swaylock, foot, GTK/Qt theme. Every config
# file lives in /etc (niri: /etc/niri/config.kdl, the rest under /etc/xdg).
{
  config,
  lib,
  pkgs,
  vmRegistry,
  ...
}:
let
  cfg = config.nox.desktop;
  theme = import ./theme.nix {
    inherit lib;
    inherit (cfg) theme;
  };

  # niri's settings: attrs → KDL (home-manager's wayland.windowManager.niri
  # conventions: `_args`, `_props`, `_children`)
  kdlValue =
    with lib.types;
    nullOr (oneOf [
      bool
      int
      float
      str
      (attrsOf kdlValue)
      (listOf kdlValue)
    ])
    // {
      description = "KDL value";
    };

  json = pkgs.formats.json { };
  toml = pkgs.formats.toml { };
  swayncConfig = json.generate "config.json" cfg.swaync.settings;
  swayncStyle = pkgs.writeText "swaync-style.css" cfg.swaync.style;
  wpaperdConfig = toml.generate "wpaperd-wallpaper" cfg.wpaperd.settings;
  swaylockConfig = pkgs.writeText "swaylock-config" (
    lib.concatStrings (
      lib.mapAttrsToList (
        n: v:
        if v == false then
          ""
        else
          (if v == true then n else n + "=" + (if builtins.isPath v then "${v}" else toString v)) + "\n"
      ) cfg.swaylock.settings
    )
  );

  # Session services as home-manager had them (graphical-session.target)
  sessionService = {
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    unitConfig.ConditionEnvironment = "WAYLAND_DISPLAY";
  };
in
{
  imports = [
    ./session.nix
    ./niri.nix
    ./waybar.nix
    ./rofi.nix
    ./gtk-qt.nix
    ./foot.nix
    ./plymouth.nix
  ];

  options.nox.desktop = {
    compositor = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "niri" ]);
      default = "niri";
      description = "Compositor of dom0's desktop. `null`: none from NoX; bring your own (session, keybinds, window rules), see docs/compositor.md. Waybar, rofi, swaync, wpaperd, swaylock, foot and the GTK/Qt theme stay.";
    };
    # Compositor hooks: shell snippets behind `nox-wm <command>`
    # (desktop/session.nix), used by vm-clip, close-guard, screenrec-full,
    # vm-autostart and nox doctor. The compositor module sets them
    # (desktop/niri.nix); with nox.desktop.compositor = null the own config
    # writes them. Unset: the command fails, the tools fall back or refuse.
    wm =
      lib.mapAttrs
        (
          _: description:
          lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            inherit description;
          }
        )
        {
          focusedWindow = "`nox-wm focused-window`: print the focused window as `<id>\t<pid>\t<app id>` (empty fields allowed), nothing if none. Unset: vm-clip refuses, close-guard does nothing.";
          windows = "`nox-wm windows`: print the app id of every open window, one per line. Unset: vm-autostart starts the login windows without checking for open ones.";
          closeWindow = "`nox-wm close-window <id>`: close the window with that id (from focused-window).";
          focusedOutput = "`nox-wm focused-output`: print the name of the focused output (screenrec-full).";
          openTerminals = "`nox-wm open-terminals <tab>…`: open the login terminals (nox.desktop.login.terminalTabs; `dom0` or a VM name, app ids `term-dom0` and `[<vm>] term-<vm>`). Unset: vm-autostart leaves them out.";
        };

    # The user's windows at login (vm-autostart, at session start and from
    # manage-vms after a VM's (re)start)
    login = {
      terminalTabs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "dom0"
          "nvim"
          "coding"
        ];
        description = "Terminals as tabs of one column at login, in this order: `dom0` (foot) or a VM (its foot with zellij).";
      };
      dom0Command = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "zellij"
          "--layout"
          "tabs"
        ];
        description = "Command in dom0's terminal tab (empty: the shell).";
      };
      windows = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              vm = lib.mkOption {
                type = lib.types.str;
                description = "VM the window runs in.";
              };
              command = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                description = "Command in the VM (vm-run).";
              };
              appId = lib.mkOption {
                type = lib.types.str;
                description = "Extended regex on the window's app id without the \"[<vm>] \" prefix: an open window that matches is not started again.";
              };
            };
          }
        );
        default = [ ];
        description = "Further windows at login.";
      };
    };
    theme = lib.mkOption {
      type = import ./theme-type.nix { inherit lib; };
      # The fleet's theme (registry nox.theme), which the VMs follow too
      default = vmRegistry.theme;
      defaultText = lib.literalExpression "nox.theme (vms.nix)";
      example = lib.literalExpression ''
        {
          name = "tokyo-night";
          flavor = "neon";
          decor = [ "stars" ];
          lock.shade = "normal";
        }
      '';
      description = "Desktop theme of dom0: colors, fonts and radii for niri, waybar, rofi, swaync, swaylock, foot and GTK/Qt, and the generated wallpaper and lock screen (nix/nox-branding.nix). Defaults to the fleet's `nox.theme` (vms.nix); set that one, so the VMs follow (a different value here only changes dom0 and warns). Single values stay overridable through the modules' options (e.g. nox.desktop.niri.settings, nox.desktop.wpaperd.settings).";
    };
    keyboard =
      lib.mapAttrs
        (
          name: default:
          lib.mkOption {
            type = lib.types.str;
            inherit default;
            description = "xkb ${name} of the compositor's keyboard (empty: not set). The niri module applies it; an own compositor reads it from here.";
          }
        )
        {
          layout = "us";
          variant = "";
          options = "";
        };
    # Trust label per VM (registry `label`, absent = untrusted) as window
    # colors on the "[<vm>] " app id prefix that dom0's wprsc sets
    # (`--app-id-prefix`, dom0/tools/vm-gui.nix, vm-run; "[<vm>]" alone for
    # windows without an app id). A VM cannot fake it: its own app id only
    # follows the prefix. dom0's color only for app ids that don't start
    # with "["; windows matching neither (a dom0 window without an app id)
    # keep the compositor's default
    labels = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.str);
      readOnly = true;
      default =
        map
          (
            l:
            l
            // {
              active = theme.label.${l.label};
              inactiveBorder = theme.labelWithAlpha l.label theme.opacity.inactiveBorder;
              inactiveRing = theme.labelWithAlpha l.label theme.opacity.inactiveRing;
            }
          )
          (
            [
              {
                label = "dom0";
                appId = "^[^\\[]";
              }
            ]
            ++ lib.mapAttrsToList (label: vms: {
              inherit label;
              appId = "^\\[(${lib.concatMapStringsSep "|" (vm: vm.name) vms})\\]( |$)";
            }) (lib.groupBy (vm: vm.label or "untrusted") (vmRegistry.vms ++ vmRegistry.imageDomains))
          );
      defaultText = lib.literalMD "one entry per trust label in use, from the registry and the theme";
      description = "Window colors per trust label, for the window rules of the compositor (desktop/niri.nix uses them; with nox.desktop.compositor = null the own config applies them). Each entry: `label`, `appId` (extended regex on the app id), `active` (#rrggbb: border and focus ring of the focused window), `inactiveBorder` and `inactiveRing` (#rrggbbaa).";
    };
    waybar.workspaces = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            module = lib.mkOption {
              type = lib.types.str;
              description = "waybar's workspaces module, e.g. `hyprland/workspaces`.";
            };
            settings = lib.mkOption {
              type = (pkgs.formats.json { }).type;
              default = { };
              description = "The module's waybar settings.";
            };
          };
        }
      );
      default =
        if cfg.compositor == "niri" then
          {
            module = "niri/workspaces";
            settings.format = "{index}";
          }
        else
          null;
      defaultText = lib.literalExpression ''
        niri: { module = "niri/workspaces"; settings.format = "{index}"; }, otherwise null
      '';
      description = "Workspaces on the left of waybar (null: none).";
    };
    niri.settings = lib.mkOption {
      type = lib.types.attrsOf kdlValue;
      default = { };
      description = "niri's config as Nix attrs (home-manager's wayland.windowManager.niri.settings format), written to /etc/niri/config.kdl and validated at build time.";
    };
    swaync = {
      enable = lib.mkEnableOption "swaync notifications";
      settings = lib.mkOption {
        inherit (json) type;
        default = { };
        description = "swaync's config.json.";
      };
      style = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "swaync's style.css.";
      };
    };
    wpaperd = {
      enable = lib.mkEnableOption "wpaperd wallpapers";
      settings = lib.mkOption {
        inherit (toml) type;
        default = { };
        description = "wpaperd's config (per output: path, …).";
      };
    };
    swaylock = {
      enable = lib.mkEnableOption "swaylock (Mod+Alt+L)";
      image = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Own lock screen image instead of the rendered one (nox-branding). With it the ring is the plain one (shown while typing, filled) instead of the logo's neon o.";
      };
      settings = lib.mkOption {
        type =
          with lib.types;
          attrsOf (oneOf [
            bool
            float
            int
            path
            str
          ]);
        default = { };
        description = "swaylock's config (`-C /etc/xdg/swaylock/config`).";
      };
    };
  };

  config = lib.mkMerge [
    {
      # The VMs only see nox.theme (registry): a different dom0 theme splits
      # the look. Without NoX's compositor: what is left to do
      # (docs/compositor.md)
      warnings =
        lib.optional (cfg.theme != vmRegistry.theme)
          "nox.desktop.theme differs from nox.theme (vms.nix): the VMs keep nox.theme. Set the theme in vms.nix to change both."
        ++ lib.optionals (cfg.compositor == null) (
          let
            unset = lib.attrNames (lib.filterAttrs (_: v: v == null) cfg.wm);
          in
          lib.optional (unset != [ ])
            "nox.desktop.compositor is null and nox.desktop.wm.{${lib.concatStringsSep "," unset}} unset: vm-clip refuses without focusedWindow, close-guard and screenrec-full do nothing, vm-autostart skips its checks and the login terminals (docs/compositor.md)."
          ++ lib.optional (
            cfg.niri.settings != { }
          ) "nox.desktop.niri.settings is set, but nox.desktop.compositor is null: ignored."
        );
    }
    (lib.mkIf cfg.swaync.enable {
      # at-spi2-core: no "AT-SPI: Error retrieving accessibility bus" noise
      environment = {
        systemPackages = [
          pkgs.swaynotificationcenter
          pkgs.at-spi2-core
        ];
        # Not under /etc/xdg/swaync: swaync takes its base style.css from
        # XDG_CONFIG_DIRS (/etc/xdg first) and the user one (-s) on top; ours
        # there would replace the base and leave only the overrides
        etc."nox/swaync/config.json".source = swayncConfig;
        etc."nox/swaync/style.css".source = swayncStyle;
      };
      systemd.user.services.swaync = sessionService // {
        description = "Swaync notification daemon";
        documentation = [ "https://github.com/ErikReider/SwayNotificationCenter" ];
        restartTriggers = [
          swayncConfig
          swayncStyle
        ];
        serviceConfig = {
          Type = "dbus";
          BusName = "org.freedesktop.Notifications";
          ExecStart = "${lib.getExe pkgs.swaynotificationcenter} -c /etc/nox/swaync/config.json -s /etc/nox/swaync/style.css";
          Restart = "on-failure";
        };
      };
    })
    (lib.mkIf cfg.wpaperd.enable {
      environment.systemPackages = [ pkgs.wpaperd ];
      environment.etc."xdg/wpaperd/wallpaper.toml".source = wpaperdConfig;
      systemd.user.services.wpaperd = sessionService // {
        description = "wpaperd";
        restartTriggers = [ wpaperdConfig ];
        serviceConfig = {
          ExecStart = "${lib.getExe pkgs.wpaperd} -c /etc/xdg/wpaperd/wallpaper.toml";
          Restart = "always";
          RestartSec = "10";
        };
      };
    })
    (lib.mkIf cfg.swaylock.enable {
      environment.systemPackages = [ pkgs.swaylock ];
      environment.etc."xdg/swaylock/config".source = swaylockConfig;
    })
  ];
}

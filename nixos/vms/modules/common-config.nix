{
  lib,
  pkgs,
  config,
  vmRegistry,
  ...
}:

with lib;

let
  cfg = config.services.common-config;
  defaultPkgs = import ../default-pkgs.nix { inherit pkgs; };
  hostName = config.networking.hostName or "";
  vmName = if hasSuffix "-vm" hostName then removeSuffix "-vm" hostName else hostName;
  currentVm =
    if builtins.hasAttr vmName vmRegistry.byName then
      builtins.getAttr vmName vmRegistry.byName
    else
      { };
  hostSSHKey = currentVm.hostSSHKey or null;
in
{
  imports = [
    ./xen-meminfo.nix
    ./usbip-client.nix
    ./vchan-relay.nix
    ./lab-target.nix
    # GUI over wprs (wprsd, foot as the terminal) in every VM: the admin
    # interface once dom0 has no SSH into the guests (xen-migration.md, spec
    # SSH removal)
    ./wprs.nix
  ];

  options.services.common-config = {
    enable = mkEnableOption "Enable the common-config module";
    user = mkOption {
      type = types.str;
      default = "user";
      description = "Username for the main user.";
    };
    withDefaultPkgs = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the default set of packages defined in default-pkgs.nix";
    };
    browser = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "firefox.desktop";
      description = "Desktop file of the VM's browser: links, HTML, PDFs and images open there (xdg-open, e.g. from yazi or a chat app).";
    };
  };

  config = mkIf cfg.enable {
    # Man pages (microvm.nix turns all documentation off); no info, doc or
    # NixOS manual (coding: +17 MiB, 2026-10-22)
    documentation = {
      enable = true;
      man.enable = true;
      info.enable = false;
      doc.enable = false;
      nixos.enable = false;
    };

    systemd = {
      # Driver domains (sys-net, sys-vpn, …): tell dom0 the backend is up once
      # xl devd runs (data/backend-ready, guest-writable); clients' preStart
      # waits for it (vms/modules/net-config.nix)
      services.xendriverdomain = mkIf (config.microvm.xen.driverDomain or false) {
        serviceConfig = {
          ExecStartPost = "${config.microvm.xen.package}/bin/xenstore-write data/backend-ready 1";
          ExecStopPost = "-${config.microvm.xen.package}/bin/xenstore-rm data/backend-ready";
        };
      };

      # Keyboards live in sys-usb (and in steam via input-to): Ctrl+Alt+Del
      # meant for dom0 (niri quit) rebooted sys-usb, all input dropped
      # (xmg 2026-10-15). Masked, the guest ignores it
      ctrlAltDelUnit = "/dev/null";

      tmpfiles.rules = [
        "d /home/${cfg.user} 0755 ${cfg.user} users -"
        "d /home/${cfg.user}/.ssh 0700 ${cfg.user} users -"
      ];
    };
    # Xen's vif-bridge adds `iptables -m physdev` rules for every new vif;
    # loading these modules then (modprobe) deadlocked with xenwatch: no
    # new vifs, usb-helper hung (sys-net 2026-10-16, sys-usb xmg 2026-10-19,
    # Known Issues). Load them at boot in every driver domain
    boot.kernelModules = mkIf (config.microvm.xen.driverDomain or false) [
      "nft_compat"
      "xt_physdev"
      "br_netfilter"
    ];

    nixpkgs.overlays = [
      (final: _prev: {
        inherit (final.lixPackageSets.latest)
          nixpkgs-review
          #         error: infinite recursion encountered
          # at /nix/store/wjfxdzblindbl9sp2hbwhi4iyh5jh348-source/pkgs/tools/package-management/lix/default.nix:128:24:
          #    127|
          #    128|           nix-direnv = nix-direnv.override {
          #       |                        ^
          #    129|             nix = self.lix;
          # note: trace involved the following derivations:
          # derivation 'microvm-cloud-hypervisor-coding-vm'
          # derivation 'microvm-coding-vm-microvm-run'
          # derivation 'nixos-system-coding-vm-26.05.20260430.15f4ee4'
          # derivation 'etc'
          # nix-direnv
          nix-eval-jobs
          nix-fast-build
          colmena
          ;
      })
    ];

    nix.package = pkgs.lixPackageSets.latest.lix;

    # The RAM balancer (dom0 modules/xen-memory.nix) reacts in 2-4 s; zram
    # bridges a faster peak instead of the OOM killer (xmg 2026-10-27: magick
    # took 1.1 GB in nvim between two steps). It counts used swap as usage,
    # so the VM grows and the swap drains again. Size from the boot RAM
    zramSwap = {
      enable = lib.mkDefault true;
      memoryPercent = lib.mkDefault 50;
    };

    # The user's session (zellij, nvim, Claude, …) gets 10 s to stop, then
    # SIGKILL: the default 2 min outlasted the runner, which destroys the
    # domain after 60 s (nvim, xmg 2026-10-27: "A stop job is running for
    # User Manager for UID 1000"), so every restart of such a VM took a minute
    systemd.services."user@".serviceConfig.TimeoutStopSec = lib.mkDefault "10s";

    # Time zone and locale: NixOS defaults (UTC, en_US.UTF-8); the user sets
    # them for the fleet in `nox.vmModule`
    i18n.defaultLocale = "en_US.UTF-8";

    services.openssh = {
      # Only VMs dom0 still logs into (registry `hostSSHKey`: the builder);
      # the others get dom0's calls over nox-rpc (xen-migration.md SSH removal)
      enable = hostSSHKey != null;
      # / is a tmpfs, so sshd-keygen runs on every boot; RSA 4096 delayed
      # sshd (and zellij from dom0) by seconds while all VMs boot at once
      # (xmg 2026-10-16). dom0 and the image domains use ed25519 only
      hostKeys = [
        {
          type = "ed25519";
          path = "/etc/ssh/ssh_host_ed25519_key";
        }
      ];
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        MaxSessions = 100;
        MaxStartups = "30:50:100";
        LoginGraceTime = 30;
      };
      extraConfig = ''
        # TCP Keepalive für stabile Verbindungen
        TCPKeepAlive yes
        ClientAliveInterval 60
        ClientAliveCountMax 3
        # Login-Beschleunigung
        UseDNS no
        # DBus Forwarding
        StreamLocalBindUnlink yes
      '';
    };

    security.pam.loginLimits = [
      {
        domain = "*";
        type = "soft";
        item = "nofile";
        value = "100000";
      }
      {
        domain = "*";
        type = "hard";
        item = "nofile";
        value = "100000";
      }
    ];

    security.sudo = {
      enable = true;
      wheelNeedsPassword = false;
    };

    users.groups.users = { };

    users.users."${cfg.user}" = {
      isNormalUser = true;
      group = "users";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = mkIf (hostSSHKey != null) [ hostSSHKey ];
    };

    # Emergency access over `xl console` (hvc0): the user has no password,
    # so log in automatically; the console is reachable only from dom0
    services.getty.autologinUser = cfg.user;

    programs = {
      # dconf on the VM's own session bus (apps started over RPC use it,
      # vchan-relay.nix); dark by default for GTK4/libadwaita apps
      dconf = {
        enable = true;
        profiles.user.databases = [
          { settings."org/gnome/desktop/interface".color-scheme = "prefer-dark"; }
        ];
      };

      # No nano: vim is the editor everywhere ($EDITOR, also yazi), the IDE
      # stack sets nvim (2026-10-14)
      nano.enable = false;

      vim = {
        enable = true;
        defaultEditor = !config.programs.neovim.defaultEditor;
      };
    };

    environment.sessionVariables = {
      TERM = "xterm-256color";
      GTK_THEME = "Adwaita:dark";
      QT_QPA_PLATFORMTHEME = "gtk2";
      QT_STYLE_OVERRIDE = "Adwaita-Dark";
      GTK_CURSORS_THEME = "Bibata-Modern-Ice";
      XCURSOR_THEME = "Bibata-Modern-Ice";
      WAYLAND_CURSOR_THEME = "Bibata-Modern-Ice";
    };

    fonts.packages = with pkgs; [
      nerd-fonts.fira-code
      (import ../../desktop/symbols-font.nix { inherit pkgs; })
      noto-fonts-color-emoji
    ];

    xdg.mime.defaultApplications = mkMerge [
      (mkIf (cfg.browser != null) (
        genAttrs [
          "text/html"
          "x-scheme-handler/http"
          "x-scheme-handler/https"
          "application/pdf"
          "image/png"
          "image/jpeg"
          "image/gif"
          "image/webp"
          "image/svg+xml"
          "image/bmp"
          "image/avif"
        ] (_: cfg.browser)
      ))
      # Text opens in the editor, not in whatever claims it (coding: Helix)
      (genAttrs [ "text/plain" "text/markdown" ] (
        _: if config.programs.neovim.defaultEditor then "nvim.desktop" else "vim.desktop"
      ))
    ];

    environment.systemPackages = mkMerge [
      (mkIf cfg.withDefaultPkgs (mkBefore defaultPkgs))
      # xdg-open itself (yazi, file dialogs); every VM has a GUI over wprs
      [ pkgs.xdg-utils ]
    ];
  };
}

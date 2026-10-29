{ pkgs, ... }:
{
  environment = {
    systemPackages = [
      pkgs.yazi
      # TUI for removable media incl. LUKS unlock (udisksctl, see below)
      pkgs.bashmount
    ];

    etc = {
      "yazi/init.lua".text = ''
        require("full-border"):setup {
          set = "rounded",
        }

        require("git"):setup {
          order = 1500,
        }
      '';

      "yazi/yazi.toml".text = ''
        [mgr]
        linemode = "size"
        show_hidden = true

        # GUI apps need the wprs display like vm-run starts them; text files
        # open in $EDITOR (vim/nvim)
        [opener]
        open = [
          # setsid + no inherited fds: the browser outlives yazi and its foot
          # window (explorer). No portal: xdg-desktop-portal never starts in the
          # VMs (needs graphical-session.target). %s1 = the file, quoted by yazi
          # (yazi 26 no longer fills in $1)
          { run = 'setsid -f env -u NIXOS_XDG_OPEN_USE_PORTAL WAYLAND_DISPLAY=wprs-0 DISPLAY=:100 XDG_SESSION_TYPE=wayland xdg-open %s1 </dev/null >/dev/null 2>&1', desc = "Open", orphan = true },
        ]

        [[plugin.prepend_fetchers]]
        id    = "git"
        url   = "*"
        run   = "git"
        group = "git"

        [[plugin.prepend_fetchers]]
        id    = "git"
        url   = "*/"
        run   = "git"
        group = "git"
      '';

      # Keybindings only work from keymap.toml (in yazi.toml they were ignored,
      # so mount, chmod, compress etc. never triggered, 2026-10-14)
      "yazi/keymap.toml".text = ''
        [[mgr.prepend_keymap]]
        desc = "Mount, unmount or eject removable media"
        on   = "M"
        run  = "plugin mount"

        [[mgr.prepend_keymap]]
        desc = "Chmod on selected files"
        on   = ["c", "m"]
        run  = "plugin chmod"

        # vm-copy: type the target VM at the cursor, dom0 asks in a rofi dialog;
        # the files land in ~/Incoming/<this vm> there. %s = selection, else the
        # hovered file
        [[mgr.prepend_keymap]]
        desc = "Copy to another VM (type its name, dom0 asks)"
        on   = ["C", "c"]
        run  = 'shell --block --interactive --cursor=8 "vm-copy  %s"'

        [[mgr.prepend_keymap]]
        desc = "Move to another VM (type its name, dom0 asks)"
        on   = ["C", "m"]
        run  = 'shell --block --interactive --cursor=11 "vm-copy -m  %s"'

        [[mgr.prepend_keymap]]
        desc = "Jump to char"
        on   = "F"
        run  = "plugin jump-to-char"

        [[mgr.prepend_keymap]]
        desc = "Compress selected files"
        on   = "z"
        run  = "plugin compress"

        [[mgr.prepend_keymap]]
        desc = "Smart Paste (context-aware paste)"
        on   = "P"
        run  = "plugin smart-paste"
      '';

      "yazi/plugins/git.yazi".source = pkgs.yaziPlugins.git;

      "yazi/plugins/chmod.yazi".source = pkgs.yaziPlugins.chmod;

      "yazi/plugins/mount.yazi".source = pkgs.yaziPlugins.mount;

      "yazi/plugins/full-border.yazi".source = pkgs.yaziPlugins.full-border;

      "yazi/plugins/jump-to-char.yazi".source = pkgs.yaziPlugins.jump-to-char;

      # compress 0.6 still calls fs.unique_name, yazi 26 has fs.unique(kind, url)
      # ("attempt to call a nil value (field 'unique_name')", 2026-10-15)
      "yazi/plugins/compress.yazi".source = pkgs.yaziPlugins.compress.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace main.lua \
            --replace-fail 'fs.unique_name(Url(temp_dir))' 'fs.unique("dir", Url(temp_dir))' \
            --replace-fail 'fs.unique_name(Url(final_output_url))' 'fs.unique("file", Url(final_output_url))'
        '';
      });

      "yazi/plugins/smart-paste.yazi".source = pkgs.yaziPlugins.smart-paste;
    };

  };

  systemd.tmpfiles.rules = [
    "d /home/user/.config/yazi 0755 user users -"
    "L+ /home/user/.config/yazi/yazi.toml - - - - /etc/yazi/yazi.toml"
    "L+ /home/user/.config/yazi/init.lua - - - - /etc/yazi/init.lua"
    "L+ /home/user/.config/yazi/keymap.toml - - - - /etc/yazi/keymap.toml"
    "L+ /home/user/.config/yazi/plugins - - - - /etc/yazi/plugins"
  ];

  # The mount plugin uses udisksctl (USB storage from sys-usb via vm-usb)
  services.udisks2.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (
        subject.isInGroup("wheel") &&
        action.id.indexOf("org.freedesktop.udisks2.") == 0
      ) {
        return polkit.Result.YES;
      }
    });
  '';
}

# Another compositor instead of niri

NoX's desktop in dom0 uses niri by default. It is a choice, not a
requirement: one switch turns it off, and everything that does not depend on
the compositor stays.

```nix
nox.desktop.compositor = null;
```

A working starting point with Hyprland: [examples/hyprland.nix](examples/hyprland.nix).
The flake check `compositor-none` (`nixos/tests/compositor-none.nix`)
evaluates it with a real dom0 and runs `Hyprland --verify-config` on the
generated config.

## What stays

- waybar, rofi, swaync (notifications), wpaperd (wallpaper), swaylock (lock
  screen with the NoX logo), foot, the GTK/Qt theme, cursor, plymouth
- The session services start with `graphical-session.target`
- The tools: `vm-run`, `vm-clip`, `vm-tray`, `vm-autostart`, `close-guard`,
  `screenrec-region`, `screenrec-full`, `explorer`, `nox`; wprs windows of the
  VMs with their `[<vm>] ` app id prefix

## What goes

- niri itself, `/etc/niri/config.kdl`, `nox.desktop.niri.settings` (ignored,
  with a warning), niri's portal config, `xwayland-satellite`
- The default session (`services.displayManager.defaultSession`)
- All keybinds, window rules, outputs and workspaces (they lived in niri's
  config)
- `niri-binds` (the keybinding viewer) and `terminal-tabs` (the login
  terminals as one tabbed column)

## What is left to implement

A build warning lists the open points while `nox.desktop.wm` hooks are unset.

1. **Session.** Enable the compositor and set
   `services.displayManager.defaultSession`; sddm logs into it (autologin).
   The compositor must start `graphical-session.target`, otherwise waybar,
   swaync and wpaperd stay off (Hyprland: `programs.hyprland.withUWSM`,
   session `hyprland-uwsm`).
2. **Portals.** `xdg.portal` is on with the GTK portal; screen sharing and
   the rest come from the compositor's portal (Hyprland's module adds its
   own).
3. **Compositor hooks** (`nox.desktop.wm`): shell snippets behind
   `nox-wm <command>`.

   | Hook | Command | Prints / does | Without it |
   | --- | --- | --- | --- |
   | `focusedWindow` | `nox-wm focused-window` | `<id>\t<pid>\t<app id>`, nothing if none | vm-clip refuses, close-guard does nothing |
   | `windows` | `nox-wm windows` | the app ids of all windows, one per line | vm-autostart starts windows that are already open |
   | `closeWindow` | `nox-wm close-window <id>` | closes the window | close-guard does nothing |
   | `focusedOutput` | `nox-wm focused-output` | the focused output's name | screenrec-full refuses |
   | `openTerminals` | `nox-wm open-terminals <tab>…` | opens the login terminals | vm-autostart leaves them out |

4. **Trust label colors** (security relevant: they show which VM a window
   belongs to). `nox.desktop.labels` holds one entry per label: `appId`
   (regex on the app id, e.g. `^\[(net|disp)\]( |$)`), `active`,
   `inactiveBorder`, `inactiveRing`. Turn each into a window rule. VM windows
   always carry wprsc's `[<vm>] ` prefix, which a VM cannot fake.
5. **Keybinds.** NoX's commands to bind:

   | Command | niri's key |
   | --- | --- |
   | `foot` | Mod+T |
   | `pkill rofi \|\| rofi -modi drun,filebrowser,window,run -show drun -theme /etc/xdg/rofi/config.rasi` | Mod+A |
   | `close-guard` (terminals close on the second press within 3 s) | Mod+Q |
   | `swaylock -C /etc/xdg/swaylock/config` | Mod+Alt+L |
   | `vm-clip copy` / `vm-clip paste` | Mod+Alt+C / Mod+Alt+V |
   | `rofimoji … \| vm-clip put` (emoji and Nerd Font glyphs) | Mod+Comma / Mod+Period |
   | `explorer` | Mod+E |
   | `screenrec-region` / `screenrec-full` | Mod+R / Mod+Shift+R |
   | `wpctl …` (volume), `brightnessctl -e4 -n2 set 5%±`, `playerctl …` | media keys |

6. **Autostart.** At session start: `vm-autostart` (the windows of
   `nox.desktop.login`) and `vm-tray <vm>` for each VM with tray apps.
   `manage-vms` calls both again after a VM's (re)start.
7. **Keyboard, outputs, workspaces.** `nox.desktop.keyboard` is read by the
   niri module only; pass it to the compositor yourself. Outputs and
   workspaces belong in the own config anyway.
8. **Login terminals.** Without tabs they open as single windows with the
   app ids `term-dom0` and `[<vm>] term-<vm>`; window rules place them.
9. **waybar workspaces.** `nox.desktop.waybar.workspaces.module`, e.g.
   `hyprland/workspaces` (null: none).

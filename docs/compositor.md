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
- The tools: `nox` (`nox run`), `vm-clip`, `vm-tray`, `vm-autostart`, `close-guard`,
  `screenrec-region`, `screenrec-full`, `explorer`; wprs windows of the
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
   | `windows` | `nox-wm windows` | the app ids of all windows, one per line | nox doctor cannot count a VM's windows |
   | `closeWindow` | `nox-wm close-window <id>` | closes the window | close-guard does nothing |
   | `focusedOutput` | `nox-wm focused-output` | the focused output's name | screenrec-full refuses |
   | `openTerminals` | `nox-wm open-terminals <tab>…` | opens the login terminals | vm-autostart leaves them out |
   | `castTargets` | `nox-wm cast-targets` | what a VM may be shown: `window\t<id>\t<label>` / `output\t<name>\t<label>`, one per line | VMs with `screenShare` get no screen |
   | `cast` | `nox-wm cast window <id>\|output <name>` | casts it as a PipeWire stream, prints the node id, ends when stdin closes | as above |

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
   | `close-guard` (every window closes on the second call within 3 s; the notification names no key) | Mod+Q |
   | `swaylock -C /etc/xdg/swaylock/config` | Mod+Alt+L |
   | `vm-clip copy` / `vm-clip paste` | Mod+Alt+C / Mod+Alt+V |
   | `rofimoji … \| vm-clip put` (emoji and Nerd Font glyphs) | Mod+Comma / Mod+Period |
   | `explorer` | Mod+E |
   | `screenrec-region` / `screenrec-full` | Mod+R / Mod+Shift+R |
   | `wpctl …` (volume), `brightnessctl -e4 -n2 set 5%±`, `playerctl …` | media keys |

   These are NoX's defaults, not fixed: the user rebinds a key by defining the same bind in `nox.desktop.niri.settings.binds` (the whole bind is replaced), and removes one with `null`, e.g. `"Mod+C" = { _props.repeat = false; spawn = [ "close-guard" ]; }; "Mod+Q" = null;`. The keybinding viewer follows the merged binds.

6. **Autostart.** At session start: `vm-autostart` (the windows of
   `nox.desktop.login`) and `vm-tray <vm>` for each VM with tray apps.
   `nox start|restart` calls both again after a VM's (re)start.
7. **Keyboard, outputs, workspaces.** `nox.desktop.keyboard` is read by the
   niri module only; pass it to the compositor yourself. Outputs and
   workspaces belong in the own config anyway.
8. **Login terminals.** Without tabs they open as single windows;
   identify a window by its launch, not by an app id the app chose (zellij's
   is fixed): dom0's foot by its pid, a VM's terminal by the `[<vm>] ` prefix
   of the app id that dom0's wprsc sets (a VM cannot fake it). `nox run`
   takes a fixed token (`NOX_APP_TOKEN`, 8-32 hex chars) and prints the VM's
   answer `ok: started …` or `ok: already started`; the VM refuses a second
   start with the same token, that is the dedup (vm-autostart does this for
   `nox.desktop.login.windows`). The niri module's `terminal-tabs` is the
   reference.
9. **waybar workspaces.** `nox.desktop.waybar.workspaces.module`, e.g.
   `hyprland/workspaces` (null: none).

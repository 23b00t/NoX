# NoX options

Generated from the option declarations (`nix build .#options-doc`); do not edit.

## Roles

| Role | Description | Defaults |
| --- | --- | --- |
| `browser` | Browsing. | `explorer = true`, `home = {"size":10000}`, `memory = 2048`, `memoryMax = 6144`, `storeGroup = desktop`, `vcpu = 4` |
| `desktop` | GUI apps over wprs with a file manager. | `explorer = true`, `home = {"size":10000}`, `memory = 2048`, `memoryMax = 4096`, `storeGroup = desktop`, `vcpu = 2` |
| `dev` | Software development: editor, language tooling, zsh, zellij, yazi. | `explorer = true`, `githubAgent = true`, `home = {"size":20000}`, `memory = 2048`, `memoryMax = 8192`, `storeGroup = dev`, `vcpu = 2` |
| `gaming` | Games with the GPU passed through. | `backup = false`, `dbus = false`, `gpu = true`, `home = {"size":200000}`, `memory = 16384`, `vcpu = 8` |
| `minimal` | Base system only; software comes in imperatively or from the VM's module. | `home = {"size":4096}`, `memory = 1024`, `memoryMax = 2048` |
| `terminal` | Text-mode work in zellij. | `home = {"size":1024}`, `memory = 1024`, `storeGroup = desktop` |
| `windows` | Windows programs under wine (Bottles). | `dbus = false`, `home = {"size":40000}`, `memory = 2048`, `memoryMax = 6144`, `vcpu = 4` |

## App catalog

| App | Package | Name |
| --- | --- | --- |
| `bottles` | (the VM's module) | Bottles |
| `chromium` | `chromium` | Chromium |
| `dbeaver` | `dbeaver-bin` | DBeaver |
| `element` | `element-desktop` | Element |
| `firefox` | `firefox` | Firefox |
| `gimp` | `gimp` | GIMP |
| `inkscape` | `inkscape` | Inkscape |
| `keepassxc` | `keepassxc` | KeePassXC |
| `libreoffice` | `libreoffice` | LibreOffice |
| `nm-applet` | `networkmanagerapplet` | Network |
| `pdfarranger` | `pdfarranger` | PDF Arranger |
| `pinta` | `pinta` | Pinta |
| `telegram` | `telegram-desktop` | Telegram |
| `vesktop` | `vesktop` | Vesktop |
| `vlc` | `vlc` | VLC |
| `zen` | (the VM's module) | Zen |

## Infrastructure VMs

On by default: `sys-firewall`, `sys-net`, `sys-usb`; with `nox.infra.<name>.enable`: `builder`, `disp`, `disp-backup`, `sys-print`, `sys-vpn`.

## Options

### nox\.apps

App catalog: known apps with the right switches; a VM’s ` apps.<id> ` takes these fields and overrides single ones\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.enable



Install the app and derive its desktop entry, waybar icon and tray start\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.package



Attribute path in the VM’s pkgs; null: the VM’s own module installs it\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"element-desktop"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.args



Arguments for every start (desktop entry and tray)\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.binary



Command run in the VM\. Default: the app id\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.categories



Desktop entry categories\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.genericName



Generic name of the desktop entry\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.icon



Icon name (desktop entry, waybar)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.install



Install ` package `; false: the VM’s own module installs the app (a wrapped build, ` programs.firefox `)\. Default: true\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.menu



Desktop entry in dom0’s app menu; false for apps that only run in the tray (nm-applet)\. Default: true\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.mimeType



MIME types the desktop entry opens\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.name



Display name of the desktop entry (“\<name> (\<vm>)”)\. Default: the app id\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.tray



Start into the tray with the session and after the VM (re)starts (vm-tray)\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.trayArgs



Extra arguments for the tray start\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```



*Example:*

```nix
[
  "--hidden"
]
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.unfree



Package is unfree: allowed in this VM by name only, and only in an own store image or a store group marked ` unfree `\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.apps\.\<name>\.x11



Electron app over XWayland (` --ozone-platform=x11 `): a Wayland Electron window hidden to the tray can’t come back under wprs\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.desktop\.keyboard\.layout



xkb layout of niri’s keyboard (empty: not set)\.



*Type:*
string



*Default:*

```nix
"us"
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.keyboard\.options



xkb options of niri’s keyboard (empty: not set)\.



*Type:*
string



*Default:*

```nix
""
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.keyboard\.variant



xkb variant of niri’s keyboard (empty: not set)\.



*Type:*
string



*Default:*

```nix
""
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.login\.dom0Command



Command in dom0’s terminal tab (empty: the shell)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "zellij"
  "--layout"
  "tabs"
]
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.login\.terminalTabs



Terminals as tabs of one column at login, in this order: ` dom0 ` (foot) or a VM (its foot with zellij)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "dom0"
  "nvim"
  "coding"
]
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.login\.windows



Further windows at login\.



*Type:*
list of (submodule)



*Default:*

```nix
[ ]
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.login\.windows\.\*\.appId



Extended regex on the window’s app id without the "\[\<vm>] " prefix: an open window that matches is not started again\.



*Type:*
string

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.login\.windows\.\*\.command



Command in the VM (vm-run)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.login\.windows\.\*\.vm



VM the window runs in\.



*Type:*
string

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.niri\.settings



niri’s config as Nix attrs (home-manager’s wayland\.windowManager\.niri\.settings format), written to /etc/niri/config\.kdl and validated at build time\.



*Type:*
attribute set of (KDL value)



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.swaylock\.enable



Whether to enable swaylock (Mod+Alt+L)\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.swaylock\.image



Own lock screen image instead of the rendered one (nox-branding)\. With it the ring is the plain one (shown while typing, filled) instead of the logo’s neon o\.



*Type:*
null or absolute path



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.swaylock\.settings



swaylock’s config (` -C /etc/xdg/swaylock/config `)\.



*Type:*
attribute set of (boolean or floating point number or signed integer or absolute path or string)



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.swaync\.enable



Whether to enable swaync notifications\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.swaync\.settings



swaync’s config\.json\.



*Type:*
JSON value



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.swaync\.style



swaync’s style\.css\.



*Type:*
strings concatenated with “\\n”



*Default:*

```nix
""
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme



Desktop theme of dom0: colors, fonts and radii for niri, waybar, rofi, swaync, swaylock, foot and GTK/Qt, and the generated wallpaper and lock screen (nix/nox-branding\.nix)\. Defaults to the fleet’s ` nox.theme ` (vms\.nix); set that one, so the VMs follow (a different value here only changes dom0 and warns)\. Single values stay overridable through the modules’ options (e\.g\. nox\.desktop\.niri\.settings, nox\.desktop\.wpaperd\.settings)\.



*Type:*
submodule



*Default:*

```nix
nox.theme (vms.nix)
```



*Example:*

```nix
{
  name = "tokyo-night";
  flavor = "neon";
  decor = [ "stars" ];
  lock.shade = "normal";
}

```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.colors



Overrides of the theme’s semantic roles (hex without ‘\#’): bg, bgDark, border, fg, fgActive, accent, accentStrong, accent2, muted, urgent, warn, ok, info, shadow\. Logo and wallpaper colors follow them where the theme derives them from roles\.



*Type:*
attribute set of string matching the pattern \[0-9a-fA-F]{6}



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  accent = "ff9e64";
}
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.cursor\.package



Attribute name in pkgs of the package with the cursor theme (a name: the fleet’s theme is evaluated without pkgs)\. Installed in dom0 and every VM\.



*Type:*
string



*Default:*

```nix
"bibata-cursors"
```



*Example:*

```nix
"adwaita-icon-theme"
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.cursor\.name



Cursor theme (XCursor) of niri, the login screen, GTK/Qt apps in dom0 and the VMs’ apps over wprs\.



*Type:*
string



*Default:*

```nix
"Bibata-Modern-Ice"
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.cursor\.size



Cursor size in px\.



*Type:*
positive integer, meaning >0



*Default:*

```nix
24
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.dark



GTK and Qt apps in their dark variant (dom0 and the VMs: GTK theme, color-scheme, Qt style)\. false = the light variant; the desktop’s own colors come from the theme\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.decor



Sky behind the logo: a crescent moon, stars, both or none\.



*Type:*
list of (one of “moon”, “stars”)



*Default:*

```nix
[
  "moon"
  "stars"
]
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.flavor



Logo style: organic (glossy 3D), neon (glowing tubes) or glitch\.



*Type:*
one of “organic”, “neon”, “glitch”



*Default:*

```nix
"organic"
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.graphics



Overrides of the logo and wallpaper colors (hex without ‘\#’): front, surface, edgeA, edgeB, glow, glow2 (bg and bgDark follow ` colors `)\.



*Type:*
attribute set of string matching the pattern \[0-9a-fA-F]{6}



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  glow = "ff9e64";
}
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.labels



Overrides of the trust label colors (hex without ‘\#’): the border and focus ring of each VM’s windows in dom0 (registry ` label `)\. Labels: dom0, unknown, sys, dev, personal, social, untrusted, vault, anon\.



*Type:*
attribute set of string matching the pattern \[0-9a-fA-F]{6}



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  social = "d1bfff";
}
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.lock



Look of the lock screen image (the logo without its o: swaylock’s ring takes its place)\. flavor defaults to neon, shade and decor to the wallpaper’s\.



*Type:*
submodule



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.lock\.decor



Sky behind the logo: a crescent moon, stars, both or none\.



*Type:*
list of (one of “moon”, “stars”)



*Default:*

```nix
theme.decor
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.lock\.flavor



Logo style: organic (glossy 3D), neon (glowing tubes) or glitch\.



*Type:*
one of “organic”, “neon”, “glitch”



*Default:*

```nix
"neon"
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.lock\.shade



Background of the graphics: the theme’s colors (normal) or pulled 45 % towards black (dark)\. The desktop colors stay as they are\.



*Type:*
one of “normal”, “dark”



*Default:*

```nix
theme.shade
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.name



Theme (desktop/themes/\<name>\.nix): colors for niri, waybar, rofi, swaync, swaylock, foot, GTK/Qt, logo and wallpaper; icon theme\.



*Type:*
one of “black”, “catppuccin-mocha”, “dracula”, “nox”, “tokyo-night”



*Default:*

```nix
"nox"
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.resolution



Size of the rendered wallpaper and lock screen image (scaled to each output)\.



*Type:*
one of “3840x2160”, “2560x1600”



*Default:*

```nix
"3840x2160"
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.theme\.shade



Background of the graphics: the theme’s colors (normal) or pulled 45 % towards black (dark)\. The desktop colors stay as they are\.



*Type:*
one of “normal”, “dark”



*Default:*

```nix
"dark"
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.wpaperd\.enable



Whether to enable wpaperd wallpapers\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktop\.wpaperd\.settings



wpaperd’s config (per output: path, …)\.



*Type:*
TOML value



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/desktop](../nixos/desktop)



### nox\.desktopEntries



Desktop entries in dom0: file id → fields as in home-manager’s xdg\.desktopEntries (name, genericName, exec, icon, categories, mimeType, terminal, type, noDisplay)\. Also the source of waybar’s app id → icon mapping\.



*Type:*
attribute set of attribute set of anything



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/dom0/tools/desktop-entries\.nix](../nixos/dom0/tools/desktop-entries.nix)



### nox\.images



Image domains (upstream disk images: Whonix, Kali); manual steps in the docs\. Their ` apps ` only give dom0’s desktop entries (` package ` and ` install ` are not used, the image brings the software)\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.enable



Whether this machine runs the domain (the definition is kept either way)\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps



Apps of the VM; an id from the catalog (nox\.apps) takes its fields from there\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```



*Example:*

```nix
{ element.tray = true; vesktop.enable = false; }
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.enable



Install the app and derive its desktop entry, waybar icon and tray start\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.package



Attribute path in the VM’s pkgs; null: the VM’s own module installs it\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"element-desktop"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.args



Arguments for every start (desktop entry and tray)\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.binary



Command run in the VM\. Default: the app id\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.categories



Desktop entry categories\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.genericName



Generic name of the desktop entry\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.icon



Icon name (desktop entry, waybar)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.install



Install ` package `; false: the VM’s own module installs the app (a wrapped build, ` programs.firefox `)\. Default: true\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.menu



Desktop entry in dom0’s app menu; false for apps that only run in the tray (nm-applet)\. Default: true\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.mimeType



MIME types the desktop entry opens\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.name



Display name of the desktop entry (“\<name> (\<vm>)”)\. Default: the app id\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.tray



Start into the tray with the session and after the VM (re)starts (vm-tray)\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.trayArgs



Extra arguments for the tray start\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```



*Example:*

```nix
[
  "--hidden"
]
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.unfree



Package is unfree: allowed in this VM by name only, and only in an own store image or a store group marked ` unfree `\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.apps\.\<name>\.x11



Electron app over XWayland (` --ozone-platform=x11 `): a Wayland Electron window hidden to the tray can’t come back under wprs\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.index



Last octet of the domain’s addresses (admin net, uplink, USB/IP link), its tap and MAC\.



*Type:*
integer between 1 and 254 (both inclusive)

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.label



Trust label: the window border color in dom0\. Default: untrusted\.



*Type:*
null or one of “sys”, “dev”, “personal”, “social”, “untrusted”, “vault”, “anon”



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.images\.\<name>\.short



Short alias for the command line tools\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.infra\.builder\.enable



NoX’s builder VM (module nixos/vms/builder)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [nixos/registry/infra\.nix](../nixos/registry/infra.nix)



### nox\.infra\.disp\.enable



NoX’s disp VM (module nixos/vms/disp)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [nixos/registry/infra\.nix](../nixos/registry/infra.nix)



### nox\.infra\.disp-backup\.enable



NoX’s disp-backup VM (module nixos/vms/disp-backup)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [nixos/registry/infra\.nix](../nixos/registry/infra.nix)



### nox\.infra\.sys-firewall\.enable



NoX’s sys-firewall VM (module nixos/vms/sys-firewall)\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [nixos/registry/infra\.nix](../nixos/registry/infra.nix)



### nox\.infra\.sys-net\.enable



NoX’s sys-net VM (module nixos/vms/sys-net)\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [nixos/registry/infra\.nix](../nixos/registry/infra.nix)



### nox\.infra\.sys-print\.enable



NoX’s sys-print VM (module nixos/vms/sys-print)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [nixos/registry/infra\.nix](../nixos/registry/infra.nix)



### nox\.infra\.sys-usb\.enable



NoX’s sys-usb VM (module nixos/vms/sys-usb)\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [nixos/registry/infra\.nix](../nixos/registry/infra.nix)



### nox\.infra\.sys-vpn\.enable



NoX’s sys-vpn VM (module nixos/vms/sys-vpn)\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [nixos/registry/infra\.nix](../nixos/registry/infra.nix)



### nox\.network\.adminPrefix



First three octets of the admin net (dom0 \.254, sys-net \.253); a domain’s address is \<prefix>\.\<index>\.



*Type:*
string



*Default:*

```nix
"10.0.0"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.roles



Roles a VM can have (` nox.vms.<name>.role `); NoX brings minimal, terminal, dev, desktop, browser, windows and gaming, more can be added or extended like any module\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.roles\.\<name>\.defaults



Defaults for the fields of the VMs with this role\.



*Type:*
attribute set of anything



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  home = {
    size = 10000;
  };
  memory = 2048;
}
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.roles\.\<name>\.description



What kind of work the role is for\.



*Type:*
string



*Default:*

```nix
""
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.roles\.\<name>\.module



NixOS module of the role in the VM: the NoX building blocks its kind of work needs\. Free software only; apps come from the VM\.



*Type:*
module



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.storeGroups



Shared read-only store images (` storeGroup ` of a VM): trust in the software, not in the VM\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.storeGroups\.\<name>\.description



Where the group’s software comes from\.



*Type:*
string



*Default:*

```nix
""
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.storeGroups\.\<name>\.unfree



Members may bring unfree packages; in any other group the VM’s build fails on one\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme



Desktop theme of the whole fleet: dom0’s desktop (nox\.desktop\.theme takes it as its default) and every VM (foot over wprs, the own niri of e\.g\. godot-gpu)\. Set it here, not per machine, so the VMs follow dom0; options in nox\.desktop\.theme\.



*Type:*
submodule



*Default:*

```nix
{ }
```



*Example:*

```nix
{ name = "tokyo-night"; flavor = "neon"; }
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.colors



Overrides of the theme’s semantic roles (hex without ‘\#’): bg, bgDark, border, fg, fgActive, accent, accentStrong, accent2, muted, urgent, warn, ok, info, shadow\. Logo and wallpaper colors follow them where the theme derives them from roles\.



*Type:*
attribute set of string matching the pattern \[0-9a-fA-F]{6}



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  accent = "ff9e64";
}
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.cursor\.package



Attribute name in pkgs of the package with the cursor theme (a name: the fleet’s theme is evaluated without pkgs)\. Installed in dom0 and every VM\.



*Type:*
string



*Default:*

```nix
"bibata-cursors"
```



*Example:*

```nix
"adwaita-icon-theme"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.cursor\.name



Cursor theme (XCursor) of niri, the login screen, GTK/Qt apps in dom0 and the VMs’ apps over wprs\.



*Type:*
string



*Default:*

```nix
"Bibata-Modern-Ice"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.cursor\.size



Cursor size in px\.



*Type:*
positive integer, meaning >0



*Default:*

```nix
24
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.dark



GTK and Qt apps in their dark variant (dom0 and the VMs: GTK theme, color-scheme, Qt style)\. false = the light variant; the desktop’s own colors come from the theme\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.decor



Sky behind the logo: a crescent moon, stars, both or none\.



*Type:*
list of (one of “moon”, “stars”)



*Default:*

```nix
[
  "moon"
  "stars"
]
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.flavor



Logo style: organic (glossy 3D), neon (glowing tubes) or glitch\.



*Type:*
one of “organic”, “neon”, “glitch”



*Default:*

```nix
"organic"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.graphics



Overrides of the logo and wallpaper colors (hex without ‘\#’): front, surface, edgeA, edgeB, glow, glow2 (bg and bgDark follow ` colors `)\.



*Type:*
attribute set of string matching the pattern \[0-9a-fA-F]{6}



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  glow = "ff9e64";
}
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.labels



Overrides of the trust label colors (hex without ‘\#’): the border and focus ring of each VM’s windows in dom0 (registry ` label `)\. Labels: dom0, unknown, sys, dev, personal, social, untrusted, vault, anon\.



*Type:*
attribute set of string matching the pattern \[0-9a-fA-F]{6}



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  social = "d1bfff";
}
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.lock



Look of the lock screen image (the logo without its o: swaylock’s ring takes its place)\. flavor defaults to neon, shade and decor to the wallpaper’s\.



*Type:*
submodule



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.lock\.decor

Sky behind the logo: a crescent moon, stars, both or none\.



*Type:*
list of (one of “moon”, “stars”)



*Default:*

```nix
theme.decor
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.lock\.flavor



Logo style: organic (glossy 3D), neon (glowing tubes) or glitch\.



*Type:*
one of “organic”, “neon”, “glitch”



*Default:*

```nix
"neon"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.lock\.shade



Background of the graphics: the theme’s colors (normal) or pulled 45 % towards black (dark)\. The desktop colors stay as they are\.



*Type:*
one of “normal”, “dark”



*Default:*

```nix
theme.shade
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.name



Theme (desktop/themes/\<name>\.nix): colors for niri, waybar, rofi, swaync, swaylock, foot, GTK/Qt, logo and wallpaper; icon theme\.



*Type:*
one of “black”, “catppuccin-mocha”, “dracula”, “nox”, “tokyo-night”



*Default:*

```nix
"nox"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.resolution



Size of the rendered wallpaper and lock screen image (scaled to each output)\.



*Type:*
one of “3840x2160”, “2560x1600”



*Default:*

```nix
"3840x2160"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.theme\.shade



Background of the graphics: the theme’s colors (normal) or pulled 45 % towards black (dark)\. The desktop colors stay as they are\.



*Type:*
one of “normal”, “dark”



*Default:*

```nix
"dark"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.unfree



Unfree packages (pname) allowed in dom0; set where the package is added\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "claude-code"
]
```

*Declared by:*
 - [nixos/dom0/unfree\.nix](../nixos/dom0/unfree.nix)



### nox\.vmModule



NixOS module of every NoX VM (role and infrastructure VMs, not image domains): settings for the whole fleet such as time zone and locale\.



*Type:*
module



*Default:*

```nix
{ }
```



*Example:*

```nix
{ time.timeZone = "Europe/Berlin"; }
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms



NixOS guests (microvm\.nix on Xen)\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.enable



Whether this machine runs the domain (the definition is kept either way)\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps



Apps of the VM; an id from the catalog (nox\.apps) takes its fields from there\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```



*Example:*

```nix
{ element.tray = true; vesktop.enable = false; }
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.enable



Install the app and derive its desktop entry, waybar icon and tray start\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.package



Attribute path in the VM’s pkgs; null: the VM’s own module installs it\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"element-desktop"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.args



Arguments for every start (desktop entry and tray)\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.binary



Command run in the VM\. Default: the app id\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.categories



Desktop entry categories\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.genericName



Generic name of the desktop entry\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.icon



Icon name (desktop entry, waybar)\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.install



Install ` package `; false: the VM’s own module installs the app (a wrapped build, ` programs.firefox `)\. Default: true\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.menu



Desktop entry in dom0’s app menu; false for apps that only run in the tray (nm-applet)\. Default: true\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.mimeType



MIME types the desktop entry opens\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.name



Display name of the desktop entry (“\<name> (\<vm>)”)\. Default: the app id\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.tray



Start into the tray with the session and after the VM (re)starts (vm-tray)\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.trayArgs



Extra arguments for the tray start\.



*Type:*
null or (list of string)



*Default:*

```nix
null
```



*Example:*

```nix
[
  "--hidden"
]
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.unfree



Package is unfree: allowed in this VM by name only, and only in an own store image or a store group marked ` unfree `\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.apps\.\<name>\.x11



Electron app over XWayland (` --ozone-platform=x11 `): a Wayland Electron window hidden to the tray can’t come back under wprs\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.autostart



Start with dom0\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.backup



/home in the home backup (nox backup --all)\. Default: true except sys-\* VMs and disposables\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.bluetooth



bluez in the VM (adapter over USB/IP from sys-usb)\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.clipboard



Copy/paste through dom0 (vm-clip): allow, ask (pasting in is free, copying out asks) or deny\. Default: deny for sys-\* VMs, else allow\.



*Type:*
null or one of “allow”, “ask”, “deny”



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.copy



Files between domains over nox-rpc (vm-copy, nox copy)\.



*Type:*
null or (submodule)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.copy\.incoming



Files into the VM: ask, warn (ask, the user types the VM’s name) or deny\. Default: ask\.



*Type:*
null or one of “ask”, “warn”, “deny”



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.copy\.outgoing



Files out of the VM\. Default: deny for sys-\* VMs, else ask\.



*Type:*
null or one of “ask”, “warn”, “deny”



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.dbus



Filtered session bus to dom0 (notifications, tray)\. Default: true\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.disposable



Boots empty every time (home and store overlay images are deleted before start and after stop)\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.egress



Outgoing traffic the VM may send through sys-firewall; null: everything\. DNS always through sys-firewall’s resolver\.



*Type:*
null or (list of (submodule))



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.egress\.\*\.ports



Ports; empty: all ports to that net\.



*Type:*
list of 16 bit unsigned integer; between 0 and 65535 (both inclusive)



*Default:*

```nix
[ ]
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.egress\.\*\.to



Destination net (CIDR)\.



*Type:*
string

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.explorer



The VM has yazi (roles dev, desktop, browser): ` explorer ` in dom0 offers it\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.githubAgent



dom0’s GitHub-only SSH agent in the VM\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.gpu



Passes the machine’s GPU (hardware config) through to the VM\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.hasDisposable



Adds the VM’s disposable ` disp-<name> ` (` nox disp --from <name> `): the same role, apps, module and fields, but empty on every start, label of ` disp `, index + 100, short ` d<short> `, no backup, no autostart, no desktop entries\. Needs a role and a store group (an own store image is not supported yet)\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.home\.image



Image of the /home/user volume; null: home\.img in the VM’s state directory\. An absolute path shares another VM’s home (two starts of one VM that never run together; set ` backup = false ` on the second)\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"/var/lib/microvms/godot/home.img"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.home\.size



Size of the /home/user volume in MB\.



*Type:*
null or (positive integer, meaning >0)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.index



Last octet of the domain’s addresses (admin net, uplink, USB/IP link), its tap and MAC\.



*Type:*
integer between 1 and 254 (both inclusive)

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.labTarget



kali may test this VM’s apps over the lab bridge (vm-lab attach)\. Default: false\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.label



Trust label: the window border color in dom0\. Default: untrusted\.



*Type:*
null or one of “sys”, “dev”, “personal”, “social”, “untrusted”, “vault”, “anon”



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.memPriority



RAM balancer priority (higher grows first)\. Default: 0\.



*Type:*
null or signed integer



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.memory



RAM at boot in MB\.



*Type:*
null or (positive integer, meaning >0)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.memoryMax



RAM the balancer may grow the VM to, in MB; null: fixed at ` memory `\.



*Type:*
null or (positive integer, meaning >0)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.module



NixOS module with what is the VM’s own (packages, files, services), on top of its role\.



*Type:*
null or module



*Default:*

```nix
null
```



*Example:*

```nix
./vms/php.nix
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.role



Kind of work in the VM (nox\.roles): its base software and the defaults of the fields below\. null: no role, the VM’s module comes from the user’s own definitions\.



*Type:*
null or string



*Default:*

```nix
null
```



*Example:*

```nix
"dev"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.short



Short alias for the command line tools\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.store\.size



Size of the persistent store overlay in MB (new store paths built or fetched in the VM)\. Read by the builder (default 100000, registry/infra\.nix)\. The image is created once: a bigger value needs the existing image grown by hand (truncate, e2fsck -f, resize2fs) or deleted (empty cache)\.



*Type:*
null or (positive integer, meaning >0)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.storeGroup



Shared read-only store image (nox\.storeGroups); null: an image of its own\.



*Type:*
null or string



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.uplink



Driver domain that serves the VM’s uplink (sys-firewall, sys-vpn, sys-net); null: offline\.



*Type:*
null or string



*Default:*

```nix
"sys-firewall"
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



### nox\.vms\.\<name>\.vcpu



Virtual CPUs\. Default: 1\.



*Type:*
null or (positive integer, meaning >0)



*Default:*

```nix
null
```

*Declared by:*
 - [nixos/registry/vms\.nix](../nixos/registry/vms.nix)



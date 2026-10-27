# Theme dracula (nox.desktop.theme.name): Dracula. Data only;
# desktop/theme.nix adds the shared parts (opacity, radii, fonts, …).
rec {
  # Hex without '#', Dracula's names
  palette = {
    bg = "282a36"; # background
    bgDark = "191a21";
    surface = "44475a"; # current line
    fg = "f8f8f2"; # foreground
    comment = "6272a4";
    border = "44475a";
    cyan = "8be9fd";
    green = "50fa7b";
    orange = "ffb86c";
    pink = "ff79c6";
    purple = "bd93f9";
    red = "ff5555";
    yellow = "f1fa8c";
    white = "f8f8f2";
    black = "000000";
  };

  # Semantic roles (nox.desktop.theme.colors overrides them)
  raw = {
    inherit (palette)
      bg
      bgDark
      border
      fg # text everywhere
      ;
    fgActive = palette.fg; # text on accent backgrounds
    accent = palette.purple; # focus ring, active workspace, selection
    accentStrong = palette.pink; # active tab indicator, stronger than accent
    accent2 = palette.cyan; # second gradient stop, selection background
    muted = palette.comment;
    urgent = palette.red;
    warn = palette.yellow;
    ok = palette.green;
    info = palette.cyan;
    shadow = palette.black;
  };

  # Trust labels: window border per VM label (same meaning in every theme;
  # Dracula has no blue, so anon is orange)
  labels = {
    dom0 = palette.fg;
    unknown = palette.comment;
    sys = palette.red;
    dev = palette.purple;
    personal = palette.green;
    untrusted = palette.yellow;
    vault = palette.cyan;
    anon = palette.orange;
  };

  # Logo and wallpaper colors from the (overridden) roles
  graphics = r: {
    front = palette.white;
    inherit (palette) surface;
    edgeA = r.accent2;
    edgeB = r.accentStrong;
    glow = r.accentStrong;
    glow2 = r.accent;
  };

  icons = {
    name = "Tela-circle-dracula";
    variant = "dracula";
  };

  # foot [colors-dark]: dracula/foot foot.ini (selection as Dracula's
  # current line)
  terminal = {
    background = "282a36";
    foreground = "f8f8f2";
    selection-background = "44475a";
    selection-foreground = "f8f8f2";
    regular0 = "21222c";
    regular1 = "ff5555";
    regular2 = "50fa7b";
    regular3 = "f1fa8c";
    regular4 = "bd93f9";
    regular5 = "ff79c6";
    regular6 = "8be9fd";
    regular7 = "f8f8f2";
    bright0 = "6272a4";
    bright1 = "ff6e6e";
    bright2 = "69ff94";
    bright3 = "ffffa5";
    bright4 = "d6acff";
    bright5 = "ff92df";
    bright6 = "a4ffff";
    bright7 = "ffffff";
  };
}

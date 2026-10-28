# Theme black (nox.desktop.theme.name): near-black and white, neutral greys.
# Status and trust label colors stay in full color (they carry meaning).
# Data only; desktop/theme.nix adds the shared parts (opacity, radii, …).
rec {
  # Hex without '#'
  palette = {
    bg = "1f1f23";
    bgDark = "141417";
    surface = "2e2e33";
    fg = "d4d4d8";
    comment = "6b6b73";
    border = "3a3a40";
    grey = "8a8a92";
    silver = "c4c4cc";
    silverLight = "c8c8cf";
    light = "e6e6ea";
    white = "ffffff";
    red = "ff5f5f";
    yellow = "e5c07b";
    green = "98c379";
    cyan = "56b6c2";
    blue = "61afef";
    magenta = "c678dd";
    violet = "9d7cd8";
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
    fgActive = palette.bgDark; # text on accent backgrounds (light accents)
    accent = palette.silver; # focus ring, active workspace, selection
    accentStrong = palette.light; # active tab indicator, stronger than accent
    accent2 = palette.grey; # second gradient stop, selection background
    muted = palette.comment;
    urgent = palette.red;
    warn = palette.yellow;
    ok = palette.green;
    info = palette.cyan;
    shadow = palette.black;
  };

  # Trust labels: window border per VM label (same meaning in every theme)
  labels = {
    dom0 = palette.fg;
    unknown = palette.comment;
    sys = palette.red;
    dev = palette.magenta;
    personal = palette.green;
    social = palette.violet;
    untrusted = palette.yellow;
    vault = palette.cyan;
    anon = palette.blue;
  };

  # Logo and wallpaper colors from the (overridden) roles
  graphics = r: {
    front = palette.white;
    inherit (palette) surface;
    edgeA = r.accent2;
    edgeB = palette.silverLight;
    glow = r.accentStrong;
    glow2 = r.accent;
  };

  icons = {
    name = "Tela-circle-black";
    variant = "black";
  };

  # foot [colors-dark]: grey base, regular ANSI colors
  terminal = {
    background = palette.bgDark;
    foreground = palette.fg;
    selection-background = palette.border;
    selection-foreground = palette.white;
    regular0 = "1f1f23";
    regular1 = "ff5f5f";
    regular2 = "98c379";
    regular3 = "e5c07b";
    regular4 = "61afef";
    regular5 = "c678dd";
    regular6 = "56b6c2";
    regular7 = "bbbbc2";
    bright0 = "5a5a62";
    bright1 = "ff7f7f";
    bright2 = "b0d695";
    bright3 = "f0d29a";
    bright4 = "8cc6f5";
    bright5 = "d89ae8";
    bright6 = "7fcdd6";
    bright7 = "ffffff";
  };
}

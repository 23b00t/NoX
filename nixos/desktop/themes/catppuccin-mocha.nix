# Theme catppuccin-mocha (nox.desktop.theme.name): Catppuccin Mocha. Data
# only; desktop/theme.nix adds the shared parts (opacity, radii, fonts, …).
rec {
  # Hex without '#', Catppuccin's names where they exist
  palette = {
    bg = "1e1e2e"; # base
    bgDark = "11111b"; # crust
    surface = "313244"; # surface0
    fg = "cdd6f4"; # text
    comment = "6c7086"; # overlay0
    border = "45475a"; # surface1
    blue = "89b4fa";
    sky = "89dceb";
    teal = "94e2d5";
    mauve = "cba6f7";
    lavender = "b4befe";
    pink = "f5c2e7";
    rosewater = "f5e0dc";
    red = "f38ba8";
    yellow = "f9e2af";
    green = "a6e3a1";
    white = "f5f3ff";
    black = "000000";
  };

  # Semantic roles (nox.desktop.theme.colors overrides them)
  raw = {
    inherit (palette) bg bgDark border;
    fg = palette.lavender; # text everywhere
    fgActive = palette.bgDark; # text on accent backgrounds (light accents)
    accent = palette.mauve; # focus ring, active workspace, selection
    accentStrong = palette.pink; # active tab indicator, stronger than accent
    accent2 = palette.blue; # second gradient stop, selection background
    muted = palette.comment;
    urgent = palette.red;
    warn = palette.yellow;
    ok = palette.green;
    info = palette.sky;
    shadow = palette.black;
  };

  # Trust labels: window border per VM label (same meaning in every theme)
  labels = {
    dom0 = palette.fg;
    unknown = palette.comment;
    sys = palette.red;
    dev = palette.mauve;
    personal = palette.green;
    social = palette.lavender;
    untrusted = palette.yellow;
    vault = palette.sky;
    anon = palette.blue;
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
    name = "Tela-circle-purple";
    variant = "purple";
  };

  # foot [colors-dark]: catppuccin/foot themes/catppuccin-mocha.ini
  terminal = {
    background = "1e1e2e";
    foreground = "cdd6f4";
    selection-background = "414356";
    selection-foreground = "cdd6f4";
    urls = "89b4fa";
    regular0 = "45475a";
    regular1 = "f38ba8";
    regular2 = "a6e3a1";
    regular3 = "f9e2af";
    regular4 = "89b4fa";
    regular5 = "f5c2e7";
    regular6 = "94e2d5";
    regular7 = "bac2de";
    bright0 = "585b70";
    bright1 = "f38ba8";
    bright2 = "a6e3a1";
    bright3 = "f9e2af";
    bright4 = "89b4fa";
    bright5 = "f5c2e7";
    bright6 = "94e2d5";
    bright7 = "a6adc8";
  };
}

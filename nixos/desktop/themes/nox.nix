# Theme nox (nox.desktop.theme.name, the default): Tokyo Night on a darker,
# violet night background, with pink as the strong accent. Data only;
# desktop/theme.nix adds the shared parts (opacity, radii, fonts, …).
rec {
  # Hex without '#'
  palette = {
    bg = "1a1030";
    bgDark = "0f0b1a";
    surface = "241640";
    fg = "c0caf5";
    comment = "565f89";
    border = "3a2d5c";
    blue = "7aa2f7";
    cyan = "7dcfff";
    teal = "b4f9f8";
    magenta = "bb9af7";
    lavender = "d1bfff";
    purple = "9d7cd8";
    pink = "ff79c6";
    red = "f7768e";
    yellow = "e0af68";
    green = "9ece6a";
    white = "f4f0ff";
    black = "000000";
  };

  # Semantic roles (nox.desktop.theme.colors overrides them)
  raw = {
    inherit (palette) bg bgDark border;
    fg = palette.blue; # text everywhere
    fgActive = palette.teal; # text on accent backgrounds
    accent = palette.magenta; # focus ring, active workspace, selection
    accentStrong = palette.pink; # active tab indicator, stronger than accent
    accent2 = palette.blue; # second gradient stop, selection background
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
    social = palette.purple;
    untrusted = palette.yellow;
    vault = palette.cyan;
    anon = palette.blue;
  };

  # Logo and wallpaper colors from the (overridden) roles; bg and bgDark
  # come from the roles too
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

  # foot [colors-dark]: Tokyo Night's terminal colors on the nox background
  terminal = {
    background = palette.bgDark;
    foreground = palette.fg;
    selection-background = "2e2350";
    selection-foreground = palette.fg;
    urls = "73daca";
    regular0 = "15161e";
    regular1 = "f7768e";
    regular2 = "9ece6a";
    regular3 = "e0af68";
    regular4 = "7aa2f7";
    regular5 = "bb9af7";
    regular6 = "7dcfff";
    regular7 = "a9b1d6";
    bright0 = "414868";
    bright1 = "f7768e";
    bright2 = "9ece6a";
    bright3 = "e0af68";
    bright4 = "7aa2f7";
    bright5 = "bb9af7";
    bright6 = "7dcfff";
    bright7 = "c0caf5";
  };
}

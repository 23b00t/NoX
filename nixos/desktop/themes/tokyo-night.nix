# Theme tokyo-night (nox.desktop.theme.name): Tokyo Night storm/night with an
# extra pink as the strong accent. Data only; desktop/theme.nix adds the
# shared parts (opacity, radii, fonts, …).
rec {
  # Hex without '#'
  palette = {
    bg = "24283b"; # storm background
    bgDark = "1a1b26"; # night background
    surface = "292e42";
    fg = "c0caf5";
    comment = "565f89";
    border = "3b4261";
    blue = "7aa2f7";
    cyan = "7dcfff";
    teal = "b4f9f8";
    magenta = "bb9af7";
    lavender = "d1bfff";
    pink = "ff79c6";
    red = "f7768e";
    yellow = "e0af68";
    green = "9ece6a";
    white = "eef1ff";
    black = "000000";
  };

  # Semantic roles (nox.desktop.theme.colors overrides them)
  raw = {
    inherit (palette) bg bgDark border;
    fg = palette.blue; # text everywhere, as waybar always had it
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
    untrusted = palette.yellow;
    vault = palette.cyan;
    anon = palette.blue;
  };

  # Logo and wallpaper colors: blue/magenta/cyan, no pink
  graphics = r: {
    front = palette.white;
    inherit (palette) surface;
    edgeA = r.info;
    edgeB = r.accent;
    glow = r.accent;
    glow2 = r.accent2;
  };

  icons = {
    name = "Tela-circle-dracula";
    variant = "dracula";
  };

  # foot [colors-dark]: tokyonight.nvim's extras/foot/tokyonight_night.ini
  terminal = {
    background = "1a1b26";
    foreground = "c0caf5";
    selection-background = "283457";
    selection-foreground = "c0caf5";
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

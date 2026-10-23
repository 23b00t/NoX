# Noto Sans Symbols 2 alone (not all of noto-fonts, 50 MB): FiraCode Nerd
# Font lacks some symbols, e.g. U+23F5 (⏵) in Claude Code's "auto mode";
# kitty drew them itself, foot needs a font (fallback in theme.foot).
# FreeMono alone (not all of freefont) for what Symbols 2 lacks too, e.g.
# U+23BF (⎿) before Claude Code's "Tip:"
{ pkgs }:
pkgs.runCommand "noto-sans-symbols2" { } ''
  install -Dm444 ${pkgs.noto-fonts}/share/fonts/noto/NotoSansSymbols2-Regular.otf \
    $out/share/fonts/noto/NotoSansSymbols2-Regular.otf
  install -Dm444 ${pkgs.freefont_ttf}/share/fonts/truetype/FreeMono.ttf \
    $out/share/fonts/truetype/FreeMono.ttf
''

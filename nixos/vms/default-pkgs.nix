{ pkgs }:
with pkgs;
[
  btop
  vim
  usbutils
  file
  tree
  lsof

  nerd-fonts.fira-code
  # 7-Zip (7zz, used by yazi to extract): zip, 7z, tar.*; the free build
  # without RAR (NoX brings no unfree software)
  _7zz
  jq
  poppler
  resvg
  imagemagick
]

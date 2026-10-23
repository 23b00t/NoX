{ pkgs }:
with pkgs;
[
  btop
  vim
  usbutils
  file
  tree
  lsof
  bibata-cursors

  nerd-fonts.fira-code
  # 7-Zip (7zz, used by yazi to extract): zip, 7z, tar.*, and RAR where
  # unfree packages are allowed (RAR extraction is unfree)
  (if pkgs.config.allowUnfree or false then _7zz-rar else _7zz)
  jq
  poppler
  resvg
  imagemagick
]

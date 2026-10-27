# Hex color math for the NoX branding (nix/nox-branding.nix), the same as
# branding/gen.py's mix(): colors are "rrggbb" without '#'.
{ lib }:
rec {
  # "rrggbb" -> [ r g b ]
  toRgb =
    hex:
    map (i: lib.fromHexString (builtins.substring i 2 hex)) [
      0
      2
      4
    ];

  # 0-255 -> two lowercase hex digits
  toHex2 = n: lib.toLower (lib.fixedWidthString 2 "0" (lib.toHexString n));

  # Python's round(): halves go to the even neighbor, so the colors match
  # gen.py's bit for bit
  round =
    x:
    let
      f = builtins.floor x;
      d = x - f;
    in
    if d > 0.5 then
      f + 1
    else if d < 0.5 then
      f
    else if lib.mod f 2 == 0 then
      f
    else
      f + 1;

  # Blend a -> b by t (0..1), per channel
  mix =
    a: b: t:
    lib.concatStrings (lib.zipListsWith (x: y: toHex2 (round (x + (y - x) * t))) (toRgb a) (toRgb b));
}

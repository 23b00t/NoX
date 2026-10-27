# NoX branding

The NoX logo, icon and wallpapers. `gen.py` holds the design and writes
`templates/`; a NoX system builds its images from those templates in Nix
(`nix/nox-branding.nix`, colors from `nox.desktop.theme`), without Python.

## Design

- Wordmark **N o X**: glossy, slightly 3D, organic letters from
  variable-width strokes ("getropft": the weight sinks to the bottom). The
  small o floats on the mid line between N and X. It is a tilted egg with an
  off-center eye.
- Flavors:
  - `organic`: the glossy logo
  - `neon`: glowing tubes along the centerlines
  - `glitch`: the glossy logo with an RGB split and shifted slices
- Icon: the o with its eye alone. It reads down to 16 px; the wordmark reads
  from 32 px up.
- Wallpaper layers, bottom to top:
  1. gradient
  2. halo behind the logo
  3. stars (fixed positions)
  4. crescent moon (upper right)
  5. scanlines
  6. vignette
  7. logo (centered, 30 % of the width)
- Shade `dark` mixes `bgDark`, `bg` and `surface` 45 % towards black (graphics
  only).
- Lock screen: the same scene with a bigger logo (45 % of the width) without
  its o. The o's place is the screen center, where swaylock draws its ring.
  The ring is always visible and drawn as a neon tube (NoX's
  `desktop/niri.nix`: radius 70, thickness 7, light core, glow-colored
  edges), so it becomes the o and lights up while typing. With the neon
  flavor, the image draws the o's soft glow behind the ring.
  `LOCK_RING`/`LOCK_REF_WIDTH` in `gen.py` mirror these settings for the
  previews (`out/<palette>/lock/preview-*.png`).

## Files

| Path | What |
|---|---|
| `gen.py` | Design, palettes, template export, local renders, verification |
| `templates/*.svg` | Logos (`logo`, `logo-flat`, `logo-mono`, `logo-neon`, `logo-glitch`), `icon`, `wallpaper-<flavor>-<decor>-<w>x<h>` and `lock-<flavor>-<decor>-<w>x<h>` with `<decor>` = plain, moon, stars or moon-stars |
| `templates/colors.json` | Derived colors: `{ "<name>": { "a", "b", "t" } }` = mix(a, b, t); `a`/`b` are roles, hex values or other entries |
| `out/`, `drafts/` | Local renders and design history (not versioned) |

Templates write every color as `#@name@`. The roles are `bgDark`, `bg`,
`surface`, `front`, `edgeA`, `edgeB`, `glow` and `glow2`; the other names come
from `colors.json`. The shade is not baked in. The Nix side, and `gen.py`'s
`resolve()`/`fill()` as its reference, does this:

1. apply the shade to the roles
2. compute `colors.json` (`nixos/lib/color.nix` rounds like Python)
3. replace the placeholders
4. render with resvg

## Commands

Needs `python3` and `resvg`; ImageMagick only for the overview sheets.

```sh
python3 gen.py templates                # after a design change: rewrite templates/
python3 gen.py verify                   # templates vs. direct build (SVG text, no rendering)
python3 gen.py render [palette ...]     # out/<palette>/ (logos, icons, default wallpaper and lock, 2560x1600)
python3 gen.py render --full <palette>  # every shade/decor/flavor (nox always gets it)
python3 gen.py render --4k ...          # also 3840x2160 (blur at 4K needs much more RAM)
```

## Palettes

`gen.py`'s `PALETTES` are the graphic roles of the desktop themes in
`nixos/desktop/themes/` (their `graphics` plus `bg`/`bgDark` from the roles).
Keep the two in sync when a theme changes. A new theme only needs a theme
file; `gen.py` needs it only for local previews.

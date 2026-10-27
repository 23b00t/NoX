#!/usr/bin/env python3
"""NoX branding: logo, icon and wallpapers as SVG/PNG for every palette, and
palette-independent templates for building them in Nix.

Design (see README.md): glossy 3D "NoX" wordmark from
variable-width strokes ("getropft"), the o floats on the mid line with an
off-center eye. Variants: organic (glossy), neon (tube), glitch (G5).
Wallpapers: gradient, halo, scanlines, vignette, optional moon and stars,
normal or dark shade.

Usage:
  python3 gen.py render [palette ...]  -> out/<palette>/ (default: all palettes;
                                          the full wallpaper set only for nox)
  python3 gen.py render --full <palette ...>   full wallpaper set for these
  python3 gen.py render --4k ...       also 3840x2160 (needs much more RAM)
  python3 gen.py templates             -> templates/*.svg, templates/colors.json
  python3 gen.py verify                templates filled vs. direct build (text), nox
Needs resvg (and ImageMagick for the overview sheets).

Templates: every color is a placeholder written as `#@name@`, filled with hex
without '#'. Base roles are @bgDark@ @bg@ @surface@ @fg@ @front@ @edgeA@
@edgeB@ @glow@ @glow2@; derived colors from mix(a, b, t) are listed in
templates/colors.json as {"<name>": {"a": .., "b": .., "t": ..}} in dependency
order (a and b are roles, hex values or earlier names). The shade is not baked
in: apply darker() to the palette before filling. resolve() and fill() are the
reference for the Nix side.
"""
import json
import math
import random
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # keep branding/ free of __pycache__

HERE = Path(__file__).parent
OUT = HERE / "out"
TEMPLATES = HERE / "templates"

# --- Palettes ----------------------------------------------------------------
# Hex without '#', same convention as nixos/desktop/theme.nix
ROLES = ["bgDark", "bg", "surface", "fg", "front", "edgeA", "edgeB", "glow", "glow2"]
PALETTES = {
    # Darker Tokyo Night with a lilac/pink tint (the NoX default)
    "nox": {
        "bgDark": "0f0b1a", "bg": "1a1030", "surface": "241640",
        "fg": "c0caf5", "front": "f4f0ff",
        "edgeA": "7aa2f7", "edgeB": "ff79c6", "glow": "ff79c6", "glow2": "bb9af7",
    },
    # Tokyo Night proper: blue/magenta/cyan, no extra pink
    "tokyo-night": {
        "bgDark": "1a1b26", "bg": "24283b", "surface": "292e42",
        "fg": "c0caf5", "front": "eef1ff",
        "edgeA": "7dcfff", "edgeB": "bb9af7", "glow": "bb9af7", "glow2": "7aa2f7",
    },
    "catppuccin-mocha": {
        "bgDark": "11111b", "bg": "1e1e2e", "surface": "313244",
        "fg": "cdd6f4", "front": "f5f3ff",
        "edgeA": "89b4fa", "edgeB": "f5c2e7", "glow": "f5c2e7", "glow2": "cba6f7",
    },
    "dracula": {
        "bgDark": "191a21", "bg": "282a36", "surface": "44475a",
        "fg": "f8f8f2", "front": "f8f8f2",
        "edgeA": "8be9fd", "edgeB": "ff79c6", "glow": "ff79c6", "glow2": "bd93f9",
    },
    # Near-black and white: neutral greys, no hue. bg is a bit lifted so the
    # dark shade still is not pure black.
    "black": {
        "bgDark": "141417", "bg": "1f1f23", "surface": "2e2e33",
        "fg": "d4d4d8", "front": "ffffff",
        "edgeA": "8a8a92", "edgeB": "c8c8cf", "glow": "e6e6ea", "glow2": "c4c4cc",
    },
}

# --- Options -----------------------------------------------------------------
FLAVORS = ["organic", "neon", "glitch"]
DECORS = ["plain", "moon", "stars", "moon-stars"]
SHADES = ["normal", "dark"]
WALLPAPER_SIZES = [(3840, 2160), (2560, 1600)]
DEFAULT = dict(flavor="organic", decor="moon-stars", shade="dark")

# --- Design parameters -------------------------------------------------------
FILL = (0.3, 0.65, 0.25)  # front fill: front -> glow2 -> glow
GAP = 3  # space between N|o and o|X
KERN_X = 15  # pulls only the X towards the o (its arms cross at mid height)
DEPTH = 5  # extrusion layers
HALF = 16  # max half stroke width, used for spacing and bounds
DARK = 0.45  # dark shade: background colors mixed this far towards black
GLITCH_SPLIT = 4  # RGB split of the glitch logo
GLITCH_BANDS = [(6, 12, 10), (46, 7, -7), (78, 10, 5)]  # (y, height, x shift)
ICON_SIZES = [16, 24, 32, 48, 64, 128, 256]
# Lock screen: the logo without its o, the o's center on the screen center,
# where swaylock draws its ring (the o). The ring settings live in NoX's
# desktop/niri.nix; LOCK_RING mirrors them for the previews (radius and
# thickness in logical px at LOCK_REF_WIDTH logical px).
LOCK_LOGO_WIDTH = 0.45  # of the image width; the o gap then fits ring radii
LOCK_RING = (70, 7)
LOCK_REF_WIDTH = 1920
DEFAULT_LOCK = dict(flavor="neon", decor="moon-stars", shade="dark")


# --- Colors ------------------------------------------------------------------
def _mix_hex(a, b, t):
    ca = [int(a[i:i + 2], 16) for i in (0, 2, 4)]
    cb = [int(b[i:i + 2], 16) for i in (0, 2, 4)]
    return "".join(f"{round(x + (y - x) * t):02x}" for x, y in zip(ca, cb))


DERIVED = {}  # placeholder name -> {"a", "b", "t"}, filled while exporting


def mix(a, b, t):
    """Blend hex colors a -> b by t (0..1). With placeholders ("@role@") it
    returns a new placeholder and records how to compute it."""
    if not (a.startswith("@") or b.startswith("@")):
        return _mix_hex(a, b, t)
    an, bn = a.strip("@"), b.strip("@")
    name = f"{an}~{bn}~{round(t * 1000)}"
    DERIVED.setdefault(name, {"a": an, "b": bn, "t": t})
    return f"@{name}@"


def darker(p, t=DARK):
    """The dark shade: background colors pulled towards black."""
    q = dict(p)
    for k in ("bgDark", "bg", "surface"):
        q[k] = mix(p[k], "000000", t)
    return q


def shaded(p, shade):
    return darker(p) if shade == "dark" else p


# --- Geometry ----------------------------------------------------------------
# A stroke is (4 cubic Bezier control points, (w_start, w_mid, w_end)).
# Cap height is 100 (y 0..100).
N_STROKES = [([(0, 100), (0, 66), (1, 33), (0, 0)], (32, 26, 19)),
             ([(0, 0), (22, 28), (38, 64), (60, 100)], (19, 24, 31)),
             ([(60, 100), (60, 66), (59, 33), (60, 0)], (32, 26, 19))]
X_STROKES = [([(0, 0), (28, 24), (38, 74), (64, 100)], (19, 25, 32)),
             ([(64, 0), (36, 24), (26, 74), (0, 100)], (19, 25, 32))]


def bez(pts, t):
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = pts
    u = 1 - t
    return (u**3 * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t**3 * x3,
            u**3 * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t**3 * y3)


def width_at(prof, t):
    w0, wm, w1 = prof
    return w0 + (w1 - w0) * t + (wm - (w0 + w1) / 2) * 4 * t * (1 - t)


def ellipse(cx, cy, rx, ry):
    return (f"M{cx - rx:.2f},{cy:.2f} a{rx:.2f},{ry:.2f} 0 1,0 {2 * rx:.2f},0 "
            f"a{rx:.2f},{ry:.2f} 0 1,0 {-2 * rx:.2f},0 Z")


def stroke_outline(pts, prof, n=48):
    """Filled outline of a variable-width stroke, plus round end caps."""
    left, right = [], []
    for i in range(n + 1):
        t = i / n
        x, y = bez(pts, t)
        xa, ya = bez(pts, max(0, t - 1e-3))
        xb, yb = bez(pts, min(1, t + 1e-3))
        dx, dy = xb - xa, yb - ya
        ln = math.hypot(dx, dy) or 1
        nx, ny = -dy / ln, dx / ln
        h = width_at(prof, t) / 2
        left.append((x + nx * h, y + ny * h))
        right.append((x - nx * h, y - ny * h))
    poly = left + right[::-1]
    d = "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in poly) + " Z"
    caps = []
    for t in (0, 1):
        x, y = bez(pts, t)
        r = width_at(prof, t) / 2
        caps.append(ellipse(x, y, r, r))
    return [d] + caps


def egg(cx, cy, r, eye=1.0):
    """The o: slightly tilted egg with an off-center eye (one evenodd path)."""
    ry = r * 0.94
    d = (ellipse(cx, cy, r, ry) + " "
         + ellipse(cx + r * 0.22, cy - r * 0.24, r * 0.36 * eye, r * 0.28 * eye))
    return f'<path fill-rule="evenodd" d="{d}" transform="rotate(-14 {cx} {cy})"/>'


O_R = 27
O_CENTER = (60 + HALF + GAP + O_R, 50)  # the o floats on the mid line


def wordmark(r=O_R, o=True):
    """Returns (filled outline paths, centerline paths, width); o=False
    leaves the o out (lock screen: swaylock's ring takes its place)."""
    o_cx, o_cy = O_CENTER
    x_off = o_cx + r + GAP + HALF - KERN_X
    x = [([(px + x_off, py) for px, py in pts], prof) for pts, prof in X_STROKES]
    outlines = []
    for pts, prof in N_STROKES + x:
        outlines += stroke_outline(pts, prof)
    paths = [f'<path d="{d}"/>' for d in outlines] + ([egg(o_cx, o_cy, r)] if o else [])
    center = []
    for pts, _ in N_STROKES + x:
        (a, b), (c, d), (e, f), (g, h) = pts
        center.append(f"M{a},{b} C{c},{d} {e},{f} {g},{h}")
    if o:
        center.append(o_centerline())
    return paths, center, x_off + 64 + HALF


def o_centerline():
    """The o's neon tube (also its halo on the lock screen)."""
    return ellipse(*O_CENTER, O_R * 0.7, O_R * 0.94 * 0.7)


# Logo geometry spans x -HALF..W, y -HALF..100+HALF
W = wordmark()[2]
BOUNDS = (-HALF, -HALF, W, 100 + HALF)


# --- Logo variants: each returns (defs, body) ---------------------------------
def base_defs(pid, p, o=True):
    paths, center, _ = wordmark(o=o)
    x0, y0, x1, y1 = BOUNDS
    defs = [f'<g id="{pid}-shape">' + "".join(paths) + "</g>",
            f'<g id="{pid}-center" fill="none" stroke-linecap="round" '
            'stroke-linejoin="round">'
            + "".join(f'<path d="{d}"/>' for d in center) + "</g>",
            f'<linearGradient id="{pid}-front" gradientUnits="userSpaceOnUse" '
            f'x1="{x0}" y1="{y0}" x2="{x1}" y2="{y1}">'
            f'<stop offset="0" stop-color="#{mix(p["front"], p["glow2"], FILL[0])}"/>'
            f'<stop offset="0.5" stop-color="#{mix(p["front"], p["glow2"], FILL[1])}"/>'
            f'<stop offset="1" stop-color="#{mix(p["glow2"], p["glow"], FILL[2])}"/>'
            '</linearGradient>']
    for name, sd in (("blur", 14), ("blur2", 34), ("tight", 4), ("mid", 9)):
        defs.append(
            f'<filter id="{pid}-{name}" x="-50%" y="-50%" width="200%" height="200%">'
            f'<feGaussianBlur stdDeviation="{sd}"/></filter>')
    return defs


def glow(pid, p):
    return [f'<use href="#{pid}-shape" fill="#{p["glow2"]}" '
            f'opacity="0.45" filter="url(#{pid}-blur2)"/>',
            f'<use href="#{pid}-shape" fill="#{p["glow"]}" '
            f'opacity="0.55" filter="url(#{pid}-blur)" transform="translate(3,4)"/>']


def logo_glossy(pid, p, o=True):
    """Main logo: glow, extrusion blue -> pink, gradient front, gloss."""
    x0, y0, x1, y1 = BOUNDS
    defs = base_defs(pid, p, o)
    defs.append(
        f'<linearGradient id="{pid}-gloss" gradientUnits="userSpaceOnUse" '
        f'x1="0" y1="{y0}" x2="0" y2="{y1}">'
        '<stop offset="0" stop-color="#fff" stop-opacity="0.5"/>'
        '<stop offset="0.45" stop-color="#fff" stop-opacity="0.08"/>'
        '<stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>')
    defs.append(
        f'<mask id="{pid}-mask" maskUnits="userSpaceOnUse" '
        f'x="{x0 - 10}" y="{y0 - 10}" width="{x1 - x0 + 20}" height="{y1 - y0 + 20}">'
        f'<use href="#{pid}-shape" fill="#fff"/></mask>')
    body = glow(pid, p)
    for i in range(DEPTH, 0, -1):
        t = i / DEPTH
        a = mix(p["edgeA"], p["bgDark"], 0.2 + 0.4 * t)
        b = mix(p["edgeB"], p["bgDark"], 0.2 + 0.4 * t)
        gid = f"{pid}-edge{i}"
        defs.append(
            f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" '
            f'x1="{x0}" y1="0" x2="{x1}" y2="0">'
            f'<stop offset="0" stop-color="#{a}"/>'
            f'<stop offset="1" stop-color="#{b}"/></linearGradient>')
        body.append(f'<use href="#{pid}-shape" fill="url(#{gid})" '
                    f'transform="translate({i * 0.8:.2f},{i * 1.0:.2f})"/>')
    body.append(f'<use href="#{pid}-shape" fill="url(#{pid}-front)"/>')
    body.append(f'<rect x="{x0 - 10}" y="{y0 - 10}" width="{x1 - x0 + 20}" '
                f'height="{y1 - y0 + 20}" fill="url(#{pid}-gloss)" mask="url(#{pid}-mask)"/>')
    return defs, body


def logo_flat(pid, p, o=True):
    """Gradient front only: UI, print."""
    return base_defs(pid, p, o), [f'<use href="#{pid}-shape" fill="url(#{pid}-front)"/>']


def logo_mono(pid, p, o=True):
    """One color (palette front)."""
    return base_defs(pid, p, o), [f'<use href="#{pid}-shape" fill="#{p["front"]}"/>']


def logo_neon(pid, p, o=True):
    """Glowing neon tubes along the centerlines, no body. Without the o, its
    soft glow stays: swaylock's ring is the tube's core."""
    g, g2 = p["glow"], p["glow2"]
    c = f'href="#{pid}-center"'
    defs = base_defs(pid, p, o)
    halo = []
    if not o:
        # Filter region in user space: the default one (relative to the
        # small ring) would cut the blur off square
        x0, y0, x1, y1 = BOUNDS
        for name, sd in (("hblur", 14), ("hmid", 9)):
            defs.append(f'<filter id="{pid}-{name}" filterUnits="userSpaceOnUse" '
                        f'x="{x0 - 60}" y="{y0 - 60}" width="{x1 - x0 + 120}" '
                        f'height="{y1 - y0 + 120}"><feGaussianBlur stdDeviation="{sd}"/></filter>')
        halo = [
            f'<path d="{o_centerline()}" fill="none" stroke="#{g2}" stroke-width="22" '
            f'opacity="0.35" filter="url(#{pid}-hblur)"/>',
            f'<path d="{o_centerline()}" fill="none" stroke="#{g}" stroke-width="14" '
            f'opacity="0.6" filter="url(#{pid}-hmid)"/>',
        ]
    return defs, halo + [
        f'<use {c} stroke="#{g2}" stroke-width="22" opacity="0.35" filter="url(#{pid}-blur)"/>',
        f'<use {c} stroke="#{g}" stroke-width="14" opacity="0.8" filter="url(#{pid}-mid)"/>',
        f'<use {c} stroke="#{g}" stroke-width="9" opacity="0.9" filter="url(#{pid}-tight)"/>',
        f'<use {c} stroke="#{mix(g, "ffffff", 0.55)}" stroke-width="6"/>',
        f'<use {c} stroke="#ffffff" stroke-width="2.5" opacity="0.9"/>',
    ]


def logo_glitch(pid, p, o=True):
    """Glossy logo with RGB split; whole slices (split and body) are shifted."""
    x0, y0, x1, y1 = BOUNDS
    defs, body = logo_glossy(pid, p, o)
    halo, layers = body[:2], body[2:]
    s = GLITCH_SPLIT
    rgb = [f'<use href="#{pid}-shape" fill="#{p["edgeA"]}" opacity="0.9" '
           f'transform="translate({-s},{-s * 0.25})"/>',
           f'<use href="#{pid}-shape" fill="#{p["glow"]}" opacity="0.9" '
           f'transform="translate({s},{s * 0.25})"/>']
    defs.append(f'<g id="{pid}-stack">' + "".join(rgb + layers) + "</g>")
    m = 40
    holes = "".join(f'<rect x="{x0 - m}" y="{y}" width="{x1 - x0 + 2 * m}" height="{h}" fill="#000"/>'
                    for y, h, _ in GLITCH_BANDS)
    defs.append(f'<mask id="{pid}-cut" maskUnits="userSpaceOnUse" x="{x0 - m}" y="{y0 - m}" '
                f'width="{x1 - x0 + 2 * m}" height="{y1 - y0 + 2 * m}">'
                f'<rect x="{x0 - m}" y="{y0 - m}" width="{x1 - x0 + 2 * m}" '
                f'height="{y1 - y0 + 2 * m}" fill="#fff"/>{holes}</mask>')
    out = halo + [f'<use href="#{pid}-stack" mask="url(#{pid}-cut)"/>']
    for i, (y, h, dx) in enumerate(GLITCH_BANDS):
        # Overlap the cut by half a unit on each side: anti-aliased mask and
        # clip edges would otherwise leave hairline seams
        defs.append(f'<clipPath id="{pid}-band{i}"><rect x="{x0 - m}" y="{y - 0.5}" '
                    f'width="{x1 - x0 + 2 * m}" height="{h + 1}"/></clipPath>')
        out.append(f'<g clip-path="url(#{pid}-band{i})"><use href="#{pid}-stack" '
                   f'transform="translate({dx},0)"/></g>')
    return defs, out


# name -> (builder, margin around BOUNDS for the glow, in logo units)
LOGOS = {
    "logo": (logo_glossy, 70),
    "logo-flat": (logo_flat, 4),
    "logo-mono": (logo_mono, 4),
    "logo-neon": (logo_neon, 50),
    "logo-glitch": (logo_glitch, 60),
}
FLAVOR_LOGO = {"organic": "logo", "neon": "logo-neon", "glitch": "logo-glitch"}


# --- Documents ---------------------------------------------------------------
def svg_doc(w, h, defs, body, view=None):
    vb = view or f"0 0 {w} {h}"
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
            f'viewBox="{vb}">\n<defs>\n' + "\n".join(defs) + "\n</defs>\n"
            + "\n".join(body) + "\n</svg>\n")


def logo_doc(name, p, height=400):
    build, m = LOGOS[name]
    defs, body = build("l", p)
    x0, y0, x1, y1 = BOUNDS
    vw, vh = x1 - x0 + 2 * m, y1 - y0 + 2 * m
    return svg_doc(round(height * vw / vh), height, defs, body,
                   f"{x0 - m} {y0 - m} {vw} {vh}")


def icon_doc(p):
    """Small mark: the o with its eye (opened up a bit), front gradient and one
    edge layer. Reads down to 16 px."""
    shape = egg(50, 50, 44, eye=1.2)
    defs = ['<linearGradient id="f" x1="0" y1="0" x2="1" y2="1">'
            f'<stop offset="0" stop-color="#{mix(p["front"], p["glow2"], FILL[0])}"/>'
            f'<stop offset="0.5" stop-color="#{mix(p["front"], p["glow2"], FILL[1])}"/>'
            f'<stop offset="1" stop-color="#{mix(p["glow2"], p["glow"], FILL[2])}"/>'
            '</linearGradient>',
            '<linearGradient id="e" x1="0" y1="0" x2="1" y2="0">'
            f'<stop offset="0" stop-color="#{mix(p["edgeA"], p["bgDark"], 0.3)}"/>'
            f'<stop offset="1" stop-color="#{mix(p["edgeB"], p["bgDark"], 0.3)}"/>'
            '</linearGradient>',
            f'<g id="m">{shape}</g>',
            # Gradients on a full rect, masked by the mark: on the path itself
            # a gradient would follow each piece's bounding box
            '<mask id="mk" maskUnits="userSpaceOnUse" x="0" y="0" width="100" height="100">'
            '<use href="#m" fill="#fff"/></mask>',
            '<mask id="mke" maskUnits="userSpaceOnUse" x="0" y="0" width="100" height="100">'
            '<use href="#m" fill="#fff" transform="translate(1.6,2)"/></mask>']
    body = ['<rect width="100" height="100" fill="url(#e)" mask="url(#mke)"/>',
            '<rect width="100" height="100" fill="url(#f)" mask="url(#mk)"/>']
    return svg_doc(100, 100, defs, body)


def placed(name, p, pid, cx, cy, width, o=True):
    """Logo with the given width, centered at (cx, cy); without the o, its
    gap is centered there instead (lock screen)."""
    defs, body = LOGOS[name][0](pid, p, o)
    x0, y0, x1, y1 = BOUNDS
    s = width / (x1 - x0)
    ax, ay = ((x0 + x1) / 2, (y0 + y1) / 2) if o else O_CENTER
    tx, ty = cx - ax * s, cy - ay * s
    head = f'<g transform="translate({tx:.2f},{ty:.2f}) scale({s:.4f})">'
    return defs, [head] + body + ["</g>"]


def background(p, w, h):
    """Gradient, soft halo behind the logo, scanlines, vignette."""
    line = max(2, round(h / 540))  # scanline period: 4px at 4K
    defs = [
        '<linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1">'
        f'<stop offset="0" stop-color="#{p["bgDark"]}"/>'
        f'<stop offset="0.6" stop-color="#{p["bg"]}"/>'
        f'<stop offset="1" stop-color="#{mix(p["bg"], p["glow2"], 0.12)}"/></linearGradient>',
        '<radialGradient id="halo" cx="0.5" cy="0.5" r="0.45">'
        f'<stop offset="0" stop-color="#{p["glow2"]}" stop-opacity="0.16"/>'
        f'<stop offset="1" stop-color="#{p["glow2"]}" stop-opacity="0"/></radialGradient>',
        '<radialGradient id="vignette" cx="0.5" cy="0.5" r="0.75">'
        '<stop offset="0.55" stop-color="#000" stop-opacity="0"/>'
        '<stop offset="1" stop-color="#000" stop-opacity="0.45"/></radialGradient>',
        f'<pattern id="scan" width="{line * 2}" height="{line * 2}" patternUnits="userSpaceOnUse">'
        f'<rect width="{line * 2}" height="{line}" fill="#000" opacity="0.22"/></pattern>',
    ]
    body = [f'<rect width="{w}" height="{h}" fill="url(#bg)"/>',
            f'<rect width="{w}" height="{h}" fill="url(#halo)"/>',
            f'<rect width="{w}" height="{h}" fill="url(#scan)"/>',
            f'<rect width="{w}" height="{h}" fill="url(#vignette)"/>']
    return defs, body


def moon_geometry(w, h):
    s = h / 2160
    return w * 0.79, h * 0.2, 150 * s


def moon(p, w, h):
    """Crescent in the upper right: lit sickle, faint earthshine, glow."""
    s = h / 2160
    cx, cy, r = moon_geometry(w, h)
    # The shadow disc is shifted up-right, the lit sickle faces down-left
    sx, sy, sr = cx + r * 0.38, cy - r * 0.22, r * 0.9
    defs = [
        f'<mask id="m-cut" maskUnits="userSpaceOnUse" x="0" y="0" width="{w}" height="{h}">'
        f'<rect width="{w}" height="{h}" fill="#fff"/>'
        f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="{sr:.1f}" fill="#000"/></mask>',
        f'<radialGradient id="m-lit" gradientUnits="userSpaceOnUse" cx="{cx - r * 0.5:.1f}" '
        f'cy="{cy + r * 0.4:.1f}" r="{r * 1.6:.1f}">'
        f'<stop offset="0" stop-color="#{p["front"]}"/>'
        f'<stop offset="0.6" stop-color="#{mix(p["front"], p["glow2"], 0.45)}"/>'
        f'<stop offset="1" stop-color="#{mix(p["glow2"], p["glow"], 0.4)}"/></radialGradient>',
        f'<filter id="m-glow" x="-100%" y="-100%" width="300%" height="300%">'
        f'<feGaussianBlur stdDeviation="{28 * s:.1f}"/></filter>',
        f'<filter id="m-glow2" x="-150%" y="-150%" width="400%" height="400%">'
        f'<feGaussianBlur stdDeviation="{90 * s:.1f}"/></filter>',
    ]
    body = [
        f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r * 1.3:.1f}" fill="#{p["glow2"]}" '
        'opacity="0.18" filter="url(#m-glow2)"/>',
        f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="#{p["glow2"]}" opacity="0.07"/>',
        f'<g filter="url(#m-glow)" opacity="0.7"><circle cx="{cx:.1f}" cy="{cy:.1f}" '
        f'r="{r:.1f}" fill="#{p["glow"]}" mask="url(#m-cut)"/></g>',
        f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="url(#m-lit)" mask="url(#m-cut)"/>',
    ]
    return defs, body


SPARKLE = ("M0,-1 Q0.12,-0.12 1,0 Q0.12,0.12 0,1 "
           "Q-0.12,0.12 -1,0 Q-0.12,-0.12 0,-1 Z")


def stars(p, w, h, seed=7, logo_width=0.3):
    """Few 4-point sparkles and small dots, kept off the logo, the moon's place
    (also without a moon, so the stars stay put) and the screen edges."""
    s = h / 2160
    rnd = random.Random(seed)
    mx, my, mr = moon_geometry(w, h)
    lw = w * logo_width * 0.62  # logo box half sizes + margin
    lh = lw * 0.5

    def free(x, y, pad):
        if abs(x - w / 2) < lw + pad and abs(y - h / 2) < lh + pad:
            return False
        return (x - mx) ** 2 + (y - my) ** 2 > (mr * 2.2 + pad) ** 2

    def place(pad, ymax):
        while True:
            m = 40 * s
            x, y = rnd.uniform(m, w - m), rnd.uniform(m, h * ymax)
            if free(x, y, pad):
                return x, y

    defs = [f'<filter id="s-glow" x="-200%" y="-200%" width="500%" height="500%">'
            f'<feGaussianBlur stdDeviation="{6 * s:.1f}"/></filter>']
    body = []
    tints = [p["front"], mix(p["front"], p["glow2"], 0.5), mix(p["front"], p["glow"], 0.4)]
    for _ in range(90):  # dots, denser towards the top
        x, y = place(10 * s, rnd.choice((0.55, 0.8, 1.0)))
        r = rnd.uniform(1.2, 3.2) * s
        body.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.2f}" '
                    f'fill="#{rnd.choice(tints)}" opacity="{rnd.uniform(0.25, 0.75):.2f}"/>')
    for _ in range(11):  # sparkles
        x, y = place(60 * s, rnd.choice((0.6, 0.85)))
        size = rnd.uniform(9, 24) * s
        c = rnd.choice(tints)
        t = f'translate({x:.1f},{y:.1f}) scale({size:.2f})'
        body.append(f'<path d="{SPARKLE}" transform="{t} scale(1.6)" fill="#{p["glow2"]}" '
                    'opacity="0.55" filter="url(#s-glow)"/>')
        body.append(f'<path d="{SPARKLE}" transform="{t}" fill="#{c}" opacity="0.9"/>')
    return defs, body


def wallpaper_doc(flavor, decor, p, w, h, lock=False):
    """The wallpaper; lock=True: the lock screen image (bigger logo without
    its o, the gap on the screen center for swaylock's ring)."""
    logo_width = LOCK_LOGO_WIDTH if lock else 0.3
    defs, body = background(p, w, h)
    sky_defs, sky = [], []  # stars and moon sit under the scanlines and vignette
    if "stars" in decor:
        d, b = stars(p, w, h, logo_width=logo_width)
        sky_defs += d
        sky += b
    if "moon" in decor:
        d, b = moon(p, w, h)
        sky_defs += d
        sky += b
    ld, lb = placed(FLAVOR_LOGO[flavor], p, "w", w / 2, h / 2, w * logo_width, o=not lock)
    return svg_doc(w, h, defs + sky_defs + ld, body[:2] + sky + body[2:] + lb)


# --- Templates ---------------------------------------------------------------
PLACEHOLDERS = {r: f"@{r}@" for r in ROLES}


def template_docs():
    """{file name: svg} for every template, built with placeholder colors."""
    p = PLACEHOLDERS
    docs = {f"{name}.svg": logo_doc(name, p) for name in LOGOS}
    docs["icon.svg"] = icon_doc(p)
    for w, h in WALLPAPER_SIZES:
        for flavor in FLAVORS:
            for decor in DECORS:
                docs[f"wallpaper-{flavor}-{decor}-{w}x{h}.svg"] = wallpaper_doc(flavor, decor, p, w, h)
                docs[f"lock-{flavor}-{decor}-{w}x{h}.svg"] = wallpaper_doc(
                    flavor, decor, p, w, h, lock=True)
    return docs


def export_templates():
    DERIVED.clear()
    docs = template_docs()
    TEMPLATES.mkdir(exist_ok=True)
    for old in TEMPLATES.glob("*.svg"):
        old.unlink()
    for name, svg in docs.items():
        (TEMPLATES / name).write_text(svg)
    (TEMPLATES / "colors.json").write_text(json.dumps(DERIVED, indent=2) + "\n")
    print(f"{len(docs)} templates, {len(DERIVED)} derived colors -> {TEMPLATES}")


def resolve(palette, shade="normal"):
    """Base roles (after the shade) plus all derived colors from colors.json."""
    colors = dict(shaded(palette, shade))
    for name, d in json.loads((TEMPLATES / "colors.json").read_text()).items():
        colors[name] = _mix_hex(colors.get(d["a"], d["a"]), colors.get(d["b"], d["b"]), d["t"])
    return colors


def fill(svg, colors):
    for name, value in colors.items():
        svg = svg.replace(f"@{name}@", value)
    if "@" in svg:
        raise ValueError("unfilled placeholder left")
    return svg


# --- Output ------------------------------------------------------------------
def render_png(svg_path, png_path, size=None):
    wh = ["-w", str(size), "-h", str(size)] if size else []
    subprocess.run(["resvg", *wh, str(svg_path), str(png_path)], check=True)


def from_template(template, palette, shade, svg_path, keep_svg=True, size=None):
    """Fill a template and render it: exactly what the Nix side will do."""
    svg_path.parent.mkdir(parents=True, exist_ok=True)
    svg_path.write_text(fill((TEMPLATES / template).read_text(), resolve(palette, shade)))
    render_png(svg_path, svg_path.with_suffix(".png"), size)
    if not keep_svg:
        svg_path.unlink()
    print(svg_path.with_suffix(".png"))


def render(name, full, sizes):
    """out/<name>/logo/: logos (SVG + PNG) and icon sizes.
    out/<name>/wallpaper/<shade>/<decor>/<flavor>-<w>x<h>.png: the full set,
    or only the default (dark, moon-stars, organic) unless full.
    out/<name>/lock/: the default lock image and a preview with the ring."""
    p = PALETTES[name]
    d = OUT / name
    for logo in LOGOS:
        from_template(f"{logo}.svg", p, "normal", d / "logo" / f"{logo}.svg")
    from_template("icon.svg", p, "normal", d / "logo" / "icon.svg")
    for size in ICON_SIZES:
        from_template("icon.svg", p, "normal", d / "logo" / f"icon-{size}.svg",
                      keep_svg=False, size=size)
    combos = ([(s, dc, f) for s in SHADES for dc in DECORS for f in FLAVORS] if full
              else [(DEFAULT["shade"], DEFAULT["decor"], DEFAULT["flavor"])])
    for shade, decor, flavor in combos:
        for w, h in sizes:
            from_template(f"wallpaper-{flavor}-{decor}-{w}x{h}.svg", p, shade,
                          d / "wallpaper" / shade / decor / f"{flavor}-{w}x{h}.svg",
                          keep_svg=False)
    lk = DEFAULT_LOCK
    for w, h in sizes:
        img = d / "lock" / lk["shade"] / lk["decor"] / f"{lk['flavor']}-{w}x{h}.svg"
        from_template(f"lock-{lk['flavor']}-{lk['decor']}-{w}x{h}.svg", p, lk["shade"], img,
                      keep_svg=False)
        lock_preview(p, img.with_suffix(".png"), d / "lock" / f"preview-{w}x{h}.png")


def lock_preview(p, image, out):
    """The lock image with swaylock's idle ring drawn on (NoX's settings in
    desktop/niri.nix: core, pink edge lines), as on a LOCK_REF_WIDTH wide
    output."""
    w = int(subprocess.run(["magick", "identify", "-format", "%w", str(image)],
                           capture_output=True, text=True).stdout)
    h = int(subprocess.run(["magick", "identify", "-format", "%h", str(image)],
                           capture_output=True, text=True).stdout)
    k = w / LOCK_REF_WIDTH
    radius, thick = LOCK_RING[0] * k, LOCK_RING[1] * k
    cx, cy = w / 2, h / 2
    core = _mix_hex(p["glow"], "ffffff", 0.55)

    def ring(r, color, width):
        return ["-fill", "none", "-stroke", f"#{color}", "-strokewidth", f"{width:.1f}",
                "-draw", f"circle {cx},{cy} {cx + r},{cy}"]
    subprocess.run(["magick", str(image),
                    *ring(radius, core, thick),
                    *ring(radius + thick / 2, p["glow"], 2 * k),
                    *ring(radius - thick / 2, p["glow"], 2 * k),
                    str(out)], check=True)
    print(out)


def overviews(names):
    """out/overview.png: the default wallpaper of every palette;
    out/<palette>/overview.png: all wallpaper variants (if rendered)."""
    tiles = []
    for name in names:
        dflt = (OUT / name / "wallpaper" / DEFAULT["shade"] / DEFAULT["decor"]
                / f"{DEFAULT['flavor']}-2560x1600.png")
        tiles.append(str(dflt))
        full = sorted((OUT / name / "wallpaper").glob("*/*/*-2560x1600.png"))
        if len(full) > 1:
            order = [OUT / name / "wallpaper" / s / dc / f"{f}-2560x1600.png"
                     for s in SHADES for dc in DECORS for f in FLAVORS]
            labels = [f"{s} / {dc} / {f}" for s in SHADES for dc in DECORS for f in FLAVORS]
            args = ["magick", "montage"]
            for path, label in zip(order, labels):
                args += ["-label", label, str(path)]
            subprocess.run(args + ["-tile", "6x", "-geometry", "480x300+4+4", "-pointsize", "14",
                                   "-background", "#000000", "-fill", "#cccccc",
                                   "-font", _font(), str(OUT / name / "overview.png")], check=True)
    args = ["magick", "montage"]
    for name, t in zip(names, tiles):
        args += ["-label", name, t]
    subprocess.run(args + ["-tile", "3x", "-geometry", "960x600+6+6", "-pointsize", "20",
                           "-background", "#000000", "-fill", "#cccccc", "-font", _font(),
                           str(OUT / "overview.png")], check=True)


def _font():
    # ImageMagick's default font renders nothing here; ask fontconfig for a file
    return subprocess.run(["fc-match", "-f", "%{file}", "DejaVu Sans"],
                          capture_output=True, text=True).stdout


def verify():
    """Templates filled with nox must equal a direct build character for
    character (catches templates that are out of date with the code). Text
    only, nothing is rendered: same SVG text, same pixels."""
    p = PALETTES["nox"]
    cases = [(f"{n}.svg", "normal", lambda n=n: logo_doc(n, p)) for n in LOGOS]
    cases.append(("icon.svg", "normal", lambda: icon_doc(p)))
    for w, h in WALLPAPER_SIZES:
        for shade in SHADES:
            for flavor in FLAVORS:
                for decor in DECORS:
                    for kind, lock in (("wallpaper", False), ("lock", True)):
                        cases.append((f"{kind}-{flavor}-{decor}-{w}x{h}.svg", shade,
                                      lambda f=flavor, dc=decor, s=shade, lk=lock, w=w, h=h:
                                      wallpaper_doc(f, dc, shaded(p, s), w, h, lock=lk)))
    failed = [tpl for tpl, shade, direct in cases
              if fill((TEMPLATES / tpl).read_text(), resolve(p, shade)) != direct()]
    for tpl in failed:
        print("DIFF", tpl)
    print(f"{len(cases) - len(failed)}/{len(cases)} ok")
    sys.exit(1 if failed else 0)

if __name__ == "__main__":
    args = sys.argv[1:] or ["render"]
    cmd = args.pop(0)
    if cmd == "templates":
        export_templates()
    elif cmd == "render":
        full = "--full" in args
        # 4K renders with blur need a lot of RAM: local previews in 2560x1600
        # unless asked for (the Nix package renders nox.desktop.theme.resolution)
        sizes = WALLPAPER_SIZES if "--4k" in args else [(2560, 1600)]
        names = [a for a in args if not a.startswith("--")] or list(PALETTES)
        for name in names:
            render(name, full or name == "nox", sizes)
        overviews([n for n in PALETTES if (OUT / n).exists()])
    elif cmd == "verify":
        verify()
    else:
        sys.exit(__doc__)

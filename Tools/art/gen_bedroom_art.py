#!/usr/bin/env python3
"""Generate the bedroom's poster and rug artwork.

Original artwork, drawn procedurally — nothing traced, sampled or derived from
a real poster or textile. That keeps the room free of the licensing question
every "90s poster" image search runs into, and it means the art can be retuned
by editing numbers rather than by re-downloading.

    python3 Tools/art/gen_bedroom_art.py

Writes into RetroXR/imported-assets/bedroom/generated/. Godot imports these with
default settings; none of them is a normal map, so no .import fixups are needed
(unlike the ambientCG material set, which has to be told compress/normal_map=1).
"""

import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "RetroXR",
                   "imported-assets", "bedroom", "generated")


def _grain(img, amount=6, seed=0):
    """Break up flat fills so they do not band under the room's warm lighting."""
    rnd = random.Random(seed)
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y][:3]
            n = rnd.randint(-amount, amount)
            px[x, y] = (max(0, min(255, r + n)),
                        max(0, min(255, g + n)),
                        max(0, min(255, b + n)))
    return img


# --------------------------------------------------------------------------
# Poster 1 — Memphis confetti. Squiggles, triangles and dots on cream: the
# look that was on every notebook, cup and bedroom wall around 1990.
# --------------------------------------------------------------------------
def poster_memphis(w=640, h=854, seed=7):
    rnd = random.Random(seed)
    img = Image.new("RGB", (w, h), (238, 232, 217))
    d = ImageDraw.Draw(img)
    palette = [(0, 156, 166), (222, 45, 122), (247, 190, 45), (30, 30, 38),
               (120, 90, 190)]

    for _ in range(90):
        kind = rnd.choice(["tri", "dot", "zig", "bar", "ring"])
        c = rnd.choice(palette)
        x, y = rnd.randint(0, w), rnd.randint(0, h)
        s = rnd.randint(14, 54)
        if kind == "tri":
            a = rnd.uniform(0, math.tau)
            pts = [(x + s * math.cos(a + i * math.tau / 3),
                    y + s * math.sin(a + i * math.tau / 3)) for i in range(3)]
            d.polygon(pts, fill=c)
        elif kind == "dot":
            d.ellipse([x - s // 3, y - s // 3, x + s // 3, y + s // 3], fill=c)
        elif kind == "ring":
            d.ellipse([x - s // 2, y - s // 2, x + s // 2, y + s // 2],
                      outline=c, width=max(3, s // 8))
        elif kind == "bar":
            a = rnd.choice([0, 45, 90, 135])
            dx = s * math.cos(math.radians(a))
            dy = s * math.sin(math.radians(a))
            d.line([x - dx, y - dy, x + dx, y + dy], fill=c,
                   width=rnd.randint(5, 12))
        else:  # zig
            pts = []
            px_, py_ = x, y
            for i in range(rnd.randint(3, 6)):
                px_ += rnd.randint(14, 30) * rnd.choice([-1, 1])
                py_ += rnd.randint(14, 30)
                pts.append((px_, py_))
            if len(pts) > 1:
                d.line(pts, fill=c, width=rnd.randint(5, 10), joint="curve")

    # A wide cream margin keeps it reading as a printed poster rather than a
    # full-bleed texture.
    m = int(w * 0.055)
    d.rectangle([0, 0, w, m], fill=(238, 232, 217))
    d.rectangle([0, h - m, w, h], fill=(238, 232, 217))
    d.rectangle([0, 0, m, h], fill=(238, 232, 217))
    d.rectangle([w - m, 0, w, h], fill=(238, 232, 217))
    d.rectangle([m, m, w - m, h - m], outline=(30, 30, 38), width=3)
    return _grain(img, 4, seed)


# --------------------------------------------------------------------------
# Poster 2 — grid sunset. Banded sun over a vanishing-point grid.
# --------------------------------------------------------------------------
def poster_grid(w=640, h=854, seed=11):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    horizon = int(h * 0.60)

    for y in range(horizon):                       # sky gradient
        t = y / horizon
        d.line([0, y, w, y], fill=(int(28 + 190 * t ** 2),
                                   int(10 + 40 * t ** 2),
                                   int(70 + 60 * t)))
    for y in range(horizon, h):                    # ground
        t = (y - horizon) / (h - horizon)
        d.line([0, y, w, y], fill=(int(20 + 30 * t), 6, int(40 + 30 * t)))

    cx, cy, r = w // 2, int(horizon * 0.94), int(w * 0.30)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 178, 60))
    for i in range(9):                             # slice the disc
        yy = cy - r + int(r * 0.75) + i * 9
        d.rectangle([cx - r, yy, cx + r, yy + 3 + i // 2],
                    fill=(int(28 + 120), 30, 90))

    for i in range(-9, 10):                        # perspective grid
        d.line([cx + i * (w // 9), h, cx + i * 14, horizon],
               fill=(0, 220, 210), width=2)
    yy, step = float(horizon), 3.0
    while yy < h:
        d.line([0, yy, w, yy], fill=(0, 220, 210), width=2)
        step *= 1.32
        yy += step

    d.rectangle([0, horizon - 2, w, horizon + 1], fill=(255, 120, 190))
    img = img.filter(ImageFilter.GaussianBlur(0.4))
    d = ImageDraw.Draw(img)
    m = int(w * 0.04)
    d.rectangle([m, m, w - m, h - m], outline=(255, 200, 90), width=3)
    return _grain(img, 3, seed)


# --------------------------------------------------------------------------
# Poster 3 — test card. Colour bars over a staircase, the thing a CRT showed
# when nothing else was on. No text and no station identity: an invented card,
# not a copy of a real broadcaster's.
# --------------------------------------------------------------------------
def poster_testcard(w=640, h=480, seed=21):
    img = Image.new("RGB", (w, h), (18, 18, 20))
    d = ImageDraw.Draw(img)
    bars = [(235, 235, 235), (225, 220, 60), (60, 210, 220), (60, 200, 90),
            (215, 70, 175), (220, 65, 60), (60, 80, 200)]
    top = int(h * 0.62)
    bw = w / float(len(bars))
    for i, c in enumerate(bars):
        d.rectangle([i * bw, 0, (i + 1) * bw, top], fill=c)
    # Reversed narrow band, the way a real card inverts the order below the bars.
    mid = int(h * 0.72)
    for i, c in enumerate(reversed(bars)):
        d.rectangle([i * bw, top, (i + 1) * bw, mid], fill=tuple(int(v * 0.55) for v in c))
    # Luminance staircase.
    steps = 8
    sw = w / float(steps)
    for i in range(steps):
        g = int(20 + 215 * i / float(steps - 1))
        d.rectangle([i * sw, mid, (i + 1) * sw, h], fill=(g, g, g))
    # A centring circle, drawn as an outline so it reads as a card not a target.
    r = int(h * 0.30)
    d.ellipse([w // 2 - r, top // 2 - r, w // 2 + r, top // 2 + r],
              outline=(20, 20, 22), width=4)
    return _grain(img, 4, seed)


# --------------------------------------------------------------------------
# Poster 4 — ray burst. Wedges from a low corner with a hard horizon, the
# poster-shop geometry of the period.
# --------------------------------------------------------------------------
def poster_burst(w=560, h=760, seed=23):
    img = Image.new("RGB", (w, h), (26, 22, 40))
    d = ImageDraw.Draw(img)
    for y in range(h):                                  # graded field
        t = y / float(h)
        d.line([0, y, w, y], fill=(int(26 + 60 * t), int(22 + 30 * t), int(40 + 40 * t)))
    ox, oy = w * 0.5, h * 0.78
    palette = [(235, 120, 60), (240, 180, 70), (90, 190, 180), (215, 90, 130)]
    n = 13
    for i in range(n):
        a0 = math.pi + (i / float(n)) * math.pi
        a1 = math.pi + ((i + 0.62) / float(n)) * math.pi
        far = h * 1.3
        d.polygon([(ox, oy),
                   (ox + far * math.cos(a0), oy + far * math.sin(a0)),
                   (ox + far * math.cos(a1), oy + far * math.sin(a1))],
                  fill=palette[i % len(palette)])
    d.rectangle([0, oy, w, h], fill=(24, 20, 34))       # hard horizon
    for i in range(6):                                  # receding floor lines
        yy = oy + (h - oy) * ((i + 1) / 6.0) ** 1.7
        d.line([0, yy, w, yy], fill=(90, 190, 180), width=2)
    m = int(w * 0.05)
    d.rectangle([m, m, w - m, h - m], outline=(238, 226, 200), width=3)
    return _grain(img, 3, seed)


# --------------------------------------------------------------------------
# Poster 5 — halftone arc. A dot screen whose dots grow along a sweep, which is
# what a cheap two-colour print of the era actually looked like up close.
# --------------------------------------------------------------------------
def poster_halftone(w=520, h=520, seed=27):
    img = Image.new("RGB", (w, h), (240, 234, 220))
    d = ImageDraw.Draw(img)
    ink = (40, 70, 150)
    step = 13
    cx, cy = w * 0.34, h * 0.66
    maxd = math.hypot(w, h) * 0.78
    for gy in range(0, h + step, step):
        for gx in range(0, w + step, step):
            t = 1.0 - min(1.0, math.hypot(gx - cx, gy - cy) / maxd)
            r = (step * 0.5) * (t ** 1.6)
            if r > 0.6:
                d.ellipse([gx - r, gy - r, gx + r, gy + r], fill=ink)
    # One solid form over the screen, so it is a composition and not a texture.
    d.polygon([(w * 0.60, h * 0.16), (w * 0.88, h * 0.62), (w * 0.32, h * 0.62)],
              fill=(225, 120, 55))
    m = int(w * 0.055)
    d.rectangle([m, m, w - m, h - m], outline=(40, 70, 150), width=3)
    return _grain(img, 3, seed)


# --------------------------------------------------------------------------
# Rug — a geometric medallion carpet, drawn as one quadrant and mirrored so
# it is exactly symmetric the way a woven rug is.
# --------------------------------------------------------------------------
# Rug colourways. The first version was a saturated Persian red — measured
# against the room it was 0.60 saturation and 0.32 value, where the walls are
# 0.10/0.61 and the carpet 0.29/0.70. It contrasted on BOTH axes at once, which
# is why it dominated every shot. These sit inside the room's own range.
RUG_PALETTES = {
    "red":        ((138, 30, 28), (24, 38, 74), (226, 210, 174), (198, 150, 60)),
    "taupe":      ((152, 136, 118), (112, 100, 88), (224, 214, 196), (176, 158, 132)),
    "sage":       ((138, 146, 128), (100, 108, 94), (222, 222, 206), (166, 172, 150)),
    "slate":      ((130, 138, 146), (94, 102, 112), (214, 218, 220), (158, 166, 174)),
    "terracotta": ((158, 130, 116), (114, 92, 84), (226, 214, 198), (182, 154, 130)),
    "greige":     ((156, 148, 140), (116, 108, 100), (226, 220, 212), (180, 170, 158)),
}


def rug(w=1024, h=683, seed=3, palette="taupe"):
    FIELD, NAVY, CREAM, GOLD = RUG_PALETTES[palette]

    img = Image.new("RGB", (w, h), FIELD)
    d = ImageDraw.Draw(img)
    cx, cy = w / 2, h / 2

    def diamond(ccx, ccy, rx, ry, fill=None, outline=None, width=3):
        pts = [(ccx, ccy - ry), (ccx + rx, ccy), (ccx, ccy + ry), (ccx - rx, ccy)]
        d.polygon(pts, fill=fill, outline=outline, width=width)

    # Border bands, outermost first.
    for inset, colour, thick in ((0, NAVY, 0.030), (0.030, CREAM, 0.012),
                                 (0.042, FIELD, 0.055), (0.097, GOLD, 0.010),
                                 (0.107, NAVY, 0.026), (0.133, CREAM, 0.010)):
        a, b = inset * h, (inset + thick) * h
        d.rectangle([a, a, w - a, h - a], outline=colour,
                    width=max(2, int(b - a)))

    # Guard-band motifs: alternating cream/gold diamonds around the navy band.
    ring = 0.120 * h
    n = 34
    for i in range(n):
        t = i / n
        px_ = ring + t * (w - 2 * ring)
        for py_ in (ring, h - ring):
            diamond(px_, py_, 7, 7, fill=CREAM if i % 2 else GOLD)
    m = 22
    for i in range(m):
        t = i / m
        py_ = ring + t * (h - 2 * ring)
        for px_ in (ring, w - ring):
            diamond(px_, py_, 7, 7, fill=CREAM if i % 2 else GOLD)

    # Field lattice.
    for gx in range(-6, 7):
        for gy in range(-4, 5):
            px_ = cx + gx * (w * 0.072)
            py_ = cy + gy * (h * 0.098)
            if abs(gx) < 3 and abs(gy) < 2:
                continue                       # cleared for the medallion
            if not (ring * 1.5 < px_ < w - ring * 1.5):
                continue
            if not (ring * 1.5 < py_ < h - ring * 1.5):
                continue
            diamond(px_, py_, 12, 16, outline=CREAM, width=2)
            diamond(px_, py_, 5, 7, fill=GOLD if (gx + gy) % 2 else NAVY)

    # Central medallion.
    diamond(cx, cy, w * 0.215, h * 0.255, fill=NAVY)
    diamond(cx, cy, w * 0.195, h * 0.232, outline=GOLD, width=4)
    diamond(cx, cy, w * 0.135, h * 0.160, fill=FIELD)
    diamond(cx, cy, w * 0.120, h * 0.142, outline=CREAM, width=3)
    diamond(cx, cy, w * 0.058, h * 0.070, fill=NAVY)
    for i in range(8):                          # rosette
        a = i * math.tau / 8
        diamond(cx + math.cos(a) * w * 0.035, cy + math.sin(a) * h * 0.052,
                9, 13, fill=GOLD)
    # Pendants top and bottom, the way a medallion rug finishes.
    for sgn in (-1, 1):
        diamond(cx, cy + sgn * h * 0.300, w * 0.038, h * 0.048, fill=NAVY)
        diamond(cx, cy + sgn * h * 0.300, w * 0.022, h * 0.028, fill=GOLD)

    # Corner spandrels.
    for sx in (-1, 1):
        for sy in (-1, 1):
            ccx = cx + sx * w * 0.375
            ccy = cy + sy * h * 0.320
            diamond(ccx, ccy, w * 0.055, h * 0.070, fill=NAVY)
            diamond(ccx, ccy, w * 0.032, h * 0.040, fill=CREAM)

    img = img.filter(ImageFilter.GaussianBlur(0.6))   # woven softness
    return _grain(img, 7, seed)


def print_look(img, sat=0.6, black_lift=0.16, white_cap=0.92):
    """Make flat-drawn artwork behave like ink on paper in a dim warm room.

    Drawn straight, both posters were far outside the room: the grid one measured
    0.825 per-pixel saturation and 0.256 luminance SD, against 0.033/0.020 for the
    walls and 0.215/0.030 for the carpet — four times the saturation and eight
    times the contrast of anything near it.

    Three corrections, each physical rather than arbitrary:
      * Lift the blacks. Printed ink is never 0,0,0, and the darkest part of a
        poster on a dim wall reads as a warm dark grey.
      * Cap the whites. Paper is not a light source; unlike a screen it cannot
        exceed the light falling on it.
      * Desaturate. Pigment under low warm light is duller than the same colour
        on a backlit display, which is what the drawing code effectively assumes.

    A poster is still meant to be the brightest thing on a wall, so this pulls it
    toward the room rather than into it.
    """
    a = np.asarray(img.convert("RGB"), dtype=float) / 255.0
    mx = a.max(axis=2, keepdims=True)
    mn = a.min(axis=2, keepdims=True)
    grey = (mx + mn) * 0.5
    a = grey + (a - grey) * sat                       # desaturate about mid-grey
    a = a * (white_cap - black_lift) + black_lift     # compress into the print range
    return Image.fromarray((np.clip(a, 0.0, 1.0) * 255.0).astype("uint8"))


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "rugs":
        # Colourway audition: emit every palette, plus its measured saturation
        # and value so a candidate can be rejected before a render is spent.
        import colorsys
        out_dir = sys.argv[2] if len(sys.argv) > 2 else OUT
        os.makedirs(out_dir, exist_ok=True)
        for pal in RUG_PALETTES:
            im = rug(palette=pal)
            path = os.path.join(out_dir, "rug_%s.png" % pal)
            im.save(path)
            px = list(im.getdata())
            n = float(len(px))
            mr = sum(q[0] for q in px) / n / 255.0
            mg = sum(q[1] for q in px) / n / 255.0
            mb = sum(q[2] for q in px) / n / 255.0
            _, sat, val = colorsys.rgb_to_hsv(mr, mg, mb)
            print("wrote rug_%-11s sat %.3f  val %.3f" % (pal + ".png", sat, val))
        raise SystemExit(0)

    for name, im in (("poster_memphis", print_look(poster_memphis(), sat=0.66)),
                     ("poster_grid", print_look(poster_grid(), sat=0.52)),
                     ("poster_testcard", print_look(poster_testcard(), sat=0.44)),
                     ("poster_burst", print_look(poster_burst(), sat=0.50)),
                     ("poster_halftone", print_look(poster_halftone(), sat=0.58)),
                     ("rug_persian", rug(palette="taupe"))):
        path = os.path.join(OUT, name + ".png")
        im.save(path)
        print("wrote %s  %dx%d" % (path, im.size[0], im.size[1]))

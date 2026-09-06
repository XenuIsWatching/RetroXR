#!/usr/bin/env python3
"""Re-hue one colour range of a texture, leaving the rest alone.

Downloaded furniture keeps arriving in a colourway that fights this room, and the
fix is rarely a material tint: `albedo_color` MULTIPLIES, so it can darken and
desaturate but never change a hue. Green times cream is muddy green, not cream.

Where the offending colour occupies a distinct hue band in the texture, and the
rest of the atlas does not, it can be replaced properly. The bed is the case this
was written for: one mesh, one surface, one 1024x1024 atlas that is 54% brown
wood frame, 17% green duvet and 25% desaturated sheets. Selecting the green band
recolours the bedding and leaves the frame untouched.

Works in HSV and **keeps V**, so every fold, crease and shadow in the fabric
survives — only hue and saturation move. That is the difference between this and
rebuilding a texture from luminance, which flattens whatever print was there (and
preserved a chevron it was meant to remove, on the cushions).

    python3 Tools/art/recolour_texture.py IN OUT --hue 70 170 --to-hue 36 \\
        --sat-scale 0.35 --sat-max 0.20 --val-gain 1.2

Angles are degrees on the 0-360 colour wheel: ~35 warm tan, ~90 green, ~210 blue.
"""

import argparse

import numpy as np
from PIL import Image


def rgb_to_hsv(a):
    """Vectorised RGB->HSV on a float array in 0..1. Returns H in degrees."""
    mx = a.max(axis=2)
    mn = a.min(axis=2)
    d = mx - mn
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    h = np.zeros_like(mx)
    nz = d > 1e-9
    safe = np.maximum(d, 1e-9)
    h = np.where(nz & (mx == r), ((g - b) / safe) % 6.0, h)
    h = np.where(nz & (mx == g), (b - r) / safe + 2.0, h)
    h = np.where(nz & (mx == b), (r - g) / safe + 4.0, h)
    s = np.where(mx > 1e-9, d / np.maximum(mx, 1e-9), 0.0)
    return h * 60.0, s, mx


def hsv_to_rgb(h, s, v):
    h = np.mod(h, 360.0) / 60.0
    i = np.floor(h).astype(int)
    f = h - i
    p = v * (1.0 - s)
    q = v * (1.0 - s * f)
    t = v * (1.0 - s * (1.0 - f))
    i = i % 6
    out = np.zeros(h.shape + (3,))
    for k, (rr, gg, bb) in enumerate(((v, t, p), (q, v, p), (p, v, t),
                                      (p, q, v), (t, p, v), (v, p, q))):
        m = i == k
        out[..., 0] = np.where(m, rr, out[..., 0])
        out[..., 1] = np.where(m, gg, out[..., 1])
        out[..., 2] = np.where(m, bb, out[..., 2])
    return out


def recolour(src, hue_lo, hue_hi, to_hue, sat_scale, sat_max, val_gain, sat_min,
             val_lift=0.0):
    a = np.asarray(Image.open(src).convert("RGB"), dtype=float) / 255.0
    h, s, v = rgb_to_hsv(a)

    if hue_lo <= hue_hi:
        in_band = (h >= hue_lo) & (h <= hue_hi)
    else:                                   # a band that wraps through red
        in_band = (h >= hue_lo) | (h <= hue_hi)
    sel = in_band & (s >= sat_min)

    h2 = np.where(sel, float(to_hue), h)
    s2 = np.where(sel, np.minimum(s * sat_scale, sat_max), s)
    # Gain alone cannot lighten a dark fabric: multiplying clips the highlights
    # while the shadowed folds stay dark, so the whole thing reads mid-tone. The
    # lift blends toward white instead, which raises the shadows too — that is
    # what turns a mid green duvet into a cream one.
    vg = np.clip(v * val_gain, 0.0, 1.0)
    v2 = np.where(sel, vg * (1.0 - val_lift) + val_lift, v)
    out = hsv_to_rgb(h2, s2, v2)
    return Image.fromarray((np.clip(out, 0.0, 1.0) * 255.0).astype("uint8")), \
        float(sel.sum()) / sel.size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--hue", nargs=2, type=float, required=True,
                    metavar=("LO", "HI"), help="hue band to replace, degrees")
    ap.add_argument("--to-hue", type=float, required=True)
    ap.add_argument("--sat-scale", type=float, default=0.4)
    ap.add_argument("--sat-max", type=float, default=0.25)
    ap.add_argument("--sat-min", type=float, default=0.10,
                    help="ignore pixels below this saturation; they are greys")
    ap.add_argument("--val-gain", type=float, default=1.0)
    ap.add_argument("--val-lift", type=float, default=0.0,
                    help="blend value toward white, 0..1; lightens shadows too")
    args = ap.parse_args()

    im, frac = recolour(args.src, args.hue[0], args.hue[1], args.to_hue,
                        args.sat_scale, args.sat_max, args.val_gain, args.sat_min,
                        args.val_lift)
    im.save(args.dst)
    print("wrote %s  (%.1f%% of pixels recoloured)" % (args.dst, 100.0 * frac))


if __name__ == "__main__":
    main()

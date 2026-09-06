"""Bake Quest Touch Plus line art for the Controls remap diagram.

Consumes the normal + part-ID passes written by a throwaway Godot probe (see
CLAUDE.md "Headless Testing") and emits, into RetroXR/Textures/Controllers/:

    quest_touch_plus_left.png    white RGB; alpha = 1.0 stroke, 0.10 body
    quest_touch_plus_right.png

White RGB means the Control tints them with `modulate`, so the diagram follows
the panel theme instead of baking a palette into the texture.

It also prints the anchor table for controller_diagram.gd. Anchors are
normalized to the cropped image, so they survive any later resize.

Usage:
    python Tools/art/bake_controller_art.py <pass_dir> [out_dir]

The model is meta-quest-touch-plus from immersive-web/webxr-input-profiles (MIT).
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

SS = 2                 # probe supersample factor
TARGET_H = 900         # baked texture height
BODY_ALPHA = 0.10      # interior wash, so the silhouette reads on a dark panel
NORMAL_T = 0.16        # view-space normal gradient that counts as a crease
ID_T = 0.10            # part-ID difference that counts as a seam
PAD = 6                # transparent margin kept around the crop

# Probe output, in full-resolution pixels (pre-crop, pre-downsample).
ANCHORS = {
    "left": {
        "ax_button": (642.50, 545.37),
        "by_button": (712.59, 550.58),
        "trigger": (898.36, 697.02),
        "grip": (559.99, 817.52),
        "primary_click": (810.32, 462.95),
    },
    "right": {
        "ax_button": (597.23, 545.70),
        "by_button": (526.57, 551.25),
        "trigger": (340.93, 697.45),
        "grip": (679.98, 817.61),
        "primary_click": (429.56, 463.14),
    },
}


def _shifts(a):
    return (np.roll(a, 1, 0), np.roll(a, -1, 0), np.roll(a, 1, 1), np.roll(a, -1, 1))


def _edges(normals, ids):
    """Silhouette + part seams + creases, at supersampled resolution."""
    alpha = normals[..., 3] > 0.5
    n, i = normals[..., :3], ids[..., :3]

    sil = np.zeros_like(alpha)
    for s in _shifts(alpha):
        sil |= alpha & ~s

    seam = np.zeros_like(alpha)
    for s in _shifts(i):
        seam |= np.abs(i - s).sum(axis=2) > ID_T
    seam &= alpha

    grad = np.zeros(alpha.shape, float)
    for s in _shifts(n):
        grad = np.maximum(grad, np.abs(n - s).sum(axis=2))

    lines = sil | seam | ((grad > NORMAL_T) & alpha)
    thick = lines.copy()
    for s in _shifts(thick):
        thick |= s
    return alpha, sil, thick & (alpha | sil)


def bake(hand, pass_dir, out_dir):
    normals = np.array(Image.open(pass_dir / f"normals_{hand}.png").convert("RGBA"), float) / 255.
    ids = np.array(Image.open(pass_dir / f"ids_{hand}.png").convert("RGBA"), float) / 255.
    alpha, sil, lines = _edges(normals, ids)

    solid = alpha | sil
    a = np.where(lines, 1.0, np.where(solid, BODY_ALPHA, 0.0))
    h, w = a.shape
    rgba = np.dstack([np.full((h, w, 3), 255.0), a * 255.0]).astype(np.uint8)
    img = Image.fromarray(rgba, "RGBA")

    ys, xs = np.nonzero(solid)
    box = (max(xs.min() - PAD, 0), max(ys.min() - PAD, 0),
           min(xs.max() + PAD + 1, w), min(ys.max() + PAD + 1, h))
    img = img.crop(box)

    scale = TARGET_H / img.height
    img = img.resize((round(img.width * scale), TARGET_H), Image.LANCZOS)

    out = out_dir / f"quest_touch_plus_{hand}.png"
    img.save(out)

    # Anchors are in probe pixels; map through the same crop, then normalize.
    uv = {}
    for key, (px, py) in ANCHORS[hand].items():
        uv[key] = ((px - box[0]) / (box[2] - box[0]),
                   (py - box[1]) / (box[3] - box[1]))
    return out, img.size, uv


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    pass_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else \
        Path(__file__).resolve().parent.parent / "RetroXR" / "Textures" / "Controllers"
    out_dir.mkdir(parents=True, exist_ok=True)

    table = {}
    for hand in ("left", "right"):
        out, size, uv = bake(hand, pass_dir, out_dir)
        table[hand] = uv
        print(f"wrote {out}  {size[0]}x{size[1]}")

    print("\n# Paste into controller_diagram.gd:")
    print("const ANCHORS: Dictionary = {")
    for hand in ("left", "right"):
        print(f'\t"{hand}": {{')
        for key, (u, v) in table[hand].items():
            print(f'\t\t"{key}": Vector2({u:.4f}, {v:.4f}),')
        print("\t},")
    print("}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

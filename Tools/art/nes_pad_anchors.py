"""Measure the ConsolePadArt anchors for the NES pad, and check the leader lines.

The NES pad used to be DRAWN here, the way gen_gamepad_art.py still draws the
Xbox one, so its anchors were coordinates chosen in this file. It is now someone
else's illustration (CC BY-SA 3.0 — see
RetroXR/Textures/Controllers/ATTRIBUTIONS.txt), so the anchors have to be found
IN the art instead — which is what this does, by colour:

    the two red discs          -> b, a
    the dark cross             -> up, down, left, right (arm tips, pulled in)
    the two dark pills         -> select, start

The cross and the pills share their fill with the face plate behind them, but
each is ringed by a lighter outline, so they still come out as their own
connected components. The face itself is rejected for spanning most of the
image.

Measuring beats eyeballing because every one of these is a filled shape with an
unambiguous centre, and re-running this after the art changes is the only way the
dots stay on the buttons.

Input is a PNG render of the SVG. Godot is the renderer that matters — it is the
one whose ThorVG output the game actually shows — so produce it with a throwaway
probe (see CLAUDE.md "Headless Testing"):

    var tex := load("res://Textures/Controllers/nes_pad_colour.svg") as Texture2D
    tex.get_image().save_png("res://probe_out/pad_raw.png")

Then:

    python Tools/art/nes_pad_anchors.py RetroXR/probe_out/pad_raw.png

Prints the anchor table for console_pad_art.gd and the leader-line intersection
count over a sweep of panel sizes, which must stay 0.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# ── Diagram layout constants, mirrored from console_pad_diagram.gd ────────────
# The crossing count below is only meaningful if these match the widget.
MAX_W = 1520.0
SLOT_W = 180.0
ROW_H = 50.0
ROW_PAD = 14.0
STUB = 18.0

## How far inside a d-pad arm's tip the dot sits, as a fraction of the cross's
## half-extent. Right on the tip it reads as sitting on the arm's edge.
ARM_INSET = 0.18

## Which row each control belongs to. Split by anchor height — the pad's upper
## controls reach up, the lower ones reach down — so no lead from one row has to
## cross the other's. Within a row the slots keep anchor-x order, and the widget
## parks each slot under its own anchor, so no two leads in a row can invert.
## `down` is on the bottom row despite sharing the cross's x with `up`, because
## from the top its lead would run straight through the cross.
TOP = ["left", "up", "right"]
BOTTOM = ["down", "select", "start", "b", "a"]


def _blobs(mask, min_px):
    """Connected components of a boolean mask, as dicts of centre and bounds."""
    h, w = mask.shape
    seen = np.zeros(mask.shape, bool)
    out = []
    for y in range(h):
        for x in range(w):
            if not mask[y, x] or seen[y, x]:
                continue
            stack = [(y, x)]
            seen[y, x] = True
            pts = []
            while stack:
                cy, cx = stack.pop()
                pts.append((cy, cx))
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = cy + dy, cx + dx
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        stack.append((ny, nx))
            if len(pts) >= min_px:
                p = np.array(pts)
                out.append(dict(n=len(pts), cx=p[:, 1].mean(), cy=p[:, 0].mean(),
                                x0=p[:, 1].min(), x1=p[:, 1].max(),
                                y0=p[:, 0].min(), y1=p[:, 0].max()))
    return out


def measure(png_path):
    im = Image.open(png_path).convert("RGBA")
    a = np.array(im).astype(int)
    r, g, b, alpha = a[..., 0], a[..., 1], a[..., 2], a[..., 3]
    opaque = alpha > 40
    w, h = im.width, im.height

    red = _blobs((r > 170) & (g < 90) & (b < 90) & opaque, 200)
    if len(red) != 2:
        raise SystemExit("expected 2 red buttons, found %d" % len(red))
    red.sort(key=lambda d: d["cx"])
    face = {"b": red[0], "a": red[1]}

    black = _blobs((r < 20) & (g < 20) & (b < 20) & opaque, 200)
    # The largest black shape that is roughly as tall as it is wide is the cross;
    # the outline of the whole pad is also near-black but spans the full image.
    crosses = [d for d in black
               if d["x1"] - d["x0"] < w * 0.5 and 0.6 < (d["x1"] - d["x0"]) / max(d["y1"] - d["y0"], 1) < 1.6]
    if not crosses:
        raise SystemExit("no d-pad cross found")
    cross = max(crosses, key=lambda d: d["n"])

    # The two pills are small, wide and side by side, below the cross's row.
    pills = [d for d in black
             if (d["x1"] - d["x0"]) > 2.0 * (d["y1"] - d["y0"]) and d["n"] < cross["n"] * 0.5]
    if len(pills) != 2:
        raise SystemExit("expected 2 menu pills, found %d" % len(pills))
    pills.sort(key=lambda d: d["cx"])

    cx, cy = cross["cx"], cross["cy"]
    half_x = (cross["x1"] - cross["x0"]) * 0.5
    half_y = (cross["y1"] - cross["y0"]) * 0.5
    px = {
        "up": (cx, cy - half_y * (1.0 - ARM_INSET)),
        "down": (cx, cy + half_y * (1.0 - ARM_INSET)),
        "left": (cx - half_x * (1.0 - ARM_INSET), cy),
        "right": (cx + half_x * (1.0 - ARM_INSET), cy),
        "select": (pills[0]["cx"], pills[0]["cy"]),
        "start": (pills[1]["cx"], pills[1]["cy"]),
        "b": (face["b"]["cx"], face["b"]["cy"]),
        "a": (face["a"]["cx"], face["a"]["cy"]),
    }
    return {k: (x / w, y / h) for k, (x, y) in px.items()}, (w, h)


# ── Leader lines ──────────────────────────────────────────────────────────────

def _seg_hit(p1, p2, p3, p4):
    """Do segments p1p2 and p3p4 properly cross?

    Shared endpoints do not count. Every lead meets its own stub at a point, so
    without this test each one scores a crossing against itself and a perfectly
    clean layout reports two per panel size.
    """
    if len({p1, p2, p3, p4}) < 4:
        return False

    def cross(o, p, q):
        return (p[0] - o[0]) * (q[1] - o[1]) - (p[1] - o[1]) * (q[0] - o[0])

    d1, d2 = cross(p3, p4, p1), cross(p3, p4, p2)
    d3, d4 = cross(p1, p2, p3), cross(p1, p2, p4)
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0))


def _slot_xs(order, anchors, art_x, art_w, w):
    """Slot centres for one row: each parked under its own anchor, pushed apart
    only where two would overlap. Mirrors ConsolePadDiagram._slot_xs."""
    xs = [art_x + anchors[k][0] * art_w for k in order]
    for i in range(1, len(xs)):
        if xs[i] - xs[i - 1] < SLOT_W:
            xs[i] = xs[i - 1] + SLOT_W
    over = xs[-1] - (w - SLOT_W * 0.5)
    if over > 0:
        xs = [x - over for x in xs]
        for i in range(len(xs) - 2, -1, -1):
            if xs[i + 1] - xs[i] < SLOT_W:
                xs[i] = xs[i + 1] - SLOT_W
    lo = SLOT_W * 0.5
    if xs[0] < lo:
        shift = lo - xs[0]
        xs = [x + shift for x in xs]
    return xs


def _crossings(anchors, aspect):
    total = 0
    for w in range(900, 1701, 100):
        for h in range(440, 721, 40):
            band_w = min(w, MAX_W)
            art_h = h - 2.0 * (ROW_H + ROW_PAD)
            art_w = art_h * aspect
            if art_w > band_w:
                art_w = band_w
                art_h = art_w / aspect
            art_x, art_y = (w - art_w) * 0.5, (h - art_h) * 0.5

            segs = []
            for top, order in ((True, TOP), (False, BOTTOM)):
                row_y = 0.0 if top else h - ROW_H
                xs = _slot_xs(order, anchors, art_x, art_w, w)
                for i, key in enumerate(order):
                    edge = (xs[i], row_y + (ROW_H if top else 0.0))
                    stub = (xs[i], edge[1] + (STUB if top else -STUB))
                    ax, ay = anchors[key]
                    segs.append((stub, (art_x + ax * art_w, art_y + ay * art_h)))
                    segs.append((edge, stub))
            for i in range(len(segs)):
                for j in range(i + 1, len(segs)):
                    if _seg_hit(segs[i][0], segs[i][1], segs[j][0], segs[j][1]):
                        total += 1
    return total


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    png = Path(sys.argv[1])
    anchors, (w, h) = measure(png)

    print('\t\t"anchors": {')
    for key in TOP + BOTTOM:
        print('\t\t\t"%s": Vector2(%.4f, %.4f),' % (key, anchors[key][0], anchors[key][1]))
    print("\t\t},")
    print('\t\t"top": %s,' % str(TOP).replace("'", '"'))
    print('\t\t"bottom": %s,' % str(BOTTOM).replace("'", '"'))
    print("\nart %dx%d, aspect %.3f" % (w, h, w / h))
    print("leader-line crossings over the size sweep: %d"
          % _crossings(anchors, w / h))


if __name__ == "__main__":
    main()

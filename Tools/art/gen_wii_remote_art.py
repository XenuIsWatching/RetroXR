"""Build the Wii Remote diagram for the CONTROLS tab, and print its anchors.

Two CC0 sources, composed rather than drawn:

    the remote      MilkToastRat Pack, SVG/wii.svg  (CC0-1.0)
    the button marks Kenney "Input Prompts" 1.5, Nintendo Wii/Vector  (CC0-1.0)

The remote arrives with BLANK buttons — a clean white shell and nothing printed
on it — which is no use in a remap diagram where the player has to match a row
called "minus" to a physical button. Kenney's Wii set has exactly the marks the
hardware carries, so the marks are lifted from there and printed onto the shell.
Taking them from the same set the CONTROLS rows use for their legend chips is
the point: the mark on the picture and the chip beside it are then the same
drawing, not two artists' idea of a plus sign.

Neither source is share-alike, which is deliberate. The NES pad is CC BY-SA and
is the only such asset in the repo (see RetroXR/Textures/Controllers/
ATTRIBUTIONS.txt); this one adds no second obligation.

WHY A SCRIPT AND NOT A ONE-OFF EDIT. The anchors ConsolePadArt needs are the
button centres, and they are read here out of the source drawing's own path data
rather than measured off a render the way nes_pad_anchors.py has to measure the
NES. That art is someone else's with unknown geometry; this one we compose, so
the centres are known exactly and re-deriving them is free. Re-run this if
either upstream asset is ever refreshed.

    python Tools/art/gen_wii_remote_art.py --in <wii.svg> --kenney <kenney.zip>

Both inputs are downloads, not vendored: the pack is 5 MB for six glyphs.
"""

from __future__ import annotations

import argparse
import io
import os
import re
import zipfile

# Kenney's button glyphs are 64x64 with the button circle at r=24, centred.
KENNEY_BUTTON_R = 24.0
KENNEY_BOX = 64.0

# Marks to print, and which button of the remote each goes on. The names on the
# left are Kenney's file stems; the ones on the right are the control names
# ConsolePadArt and the Wiimote's FACE_BUTTONS dictionary already speak.
# Kenney draws these white, which is invisible on a white remote, so each mark is
# re-inked. Four values, following the hardware rather than one flat grey — the
# colour is doing work here, because it is the only thing that separates the game
# buttons from the two that are not.
#
# A is the darkest: it is the button you press, and on the remote it is the one
# with real contrast against its cap.
INK = "#3d3d3d"

# minus, plus, 1 and 2 are grey on the hardware and grey here, a stop lighter than
# A so the hierarchy reads at diagram size. Not lighter than this: it has to stay
# legible on a near-white cap.
GREY_INK = "#75757a"

# Home takes the remote's own blue — #16b4e6 is already in this file, as the lit
# player LED, so the accent is the source's rather than one invented for it.
HOME_INK = "#16b4e6"

# Power is the exception, and red on purpose. It is the one control on this
# remote that is NOT a game input — it turns the thing on — and it carries no
# anchor, no lead and no binding row, so nothing else on the page distinguishes
# it from the six caps that do. Colour is what says "this one is different"
# before you have read a word. Muted rather than a signal red: it sits beside a
# dark grey d-pad on a white shell and should not be the loudest thing there.
POWER_INK = "#cc3327"

MARKS = [
    ("power", "power", POWER_INK),
    ("a", "a", INK),
    ("minus", "minus", GREY_INK),
    ("home", "home", HOME_INK),
    ("plus", "plus", GREY_INK),
    ("1", "one", GREY_INK),
    ("2", "two", GREY_INK),
]

# Trimmed to the drawing's own alpha, with a little air. The source is a 1000
# square with the remote occupying a quarter of it; left uncropped the diagram
# would be mostly empty and the leader lines would run miles.
VIEWBOX = (376.0, 13.0, 246.0, 974.0)


def sub_paths(d: str) -> list[str]:
    """Split a path's `d` into its subpaths, each still starting with M."""
    return [p.strip() for p in re.split(r"(?=M)", d) if p.strip()]


def bbox(d: str) -> tuple[float, float, float, float]:
    """Crude bbox from every coordinate pair in a subpath.

    Good enough on purpose: these are the glyph marks, all straight lines and
    short quadratics whose control points sit inside the ink. A curve can bulge
    past its control points in general, but not far enough here to move a centre by a
    pixel, and the centre is all this is used for.
    """
    nums = [float(n) for n in re.findall(r"-?\d+(?:\.\d+)?", d)]
    xs, ys = nums[0::2], nums[1::2]
    return min(xs), min(ys), max(xs), max(ys)


def mark_path(svg: str) -> str:
    """The symbol out of a Kenney button glyph, with the button circle dropped.

    The circle is NOT reliably the first subpath — wii_button_minus.svg puts it
    second — so it is found by size instead. Dropping subpath[0] blindly deletes
    the minus sign.

    It is matched against the button DIAMETER, not against the 64 box it sits in.
    The circle spans 8..56, so a threshold of 0.8 of the box (51.2) does not catch
    it — and a kept circle is not a crash but a silent change of design: every cap
    comes out a solid dark disc with the mark knocked out of it, covering the
    shading the remote was drawn with.

    Everything else is kept in ONE path and in source order, because the
    counters (the triangle in the A, the door in the house) are holes only by
    winding direction under the default nonzero fill rule. Split them into
    separate elements and they fill in solid.
    """
    d = re.search(r'\sd="([^"]+)"', svg).group(1)
    keep = []
    for sp in sub_paths(d):
        x0, y0, x1, y1 = bbox(sp)
        if (x1 - x0) >= 2.0 * KENNEY_BUTTON_R and (y1 - y0) >= 2.0 * KENNEY_BUTTON_R:
            continue  # the button circle
        keep.append(sp)
    if not keep:
        raise SystemExit("no mark left after dropping the circle")
    return " ".join(keep)


def circle_pairs(svg: str) -> list[tuple[float, float, float]]:
    """Every (cx, cy, r) the remote draws as a PAIR of arc subpaths.

    The source draws each round button twice — an outer edge and an inner face —
    as two paths whose y extents match. Reading the centre off the path data
    beats measuring pixels: it is the number the artist actually used.
    """
    out = []
    for m in re.finditer(r'\sd="(M(-?[\d.]+),(-?[\d.]+)c[^"]+)"', svg):
        d = m.group(1)
        x0, y0, x1, y1 = bbox(d)
        out.append(((x0 + x1) * 0.5, (y0 + y1) * 0.5, (y1 - y0) * 0.5))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src", required=True, help="MilkToastRat wii.svg")
    ap.add_argument("--kenney", required=True, help="kenney_input-prompts_1.5.zip")
    ap.add_argument("--out", required=True, help="destination .svg")
    args = ap.parse_args()

    src = io.open(args.src, encoding="utf-8").read()
    zf = zipfile.ZipFile(args.kenney)

    # The buttons, by hand from the source's own geometry. Each is the centre and
    # radius of one round control; see circle_pairs() for where they come from.
    buttons = {
        # Top left, and the smallest cap on the remote. The 23.9 circle around it
        # in the source is the recess, not the button.
        "power": (438.69, 65.06, 17.08),
        "a": (501.00, 320.92, 38.29),
        "minus": (435.77, 480.57, 19.10),
        "home": (501.09, 480.57, 19.10),
        "plus": (566.41, 480.57, 19.10),
        "one": (501.63, 728.87, 26.63),
        "two": (501.63, 812.18, 26.63),
    }

    groups = []
    for stem, control, ink in MARKS:
        glyph = zf.read("Nintendo Wii/Vector/wii_button_%s.svg" % stem).decode()
        d = mark_path(glyph)
        cx, cy, r = buttons[control]
        # Scale by the BUTTON, not by the mark, so every mark keeps the size
        # relative to its cap that Kenney drew it at. Scaling each mark to a
        # common height instead would blow the minus sign up to the size of an A.
        s = r / KENNEY_BUTTON_R
        bb = [bbox(sp) for sp in sub_paths(d)]
        mx0 = min(b[0] for b in bb)
        my0 = min(b[1] for b in bb)
        mx1 = max(b[2] for b in bb)
        my1 = max(b[3] for b in bb)
        ox = (mx0 + mx1) * 0.5
        oy = (my0 + my1) * 0.5
        groups.append(
            '  <g transform="translate(%.4f %.4f) scale(%.6f) translate(%.4f %.4f)">\n'
            '    <path fill="%s" d="%s"/>\n'
            "  </g>" % (cx, cy, s, -ox, -oy, ink, d)
        )

    # Crop, and append the marks last so they sit over the caps.
    out = re.sub(r'viewBox="[^"]*"', 'viewBox="%g %g %g %g"' % VIEWBOX, src, count=1)
    out = out.replace("</svg>", "\n".join(groups) + "\n</svg>")
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    io.open(args.out, "w", encoding="utf-8", newline="\n").write(out)
    print("wrote %s" % args.out)

    # The anchors, normalized to the cropped viewBox, ready to paste into
    # Scripts/Data/systems/console_pad_art.gd.
    vx, vy, vw, vh = VIEWBOX
    extra = {
        "up": (500.90, 133.00),
        "down": (500.90, 220.00),
        "left": (466.00, 176.50),
        "right": (535.90, 176.50),
    }
    print("\n\t\t\"anchors\": {")
    # Deliberately NOT power: it is printed on the art but is not a game input, so
    # it gets no anchor, no lead and no binding row.
    order = ["up", "down", "left", "right", "a", "minus", "home", "plus", "one", "two"]
    for k in order:
        if k in extra:
            x, y = extra[k]
        else:
            x, y, _r = buttons[k]
        print("\t\t\t\"%s\": Vector2(%.4f, %.4f)," % (k, (x - vx) / vw, (y - vy) / vh))
    print("\t\t},")


if __name__ == "__main__":
    main()

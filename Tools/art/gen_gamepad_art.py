"""Draw the physical-gamepad line art for the Controls remap diagram.

The Quest art in this project is baked from a real glTF (bake_controller_art.py),
because a Touch controller's shape is not something you can guess. A gamepad is:
every feature is a circle, a capsule or a cross on a symmetric body, so drawing it
outright is both simpler and better — the anchors come out as coordinates chosen
here rather than measured off a render, so they can never drift from the art.

It is deliberately an Xbox *layout* — offset sticks, ABXY diamond, bumpers and
triggers — and deliberately not an Xbox. No logo, no trade dress, nothing traced
from a photo, so there is nothing to license and nobody's mark to borrow.

Emits, into RetroXR/Textures/Controllers/:

    gamepad_line.svg    white stroke, faint white body; alpha carries the drawing

White means the Control tints it with `modulate`, exactly like the Quest art, so
the diagram follows the panel theme instead of baking a palette into the asset.

Also prints the ANCHORS table for gamepad_diagram.gd, normalized to the viewBox
so the diagram can be laid out at any size.

Usage:
    python Tools/art/gen_gamepad_art.py [out_dir]
"""
import sys
from pathlib import Path

W, H = 1000, 720

STROKE = 5.0
BODY_FILL = 0.10        # interior wash, so the silhouette reads on a dark panel

# ── Feature positions ─────────────────────────────────────────────────────────
# Everything below is mirrored about CX by construction, so the pad cannot end up
# subtly lopsided.
CX = W / 2

STICK_R = 62            # outer ring
STICK_INNER = 38        # the cap you actually push
LS = (268, 262)
RS = (605, 408)

DPAD = (398, 408)
DPAD_ARM = 46           # centre to tip
DPAD_HALF = 30 / 2      # arm half-width

FACE = (722, 268)       # ABXY diamond centre
FACE_SPREAD = 56
FACE_R = 30

GUIDE = (CX, 208)
GUIDE_R = 32
BACK = (441, 268)
START = (559, 268)
SMALL_R = 19

# Both sit clear ABOVE the body rather than crossing its top edge. Overlapping
# looked wrong and could not be fixed by draw order: the art is white-on-alpha so
# a bumper has no opaque fill to hide the body outline behind it.
# A front view cannot really show a trigger, but the diagram needs an anchor.
BUMPER_Y = 128
TRIGGER_Y = 82
SHOULDER_HALF_W = 70
TRIGGER_HALF_W = 50
LX, RX = 300, 700

# ── Body ──────────────────────────────────────────────────────────────────────
# One closed path: top edge with a shallow centre dip, shoulders, two grips, and
# an underside that arcs up between them.
BODY = """
M 250 185
C 330 152 400 150 460 160
C 480 164 520 164 540 160
C 600 150 670 152 750 185
C 830 218 878 272 876 340
C 874 415 850 480 822 558
C 802 612 764 646 720 638
C 682 630 656 586 636 530
C 616 476 574 458 500 458
C 426 458 384 476 364 530
C 344 586 318 630 280 638
C 236 646 198 612 178 558
C 150 480 126 415 124 340
C 122 272 170 218 250 185
Z
"""


def _stroke(extra=""):
    return ('fill="none" stroke="#ffffff" stroke-width="%.1f" '
            'stroke-linecap="round" stroke-linejoin="round" %s' % (STROKE, extra))


def _circle(cx, cy, r, extra=""):
    return '<circle cx="%.1f" cy="%.1f" r="%.1f" %s/>' % (cx, cy, r, _stroke(extra))


def _capsule(cx, cy, half_w, half_h):
    """Rounded bar — bumpers and triggers."""
    return ('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" %s/>'
            % (cx - half_w, cy - half_h, half_w * 2, half_h * 2, half_h, _stroke()))


def _dpad(cx, cy, arm, half):
    """A plus sign as one closed path, so the inner corners stay square."""
    p = [
        (cx - half, cy - arm), (cx + half, cy - arm),
        (cx + half, cy - half), (cx + arm, cy - half),
        (cx + arm, cy + half), (cx + half, cy + half),
        (cx + half, cy + arm), (cx - half, cy + arm),
        (cx - half, cy + half), (cx - arm, cy + half),
        (cx - arm, cy - half), (cx - half, cy - half),
    ]
    d = "M %.1f %.1f " % p[0] + " ".join("L %.1f %.1f" % q for q in p[1:]) + " Z"
    return '<path d="%s" %s/>' % (d, _stroke())


def build() -> str:
    out = []
    out.append('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" '
               'width="%d" height="%d">' % (W, H, W, H))

    for x in (LX, RX):
        out.append(_capsule(x, TRIGGER_Y, TRIGGER_HALF_W, 17))
        out.append(_capsule(x, BUMPER_Y, SHOULDER_HALF_W, 15))

    out.append('<path d="%s" fill="#ffffff" fill-opacity="%.2f" '
               'stroke="#ffffff" stroke-width="%.1f" stroke-linejoin="round"/>'
               % (" ".join(BODY.split()), BODY_FILL, STROKE))

    for c in (LS, RS):
        out.append(_circle(c[0], c[1], STICK_R))
        out.append(_circle(c[0], c[1], STICK_INNER))

    out.append(_dpad(DPAD[0], DPAD[1], DPAD_ARM, DPAD_HALF))

    for dx, dy in ((0, -FACE_SPREAD), (FACE_SPREAD, 0), (0, FACE_SPREAD), (-FACE_SPREAD, 0)):
        out.append(_circle(FACE[0] + dx, FACE[1] + dy, FACE_R))

    out.append(_circle(GUIDE[0], GUIDE[1], GUIDE_R))
    out.append(_circle(BACK[0], BACK[1], SMALL_R))
    out.append(_circle(START[0], START[1], SMALL_R))

    out.append("</svg>")
    return "\n".join(out)


## Anchor per bindable input. Keys match gamepad_diagram.gd, which maps them onto
## GamepadBindings' "btn:<n>" / "axis:<n>:<sign>" encoding.
def anchors() -> dict:
    return {
        "lt": (LX, TRIGGER_Y),
        "rt": (RX, TRIGGER_Y),
        "lb": (LX, BUMPER_Y),
        "rb": (RX, BUMPER_Y),
        "ls": LS,
        "rs": RS,
        "dpad_up": (DPAD[0], DPAD[1] - DPAD_ARM),
        "dpad_down": (DPAD[0], DPAD[1] + DPAD_ARM),
        "dpad_left": (DPAD[0] - DPAD_ARM, DPAD[1]),
        "dpad_right": (DPAD[0] + DPAD_ARM, DPAD[1]),
        "y": (FACE[0], FACE[1] - FACE_SPREAD),
        "b": (FACE[0] + FACE_SPREAD, FACE[1]),
        "a": (FACE[0], FACE[1] + FACE_SPREAD),
        "x": (FACE[0] - FACE_SPREAD, FACE[1]),
        "guide": GUIDE,
        "back": BACK,
        "start": START,
    }


def main() -> None:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        Path(__file__).resolve().parent.parent / "RetroXR" / "Textures" / "Controllers"
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "gamepad_line.svg"
    path.write_text(build(), encoding="utf-8")
    print("wrote %s" % path)

    print("\nconst ANCHORS: Dictionary = {")
    for name, (x, y) in anchors().items():
        print('\t"%s": Vector2(%.4f, %.4f),' % (name, x / W, y / H))
    print("}")


if __name__ == "__main__":
    main()

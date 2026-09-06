"""Turn the Wii Remote diagram on its side, and print the anchors that go with it.

    python Tools/art/gen_wii_remote_sideways.py

Reads the committed RetroXR/Textures/Controllers/wii_remote.svg and writes
wii_remote_sideways.svg beside it. Unlike gen_wii_remote_art.py this needs no
downloads: it is a transform of art already in the repo, so it can be re-run by
anyone at any time.

WHY A SCRIPT. The anchors are not the same drawing's anchors moved -- they are
moved AND re-keyed, and the re-keying is the part nobody can check by eye. Doing
it here means the reasoning sits next to the arithmetic instead of in a commit
message nobody reads again.

Which way it turns, and why that is not arbitrary. A sideways remote is held
like an NES pad: d-pad under the left thumb, 1 and 2 under the right. The d-pad
is at the TOP of an upright remote, so the top must end up on the LEFT, which is
a COUNTER-clockwise quarter turn. Turning it the other way puts the d-pad under
the right thumb and the whole picture is a mirror of how anyone actually holds
it -- and it still looks like a perfectly good sideways remote, which is what
makes it worth stating.

THE RE-KEYING. Dolphin's descWiimoteSideways keeps the same RetroPad bits and
changes what they MEAN (Input.cpp): the core does the remap internally, so the
frontend sends the same bits either way.

    plain      b -> B(trigger)   a -> A     x -> 1     y -> 2
    sideways   b -> 1            a -> 2     x -> A     y -> B(trigger)

So a control key points at a different physical button in this picture than in
the upright one, and the anchor table has to follow. Same for the d-pad: after a
counter-clockwise turn the key that is physically uppermost is the one that was
on the RIGHT, so "up" takes the old "right" position and round the cross.
"""

from __future__ import annotations

import pathlib
import re

ART = pathlib.Path("RetroXR/Textures/Controllers/wii_remote.svg")
OUT = pathlib.Path("RetroXR/Textures/Controllers/wii_remote_sideways.svg")

# The upright anchors, exactly as ConsolePadArt._ROWS["wii"] carries them, keyed
# by the PHYSICAL button so the re-key below reads as what it is.
UPRIGHT = {
    "dpad_up":    (0.5077, 0.1232),
    "dpad_left":  (0.3659, 0.1679),
    "dpad_right": (0.6500, 0.1679),
    "dpad_down":  (0.5077, 0.2125),
    "A":          (0.5081, 0.3161),
    "trigger_B":  (0.5081, 0.3922),
    "minus":      (0.2430, 0.4801),
    "home":       (0.5085, 0.4801),
    "plus":       (0.7740, 0.4801),
    "one":        (0.5107, 0.7350),
    "two":        (0.5107, 0.8205),
}

# RetroPad target -> the physical button it drives when the remote is sideways.
SIDEWAYS_KEYS = {
    "b": "one",
    "a": "two",
    "x": "A",
    "y": "trigger_B",
    # The cross turns with the shell: whatever was on the right is now on top.
    "up": "dpad_right",
    "down": "dpad_left",
    "left": "dpad_up",
    "right": "dpad_down",
    "select": "minus",
    "r3": "home",
    "start": "plus",
}


def rotate_ccw(u: float, v: float) -> tuple[float, float]:
    """Normalised (u, v) through a counter-clockwise quarter turn.

    SVG y runs DOWN, so rotate(-90) sends (x, y) to (y, -x); in normalised terms
    that is (u, v) -> (v, 1 - u), and the art goes from 1:4 portrait to 4:1
    landscape.
    """
    return (v, 1.0 - u)


def main() -> None:
    svg = ART.read_text(encoding="utf-8")
    m = re.search(r'viewBox="([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)"', svg)
    if not m:
        raise SystemExit("no viewBox in %s" % ART)
    vx, vy, vw, vh = (float(g) for g in m.groups())

    # rotate(-90) about the origin sends x to y and y to -x, so the content lands
    # at x in [vy, vy+vh] and y in [-(vx+vw), -vx]. Translate it back to a box
    # that starts at the origin, and swap the viewBox's own extents with it.
    tx = -vy
    ty = vx + vw
    body = svg.split(">", 1)[1] if svg.lstrip().startswith("<?xml") else svg
    inner = svg[svg.index(">", svg.index("<svg")) + 1:]
    inner = inner.rsplit("</svg>", 1)[0]

    head = svg[: svg.index(">", svg.index("<svg")) + 1]
    head = re.sub(r'viewBox="[^"]*"', 'viewBox="0 0 %g %g"' % (vh, vw), head)
    head = re.sub(r'\swidth="[^"]*"', "", head, count=1)
    head = re.sub(r'\sheight="[^"]*"', "", head, count=1)

    OUT.write_text(
        head
        + '\n<g transform="translate(%g,%g) rotate(-90)">' % (tx, ty)
        + inner
        + "</g>\n</svg>\n",
        encoding="utf-8",
    )
    print("wrote %s  (%g x %g)" % (OUT, vh, vw))
    print()
    print('\t\t"anchors": {')
    for target, physical in SIDEWAYS_KEYS.items():
        u, v = rotate_ccw(*UPRIGHT[physical])
        print('\t\t\t"%s": Vector2(%.4f, %.4f),\t# %s' % (target, u, v, physical))
    print("\t\t},")


if __name__ == "__main__":
    main()

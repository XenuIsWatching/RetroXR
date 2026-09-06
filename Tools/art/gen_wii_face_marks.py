"""Cut the Wii Remote's printed marks out of the CONTROLS diagram, one per cap.

The 3D remote in the room and the diagram on the CONTROLS tab now carry the same
seven marks, because they are the same drawing: `gen_wii_remote_art.py` prints
Kenney's glyphs onto the shell art, and this lifts each of them back out as a
square texture sized to the cap it belongs on.

Going through the diagram rather than back to Kenney's zip is the point. The zip
is a 5 MB download nobody has checked out, and the sizing decision — scale each
mark by its BUTTON so a minus stays a minus next to an A — has already been made
there. Re-deriving it here would be a second copy of that judgement, free to
drift.

    python Tools/art/gen_wii_face_marks.py

Every mark comes out 128 square with the cap filling the frame, so the quad that
carries it in the scene is simply the cap's diameter. That works out to one
constant scale for all seven: Kenney draws in a 64 box with the cap at r=24, so
blowing the cap up to 128 is always 128/48.

The INK is re-chosen here, and only where the medium forces it. The diagram's
caps are near-white; these are moulded grey plastic, and POWER's is red. A red
power symbol on a red cap is not a design, it is an absence.
"""

from __future__ import annotations

import io
import os
import re

SRC = "RetroXR/Textures/Controllers/wii_remote.svg"
OUT_DIR = "RetroXR/Textures/Controllers/wii_marks"

# In the order gen_wii_remote_art.py appends them.
MARKS = ["power", "a", "minus", "home", "plus", "one", "two"]

# Kenney's box is 64 with the button circle at r=24 (it spans 8..56). Scaling the
# CIRCLE to the 128 texture is therefore 128/48, whatever size cap it lands on.
TEX = 128.0
SCALE = TEX / 48.0

# Ink, per mark, for a moulded grey cap rather than a near-white diagram.
#
#   a, home   unchanged — #3d3d3d has contrast to spare on Mat_grey, and HOME's
#             blue is the remote's own LED blue, which the shell shares.
#   the greys a stop darker than the diagram's #75757a. That was picked to stay
#             legible on white; these caps are Mat_cap, and grey on grey is not.
#   power     pale, because the cap under it is RED. The diagram inks this red on
#             a white button to say "not a game input"; here the CAP says that.
INK = {
    "power": "#e9e9ec",
    "a": "#3d3d3d",
    "minus": "#4a4a50",
    "home": "#16b4e6",
    "plus": "#4a4a50",
    "one": "#4a4a50",
    "two": "#4a4a50",
}

GROUP = re.compile(
    r'<g transform="translate\([\d.]+ [\d.]+\) scale\([\d.]+\) '
    r'translate\((-?[\d.]+) (-?[\d.]+)\)">\s*<path fill="#[0-9a-f]{6}" d="([^"]+)"/>\s*</g>'
)


def main() -> None:
    src = io.open(SRC, encoding="utf-8").read()
    groups = GROUP.findall(src)
    if len(groups) != len(MARKS):
        raise SystemExit(
            "expected %d mark groups in %s, found %d — has the generator changed?"
            % (len(MARKS), SRC, len(groups))
        )
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, (ox, oy, d) in zip(MARKS, groups):
        svg = (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %g %g">\n'
            '  <g transform="translate(%g %g) scale(%.6f) translate(%s %s)">\n'
            '    <path fill="%s" d="%s"/>\n'
            "  </g>\n"
            "</svg>\n"
            % (TEX, TEX, TEX / 2, TEX / 2, SCALE, ox, oy, INK[name], d)
        )
        path = os.path.join(OUT_DIR, "wii_mark_%s.svg" % name)
        io.open(path, "w", encoding="utf-8", newline="\n").write(svg)
        print("wrote %s" % path)


if __name__ == "__main__":
    main()

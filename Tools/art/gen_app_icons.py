#!/usr/bin/env python3
"""Draw RetroXR's app icons from the vector mark's geometry.

    python Tools/art/gen_app_icons.py

Writes into RetroXR/Textures/ the four files export_presets.cfg points at, plus
the 512 project icon:

    app_icon.png       512   project icon (Godot editor / window)
    app_icon_192.png   192   legacy square launcher icon, full bleed
    app_icon_fg.png    432   adaptive FOREGROUND, real alpha
    app_icon_bg.png    432   adaptive BACKGROUND, opaque, no artwork
    app_icon_mono.png  432   themed icon, white silhouette on alpha

Drawn here rather than exported from game-icons/retroxr-mark.svg on purpose:
the adaptive layers need a genuine alpha channel and exact pixel dimensions,
and every SVG rasteriser on this box either isn't installed or bakes a white
matte in. Geometry below mirrors the SVG in its own 1024 space, so the two stay
in step — change one, change the other.

Everything is drawn at 4x and box-filtered down, which is cheaper to reason
about than per-shape antialiasing and gives cleaner curves.
"""

import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "RetroXR", "Textures")
SS = 4                      # supersample factor
U = 1024                    # design space, matching the SVG viewBox

# ── palette ──────────────────────────────────────────────────────────────────
INK        = (11, 15, 28)
SHELL_TOP  = (255, 255, 255)
SHELL_MID  = (228, 235, 250)
SHELL_BOT  = (185, 197, 224)
STRAP_TOP  = (128, 144, 179)
STRAP_BOT  = (85, 98, 138)
BG_IN      = (27, 36, 64)
BG_OUT     = (11, 15, 28)
PHOS       = [(0.00, (201, 255, 233)), (0.30, (92, 240, 184)),
              (0.68, (28, 201, 142)),  (1.00, (5, 59, 44))]
GLOW       = (28, 201, 142)
PIXEL      = (242, 255, 250)

# ── geometry, in 1024-space (mirrors retroxr-mark.svg) ───────────────────────
SHELL   = (92, 252, 932, 772)          # x0,y0,x1,y1
SHELL_R = 150
STRAP_L = (24, 412, 112, 612)
STRAP_R = (912, 412, 1000, 612)
STRAP_R_ = 40
LENS    = [(332, 512), (692, 512)]
WELL_R  = 168
PHOS_R  = 150
RIM_W   = 14
SCAN_PITCH, SCAN_BAR, SCAN_A = 18, 8, 0.34
LIT     = (284, 464, 326, 506)


def s(v):
    """design units -> supersampled pixels"""
    return int(round(v * SS))


def vgrad(w, h, top, bot):
    t = np.linspace(0, 1, h)[:, None]
    arr = np.zeros((h, w, 3))
    for i in range(3):
        arr[:, :, i] = top[i] * (1 - t) + bot[i] * t
    return Image.fromarray(arr.astype("uint8"), "RGB")


def vgrad3(w, h, top, mid, bot):
    t = np.linspace(0, 1, h)[:, None]
    arr = np.zeros((h, w, 3))
    for i in range(3):
        a = top[i] + (mid[i] - top[i]) * np.clip(t / 0.55, 0, 1)
        b = mid[i] + (bot[i] - mid[i]) * np.clip((t - 0.55) / 0.45, 0, 1)
        arr[:, :, i] = np.where(t < 0.55, a, b)
    return Image.fromarray(arr.astype("uint8"), "RGB")


def radial(size, stops):
    """stops: [(pos 0..1, rgb)] measured from the centre outward."""
    n = size
    y, x = np.mgrid[0:n, 0:n]
    # phosphor hot-spot sits slightly above centre, as in the SVG
    d = np.sqrt((x - n / 2) ** 2 + (y - n * 0.40) ** 2) / (n * 0.68 / 2 * 1.0)
    d = np.clip(d / 2, 0, 1)
    arr = np.zeros((n, n, 3))
    for i in range(len(stops) - 1):
        p0, c0 = stops[i]
        p1, c1 = stops[i + 1]
        m = (d >= p0) & (d <= p1)
        t = np.zeros_like(d)
        t[m] = (d[m] - p0) / max(p1 - p0, 1e-6)
        for ch in range(3):
            arr[:, :, ch] = np.where(m, c0[ch] + (c1[ch] - c0[ch]) * t, arr[:, :, ch])
    arr[d >= stops[-1][0]] = stops[-1][1]
    return Image.fromarray(arr.astype("uint8"), "RGB")


def rr_mask(w, h, box, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=r, fill=255)
    return m


def draw_headset(canvas_u, shadow=True):
    """The headset alone, RGBA with real alpha, on a canvas_u-square canvas."""
    n = s(canvas_u)
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))

    # -- strap stubs
    for box in (STRAP_L, STRAP_R):
        w, h = s(box[2] - box[0]), s(box[3] - box[1])
        g = vgrad(w, h, STRAP_TOP, STRAP_BOT).convert("RGBA")
        g.putalpha(rr_mask(w, h, (0, 0, w - 1, h - 1), s(STRAP_R_)))
        img.alpha_composite(g, (s(box[0]), s(box[1])))

    # -- shell body
    sw, sh = s(SHELL[2] - SHELL[0]), s(SHELL[3] - SHELL[1])
    body = vgrad3(sw, sh, SHELL_TOP, SHELL_MID, SHELL_BOT).convert("RGBA")
    body.putalpha(rr_mask(sw, sh, (0, 0, sw - 1, sh - 1), s(SHELL_R)))
    img.alpha_composite(body, (s(SHELL[0]), s(SHELL[1])))

    # brow highlight: top third of the shell, softened
    brow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(brow).rounded_rectangle(
        (s(SHELL[0]), s(SHELL[1]), s(SHELL[2]), s(SHELL[1] + 150)),
        radius=s(SHELL_R), fill=(255, 255, 255, 128))
    keep = Image.new("L", (n, n), 0)
    ImageDraw.Draw(keep).rounded_rectangle(
        (s(SHELL[0]), s(SHELL[1]), s(SHELL[2]), s(SHELL[3])), radius=s(SHELL_R), fill=255)
    brow.putalpha(Image.composite(brow.getchannel("A"), Image.new("L", (n, n), 0), keep))
    img.alpha_composite(brow)

    # shell outline
    ImageDraw.Draw(img).rounded_rectangle(
        (s(SHELL[0]), s(SHELL[1]), s(SHELL[2]), s(SHELL[3])),
        radius=s(SHELL_R), outline=INK + (255,), width=s(12))

    # -- lenses
    d = ImageDraw.Draw(img)
    for (cx, cy) in LENS:
        d.ellipse((s(cx - WELL_R), s(cy - WELL_R), s(cx + WELL_R), s(cy + WELL_R)),
                  fill=INK + (255,))

    pn = s(PHOS_R * 2)
    phos = radial(pn, PHOS).convert("RGBA")
    circ = Image.new("L", (pn, pn), 0)
    ImageDraw.Draw(circ).ellipse((0, 0, pn - 1, pn - 1), fill=255)
    # scanlines, baked into the phosphor before masking
    sl = ImageDraw.Draw(phos)
    for yy in range(0, pn, s(SCAN_PITCH)):
        sl.rectangle((0, yy, pn, yy + s(SCAN_BAR)), fill=(2, 22, 15, int(255 * SCAN_A)))
    phos.putalpha(circ)
    for (cx, cy) in LENS:
        img.alpha_composite(phos, (s(cx - PHOS_R), s(cy - PHOS_R)))

    # one lit pixel, then the rims over the top
    d = ImageDraw.Draw(img)
    d.rectangle((s(LIT[0]), s(LIT[1]), s(LIT[2]), s(LIT[3])), fill=PIXEL + (255,))
    for (cx, cy) in LENS:
        d.ellipse((s(cx - PHOS_R), s(cy - PHOS_R), s(cx + PHOS_R), s(cy + PHOS_R)),
                  outline=INK + (255,), width=s(RIM_W))

    if shadow:
        sh_img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        sh_img.putalpha(img.getchannel("A").point(lambda v: int(v * 0.55)))
        sh_img = sh_img.filter(ImageFilter.GaussianBlur(s(24)))
        base = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        base.alpha_composite(sh_img, (0, s(20)))
        base.alpha_composite(img)
        img = base
    return img


def backdrop(canvas_u):
    n = s(canvas_u)
    y, x = np.mgrid[0:n, 0:n]
    d = np.clip(np.sqrt((x - n / 2) ** 2 + (y - n * 0.45) ** 2) / (n * 0.78), 0, 1)
    arr = np.zeros((n, n, 3))
    for i in range(3):
        arr[:, :, i] = BG_IN[i] * (1 - d) + BG_OUT[i] * d
    bg = Image.fromarray(arr.astype("uint8"), "RGB").convert("RGBA")
    glow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        (s(132), s(242), s(892), s(782)), fill=GLOW + (41,))
    bg.alpha_composite(glow.filter(ImageFilter.GaussianBlur(s(30))))
    return bg


def save(img, name, size):
    img.resize((size, size), Image.LANCZOS).save(os.path.join(OUT, name))
    print(f"  {name:20} {size}x{size}")


def main():
    full = backdrop(U)
    full.alpha_composite(draw_headset(U))
    save(full.convert("RGB").convert("RGBA"), "app_icon.png", 512)
    save(full.convert("RGB").convert("RGBA"), "app_icon_192.png", 192)

    # Adaptive foreground: the launcher masks this and only the centre 288 of
    # 432 is guaranteed. At a 330px shell the mask ate both shell edges and the
    # whole strap, leaving a white band — 240 puts even the outer strap corner
    # at r=142 of the 144 safe radius, so the silhouette survives a circle mask.
    fg = Image.new("RGBA", (s(U), s(U)), (0, 0, 0, 0))
    fg.alpha_composite(draw_headset(U, shadow=False))
    # Resize the whole 1024 canvas so the SHELL alone lands at 240px of the 432
    # output — do NOT also apply a 432/1024 conversion, that shrinks it twice
    # and leaves the headset a third of the tile.
    scale = 240.0 / (SHELL[2] - SHELL[0])
    tgt = int(round(U * scale * SS))
    fg = fg.resize((tgt, tgt), Image.LANCZOS)
    canvas = Image.new("RGBA", (s(432), s(432)), (0, 0, 0, 0))
    off = (s(432) - tgt) // 2
    canvas.alpha_composite(fg, (off, off))
    save(canvas, "app_icon_fg.png", 432)

    save(backdrop(U).convert("RGB").convert("RGBA"), "app_icon_bg.png", 432)

    # Themed icon: flat white silhouette of the shell + straps, alpha only.
    sil = Image.new("RGBA", (s(U), s(U)), (0, 0, 0, 0))
    dd = ImageDraw.Draw(sil)
    for box in (STRAP_L, STRAP_R):
        dd.rounded_rectangle((s(box[0]), s(box[1]), s(box[2]), s(box[3])),
                             radius=s(STRAP_R_), fill=(255, 255, 255, 255))
    dd.rounded_rectangle((s(SHELL[0]), s(SHELL[1]), s(SHELL[2]), s(SHELL[3])),
                         radius=s(SHELL_R), fill=(255, 255, 255, 255))
    # punch the lenses out so it still reads as a headset when flattened
    for (cx, cy) in LENS:
        dd.ellipse((s(cx - PHOS_R), s(cy - PHOS_R), s(cx + PHOS_R), s(cy + PHOS_R)),
                   fill=(255, 255, 255, 0))
    sil = sil.resize((tgt, tgt), Image.LANCZOS)
    mono = Image.new("RGBA", (s(432), s(432)), (0, 0, 0, 0))
    mono.alpha_composite(sil, (off, off))
    save(mono, "app_icon_mono.png", 432)


if __name__ == "__main__":
    main()

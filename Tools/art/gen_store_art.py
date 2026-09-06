#!/usr/bin/env python3
"""Draw the SideQuest store art from the same mark as the app icons.

    python Tools/art/gen_store_art.py

Writes into game-icons/:

    retroxr-icon.jpg     1024x1024  square store icon, full bleed
    retroxr-listing.jpg  1280x720   16:9 cover, mark over the wordmark

Reuses Tools/art/gen_app_icons.py for the headset and the palette so the store
art and the shipped launcher icon can never drift apart. The lockup in
game-icons/retroxr-lockup.svg is the 1600x520 sibling of this layout; that
aspect suits mark-left/word-right, 16:9 does not, so this one stacks.

JPEG because SideQuest's uploader takes jpg/png and these have no alpha to
preserve; quality 92 with subsampling off keeps the wordmark edges clean
(the default 4:2:0 chroma subsampling smears the green "XR" against the
dark backdrop).
"""

import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

import gen_app_icons as M

OUT = os.path.join(os.path.dirname(__file__), "..", "game-icons")

WORD_LIGHT = (238, 243, 255)
WORD_ACCENT = (45, 227, 167)        # the phosphor green, so type and lenses match

# Segoe UI Black first — it is the weight retroxr-lockup.svg asks for (800).
FONTS = ["seguibl.ttf", "ariblk.ttf", "arialbd.ttf"]


def load_font(px):
    for name in FONTS:
        p = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts", name)
        if os.path.exists(p):
            return ImageFont.truetype(p, px)
    raise SystemExit("no heavy sans font found; tried " + ", ".join(FONTS))


def wide_backdrop(w, h):
    """The square icon's radial backdrop, stretched to an arbitrary aspect."""
    y, x = np.mgrid[0:h, 0:w]
    d = np.clip(np.sqrt(((x - w / 2) / (w * 0.62)) ** 2
                        + ((y - h * 0.42) / (h * 0.78)) ** 2), 0, 1)
    arr = np.zeros((h, w, 3))
    for i in range(3):
        arr[:, :, i] = M.BG_IN[i] * (1 - d) + M.BG_OUT[i] * d
    bg = Image.fromarray(arr.astype("uint8"), "RGB").convert("RGBA")

    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        (w * 0.20, h * 0.10, w * 0.80, h * 0.62), fill=M.GLOW + (46,))
    bg.alpha_composite(glow.filter(ImageFilter.GaussianBlur(w * 0.05)))
    return bg


def headset_at(shell_px):
    """The mark, resized so its shell body spans shell_px across."""
    hs = M.draw_headset(M.U)
    scale = shell_px / (M.SHELL[2] - M.SHELL[0])
    n = int(round(M.U * scale))
    return hs.resize((n, n), Image.LANCZOS), scale


def fit_font(text, target_px):
    """Largest size whose rendered advance width is <= target_px."""
    size = 10
    while True:
        f = load_font(size + 8)
        if ImageDraw.Draw(Image.new("L", (1, 1))).textlength(text, f) > target_px:
            return load_font(size)
        size += 8


def draw_wordmark(img, cx, baseline, target_px):
    """"Retro" light + "XR" accent, centred on cx, sitting on `baseline`."""
    font = fit_font("RetroXR", target_px)
    d = ImageDraw.Draw(img)
    w_all = d.textlength("RetroXR", font)
    w_ret = d.textlength("Retro", font)
    x = cx - w_all / 2

    # drop shadow first, as one pass over the whole word, so the two colour
    # runs do not each cast their own edge into the other
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ds = ImageDraw.Draw(sh)
    ds.text((x, baseline), "RetroXR", font=font, fill=(0, 0, 0, 170), anchor="ls")
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(img.width * 0.006)))

    d.text((x, baseline), "Retro", font=font, fill=WORD_LIGHT + (255,), anchor="ls")
    d.text((x + w_ret, baseline), "XR", font=font, fill=WORD_ACCENT + (255,), anchor="ls")


def save_jpg(img, name):
    p = os.path.join(OUT, name)
    img.convert("RGB").save(p, "JPEG", quality=92, subsampling=0, optimize=True)
    print(f"  {name:22} {img.width}x{img.height}  {os.path.getsize(p) // 1024} KB")


def main():
    # ── square store icon: identical composition to app_icon.png, 1024 ────────
    icon = M.backdrop(M.U)
    icon.alpha_composite(M.draw_headset(M.U))
    save_jpg(icon.resize((1024, 1024), Image.LANCZOS), "retroxr-icon.jpg")

    # ── 16:9 cover: mark above, wordmark below ───────────────────────────────
    W, H = 1280, 720
    cover = wide_backdrop(W, H)

    # 470, not 560: at 560 the shell cleared the top edge by ~20px and the
    # wordmark sat on the bottom one. This leaves ~110 top / ~130 bottom.
    mark, scale = headset_at(470)
    # centre the SHELL (not the 1024 canvas) on the composition's optical axis
    shell_cx = (M.SHELL[0] + M.SHELL[2]) / 2 * scale
    shell_cy = (M.SHELL[1] + M.SHELL[3]) / 2 * scale
    cover.paste(mark, (int(W / 2 - shell_cx), int(H * 0.355 - shell_cy)), mark)

    draw_wordmark(cover, W / 2, H * 0.815, W * 0.50)
    save_jpg(cover, "retroxr-listing.jpg")

    # ── banner ───────────────────────────────────────────────────────────────
    # Measured off SideQuest's own Banner-Guidelines.png rather than the
    # "16:9, 1280px" line in the page hints, which does not describe this slot:
    #   full canvas  2048 x 512   (4:1 — the outer thirds get cropped)
    #   mobile band  x  724..1323 (600 wide, all that survives on a phone)
    #   safe space   x  752..1295, y 172..383  — logo/important content here
    # So the artwork is CENTRED, not offset; an earlier pass put it at x~1340,
    # outside both the safe box and the mobile band.
    BW, BH = 2048, 512
    SAFE = (752, 172, 1295, 383)
    ban = wide_backdrop(BW, BH)

    hot = Image.new("RGBA", (BW, BH), (0, 0, 0, 0))
    ImageDraw.Draw(hot).ellipse((BW * 0.28, -BH * 0.30, BW * 0.72, BH * 1.30),
                                fill=M.GLOW + (58,))
    ban.alpha_composite(hot.filter(ImageFilter.GaussianBlur(BW * 0.045)))

    # Lay the 1600x520 lockup out inside the safe box: mark left, word right.
    s = 520.0 / 1600.0
    ox, oy = (SAFE[0] + SAFE[2]) / 2 - 1600 * s / 2, (SAFE[1] + SAFE[3]) / 2 - 520 * s / 2
    bmark, bscale = headset_at(604 * s)          # lockup shell is 604 wide
    ban.paste(bmark,
              (int(ox + 382 * s - (M.SHELL[0] + M.SHELL[2]) / 2 * bscale),
               int(oy + 260 * s - (M.SHELL[1] + M.SHELL[3]) / 2 * bscale)), bmark)
    draw_wordmark(ban, ox + 1180 * s, oy + 330 * s, 760 * s)

    # a whole-field scanline wash, tying the banner to the lenses
    scan = Image.new("RGBA", (BW, BH), (0, 0, 0, 0))
    sd = ImageDraw.Draw(scan)
    for yy in range(0, BH, 4):
        sd.rectangle((0, yy, BW, yy + 1), fill=(0, 0, 0, 26))
    ban.alpha_composite(scan)

    save_jpg(ban, "retroxr-banner.jpg")




def meta_store_assets():
    """Meta Horizon Store dashboard assets.

    The Quest library icon is NOT read from the APK — it is uploaded to the
    Developer Dashboard. Per Meta's asset guidelines: 512x512, 24-bit PNG,
    squared corners, NO transparency. Optional spatialized layers are 180x180
    with the foreground inside a safe area leaving 18dp padding.
    """
    icon = M.backdrop(M.U)
    icon.alpha_composite(M.draw_headset(M.U))
    # .convert("RGB") is the point: the guidelines forbid transparency here
    p = os.path.join(OUT, "meta-store-icon-512.png")
    icon.convert("RGB").resize((512, 512), Image.LANCZOS).save(p)
    print(f"  {'meta-store-icon-512.png':32} 512x512  RGB, no alpha")

    # spatialized pair: 180x180, foreground keeps 18dp of padding on every side
    S, PAD = 180, 18
    inner = S - 2 * PAD                       # 144 of 180
    fg = Image.new("RGBA", (M.s(M.U), M.s(M.U)), (0, 0, 0, 0))
    fg.alpha_composite(M.draw_headset(M.U, shadow=False))
    scale = inner / (M.STRAP_R[2] - M.STRAP_L[0])   # fit the FULL mark, straps included
    tgt = int(round(M.U * scale * M.SS))
    fg = fg.resize((tgt, tgt), Image.LANCZOS)
    canvas = Image.new("RGBA", (M.s(S), M.s(S)), (0, 0, 0, 0))
    off = (M.s(S) - tgt) // 2
    canvas.alpha_composite(fg, (off, off))
    canvas.resize((S, S), Image.LANCZOS).save(os.path.join(OUT, "meta-spatial-foreground-180.png"))
    print(f"  {'meta-spatial-foreground-180.png':32} {S}x{S}  RGBA, {PAD}dp padding")

    bg = M.backdrop(M.U).convert("RGB").resize((S, S), Image.LANCZOS)
    bg.save(os.path.join(OUT, "meta-spatial-background-180.png"))
    print(f"  {'meta-spatial-background-180.png':32} {S}x{S}  RGB")


if __name__ == "__main__":
    main()
    if os.environ.get("META_ASSETS"):
        meta_store_assets()

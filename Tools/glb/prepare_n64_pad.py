#!/usr/bin/env python3
"""Turn the raw N64 controller scan into the shell RetroXR ships.

Four jobs, in this order:

  1. Drop the ``N64_Controller_BACKUP`` mesh. The source carries the body twice
     -- ``Body`` (2102 tris) and a 3520-tri copy occupying the identical AABB.
     Both draw, so the shipped pad would render its own shell twice, z-fighting
     against itself, for 3520 wasted triangles.

  2. Clear the two trademark marks:

       - the ``Nintendo(R)`` wordmark on the front face, inside a moulded badge
       - the Nintendo 64 "N" logo and the ``NUS-005 ... 64 CONTROLLER`` legend
         moulded into the underside

     From EVERY map, not just the normal one, and that is the trap this asset
     sets. The wordmark is embossed in the normal map AND painted into the base
     colour, and its albedo contrast is about six levels out of 255 -- invisible
     when the region is eyeballed or summarised as a min/max, and perfectly
     legible in a render, where it reads as flat grey lettering with no relief
     at all. Clearing only the normal map removes the moulding and leaves the
     printing untouched. So the mask is computed once (from the normal map,
     where the badge frame is legible) and applied to all three.

     The badge's OUTLINE is kept and only its interior cleared, so the front
     face still carries the moulded oval a real pad has -- an empty badge reads
     as a blank plate rather than as a scrubbed one. The underside legend has no
     such frame and goes entirely.

     Clearing means RECONSTRUCTING each region from the surface around it --
     normalised convolution, so the fill is an interpolation of the hole's own
     borders -- plus grain matched to the neighbouring plain surface. Not a
     donor patch copied from elsewhere on the map: on this asset the patch that
     scores flattest still carries more contrast than the faint albedo wordmark
     it would cover, which makes that map measurably worse. And not a flat fill
     either, which would leave a mirror-smooth rectangle on a finely noisy
     shell, visible from a distance under a moving highlight.

  3. Resize the three 4096x4096 maps. A pad held at 30 cm does not need 4K, and
     three of them is ~50 MB of Quest VRAM for one hand prop.

  4. Flatten the four Sketchfab/FBX wrapper nodes. Their two rotations cancel to
     identity, so they compose to nothing and only deepen the imported tree.

Verification is built in and covers every map. --verify re-reads the written
file and reports, per map and per mark, what share of that mark's ORIGINAL
contrast still shows -- measured only where the source actually has the mark,
and relative to the source's own contrast there, so the number reads directly:
100% is an untouched mark, 0% a region that now matches the plain surface
beside it. Anchoring on the source is what makes the check able to go red;
`remaining_mark` refuses outright rather than passing if it cannot find the
mark, separate it from its surround, or measure it.

The check is NOT the last word, though, and this asset is why: its albedo
wordmark is six grey levels, which several plausible texel statistics call
clean and a single render does not. Look at the thing.

    python Tools/glb/prepare_n64_pad.py \
        --in ~/Downloads/n64_controller.glb \
        --out RetroXR/imported-assets/controllers/n64/n64_controller.glb
"""

from __future__ import annotations

import argparse
import io
import json
import os
import struct
import sys

import numpy as np
from PIL import Image

# ── The two marks, in source (4096) texel coordinates ────────────────────────
# Measured off the source normal map, not guessed: each is the bounding box of
# the embossing at a threshold that separates moulded relief from surface noise.
#
# BADGE is the wordmark's enclosing badge, cleared in "interior" mode -- the
# frame is found in the image and only what it encloses is cleared. A rectangle
# cannot do this job: the badge is a rounded rectangle whose corners curve in to
# x~2236 while its straight sides sit at x~2254, and the (R) reaches x=2244 at
# a height where the frame is clear of it. Any box wide enough for the (R) eats
# the corners, and any box that spares the corners leaves an arc of the (R)
# standing. Finding the frame sidesteps the whole conflict.
BADGE = (1728, 3726, 2270, 3858)
# The underside legend has no enclosing frame -- "all" mode clears the box.
LEGEND = (3820, 3155, 4005, 3350)
MARKS: dict[str, tuple[tuple[int, int, int, int], str]] = {
    "badge": (BADGE, "interior"),
    "legend": (LEGEND, "all"),
}

# Wrapper nodes the source nests the geometry under. Removed only after their
# composed transform is confirmed to be identity.
WRAPPERS = ("Sketchfab_model", "N64_Controller_02.FBX", "RootNode", "polySurface2")

DROP_MESHES = ("N64_Controller_BACKUP",)

ROOT_NAME = "N64Controller"

# The source is modelled in centimetres (the body measures 15.93 units across a
# controller that is 159 mm wide), and RetroXR works in metres.
#
# Baked into the geometry here rather than left to the importer's
# nodes/root_scale, because the two are NOT equivalent for this asset. A root
# scale scales the root node, so every button keeps its centimetre-space local
# transform and the press depths ControlAnimator applies -- which are plain
# metres for every other pad in the project -- would land 100x too small. Baking
# it means the imported tree is already metric and a depth of 0.002 really is
# 2 mm.
SCALE = 0.01

# Per-map output size. The normal map keeps the most resolution because it is
# the only one carrying the moulded relief -- the letters on the buttons, the
# grip texture, the seams. Base colour is near-flat grey with a handful of solid
# colour islands, and roughness is near-uniform; both survive a harder cut.
SIZES = {"blinn1_normal": 2048, "blinn1_baseColor": 1024, "blinn1_metallicRoughness": 512}

## The map the marks are LOCATED in. The badge's frame only exists as relief, so
## the region to clear can only be derived here -- and is then reused verbatim on
## the other maps, which share this one's UV layout.
NORMAL_MAP = "blinn1_normal"


# ── GLB container ────────────────────────────────────────────────────────────

def read_glb(path: str) -> tuple[dict, bytes]:
    d = open(path, "rb").read()
    if d[:4] != b"glTF":
        raise SystemExit(f"{path}: not a GLB")
    n = struct.unpack("<I", d[12:16])[0]
    gltf = json.loads(d[20 : 20 + n])
    off = 20 + n
    blen, btype = struct.unpack("<II", d[off : off + 8])
    if btype != 0x004E4942:
        raise SystemExit(f"{path}: second chunk is not BIN")
    return gltf, d[off + 8 : off + 8 + blen]


def write_glb(path: str, gltf: dict, blob: bytes) -> None:
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    bl = blob + b"\0" * (-len(blob) % 4)
    total = 12 + 8 + len(js) + 8 + len(bl)
    with open(path, "wb") as f:
        f.write(b"glTF" + struct.pack("<II", 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        f.write(struct.pack("<II", len(bl), 0x004E4942) + bl)


# ── Mark removal ─────────────────────────────────────────────────────────────

def deviation(arr: np.ndarray) -> np.ndarray:
    """How far each texel's normal tilts off flat. Relief shows, noise does not.

    Normal maps only -- this is what makes the badge FRAME findable, and the
    frame is what defines the region to clear.
    """
    a = arr.astype(np.int16)
    return np.abs(a[:, :, 0] - 128) + np.abs(a[:, :, 1] - 128)


## Radius of the background blur `contrast` measures against. Wide enough to
## span a letter stroke (so the letter stands out from it) and narrow enough to
## follow the shell's own broad shading (so a curved panel does not read as one
## enormous mark).
CONTRAST_SIGMA = 6.0


def contrast(arr: np.ndarray) -> np.ndarray:
    """Local contrast: how far each texel departs from its blurred surroundings.

    Works on any map. A mark is a local departure from the background whether it
    is moulded (normal map) or printed (albedo), which is the whole point --
    measuring relief alone misses a wordmark that is only six levels of grey.
    """
    from scipy import ndimage

    a = arr.astype(np.float32)
    bg = np.stack([ndimage.gaussian_filter(a[:, :, c], CONTRAST_SIGMA)
                   for c in range(a.shape[2])], axis=2)
    return np.abs(a - bg).sum(axis=2)


def feather(w: int, h: int, edge: int) -> np.ndarray:
    """A 0..1 mask, 1 in the middle, ramping to 0 over `edge` texels."""
    def ramp(n: int) -> np.ndarray:
        v = np.ones(n, np.float32)
        e = min(edge, n // 2)
        if e > 0:
            r = np.linspace(0.0, 1.0, e + 2)[1:-1]
            v[:e], v[-e:] = r, r[::-1]
        return v
    return np.outer(ramp(h), ramp(w))[:, :, None]


def fill_region(arr: np.ndarray, mask: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Replace the masked texels with the surface that surrounds them.

    Normalised convolution: blur the image with the masked texels given zero
    weight, and divide by the blurred weight. What comes back inside the hole is
    an interpolation of its own borders, so the fill takes the exact local level
    of whatever it replaces -- no seam, and no possibility of importing a feature
    from somewhere else on the map, which is what a copied donor patch does. On
    this asset a donor patch makes the albedo map measurably WORSE: the patch
    that scores flattest still carries more contrast than the faint wordmark it
    would be covering.

    Grain is then added back as noise matched to the surrounding surface's own,
    because a perfectly smooth patch on a finely noisy shell reads as a
    rectangle under a moving highlight.
    """
    from scipy import ndimage

    ys, xs = np.nonzero(mask > 0.0)
    if len(xs) == 0:
        return arr
    H, W = mask.shape
    sigma = max(8.0, 0.35 * max(xs.max() - xs.min(), ys.max() - ys.min()))

    w = (1.0 - np.clip(mask, 0.0, 1.0)).astype(np.float32)
    den = ndimage.gaussian_filter(w, sigma, mode="nearest")
    bg = np.empty_like(arr)
    for c in range(arr.shape[2]):
        num = ndimage.gaussian_filter(arr[:, :, c] * w, sigma, mode="nearest")
        bg[:, :, c] = num / np.maximum(den, 1e-6)

    # Grain amplitude from PLAIN surface only: unmasked texels whose own local
    # residual is small. Measuring it from a ring around the mask instead is
    # wrong for the badge, whose ring IS the moulded frame -- that estimate came
    # out enormous and filled the badge with loud noise, which then measured as
    # a surviving mark.
    solid = mask > 0.5
    resid = np.stack([arr[:, :, c] - ndimage.gaussian_filter(arr[:, :, c], 2.0, mode="nearest")
                      for c in range(arr.shape[2])], axis=2)
    strength = np.abs(resid).sum(axis=2)
    near = ndimage.binary_dilation(solid, iterations=FILL_MARGIN // 2)
    plain = near & ~solid & (strength < np.percentile(strength[~solid], 60))
    out = bg.copy()
    if plain.sum() > 64:
        for c in range(arr.shape[2]):
            amp = float(resid[:, :, c][plain].std())
            out[:, :, c] += rng.normal(0.0, amp, size=arr.shape[:2]).astype(np.float32)

    m = np.clip(mask, 0.0, 1.0)[:, :, None]
    return arr * (1.0 - m) + out * m


## Relief strong enough to be the badge's own moulded frame.
FRAME_THRESHOLD = 45
## How far to hold the clear off the frame, so its shaded inner edge survives.
FRAME_KEEP = 3


def interior_mask(dev: np.ndarray, box: tuple[int, int, int, int]) -> np.ndarray:
    """Everything the badge's frame encloses, excluding the frame itself.

    The frame is the largest relief component in the box -- a closed ring, so
    filling its holes yields frame-plus-interior and subtracting the ring back
    off yields the interior alone, letters and (R) included, whatever shape the
    frame happens to be.
    """
    from scipy import ndimage

    x0, y0, x1, y1 = box
    sub = dev[y0:y1, x0:x1] > FRAME_THRESHOLD
    lab, n = ndimage.label(sub)
    if n == 0:
        raise SystemExit(f"no relief found in badge box {box}")
    sizes = ndimage.sum(sub, lab, range(1, n + 1))
    ring = lab == (int(np.argmax(sizes)) + 1)
    filled = ndimage.binary_fill_holes(ring)
    inner = filled & ~ndimage.binary_dilation(ring, iterations=FRAME_KEEP)
    if not inner.any():
        raise SystemExit(f"badge frame in {box} is not a closed ring; cannot "
                         f"find its interior")
    return inner


def build_masks(normal: Image.Image, edge: int = 5) -> dict[str, np.ndarray]:
    """Per-mark blend weights, computed ONCE from the normal map.

    The badge's frame is only legible as relief, so the region to clear can only
    be derived from the normal map -- and then the SAME region must be applied
    to the albedo and roughness maps, which share the UV layout. Deriving a mask
    separately per map would find a different region in each (the albedo has no
    frame to find at all) and leave part of the mark standing somewhere.
    """
    from scipy import ndimage

    dev = deviation(np.asarray(normal.convert("RGB")))
    masks: dict[str, np.ndarray] = {}
    for name, ((x0, y0, x1, y1), mode) in MARKS.items():
        if mode == "interior":
            inner = interior_mask(dev, (x0, y0, x1, y1))
            # Soften the mask's own edge the way `feather` softens a box's, so
            # the donor does not meet the original along a hard 1-texel step.
            m = ndimage.uniform_filter(inner.astype(np.float32), size=2 * edge + 1) * inner
        else:
            m = feather(x1 - x0, y1 - y0, edge)[:, :, 0]
        masks[name] = m
    return masks


## Margin of untouched surface `fill_region` gets to reconstruct a hole from.
FILL_MARGIN = 96


def clear_marks(img: Image.Image, masks: dict[str, np.ndarray], seed: int = 7) -> dict:
    """Reconstruct every mark's region from the surface around it."""
    arr = np.asarray(img.convert("RGB")).astype(np.float32)
    rng = np.random.default_rng(seed)     # deterministic: same input, same output
    report: dict[str, dict] = {}
    for name, ((x0, y0, x1, y1), _mode) in MARKS.items():
        # Work on a crop with a margin, so the reconstruction has real
        # surrounding surface to interpolate from rather than the hole's own edge.
        cx0, cy0 = max(0, x0 - FILL_MARGIN), max(0, y0 - FILL_MARGIN)
        cx1, cy1 = min(arr.shape[1], x1 + FILL_MARGIN), min(arr.shape[0], y1 + FILL_MARGIN)
        crop = arr[cy0:cy1, cx0:cx1]
        m = np.zeros(crop.shape[:2], np.float32)
        m[y0 - cy0 : y1 - cy0, x0 - cx0 : x1 - cx0] = masks[name]
        arr[cy0:cy1, cx0:cx1] = fill_region(crop, m, rng)
        report[name] = {"box": (x0, y0, x1, y1),
                        "texels": int((masks[name] > 0.5).sum())}
    return {"image": Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB"),
            "marks": report}


## Fraction of a mark's original contrast that may still be present. Well below
## anything readable: at 5% a wordmark is indistinguishable from surface grain.
MARK_MAX_REMAINING = 0.05

## A source texel carrying at least this share of the mark's peak residual is
## treated as part of the mark, and is where the output gets measured. Sampling
## the whole box instead would dilute the measurement with the plain surface
## around the letters, which is identical in both and hides a surviving mark.
MARK_CORE_QUANTILE = 0.90


def residual(arr: np.ndarray) -> np.ndarray:
    """Per-texel departure from the local background, summed over channels.

    The mark's signal whatever map it is in: moulded relief in a normal map and
    printed lettering in an albedo map are both local departures, and the same
    measurement finds either.
    """
    from scipy import ndimage

    a = arr.astype(np.float32)
    bg = np.stack([ndimage.gaussian_filter(a[:, :, c], CONTRAST_SIGMA, mode="nearest")
                   for c in range(a.shape[2])], axis=2)
    return np.abs(a - bg).sum(axis=2)


def remaining_mark(src: np.ndarray, out: np.ndarray,
                   region: np.ndarray) -> tuple[float, int]:
    """How much of the source's mark still shows in the output, as a fraction.

    Measured only where the SOURCE actually has the mark, and expressed relative
    to the source's own contrast there, so the answer is directly readable: 1.0
    means the mark is fully intact, 0.0 that the region now matches the plain
    surface beside it. Grain added by the fill does not inflate it, because
    grain is uncorrelated with the letter shapes and is subtracted off as the
    floor.
    """
    from scipy import ndimage

    sr, orr = residual(src), residual(out)
    # Pull the measured area in off the region's own border. The badge's frame
    # sits immediately outside it and is KEPT, and its contrast blurs inward
    # over CONTRAST_SIGMA -- present identically in source and output, so it
    # reads as a surviving mark and swamps the letters it sits beside.
    sel = ndimage.binary_erosion(region > 0.5, iterations=int(2 * CONTRAST_SIGMA))
    if sel.sum() < 64:
        raise SystemExit("mark region is empty once its border is excluded; "
                         "the mark coordinates have drifted or the region is "
                         "too thin to measure")
    core = sel & (sr >= np.quantile(sr[sel], MARK_CORE_QUANTILE))
    rest = sel & ~core
    if core.sum() < 32 or rest.sum() < 32:
        raise SystemExit("cannot separate the mark from its surround")
    # Floor = the plain surface inside the same region, per image, so each side
    # is compared against its own noise level rather than against zero.
    src_signal = float(sr[core].mean() - sr[rest].mean())
    out_signal = float(orr[core].mean() - orr[rest].mean())
    if src_signal <= 1e-6:
        raise SystemExit("the source shows no mark here; nothing to verify against")
    return max(0.0, out_signal / src_signal), int(core.sum())


# ── Node surgery ─────────────────────────────────────────────────────────────

def quat_mul(a: list[float], b: list[float]) -> list[float]:
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return [aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz]


def flatten_tree(gltf: dict) -> list[str]:
    """Collapse the wrapper chain, drop DROP_MESHES, return what was dropped."""
    nodes = gltf["nodes"]
    by_name = {n.get("name"): i for i, n in enumerate(nodes)}

    # Confirm the wrappers really compose to identity before discarding them.
    q = [0.0, 0.0, 0.0, 1.0]
    for w in WRAPPERS:
        i = by_name.get(w)
        if i is None:
            continue
        n = nodes[i]
        if "matrix" in n or "scale" in n or n.get("translation", [0, 0, 0]) != [0, 0, 0]:
            raise SystemExit(f"wrapper {w!r} carries a translation/scale; not safe to flatten")
        q = quat_mul(q, n.get("rotation", [0.0, 0.0, 0.0, 1.0]))
    if max(abs(q[0]), abs(q[1]), abs(q[2])) > 1e-5 or abs(abs(q[3]) - 1.0) > 1e-5:
        raise SystemExit(f"wrapper rotations do not cancel (composed {q}); not safe to flatten")

    keep, dropped = [], []
    for i, n in enumerate(nodes):
        name = n.get("name", "")
        if name in WRAPPERS:
            continue
        if name in DROP_MESHES:
            dropped.append(name)
            continue
        keep.append(i)

    new_nodes = [{"name": ROOT_NAME, "children": list(range(1, len(keep) + 1))}]
    for i in keep:
        n = dict(nodes[i])
        n.pop("children", None)
        new_nodes.append(n)
    gltf["nodes"] = new_nodes
    gltf["scenes"] = [{"nodes": [0]}]
    gltf["scene"] = 0
    return dropped


def rescale(gltf: dict, blob: bytearray, factor: float) -> None:
    """Scale every POSITION accessor and node translation in place."""
    pos_accessors: set[int] = set()
    for mesh in gltf["meshes"]:
        for prim in mesh["primitives"]:
            a = prim.get("attributes", {}).get("POSITION")
            if a is not None:
                pos_accessors.add(a)
    for ai in sorted(pos_accessors):
        acc = gltf["accessors"][ai]
        if acc["componentType"] != 5126 or acc["type"] != "VEC3":
            raise SystemExit(f"accessor {ai}: POSITION is not float32 VEC3; "
                             f"cannot rescale in place")
        bv = gltf["bufferViews"][acc["bufferView"]]
        stride = bv.get("byteStride", 12)
        if stride != 12:
            raise SystemExit(f"accessor {ai}: interleaved POSITION (stride "
                             f"{stride}); cannot rescale in place")
        base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
        n = acc["count"] * 3
        vals = np.frombuffer(bytes(blob[base : base + n * 4]), np.float32) * factor
        blob[base : base + n * 4] = vals.astype(np.float32).tobytes()
        for key in ("min", "max"):
            if key in acc:
                acc[key] = [v * factor for v in acc[key]]
    for node in gltf["nodes"]:
        if "translation" in node:
            node["translation"] = [v * factor for v in node["translation"]]


def prune(gltf: dict, blob: bytes) -> bytes:
    """Rebuild meshes, accessors, bufferViews and the BIN chunk from live nodes.

    Rebuilding all four together, rather than only the bufferViews, is the
    point. Dropping a node leaves its mesh in ``meshes[]`` and its accessors in
    ``accessors[]``, and glTF's importer parses every mesh in the file whether a
    node references it or not -- so an orphan accessor still pointing at a
    bufferView that pruning renumbered is a hard import error, not dead weight.
    """
    live_meshes = sorted({n["mesh"] for n in gltf["nodes"] if "mesh" in n})
    mesh_remap = {old: new for new, old in enumerate(live_meshes)}

    live_acc: list[int] = []
    for mi in live_meshes:
        for prim in gltf["meshes"][mi]["primitives"]:
            live_acc += list(prim.get("attributes", {}).values())
            if "indices" in prim:
                live_acc.append(prim["indices"])
    live_acc = sorted(set(live_acc))
    acc_remap = {old: new for new, old in enumerate(live_acc)}

    used = sorted({gltf["accessors"][a]["bufferView"] for a in live_acc
                   if "bufferView" in gltf["accessors"][a]}
                  | {im["bufferView"] for im in gltf.get("images", [])
                     if "bufferView" in im})

    out = bytearray()
    bv_remap: dict[int, int] = {}
    new_views = []
    for old in used:
        bv = gltf["bufferViews"][old]
        o, L = bv.get("byteOffset", 0), bv["byteLength"]
        out += b"\0" * (-len(out) % 4)
        nv = {"buffer": 0, "byteOffset": len(out), "byteLength": L}
        for key in ("byteStride", "target"):
            if key in bv:
                nv[key] = bv[key]
        bv_remap[old] = len(new_views)
        new_views.append(nv)
        out += blob[o : o + L]

    new_accessors = []
    for old in live_acc:
        acc = dict(gltf["accessors"][old])
        if "bufferView" in acc:
            acc["bufferView"] = bv_remap[acc["bufferView"]]
        new_accessors.append(acc)

    new_meshes = []
    for mi in live_meshes:
        mesh = dict(gltf["meshes"][mi])
        prims = []
        for prim in mesh["primitives"]:
            p = dict(prim)
            p["attributes"] = {k: acc_remap[v] for k, v in prim.get("attributes", {}).items()}
            if "indices" in prim:
                p["indices"] = acc_remap[prim["indices"]]
            prims.append(p)
        mesh["primitives"] = prims
        new_meshes.append(mesh)

    for node in gltf["nodes"]:
        if "mesh" in node:
            node["mesh"] = mesh_remap[node["mesh"]]
    for im in gltf.get("images", []):
        if "bufferView" in im:
            im["bufferView"] = bv_remap[im["bufferView"]]

    gltf["bufferViews"] = new_views
    gltf["accessors"] = new_accessors
    gltf["meshes"] = new_meshes
    gltf["buffers"] = [{"byteLength": len(out)}]
    return bytes(out)


# ── Driver ───────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", dest="dst", required=True)
    ap.add_argument("--verify", action="store_true",
                    help="re-read the written GLB and report residual mark relief")
    ap.add_argument("--dump-textures", metavar="DIR",
                    help="also write the processed maps as PNGs, for eyeballing")
    args = ap.parse_args()

    src = os.path.expanduser(args.src)
    dst = os.path.expanduser(args.dst)

    gltf, blob = read_glb(src)
    print(f"read {src}  ({os.path.getsize(src) / 1e6:.1f} MB, "
          f"{len(gltf['nodes'])} nodes, {len(gltf.get('images', []))} images)")

    dropped = flatten_tree(gltf)
    print(f"  flattened wrappers {WRAPPERS} -> single root {ROOT_NAME!r}")
    for name in dropped:
        print(f"  dropped duplicate mesh node: {name}")

    # Rewrite the images in place inside the (still original) blob's views.
    views = gltf["bufferViews"]
    images: dict[str, Image.Image] = {}
    for im in gltf.get("images", []):
        bv = views[im["bufferView"]]
        o, L = bv.get("byteOffset", 0), bv["byteLength"]
        images[im.get("name", "")] = Image.open(io.BytesIO(blob[o : o + L])).convert("RGB")

    if NORMAL_MAP not in images:
        raise SystemExit(f"no {NORMAL_MAP!r} image; the badge frame can only be "
                         f"found in the normal map, so the marks cannot be located")
    masks = build_masks(images[NORMAL_MAP])
    for mk, m in masks.items():
        print(f"  mark {mk}: {int((m > 0.5).sum())} texels to clear")

    new_image_bytes: dict[int, bytes] = {}
    for im in gltf.get("images", []):
        name = im.get("name", "")
        # Every map, not only the normal one: the wordmark is printed into the
        # albedo as well as moulded into the normal, and clearing one alone
        # leaves the other perfectly legible in a render.
        res = clear_marks(images[name], masks)
        img = res["image"]
        for mk, info in res["marks"].items():
            print(f"  {name}: cleared {mk} ({info['texels']} texels)")
        size = SIZES.get(name)
        if size and img.width != size:
            print(f"  {name}: {img.width}x{img.height} -> {size}x{size}")
            img = img.resize((size, size), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, "PNG", optimize=True)
        new_image_bytes[im["bufferView"]] = buf.getvalue()
        if args.dump_textures:
            os.makedirs(args.dump_textures, exist_ok=True)
            img.save(os.path.join(args.dump_textures, name + ".png"))

    # Splice the new image payloads in: give each image its own view at the end
    # of the blob, then prune drops whatever the old ones left behind.
    blob = bytearray(blob)
    rescale(gltf, blob, SCALE)
    print(f"  scaled geometry by {SCALE} (centimetres -> metres)")
    for bvi, payload in new_image_bytes.items():
        blob += b"\0" * (-len(blob) % 4)
        views[bvi] = {"buffer": 0, "byteOffset": len(blob), "byteLength": len(payload)}
        blob += payload
    gltf["buffers"] = [{"byteLength": len(blob)}]

    blob = prune(gltf, bytes(blob))
    gltf.setdefault("asset", {})["generator"] = "RetroXR Tools/glb/prepare_n64_pad.py"
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    write_glb(dst, gltf, blob)
    tris = sum(
        gltf["accessors"][p["indices"]]["count"] // 3
        for n in gltf["nodes"] if "mesh" in n
        for p in gltf["meshes"][n["mesh"]]["primitives"] if "indices" in p)
    print(f"wrote {dst}  ({os.path.getsize(dst) / 1e6:.2f} MB, "
          f"{len(gltf['nodes']) - 1} meshes, {tris} tris)")

    if args.verify:
        return verify(dst, src)
    return 0


def _images(path: str) -> dict[str, Image.Image]:
    gltf, blob = read_glb(path)
    out: dict[str, Image.Image] = {}
    for im in gltf.get("images", []):
        bv = gltf["bufferViews"][im["bufferView"]]
        o, L = bv.get("byteOffset", 0), bv["byteLength"]
        out[im.get("name", "")] = Image.open(io.BytesIO(blob[o : o + L])).convert("RGB")
    return out


ANALYSIS_SIZE = 4096


def _roundtrip(img: Image.Image, through: int) -> np.ndarray:
    """Resample to `through` and back to ANALYSIS_SIZE.

    Both sides of the comparison go through this, including the source. The
    measurement is then made at one resolution, with one blur radius, on two
    images that have had exactly the same treatment -- so a difference between
    them is a difference in content, which is the only thing being asked about.
    """
    if img.width != through:
        img = img.resize((through, through), Image.LANCZOS)
    if img.width != ANALYSIS_SIZE:
        img = img.resize((ANALYSIS_SIZE, ANALYSIS_SIZE), Image.LANCZOS)
    return np.asarray(img.convert("RGB"))


def verify(dst: str, src: str) -> int:
    """A check that can fail: how much of each mark still shows, in every map."""
    src_imgs, out_imgs = _images(src), _images(dst)
    if NORMAL_MAP not in src_imgs:
        print("VERIFY FAIL: no normal map in the source")
        return 1
    masks = build_masks(src_imgs[NORMAL_MAP])

    print(f"\nverify (share of each mark's own contrast still present; "
          f"budget {MARK_MAX_REMAINING * 100:.0f}%)")
    ok = True
    for map_name in sorted(out_imgs):
        if map_name not in src_imgs:
            continue
        through = out_imgs[map_name].width
        so = _roundtrip(src_imgs[map_name], through)
        oo = _roundtrip(out_imgs[map_name], through)
        for mark, ((x0, y0, x1, y1), _mode) in MARKS.items():
            frac, n = remaining_mark(so[y0:y1, x0:x1], oo[y0:y1, x0:x1], masks[mark])
            verdict = "clear" if frac <= MARK_MAX_REMAINING else "MARK REMAINS"
            print(f"  {map_name:26s} {mark:7s} {frac * 100:6.1f}% of "
                  f"{n:6d} mark texels   -> {verdict}")
            ok = ok and verdict == "clear"

    # The measurement is anchored on the SOURCE's own contrast in the same
    # place, so the source scores 1.0 by construction and a metric that has
    # stopped working cannot quietly read clean: remaining_mark refuses outright
    # if it cannot find the mark, separate it from its surround, or measure it.
    print("OK" if ok else "VERIFY FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

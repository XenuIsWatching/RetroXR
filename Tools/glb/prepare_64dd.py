#!/usr/bin/env python3
"""Turn the 64DD .ugc bundles into the drive and disk RetroXR ships.

Inputs are four ``.ugc`` bundles (Unity AssetBundles): the retail and Dev Kit
Nintendo 64 Disk Drive by ArilcedT, and the plain and blue 64DD disk by
Mickemoose. They are converted with ugc-to-gltf, then reworked here:

  drive   The two bundles carry identical geometry and identical normal / ORM
          maps; only the colour bake differs. One GLB is written, with the
          retail colour map bound and the dev-kit map beside it for a runtime
          swap. The RCA cable bundle and its plugs are dropped (RetroXR has
          its own leads), so are the three finger-gesture empties, the two
          zero-position highlight empties and the three socket animations.
          The model faces -Z; RetroXR reads a unit from +Z, so it is yawed
          180 degrees. The converter builds its ORM from the metallic map's
          alpha, which this bake does not carry, so every texel came out
          roughness 0 -- a mirror. The ORM is rebuilt from the bundle's own
          ao / roughness / metallic maps. The LED's emission is zeroed so
          the room can drive it from the core's disk activity. Maps are resized
          from 4096 to 2048.

  disk    One GLB, plain colour map bound, blue map beside it. The "Desync"
          sticker and the socket empty are dropped. The model lies flat with
          the label up and the shutter on -Z; the floppy contract is label
          +Z, shutter +Y (it goes into the drive first) and the paper label
          toward -Y, so positions and normals are rotated by
          (x, y, z) -> (x, -z, y).

Every texture is written as a PNG beside the GLB and referenced by uri, so
the two colour variants share one mesh file.

    python Tools/glb/prepare_64dd.py \
        --src ~/OneDrive/Documents/n64dd-models \
        --converter ~/ugc-to-gltf/ugc_to_gltf.py \
        --work /tmp/n64dd --verify
"""
from __future__ import annotations

import argparse
import hashlib
import io
import os
import subprocess
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from prepare_n64_pad import prune, read_glb, write_glb  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DRIVE = os.path.join(REPO, "RetroXR", "imported-assets", "consoles", "nintendo_64dd")
OUT_DISK = os.path.join(REPO, "RetroXR", "imported-assets", "carts", "nintendo_64dd")

BUNDLES = {
    "drive": "Nintendo_64_Disk_Drive_a77d0ed5.ugc",
    "drive_dev": "Nintendo_64_Disk_Drive_(Dev_Kit)_bb88589e.ugc",
    "disk": "64DD_Disk_9ff9560b.ugc",
    "disk_blue": "64DD_Disk_(Blue)_17117013.ugc",
}

DRIVE_DROP = {"Plugs", "Cable Plug (YWR)", "RCA_Red", "RCA_White", "RCA_Yellow", "Cables",
              "Finger Button", "Finger Button (1)", "Finger Button (2)",
              "N64_DiskDrive_Butt", "N64_DiskDrive_LightLit"}
DISK_DROP = {"Desync", "Media Socket"}
FORBIDDEN = DRIVE_DROP | DISK_DROP

# Seated pose of the socket, read off the bundle's close animation (the node
# itself is baked at the open pose). The bundle mates the disk's own socket empty to
# it, and that empty sits on the disk's TOP face (y = +0.00508 in the disk
# bundle), so the marker is lowered by that much to mark the disk's centre.
SOCKET_SEATED = [-0.0002, 0.0335 - 0.00508, -0.0698]

DRIVE_YAW = np.array([[-1, 0, 0], [0, 1, 0], [0, 0, -1]], np.float32)
DISK_TO_CART = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], np.float32)

DRIVE_TEXTURE_SIZE = 2048


# ── glTF helpers ─────────────────────────────────────────────────────────────

def accessor_array(gltf: dict, blob: bytes, ai: int) -> np.ndarray:
    acc = gltf["accessors"][ai]
    if acc["componentType"] != 5126 or acc["type"] != "VEC3":
        raise SystemExit(f"accessor {ai}: not float32 VEC3")
    bv = gltf["bufferViews"][acc["bufferView"]]
    if bv.get("byteStride", 12) != 12:
        raise SystemExit(f"accessor {ai}: interleaved; cannot transform in place")
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    return np.frombuffer(bytes(blob[base:base + acc["count"] * 12]), np.float32).reshape(-1, 3)


def write_accessor(gltf: dict, blob: bytearray, ai: int, vals: np.ndarray, bounds: bool) -> None:
    acc = gltf["accessors"][ai]
    bv = gltf["bufferViews"][acc["bufferView"]]
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    blob[base:base + vals.size * 4] = vals.astype(np.float32).tobytes()
    if bounds:
        acc["min"] = [float(v) for v in vals.min(0)]
        acc["max"] = [float(v) for v in vals.max(0)]


def transform_geometry(gltf: dict, blob: bytearray, m: np.ndarray) -> None:
    """Apply a proper rotation to every live position, normal and translation."""
    if abs(np.linalg.det(m) - 1.0) > 1e-6:
        raise SystemExit("transform is not a proper rotation; winding would flip")
    done: set[int] = set()
    for node in gltf["nodes"]:
        if "mesh" not in node:
            continue
        for prim in gltf["meshes"][node["mesh"]]["primitives"]:
            attrs = prim.get("attributes", {})
            for key in ("POSITION", "NORMAL"):
                ai = attrs.get(key)
                if ai is None or ai in done:
                    continue
                done.add(ai)
                vals = accessor_array(gltf, blob, ai) @ m.T
                write_accessor(gltf, blob, ai, vals, bounds=key == "POSITION")
            if "TANGENT" in attrs:
                raise SystemExit("tangents present; extend transform_geometry")
    for node in gltf["nodes"]:
        if "translation" in node:
            node["translation"] = [float(v) for v in (np.array(node["translation"]) @ m.T)]
        if "rotation" in node and node["rotation"] != [0, 0, 0, 1]:
            raise SystemExit(f"node {node.get('name')!r} carries a rotation; drop or convert it")


def drop_nodes(gltf: dict, names: set[str]) -> list[str]:
    keep = [n for n in gltf["nodes"] if n.get("name") not in names]
    dropped = [n.get("name") for n in gltf["nodes"] if n.get("name") in names]
    for n in keep:
        if n.get("children"):
            raise SystemExit("nested nodes; drop_nodes assumes a flat scene")
    gltf["nodes"] = keep
    gltf["scenes"] = [{"nodes": list(range(len(keep)))}]
    gltf["scene"] = 0
    return dropped


def rename_nodes(gltf: dict, mapping: dict[str, str]) -> None:
    seen: set[str] = set()
    for n in gltf["nodes"]:
        new = mapping.get(n.get("name"))
        if new is None:
            continue
        if new in seen:
            raise SystemExit(f"two nodes would both be named {new!r}")
        seen.add(new)
        n["name"] = new


def image_bytes(gltf: dict, blob: bytes, ii: int) -> bytes:
    im = gltf["images"][ii]
    bv = gltf["bufferViews"][im["bufferView"]]
    o = bv.get("byteOffset", 0)
    return bytes(blob[o:o + bv["byteLength"]])


def image_pil(gltf: dict, blob: bytes, ii: int) -> Image.Image:
    return Image.open(io.BytesIO(image_bytes(gltf, blob, ii)))


def save_png(img: Image.Image, path: str, size: int | None = None) -> None:
    if size is not None and img.size != (size, size):
        img = img.resize((size, size), Image.LANCZOS)
    img.save(path, optimize=True)


def externalize(gltf: dict, ii: int, uri: str) -> None:
    im = gltf["images"][ii]
    im.pop("bufferView", None)
    im.pop("mimeType", None)
    im["uri"] = uri


def prune_materials(gltf: dict) -> None:
    """Keep only the materials, textures and images live meshes reach."""
    live_mat = sorted({p["material"] for n in gltf["nodes"] if "mesh" in n
                       for p in gltf["meshes"][n["mesh"]]["primitives"] if "material" in p})
    mat_remap = {o: i for i, o in enumerate(live_mat)}
    mats = [gltf["materials"][i] for i in live_mat]

    def tex_refs(mat: dict):
        pbr = mat.get("pbrMetallicRoughness", {})
        for slot in (pbr.get("baseColorTexture"), pbr.get("metallicRoughnessTexture"),
                     mat.get("normalTexture"), mat.get("occlusionTexture"),
                     mat.get("emissiveTexture")):
            if slot is not None:
                yield slot

    live_tex = sorted({s["index"] for m in mats for s in tex_refs(m)})
    tex_remap = {o: i for i, o in enumerate(live_tex)}
    texs = [gltf["textures"][i] for i in live_tex]
    live_img = sorted({t["source"] for t in texs})
    img_remap = {o: i for i, o in enumerate(live_img)}
    for t in texs:
        t["source"] = img_remap[t["source"]]
    for m in mats:
        for s in tex_refs(m):
            s["index"] = tex_remap[s["index"]]
    for n in gltf["nodes"]:
        if "mesh" in n:
            for p in gltf["meshes"][n["mesh"]]["primitives"]:
                if "material" in p:
                    p["material"] = mat_remap[p["material"]]
    gltf["materials"] = mats
    gltf["textures"] = texs
    gltf["images"] = [gltf["images"][i] for i in live_img]


def material(gltf: dict, name: str) -> dict:
    for m in gltf["materials"]:
        if m.get("name") == name:
            return m
    raise SystemExit(f"no material named {name!r}")


def image_index(gltf: dict, name: str, size: tuple[int, int] | None = None,
                blob: bytes | None = None) -> int:
    hits = [i for i, im in enumerate(gltf["images"]) if im.get("name") == name]
    if size is not None:
        hits = [i for i in hits if image_pil(gltf, blob, i).size == size]
    if len(hits) != 1:
        raise SystemExit(f"image {name!r} {size or ''}: {len(hits)} matches")
    return hits[0]


# ── Sources ──────────────────────────────────────────────────────────────────

def convert(converter: str, src: str, work: str) -> dict[str, str]:
    os.makedirs(work, exist_ok=True)
    out = {}
    for key, fn in BUNDLES.items():
        glb = os.path.join(work, key + ".glb")
        subprocess.run([sys.executable, converter, os.path.join(src, fn), glb], check=True)
        out[key] = glb
    return out


def bundle_textures(path: str) -> dict[str, Image.Image]:
    import UnityPy
    env = UnityPy.load(path)
    out = {}
    for o in env.objects:
        if o.type.name == "Texture2D":
            t = o.read()
            out[t.m_Name] = t.image
    return out


# ── Drive ────────────────────────────────────────────────────────────────────

def build_drive(glbs: dict[str, str], src: str, out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    gltf, blob = read_glb(glbs["drive"])
    blob = bytearray(blob)
    dev, dev_blob = read_glb(glbs["drive_dev"])

    # The dev bundle must be the same mesh with the same normal / ORM, or one
    # GLB cannot serve both.
    for name in ("normal", "orm"):
        a = image_bytes(gltf, blob, image_index(gltf, name, (4096, 4096), blob))
        b = image_bytes(dev, dev_blob, image_index(dev, name, (4096, 4096), dev_blob))
        if hashlib.sha1(a).digest() != hashlib.sha1(b).digest():
            raise SystemExit(f"dev bundle's {name} map differs from retail; ship both GLBs")
    if len(dev["meshes"]) != len(gltf["meshes"]):
        raise SystemExit("dev bundle mesh count differs from retail")

    dropped = drop_nodes(gltf, DRIVE_DROP)
    gltf.pop("animations", None)
    rename_nodes(gltf, {"64DD": "Shell", "default (1)": "AccessLed", "System Socket": "SocketMarker"})
    # Two nodes are both named "default": the LED lens and the eject button.
    for n in gltf["nodes"]:
        if n.get("name") == "default":
            tris = gltf["accessors"][gltf["meshes"][n["mesh"]]["primitives"][0]["indices"]]["count"] // 3
            n["name"] = "EjectButton" if tris > 100 else "LedLens"
    socket = next(n for n in gltf["nodes"] if n["name"] == "SocketMarker")
    socket["translation"] = list(SOCKET_SEATED)
    socket.pop("rotation", None)
    transform_geometry(gltf, blob, DRIVE_YAW)

    src_tex = bundle_textures(os.path.join(src, BUNDLES["drive"]))
    ao = np.asarray(src_tex["64DD Bake_ao"].convert("L"))
    rough = np.asarray(src_tex["64DD Bake_roughness"].convert("L"))
    metal = np.asarray(src_tex["64DD Bake_metallic"].convert("L"))
    orm = Image.fromarray(np.stack([ao, rough, metal], -1), "RGB")

    color_i = image_index(gltf, "64DD Bake_color")
    normal_i = image_index(gltf, "normal", (4096, 4096), blob)
    orm_i = image_index(gltf, "orm", (4096, 4096), blob)
    save_png(image_pil(gltf, blob, color_i).convert("RGB"),
             os.path.join(out_dir, "n64dd_drive_color.png"), DRIVE_TEXTURE_SIZE)
    save_png(image_pil(gltf, blob, normal_i).convert("RGB"),
             os.path.join(out_dir, "n64dd_drive_normal.png"), DRIVE_TEXTURE_SIZE)
    save_png(orm, os.path.join(out_dir, "n64dd_drive_orm.png"), DRIVE_TEXTURE_SIZE)
    save_png(image_pil(dev, dev_blob, image_index(dev, "64dddev 1")).convert("RGB"),
             os.path.join(out_dir, "n64dd_drive_color_dev.png"))
    externalize(gltf, color_i, "n64dd_drive_color.png")
    externalize(gltf, normal_i, "n64dd_drive_normal.png")
    externalize(gltf, orm_i, "n64dd_drive_orm.png")

    bake = material(gltf, "bake")
    bake["pbrMetallicRoughness"]["metallicFactor"] = 1.0
    bake["pbrMetallicRoughness"]["roughnessFactor"] = 1.0
    bake["name"] = "shell"
    led = material(gltf, "Light Lit")
    led["emissiveFactor"] = [0.0, 0.0, 0.0]
    led["name"] = "access_led"
    material(gltf, "Bake")["name"] = "eject_button"
    material(gltf, "Material.006")["name"] = "led_lens"

    prune_materials(gltf)
    blob = prune(gltf, bytes(blob))
    write_glb(os.path.join(out_dir, "n64dd_drive.glb"), gltf, blob)
    print(f"drive: dropped {dropped}")


# ── Disk ─────────────────────────────────────────────────────────────────────

def build_disk(glbs: dict[str, str], out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    gltf, blob = read_glb(glbs["disk"])
    blob = bytearray(blob)
    blue, blue_blob = read_glb(glbs["disk_blue"])

    dropped = drop_nodes(gltf, DISK_DROP)
    rename_nodes(gltf, {"64disk": "Shell"})
    transform_geometry(gltf, blob, DISK_TO_CART)

    color_i = image_index(gltf, "64DD Disk New Texture")
    normal_i = image_index(gltf, "normal", (1024, 1024), blob)
    label_i = image_index(gltf, "Label_Albedo")
    label_n_i = image_index(gltf, "normal", (128, 512), blob)
    save_png(image_pil(gltf, blob, color_i).convert("RGB"), os.path.join(out_dir, "n64dd_disk_color.png"))
    save_png(image_pil(gltf, blob, normal_i).convert("RGB"), os.path.join(out_dir, "n64dd_disk_normal.png"))
    save_png(image_pil(gltf, blob, label_i).convert("RGB"), os.path.join(out_dir, "n64dd_disk_label.png"))
    save_png(image_pil(gltf, blob, label_n_i).convert("RGB"), os.path.join(out_dir, "n64dd_disk_label_normal.png"))
    save_png(image_pil(blue, blue_blob, image_index(blue, "64DD Disk New Texture_Blue")).convert("RGB"),
             os.path.join(out_dir, "n64dd_disk_color_blue.png"))
    externalize(gltf, color_i, "n64dd_disk_color.png")
    externalize(gltf, normal_i, "n64dd_disk_normal.png")
    externalize(gltf, label_i, "n64dd_disk_label.png")
    externalize(gltf, label_n_i, "n64dd_disk_label_normal.png")

    material(gltf, "Material.016")["name"] = "shell"
    material(gltf, "Quick_MediaLabel")["name"] = "label"

    prune_materials(gltf)
    blob = prune(gltf, bytes(blob))
    write_glb(os.path.join(out_dir, "n64dd_disk.glb"), gltf, blob)
    print(f"disk: dropped {dropped}")


# ── Verify ───────────────────────────────────────────────────────────────────

def verify(path: str) -> int:
    gltf, blob = read_glb(path)
    bad = 0
    print(f"=== {path}")
    if gltf.get("animations"):
        print("  FAIL: animations survived")
        bad += 1
    for n in gltf["nodes"]:
        name = n.get("name", "")
        if name in FORBIDDEN:
            print(f"  FAIL: node {name!r} survived")
            bad += 1
        if "mesh" in n:
            prim = gltf["meshes"][n["mesh"]]["primitives"][0]
            acc = gltf["accessors"][prim["attributes"]["POSITION"]]
            pos = accessor_array(gltf, blob, prim["attributes"]["POSITION"])
            lo, hi = pos.min(0), pos.max(0)
            if not (np.allclose(lo, acc["min"], atol=1e-6) and np.allclose(hi, acc["max"], atol=1e-6)):
                print(f"  FAIL: {name}: accessor bounds stale")
                bad += 1
            tris = gltf["accessors"][prim["indices"]]["count"] // 3
            mat = gltf["materials"][prim["material"]]["name"]
            print(f"  {name:14s} tris={tris:5d} mat={mat:12s} "
                  f"lo=({lo[0]:+.4f} {lo[1]:+.4f} {lo[2]:+.4f}) hi=({hi[0]:+.4f} {hi[1]:+.4f} {hi[2]:+.4f})")
        else:
            print(f"  {name:14s} marker t={n.get('translation')}")
    for im in gltf["images"]:
        if "uri" not in im:
            print(f"  FAIL: image {im.get('name')!r} still embedded")
            bad += 1
            continue
        p = os.path.join(os.path.dirname(path), im["uri"])
        if not os.path.exists(p):
            print(f"  FAIL: {im['uri']} missing")
            bad += 1
            continue
        print(f"  image {im['uri']:32s} {Image.open(p).size} {os.path.getsize(p) // 1024} KB")
    for m in gltf["materials"]:
        pbr = m.get("pbrMetallicRoughness", {})
        print(f"  material {m['name']:12s} metal={pbr.get('metallicFactor', 1)} rough={pbr.get('roughnessFactor', 1)} "
              f"emissive={m.get('emissiveFactor', [0, 0, 0])}")
    print(f"  glb {os.path.getsize(path) // 1024} KB")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", required=True, help="folder holding the four .ugc bundles")
    ap.add_argument("--converter", required=True, help="path to ugc_to_gltf.py")
    ap.add_argument("--work", required=True, help="scratch folder for the converter's GLBs")
    ap.add_argument("--out-drive", default=OUT_DRIVE)
    ap.add_argument("--out-disk", default=OUT_DISK)
    ap.add_argument("--verify", action="store_true")
    a = ap.parse_args()

    glbs = convert(a.converter, a.src, a.work)
    build_drive(glbs, a.src, a.out_drive)
    build_disk(glbs, a.out_disk)
    if a.verify:
        bad = verify(os.path.join(a.out_drive, "n64dd_drive.glb"))
        bad += verify(os.path.join(a.out_disk, "n64dd_disk.glb"))
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

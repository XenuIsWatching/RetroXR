"""Prepare synthetic worlds' PS1 pad (SCPH-1080) for RetroXR.

    blender --background --python Tools/glb/prepare_ps1_pad.py -- \
        --in ~/Downloads/sony_playstation_one_controller.glb \
        --out RetroXR/imported-assets/controllers/playstation/ps1_pad.glb

Why this asset and not the pad that came with the console scene: in THAT model the
four face buttons, both shoulder pairs and SELECT/START are a single connected
surface (11,784 triangles in one island), so no separation recovers them and no
button can travel on its own. This one is 106 disconnected islands, so every
control can be pulled out and animated.

Two things worth knowing:

  * The FRONT wordmarks are albedo only. The normal map is flat across the whole
    "SONY" / "PlayStation" region on the face — only the button recesses are
    embossed — so erasing the base colour leaves no relief ghost behind. That was
    worth checking: a co-located embossed copy is exactly what made the Atari's
    logo removal leave a visible mark.

    The BACK is the other way round, and this file used to claim the whole sheet
    was flat and stop there. The compliance plate under the pad — "SONY",
    "CONTROLLER" and its fine print — is embossed in the NORMAL map and carries
    no albedo at all, so the base-colour scrub could never have touched it and
    the wordmark shipped, white on white, legible whenever the pad was picked up
    and turned over. Checking one region and generalising to the sheet is the
    whole mistake; scrub_normal_label handles that plate.

  * The functional legends and the trademarks separate cleanly in X. START and
    SELECT end at texture x=230; "PlayStation", the PS logo and "SONY" all start
    past x=340. One rect removes all three marks and touches neither legend.
"""
import bpy
import bmesh
import math
import mathutils
import sys
import os

## Sampled off the sheet rather than guessed — the pad's plastic is a warm grey,
## not a neutral one, and a neutral fill leaves a visible patch.
PAD_GREY = (165, 159, 160)

## x0, y0, x1, y1 in the 4096 base-colour sheet. Covers "PlayStation", the PS
## logo glyph and "SONY"; START/SELECT sit left of x=230 and are untouched.
SCRUB_RECT = (330, 490, 640, 990)

## The compliance plate on the pad's UNDERSIDE, in the DOWNSCALED 1024 normal
## map's pixels — x0, y0, x1, y1, top-left origin.
##
## Measured at 1024 and scrubbed after downscale_textures, unlike SCRUB_RECT
## above, which is measured in the source's 4096 sheet. Deliberate: these are the
## coordinates that were actually verified, against the shipped asset, by column
## and row profile. The plate's border is at columns 260-261 / 327-328 and rows
## 134-135 / 231-232 and is LEFT STANDING — the recess is real moulding, and a
## blank plate is what a de-branded pad has. Only the lettering inside goes.
##
## The screw boss at x 335-340 is outside this rect and must stay outside it.
NORMAL_LABEL_RECT = (262, 136, 327, 231)

## A flat tangent-space normal, sampled off this sheet rather than assumed: it is
## (128, 127, 255) here, not the (128, 128, 255) you would write down.
FLAT_NORMAL = (128, 127, 255)

TARGET_WIDTH = 0.1449          # a real SCPH-1080 is ~145 mm across


def argv():
    return sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def opt(args, flag, default=None):
    return args[args.index(flag) + 1] if flag in args else default


def scrub_base_colour():
    import numpy as np
    done = 0
    for img in bpy.data.images:
        if img.size[0] != 4096 or not img.pixels:
            continue
        # Only the BASE COLOUR sheet. The normal map is the same size, and
        # flooding it with a flat colour would wipe every embossed detail.
        if not _is_base_colour(img):
            continue
        w, h = img.size
        px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
        x0, y0, x1, y1 = SCRUB_RECT
        fy0, fy1 = h - y1, h - y0          # Blender's buffer is bottom-up
        px[fy0:fy1, x0:x1, 0] = PAD_GREY[0] / 255.0
        px[fy0:fy1, x0:x1, 1] = PAD_GREY[1] / 255.0
        px[fy0:fy1, x0:x1, 2] = PAD_GREY[2] / 255.0
        px[fy0:fy1, x0:x1, 3] = 1.0
        img.pixels = px.ravel().tolist()
        img.pack()
        print("[scrub] %s rect %s <- %s" % (img.name, SCRUB_RECT, PAD_GREY))
        done += 1
    if done == 0:
        print("[warn] no base-colour sheet scrubbed")


## Every other imported asset in this project ships 1024-square sheets — both
## Atari 2600 parts, the NES console and pad, the SNES Mouse, the whole bedroom.
## Match that. Downscale AFTER the scrub: the trademark rects are measured in the
## full-resolution sheet's pixels.
MAX_TEX = 1024


def downscale_textures():
    for img in bpy.data.images:
        w, h = img.size
        if w <= MAX_TEX and h <= MAX_TEX:
            continue
        if w == 0 or h == 0:
            continue
        s = float(MAX_TEX) / float(max(w, h))
        img.scale(max(1, int(w * s)), max(1, int(h * s)))
        img.pack()
        print("[tex] %s %dx%d -> %dx%d" % (img.name, w, h, img.size[0], img.size[1]))


## Flatten the underside's embossed label plate. Runs AFTER downscale_textures,
## because NORMAL_LABEL_RECT is measured in the 1024 sheet — see the constant.
def scrub_normal_label():
    import numpy as np
    done = 0
    for img in bpy.data.images:
        if not img.pixels or _is_base_colour(img):
            continue
        w, h = img.size
        if (w, h) != (1024, 1024):
            print("[warn] normal sheet is %dx%d, not 1024 — rect not applied" % (w, h))
            continue
        px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
        x0, y0, x1, y1 = NORMAL_LABEL_RECT
        fy0, fy1 = h - y1, h - y0          # Blender's buffer is bottom-up
        for c in range(3):
            px[fy0:fy1, x0:x1, c] = FLAT_NORMAL[c] / 255.0
        img.pixels = px.ravel().tolist()
        img.pack()
        print("[scrub] %s label plate %s <- flat" % (img.name, NORMAL_LABEL_RECT))
        done += 1
    if done == 0:
        print("[warn] no normal sheet scrubbed — the underside wordmark may survive")


def _is_base_colour(img):
    for mat in bpy.data.materials:
        if not mat.use_nodes:
            continue
        for node in mat.node_tree.nodes:
            if node.type != 'BSDF_PRINCIPLED':
                continue
            inp = node.inputs.get("Base Color")
            if inp is None or not inp.is_linked:
                continue
            src = inp.links[0].from_node
            if src.type == 'TEX_IMAGE' and src.image == img:
                return True
    return False


def normalise(root, meshes):
    lo, hi = bounds(meshes)
    s = TARGET_WIDTH / (hi.x - lo.x)
    root.scale = tuple(v * s for v in root.scale)
    bpy.context.view_layer.update()
    lo, hi = bounds(meshes)
    mw = root.matrix_world.copy()
    mw.translation = mw.translation - mathutils.Vector(
        ((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5, lo.z))
    root.matrix_world = mw
    bpy.context.view_layer.update()


def bake_scale(root):
    """Push the root's scale into the mesh data, so every node exports at 1.

    normalise() resizes the pad by writing root.scale, which leaves every
    descendant sitting in a frame scaled by 0.0103. That is invisible to anything
    reading WORLD transforms -- which is everything except an animation.
    ControlAnimator presses a button with `rest.origin + dir * depth`, and
    `origin` is in the PARENT's units while `depth` is in metres, so a 1.4 mm
    press came out as 0.0144 mm: exactly 1.4 x 0.0103, and invisible.

    Measured against the other four animated pads -- NES, CX40, Virtual Boy,
    RetroPad -- every one of them sits at scale 1.0000 and travels exactly the
    depth it asks for. So the animator's contract is right and this asset was the
    one breaking it, which is why the fix belongs here and not in shared code.

    The D-pad was unaffected and worked throughout, because a rotation does not
    care what the frame is scaled by. Only the translations were lost.
    """
    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    world = {o: o.matrix_world.copy() for o in meshes}
    root.scale = (1.0, 1.0, 1.0)
    bpy.context.view_layer.update()
    # Put every mesh back where it was. Their local bases now carry the scale the
    # root gave up, which is what transform_apply then bakes into the vertices.
    for o in meshes:
        o.matrix_world = world[o]
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action='DESELECT')
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    worst = max(max(abs(v - 1.0) for v in o.matrix_basis.to_scale()) for o in meshes)
    print("[pad] baked the root scale; worst node scale error now %.2e" % worst)


def bounds(objs):
    lo = mathutils.Vector((1e9, 1e9, 1e9))
    hi = mathutils.Vector((-1e9, -1e9, -1e9))
    for o in objs:
        for v in o.data.vertices:
            p = o.matrix_world @ v.co
            for i in range(3):
                lo[i] = min(lo[i], p[i])
                hi[i] = max(hi[i], p[i])
    return lo, hi


## Each control, as a centroid box in the normalised pad's frame (Blender Z-up:
## x = left/right, y = depth with +y AWAY from the player, z = height).
##
## Measured off the separated islands rather than guessed. Note the controls do
## NOT come through as one island each: the D-pad arrives as its four arms plus
## their side walls, and each shoulder as three slabs, so every control is a GROUP
## of islands that gets joined back together under one name.
##
## Face-button positions confirm the standard layout — triangle furthest away,
## cross nearest, square left, circle right — which is why they are named from
## their geometry and not from the (trademarked) symbols on their caps.
CONTROLS = [
    # name,          x0,      x1,      y0,      y1,      z0
    ("DPad",       -0.060,  -0.026,  -0.008,   0.028,   0.038),
    ("BtnSquare",   0.0243,  0.0363,  0.0043,  0.0163,  0.038),
    ("BtnTriangle", 0.0365,  0.0485,  0.0157,  0.0277,  0.038),
    ("BtnCircle",   0.0480,  0.0600,  0.0041,  0.0161,  0.038),
    ("BtnCross",    0.0368,  0.0488, -0.0076,  0.0044,  0.038),
    ("BtnSelect",  -0.0165,  -0.005, -0.006,   0.007,   0.038),
    ("BtnStart",    0.003,    0.015, -0.006,   0.007,   0.038),
    ("BtnL1",      -0.052,   -0.031,  0.030,   0.050,   0.026),
    ("BtnL2",      -0.052,   -0.031,  0.030,   0.050,   0.008),
    ("BtnR1",       0.031,    0.052,  0.030,   0.050,   0.026),
    ("BtnR2",       0.031,    0.052,  0.030,   0.050,   0.008),
]


## How big an island may be and still be part of a control, as (x, y, z) in the
## normalised pad's frame.
##
## A centroid box says WHERE an island is and nothing about its size, and that is
## not enough: the pad's two round lobe plates -- the dishes the controls sit in,
## 49.8 x 48.5 x 0.9 mm, 83 triangles each -- have their centroids inside the
## D-pad's box and the cross's box respectively, so both were being joined in.
## The D-pad then WAS the left lobe, and pressing a direction rocked the whole
## dish and the grip under it; CROSS was the right lobe, and travelling 1.4 mm
## read as nothing moving at all.
##
## 20 mm in plan and 12 mm of height. The first pass allowed 32 x 32 x 15, which
## cleared the lobes and the grips but still let the shoulders' own printed L and
## R legend plate through: BtnL1 came out 27.6 x 14.7 x 15.5 mm against BtnL2's
## 17.7 x 8.2 x 10.8, and pressing L slid a slab of lettered shell down with it.
## Both real shoulders and every face cap fit inside 20 x 20 x 12; the D-pad's
## widest island is its printed arrows at 27.6 mm, which is why those now fail the
## gate and stay shell -- they are ink on the dish, not part of the rocker.
MAX_CONTROL_SPAN = (0.020, 0.020, 0.012)


def group_controls(parts):
    """Join each control's islands into one named object; leave the rest as shell.

    AnimatedController travels a whole MeshInstance3D, so a control split across
    six islands would only ever move a sixth of itself.
    """
    named = []
    claimed = set()
    for name, x0, x1, y0, y1, z0 in CONTROLS:
        members = []
        # Re-query LIVE. bpy.ops.object.join() deletes the objects it merges, so
        # a list captured before the first join holds dangling references and
        # every control after the first one silently matched nothing.
        for p in [o for o in bpy.data.objects if o.type == 'MESH']:
            if p.name in claimed or p.name in [n[0] for n in CONTROLS]:
                continue
            vs = [p.matrix_world @ v.co for v in p.data.vertices]
            if not vs:
                continue
            c = sum(vs, mathutils.Vector()) / len(vs)
            top = max(v.z for v in vs)
            size = mathutils.Vector((
                max(v.x for v in vs) - min(v.x for v in vs),
                max(v.y for v in vs) - min(v.y for v in vs),
                max(v.z for v in vs) - min(v.z for v in vs)))
            if any(size[i] > MAX_CONTROL_SPAN[i] for i in range(3)):
                continue
            if x0 <= c.x <= x1 and y0 <= c.y <= y1 and top >= z0:
                members.append(p)
        if not members:
            print("[warn] %s: no islands matched" % name)
            continue
        bpy.ops.object.select_all(action='DESELECT')
        for m in members:
            m.select_set(True)
        bpy.context.view_layer.objects.active = members[0]
        if len(members) > 1:
            bpy.ops.object.join()
        obj = bpy.context.view_layer.objects.active
        obj.name = name
        claimed.add(name)
        named.append(obj)
        print("[ctl] %-12s %2d islands -> %d tris"
              % (name, len(members), len(obj.data.polygons)))
    return named


def merge_shell(parts, named):
    """Join everything that is not a control back into one shell mesh, so the pad
    exports as a dozen objects rather than a hundred."""
    rest = [p for p in bpy.data.objects
            if p.type == 'MESH' and p not in named]
    if len(rest) < 2:
        return
    bpy.ops.object.select_all(action='DESELECT')
    for r in rest:
        r.select_set(True)
    bpy.context.view_layer.objects.active = rest[0]
    bpy.ops.object.join()
    bpy.context.view_layer.objects.active.name = "PadShell"
    print("[ctl] PadShell    %2d islands -> %d tris"
          % (len(rest), len(bpy.context.view_layer.objects.active.data.polygons)))


def report_islands(ob):
    """Separate into loose parts and print each one's centroid and size.

    Blender is Z-up here: (x, y, z) is (left-right, depth, height). The pad is
    normalised face-up, so z picks out the controls on the top face.
    """
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.mesh.separate(type='LOOSE')
    parts = [o for o in bpy.data.objects if o.type == 'MESH']
    print("[islands] %d" % len(parts))
    rows = []
    for p in parts:
        vs = [p.matrix_world @ v.co for v in p.data.vertices]
        if not vs:
            continue
        c = sum(vs, mathutils.Vector()) / len(vs)
        lo = mathutils.Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
        hi = mathutils.Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
        rows.append((p, c, hi - lo, len(p.data.polygons)))
    rows.sort(key=lambda r: (-r[1].z, r[1].x))
    if "--islands" in sys.argv:
        for p, c, size, n in rows:
            print("[isl] %-22s c=(%7.4f %7.4f %7.4f) size=(%.4f %.4f %.4f) tris=%d"
                  % (p.name[:22], c.x, c.y, c.z, size.x, size.y, size.z, n))
    return rows


def main():
    args = argv()
    src = os.path.expanduser(opt(args, "--in"))
    dst = os.path.expanduser(opt(args, "--out"))

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)

    scrub_base_colour()
    downscale_textures()
    scrub_normal_label()

    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    root = meshes[0]
    while root.parent is not None:
        root = root.parent
    normalise(root, meshes)

    lo, hi = bounds(meshes)
    print("[pad] %.4f x %.4f x %.4f m (w x depth x height)"
          % (hi.x - lo.x, hi.y - lo.y, hi.z - lo.z))

    rows = report_islands(meshes[0])
    parts = [r[0] for r in rows]
    named = group_controls(parts)
    merge_shell(parts, named)
    bake_scale(root)

    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.export_scene.gltf(filepath=dst, export_format='GLB',
                              use_selection=True, export_yup=True)
    print("[pad] wrote", dst)


main()

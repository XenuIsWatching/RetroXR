## Bakes the Wii Nunchuk's parts to Scenes/Objects/controllers/wii/nunchuk_*.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_nunchuk.gd
##
## The shell, C and Z are CUT FROM A LASER SCAN. Only the analog stick and the cord's
## strain relief are still drawn here, because the scan does not contain them -- the
## download is the two shell halves, the button bracket and the two keys.
##
## Pipeline, and both steps are needed before this script has anything to read:
##
##   blender --background --python Tools/glb/decimate_stl.py -- ##       --in <scan>/Top.stl --in <scan>/Bottom.stl --out /tmp/shell.stl --target 8000
##   python Tools/art/nunchuk_scan_keys.py --scan <scan dir> --shell /tmp/shell.stl
##
## Source: Wesk's "Wiimote Nunchuck Scan" on bitbuilt.net, released under the Unlicense
## (public domain). See RetroXR/Tools/scan/LICENSE.txt. The scans are 250 MB and are not
## in this repo; the cropped .tri files are.
##
## What was here before, and why it went. The shell was a Catmull-Rom LOFT -- a stack of
## rings whose front and back reach differed, so the silhouette could scoop in on one
## side while sweeping out on the other. That was the right structure and it got the
## overall form right once its profile table was measured against this same scan; the
## first table had the depth profile inverted end for end and rendered a bowling pin with
## a bottle cap on it, and every one of the checks below passed on it.
##
## What a loft of one ring per station cannot do is a FACET. The real shell carries a
## flat panel recessed into the brow for the two keys, and with no way to cut one, a
## 21 mm Z floated 3-4 mm clear at every rake there was; it had to be shortened to 14 to
## seat at all. The seam had to be a separate ribbon standing 0.35 mm off the surface,
## the stick's gate a separate collar, and both wanted their own hand-solved angle. All
## of that is geometry the scan simply has.
##
## Kept from that era, because they earn their keep on any mesh: the winding check reads
## the COMMITTED mesh's own stored normals at its six extreme vertices, which caught the
## scan's keys arriving inside out (STL winds counter-clockwise from outside, Godot's
## front face is clockwise); and _smooth indexes before generating normals so smoothing
## crosses seams.
extends SceneTree

# The shell runs the full 113 mm nose to tail tip. It used to be 105, on the reasoning
# that the stick stood proud of the crown and made up the difference — but the stick is
# not on the crown, it is set into the back face, so it adds nothing to the length.
const Y_TOP := 0.056
const Y_TIP := -0.057

## The analog stick's seat on the back face. Everything else that used to be tuned here
## -- the profile table, the key stations, their rakes, the seam angle -- is gone with
## the loft: the shell, C and Z are all cut from the scan now and carry their own
## placement, so there is nothing left to seat but the stick, which the scan does not
## contain (the download is the two shell halves, the button bracket and the two keys).
##
## 34.5 degrees off the SPINE NORMAL -- the perpendicular to the long axis -- leaning
## toward the nose. Taken from the plane of the BORE'S OWN RIM, which is the only surface
## that has to be got right: a stick is mechanically perpendicular to its gate, and the
## boot has to meet that rim all the way round or it leaves a hole.
##
## Sectioning the scan gives the rim directly. It is a saddle, not a circle: z = +21 at
## the nose edge (y = 25), +10 at the tail edge (y = 41), +16.5 at both flanks (x = +/-9).
## The plane through those three is normal to (0, 0.566, 0.824).
##
## This was 19 degrees for a long time, from a side elevation, a plan view and a fit to
## the shell's back surface AROUND the bore -- three sources agreeing, and all three
## measuring the wrong thing. The head's back face is much flatter than the gate cut into
## it, so a fit over any useful window averages the gate away. The symptom was a boot
## that could not be made to fit: symmetric, it stood 10 mm below the rim on the nose side
## and poked out on the tail side, and no amount of widening or raising it closed both.
const STICK_AXIS_FROM_SPINE := 0.6021   # deg_to_rad(34.5)

## Where the stick's own pole sits below its seat, along that axis. 0.5 mm, because the
## shell's bore is 16 mm long on a face that drops 11 mm across it: every millimetre of
## drop puts the boot another millimetre down a well it is supposed to be filling. At the
## 3.4 mm this started at, the cap also stood only 5 mm proud of the body against the 8
## to 11 the reference shows.
const STICK_DROP := 0.0005

## How many sides the turned parts get. The shell used to be lofted at 40 rings of
## these; only the stick and the strain relief still are.
const SEGS := 28


func _init() -> void:
	_build_body()
	_build_stick()
	_build_boot()
	_build_c()
	_build_z()
	quit()


# ── The shell ────────────────────────────────────────────────────────────────

func _build_body() -> void:
	_build_scan_part("res://Tools/scan/nunchuk_body.tri",
		"res://Scenes/Objects/controllers/wii/nunchuk_body.res")


## Reads Tools/art/nunchuk_scan_keys.py's output: "NCTR", vertex and triangle counts,
## then the vertices and the indices. Expanded back to a soup so the ordinary
## _smooth/_save path runs -- including the winding check, which matters more here
## than anywhere else in this file because the winding came from another program's
## conventions and Godot's front face is the opposite one.
func _build_scan_part(src: String, dst: String) -> void:
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null:
		push_error("[gen] missing %s -- run Tools/art/nunchuk_scan_keys.py" % src)
		return
	if f.get_buffer(4).get_string_from_ascii() != "NCTR":
		push_error("[gen] %s is not a .tri" % src)
		return
	var nv := f.get_32()
	var nt := f.get_32()
	var verts: Array[Vector3] = []
	verts.resize(nv)
	for i in nv:
		verts[i] = Vector3(f.get_float(), f.get_float(), f.get_float())
	var tris: Array[Vector3] = []
	tris.resize(nt * 3)
	for i in nt * 3:
		tris[i] = verts[f.get_32()]
	_save(_smooth(tris), dst)


## The stick: a waisted stalk under a dished cap. The cap's top is CONCAVE — a thumb
## sits in it — and the rim stands slightly proud of the dish, which is the reading
## that separates it from a plain disc at a glance.
func _build_stick() -> void:
	var rings: Array = []
	# The BOOT, and it is the reason the stick had a hole around it. The shell is a
	# scan now, so its bore is a real 19 mm x 16 mm opening; a 12.4 mm stalk standing
	# in the middle of that leaves a crescent you look straight down into.
	#
	# Measured by sectioning the scan rather than guessed at. Across the body at the
	# stick's station the outer surface simply stops between x = -9 and x = +9; along
	# the centreline it stops between y = 25 and y = 41. That also shows why the first
	# attempt at this failed: the rim is not level. It sits at z = +21 on the nose
	# side and z = +10 on the tail side, an 11 mm drop across an 18 mm hole, so a flat
	# disc tucked 6 mm under the stalk ended up 16 mm below the rim and simply floored
	# a deep well instead of closing it.
	#
	# So it is a shallow DOME, 25 mm across at its base and rising to meet the stalk,
	# which is what the real part has anyway: a rubber boot filling the gate. Paired
	# with a much smaller STICK_DROP so it sits up in the opening rather than at the
	# bottom of it.
	rings.append(_disc(-0.0060, 0.0000))             # buried pole, closes the boot
	rings.append(_disc(-0.0060, 0.0120))             # skirt, never seen
	rings.append(_disc(-0.0018, 0.0128))             # the widest ring: this is the one
	rings.append(_disc(-0.0006, 0.0112))             # that shows, 1.8 mm under the rim
	rings.append(_disc(0.0, 0.0062))
	rings.append(_disc(0.0020, 0.0059))
	rings.append(_disc(0.0044, 0.0051))              # the waist
	rings.append(_disc(0.0060, 0.0057))
	rings.append(_disc(0.0072, 0.0074))              # cap flares out
	rings.append(_disc(0.0084, 0.0088))
	rings.append(_disc(0.0098, 0.0094))              # rim, the widest point
	rings.append(_disc(0.0114, 0.0095))
	rings.append(_disc(0.0126, 0.0090))              # rim rolls over
	rings.append(_disc(0.0130, 0.0082))              # the rim land, the cap's high point
	# The concentric groove. Plainly there in a photograph taken down the stick's
	# axis, and the detail that stops the cap reading as a plain disc: the top is a
	# flat outer land, a turned groove, then a shallow centre inside it.
	rings.append(_disc(0.0124, 0.0076))
	rings.append(_disc(0.0123, 0.0070))
	rings.append(_disc(0.0128, 0.0064))              # inner land climbs back out of it
	rings.append(_disc(0.0126, 0.0044))              # centre, dished a little
	rings.append(_disc(0.0122, 0.0022))
	rings.append(_disc(0.0121, 0.0000))
	_save(_smooth(_loft(rings)), "res://Scenes/Objects/controllers/wii/nunchuk_stick.res")


## The ribbed strain relief. Four ribs on a taper, so the cord reads as moulded into
## the tail rather than butted onto it.
func _build_boot() -> void:
	var rings: Array = []
	# Capped, even though this end is buried in the tail: an open ring leaves a hole
	# that the enclosed-volume check cannot see past, so it would report a shell with
	# a missing face as sound.
	rings.append(_disc(0.0, 0.0))
	rings.append(_disc(0.0, 0.0052))
	var ribs := 4
	for i in ribs:
		var f := float(i) / float(ribs)
		var base := lerpf(0.0052, 0.0031, f)
		var y := -0.0022 - 0.0036 * float(i)
		# 1.14, not 1.28. The ribs stood 9.2 mm out of an 8 mm tail at the larger
		# figure, which stepped OUT past the shell and read as a threaded bolt rather
		# than as moulded rubber.
		rings.append(_disc(y + 0.0010, base * 1.14))
		rings.append(_disc(y - 0.0010, base * 1.14))
		rings.append(_disc(y - 0.0014, base))
	rings.append(_disc(-0.0164, 0.0026))
	rings.append(_disc(-0.0170, 0.0000))
	_save(_smooth(_loft(rings)), "res://Scenes/Objects/controllers/wii/nunchuk_boot.res")


## C and Z are CUT FROM THE LASER SCAN, not drawn here.
##
## Source: Wesk's "Wiimote Nunchuck Scan" on bitbuilt.net, released under the Unlicense
## (public domain). Tools/art/nunchuk_scan_keys.py crops each key to its cap plus a 5.5 mm
## skirt, welds it down to a few thousand triangles and writes Tools/scan/nunchuk_*.tri;
## the 250 MB scans themselves are not in this repo.
##
## The shell stays procedural and the keys do not, and the split is not arbitrary. A
## shell is a smooth loft and reads as one. What makes a key read as a key is a crisp
## outline and a parting line, and every attempt to measure THOSE and redraw them here
## gave a different answer -- the rake alone came back at 21, 25, 27, 31, 41 and 63
## degrees on the same part, differing only in which facets were gathered, because a
## scanned button is mostly internal ribs and stem and they out-vote the 13 mm of face
## that shows. Cropping ends the argument: the part carries its own shape and size.
##
## What the scan does NOT carry over is placement. It knows what a key looks like; it
## does not know what this shell looks like, and they are not the same surface. The seat
## is still _seat_rake's, bisected so both ends of the key stand the same distance off.
func _build_c() -> void:
	_build_scan_part("res://Tools/scan/nunchuk_c.tri",
		"res://Scenes/Objects/controllers/wii/nunchuk_c.res")


## Z: the trigger. Cut from the scan too -- see _build_c above for why.
func _build_z() -> void:
	_build_scan_part("res://Tools/scan/nunchuk_z.tri",
		"res://Scenes/Objects/controllers/wii/nunchuk_z.res")
## Stitches a stack of rings into a triangle soup.
static func _loft(rings: Array) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for r in range(rings.size() - 1):
		var lo: Array = rings[r]
		var hi: Array = rings[r + 1]
		for s in lo.size():
			var s2 := (s + 1) % lo.size()
			var a: Vector3 = lo[s]
			var b: Vector3 = lo[s2]
			var c: Vector3 = hi[s]
			var d: Vector3 = hi[s2]
			# A pole ring collapses one side of the quad; emitting the degenerate
			# triangle anyway would leave a zero-area face for generate_normals to
			# average in, which dimples the crown.
			if a.is_equal_approx(b):
				out.append_array([a, d, c])
			elif c.is_equal_approx(d):
				out.append_array([a, b, c])
			else:
				out.append_array([a, b, c])
				out.append_array([b, d, c])
	return out




# ── Helpers ──────────────────────────────────────────────────────────────────

## A horizontal ring of radius `r` at height `y`. Radius zero makes it a pole.
static func _disc(y: float, r: float) -> Array:
	var out: Array = []
	for s in SEGS:
		var a := TAU * float(s) / float(SEGS)
		out.append(Vector3(r * sin(a), y, r * cos(a)))
	return out


## Weld, smooth-shade and pack a triangle soup. Indexing FIRST is what makes
## generate_normals average across the seams instead of faceting every quad.
func _smooth(tris: Array[Vector3]) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in _orient(tris):
		st.add_vertex(v)
	st.index()
	st.generate_normals()
	return st.commit()


## Turn a solid the right way out if it came out inside in.
##
## Which way a loft winds depends on which way its rings TRAVEL, and the five solids
## here do not agree: the shell and the boot are stacked downward from the crown and
## the tail, the stick and the keys upward from their seats. Wound by hand that is a
## sign to get wrong in three places out of five — it was, first run — so nothing here
## reasons about it. The soup is weighed and flipped whole.
##
## The TARGET SIGN is negative, and this shipped with it positive. Godot's front face
## is the CLOCKWISE one, so `generate_normals` returns the negative of the textbook
## (b-a) x (c-a): a soup wound anticlockwise-from-outside — the orientation the
## divergence theorem calls POSITIVE volume — is back-to-front for the renderer.
##
## An inside-out solid does not look inverted, which is why this survived so long.
## It still paints an opaque silhouette, because what you see is the far inner
## surface. What it stops doing is OCCLUDING: every outward face is culled, so it
## writes no depth on the side you are looking at and anything inside or behind it
## draws straight through. Believe `_check_outward` rather than this comment.
static func _orient(tris: Array[Vector3]) -> Array[Vector3]:
	if _volume(tris) <= 0.0:
		return tris
	var out: Array[Vector3] = []
	for i in range(0, tris.size(), 3):
		out.append_array([tris[i], tris[i + 2], tris[i + 1]])
	return out


static func _volume(tris: Array[Vector3]) -> float:
	var v := 0.0
	for i in range(0, tris.size(), 3):
		v += tris[i].dot(tris[i + 1].cross(tris[i + 2])) / 6.0
	return v


func _save(mesh: ArrayMesh, path: String) -> void:
	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	print("[gen] %-44s err=%d  %.4f x %.4f x %.4f m  %s" % [path, err,
		ab.size.x, ab.size.y, ab.size.z, _check_outward(mesh)])


## Does this solid face outward, as the RENDERER will read it?
##
## NOT a volume sign — that is the test that was wrong here, and it passed for
## every mesh in this file while all of them were inside out. This reads the
## normals actually stored in the committed mesh, at the six vertices furthest
## along each axis, and asks whether each points the way that vertex faces.
##
## It is worth the lines because it is the only check here that can tell an
## inside-out solid from a correct one. A volume sign, an AABB and a manifold edge
## count are identical for both.
static func _check_outward(mesh: ArrayMesh) -> String:
	var arrays := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var bad: Array[String] = []
	var axes := {"+X": Vector3.RIGHT, "-X": Vector3.LEFT, "+Y": Vector3.UP,
		"-Y": Vector3.DOWN, "+Z": Vector3.BACK, "-Z": Vector3.FORWARD}
	for label: String in axes:
		var axis: Vector3 = axes[label]
		var best := 0
		for i in v.size():
			if v[i].dot(axis) > v[best].dot(axis):
				best = i
		if n[best].dot(axis) <= 0.0:
			bad.append(label)
	return "outward" if bad.is_empty() else "<-- INSIDE OUT on %s" % ", ".join(bad)


## Signed volume of the committed solid, read back from its own stored arrays.
static func _enclosed(mesh: ArrayMesh) -> float:
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var v := 0.0
	for i in range(0, idx.size(), 3):
		v += verts[idx[i]].dot(verts[idx[i + 1]].cross(verts[idx[i + 2]])) / 6.0
	return v

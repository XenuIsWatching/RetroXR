## Bakes the Wii SENSOR BAR connector PAIR to Scenes/Objects/wii_sensor_{plug,jack}.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_wii_sensor.gd
##
## Both halves in one file for gen_vga.gd's reason: the male barrel and the female
## mouth come off the same constants, so the fit cannot drift.
##
## ── Dimensions ───────────────────────────────────────────────────────────────
## CALIPERED off a real lead:
##
##   grey hood      18 long x 10.75 wide x 8 high
##   barrel         7 x 5, standing 5 mm proud of the hood face
##   orange lip     the last 2 mm of that 5, and a 1.25 mm RIM rather than a face —
##                  the cup behind it is orange too, and about as deep as the metal
##   key            a corner cut 2 mm into the barrel's 5 mm dimension, on the same
##                  side as the hood's ribbed face
##   cord           1.6 mm
##   socket mouth   9.5 x 7, its own corner cut 2 mm into the 7 mm side
##
## The two cuts agreeing at 2 mm is the check that they are the same feature measured
## from both halves.
##
## DERIVED: the red moulding's 0.75 mm wall and 1.5 mm proud face. There is no black
## bezel round this one — the red part sits straight in the white case.
##
## ── The key, and why the halves are NOT authored alike ────────────────────────
## ONE corner is cut, not two, so unlike the AV Multi Out this connector is asymmetric
## about Y — and that is exactly the case gen_vga.gd's D-shell note is about.
##
## A snap zone composes plug_basis = zone_basis * Rx(180) while a jack parented to the
## zone gets zone_basis itself, so a mated pair differs by a Y NEGATION that no
## rotation of the port can undo. The Multi Out escapes it because its key is on an END
## and its two cut corners are symmetric about Y. This one does not:
##
##   socket key at (-X, -Y)      plug key at (-X, +Y)
##
## Author them alike and the plug keys against the corner diagonally opposite the one
## it has to mate with, which no amount of turning the port node will fix.
##
## Those two land the cut TOP-RIGHT of the socket as you look at the back panel from
## behind with the console the right way up — the disc slot near the panel's top edge.
## The port's basis puts its local +X on the room's +X and its local +Y on the room's
## -Y, so local (-X, -Y) comes out (-X, high): the same side of the machine as the
## Multi Out's key. Both booleans below flip together if that is ever wrong.
##
## ── Contracts ────────────────────────────────────────────────────────────────
## Authored connector-on-+Z, cable-trailing--Z — VerletRope's plug_exit_axis and what
## RcaPlug._derive_cable_anchor reads. The MALE origin sits on the hood's front face
## and the FEMALE origin on the panel plane.
##
## MATING: the hood's face stops on the red moulding, which stands 1.5 mm proud, so a
## seated plug's origin ends up 1.5 mm proud of the panel. The 5 mm barrel is longer
## than anything drawn on this side of the panel and is meant to be — it goes through
## the mouth into the console's own body, which is solid and hides it. Only the
## quarter-millimetre of slot in front reads, and it reads because of its MATERIAL:
## these rooms light with ambient_light_source = COLOR and no radiance map, so the
## floor of a bore is lit exactly as brightly as its mouth.
##
## Surface order:
##   0 = grey hood and boot   (plug) / the red moulding (jack)
##   1 = the chrome barrel    (plug) / the dark slot     (jack)
##   2 = the orange cap       (plug)
extends SceneTree

const PlugMats := preload("res://Tools/gen/plug_materials.gd")

const OUT_PLUG := "res://Scenes/Objects/system_models/wii/wii_sensor_plug.res"
const OUT_JACK := "res://Scenes/Objects/system_models/wii/wii_sensor_jack.res"

# --- calipered ---------------------------------------------------------------
const HOOD_L := 0.018
const HOOD_W := 0.01075
const HOOD_H := 0.008
const BARREL_W := 0.007
const BARREL_H := 0.005
const BARREL_PROUD := 0.005
const CAP_L := 0.002             # the orange, part of BARREL_PROUD
const KEY_CUT := 0.002           # 5 - 3, into the barrel's 5 mm dimension
## The orange is a LIP round a hollow, not a solid nose: a 1.25 mm wall with an
## orange-lined cup behind it, sunk as deep as the metal section is long. Calipered.
const LIP_T := 0.00125
const CORD_D := 0.0016
const MOUTH_W := 0.0095
const MOUTH_H := 0.007
const MOUTH_CUT := 0.002         # 7 - 5, into the mouth's 7 mm dimension

# --- derived -----------------------------------------------------------------
const RED_WALL := 0.00075
## The hood and the red surround follow the section they enclose rather than being
## plain rectangles. Not styling: _band pairs its two loops index for index, so a
## 5-cornered keyed section inside a 4-cornered rounded rectangle has nothing to pair
## with. Resampling one along the other's directions was tried and threw a stray flap
## off the hood's front face — the sibling gen_wii_av.gd pairs like with like, and so
## does this now.
const HOOD_CUT := 0.0015
const HOOD_R := 0.0006
const BARREL_R := 0.0004

const HOOD_GREY := Color(0.44, 0.44, 0.42)
const CAP_ORANGE := Color(0.82, 0.26, 0.09)
const RED_MOULD := Color(0.72, 0.21, 0.07)

const ARC := 3
const RING := 12

# --- plug z ------------------------------------------------------------------
const Z_TIP := BARREL_PROUD
const Z_CAP := BARREL_PROUD - CAP_L
## How far the cup is sunk: the length of the metal section, which is what "about as
## deep as the metallic part" measures out as. Derived rather than written as 3 mm, so
## shortening the orange cannot silently deepen the hole.
const CUP_DEPTH := BARREL_PROUD - CAP_L
const Z_CUP_FLOOR := Z_TIP - CUP_DEPTH
const Z_FACE := 0.0
const Z_HOOD_BACK := -HOOD_L
const Z_CORD := -0.030
const RELIEF_RIBS := 4
const RELIEF_RIB_AMP := 0.0004
const BOOT_R := 0.0026

# --- jack z ------------------------------------------------------------------
const Z_PANEL := 0.0
const Z_MOUTH_FLOOR := 0.0002
const Z_RED := 0.0015

## Where a seated plug's origin ends up, for the port that carries this jack.
const PROUD := Z_RED


func _init() -> void:
	_build_plug()
	_build_jack()
	quit()


# ── the male plug ────────────────────────────────────────────────────────────

func _build_plug() -> void:
	var mesh := ArrayMesh.new()
	var hood := _key_loop(HOOD_W, HOOD_H, HOOD_CUT, HOOD_R, true)
	# Key on +Y. See the header: the jack cuts -Y, and the pair only mates because
	# the snap zone's Rx(180) negates one of them.
	var barrel := _key_loop(BARREL_W, BARREL_H, KEY_CUT, BARREL_R, true)

	# --- surface 0: the grey hood and its boot -------------------------------
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_loft(st, hood, Z_HOOD_BACK, hood, Z_FACE)
	_band(st, barrel, hood, Z_FACE, true)
	_cap(st, hood, Z_HOOD_BACK, false)
	_lathe(st, _boot_profile())
	st.generate_normals()
	var m_hood := PlugMats.matte(HOOD_GREY)
	st.set_material(m_hood)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, m_hood)

	# --- surface 1: the chrome barrel ----------------------------------------
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_loft(st, barrel, Z_FACE, barrel, Z_CAP)
	st.generate_normals()
	var m_metal := PlugMats.chrome()
	st.set_material(m_metal)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(1, m_metal)

	# --- surface 2: the orange cap -------------------------------------------
	# The one part of this connector anybody can name from across the room, and the
	# only reason the socket is findable at all: an orange nose against a white case.
	# A RIM and not a face. The wall is 1.25 mm and everything inside it is orange too,
	# sunk the length of the metal section — so what reads at arm's length is a bright
	# ring round a dimmer bore rather than a solid orange block.
	var cup := _key_loop(BARREL_W - 2.0 * LIP_T, BARREL_H - 2.0 * LIP_T,
		KEY_CUT - LIP_T, BARREL_R, true)
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_loft(st, barrel, Z_CAP, barrel, Z_TIP)        # the outside of the lip
	_band(st, cup, barrel, Z_TIP, true)            # the 1.25 mm rim itself
	_loft(st, cup, Z_TIP, cup, Z_CUP_FLOOR)        # wound inward: the cup's wall
	_cap(st, cup, Z_CUP_FLOOR, true)               # and its floor
	st.generate_normals()
	var m_cap := PlugMats.matte(CAP_ORANGE, 0.60)
	st.set_material(m_cap)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(2, m_cap)

	_save(mesh, OUT_PLUG, true)


func _boot_profile() -> PackedVector2Array:
	var p := PackedVector2Array()
	# Starts 2 mm INSIDE the hood, not on its back face. The boot and the hood are
	# separate overlapping solids, so a base disc sitting exactly on the hood's rear
	# cap is coplanar with it and the two z-fight — which showed up as a gash torn
	# across the joint, not as the shimmer coplanar faces usually give. Buried, it
	# costs nothing: nobody sees inside a closed moulding.
	var zin: float = Z_HOOD_BACK + 0.002
	p.append(Vector2(zin, 0.0))
	var steps := RELIEF_RIBS * 3
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var z: float = lerpf(zin, Z_CORD, t)
		var base: float = lerpf(BOOT_R, CORD_D * 0.5, t)
		var bump: float = 0.5 + 0.5 * sin(t * float(RELIEF_RIBS) * TAU - PI * 0.5)
		p.append(Vector2(z, base + RELIEF_RIB_AMP * bump))
	p.append(Vector2(Z_CORD, CORD_D * 0.5))
	p.append(Vector2(Z_CORD, 0.0))
	return p


# ── the female jack ──────────────────────────────────────────────────────────
#
# Authored ENTIRELY at z >= 0, in front of the panel. A panel-mount socket sits on a
# solid panel, and anything authored behind the flange has the case's own back face
# between it and the eye — gen_vga.gd records what that looks like.

func _build_jack() -> void:
	var mesh := ArrayMesh.new()
	# Key on -Y — the opposite corner to the plug's. See the header.
	var mouth := _key_loop(MOUTH_W, MOUTH_H, MOUTH_CUT, BARREL_R, false)
	var outer := _key_loop(MOUTH_W + 2.0 * RED_WALL, MOUTH_H + 2.0 * RED_WALL,
		MOUTH_CUT, HOOD_R, false)

	# --- surface 0: the red moulding -----------------------------------------
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_loft(st, outer, Z_PANEL, outer, Z_RED)
	_band(st, mouth, outer, Z_RED, true)
	st.generate_normals()
	var m_red := PlugMats.matte(RED_MOULD, 0.60)
	st.set_material(m_red)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, m_red)

	# --- surface 1: the slot -------------------------------------------------
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_loft(st, mouth, Z_RED, mouth, Z_MOUTH_FLOOR)   # wound inward
	_cap(st, mouth, Z_MOUTH_FLOOR, true)
	st.generate_normals()
	var m_void := StandardMaterial3D.new()
	m_void.albedo_color = Color(0.020, 0.020, 0.024)
	m_void.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	st.set_material(m_void)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(1, m_void)

	_save(mesh, OUT_JACK, false)


# ── geometry helpers ─────────────────────────────────────────────────────────
#
# gen_wii_av.gd's set. Every one emits in Godot's Plane(a,b,c) order, so facing
# follows vertex order: a loft with z increasing faces outward, one with z decreasing
# faces into a bore, and a band faces +Z when its inner loop is passed first.


## A rectangle with ONE corner cut at 45 degrees — this connector's key. `cut_pos_y`
## picks which side of the section the cut is on, and the two halves of the pair take
## opposite answers; see the header for why that is not a slip.
##
## Five corners either way, and every loop in this file is one of these, so any two
## pair up edge for edge.
func _key_loop(w: float, h: float, cut: float, r: float,
		cut_pos_y: bool) -> PackedVector2Array:
	var hw: float = w * 0.5
	var hh: float = h * 0.5
	var pts: PackedVector2Array
	if cut_pos_y:
		pts = PackedVector2Array([
			Vector2(hw, hh),
			Vector2(-hw + cut, hh),
			Vector2(-hw, hh - cut),
			Vector2(-hw, -hh),
			Vector2(hw, -hh),
		])
	else:
		pts = PackedVector2Array([
			Vector2(hw, hh),
			Vector2(-hw, hh),
			Vector2(-hw, -hh + cut),
			Vector2(-hw + cut, -hh),
			Vector2(hw, -hh),
		])
	return _fillet(pts, r)


func _fillet(corners: PackedVector2Array, r: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := corners.size()
	for i in n:
		var p: Vector2 = corners[i]
		var u: Vector2 = (corners[(i - 1 + n) % n] - p).normalized()
		var v: Vector2 = (corners[(i + 1) % n] - p).normalized()
		var half: float = acos(clampf(u.dot(v), -1.0, 1.0)) * 0.5
		var c: Vector2 = p + (u + v).normalized() * (r / sin(half))
		var a0: float = (p + u * (r / tan(half)) - c).angle()
		var a1: float = (p + v * (r / tan(half)) - c).angle()
		var da: float = wrapf(a1 - a0, -PI, PI)
		for k in range(ARC + 1):
			out.append(c + Vector2(r, 0.0).rotated(a0 + da * float(k) / float(ARC)))
	return out


func _loft(st: SurfaceTool, l0: PackedVector2Array, z0: float,
		l1: PackedVector2Array, z1: float) -> void:
	var n := l0.size()
	for i in n:
		var j := (i + 1) % n
		var p00 := Vector3(l0[i].x, l0[i].y, z0)
		var p10 := Vector3(l0[j].x, l0[j].y, z0)
		var p01 := Vector3(l1[i].x, l1[i].y, z1)
		var p11 := Vector3(l1[j].x, l1[j].y, z1)
		st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
		st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)


## Flat band between two concentric loops at one z, paired index for index. Faces +Z
## as written. Both loops must therefore carry the same point count — see HOOD_CUT.
func _band(st: SurfaceTool, inner: PackedVector2Array, outer: PackedVector2Array,
		z: float, face_pos: bool) -> void:
	var n := inner.size()
	for i in n:
		var j := (i + 1) % n
		var i0 := Vector3(inner[i].x, inner[i].y, z)
		var i1 := Vector3(inner[j].x, inner[j].y, z)
		var o0 := Vector3(outer[i].x, outer[i].y, z)
		var o1 := Vector3(outer[j].x, outer[j].y, z)
		if face_pos:
			st.add_vertex(i0); st.add_vertex(o1); st.add_vertex(o0)
			st.add_vertex(i0); st.add_vertex(i1); st.add_vertex(o1)
		else:
			st.add_vertex(i0); st.add_vertex(o0); st.add_vertex(o1)
			st.add_vertex(i0); st.add_vertex(o1); st.add_vertex(i1)


func _cap(st: SurfaceTool, loop: PackedVector2Array, z: float,
		face_pos: bool) -> void:
	var c := Vector2.ZERO
	for p: Vector2 in loop:
		c += p
	c /= float(loop.size())
	var cv := Vector3(c.x, c.y, z)
	for i in loop.size():
		var j := (i + 1) % loop.size()
		var a := Vector3(loop[i].x, loop[i].y, z)
		var b := Vector3(loop[j].x, loop[j].y, z)
		if face_pos:
			st.add_vertex(cv); st.add_vertex(b); st.add_vertex(a)
		else:
			st.add_vertex(cv); st.add_vertex(a); st.add_vertex(b)


func _lathe(st: SurfaceTool, profile: PackedVector2Array) -> void:
	for s in range(profile.size() - 1):
		var z0: float = profile[s].x
		var r0: float = profile[s].y
		var z1: float = profile[s + 1].x
		var r1: float = profile[s + 1].y
		if is_equal_approx(z0, z1) and is_equal_approx(r0, r1):
			continue
		for i in RING:
			var a0: float = TAU * float(i) / float(RING)
			var a1: float = TAU * float(i + 1) / float(RING)
			var p00 := Vector3(cos(a0) * r0, sin(a0) * r0, z0)
			var p10 := Vector3(cos(a1) * r0, sin(a1) * r0, z0)
			var p01 := Vector3(cos(a0) * r1, sin(a0) * r1, z1)
			var p11 := Vector3(cos(a1) * r1, sin(a1) * r1, z1)
			if is_zero_approx(r0):
				st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
			elif is_zero_approx(r1):
				st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p10)
			else:
				st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
				st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)


func _save(mesh: ArrayMesh, path: String, want_cord: bool) -> void:
	var ab: AABB = mesh.get_aabb()
	if ab.end.z <= 0.0:
		push_error("[gen] %s REFUSING: connector must sit on +Z" % path)
		return
	if want_cord and ab.position.z >= 0.0:
		push_error("[gen] %s REFUSING: cable must trail -Z" % path)
		return
	var err := ResourceSaver.save(mesh, path)
	var tris := 0
	for s in mesh.get_surface_count():
		tris += mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX].size() / 3
	print("[gen] %s err=%d  %.4f x %.4f x %.4f m  z %.4f..%.4f  tris %d" % [
		path, err, ab.size.x, ab.size.y, ab.size.z,
		ab.position.z, ab.end.z, tris])

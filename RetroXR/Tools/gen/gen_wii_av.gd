## Bakes the Wii AV Multi Out PAIR to Scenes/Objects/wii_av_{plug,jack}.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_wii_av.gd
##
## Both halves in one file for the reason gen_vga.gd gives: the male tongue and the
## female mouth come off the same constants, so the fit cannot drift.
##
## ── Dimensions ───────────────────────────────────────────────────────────────
## CALIPERED off a real lead:
##
##   grey shroud       27 wide x 15 thick x 30 along the cable
##   black tongue      22 x 7.2, standing 13 mm proud of the shroud face
##
##   black bezel       23.5 x 12       the moulded frame in the case
##
## DERIVED — kept separate so nobody mistakes it for a measured value:
##
##   mouth             22.4 x 7.6      tongue + 0.4
##
## The bezel is SMALLER than the 27 x 15 shroud, which is what says there is no
## counterbore: the shroud cannot nose into an opening narrower than itself, so it
## butts against the bezel's face and stops there. Wall thickness falls out at 0.55 mm
## across and 2.2 mm up, which is what a moulded socket of this size has.
##
## ── The key ──────────────────────────────────────────────────────────────────
## Both corners of ONE 7.2 mm END are cut at 45 degrees, so that end of the section is
## a trapezoid and the plug only goes in one way. The cut is on -X in BOTH meshes, and
## that is not a copy-paste slip:
##
## gen_vga.gd's D-shell has to be authored upside down because a snap zone composes
## plug_basis = zone_basis * Rx(180) while a jack parented to the zone gets
## zone_basis itself, so a mated pair differs by a Y NEGATION that no rotation of the
## port can undo. Rx(180) leaves X alone. This connector's key is on an end rather
## than an edge, and the two cut corners are symmetric about Y, so the reflection
## lands the pair exactly on top of each other and the mirror is not wanted here.
##
## A key on the OTHER axis would need it. Anything copied from this file onto a
## connector keyed in Y should read the gen_vga.gd note first.
##
## ── Contracts ────────────────────────────────────────────────────────────────
## Authored connector-on-+Z, cable-trailing--Z, which is VerletRope's plug_exit_axis
## and what RcaPlug._derive_cable_anchor reads. The MALE origin sits on the shroud's
## front face and the FEMALE origin on the panel plane, so the jack drops onto a port
## node pushed back by the proud offset — rca_port.tscn's rule.
##
## MATING: the shroud stops flat on the bezel's face, so a seated plug's origin ends up
## 2.0 mm proud of the panel — the bezel's own thickness. That is this connector's
## equivalent of the RCA pair's 10 mm and the VGA pair's 7.5, and wii_av_port.tscn
## carries it. Use another connector's number and the plug floats or sinks.
##
## The 13 mm tongue is longer than anything drawn on this side of the panel, and it is
## meant to be: it passes through the mouth and into the console's own body, which is
## solid and hides it. Only the 1 mm of slot in front of the panel is ever seen, and
## that reads as depth because of its MATERIAL, not its geometry — these rooms light
## with ambient_light_source = COLOR and no radiance map, so the floor of a bore is
## lit exactly as brightly as its mouth. Same trap gen_rca_jack.gd and gen_vga.gd
## both document.
##
## Two surfaces each:
##   0 = every moulded part, ONE surface on the shared connector material
##       (Shaders/connector.gdshader) with the part carried in vertex colour —
##       grey shroud, boot and black tongue (plug) / black bezel and the contact
##       blade (jack)
##   1 = the dark cavity inside the tongue (plug) / the dark slot (jack), on
##       _void() — UNSHADED, which the connector shader has no class for, so it
##       stays its own surface
## Nothing here is the tinted class: this lead's console end is one connector
## carrying three cords and has no cord colour, and CompositeCable never tints a
## shared plug, so the tinted class would only fall back to the shader's yellow.
##
## Winding is load-bearing: generate_normals() derives facing from vertex order alone.
## Every helper below emits in Godot's Plane(a,b,c) order, so a loft with z increasing
## faces outward and one with z decreasing faces into a bore.
extends SceneTree

const PlugMats := preload("res://Tools/gen/plug_materials.gd")

const OUT_PLUG := "res://Scenes/Objects/system_models/wii/wii_av_plug.res"
const OUT_JACK := "res://Scenes/Objects/system_models/wii/wii_av_jack.res"

# --- calipered ---------------------------------------------------------------
const SHROUD_W := 0.027
const SHROUD_H := 0.015
const SHROUD_L := 0.030
const TONGUE_W := 0.022
const TONGUE_H := 0.0072
const TONGUE_L := 0.013

# --- derived -----------------------------------------------------------------
const KEY_CUT := 0.0020          # 45 deg corner cut, both corners of the -X end
const SHROUD_CUT := 0.0030       # ONE corner only, like the bezel it lands on
const CLEAR := 0.0002            # sliding fit, per side

## 0.7 mm, not the 1.2 a hood this size invites. A moulded connector is a flat-faced
## block with a broken edge; at 1.2 on a 15 mm section the shroud rendered as a bar of
## soap, which is the same trap gen_vga.gd's HOOD_R records.
const SHROUD_R := 0.0007
const TONGUE_R := 0.0005
const TONGUE_WALL := 0.0009

## The moulded grey. Dark enough to read AS grey against the console's own off-white
## shell, which is the only place this plug is ever seen: at the 0.60 it was first
## given, a lit face came back near 0.80 and the lead looked like part of the case.
const SHROUD_GREY := Color(0.46, 0.46, 0.44)
const TONGUE_BLACK := Color(0.075, 0.075, 0.080)
const BLADE_GREY := Color(0.50, 0.50, 0.48)

const ARC := 4                   # samples per filleted corner
const RING := 16

# --- plug z ------------------------------------------------------------------
const Z_TIP := 0.0130            # the tongue's end
const Z_CAVITY := 0.0010         # floor of the hollow inside it
const Z_FACE := 0.0              # shroud front face, the mating plane
const Z_SHROUD_BACK := -0.0300
const Z_CORD := -0.0500
const RELIEF_RIBS := 5
const RELIEF_RIB_AMP := 0.0005
## The strain relief, sized against the two things it actually sits between rather
## than picked: 14.4 mm across where it leaves a 15 mm-thick shroud, tapering over
## 20 mm to 9.6 mm at the cord.
##
## Both were half that and the boot read as pinched. The tell was the far end — a boot
## has to end WIDER than the cord it grips, and this one ended at 7.4 mm on a ribbon
## measuring 13. CORD_R now clears the ribbon wii_av_cable.tscn actually ships: three
## 3 mm cords side by side, so 9 mm across. Change that scene's tube_radius and change
## this with it.
const BOOT_R := 0.0072
const CORD_R := 0.0048

# --- jack z ------------------------------------------------------------------
const Z_PANEL := 0.0
const Z_MOUTH_FLOOR := 0.0002    # the slot's dark back wall
const Z_BLADE := 0.0010
const Z_BEZEL := 0.0020          # the black frame's face: the shroud stops here

## Where a seated plug's origin ends up, for wii_av_port.tscn. Named rather than
## written twice — see the MATING note in the header.
const PROUD := Z_BEZEL

const BEZEL_W := 0.0235
const BEZEL_H := 0.012
## 2.2 mm, not the 3.5 an 18 mm-tall frame took. The bevel has to clear the mouth's
## own corner, which on a 12 mm frame sits only 2.2 mm inside the edge: at 2.5 the cut
## passed within a quarter millimetre of it.
const BEZEL_CUT := 0.0022
const BEZEL_R := 0.0010
const BLADE_T := 0.0012
const BLADE_Y := -0.0004         # a shade below centre, as the real mouth has it


func _init() -> void:
	_build_plug()
	_build_jack()
	quit()


# ── the male plug ────────────────────────────────────────────────────────────

func _build_plug() -> void:
	var mesh := ArrayMesh.new()

	var shroud := _one_cut_loop(SHROUD_W, SHROUD_H, SHROUD_CUT, SHROUD_R, true)
	var tongue := _key_loop(TONGUE_W, TONGUE_H, KEY_CUT, TONGUE_R)
	var cavity := _key_loop(TONGUE_W - 2.0 * TONGUE_WALL, TONGUE_H - 2.0 * TONGUE_WALL,
		KEY_CUT - TONGUE_WALL, TONGUE_R)

	# --- surface 0: the grey shroud and its boot, and the black tongue -------
	# One SurfaceTool for every moulded part: each is built after set_color() with
	# its class, and the lot commits as ONE surface on the shared connector
	# material. See Shaders/connector.gdshader for why.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(PlugMats.matte_vertex(SHROUD_GREY))
	# -1 is the FLAT smooth group, and it is not optional here: generate_normals()
	# averages every face meeting at a shared position, and this connector has plenty —
	# the orange rim's inner edge sits exactly on the cup's mouth, the barrel's tip on
	# the rim's outer edge. Averaged, those faces shade toward each other and whole
	# panels read as holes. Same call gen_wii_body.gd makes and for the same reason.
	st.set_smooth_group(-1)
	_loft(st, shroud, Z_SHROUD_BACK, shroud, Z_FACE)
	# Front face: a band from the shroud's edge in to where the tongue emerges.
	_band(st, tongue, shroud, Z_FACE, true)
	# Closed solid at the back and the boot lofted out of it. Two overlapping solids
	# rather than one lofted section, because the boot is round and the shroud is a
	# six-cornered keyed loop: they cannot share a vertex count, and the seam is
	# inside the moulding where nothing looks at it.
	_cap(st, shroud, Z_SHROUD_BACK, false)
	_lathe(st, _boot_profile())

	# The black tongue.
	st.set_color(PlugMats.matte_vertex(TONGUE_BLACK))
	_loft(st, tongue, Z_FACE, tongue, Z_TIP)         # outside wall
	_band(st, cavity, tongue, Z_TIP, true)           # the rim at the open end
	_commit(st, mesh)

	# --- surface 1: the cavity the socket's blade enters ---------------------
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	_loft(st, cavity, Z_TIP, cavity, Z_CAVITY)       # wound inward: an inside wall
	_cap(st, cavity, Z_CAVITY, true)
	st.generate_normals()
	var m_void := _void()
	st.set_material(m_void)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(1, m_void)

	_save(mesh, OUT_PLUG, true)


## The ribbed strain relief, as a (z, radius) profile revolved about Z. Ribs sampled
## three times each — two points per rib gives back a sawtooth however many you use,
## which is the lesson gen_rca_plug.gd's relief records.
func _boot_profile() -> PackedVector2Array:
	var p := PackedVector2Array()
	# Starts 2 mm INSIDE the shroud, not on its back face. The boot and the shroud are
	# separate overlapping solids, so a base disc sitting exactly on the shroud's rear
	# cap is coplanar with it and the two z-fight — which showed up as a gash torn
	# across the joint, not as the shimmer coplanar faces usually give. Buried, it
	# costs nothing: nobody sees inside a closed moulding.
	var zin: float = Z_SHROUD_BACK + 0.002
	p.append(Vector2(zin, 0.0))
	var steps := RELIEF_RIBS * 3
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var z: float = lerpf(zin, Z_CORD, t)
		var base: float = lerpf(BOOT_R, CORD_R, t)
		var bump: float = 0.5 + 0.5 * sin(t * float(RELIEF_RIBS) * TAU - PI * 0.5)
		p.append(Vector2(z, base + RELIEF_RIB_AMP * bump))
	p.append(Vector2(Z_CORD, CORD_R))
	p.append(Vector2(Z_CORD, 0.0))
	return p


# ── the female jack ──────────────────────────────────────────────────────────
#
# Authored ENTIRELY at z >= 0, i.e. in front of the panel face. That is not
# cosmetic: a panel-mount socket sits on a solid panel, and anything authored behind
# the flange has the case's own back face between it and the eye. gen_vga.gd records
# what that looks like — a blank rectangle where the connector should be.
#
# So the recess this connector really has is turned inside out: a 2.5 mm frame
# standing proud with the counterbore sunk into IT, rather than a flush frame with
# the bore sunk into the case. The silhouette from any angle a player stands at is
# the same, and the alternative is cutting a hole through gen_wii_body.gd's back
# face for one socket.

func _build_jack() -> void:
	var mesh := ArrayMesh.new()

	var bezel := _one_cut_loop(BEZEL_W, BEZEL_H, BEZEL_CUT, BEZEL_R, false)
	var mouth := _key_loop(TONGUE_W + 2.0 * CLEAR, TONGUE_H + 2.0 * CLEAR,
		KEY_CUT, TONGUE_R)

	# --- surface 0: the black bezel, and the contact blade -------------------
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	st.set_color(PlugMats.matte_vertex(TONGUE_BLACK))
	_loft(st, bezel, Z_PANEL, bezel, Z_BEZEL)            # the frame's outside
	_band(st, mouth, bezel, Z_BEZEL, true)               # its face, straight to the mouth
	# The contact blade: the bar across the mouth, which is what the plug's hollow
	# tongue swallows. It is the one light thing inside a black opening, so it is
	# most of what says this socket is a socket rather than a printed rectangle.
	st.set_color(PlugMats.matte_vertex(BLADE_GREY))
	var bw: float = TONGUE_W - 2.0 * TONGUE_WALL - 0.0010
	_box(st, -bw * 0.5, bw * 0.5, BLADE_Y - BLADE_T * 0.5, BLADE_Y + BLADE_T * 0.5,
		Z_MOUTH_FLOOR, Z_BLADE)
	_commit(st, mesh)

	# --- surface 1: the slot itself ------------------------------------------
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	_loft(st, mouth, Z_BEZEL, mouth, Z_MOUTH_FLOOR)      # wound inward
	_cap(st, mouth, Z_MOUTH_FLOOR, true)
	st.generate_normals()
	var m_void := _void()
	st.set_material(m_void)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(1, m_void)

	_save(mesh, OUT_JACK, false)


## Every moulded part as ONE surface on the shared connector material.
func _commit(st: SurfaceTool, mesh: ArrayMesh) -> void:
	st.generate_normals()
	var mat := PlugMats.connector()
	st.set_material(mat)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, mat)


## Near-black and UNSHADED, for the inside of the slot and the inside of the tongue.
##
## Unshaded rather than merely dark: with ambient_light_source = COLOR and no radiance
## map, a lit surface at albedo 0.02 still picks up the room's fill and the opening
## goes grey. Shading it out is the only thing that holds a hole open at 1 mm of real
## depth — the point [[flat-ambient-gives-no-bore-shadow]] makes about a bore.
func _void() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.020, 0.020, 0.024)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


# ── geometry helpers ─────────────────────────────────────────────────────────
#
# gen_vga.gd's set, less the ones a connector with no round contacts does not need.
# Every one emits in Godot's Plane(a,b,c) order, so facing follows vertex order: a
# loft with z increasing faces outward, one with z decreasing faces into a bore, and
# a band faces +Z when its inner loop is passed first.


## The keyed section: a rectangle with BOTH corners of its -X end cut at 45 degrees.
## Anticlockwise viewed from +Z. Six corners, ARC+1 points each.
func _key_loop(w: float, h: float, cut: float, r: float) -> PackedVector2Array:
	var hw: float = w * 0.5
	var hh: float = h * 0.5
	return _fillet(PackedVector2Array([
		Vector2(hw, hh),
		Vector2(-hw + cut, hh),
		Vector2(-hw, hh - cut),
		Vector2(-hw, -hh + cut),
		Vector2(-hw + cut, -hh),
		Vector2(hw, -hh),
	]), r, PackedInt32Array([ARC, ARC, ARC, ARC, ARC, ARC]))


## A section with only ONE corner of its -X end cut. Both the socket's BEZEL and the
## plug's grey SHROUD are this; only the tongue and the mouth it goes down carry both
## cuts, because that pair is the actual key.
##
## `cut_pos_y` picks which corner survives, and the two callers take opposite answers.
## A snap zone relates plug to socket by a Y negation, so a shroud cut on +Y lands on
## the bezel's -Y cut when the two are mated — author them alike and the plug's chamfer
## sits over the bezel's square corner. Same trap gen_wii_sensor.gd records at length;
## the tongue escapes it only by being symmetric.
##
## Five corners against the tongue's six, and yet the same 30 points, because _band
## pairs its loops index for index and these have to band together. The square corner
## gets a double-length arc — 2*ARC+1 segments where the others get ARC — which buys
## back the five points the missing corner would have contributed. Sampling a right
## angle twice as finely costs nothing and is invisible.
func _one_cut_loop(w: float, h: float, cut: float, r: float,
		cut_pos_y: bool) -> PackedVector2Array:
	var hw: float = w * 0.5
	var hh: float = h * 0.5
	var pts: PackedVector2Array
	var arcs: PackedInt32Array
	if cut_pos_y:
		pts = PackedVector2Array([
			Vector2(hw, hh),
			Vector2(-hw + cut, hh),
			Vector2(-hw, hh - cut),
			Vector2(-hw, -hh),             # square
			Vector2(hw, -hh),
		])
		arcs = PackedInt32Array([ARC, ARC, ARC, 2 * ARC + 1, ARC])
	else:
		pts = PackedVector2Array([
			Vector2(hw, hh),
			Vector2(-hw, hh),              # square
			Vector2(-hw, -hh + cut),
			Vector2(-hw + cut, -hh),
			Vector2(hw, -hh),
		])
		arcs = PackedInt32Array([ARC, 2 * ARC + 1, ARC, ARC, ARC])
	return _fillet(pts, r, arcs)


## Round the corners of a convex loop, with a PER-CORNER arc count so loops with
## different numbers of corners can still carry the same number of points. Corner i
## becomes an arc of arcs[i]+1 points.
func _fillet(corners: PackedVector2Array, r: float,
		arcs: PackedInt32Array) -> PackedVector2Array:
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
		var seg: int = arcs[i]
		for k in range(seg + 1):
			out.append(c + Vector2(r, 0.0).rotated(a0 + da * float(k) / float(seg)))
	return out


## Wall between two closed loops of equal length. Faces outward when z1 > z0; pass
## the z values reversed for an inside wall.
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


## Flat band between two concentric loops at one z. Faces +Z as written.
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


## Fill a closed loop, fanned from its centroid.
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


## A closed axis-aligned box — the contact blade, which is the only part here that is
## not a section swept along Z.
func _box(st: SurfaceTool, x0: float, x1: float, y0: float, y1: float,
		z0: float, z1: float) -> void:
	var loop := PackedVector2Array([
		Vector2(x1, y1), Vector2(x0, y1), Vector2(x0, y0), Vector2(x1, y0),
	])
	_loft(st, loop, z0, loop, z1)
	_cap(st, loop, z1, true)
	_cap(st, loop, z0, false)


## Revolve a (z, radius) profile about Z.
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


## Save, and REFUSE a bake whose frame is wrong. gen_vga.gd's guard, for gen_vga.gd's
## reason: a mirrored plug seats backwards and trails its cord through the case, which
## is a bug that shows up three files away.
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

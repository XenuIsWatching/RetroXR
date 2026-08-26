## Bakes the bedroom's wall switch — a two-gang toggle plate and one toggle bat —
## to Scenes/Objects/room/switch_plate_2gang.res and switch_toggle.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen_light_switch.gd
##
## Replaces imported-assets/bedroom/furniture/light_switch.glb, which was a
## single-gang download whose lever is moulded into the plate and therefore cannot
## move — light_switch.gd had to lay a plain BoxMesh over it and tilt that. A
## generated plate gives the second gang for free, drops a download, and lets the
## bat be a bat instead of a box.
##
## FRAME. Both meshes are authored in the plate's own space: +X along the wall,
## +Y up, +Z out of the wall. The plate's back face sits at z = 0 and its front at
## z = THICK, so the .tscn mounts it by putting the node ON the wall surface rather
## than by solving an offset.
##
## The toggle's origin is its PIVOT, and the bat runs along +Z — OUT of the wall,
## not up the plate. That is the whole difference between a toggle and a rocker, and
## the first bake got it wrong: a bat authored along +Y and tilted about X leans out
## of the plate and back into it, which is a rocker being pressed. A bat along +Z
## tilted about the same X swings its TIP up and down, which is what a hand expects
## to find. The Button node then needs no basis of its own, and LightSwitch's tilt is
## negative for ON because Rx(+t) takes +Z toward -Y — see the note there.
##
## Real dimensions, because a switch plate is one of the few objects in the room a
## player has a lifetime of muscle memory for. A US two-gang plate is 4.57 x 4.50 in
## (116 x 114 mm) with a 1.875 in (47.6 mm) gang pitch, and the bat is 9 mm across.
## Getting the pitch wrong is the tell: two switches too close read as a light
## dimmer, too far as an outlet cover.
##
## Matte, not plastic(): the clearcoat lobe reads as a WET surface at any roughness,
## and a wall plate is dry moulded thermoset. Same call gen_rf_switch.gd makes.
## Albedo is taken well below what a photo of an ivory plate reads — albedo is
## reflectance, not the pixel value the camera saw.
##
## WINDING is inherited verbatim from gen_rf_switch.gd, which traces its rings as
## (cos a * rx, level, -sin a * rz) and lofts (lo_j, hi_j, hi_j1) / (lo_j, hi_j1,
## lo_j1) to face outward. Both meshes here extrude along +Z, so both use those
## rings turned by Rx(+90) — (x, y, z) -> (x, -z, y). A ROTATION preserves facing;
## swapping two axes instead would mirror it and bake everything inside out.
##
## A consequence of that rule, worth stating because the flat faces below are
## hand-wound: a triangle facing +Z is emitted CLOCKWISE as seen from +Z.
##
## The apertures are WELLS, not through-holes — four walls and a floor 2.5 mm back,
## in a dark material. Darkness has to be a material here: a real through-hole would
## show the room's ambient straight through the wall behind it.
##
## That floor is dark GREY rather than near-black, and the aperture is 10 x 20 mm
## rather than the 11 x 23 the first bake used. Both are the same correction: what
## sits behind a real bat is the switch's own moulded frame catching a little room
## light, and a large flat black rectangle read as a hole punched in the plate — at a
## glance the slot, not the bat, was the thing the eye landed on.
##
## No lettering is baked (the gen_rf_switch rule — keeps a font dependency out of
## the bake). The screw slots are drawn as a dark quad a fifth of a millimetre proud
## of each head rather than cut as a groove: at a 3 mm head the two are the same
## picture, and a cut slot costs a ring, two walls and a floor apiece.
extends SceneTree

const PlugMats := preload("res://Tools/plug_materials.gd")

const PLATE_PATH := "res://Scenes/Objects/room/switch_plate_2gang.res"
const TOGGLE_PATH := "res://Scenes/Objects/room/switch_toggle.res"

# --- Plate ---------------------------------------------------------------------
const HX := 0.058               # 116 mm along the wall
const HY := 0.057               # 114 mm tall
const THICK := 0.008            # 8 mm proud of the wall
const CORNER_R := 0.006
const CORNER_SEG := 4           # samples per corner

## The rim chamfer: the last 3.5 mm of depth comes in by 3.5 mm, so the plate has a
## lit edge all the way round instead of a hard silhouette.
const BEVEL := 0.0035

## The flat field the apertures are cut out of. Rectangular, and inset far enough
## inside the chamfer's rounded inner ring that the annulus between them never
## crosses a corner arc.
const FIELD_X := 0.050
const FIELD_Y := 0.049

## 1.875 in between gang centres.
const GANG_PITCH := 0.0477
const AP_HX := 0.0050           # 10 x 20 mm aperture
const AP_HY := 0.0100
const WELL := 0.0025            # how far the aperture floor sits back

const SCREW_R := 0.0033
const SCREW_Y := 0.0345         # one above and one below each bat
const SCREW_PROUD := 0.0006
const SLOT_HX := 0.0026
const SLOT_HY := 0.00045

# --- Toggle --------------------------------------------------------------------
## (z, half-x, half-y): the bat's cross-section along its own length. 9.2 mm across
## and 6.8 mm thick at the root — a bat is a small paddle, and the aperture is tall
## rather than the bat being tall, so the bat has 23 mm of slot to swing in.
##
## The root sits 4 mm BEHIND the pivot so the heel stays under the aperture floor
## through the whole throw and no gap opens at the base at full tilt.
const BAT_CORNER_R := 0.0016
const BAT_TIP := 0.0180
const BAT_LEVELS := [
	[-0.0040, 0.0044, 0.0040],
	[ 0.0000, 0.0044, 0.0040],
	[ 0.0060, 0.0042, 0.0037],
	[ 0.0120, 0.0038, 0.0032],
	[ 0.0155, 0.0032, 0.0026],
	[ 0.0172, 0.0019, 0.0015],
]

var _sg := 0                    # smooth-group counter, bumped per band


func _init() -> void:
	_bake_plate()
	_bake_toggle()
	quit()


# --- Plate ---------------------------------------------------------------------

func _bake_plate() -> void:
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dark := SurfaceTool.new()
	dark.begin(Mesh.PRIMITIVE_TRIANGLES)
	_sg = 0

	# Back face and side wall, then the chamfer up to the front plane. One smooth
	# group per band: a single group would smooth the wall into the chamfer and the
	# plate would shade like a tube with no edge anywhere (gen_rf_switch's note).
	var back := _ring_xy(0.0, 0.0, CORNER_R)
	var rim := _ring_xy(THICK - BEVEL, 0.0, CORNER_R)
	var lip := _ring_xy(THICK, BEVEL, CORNER_R - BEVEL)
	_band(body, back, rim)
	_band(body, rim, lip)
	body.set_smooth_group(100)
	_cap(body, back, Vector3(0, 0, 0.0), false)

	# Flat front: the annulus from the chamfer's inner ring in to a plain rectangle,
	# then that rectangle minus the two apertures.
	body.set_smooth_group(101)
	var field := _rect_ring_xy(THICK, FIELD_X, FIELD_Y)
	_annulus(body, lip, field)
	_front_field(body)

	# Aperture wells and screw heads.
	for s in [-1.0, 1.0]:
		var cx: float = s * GANG_PITCH * 0.5
		_well(body, dark, cx)
		for t in [-1.0, 1.0]:
			_screw(body, dark, cx, t * SCREW_Y)

	body.generate_normals()
	dark.generate_normals()

	# Ivory, taken a long way down from what an ivory plate photographs as.
	var mat_body := PlugMats.matte(Color(0.62, 0.60, 0.55), 0.80)
	var mat_dark := PlugMats.matte(Color(0.105, 0.100, 0.095), 0.90)
	body.set_material(mat_body)
	dark.set_material(mat_dark)

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, body.commit_to_arrays())
	mesh.surface_set_material(0, mat_body)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, dark.commit_to_arrays())
	mesh.surface_set_material(1, mat_dark)
	_report(PLATE_PATH, mesh)


## The flat front face: the FIELD rectangle with two aperture rectangles taken out,
## decomposed into five bands — above, below, and the row the apertures sit in.
func _front_field(st: SurfaceTool) -> void:
	var z := THICK
	var l: float = GANG_PITCH * 0.5 - AP_HX      # inner edge of the left aperture
	var r: float = GANG_PITCH * 0.5 + AP_HX      # outer edge
	_quad_pz(st, -FIELD_X, FIELD_X, AP_HY, FIELD_Y, z)
	_quad_pz(st, -FIELD_X, FIELD_X, -FIELD_Y, -AP_HY, z)
	_quad_pz(st, -FIELD_X, -r, -AP_HY, AP_HY, z)
	_quad_pz(st, -l, l, -AP_HY, AP_HY, z)
	_quad_pz(st, r, FIELD_X, -AP_HY, AP_HY, z)


## One aperture: four walls facing INTO the well, and a floor set back by WELL.
func _well(body: SurfaceTool, dark: SurfaceTool, cx: float) -> void:
	var z0 := THICK - WELL
	var x0: float = cx - AP_HX
	var x1: float = cx + AP_HX
	body.set_smooth_group(200 + int(signf(cx)) + 1)
	# Walls, wound the reverse of a +Z face so they are seen from inside the well.
	_quad_wall(body, Vector3(x0, -AP_HY, z0), Vector3(x0, AP_HY, z0),
		Vector3(x0, AP_HY, THICK), Vector3(x0, -AP_HY, THICK))
	_quad_wall(body, Vector3(x1, AP_HY, z0), Vector3(x1, -AP_HY, z0),
		Vector3(x1, -AP_HY, THICK), Vector3(x1, AP_HY, THICK))
	_quad_wall(body, Vector3(x1, -AP_HY, z0), Vector3(x0, -AP_HY, z0),
		Vector3(x0, -AP_HY, THICK), Vector3(x1, -AP_HY, THICK))
	_quad_wall(body, Vector3(x0, AP_HY, z0), Vector3(x1, AP_HY, z0),
		Vector3(x1, AP_HY, THICK), Vector3(x0, AP_HY, THICK))
	_quad_pz(dark, x0, x1, -AP_HY, AP_HY, z0)


## A slot-head screw: a shallow domed disc proud of the face, plus the dark quad
## that stands in for its slot.
func _screw(body: SurfaceTool, dark: SurfaceTool, cx: float, cy: float) -> void:
	var base := _ring_circle(cx, cy, THICK, SCREW_R)
	var top := _ring_circle(cx, cy, THICK + SCREW_PROUD, SCREW_R - 0.0004)
	_band(body, base, top)
	body.set_smooth_group(300)
	_cap(body, top, Vector3(cx, cy, THICK + SCREW_PROUD), true)
	_quad_pz(dark, cx - SLOT_HX, cx + SLOT_HX, cy - SLOT_HY, cy + SLOT_HY,
		THICK + SCREW_PROUD + 0.00002)


# --- Toggle --------------------------------------------------------------------

func _bake_toggle() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_sg = 0

	var rings: Array = []
	for lv: Array in BAT_LEVELS:
		rings.append(_ring_hs(float(lv[0]), float(lv[1]), float(lv[2]), BAT_CORNER_R))
	for i in range(rings.size() - 1):
		st.set_smooth_group(i)
		_loft(st, rings[i], rings[i + 1])

	st.set_smooth_group(100)
	_cap(st, rings[rings.size() - 1], Vector3(0.0, 0.0, BAT_TIP), true)
	st.set_smooth_group(101)
	_cap(st, rings[0], Vector3(0.0, 0.0, float(BAT_LEVELS[0][0])), false)

	st.generate_normals()
	# A shade lighter than the plate: the bat is the part a hand has polished.
	var mat := PlugMats.matte(Color(0.70, 0.68, 0.62), 0.62)
	st.set_material(mat)

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, mat)
	_report(TOGGLE_PATH, mesh)


# --- Rings ---------------------------------------------------------------------

## A rounded rectangle in the XY plane at depth `z`, extruding along +Z.
##
## Its winding is gen_rf_switch.gd's — which traces (cos a, level, -sin a) and lofts
## outward — turned by Rx(+90), i.e. (x, y, z) -> (x, -z, y), giving (cos a, sin a,
## level). A ROTATION, not an axis swap: swapping two axes would mirror it and bake
## every surface here inside out.
func _ring_hs(z: float, hx: float, hy: float, corner_r: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in _outline2(hx, hy, corner_r):
		out.append(Vector3(p.x, p.y, z))
	return out


## The plate's own outline, brought in by `inset` on every side.
func _ring_xy(z: float, inset: float, corner_r: float) -> PackedVector3Array:
	return _ring_hs(z, HX - inset, HY - inset, maxf(corner_r, 0.0005))


## A plain rectangle carrying the same vertex count as _ring_xy, so the two can be
## lofted into an annulus. Corner radius is nominal rather than zero: a zero radius
## collapses each corner's samples onto one point and generate_normals() then has to
## average four degenerate triangles into the corner it is trying to keep crisp.
func _rect_ring_xy(z: float, hx: float, hy: float) -> PackedVector3Array:
	return _ring_hs(z, hx, hy, 0.0008)


func _ring_circle(cx: float, cy: float, z: float, r: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in _outline2(r, r, r):
		out.append(Vector3(cx + p.x, cy + p.y, z))
	return out


## The shared 2D outline: a rounded rectangle sampled corner by corner, starting on
## the +X edge and turning toward +Y, with the last sample of each corner dropped
## because it is the first of the next.
func _outline2(hx: float, hy: float, corner_r: float) -> PackedVector2Array:
	var r: float = minf(corner_r, minf(hx, hy))
	var cx: float = hx - r
	var cy: float = hy - r
	var centres := [
		Vector2(cx, cy), Vector2(-cx, cy), Vector2(-cx, -cy), Vector2(cx, -cy),
	]
	var out := PackedVector2Array()
	for k in 4:
		var c: Vector2 = centres[k]
		for s in range(CORNER_SEG):
			var a: float = deg_to_rad(float(k) * 90.0 + float(s) * 90.0 / float(CORNER_SEG))
			out.append(Vector2(c.x + cos(a) * r, c.y + sin(a) * r))
	return out


# --- Loft primitives -----------------------------------------------------------

## Wall band between two rings, facing outward.
func _loft(st: SurfaceTool, lo: PackedVector3Array, hi: PackedVector3Array) -> void:
	var n := lo.size()
	for j in n:
		var j1 := (j + 1) % n
		st.add_vertex(lo[j]); st.add_vertex(hi[j]); st.add_vertex(hi[j1])
		st.add_vertex(lo[j]); st.add_vertex(hi[j1]); st.add_vertex(lo[j1])


## _loft with its own smooth group, for the plate's stack of bands.
func _band(st: SurfaceTool, lo: PackedVector3Array, hi: PackedVector3Array) -> void:
	st.set_smooth_group(_sg)
	_sg += 1
	_loft(st, lo, hi)


## Close a ring onto a point. `up` caps toward the ring's own outward end.
func _cap(st: SurfaceTool, ring: PackedVector3Array, centre: Vector3, up: bool) -> void:
	var n := ring.size()
	for j in n:
		var j1 := (j + 1) % n
		if up:
			st.add_vertex(ring[j]); st.add_vertex(centre); st.add_vertex(ring[j1])
		else:
			st.add_vertex(centre); st.add_vertex(ring[j]); st.add_vertex(ring[j1])


## Flat ring between an outer and an inner outline of equal vertex count. Degenerates
## to _cap when the inner collapses to a point, which is where its winding comes from.
func _annulus(st: SurfaceTool, outer: PackedVector3Array, inner: PackedVector3Array) -> void:
	var n := outer.size()
	for j in n:
		var j1 := (j + 1) % n
		st.add_vertex(outer[j]); st.add_vertex(inner[j]); st.add_vertex(outer[j1])
		st.add_vertex(inner[j]); st.add_vertex(inner[j1]); st.add_vertex(outer[j1])


## Axis-aligned rectangle facing +Z. Clockwise seen from +Z, per the header.
func _quad_pz(st: SurfaceTool, x0: float, x1: float, y0: float, y1: float, z: float) -> void:
	var a := Vector3(x0, y0, z)
	var b := Vector3(x0, y1, z)
	var c := Vector3(x1, y1, z)
	var d := Vector3(x1, y0, z)
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)


## Free quad, wound a-b-c-d.
func _quad_wall(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)


func _report(path: String, mesh: ArrayMesh) -> void:
	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	var tris := 0
	for s in mesh.get_surface_count():
		tris += mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX].size() / 3
	print("[gen] %s err=%d  %.4f x %.4f x %.4f m  surfaces %d  tris %d" % [
		path, err, ab.size.x, ab.size.y, ab.size.z, mesh.get_surface_count(), tris])

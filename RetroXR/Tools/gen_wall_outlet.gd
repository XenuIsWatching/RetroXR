## Bakes the 90s bedroom's grounded US duplex receptacle.
##
##   godot --headless --path RetroXR --script res://Tools/gen_wall_outlet.gd
##
## Like gen_light_switch.gd, the mesh is authored at real scale with +X across the
## wall, +Y up, and +Z out of the wall.  It deliberately shares the switch's warm,
## dry ivory thermoset palette rather than using a glossy generic plastic.
extends SceneTree

const PlugMats := preload("res://Tools/plug_materials.gd")
const OUT_PATH := "res://Scenes/Objects/room/wall_outlet_duplex.res"

const HX := 0.0350              # 70 x 114 mm single-gang cover
const HY := 0.0570
const THICK := 0.0070
const BEVEL := 0.0030
const CORNER_R := 0.0060
const SEG := 6


func _init() -> void:
	var ivory := SurfaceTool.new()
	ivory.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dark := SurfaceTool.new()
	dark.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Rounded cover: vertical side, broad bevel, then the flat face.
	var back := _rounded_rect(HX, HY, CORNER_R, 0.0)
	var shoulder := _rounded_rect(HX, HY, CORNER_R, THICK - BEVEL)
	var face := _rounded_rect(HX - BEVEL, HY - BEVEL, CORNER_R - BEVEL, THICK)
	_loft(ivory, back, shoulder, 0)
	_loft(ivory, shoulder, face, 1)
	_cap(ivory, face, Vector3(0, 0, THICK), true, 2)

	# Two slightly proud receptacle islands. Their oval silhouette and shallow
	# shoulder catch light without making the assembly look like three stacked toys.
	for cy in [-0.022, 0.022]:
		var island0 := _ellipse(0.0142, 0.0170, cy, THICK + 0.00015)
		var island1 := _ellipse(0.0134, 0.0162, cy, THICK + 0.00155)
		_loft(ivory, island0, island1, 10 + int(cy * 1000.0))
		_cap(ivory, island1, Vector3(0, cy, THICK + 0.00155), true, 20)

		# NEMA 5-15: the neutral slot is visibly wider, and the ground opening sits
		# below. Dark shallow inserts read as openings even against the wall behind.
		_slot(dark, -0.0068, cy + 0.0040, 0.00155, 0.0057, THICK + 0.00162)
		_slot(dark,  0.0068, cy + 0.0040, 0.00115, 0.0057, THICK + 0.00162)
		_ground(dark, cy - 0.0082, THICK + 0.00163)

	# One slotted screw between the two receptacles.
	var screw0 := _circle(0.0032, 0.0, THICK + 0.0002)
	var screw1 := _circle(0.0028, 0.0, THICK + 0.00085)
	_loft(ivory, screw0, screw1, 30)
	_cap(ivory, screw1, Vector3(0, 0, THICK + 0.00085), true, 31)
	_quad(dark, -0.00235, 0.00235, -0.00042, 0.00042, THICK + 0.00090)

	ivory.generate_normals()
	dark.generate_normals()
	var mat_ivory := PlugMats.matte(Color(0.62, 0.60, 0.55), 0.80)
	var mat_dark := PlugMats.matte(Color(0.075, 0.070, 0.064), 0.94)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ivory.commit_to_arrays())
	mesh.surface_set_material(0, mat_ivory)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, dark.commit_to_arrays())
	mesh.surface_set_material(1, mat_dark)
	var err := ResourceSaver.save(mesh, OUT_PATH)
	print("[gen] %s err=%d  size=%s  tris=%d" % [OUT_PATH, err, mesh.get_aabb().size,
		mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() / 3 +
		mesh.surface_get_arrays(1)[Mesh.ARRAY_VERTEX].size() / 3])
	quit(err)


func _outline(hx: float, hy: float, radius: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var r := minf(radius, minf(hx, hy))
	var centres := [Vector2(hx-r, hy-r), Vector2(-hx+r, hy-r),
		Vector2(-hx+r, -hy+r), Vector2(hx-r, -hy+r)]
	for corner in 4:
		for sample in SEG:
			var a := deg_to_rad(float(corner) * 90.0 + float(sample) * 90.0 / SEG)
			out.append(centres[corner] + Vector2(cos(a), sin(a)) * r)
	return out


func _rounded_rect(hx: float, hy: float, radius: float, z: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in _outline(hx, hy, radius): out.append(Vector3(p.x, p.y, z))
	return out


func _ellipse(rx: float, ry: float, cy: float, z: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in 32:
		var a := TAU * float(i) / 32.0
		out.append(Vector3(cos(a) * rx, cy + sin(a) * ry, z))
	return out


func _circle(r: float, cy: float, z: float) -> PackedVector3Array:
	return _ellipse(r, r, cy, z)


func _loft(st: SurfaceTool, lo: PackedVector3Array, hi: PackedVector3Array, group: int) -> void:
	st.set_smooth_group(group)
	for i in lo.size():
		var j := (i + 1) % lo.size()
		st.add_vertex(lo[i]); st.add_vertex(hi[i]); st.add_vertex(hi[j])
		st.add_vertex(lo[i]); st.add_vertex(hi[j]); st.add_vertex(lo[j])


func _cap(st: SurfaceTool, ring: PackedVector3Array, centre: Vector3, front: bool, group: int) -> void:
	st.set_smooth_group(group)
	for i in ring.size():
		var j := (i + 1) % ring.size()
		if front:
			st.add_vertex(ring[i]); st.add_vertex(centre); st.add_vertex(ring[j])
		else:
			st.add_vertex(centre); st.add_vertex(ring[i]); st.add_vertex(ring[j])


func _slot(st: SurfaceTool, cx: float, cy: float, hx: float, hy: float, z: float) -> void:
	# Rounded vertical slot, represented by a 12-sided capsule on the front plane.
	var ring := PackedVector3Array()
	for i in 7:
		var a := PI * float(i) / 6.0
		ring.append(Vector3(cx + cos(a) * hx, cy + hy - hx + sin(a) * hx, z))
	for i in 7:
		var a := PI + PI * float(i) / 6.0
		ring.append(Vector3(cx + cos(a) * hx, cy - hy + hx + sin(a) * hx, z))
	_cap(st, ring, Vector3(cx, cy, z), true, 100)


func _ground(st: SurfaceTool, cy: float, z: float) -> void:
	# The characteristic ground opening: round crown with a short, narrower stem.
	var r := 0.00315
	var ring := _circle(r, cy + 0.0010, z)
	_cap(st, ring, Vector3(0, cy + 0.0010, z), true, 101)
	_quad(st, -0.00215, 0.00215, cy - 0.0028, cy + 0.0010, z)


func _quad(st: SurfaceTool, x0: float, x1: float, y0: float, y1: float, z: float) -> void:
	var a := Vector3(x0,y0,z); var b := Vector3(x0,y1,z)
	var c := Vector3(x1,y1,z); var d := Vector3(x1,y0,z)
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)

## Bakes the plain CRT monitor's tapered tube hood to
## Scenes/Objects/tv_models/crt_hood.res.
##
## Run once, out of band:
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_crt_hood.gd
##
## A rectangular frustum: square front face meeting the cabinet, square back cap,
## four flat side walls. Axis along Z with the WIDE end at +Z, centred on its own
## origin, so crt_plain.tscn places it with a translation and no basis at all.
##
## Baked rather than a CylinderMesh(radial_segments = 4), which is the obvious way
## to get a tapered square out of a primitive and does not survive contact with a
## light. That mesh carries RADIAL normals — its four side vertices sit on the
## diamond's corners with normals pointing (0,·,1), (1,·,0), (0,·,-1), (-1,·,0) —
## so each face Gouraud-interpolates between two normals ninety degrees apart. The
## walls shade as curves and the corners round off, which is the opposite of the
## faceted read this cabinet wants. Flat per-face normals need unshared vertices,
## and no primitive offers those.
extends SceneTree

const OUT_PATH := "res://Scenes/Objects/tv_models/crt_hood.res"

# Front half-extent matches the cabinet it butts against: a 0.355 case.
const HALF_FRONT := 0.1775
# Back cap, a 0.20 x 0.20 panel — enough to carry the DE-15's 30.8 mm flange with
# room around it, and narrow enough that the taper reads from across the room.
const HALF_BACK := 0.10
# Half the run from the case's rear face to the back cap.
const HALF_LEN := 0.1075


func _initialize() -> void:
	var f := HALF_FRONT
	var b := HALF_BACK
	var l := HALF_LEN

	# Front ring (+Z) then back ring (-Z), both wound anticlockwise seen from +Z.
	var front := [
		Vector3(-f, -f, l), Vector3(f, -f, l), Vector3(f, f, l), Vector3(-f, f, l),
	]
	var back := [
		Vector3(-b, -b, -l), Vector3(b, -b, -l), Vector3(b, b, -l), Vector3(-b, b, -l),
	]

	# Six quads, each with its own four vertices so every face gets one flat normal.
	var quads: Array = []
	for i in range(4):
		var j := (i + 1) % 4
		quads.append([front[i], front[j], back[j], back[i]])
	quads.append([front[3], front[2], front[1], front[0]])   # front cap, facing +Z
	quads.append([back[0], back[1], back[2], back[3]])       # back cap, facing -Z

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	for q: Array in quads:
		var a: Vector3 = q[0]
		var c: Vector3 = q[1]
		var d: Vector3 = q[2]
		# Computed rather than written down: the side walls are planes of the form
		# x = f(z), and hand-deriving four of those is four chances to flip a sign.
		#
		# (d-a) x (c-a), not the other way about. The quads are wound the way
		# QuadMesh winds its own — TL, TR, BR, BL with the face pointing +Z, the
		# order gen_curved_screen.gd matches — and for that order the plain cross
		# product yields the INWARD normal. Taking it turned every face inside out:
		# six flat normals, all six negated.
		var n := (d - a).cross(c - a).normalized()
		var base := verts.size()
		for k in range(4):
			verts.push_back(q[k])
			normals.push_back(n)
		uvs.append_array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.resource_name = "CrtHood"

	var err := ResourceSaver.save(mesh, OUT_PATH)
	if err != OK:
		printerr("[gen_crt_hood] save failed: %d" % err)
	else:
		print("[gen_crt_hood] wrote %s (%d verts, %d tris, %.0f -> %.0f mm over %.0f mm)" % [
			OUT_PATH, verts.size(), indices.size() / 3,
			f * 2000.0, b * 2000.0, l * 2000.0])
	quit()

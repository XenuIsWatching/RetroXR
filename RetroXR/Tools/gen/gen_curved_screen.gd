## Bakes the RetroTV's curved tube face to Scenes/Objects/tv_models/tv_screen_curved.res.
##
## Run once, out of band — the sagitta is a physical property of the tube, not
## something to re-solve every load:
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_curved_screen.gd
##
## Replaces the flat QuadMesh(0.35, 0.25) that used to be the TV screen. The tube
## look needs real curvature rather than the UV barrel warp it had, because a UV
## warp is monoscopic: it has no parallax and no binocular depth, so in a headset
## it reads as a flat sticker the moment you move your head.
##
## Baking the curve into the mesh (rather than bulging it in a vertex shader) means
## EVERY material sits on the same surface — the dark/blue "no signal"
## StandardMaterial3Ds, the emission material the C++ VideoHandler re-asserts, and
## the CRT shader. A vertex-shader bulge would have to be duplicated into all three
## shaders and would still leave the tube flat whenever the TV is off.
extends SceneTree

const OUT_PATH := "res://Scenes/Objects/tv_models/tv_screen_curved.res"

# Matches the QuadMesh this replaces.
const SIZE := Vector2(0.35, 0.25)
const SEGMENTS := 24

# Bulge toward the viewer at the centre, in metres. Parabolic rather than
# spherical: indistinguishable at this sagitta and free of sqrt domain issues.
#
# The hard constraint is the BEZEL, not realism. The TV body is a BoxMesh whose
# front face is at z = 0.15 and the screen node sits at 0.151, so the glass RIM
# has to stay at the node's own plane — the whole bulge protrudes forward from
# there. An earlier 10/6 mm pair (16 mm at the centre) was recessed to keep the
# centre flush, which buried the rim inside the box and left only the tip of the
# parabola poking out: the screen rendered as an ellipse.
#
# 9 mm total still reads clearly as depth in a headset — at 0.6 m it is about
# 9 arcmin of binocular disparity between centre and edge, ~4 Quest 3 pixels —
# while protruding little enough to look like glass in a bezel.
const SAGITTA_X := 0.006
const SAGITTA_Y := 0.003


func _initialize() -> void:
	var hw := SIZE.x * 0.5
	var hh := SIZE.y * 0.5

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	for r in range(SEGMENTS + 1):
		for c in range(SEGMENTS + 1):
			var u := float(c) / float(SEGMENTS)
			var v := float(r) / float(SEGMENTS)
			# QuadMesh maps UV (0,0) to the top-left vertex (-hw, +hh) and (1,1)
			# to the bottom-right, so UV.y runs opposite to world Y.
			var x := (u - 0.5) * SIZE.x
			var y := (0.5 - v) * SIZE.y
			var nx := x / hw
			var ny := y / hh
			var z := SAGITTA_X * (1.0 - nx * nx) + SAGITTA_Y * (1.0 - ny * ny)

			verts.push_back(Vector3(x, y, z))
			uvs.push_back(Vector2(u, v))

			# Surface z = f(x, y) has normal (-df/dx, -df/dy, 1).
			var dzdx := -2.0 * SAGITTA_X * x / (hw * hw)
			var dzdy := -2.0 * SAGITTA_Y * y / (hh * hh)
			normals.push_back(Vector3(-dzdx, -dzdy, 1.0).normalized())

			var tan := Vector3(1.0, 0.0, dzdx).normalized()
			tangents.append_array([tan.x, tan.y, tan.z, 1.0])

	# Same winding as QuadMesh's 0,1,2 / 0,2,3 over (top-left, top-right,
	# bottom-right, bottom-left).
	var stride := SEGMENTS + 1
	for r in range(SEGMENTS):
		for c in range(SEGMENTS):
			var tl := r * stride + c
			var tr := tl + 1
			var br := tl + stride + 1
			var bl := tl + stride
			indices.append_array([tl, tr, br, tl, br, bl])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.resource_name = "TVScreenCurved"

	var err := ResourceSaver.save(mesh, OUT_PATH)
	if err != OK:
		printerr("[gen_curved_screen] save failed: %d" % err)
	else:
		print("[gen_curved_screen] wrote %s (%d verts, %d tris, bulge %.1f/%.1f mm)" % [
			OUT_PATH, verts.size(), indices.size() / 3,
			SAGITTA_X * 1000.0, SAGITTA_Y * 1000.0])
	quit()

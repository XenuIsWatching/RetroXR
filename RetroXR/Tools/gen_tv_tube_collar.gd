## Generates the shallow rounded collar that sits behind the live curved tube.
## Run from the project root:
##   godot --headless --path RetroXR --script res://Tools/gen_tv_tube_collar.gd
extends SceneTree

const OUT_PATH := "res://Scenes/Objects/tv_models/tv_tube_collar.res"
const CORNER_STEPS := 8
const OUTER_HALF := Vector2(0.185, 0.135)
const INNER_HALF := Vector2(0.173, 0.123)
const OUTER_RADIUS := 0.026
const INNER_RADIUS := 0.020
const FRONT_Z := 0.003
const INNER_Z := 0.001
const BACK_Z := -0.005


func _initialize() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var outer := _rounded_loop(OUTER_HALF, OUTER_RADIUS)
	var inner := _rounded_loop(INNER_HALF, INNER_RADIUS)
	for i: int in outer.size():
		var j := (i + 1) % outer.size()
		# Front annulus.
		_quad(st,
			Vector3(outer[i].x, outer[i].y, FRONT_Z),
			Vector3(outer[j].x, outer[j].y, FRONT_Z),
			Vector3(inner[j].x, inner[j].y, INNER_Z),
			Vector3(inner[i].x, inner[i].y, INNER_Z))
		# Inner wall: the visible dark thickness down to the tube seat.
		_quad(st,
			Vector3(inner[i].x, inner[i].y, INNER_Z),
			Vector3(inner[j].x, inner[j].y, INNER_Z),
			Vector3(inner[j].x, inner[j].y, BACK_Z),
			Vector3(inner[i].x, inner[i].y, BACK_Z))
	st.generate_normals()
	var mesh := st.commit()
	var error := ResourceSaver.save(mesh, OUT_PATH)
	if error != OK:
		printerr("[gen_tv_tube_collar] save failed: %d" % error)
		quit(1)
		return
	print("[gen_tv_tube_collar] wrote %s (%d vertices)" % [OUT_PATH, outer.size() * 12])
	quit(0)


func _rounded_loop(half_size: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var centres := [
		Vector2(half_size.x - radius, half_size.y - radius),
		Vector2(-half_size.x + radius, half_size.y - radius),
		Vector2(-half_size.x + radius, -half_size.y + radius),
		Vector2(half_size.x - radius, -half_size.y + radius),
	]
	var starts := [0.0, 90.0, 180.0, 270.0]
	for corner: int in 4:
		for step: int in CORNER_STEPS:
			var a := deg_to_rad(starts[corner] + float(step) * 90.0 / float(CORNER_STEPS))
			points.append(centres[corner] + Vector2(cos(a), sin(a)) * radius)
	return points


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.set_uv(Vector2(0.0, 0.0)); st.add_vertex(a)
	st.set_uv(Vector2(1.0, 0.0)); st.add_vertex(b)
	st.set_uv(Vector2(1.0, 1.0)); st.add_vertex(c)
	st.set_uv(Vector2(0.0, 0.0)); st.add_vertex(a)
	st.set_uv(Vector2(1.0, 1.0)); st.add_vertex(c)
	st.set_uv(Vector2(0.0, 1.0)); st.add_vertex(d)

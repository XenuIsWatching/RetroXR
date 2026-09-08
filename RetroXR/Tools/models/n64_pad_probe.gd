## Renders the N64 controller shell from named directions, so a facing question is
## settled by looking rather than by reasoning about axis signs -- which is the
## mistake this project has made twice on port and socket orientation.
##
## Windowed, NOT --headless: the dummy renderer hands back a correctly sized frame
## with nothing drawn into it, which passes a size check and shows a blank image.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/models/n64_pad_probe.gd_scene -- --out=res://probe_out
extends Node

const GLB := "res://imported-assets/controllers/n64/n64_controller.glb"
const SHOT := Vector2i(900, 900)

## Each view is a camera direction plus an up hint, named for what a person
## would call that side of a controller lying face-up on a table.
const VIEWS: Array = [
	# up = -Z on the top view, NOT +Z. With +Z the camera's right axis comes out
	# along -X and the render is mirrored: the D-pad, which is on the pad's left,
	# appears on the right and every moulded label reads backwards. A mirrored
	# render is worse than no render -- it is exactly how a facing gets authored
	# inside out while a picture appears to confirm it.
	{"name": "top",    "dir": Vector3(0, 1, 0),    "up": Vector3(0, 0, -1)},
	{"name": "bottom", "dir": Vector3(0, -1, 0),   "up": Vector3(0, 0, -1)},
	{"name": "minus_z", "dir": Vector3(0, 0.25, -1), "up": Vector3(0, 1, 0)},
	{"name": "plus_z",  "dir": Vector3(0, 0.25, 1),  "up": Vector3(0, 1, 0)},
	{"name": "plus_x",  "dir": Vector3(1, 0.25, 0),  "up": Vector3(0, 1, 0)},
	{"name": "three_quarter", "dir": Vector3(0.6, 0.8, 0.7), "up": Vector3(0, 1, 0)},
]


func _ready() -> void:
	var out := "res://probe_out"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	await _run(out)
	get_tree().quit(0)


func _run(out: String) -> void:
	var packed: PackedScene = load(GLB)
	if packed == null:
		push_error("[n64probe] could not load " + GLB)
		return

	var sv := SubViewport.new()
	sv.size = SHOT
	sv.own_world_3d = true
	sv.transparent_bg = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.18, 0.19, 0.22)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.57, 0.62)
	e.ambient_light_energy = 1.0
	env.environment = e
	sv.add_child(env)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-50, -35, 0)
	key.light_energy = 1.6
	sv.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15, 140, 0)
	fill.light_energy = 0.7
	sv.add_child(fill)

	var model: Node3D = packed.instantiate()
	sv.add_child(model)

	# Frame from the model's own bounds rather than a hardcoded distance, so this
	# keeps working if the asset is rebuilt at a different scale.
	var aabb := _aabb(model)
	print("[n64probe] aabb pos=%v size=%v centre=%v" % [aabb.position, aabb.size, aabb.get_center()])
	for child in model.get_children():
		if child is Node3D:
			print("[n64probe] node %s at %v" % [child.name, (child as Node3D).position])

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z)) * 1.15
	cam.near = 0.001
	cam.far = 10.0
	sv.add_child(cam)
	cam.current = true          # make_current() does not work inside a SubViewport

	for v: Dictionary in VIEWS:
		var dir: Vector3 = (v["dir"] as Vector3).normalized()
		cam.position = aabb.get_center() + dir * 1.0
		cam.look_at(aabb.get_center(), v["up"])
		for i in range(6):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		await get_tree().process_frame
		var img := sv.get_texture().get_image()
		# The core's frames carry an unfilled alpha channel; flatten so the PNG is
		# not written fully transparent (13 KB of picture every viewer paints white).
		img.convert(Image.FORMAT_RGB8)
		var path: String = "%s/n64_%s.png" % [out, v["name"]]
		img.save_png(path)
		print("[n64probe] wrote %s" % path)


func _aabb(root: Node) -> AABB:
	var box := AABB()
	var first := true
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var b: AABB = mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box

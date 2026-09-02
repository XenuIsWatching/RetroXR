extends Node3D
## Close-up renders of the connector family, for eyeballing a material change.
##
## Windowed, not --headless (the dummy renderer returns blank). PNGs land in
## res://probe_out/connector_<name>.png. The SubViewport shares this scene's
## world rather than owning one, because a cable parents its rope to the
## current scene and an own_world_3d viewport would render every lead away.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##     res://Tools/perf/connector_shot.tscn -- --tag=before

const SIZE := Vector2i(900, 700)

var _tag := "shot"


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void: get_tree().quit(3))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tag="):
			_tag = arg.trim_prefix("--tag=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://probe_out"))

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.18, 0.19, 0.22)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.5, 0.52)
	env.environment.ambient_light_energy = 0.6
	add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40, 35, 0)
	key.light_energy = 1.4
	add_child(key)
	var fill := OmniLight3D.new()
	fill.position = Vector3(0.3, 0.6, 0.8)
	fill.light_energy = 1.2
	fill.omni_range = 4.0
	add_child(fill)

	var tv: Node3D = (load("res://Scenes/Objects/tv.tscn") as PackedScene).instantiate()
	tv.position = Vector3(0, 0, 0)
	add_child(tv)
	var cable: Node3D = (load("res://Scenes/Objects/cables/composite_cable.tscn") as PackedScene).instantiate()
	cable.position = Vector3(1.5, 0.3, 0)
	add_child(cable)
	var psx: Node3D = (load("res://Scenes/Objects/system.tscn") as PackedScene).instantiate()
	psx.set("systemid", "playstation")
	psx.position = Vector3(-1.5, 0.2, 0)
	add_child(psx)

	# No floor here, so every body would be in free fall by the time the camera
	# arrives. Freeze them where they spawned.
	for i in 4:
		await get_tree().process_frame
	for body: Node in find_children("*", "RigidBody3D", true, false):
		(body as RigidBody3D).freeze = true

	var sv := SubViewport.new()
	sv.size = SIZE
	sv.own_world_3d = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var cam := Camera3D.new()
	cam.fov = 30.0
	cam.near = 0.005
	sv.add_child(cam)
	cam.current = true
	for i in 20:
		await get_tree().process_frame

	await _shoot(sv, cam, "tv_jacks", tv.get_node_or_null("AudioLIn"), 0.11, Vector3(0.02, 0.03, 0))
	await _shoot(sv, cam, "plug", cable.get_node_or_null("PlugA0/PlugTip"), 0.07, Vector3(0.02, 0.025, 0))
	await _shoot(sv, cam, "psx_jacks", psx.get_node_or_null("AudioLOut"), 0.09, Vector3(0.02, 0.03, 0))
	print("[shot] done")
	get_tree().quit(0)


## Look at `target` from `dist` along its local +Z (a port's socket-facing
## axis), nudged sideways so the neighbouring jacks are in frame too.
func _shoot(sv: SubViewport, cam: Camera3D, name: String, target: Node3D, dist: float, side: Vector3) -> void:
	if target == null:
		print("[shot] %s: no target" % name)
		return
	var at: Vector3 = target.global_position
	var out: Vector3 = target.global_transform.basis.z.normalized()
	print("[shot] %s target at %s +Z %s visible=%s" % [name, at, out, target.is_visible_in_tree()])
	cam.global_position = at + out * dist + side
	cam.look_at(at, Vector3.UP)
	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	var path := "res://probe_out/connector_%s_%s.png" % [name, _tag]
	sv.get_texture().get_image().save_png(path)
	print("[shot] %s" % path)

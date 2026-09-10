extends Node

## VMU model probe -- render the card's face and back so the model can be judged.
##
## Wants no core and no ROM, unlike Tools/cores/vmu_screen_probe, so it is the
## cheap way to look at the geometry after touching it. The face layout was taken
## from a photograph of the real unit; this is how it was checked against one.
##
##     "$godot" --path RetroXR --resolution 320x240 --position 20,20 ##         res://Tools/models/vmu_model_probe.tscn
##
## Windowed, never headless: the dummy renderer returns a blank image.

const OUT := "res://probe_out/vmu_model.png"


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(960, 640)
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.15, 0.16, 0.19)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.48, 0.50, 0.56)
	e.ambient_light_energy = 0.4
	env.environment = e
	sv.add_child(env)

	var key := DirectionalLight3D.new()
	key.light_energy = 0.85
	key.rotation_degrees = Vector3(-40, -28, 0)
	sv.add_child(key)

	var fill := OmniLight3D.new()
	fill.light_energy = 0.55
	fill.omni_range = 2.0
	fill.position = Vector3(-0.22, 0.10, 0.28)
	sv.add_child(fill)

	var scn: PackedScene = load("res://Scenes/Objects/controllers/dreamcast/vmu_card.tscn")
	# Face on, and turned to show the back with its name.
	var front: Node3D = scn.instantiate()
	front.position = Vector3(-0.040, 0, 0)
	front.rotation_degrees = Vector3(0, -8, 0)
	sv.add_child(front)

	var back: Node3D = scn.instantiate()
	back.position = Vector3(0.052, 0, 0)
	back.rotation_degrees = Vector3(0, 200, 0)
	sv.add_child(back)

	# Freeze, or they fall out of frame before the readback -- RigidBody3Ds with
	# no floor under them.
	for b in [front, back]:
		if b is RigidBody3D:
			(b as RigidBody3D).freeze = true

	var cam := Camera3D.new()
	cam.position = Vector3(0.004, 0.0, 0.235)
	cam.fov = 36
	sv.add_child(cam)
	cam.current = true

	for i in range(10):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://probe_out"))
	var img := sv.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	print("[probe] saved %s err=%d" % [OUT, img.save_png(OUT)])
	get_tree().quit(0)

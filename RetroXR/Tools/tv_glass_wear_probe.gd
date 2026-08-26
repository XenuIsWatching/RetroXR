## Captures the TV glass active and powered off at clean/default/heavy wear.
##
##   godot --path RetroXR --resolution 960x720 \
##     res://Tools/tv_glass_wear_probe.tscn
##
## Windowed: the dummy headless renderer does not produce useful material shots.
## Images land in res://probe_out/ and are intentionally gitignored.
extends Node3D

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")
const LEVELS := [0.0, 0.35, 1.0]

var _viewport: SubViewport
var _tv: RetroTV


class StubSource extends Node3D:
	var texture: Texture2D

	func get_video_texture() -> Texture2D:
		return texture

	func set_audio_volume(_value: float) -> void:
		pass


func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		printerr("[glass-wear] TIMEOUT")
		get_tree().quit(1))
	_run()


func _run() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(960, 720)
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_4X
	add_child(_viewport)

	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.02, 0.035)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.28, 0.34, 0.48)
	env.ambient_light_energy = 0.42
	world_env.environment = env
	_viewport.add_child(world_env)

	# A broad cool key and warm edge light make the varying glass roughness and
	# clearcoat legible without painting illumination into the wear texture.
	var key := OmniLight3D.new()
	key.position = Vector3(-0.25, 1.32, 0.52)
	key.light_color = Color(0.58, 0.72, 1.0)
	key.light_energy = 6.0
	key.omni_range = 2.0
	key.shadow_enabled = true
	_viewport.add_child(key)
	var rim := OmniLight3D.new()
	rim.position = Vector3(0.55, 0.92, 0.15)
	rim.light_color = Color(1.0, 0.58, 0.32)
	rim.light_energy = 3.0
	rim.omni_range = 1.5
	_viewport.add_child(rim)

	_tv = TV_SCENE.instantiate() as RetroTV
	_tv.position = Vector3(0.0, 1.0, 0.0)
	_tv.freeze = true
	_viewport.add_child(_tv)
	await _wait(40)

	var camera := Camera3D.new()
	camera.position = Vector3(0.34, 1.07, 0.92)
	camera.fov = 32.0
	_viewport.add_child(camera)
	camera.look_at(Vector3(0.0, 1.02, 0.0), Vector3.UP)
	camera.current = true

	var source := StubSource.new()
	source.texture = _test_picture()
	_viewport.add_child(source)
	_tv._connected_systems[RetroTV.Source.COMPOSITE_1] = source
	_tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(12)

	DirAccess.make_dir_recursive_absolute("res://probe_out")
	for level: float in LEVELS:
		_tv.set_crt_param("crt_glass_wear", level)
		await _wait(8)
		await _capture("active", level)
		_tv.remote_power_toggle()
		await _wait(8)
		await _capture("off", level)
		_tv.remote_power_toggle()
		await _wait(8)
	print("[glass-wear] captured 6 validation images")
	get_tree().quit(0)


func _test_picture() -> Texture2D:
	var image := Image.create(512, 384, false, Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var uv := Vector2(float(x) / 511.0, float(y) / 383.0)
			var sky := Color(0.025, 0.06, 0.13).lerp(Color(0.18, 0.42, 0.68), uv.y)
			var grid := 0.15 if (x % 64 < 2 or y % 48 < 2) else 0.0
			var glow := maxf(0.0, 1.0 - uv.distance_to(Vector2(0.70, 0.35)) * 5.5)
			image.set_pixel(x, y, sky + Color(grid, grid * 0.7, grid * 0.25)
				+ Color(0.8, 0.28, 0.08) * glow)
	return ImageTexture.create_from_image(image)


func _capture(state: String, level: float) -> void:
	_tv.hide_osd()
	await _wait(2)
	await RenderingServer.frame_post_draw
	var label := "%03d" % int(round(level * 100.0))
	var path := "res://probe_out/tv_glass_wear_%s_%s.png" % [state, label]
	var error := _viewport.get_texture().get_image().save_png(path)
	if error != OK:
		printerr("[glass-wear] could not save %s: %s" % [path, error])
		get_tree().quit(1)
	print("[glass-wear] %s" % path)


func _wait(frames: int) -> void:
	for _frame in frames:
		await get_tree().process_frame

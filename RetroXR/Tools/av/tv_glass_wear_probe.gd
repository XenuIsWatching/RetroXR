## Captures glass wear, reflection rotation, and CRT character on both retained
## primitive cabinets, active and powered off.
##
##   godot --path RetroXR --resolution 960x720 \
##     res://Tools/av/tv_glass_wear_probe.tscn
##
## Windowed: the dummy headless renderer does not produce useful material shots.
## Images land beside the project in build_out/tv_probe/. Keeping render targets
## outside res:// prevents the editor from hot-importing one PNG while the next
## validation frame is being drawn.
extends Node3D

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")
const WEAR_LEVELS := [0.0, 0.35, 1.0, 3.0]
const CHARACTER_LEVELS := [0.0, 0.35, 1.0]
const ROTATION_ANGLES := [-30.0, -15.0, 0.0, 15.0, 30.0]
const OUTPUT_DIR := "res://../build_out/tv_probe"

var _viewport: SubViewport
var _tv: RetroTV
var _source: StubSource


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
	# The close screen/collar can shadow the entire flat primitive bezel at this
	# diagnostic angle. Room shadowing is not under test, so keep the material key
	# unoccluded and let the separate rotation sweep judge the glass response.
	key.shadow_enabled = false
	_viewport.add_child(key)
	var rim := OmniLight3D.new()
	rim.position = Vector3(0.55, 0.92, 0.15)
	rim.light_color = Color(1.0, 0.58, 0.32)
	rim.light_energy = 3.0
	rim.omni_range = 1.5
	_viewport.add_child(rim)
	# Constant neutral fill keeps the non-emissive cabinet readable after the TV's
	# own screen-cast light switches off. It is deliberately shadowless: these
	# captures judge materials, not room-light occlusion.
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-24.0, -18.0, 0.0)
	fill.light_color = Color(0.72, 0.76, 0.84)
	fill.light_energy = 0.7
	fill.shadow_enabled = false
	_viewport.add_child(fill)

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

	_source = StubSource.new()
	_source.texture = _test_picture()
	_viewport.add_child(_source)
	_tv._connected_systems[RetroTV.Source.COMPOSITE_1] = _source
	_tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(12)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	for level: float in WEAR_LEVELS:
		_tv.set_crt_param("crt_glass_wear", level)
		await _wait(8)
		await _capture("active", level)
		_tv.remote_power_toggle()
		await _wait(8)
		await _capture("off", level)
		_tv.remote_power_toggle()
		await _wait(8)
	await _capture_rotation_sweep()
	# Rotation sweep leaves the stock set off. Turn it back on for the character
	# matrix, then repeat that matrix on the only retained shell.
	_tv.remote_power_toggle()
	await _wait(8)
	await _capture_character_matrix("stock")
	await _replace_tv_with_plain_monitor()
	await _capture_character_matrix("plain")
	print("[glass-wear] captured 8 wear, 5 rotation and 12 character images")
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
	var path := "%s/tv_glass_wear_%s_%s.png" % [OUTPUT_DIR, state, label]
	var error := _viewport.get_texture().get_image().save_png(path)
	if error != OK:
		printerr("[glass-wear] could not save %s: %s" % [path, error])
		get_tree().quit(1)
	print("[glass-wear] %s" % path)


## With the camera and room lights fixed, turn the powered-off set itself. The
## fingerprints must stay on the glass while the sheen that reveals them travels.
func _capture_rotation_sweep() -> void:
	_tv.set_crt_param("crt_glass_wear", 3.0)
	_tv.remote_power_toggle()
	await _wait(8)
	_tv.hide_osd()
	for angle: float in ROTATION_ANGLES:
		_tv.rotation.y = deg_to_rad(angle)
		await _wait(8)
		await RenderingServer.frame_post_draw
		var label := "m%02d" % abs(int(angle)) if angle < 0.0 else "p%02d" % int(angle)
		var path := "%s/tv_glass_wear_rotate_%s.png" % [OUTPUT_DIR, label]
		var error := _viewport.get_texture().get_image().save_png(path)
		if error != OK:
			printerr("[glass-wear] could not save %s: %s" % [path, error])
			get_tree().quit(1)
		print("[glass-wear] %s" % path)
	_tv.rotation.y = 0.0


func _capture_character_matrix(model: String) -> void:
	_tv.set_crt_param("crt_glass_wear", 0.35)
	for level: float in CHARACTER_LEVELS:
		_tv.set_crt_param("crt_character", level)
		await _wait(8)
		await _capture_character(model, "active", level)
		_tv.remote_power_toggle()
		await _wait(16)
		await _capture_character(model, "off", level)
		_tv.remote_power_toggle()
		await _wait(8)


func _capture_character(model: String, state: String, level: float) -> void:
	_tv.hide_osd()
	# Repeated power/material switches rebuild clustered lights asynchronously on
	# the real renderers. Let that settle so the PNG records steady-state cabinet
	# lighting rather than an intermediate frame containing emissive glass alone.
	await _wait(30)
	await RenderingServer.frame_post_draw
	var label := "%03d" % int(round(level * 100.0))
	var path := "%s/tv_character_%s_%s_%s.png" % [OUTPUT_DIR, model, state, label]
	var error := _viewport.get_texture().get_image().save_png(path)
	if error != OK:
		printerr("[glass-wear] could not save %s: %s" % [path, error])
		get_tree().quit(1)
	print("[glass-wear] %s" % path)


func _replace_tv_with_plain_monitor() -> void:
	_viewport.remove_child(_tv)
	_tv.queue_free()
	await _wait(3)
	_tv = TV_SCENE.instantiate() as RetroTV
	_tv.tv_model = "crt_plain"
	_tv.position = Vector3(0.0, 1.0, 0.0)
	_tv.freeze = true
	_viewport.add_child(_tv)
	await _wait(40)
	_tv._connected_systems[RetroTV.Source.VGA] = _source
	_tv.set_source(RetroTV.Source.VGA)
	await _wait(12)


func _wait(frames: int) -> void:
	for _frame in frames:
		await get_tree().process_frame

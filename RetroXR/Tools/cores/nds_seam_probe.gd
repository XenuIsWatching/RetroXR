## Windowed GPU regression probe for a dual-screen framebuffer seam.
##
## The synthetic source is the DS's real 256x384 stacked layout: solid red top,
## solid blue bottom. It renders ONLY the bottom window, minified through the
## production screen_window shader, and rejects any blue output pixel carrying
## red. It checks both the handheld's plain LCD path and a television's CRT path.
##
## Run windowed (the headless renderer cannot execute the spatial shader):
##   godot --path RetroXR --resolution 160x120 res://Tools/cores/nds_seam_probe.tscn
extends Node

const OUTPUT := "res://probe_out/nds_seam.png"

var _viewport: SubViewport
var _material: ShaderMaterial


func _ready() -> void:
	get_tree().create_timer(15.0).timeout.connect(func() -> void:
		printerr("[probe] NDS seam render timed out")
		get_tree().quit(2)
	)
	RenderingServer.set_default_clear_color(Color.BLACK)
	_build_scene()

	_material.set_shader_parameter("crt_enabled", false)
	var plain: Dictionary = await _measure()
	print("[probe] NDS plain seam: %s (blue=%d red=%d)" % [
		"PASS" if plain["passed"] else "FAIL", plain["blue"], plain["red"]])

	_material.set_shader_parameter("crt_enabled", true)
	_material.set_shader_parameter("crt_halation", 1.0)
	_material.set_shader_parameter("crt_notch", 0.0)
	_material.set_shader_parameter("crt_mask_strength", 0.0)
	_material.set_shader_parameter("crt_scanline_strength", 0.0)
	var crt: Dictionary = await _measure()
	var rendered := _viewport.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://probe_out"))
	rendered.save_png(OUTPUT)
	print("[probe] NDS CRT seam: %s (blue=%d red=%d)" % [
		"PASS" if crt["passed"] else "FAIL", crt["blue"], crt["red"]])

	var passed := bool(plain["passed"]) and bool(crt["passed"])
	print("[probe] RESULT=%s image=%s" % ["PASS" if passed else "FAIL", OUTPUT])
	get_tree().quit(0 if passed else 1)


func _build_scene() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(160, 120)
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	add_child(_viewport)

	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 2.0)
	camera.fov = 42.0
	camera.current = true
	_viewport.add_child(camera)

	var source := Image.create(256, 384, false, Image.FORMAT_RGBA8)
	source.fill_rect(Rect2i(0, 0, 256, 192), Color.RED)
	source.fill_rect(Rect2i(0, 192, 256, 192), Color.BLUE)
	_material = ShaderMaterial.new()
	_material.shader = load("res://Shaders/screen_window.gdshader") as Shader
	_material.set_shader_parameter("source_tex", ImageTexture.create_from_image(source))
	_material.set_shader_parameter("source_rect", Vector4(0.0, 0.5, 1.0, 0.5))

	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.8, 0.6)
	quad.mesh = mesh
	quad.material_override = _material
	quad.rotation_degrees = Vector3(20.0, 25.0, 0.0)
	_viewport.add_child(quad)


func _measure() -> Dictionary:
	for _frame in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	var rendered := _viewport.get_texture().get_image()
	var red_pixels := 0
	var blue_pixels := 0
	for y in rendered.get_height():
		for x in rendered.get_width():
			var c := rendered.get_pixel(x, y)
			if c.b > 0.05:
				blue_pixels += 1
				if c.r > 0.001:
					red_pixels += 1
	return {
		"passed": blue_pixels > 500 and red_pixels == 0,
		"blue": blue_pixels,
		"red": red_pixels,
	}

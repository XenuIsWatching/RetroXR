extends Node

var _failed := 0
var _ran := 0


func _ready() -> void:
	var old_interval: int = QualityManager.screen_light_interval
	QualityManager.screen_light_interval = 1
	var light := ScreenCastLight.new()
	add_child(light)

	light.configure_screen(Vector2(0.35, 0.25))
	_close(light.light_energy, 0.0, "reference/remains off until a picture")
	light.show_solid(Color.BLUE)
	_close(_total_energy(light), 1.2, "reference/stock TV energy")
	_close(light.spot_range, 4.5, "reference/stock TV reach")

	light.configure_screen(Vector2(0.039496627, 0.036040675))
	_close(_total_energy(light), 0.1529, "sizing/Game Boy is much dimmer", 0.002)
	_close(light.spot_range, 0.5735, "sizing/Game Boy reach is local", 0.003)

	var image := Image.create(12, 8, false, Image.FORMAT_RGB8)
	image.fill(Color.RED)
	var texture := ImageTexture.create_from_image(image)
	var region := Rect2(0.0, 0.5, 1.0, 0.5)
	light.show_picture(texture, region)
	# The viewport's RenderingDevice RID is published on its first render frame.
	await get_tree().process_frame
	await get_tree().process_frame
	var left := light.get_node_or_null("LeftGlow") as SpotLight3D
	var right := light.get_node_or_null("RightGlow") as SpotLight3D
	_ok(left != null and right != null, "picture/creates world-space region lights")
	var viewport := light.get_node_or_null("GlowSampler") as SubViewport
	_ok(viewport != null, "picture/creates tiny viewport")
	if viewport != null:
		_ok(viewport.size == Vector2i(12, 8), "picture/viewport stays tiny")
		var rect := viewport.get_node_or_null("BlurredPicture") as ColorRect
		var packed: Variant = (rect.material as ShaderMaterial).get_shader_parameter("source_rect")
		_ok(packed == Vector4(0.0, 0.5, 1.0, 0.5), "picture/preserves composite region")

	if RenderingServer.get_rendering_device() != null:
		for y in image.get_height():
			for x in image.get_width():
				image.set_pixel(x, y, Color.RED if x < 4 else Color.GREEN if x < 8 else Color.BLUE)
		texture.update(image)
		for frame in 4:
			await get_tree().process_frame
		_ok(left.light_color.r > left.light_color.g, "updates/left follows new frame")
		_ok(light.light_color.g > light.light_color.r, "updates/centre follows new frame")
		_ok(right.light_color.b > right.light_color.r, "updates/right follows new frame")

	light.show_solid(Color.BLUE)
	_close(light.light_color.b, 1.0, "solid/uses requested colour")
	light.turn_off()
	_close(light.light_energy, 0.0, "off/disables output")
	QualityManager.screen_light_interval = old_interval

	print("[test] %d cases, %s" % [_ran,
		"PASS" if _failed == 0 else "%d FAILURE(S)" % _failed])
	get_tree().quit(0 if _failed == 0 else 1)


func _ok(ok: bool, label: String) -> void:
	_ran += 1
	if ok:
		print("[test] ok   %s" % label)
	else:
		_failed += 1
		print("[test] FAIL %s" % label)


func _close(actual: float, expected: float, label: String, tolerance := 0.0001) -> void:
	_ok(absf(actual - expected) <= tolerance,
		"%s (%.4f ~= %.4f)" % [label, actual, expected])


func _total_energy(light: ScreenCastLight) -> float:
	return light.light_energy \
		+ (light.get_node("LeftGlow") as SpotLight3D).light_energy \
		+ (light.get_node("RightGlow") as SpotLight3D).light_energy

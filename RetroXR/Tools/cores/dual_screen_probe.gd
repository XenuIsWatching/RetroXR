## Headless probe for dual-screen handheld models (NDS / 3DS): the composite
## UV windows fed to the two screen quads (via the screen_window shader's
## source_rect), top→bottom material mirroring off the hidden proxy, touch-poke →
## composite-framebuffer UV conversion (including the 3DS's inset bottom rect),
## and the clamshell lid sitting open.
##
## The models are now authored .tscn scenes (Scenes/Objects/system_models/); the
## root node carries the RetroSystemModelDualScreen script that wires behaviour.
##
## Run: godot --headless --path RetroXR res://Tools/cores/dual_screen_probe.tscn
extends Node3D

var _fail := false

## The machine's picture, which each model asks its parent for. The probe stands
## in for the RetroSystem here.
var picture: Texture2D = null


func get_video_texture() -> Texture2D:
	return picture


class StubHost extends Node3D:
	var touches: Array = []
	## The machine's picture, which the model now ASKS for rather than having it
	## painted onto a hidden proxy for it to read back.
	var picture: Texture2D = null
	func get_video_texture() -> Texture2D:
		return picture
	func feed_touch(uv: Vector2, pressed: bool) -> void:
		touches.append([uv, pressed])
	func set_audio_volume(_v: float) -> void:
		pass


func _fail_if(cond: bool, msg: String) -> void:
	if cond:
		_fail = true
		print("[probe] FAIL: %s" % msg)


## The composite UV window a screen samples, read back from its screen_window
## ShaderMaterial's source_rect (x, y, w, h).
func _window(mat: ShaderMaterial) -> Rect2:
	var r: Vector4 = mat.get_shader_parameter("source_rect")
	return Rect2(r.x, r.y, r.z, r.w)


## Look the model up by id and skip cleanly if this build has not got it.
func _check_id(model_id: String, top: Rect2, bottom: Rect2) -> void:
	if not SystemModelRegistry.is_available(model_id):
		print("[probe] %s not in this build — skipped" % model_id)
		return
	await _check_model(SystemModelRegistry.resolve(model_id, "").get("scene", ""), top, bottom)


func _check_model(path: String, want_top: Rect2, want_bottom: Rect2) -> void:
	var nm := path.get_file()
	var model: RetroSystemModelDualScreen = (load(path) as PackedScene).instantiate()
	add_child(model)
	# _ready builds the window materials before its first await, but give it a
	# frame so authored control scripts settle.
	await get_tree().process_frame

	_fail_if(not model.is_handheld(), "%s not handheld" % nm)
	var proxy := model.get_builtin_screen()            # hidden composite target
	var top: MeshInstance3D = model._screen            # top screen (lid)
	var bottom: MeshInstance3D = model._bottom_screen
	_fail_if(proxy == null or top == null or bottom == null, "%s missing screens" % nm)
	if proxy == null or top == null or bottom == null:
		return

	# UV windows into the composite framebuffer (carried by the window shaders).
	var top_uv := _window(model._top_mat)
	var bot_uv := _window(model._bottom_mat)
	print("[probe] %s top_uv=%s bottom_uv=%s" % [nm, top_uv, bot_uv])
	_fail_if(not top_uv.position.is_equal_approx(want_top.position)
		or not top_uv.size.is_equal_approx(want_top.size), "%s top UV window" % nm)
	_fail_if(not bot_uv.position.is_equal_approx(want_bottom.position)
		or not bot_uv.size.is_equal_approx(want_bottom.size), "%s bottom UV window" % nm)

	# The machine's picture must reach BOTH visible screen quads through their
	# window shaders. It comes from the machine itself now — the model asks its
	# parent — where it used to be read back off a material the C++ video handler
	# painted onto the hidden proxy.
	var host := StubHost.new()
	add_child(host)
	model._host = host
	# The model asks its PARENT for the picture, and its parent here is the probe.
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	picture = ImageTexture.create_from_image(img)
	model._process(0.016)
	_fail_if(top.get_surface_override_material(0) != model._top_mat,
		"%s top did not adopt window shader" % nm)
	_fail_if(bottom.get_surface_override_material(0) != model._bottom_mat,
		"%s bottom did not adopt window shader" % nm)
	_fail_if(model._top_mat.get_shader_parameter("source_tex") != picture,
		"%s window source_tex not fed from the machine" % nm)

	# Touch conversion: pokes at the bottom screen's centre and corner map
	# through the bottom UV window.
	var touch: Area3D = model._touch
	model._send_touch(touch.global_position, true)   # centre
	model._send_touch(touch.to_global(Vector3(
		model.bottom_screen_size.x / 2.0, 0, model.bottom_screen_size.y / 2.0)), false)
	var want_centre := want_bottom.position + want_bottom.size * 0.5
	var want_corner := want_bottom.position + want_bottom.size
	_fail_if(host.touches.size() != 2, "%s touch count %d" % [nm, host.touches.size()])
	if host.touches.size() == 2:
		var t0: Array = host.touches[0]
		var t1: Array = host.touches[1]
		print("[probe] %s touch centre=%s corner=%s" % [nm, t0[0], t1[0]])
		_fail_if(not (t0[0] as Vector2).is_equal_approx(want_centre) or t0[1] != true,
			"%s centre touch %s (want %s)" % [nm, t0[0], want_centre])
		_fail_if(not (t1[0] as Vector2).is_equal_approx(want_corner) or t1[1] != false,
			"%s corner touch %s (want %s)" % [nm, t1[0], want_corner])

	# Lid: authored open (interior angle strictly between shut and flat).
	var open := model.get_lid_angle_deg()
	print("[probe] %s lid_open_deg=%f" % [nm, open])
	_fail_if(open <= 1.0 or open >= 179.0, "%s lid not open (%.1f)" % [nm, open])


func _ready() -> void:
	# Resolved through the registry, not hardcoded: a hardcoded scene path is a
	# reference outside the registry, and it made these the only two models that
	# could not be deleted without editing another file. Skipped rather than failed
	# when the model is not in this build.
	await _check_id("nds_primitive", Rect2(0, 0, 1, 0.5), Rect2(0, 0.5, 1, 0.5))
	await _check_id("n3ds_primitive", Rect2(0, 0, 0.5, 0.5), Rect2(0.05, 0.5, 0.4, 0.5))
	print("[probe] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)

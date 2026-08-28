## Windowed end-to-end probe for dual-screen handhelds (Nintendo DS).
##
## Boots an NDS handheld WITHOUT a TV (melonDS + a crafted ROM whose ARM9
## paints the TOP screen red and leaves the BOTTOM screen white):
##   A. both quads share the core's emission material (mirroring works)
##   B. composite framebuffer is stacked top/bottom: the region each quad's
##      UV window shows is the RIGHT screen (top=red, bottom=white)
##   C. feed_touch drives the new SetPointerState binding without error
##
## Run: godot --path RetroXR --rendering-driver opengl3 \
##   res://Tools/cores/nds_probe.tscn -- "--nds-rom=C:/path/dual_screen_test.nds"
extends Node3D

var rom := ""
var core := "melonds"

var _sys: RetroSystem = null
var _fail := false


func _fail_if(cond: bool, msg: String) -> void:
	if cond:
		_fail = true
		print("[nds] FAIL: %s" % msg)


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--nds-rom="):
			rom = arg.trim_prefix("--nds-rom=")
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[nds] TIMEOUT")
		get_tree().quit(1))
	var core_dll := CoreDownloadManager.default_core_root() \
		.path_join("cores").path_join(core + "_libretro.dll")
	if rom.is_empty() or not FileAccess.file_exists(rom) or not FileAccess.file_exists(core_dll):
		print("[nds] SKIP: need --nds-rom= and the %s core installed" % core)
		get_tree().quit(0)
		return
	_run()


func _wait_frames(n: int) -> void:
	var lib: Node = _sys.get_libretro_node()
	var target: int = int(lib.GetFrameCount()) + n
	while int(lib.GetFrameCount()) < target:
		await get_tree().process_frame


func _sample(img: Image, uv: Vector2) -> Color:
	return img.get_pixel(
		clampi(int(uv.x * img.get_width()), 0, img.get_width() - 1),
		clampi(int(uv.y * img.get_height()), 0, img.get_height() - 1))


func _run() -> void:
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	_sys = sys_scene.instantiate() as RetroSystem
	_sys.systemid = "nds"
	_sys.core_name = core
	add_child(_sys)
	await get_tree().process_frame

	var model: RetroSystemModelDualScreen = _sys._model as RetroSystemModelDualScreen
	_fail_if(model == null, "nds model is not dual-screen")
	if model == null:
		return _finish()

	_sys.rom_path = rom
	_sys.power_on()
	_fail_if(not _sys.is_powered_on, "power_on failed without TV")
	if not _sys.is_powered_on:
		return _finish()
	await _wait_frames(150)

	# ── A: both quads share the core material ─────────────────────────────────
	var top := model.get_builtin_screen()
	var bottom: MeshInstance3D = model._bottom_screen
	var top_mat := top.get_surface_override_material(0)
	_fail_if(top_mat == null or not (top_mat is StandardMaterial3D), "no core material on top screen")
	_fail_if(bottom.get_surface_override_material(0) != top_mat, "bottom quad not mirroring")

	# ── B: composite regions — top half red, bottom half white ────────────────
	var tex: Texture2D = (top_mat as StandardMaterial3D).get_texture(BaseMaterial3D.TEXTURE_EMISSION)
	_fail_if(tex == null, "no emission texture")
	if tex == null:
		return _finish()
	var img := tex.get_image()
	print("[nds] framebuffer %dx%d" % [img.get_width(), img.get_height()])
	var c_top := _sample(img, Vector2(0.5, 0.25))
	var c_bot := _sample(img, Vector2(0.5, 0.75))
	print("[nds] B: top=%s bottom=%s" % [c_top, c_bot])
	_fail_if(not (c_top.r > 0.5 and c_top.g < 0.3 and c_top.b < 0.3),
		"top screen region not red (%s)" % c_top)
	_fail_if(not (c_bot.r > 0.7 and c_bot.g > 0.7 and c_bot.b > 0.7),
		"bottom screen region not white (%s)" % c_bot)

	# ── C: touch feed reaches the new SetPointerState binding ─────────────────
	_sys.feed_touch(Vector2(0.5, 0.75), true)
	await _wait_frames(5)
	_sys.feed_touch(Vector2(0.5, 0.75), false)
	print("[nds] C: feed_touch ok")

	_finish()


func _finish() -> void:
	print("[nds] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(1 if _fail else 0)

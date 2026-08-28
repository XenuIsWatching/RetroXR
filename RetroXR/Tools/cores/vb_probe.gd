## Windowed end-to-end probe for the Virtual Boy stereo pipeline.
##
## Boots a virtual_boy system (mednafen_vb + a minimal .vb ROM) and checks:
##   A. the forced-options seam: power_on rewrites core_options/mednafen_vb.opt
##      with vb_3dmode = side-by-side while PRESERVING other user keys
##   B. the core actually runs side-by-side: the proxy's emission texture is
##      768 px wide (384 per eye) — proof the .opt was read by the core
##   C. the eyepiece's stereo ShaderMaterial receives that texture and the
##      powered uniform follows power state
##
## Run: godot --path RetroXR --rendering-driver opengl3 \
##   res://Tools/cores/vb_probe.tscn -- "--vb-rom=C:/path/vb_stereo_test.vb"
extends Node3D

var rom := ""
var core := "mednafen_vb"

var _sys: RetroSystem = null
var _fail := false


func _fail_if(cond: bool, msg: String) -> void:
	if cond:
		_fail = true
		print("[vb] FAIL: %s" % msg)


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--vb-rom="):
			rom = arg.trim_prefix("--vb-rom=")
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[vb] TIMEOUT")
		get_tree().quit(1))
	var root := CoreDownloadManager.default_core_root()
	if rom.is_empty() or not FileAccess.file_exists(rom) \
			or not FileAccess.file_exists(root.path_join("cores").path_join(core + "_libretro.dll")):
		print("[vb] SKIP: need --vb-rom= and the %s core installed" % core)
		get_tree().quit(0)
		return
	_run(root)


func _wait_frames(n: int) -> void:
	var lib: Node = _sys.get_libretro_node()
	var target: int = int(lib.GetFrameCount()) + n
	while int(lib.GetFrameCount()) < target:
		await get_tree().process_frame


func _run(root: String) -> void:
	# Pre-seed the .opt with a stale 3dmode AND a custom user key that the
	# forced merge must preserve.
	var opt_path := root.path_join("core_options").path_join(core + ".opt")
	DirAccess.make_dir_recursive_absolute(root.path_join("core_options"))
	var seed := FileAccess.open(opt_path, FileAccess.WRITE)
	seed.store_string("vb_3dmode = \"anaglyph\"\nvb_color_mode = \"black & red\"\n")
	seed.close()

	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	_sys = sys_scene.instantiate() as RetroSystem
	_sys.systemid = "virtual_boy"
	_sys.core_name = core
	add_child(_sys)
	await get_tree().process_frame

	var model: RetroSystemModelVirtualBoy = _sys._model as RetroSystemModelVirtualBoy
	_fail_if(model == null, "model is not VirtualBoy")
	if model == null:
		return _finish()
	_fail_if(model.get_builtin_screen() == null, "no proxy screen")
	_fail_if(model.get_builtin_screen().visible, "proxy should be hidden")

	_sys.rom_path = rom
	_sys.power_on()
	_fail_if(not _sys.is_powered_on, "power_on failed")
	if not _sys.is_powered_on:
		return _finish()

	# ── A: forced options merged, user key preserved ──────────────────────────
	var opt_text := FileAccess.get_file_as_string(opt_path)
	print("[vb] A: opt = %s" % opt_text.replace("\n", " | "))
	_fail_if(not opt_text.contains("vb_3dmode = \"side-by-side\""), "vb_3dmode not forced")
	_fail_if(not opt_text.contains("vb_color_mode = \"black & red\""), "user key lost")

	await _wait_frames(90)

	# ── B: side-by-side framebuffer (two 384px eyes) ──────────────────────────
	var proxy := model.get_builtin_screen()
	var mat := proxy.get_surface_override_material(0)
	_fail_if(not (mat is StandardMaterial3D), "no core material on proxy")
	var tex: Texture2D = null
	if mat is StandardMaterial3D:
		tex = (mat as StandardMaterial3D).get_texture(BaseMaterial3D.TEXTURE_EMISSION)
	_fail_if(tex == null, "no emission texture")
	if tex:
		print("[vb] B: framebuffer %dx%d" % [tex.get_width(), tex.get_height()])
		_fail_if(tex.get_width() != 768 or tex.get_height() != 224,
			"framebuffer not side-by-side 768x224 (%dx%d)" % [tex.get_width(), tex.get_height()])

	# ── C: eyepiece shader wired + powered uniform ────────────────────────────
	var smat: ShaderMaterial = model._stereo_mat
	_fail_if(smat.get_shader_parameter("source_tex") != tex, "eyepiece not fed core texture")
	_fail_if(float(smat.get_shader_parameter("powered")) < 0.5, "powered uniform not 1")
	_sys.power_off()
	_fail_if(float(smat.get_shader_parameter("powered")) > 0.5, "powered uniform not 0 after off")
	print("[vb] C: eyepiece wired, powered uniform follows state")

	_finish()


func _finish() -> void:
	print("[vb] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(1 if _fail else 0)

## Windowed end-to-end probe for handheld consoles (Game Boy / GBA).
##
## Boots a GBA handheld WITHOUT a TV (mgba + a crafted blue-backdrop ROM):
##   A. core renders to the BUILT-IN screen (emission texture + luminance)
##   B. volume slider drives the audio player's volume_db
##   C. video-out: connecting a real RetroTV moves the picture there;
##      disconnecting brings it back to the device
##   D. tilt: SetSensorAccel feeds without error while running
##   E. power switch (detent 0) powers the device off
##
## Run: godot --path RetroXR --rendering-driver opengl3 \
##   res://Tools/cores/handheld_probe.tscn -- "--hh-rom=C:/path/handheld_test.gba"
extends Node3D

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")

var rom := ""
var core := "mgba"

var _sys: RetroSystem = null
var _fail := false


func _fail_if(cond: bool, msg: String) -> void:
	if cond:
		_fail = true
		print("[hh] FAIL: %s" % msg)


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--hh-rom="):
			rom = arg.trim_prefix("--hh-rom=")
		elif arg.begins_with("--hh-core="):
			core = arg.trim_prefix("--hh-core=")
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[hh] TIMEOUT")
		get_tree().quit(1))
	var core_dll := CoreDownloadManager.default_core_root() \
		.path_join("cores").path_join(core + "_libretro.dll")
	if rom.is_empty() or not FileAccess.file_exists(rom) or not FileAccess.file_exists(core_dll):
		print("[hh] SKIP: need --hh-rom= and the %s core installed" % core)
		get_tree().quit(0)
		return
	_run()


func _luminance(mesh: MeshInstance3D) -> float:
	var raw := mesh.get_surface_override_material(0)
	var tex: Texture2D = null
	if raw is StandardMaterial3D:
		tex = (raw as StandardMaterial3D).get_texture(BaseMaterial3D.TEXTURE_EMISSION)
	elif raw is ShaderMaterial:
		# TV screens are wrapped in the CRT shader; the core's texture is its input.
		tex = (raw as ShaderMaterial).get_shader_parameter("source_tex") as Texture2D
	if tex == null:
		return -1.0
	var img := tex.get_image()
	if img == null:
		return -1.0
	var total := 0.0
	var samples := 0
	for y in range(0, img.get_height(), maxi(1, img.get_height() / 8)):
		for x in range(0, img.get_width(), maxi(1, img.get_width() / 8)):
			var c := img.get_pixel(x, y)
			total += c.r + c.g + c.b
			samples += 1
	return total / maxi(samples, 1)


func _wait_frames(n: int) -> void:
	var lib: Node = _sys.get_libretro_node()
	var target: int = int(lib.GetFrameCount()) + n
	while int(lib.GetFrameCount()) < target:
		await get_tree().process_frame


func _run() -> void:
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	_sys = sys_scene.instantiate() as RetroSystem
	_sys.systemid = "game_boy_advance"
	_sys.core_name = core
	add_child(_sys)
	await get_tree().process_frame

	var model: RetroSystemModel = _sys._model
	_fail_if(not model.is_handheld(), "GBA model is not handheld")
	var screen := model.get_builtin_screen()
	_fail_if(screen == null, "no builtin screen")

	# ── A: boot with NO TV → picture on the device ────────────────────────────
	_sys.rom_path = rom
	_sys.power_on()
	_fail_if(not _sys.is_powered_on, "power_on failed without TV")
	if not _sys.is_powered_on:
		return _finish()
	await _wait_frames(90)
	var lum := _luminance(screen)
	print("[hh] A: builtin screen luminance = %.3f" % lum)
	_fail_if(lum < 0.05, "builtin screen dark/missing (%.3f)" % lum)

	# ── B: volume slider drives volume_db ────────────────────────────────────
	var vol_slider: VRSlider = model._volume_slider
	vol_slider._set_from_raw(0.5)
	var asp := _sys.get_libretro_node().get_node_or_null("AudioStreamPlayer3D") as AudioStreamPlayer3D
	_fail_if(asp == null, "no audio player")
	if asp:
		var want := linear_to_db(vol_slider.value)
		print("[hh] B: volume_db = %.2f (want %.2f)" % [asp.volume_db, want])
		_fail_if(absf(asp.volume_db - want) > 0.5, "volume slider not applied")

	# ── C: video-out to a real TV and back ────────────────────────────────────
	var tv := TV_SCENE.instantiate() as RetroTV
	add_child(tv)
	await get_tree().process_frame
	_sys.on_tv_connected(tv)
	await _wait_frames(30)
	var tv_lum := _luminance(tv.get_screen_mesh())
	print("[hh] C: tv luminance = %.3f" % tv_lum)
	_fail_if(tv_lum < 0.05, "picture did not move to TV (%.3f)" % tv_lum)
	_sys.on_tv_disconnected()
	await _wait_frames(30)
	var back_lum := _luminance(screen)
	print("[hh] C: builtin luminance after unplug = %.3f" % back_lum)
	_fail_if(back_lum < 0.05, "picture did not return to device (%.3f)" % back_lum)

	# ── D: tilt feed ──────────────────────────────────────────────────────────
	_sys.get_libretro_node().SetSensorAccel(0, 0.0, 0.0, 1.0)
	await _wait_frames(10)
	print("[hh] D: SetSensorAccel ok")

	# ── E: power switch detent 0 powers off ──────────────────────────────────
	var sw: VRSlider = model._power_switch
	sw._set_from_raw(1.0)   # reflect current on-state (no toggle: already on)
	sw._set_from_raw(0.0)
	await get_tree().process_frame
	print("[hh] E: powered_on after switch-off = %s" % _sys.is_powered_on)
	_fail_if(_sys.is_powered_on, "power switch did not power off")

	_finish()


func _finish() -> void:
	print("[hh] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(1 if _fail else 0)

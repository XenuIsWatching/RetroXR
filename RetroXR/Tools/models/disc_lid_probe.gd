## Disc-lid probe — what the core believes its tray holds after the lid is cycled.
##
## Reproduces the report: open the lid mid-boot, shut it, hit reset, and see
## whether the machine boots the disc. The oracle is the core's own disk-control
## answer (RequestDiskInfo -> disk_control_ready), not the picture: it says in so
## many words whether the tray is ejected and which image is in it.
##
##   godot --path RetroXR --rendering-driver opengl3 res://Tools/models/disc_lid_probe.tscn
extends Node3D

static var _home := OS.get_environment("USERPROFILE").replace("\\", "/")

var root_dir := _home + "/retroxr/libretro"
var core := "pcsx_rearmed"
var rom := _home + "/retroxr/roms/playstation/Crash Bandicoot 2 - Cortex Strikes Back (USA).cue"

var _lib: Node = null
var _info := {}


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--disc-rom="):
			rom = arg.trim_prefix("--disc-rom=")
		elif arg.begins_with("--disc-core="):
			core = arg.trim_prefix("--disc-core=")
	get_tree().create_timer(900.0).timeout.connect(func() -> void:
		print("[disc] TIMEOUT"); get_tree().quit(1))
	if not FileAccess.file_exists(rom):
		print("[disc] SKIP: rom not found (%s)" % rom)
		get_tree().quit(0)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://probe_out"))
	var obj: Object = ClassDB.instantiate("Libretro")
	_lib = obj as Node
	add_child(_lib)
	_lib.disk_control_ready.connect(_on_disk_info)
	_run()


func _on_disk_info(has_control: bool, count: int, index: int, ejected: bool) -> void:
	_info = {"has": has_control, "count": count, "index": index, "ejected": ejected}


func _wait(n: int) -> void:
	var target: int = int(_lib.GetFrameCount()) + n
	var guard := 0
	while int(_lib.GetFrameCount()) < target and guard < n * 30:
		guard += 1
		await get_tree().process_frame


## Ask the core, and say what it answered plus how bright the picture is.
func _report(stage: String) -> void:
	_info = {}
	_lib.RequestDiskInfo()
	var guard := 0
	while _info.is_empty() and guard < 240:
		guard += 1
		await get_tree().process_frame
	var lum := 0.0
	var tex: Texture2D = _lib.GetVideoTexture()
	if tex != null:
		var img := tex.get_image()
		img.resize(64, 48, Image.INTERPOLATE_BILINEAR)
		var total := 0.0
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				var c := img.get_pixel(x, y)
				total += (c.r + c.g + c.b) / 3.0
		lum = total / float(img.get_width() * img.get_height())
		var out := Image.create_empty(img.get_width(), img.get_height(), false, Image.FORMAT_RGB8)
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				var c := img.get_pixel(x, y)
				out.set_pixel(x, y, Color(c.r, c.g, c.b, 1.0))
		out.resize(256, 192, Image.INTERPOLATE_NEAREST)
		out.save_png("res://probe_out/disc_%s.png" % stage)
	print("[disc] %-22s frame=%-6d core says: %s   lum=%.3f"
		% [stage, int(_lib.GetFrameCount()),
			"(no answer)" if _info.is_empty() else
			"control=%s images=%d index=%d EJECTED=%s"
				% [_info["has"], _info["count"], _info["index"], _info["ejected"]],
			lum])


func _lum() -> float:
	var tex: Texture2D = _lib.GetVideoTexture()
	if tex == null:
		return -1.0
	var img := tex.get_image()
	img.resize(64, 48, Image.INTERPOLATE_BILINEAR)
	var total := 0.0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			total += (c.r + c.g + c.b) / 3.0
	return total / float(img.get_width() * img.get_height())


## Watch the picture for a while after a reset — a PS1 coming back up is dark for
## a good few seconds before the logo, so one sample proves nothing.
func _watch(tag: String, frames: int) -> void:
	var step := 300
	var seen := 0
	var line: Array[String] = []
	while seen < frames:
		await _wait(step)
		seen += step
		line.append("%ds:%.3f" % [seen / 60, _lum()])
	print("[disc] %s picture over time -> %s" % [tag, " ".join(line)])


func _run() -> void:
	for variant: String in ["control", "lid"]:
		print("[disc] ==== %s ====" % variant)
		_lib.StartContent(root_dir, core, rom)
		await _wait(600)
		await _report("%s_1_booted" % variant)
		if variant == "lid":
			_lib.SetDiskEjectState(true)
			await _wait(180)
			await _report("%s_2_lid_open" % variant)
			_lib.ReplaceDiskImage(0, rom)
			_lib.SetDiskEjectState(false)
			await _wait(180)
			await _report("%s_3_lid_shut" % variant)
		_lib.RequestReset()
		await _watch(variant, 3600)
		await _report("%s_4_after_reset" % variant)
		_lib.StopContent()
		await get_tree().create_timer(1.0).timeout
	print("[disc] done")
	get_tree().quit(0)

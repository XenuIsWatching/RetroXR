## Zapper device probe — which device id makes fceumm treat a NES port as a Zapper.
##
## Oracle: with fceumm_show_crosshair enabled, the core draws a crosshair into the
## frame AT the lightgun position, but only while that port really is a Zapper.
## So: park the gun offscreen, grab a frame, aim it at a fixed spot, grab another,
## and measure how much the pixels around that spot changed. A Zapper port lights
## up; a gamepad port shows nothing.
extends Node3D

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

var root_dir := _home + "/retroxr/libretro"
var core := "fceumm"
var rom := _home + "/retroxr/roms/nes/Duck Hunt (World).nes"

## [device id, what it is]
const CASES: Array = [
	[-1,  "untouched — whatever the core chose when the game loaded"],
	[7,   "RETRO_DEVICE_LIGHTGUN — what LightGun announces today"],
	[258, "fceumm ZAPPER = SUBCLASS(MOUSE, 0)"],
	[1,   "AUTO = JOYPAD — game-database auto-detect"],
	[513, "fceumm GAMEPAD = SUBCLASS(JOYPAD, 1)"],
]

## Where the gun is aimed, in normalised screen coords.
const AIM_U := 0.35
const AIM_V := 0.30
const WINDOW := 16   # half-size of the pixel window sampled around the aim point

var _lib: Node = null


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--rom="):
			rom = arg.trim_prefix("--rom=")
		elif arg.begins_with("--core="):
			core = arg.trim_prefix("--core=")
		elif arg.begins_with("--root="):
			root_dir = arg.trim_prefix("--root=")
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("[zapper] TIMEOUT")
		get_tree().quit(1))
	if not FileAccess.file_exists(rom):
		print("[zapper] SKIP: rom not found (%s)" % rom)
		get_tree().quit(0)
		return
	var obj: Object = ClassDB.instantiate("Libretro")
	_lib = obj as Node
	add_child(_lib)
	_run()


func _wait_frames(n: int) -> void:
	var target: int = int(_lib.GetFrameCount()) + n
	while int(_lib.GetFrameCount()) < target:
		await get_tree().process_frame


func _grab() -> Image:
	await get_tree().process_frame
	var tex: Texture2D = _lib.GetVideoTexture()
	if tex == null:
		return null
	return tex.get_image()


## Mean per-pixel difference inside the window around the aim point, and over the
## whole frame (the second is the animation floor the first has to beat).
func _diff(a: Image, b: Image) -> Array:
	var w := a.get_width()
	var h := a.get_height()
	var cx := int(AIM_U * w)
	var cy := int(AIM_V * h)
	var win := 0.0
	var win_n := 0
	var all := 0.0
	for y in range(h):
		for x in range(w):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d: float = absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			all += d
			if absi(x - cx) <= WINDOW and absi(y - cy) <= WINDOW:
				win += d
				win_n += 1
	return [win / maxi(win_n, 1), all / float(w * h)]


## Which pixels moved between the two grabs, with their before/after colours.
func _changed_list(a: Image, b: Image) -> String:
	var out: Array = []
	for y in range(a.get_height()):
		for x in range(a.get_width()):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.02:
				out.append("(%d,%d %s→%s)" % [x, y, ca.to_html(false), cb.to_html(false)])
	if out.size() > 8:
		out.resize(8)
		out.append("…")
	return " ".join(out) if out.size() > 0 else "none"


## A magnified crop around the aim point, so the crosshair (2 px wide at 256x240)
## is actually visible in the saved PNG.
func _save_crop(img: Image, path: String) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var cx := int(AIM_U * w)
	var cy := int(AIM_V * h)
	var side := WINDOW * 2
	var rect := Rect2i(maxi(cx - WINDOW, 0), maxi(cy - WINDOW, 0), side, side)
	var crop := img.get_region(rect)
	crop.resize(side * 8, side * 8, Image.INTERPOLATE_NEAREST)
	# The core's framebuffer is XRGB8888, so every pixel carries alpha 0 and a
	# saved PNG reads as fully transparent. Paint the alpha back in.
	_opaque(crop).save_png(path)
	_opaque(img).save_png(path.replace(".png", "_full.png"))


func _opaque(img: Image) -> Image:
	var out := Image.create_empty(img.get_width(), img.get_height(), false, Image.FORMAT_RGB8)
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			out.set_pixel(x, y, Color(c.r, c.g, c.b, 1.0))
	return out


func _run() -> void:
	print("[zapper] booting %s with %s" % [rom.get_file(), core])
	_lib.StartContent(root_dir, core, rom)
	await _wait_frames(600)
	var info: Array = _lib.GetControllerInfo()
	for entry: Dictionary in info:
		var names: Array = []
		for c2: Dictionary in entry["controllers"]:
			names.append("%s=%d" % [c2["name"], c2["id"]])
		print("[zapper] core port %d devices: %s" % [entry["port"], ", ".join(names)])
	var probe_dir := "res://probe_out"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(probe_dir))

	# RetroSystem._core_device_id, fed the list this very core just declared.
	var sys: Object = load("res://Scripts/Objects/systems/system.gd").new()
	sys.set("_controller_info", info)
	var resolved: int = sys.call("_core_device_id", 7, 1)
	print("[zapper] resolver: lightgun on port 2 -> %d %s"
		% [resolved, "PASS" if resolved == 258 else "FAIL (expected fceumm's Zapper, 258)"])
	var no_gun: int = sys.call("_core_device_id", 7, 3)
	print("[zapper] resolver: lightgun on port 4 (no gun declared) -> %d %s"
		% [no_gun, "PASS" if no_gun == 7 else "FAIL (expected the id to pass through)"])
	var pad: int = sys.call("_core_device_id", 1, 1)
	print("[zapper] resolver: joypad on port 2 -> %d %s"
		% [pad, "PASS" if pad == 1 else "FAIL (only a light gun may be translated)"])
	sys.free()

	for c: Array in CASES:
		var dev: int = c[0]
		if dev >= 0:
			_lib.SetControllerPortDevice(1, dev)
		await _wait_frames(30)

		_lib.SetLightgunIsOffscreen(1, true)
		await _wait_frames(12)
		var off: Image = await _grab()

		_lib.SetLightgunIsOffscreen(1, false)
		_lib.SetLightgunPosition(1, int((AIM_U * 2.0 - 1.0) * 32767),
			int((AIM_V * 2.0 - 1.0) * 32767))
		await _wait_frames(12)
		var on: Image = await _grab()

		if off == null or on == null:
			print("[zapper] device %d: no video texture" % dev)
			continue
		var d := _diff(off, on)
		print("[zapper] device %-4d aimed-window delta %.4f  frame delta %.4f   %s"
			% [dev, d[0], d[1], c[1]])
		print("[zapper]   frame %dx%d  centre px off=%s on=%s  changed px: %s"
			% [on.get_width(), on.get_height(),
			off.get_pixel(int(AIM_U * on.get_width()), int(AIM_V * on.get_height())),
			on.get_pixel(int(AIM_U * on.get_width()), int(AIM_V * on.get_height())),
			_changed_list(off, on)])
		_save_crop(on, "%s/zapper_dev%d.png" % [probe_dir, dev])

	await _shot_check(resolved, probe_dir)

	_lib.StopContent()
	await get_tree().create_timer(0.5).timeout
	print("[zapper] done")
	get_tree().quit(0)


## Does a trigger pull reach the game? Start GAME A with the pad on port 1, then
## fire. Duck Hunt spends a shell on every shot, hit or miss, so the ammo row at
## the bottom of the HUD is the oracle — no need to actually hit a duck.
func _shot_check(dev: int, probe_dir: String) -> void:
	const START_MASK := 1 << 3
	_lib.SetControllerPortDevice(1, dev)
	_lib.SetLightgunIsOffscreen(1, false)
	_lib.SetLightgunPosition(1, 0, 0)
	await _wait_frames(30)

	_lib.SetJoypadState(0, START_MASK, 0, 0, 0, 0)
	await _wait_frames(10)
	_lib.SetJoypadState(0, 0, 0, 0, 0, 0)
	await _wait_frames(480)          # the dog's walk, then the ducks are released
	var before: Image = await _grab()

	_lib.SetLightgunButton(1, 2, true)   # RETRO_DEVICE_ID_LIGHTGUN_TRIGGER
	await _wait_frames(6)
	_lib.SetLightgunButton(1, 2, false)
	await _wait_frames(60)
	var after: Image = await _grab()

	if before == null or after == null:
		print("[zapper] shot check: no video texture")
		return
	# The ammo row sits in the bottom eighth of the frame.
	var h := before.get_height()
	var w := before.get_width()
	var changed := 0
	for y in range(int(h * 0.875), h):
		for x in range(w):
			var ca := before.get_pixel(x, y)
			var cb := after.get_pixel(x, y)
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.02:
				changed += 1
	print("[zapper] shot check with device %d: %d HUD pixels changed — %s"
		% [dev, changed, "PASS (the trigger reached the game)" if changed > 0
			else "FAIL (nothing responded to the trigger)"])
	_opaque(before).save_png("%s/zapper_shot_before.png" % probe_dir)
	_opaque(after).save_png("%s/zapper_shot_after.png" % probe_dir)

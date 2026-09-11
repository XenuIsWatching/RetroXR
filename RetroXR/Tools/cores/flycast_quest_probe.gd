## flycast on Quest — does it load, render, see a controller and take input?
##
## Exists because "flycast doesn't work on Quest" cannot be reproduced from a
## desk: the app's menu is world-space, so nothing on the adb side can drive it,
## and the in-app probe launch hook was removed. This boots INSTEAD of the room,
## via a feature-tagged run/main_scene on its own package, so the real app stays
## installed alongside it. See the memory on probe-as-separate-package.
##
## It answers, in order, the things that could each be "doesn't work":
##
##   1. does the core load at all on arm64            (core identity)
##   2. does it RENDER                                (frames advancing, a frame
##                                                     with more than one colour)
##   3. does the game see a CONTROLLER                (the fix under test)
##   4. does a VMU appear in socket 1                 (the slot nudge)
##   5. does input REACH it                           (frame changes under input)
##
## Everything goes to the log with an `[fq]` prefix, including an `alive` line
## every second: a process that died and one that is running but not ticking look
## identical otherwise.
##
##     adb logcat -c && adb logcat -s 'godot:*'
##
## Quote that -s pattern. Unquoted, bash eats the glob and silently disables the
## filter.
extends Node

const CORE := "flycast"
const DEVICE_JOYPAD := 1
const HEARTBEAT_SEC := 1.0

var _lib: Node = null
var _rom := ""
var _t0 := 0
var _next_beat := 0
var _nudged := false
var _load_failed := ""
var _phase := "boot"
var _last_digest := ""


func _ready() -> void:
	print("[fq] ==== flycast Quest probe ====")
	print("[fq] platform=%s  renderer=%s" % [OS.get_name(),
		ProjectSettings.get_setting("rendering/renderer/rendering_method", "?")])
	var root := CoreDownloadManager.default_core_root()
	print("[fq] core root=%s" % root)

	var lib_path := CoreDownloadManager.installed_core_lib(CORE)
	print("[fq] core installed: %s" % (lib_path if not lib_path.is_empty() else "NO"))
	if lib_path.is_empty():
		print("[fq] VERDICT: the flycast core is not installed on this device")
		return

	_rom = _find_rom()
	print("[fq] rom: %s" % (_rom if not _rom.is_empty() else "NONE FOUND"))
	if _rom.is_empty():
		print("[fq] VERDICT: no Dreamcast content on this device to load")
		return

	# The options the shipping code pins, pinned the same way so this run is not
	# a special configuration.
	var opts := {
		"reicast_device_port1_slot1": "VMU",
		"reicast_device_port1_slot2": "None",
		"reicast_per_content_vmus": "disabled",
	}
	opts.merge(VmuStorage.screen_options(0, true), true)
	CoreOptionsStore.merge_values(root, CORE, opts)
	print("[fq] pinned %d core options" % opts.size())
	print("[fq] hw render pref for %s = %s" % [CORE, AppPrefs.hw_render_for(CORE)])

	var obj: Object = ClassDB.instantiate("Libretro")
	_lib = obj as Node
	if _lib == null:
		print("[fq] VERDICT: could not instantiate a Libretro node")
		return
	_lib.name = "FlycastProbe"
	add_child(_lib)
	_lib.connect("content_load_failed", _on_load_failed)

	# BEFORE StartContent. flycast takes its main maple device from this call, and
	# until the fix under test the frontend never made it for a plain joypad — so
	# a Dreamcast came up with no controller, hence no expansion socket and no
	# VMU. The extension logs "Applying pre-start port device" when it lands.
	_lib.SetControllerPortDevice(0, DEVICE_JOYPAD)
	print("[fq] announced port 0 = JOYPAD before load")

	_phase = "loading"
	_lib.StartContent(root, CORE, _rom)
	_t0 = Time.get_ticks_msec()
	set_process(true)


func _on_load_failed(reason: String) -> void:
	_load_failed = reason
	print("[fq] LOAD FAILED: %s" % reason)
	print("[fq] VERDICT: the core refused the content")


## First Dreamcast image on the device, whatever it is called.
func _find_rom() -> String:
	var dir := CoreDownloadManager.default_core_root().get_base_dir().path_join("roms/dreamcast")
	# The roms root is a sibling of the libretro root on desktop and on Android
	# alike, but ask RomLibrary rather than assuming when it is available.
	for candidate: String in [dir, OS.get_user_data_dir().path_join("roms/dreamcast")]:
		var d := DirAccess.open(candidate)
		if d == null:
			continue
		for f in d.get_files():
			var e := f.get_extension().to_lower()
			if e in ["chd", "gdi", "cdi", "cue", "iso"]:
				return candidate.path_join(f)
	return ""


## A fingerprint of the frame, for telling "changed" from "frozen".
func _digest() -> String:
	if _lib == null:
		return ""
	var tex: Texture2D = _lib.GetVideoTexture()
	if tex == null:
		return ""
	var img := tex.get_image()
	if img == null:
		return ""
	var seen := {}
	var acc := 0
	# Sparse: a full 640x480 walk every second on a mobile CPU is not free.
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			var c := img.get_pixel(x, y).to_rgba32()
			seen[c] = true
			acc = (acc + c) & 0x7FFFFFFF
	return "%d/%d" % [seen.size(), acc]


func _process(_delta: float) -> void:
	if _lib == null:
		return
	# Held neutral except during the input window below.
	var elapsed := Time.get_ticks_msec() - _t0

	# The slot options are read only on a SECOND update_variables, which flycast
	# gates on having run a frame. Same condition RetroSystem hangs it off.
	if not _nudged and int(_lib.GetFrameCount()) > 0:
		_nudged = true
		_lib.SetCoreOption("reicast_device_port1_slot1", "VMU")
		print("[fq] frame 1 reached; re-asserted the slot option")

	# Input window: 14 s to 18 s, A held. Before and after are neutral so the
	# digest either side is comparable.
	var hold := 0
	if elapsed > 14000 and elapsed < 18000:
		hold = 1 << ControllerBindings.JOYPAD_A
	_lib.SetJoypadState(0, hold, 0, 0, 0, 0)

	if elapsed >= _next_beat:
		_next_beat += int(HEARTBEAT_SEC * 1000.0)
		var tex: Texture2D = _lib.GetVideoTexture()
		var size := str(tex.get_size()) if tex != null else "<none>"
		var d := _digest()
		var changed := "-" if d == _last_digest else "CHANGED"
		_last_digest = d
		print("[fq] alive t=%.0fs frames=%d tex=%s colours/acc=%s %s hold=%d"
			% [elapsed / 1000.0, int(_lib.GetFrameCount()), size, d, changed, hold])

	if elapsed > 26000:
		_report()
		set_process(false)


func _report() -> void:
	var frames := int(_lib.GetFrameCount())
	var ident: Dictionary = _lib.GetCoreIdentity() if _lib.has_method("GetCoreIdentity") else {}
	print("[fq] ---- report ----")
	print("[fq] core identity: %s" % str(ident))
	print("[fq] frames run: %d" % frames)
	var tex: Texture2D = _lib.GetVideoTexture()
	print("[fq] final texture: %s" % (str(tex.get_size()) if tex != null else "<none>"))
	if frames <= 0:
		print("[fq] VERDICT: the core loaded but never ran a frame")
	elif tex == null:
		print("[fq] VERDICT: frames ran but no picture was ever published")
	else:
		print("[fq] VERDICT: flycast loaded, ran %d frames and published a picture" % frames)
	print("[fq] NOTE: whether the GAME saw a controller and a VMU is in the")
	print("[fq]       picture, not in this log - grep the run for 'Applying")
	print("[fq]       pre-start port device' to confirm the fix is in this build.")
	# Left running rather than stopped: StopContent unwinds on another thread and
	# quitting into it is an access violation. The launcher force-stops instead.

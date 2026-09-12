## Pacing probe — what rate is a core actually run at, against the rate it says?
##
## The emulation loop's ceiling is the core's declared fps, so a core that
## declares one thing and advances another runs the machine at the wrong speed
## with nothing in any log to say so. This prints both, once a second, so the two
## can be compared over a whole session rather than at one moment.
##
##     "$godot" --path RetroXR --resolution 320x240 --position 20,20 \n##         res://Tools/cores/pacing_probe.tscn -- \n##         "--rom=$HOME/retroxr/roms/dreamcast/game.chd" \n##         [--secs=75] [--vsync=enabled|disabled]
##
## This is the provenance of ForcedCoreOptions.declared_frame_rate. Goin'
## Quackers ran at DOUBLE speed in its menus and gameplay while its FMV was
## perfect, and the reason is that flycast's retro_run, with threaded rendering
## on, keeps emulating until a frame is not a duplicate — so one call covers two
## vblanks of a game locked to 30 fps. Measured here: with
## reicast_detect_vsync_swap_interval disabled the core declares 59.9453 for the
## whole run and the call rate sits at 60.00/s; enabled, the core announced
## 29.972650 at t=35s and the call rate fell to 30.00/s inside a second.
##
## It taps START from twelve seconds in, because the interesting rate change is
## past a title screen and a probe that holds nothing never gets there. That is
## also the trap: a run that never leaves the intro shows one rate and proves
## nothing, so read the "declared rates seen" line at the end rather than the
## first few ticks.
##
## Writes the player's real flycast.opt when --vsync is given, and restores it.
extends Node

const KEY_VSYNC := "reicast_detect_vsync_swap_interval"
const START_MASK := 1 << 3  # RETRO_DEVICE_ID_JOYPAD_START

var rom := ""
var core := "flycast"
var secs := 60
var vsync := ""
var _lib: Node = null
var _root := ""
var _failed := ""
var _backup := PackedByteArray()


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--rom="):
			rom = s.substr("--rom=".length())
		elif s.begins_with("--secs="):
			secs = int(s.substr("--secs=".length()))
		elif s.begins_with("--vsync="):
			vsync = s.substr("--vsync=".length())
	get_tree().create_timer(float(secs) + 120.0).timeout.connect(func() -> void:
		print("[pace] TIMEOUT"); _restore(); get_tree().quit(1))
	_root = CoreDownloadManager.default_core_root()
	if rom.is_empty() or not FileAccess.file_exists(rom):
		print("[pace] SKIP: no --rom")
		get_tree().quit(2)
		return
	await _run()
	_restore()
	get_tree().quit(0)


func _opt_path() -> String:
	return _root.path_join("core_options/%s.opt" % core)


func _restore() -> void:
	if _backup.is_empty():
		return
	var f := FileAccess.open(_opt_path(), FileAccess.WRITE)
	if f != null:
		f.store_buffer(_backup)
		f.close()
	print("[pace] restored the player's flycast.opt")


func _run() -> void:
	var f := FileAccess.open(_opt_path(), FileAccess.READ)
	if f != null:
		_backup = f.get_buffer(f.get_length())
		f.close()
	if not vsync.is_empty():
		CoreOptionsStore.merge_values(_root, core, {KEY_VSYNC: vsync})
		print("[pace] pinned %s=%s" % [KEY_VSYNC, vsync])

	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	add_child(_lib)
	_lib.connect("content_load_failed", func(r: String) -> void: _failed = r)
	_lib.SetControllerPortDevice(0, 1)
	_lib.StartContent(_root, core, rom)
	print("[pace] rom=%s" % rom.get_file())

	var last_frames := 0
	var last_ms := Time.get_ticks_msec()
	var t0 := last_ms
	var declared_seen := {}
	# Start is tapped from 12 s on, to walk the intro through to the menu. Held
	# every other tick so the game sees an edge rather than a stuck button.
	var tick := 0
	while (Time.get_ticks_msec() - t0) < secs * 1000:
		var elapsed := Time.get_ticks_msec() - t0
		var press := elapsed > 12000 and (int(elapsed / 500) % 2) == 0
		_lib.SetJoypadState(0, START_MASK if press else 0, 0, 0, 0, 0)
		await get_tree().process_frame
		if not _failed.is_empty():
			print("[pace] refused: %s" % _failed)
			return
		var now := Time.get_ticks_msec()
		if now - last_ms < 1000:
			continue
		tick += 1
		var frames: int = int(_lib.GetFrameCount())
		var declared: float = float(_lib.GetDeclaredFps())
		var rate := float(frames - last_frames) / (float(now - last_ms) / 1000.0)
		if frames > 0:
			declared_seen[snappedf(declared, 0.01)] = true
			print("[pace] t=%5.1fs  declared=%7.4f  calls=%6.2f/s"
				% [float(now - t0) / 1000.0, declared, rate])
		last_frames = frames
		last_ms = now
	print("[pace] declared rates seen this run: %s" % str(declared_seen.keys()))
	if _lib.has_method("StopContent"):
		_lib.StopContent()
	await get_tree().create_timer(1.0).timeout

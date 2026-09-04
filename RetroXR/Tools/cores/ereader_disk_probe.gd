## Does mGBA publish disk control, and only for an e-Reader cartridge?
##
## Needs a real core and a real ROM, so it is a probe. It answers the half that
## can be checked without the e-Reader cartridge dump: an ORDINARY Game Boy
## Advance game must report NO disk control. Publishing unconditionally would
## give every GBA game a disc menu, and that is the mistake this guards.
##
##   godot --headless --path RetroXR res://Tools/cores/ereader_disk_probe.tscn -- \
##     --core=mgba --rom="$HOME/retroxr/roms/game_boy_advance/game.gba" --expect=none
##
## --expect=none  the core must report has_control false  (an ordinary GBA game)
## --expect=disk  the core must report has_control true   (the e-Reader cart)
##
## Exits non-zero when the answer is not the one expected, so it can gate.
extends Node

var _lib: Node = null
var _core := "mgba"
var _rom := ""
var _root := ""
var _expect := "none"
var _seen := false
var _has_control := false
var _count := 0
var _failed := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--core="):
			_core = a.substr(7)
		elif a.begins_with("--rom="):
			_rom = a.substr(6)
		elif a.begins_with("--root="):
			_root = a.substr(7)
		elif a.begins_with("--expect="):
			_expect = a.substr(9)
	if _root.is_empty():
		_root = CoreDownloadManager.default_core_root()
	if _rom.is_empty() or not FileAccess.file_exists(_rom):
		print("[edp] FAIL: --rom must name a file that exists (got '%s')" % _rom)
		get_tree().quit(1)
		return

	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	if _lib == null:
		print("[edp] FAIL: could not instantiate Libretro")
		get_tree().quit(1)
		return
	add_child(_lib)
	_lib.connect("content_load_failed", func(reason: String) -> void:
		_failed = reason)
	_lib.connect("disk_control_ready", _on_disk_control_ready)

	print("[edp] core=%s expect=%s" % [_core, _expect])
	print("[edp] rom=%s" % _rom)
	_lib.StartContent(_root, _core, _rom)

	# The core comes up asynchronously; a real one took 34 frames in an earlier
	# probe, so poll rather than sampling once.
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 12000:
		await get_tree().process_frame
		if not _failed.is_empty():
			break
		if _lib.has_method("GetCoreIdentity"):
			var ident: Dictionary = _lib.call("GetCoreIdentity")
			if not ident.is_empty():
				break
	if _failed.is_empty():
		print("[edp] core up: %s" % str(_lib.call("GetCoreIdentity")))
		_lib.RequestDiskInfo()
		var t1 := Time.get_ticks_msec()
		while not _seen and Time.get_ticks_msec() - t1 < 5000:
			await get_tree().process_frame

	_report()


func _on_disk_control_ready(has_control: bool, count: int, index: int, ejected: bool) -> void:
	_seen = true
	_has_control = has_control
	_count = count
	print("[edp] disk_control_ready has=%s images=%d index=%d ejected=%s"
		% [has_control, count, index, ejected])


func _report() -> void:
	if not _failed.is_empty():
		print("[edp] FAIL: content load failed — %s" % _failed)
		get_tree().quit(1)
		return
	if not _seen:
		print("[edp] FAIL: no disk_control_ready answer within 5 s")
		get_tree().quit(1)
		return
	var want := _expect == "disk"
	if _has_control == want:
		print("[edp] PASS: has_control=%s, which is what %s expects" % [_has_control, _expect])
		get_tree().quit(0)
	else:
		print("[edp] FAIL: has_control=%s but --expect=%s" % [_has_control, _expect])
		get_tree().quit(1)

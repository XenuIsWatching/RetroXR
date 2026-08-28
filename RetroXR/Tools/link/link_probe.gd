## Two real mGBA cores on one link bus.
##
##     "$godot" --headless --path RetroXR res://Tools/link/link_probe.tscn
##
## A probe rather than a test, because it needs a real mGBA core built with the
## link driver and a real GBA ROM, so it cannot gate a commit. What it proves is
## the one claim the headless suites cannot reach: that two instances of a core,
## each loaded from its own copy of the shared library, actually find each other
## through the frontend's bus.
##
## It asserts and exits non-zero anyway, so it is worth running by hand after
## touching either half.
##
## The link is enabled through the core's options FILE rather than SetCoreOption,
## because the core reads mgba_link_cable while loading the game and
## SetCoreOption only reaches a core that is already running. The file is the
## player's own, so it is snapshotted and put back at both ends.
extends Node

const CORE := "mgba"
const OPT_KEY := "mgba_link_cable"

var _pass := 0
var _fail := 0
var _opt_path := ""
var _opt_backup := ""
var _restored := false


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[link-probe] TIMEOUT")
		_restore()
		get_tree().quit(1))
	await _run()


func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("[link-probe] PASS  %s" % name)
	else:
		_fail += 1
		print("[link-probe] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])


func _finish() -> void:
	_restore()
	print("[link-probe] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _run() -> void:
	var root := CoreDownloadManager.default_core_root()
	var rom := _find_rom()
	if rom.is_empty():
		print("[link-probe] SKIP  no .gba ROM found; nothing to run two cores on")
		get_tree().quit(0)
		return
	print("[link-probe] rom  %s" % rom)
	print("[link-probe] root %s" % root)

	if not _enable_link_option(root):
		print("[link-probe] SKIP  could not write the core options file")
		get_tree().quit(0)
		return

	var a := Libretro.new()
	var b := Libretro.new()
	add_child(a)
	add_child(b)

	a.StartContent(root, CORE, rom)
	b.StartContent(root, CORE, rom)

	# Both cores have to get far enough through retro_load_game to attach, which
	# is a thread hand-off and a file load away.
	for i in range(240):
		await get_tree().process_frame

	# Attached but cabled to nothing: the bus has no idea these two belong
	# together until the room says so, which is the whole point of the cable.
	_eq("A alone sees no peers", a.LinkPeerCount(0), 0)
	_eq("B alone sees no peers", b.LinkPeerCount(0), 0)

	_ok("cabling them together succeeds", a.LinkConnect(b, 0, 0))
	await get_tree().process_frame

	_eq("A now sees both machines", a.LinkPeerCount(0), 2)
	_eq("B now sees both machines", b.LinkPeerCount(0), 2)

	# And the cable comes out again. A guest mid-transfer reads 0xFFFF from here
	# on, which is what a pulled cable gives it.
	a.LinkDisconnect(0)
	await get_tree().process_frame
	_eq("A is alone again", a.LinkPeerCount(0), 0)
	_eq("B is alone again", b.LinkPeerCount(0), 0)

	# Re-cabling has to work, because a player will do it.
	_ok("cabling them again succeeds", a.LinkConnect(b, 0, 0))
	await get_tree().process_frame
	_eq("A sees both machines again", a.LinkPeerCount(0), 2)

	# Stopping a linked core must not wedge the other. Its emulation thread is
	# parked on the barrier waiting for a peer that will never publish again.
	a.StopContent()
	for i in range(120):
		await get_tree().process_frame
	# Not asserted separately that the run did not hang: reaching this line at
	# all is the proof, and the 120 s timeout is what fails if it does not.
	_eq("stopping one end leaves the other alone", b.LinkPeerCount(0), 0)

	b.StopContent()
	for i in range(120):
		await get_tree().process_frame

	a.queue_free()
	b.queue_free()
	await get_tree().process_frame
	_finish()


func _find_rom() -> String:
	# RomLibrary owns where ROMs live on each platform, so ask it rather than
	# rebuilding the path here and getting it subtly wrong.
	var root := RomLibrary.default_roms_root()
	for systemid in ["game_boy_advance", "gba"]:
		var dir_path: String = root.path_join(systemid)
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for f in dir.get_files():
			if f.to_lower().ends_with(".gba"):
				return dir_path.path_join(f)
	return ""


## Turn the link on in the core's options file, keeping a copy of whatever was
## there. Returns false when the file cannot be written, which is a skip rather
## than a failure: nothing about the bus is proven either way.
func _enable_link_option(root: String) -> bool:
	_opt_path = "%s/core_options/%s.opt" % [root, CORE]
	var existing := ""
	if FileAccess.file_exists(_opt_path):
		var reader := FileAccess.open(_opt_path, FileAccess.READ)
		if reader != null:
			existing = reader.get_as_text()
			reader.close()
	_opt_backup = existing

	var lines: PackedStringArray = []
	for line in existing.split("\n", false):
		if not line.begins_with(OPT_KEY):
			lines.append(line)
	# "ON", the option's own VALUE, not "enabled", which is only the label the
	# menu prints beside it. Writing the label put a string the option does not
	# offer into the file: the core read it, matched nothing, and left the link
	# driver uninstalled -- so a probe that wrote it was exercising a
	# configuration no player can produce, and passed while the room failed.
	lines.append('%s = "ON"' % OPT_KEY)

	var writer := FileAccess.open(_opt_path, FileAccess.WRITE)
	if writer == null:
		return false
	writer.store_string("\n".join(lines) + "\n")
	writer.close()
	return true


func _restore() -> void:
	if _restored or _opt_path.is_empty():
		return
	_restored = true
	var writer := FileAccess.open(_opt_path, FileAccess.WRITE)
	if writer != null:
		writer.store_string(_opt_backup)
		writer.close()
		print("[link-probe] restored %s" % _opt_path)

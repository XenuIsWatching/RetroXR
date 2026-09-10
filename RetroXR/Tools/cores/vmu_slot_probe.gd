## VMU slot probe — whether a VMU can be swapped in a RUNNING Dreamcast.
##
## The storage design turns on one question that cannot be settled from source:
## does changing `reicast_device_port1_slot1` while the core runs re-create the
## maple device, so the VMU re-reads its file? flycast's update_variables() sets
## devices_need_refresh and retro_run calls maple_ReconnectDevices(), which reads
## like a yes.
##
##     "$godot" --headless --path RetroXR res://Tools/cores/vmu_slot_probe.tscn -- \
##         --rom="$HOME/retroxr/roms/dreamcast/Crazy Taxi 2 (USA).chd" [--seconds=8]
##
## **THIS PROBE'S RESULT IS CURRENTLY CONFOUNDED. Do not cite it.**
##
## The first run said "no", and that reading does not stand: it attaches no
## CONTROLLER, and a VMU lives in a controller's expansion socket. With no
## controller there is no socket and no VMU device, so the file was never going
## to be re-created whatever the option did. Deleting it measured nothing.
##
## It cannot be fixed by attaching one here either, which is the real finding:
## `WrapperEmuThread.cpp` applies pre-start port devices but deliberately SKIPS
## `RETRO_DEVICE_JOYPAD` ("plain joypad is what cores assume"). flycast is the
## exception — it takes its main maple device from
## `retro_set_controller_port_device`, so a port the frontend never announces
## stays empty. Crazy Taxi 2's memory-card screen says so directly: "The
## controller has been removed", and an empty socket 1 and 2 under port A.
## Attaching a pad AFTER load gets a controller drawn and still no sockets,
## because flycast builds its maple devices at load.
##
## So until the frontend announces a joypad at load, a Dreamcast in RetroXR has
## no controller and no VMU at all, and this question cannot be answered.
##
## **The first version of this probe could not have found that.** It swapped the
## file underneath the core and read it back, which reads as the swapped card
## whether the core re-read it or simply never wrote — and a game that is not
## saving never writes. Two outcomes that look identical is not a measurement.
## Deleting the file separates them: flycast's VMU device creates one when it
## finds none, so a re-created device brings the file back on its own and a
## core that ignored the option leaves it gone. No reading fits both.
##
## flycast's own log is NOT forwarded here — the run carries the frontend's lines
## and none of the core's — so do not expect to confirm this from maple chatter.
##
## It writes the player's REAL system directory and core options, because those
## paths are derived and cannot be pointed elsewhere. Both are snapshotted up
## front and restored on the way out, including on failure.
extends Node

const PORT_SLOT_KEY := "reicast_device_port1_slot1"

var rom := ""
var core := "flycast"
var seconds := 8.0

var _lib: Node = null
var _root := ""
var _vmu_path := ""
var _opt_path := ""
var _vmu_backup := PackedByteArray()
var _vmu_existed := false
var _opt_backup := PackedByteArray()
var _load_failed := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--rom="):
			rom = s.substr("--rom=".length())
		elif s.begins_with("--core="):
			core = s.substr("--core=".length())
		elif s.begins_with("--seconds="):
			seconds = maxf(2.0, float(s.substr("--seconds=".length())))
	get_tree().create_timer(seconds * 4.0 + 90.0).timeout.connect(func() -> void:
		print("[vmuprobe] TIMEOUT")
		_restore()
		get_tree().quit(1))

	_root = CoreDownloadManager.default_core_root()
	_vmu_path = _root.path_join("system/%s/dc/vmu_save_A1.bin" % core)
	_opt_path = _root.path_join("core_options/%s.opt" % core)

	if rom.is_empty() or not FileAccess.file_exists(rom):
		print("[vmuprobe] SKIP: pass --rom=<a Dreamcast disc>")
		get_tree().quit(2)
		return
	if CoreDownloadManager.installed_core_lib(core).is_empty():
		print("[vmuprobe] SKIP: core '%s' is not installed" % core)
		get_tree().quit(2)
		return

	_snapshot()
	await _measure()


# --- The player's own files, borrowed and put back ----------------------------

func _read(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	return b


func _write(path: String, data: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	return true


func _snapshot() -> void:
	_vmu_existed = FileAccess.file_exists(_vmu_path)
	if _vmu_existed:
		_vmu_backup = _read(_vmu_path)
	_opt_backup = _read(_opt_path)
	print("[vmuprobe] snapshot: vmu existed=%s (%d bytes), opt %d bytes"
		% [_vmu_existed, _vmu_backup.size(), _opt_backup.size()])


func _restore() -> void:
	if _vmu_existed:
		_write(_vmu_path, _vmu_backup)
	elif FileAccess.file_exists(_vmu_path):
		DirAccess.remove_absolute(_vmu_path)
	if not _opt_backup.is_empty():
		_write(_opt_path, _opt_backup)
	print("[vmuprobe] restored the player's VMU image and core options")


# --- A card we can recognise again --------------------------------------------

## A formatted card carrying one save whose name we choose, so that reading the
## file back says which card the core was holding.
func _card_named(save_name: String) -> PackedByteArray:
	var blank: PackedByteArray = VMUCard.blank_image()
	var body := PackedByteArray()
	body.resize(2 * VMUCard.BLOCK_SIZE)
	body.fill(0)
	# A DATA file, so its header is at the very start.
	for i in save_name.length():
		body[VMUCard.V_DESC + i] = save_name.unicode_at(i)
	body[VMUCard.V_ICONS] = 1

	var entry := PackedByteArray()
	entry.resize(VMUCard.DIR_ENTRY_SIZE)
	entry.fill(0)
	entry[VMUCard.E_TYPE] = VMUCard.TYPE_DATA
	for i in save_name.length():
		entry[VMUCard.E_NAME + i] = save_name.unicode_at(i)
	entry[VMUCard.E_BLOCKS] = 2
	entry[VMUCard.E_HDROFF] = 0

	var dci := entry.duplicate()
	dci.append_array(VMUCard._word_swap(body))
	var card: PackedByteArray = VMUCard.insert_save(blank, dci)
	return card if not card.is_empty() else blank


## What the file on disk currently calls its one save, or "<none>".
func _card_on_disk() -> String:
	var d := _read(_vmu_path)
	if not VMUCard.is_card_image(d):
		return "<not a card image, %d bytes>" % d.size()
	var saves: Array = VMUCard.list_saves(d, false)
	if saves.is_empty():
		return "<formatted, empty>"
	return str(saves[0]["name"])


func _wait(sec: float) -> void:
	var t0 := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t0) < int(sec * 1000.0):
		await get_tree().process_frame
		if not _load_failed.is_empty():
			return


# --- The measurement ----------------------------------------------------------

func _measure() -> void:
	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	if _lib == null:
		print("[vmuprobe] FAIL: could not instantiate Libretro node")
		_restore()
		get_tree().quit(1)
		return
	add_child(_lib)
	_lib.connect("content_load_failed", func(reason: String) -> void: _load_failed = reason)

	# (1) Stage a card the core has never seen, then boot.
	var staged := _card_named("PROBE_A")
	_write(_vmu_path, staged)
	print("[vmuprobe] PHASE stage-before-load: wrote a card holding '%s'" % _card_on_disk())
	print("[vmuprobe] path = %s" % _vmu_path)

	print("[vmuprobe] PHASE boot")
	_lib.StartContent(_root, core, rom)
	await _wait(seconds)
	if not _load_failed.is_empty():
		print("[vmuprobe] refused: %s" % _load_failed)
		_finish(false)
		return
	print("[vmuprobe] after boot, the file holds '%s'" % _card_on_disk())

	# (3) The decisive test, and it took two attempts to find one.
	#
	# Swapping the file underneath the core and reading it back proves nothing:
	# it reads as the swapped card whether the core re-read it or simply never
	# wrote, and a game that is not saving never writes. Two outcomes that look
	# identical is not a measurement.
	#
	# DELETING it separates them. flycast's VMU device creates its file when it
	# finds none, so if changing the slot option re-creates the maple device the
	# file comes back on its own; if nothing is re-created it stays gone. There
	# is no reading of the result that fits both.
	if FileAccess.file_exists(_vmu_path):
		DirAccess.remove_absolute(_vmu_path)
	print("[vmuprobe] PHASE deleted: file exists=%s" % FileAccess.file_exists(_vmu_path))

	await _wait(2.0)
	print("[vmuprobe] after 2s of running untouched, exists=%s"
		% FileAccess.file_exists(_vmu_path))

	print("[vmuprobe] PHASE toggle-off: %s = None" % PORT_SLOT_KEY)
	_lib.SetCoreOption(PORT_SLOT_KEY, "None")
	await _wait(2.0)
	print("[vmuprobe] after None, exists=%s" % FileAccess.file_exists(_vmu_path))

	print("[vmuprobe] PHASE toggle-on: %s = VMU" % PORT_SLOT_KEY)
	_lib.SetCoreOption(PORT_SLOT_KEY, "VMU")
	await _wait(3.0)
	var back := FileAccess.file_exists(_vmu_path)
	print("[vmuprobe] after VMU, exists=%s%s"
		% [back, ("  holding '%s'" % _card_on_disk()) if back else ""])

	await _wait(seconds)
	var settled := FileAccess.file_exists(_vmu_path)
	print("[vmuprobe] PHASE settled: exists=%s%s"
		% [settled, ("  holding '%s'" % _card_on_disk()) if settled else ""])
	print("[vmuprobe] VERDICT: the slot option %s re-create the maple device"
		% ("DOES" if settled else "does NOT"))
	_finish(true)


func _finish(ok: bool) -> void:
	if _lib != null and _lib.has_method("StopContent"):
		_lib.StopContent()
	await _wait(1.5)
	print("[vmuprobe] after stop, the file holds '%s'" % _card_on_disk())
	_restore()
	print("[vmuprobe] ---- %s ----" % ("done" if ok else "FAILED"))
	get_tree().quit(0 if ok else 1)

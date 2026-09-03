extends Node

## Does a Game Boy cartridge actually reach an N64 game through the Transfer Pak?
##
## Wants a real core and two real ROMs, so it is a probe, not a suite. One core
## per process, one pak value per process.
##
##     "$godot" --headless --path RetroXR res://Tools/cores/transferpak_probe.tscn -- \
##         --n64="Z:/roms/n64/Pokemon Stadium (USA).z64" \
##         --gb="Z:/roms/gb/Pokemon - Red Version (USA, Europe) (SGB Enhanced).gb" \
##         --pak=transfer --state=C:/tmp/red.state
##
## THE ORACLE IS THE SAVESTATE, not a log line. `savestates.c` writes, per port,
## the 28 bytes at offset 0x134 of the mounted Game Boy ROM — its header title,
## cartridge type and checksums — or 28 zero bytes when that port holds no cart:
##
##     if (dev->transferpaks[i].gb_cart == NULL) { ...28 zeros... }
##     else PUTARRAY(rom + 0x134, curr, uint8_t, 0x1c);
##
## So a run with --pak=none and a run with a cartridge differ at one fixed offset
## in the state, and two different cartridges differ from each other there. That
## cannot pass by accident: the bytes come from the file the core opened.
##
## The core's own `Inserting GB cart <title> into transferpak 0` is RETRO_LOG_INFO
## and LogHandler's floor is RETRO_LOG_WARN, so it never reaches stdout here —
## which is why this probe does not try to read it.

const CORE := "mupen64plus_next"

var _lib: Libretro
var _frames := 0
var _target := 900
var _n64 := ""
var _gb := ""
var _pak := "transfer"
var _state_path := ""
var _pak_key := ""
var _leg := "subsystem"
var _asked := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--n64="):
			_n64 = s.substr(6)
		elif s.begins_with("--gb="):
			_gb = s.substr(5)
		elif s.begins_with("--pak="):
			_pak = s.substr(6)
		elif s.begins_with("--state="):
			_state_path = s.substr(8)
		elif s.begins_with("--leg="):
			_leg = s.substr(6)
		elif s.begins_with("--frames="):
			_target = int(s.substr(9))

	if _n64.is_empty() or _gb.is_empty():
		print("[tpak] FAIL need --n64=<rom> --gb=<rom>")
		get_tree().quit(2)
		return
	print("[tpak] n64   %s" % _n64)
	print("[tpak] gb    %s" % _gb)
	print("[tpak] pak   %s" % _pak)
	print("[tpak] leg   %s" % _leg)
	print("[tpak] state %s" % _state_path)

	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("[tpak] FAIL timeout")
		get_tree().quit(1))

	_lib = Libretro.new()
	add_child(_lib)
	_lib.options_ready.connect(_on_options_ready)
	_lib.savestate_ready.connect(_on_savestate_ready)
	_lib.content_load_failed.connect(func(reason: String) -> void:
		print("[tpak] FAIL content_load_failed %s" % reason)
		get_tree().quit(1))

	var root := CoreDownloadManager.default_core_root()
	print("[tpak] core root %s" % root)

	# Slot order is the core's: GB save, GB ROM, then the N64 cartridge LAST —
	# the reverse of the Super Game Boy pairing. The core only strdups slots 0
	# and 1, but the WRAPPER refuses a load whose every declared slot does not
	# exist on disk, so the save has to be there before the call. Keyed to the
	# cartridge, so the two Pokemon runs cannot share a battery.
	var save := "%s/save/%s/%s.sav" % [root, CORE, _gb.get_file().get_basename()]
	DirAccess.make_dir_recursive_absolute("%s/save/%s" % [root, CORE])
	if not FileAccess.file_exists(save):
		var blank := PackedByteArray()
		blank.resize(0x8000)   # Pokemon is MBC3 with 32 KiB of battery RAM
		var f := FileAccess.open(save, FileAccess.WRITE)
		f.store_buffer(blank)
		f.close()
		print("[tpak] made GB save %s" % save)

	if _leg == "plain":
		# The structural control: no Game Boy cartridge reaches the core at all,
		# so every port's fingerprint slot must be 28 zeros. Without this leg the
		# offset could be any 28 bytes that happen to hold the title.
		print("[tpak] StartContent (no GB cart)")
		_lib.StartContent(root, CORE, _n64)
	else:
		print("[tpak] StartSubsystemContent ident=gb")
		_lib.StartSubsystemContent(root, CORE, _n64, "gb", PackedStringArray([save, _gb, _n64]))


func _on_options_ready(_categories: Dictionary, definitions: Dictionary, current: Dictionary) -> void:
	# Find the pak option the way RetroSystem does — by SUFFIX, never composed:
	# this core's prefix is whatever CORE_NAME it was built with.
	for key: String in definitions:
		if key.ends_with("-pak1"):
			_pak_key = key
			break
	if _pak_key.is_empty():
		print("[tpak] FAIL no -pak1 option published by this core")
		get_tree().quit(1)
		return
	print("[tpak] pak option key %s (was %s)" % [_pak_key, current.get(_pak_key, "<unset>")])
	for p in range(2, 5):
		for key: String in definitions:
			if key.ends_with("-pak%d" % p):
				print("[tpak] port %d %s = %s" % [p, key, current.get(key, "<unset>")])
	_lib.SetCoreOption(_pak_key, _pak)
	print("[tpak] set %s = %s" % [_pak_key, _pak])


func _on_savestate_ready(data: PackedByteArray, frame: int) -> void:
	print("[tpak] savestate %d bytes at frame %d" % [data.size(), frame])
	if not _state_path.is_empty():
		var f := FileAccess.open(_state_path, FileAccess.WRITE)
		if f == null:
			print("[tpak] FAIL cannot write %s" % _state_path)
		else:
			f.store_buffer(data)
			f.close()
			print("[tpak] wrote %s" % _state_path)

	var want := _cart_fingerprint()
	if want.is_empty():
		print("[tpak] FAIL cannot read %s" % _gb)
		_finish(1)
		return
	var hits := _find_all(data, want)
	print("[tpak] fingerprint %s x%d %s" % [want.slice(0, 16).get_string_from_ascii(), hits.size(), hits])

	# One port per hit. The stock core drives every transferpak off one pair of
	# globals, so the subsystem leg mounts the cartridge in all four; a per-port
	# media loader would put it in one. Either is a pass — what must not happen
	# is ZERO, and the plain leg must not find it at all.
	var ok := hits.is_empty() if _leg == "plain" else not hits.is_empty()
	print("[tpak] %s (leg=%s pak=%s)" % ["PASS" if ok else "FAIL", _leg, _pak])
	_finish(0 if ok else 1)


## The 28 bytes savestates.c copies out of a mounted cartridge — title, type,
## sizes and checksums. Reading them from the file is what makes the check able
## to fail: no other cartridge produces this string.
func _cart_fingerprint() -> PackedByteArray:
	var f := FileAccess.open(_gb, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	f.seek(0x134)
	var b := f.get_buffer(0x1c)
	f.close()
	return b if b.size() == 0x1c else PackedByteArray()


func _find_all(haystack: PackedByteArray, needle: PackedByteArray) -> PackedInt64Array:
	var out := PackedInt64Array()
	var at := 0
	while true:
		var i := haystack.find(needle[0], at)
		if i < 0 or i + needle.size() > haystack.size():
			break
		if haystack.slice(i, i + needle.size()) == needle:
			out.append(i)
			at = i + needle.size()
		else:
			at = i + 1
	return out


func _finish(code: int) -> void:
	_lib.StopContent()
	get_tree().create_timer(1.0).timeout.connect(func() -> void: get_tree().quit(code))


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 1:
		print("[tpak] running")
	if _frames == _target and not _asked:
		_asked = true
		print("[tpak] identity %s" % _lib.GetCoreIdentity())
		print("[tpak] core frames %d" % _lib.GetFrameCount())
		_lib.RequestSaveState()

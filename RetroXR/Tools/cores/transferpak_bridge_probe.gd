extends Node

## Does SetTransferPak actually put a DIFFERENT Game Boy cartridge in each
## controller's pak?
##
## This is the one thing the stock routes cannot do. The `gb` subsystem and the
## <rom>.gb sidecar both set retro_transferpak_{rom,ram}_path -- ONE pair of
## globals shared by all four ports -- so under them every pak holds the same
## cartridge and a per-port bug is invisible. This probe uses neither: it plain-
## loads the N64 ROM and answers the core's per-port question through
## RETRO_ENVIRONMENT_GET_TRANSFER_PAK_INTERFACE.
##
##     "$godot" --headless --path RetroXR res://Tools/cores/transferpak_bridge_probe.tscn -- \
##         --n64="Z:/roms/n64/Pokemon Stadium (USA).z64" \
##         --gb1="Z:/roms/gb/Pokemon - Red Version (USA, Europe) (SGB Enhanced).gb" \
##         --gb2="Z:/roms/gb/Pokemon - Blue Version (USA, Europe) (SGB Enhanced).gb"
##
## THE ORACLE IS THE SAVESTATE. savestates.c writes, per port, the 28 bytes at
## offset 0x134 of that port's mounted Game Boy ROM -- its header title, cart
## type and checksums -- or 28 zeros for a port holding no cart. So TWO
## different cartridges must produce TWO different fingerprints in one state.
## Red alone, or Red twice, is a fail: that is exactly what the shared globals
## would give, and it is the bug this interface exists to fix.

const CORE := "mupen64plus_next"

var _lib: Libretro
var _frames := 0
var _target := 900
var _n64 := ""
var _gb1 := ""
var _gb2 := ""
var _state_path := ""
var _asked := false
var _keys: Array[String] = []
## How many ports to fill. Two is the real test -- one cartridge per port is
## what the shared globals cannot do -- but one isolates a core that cannot
## survive a second pak at all.
var _ports := 2
var _saw_core := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--n64="):
			_n64 = s.substr(6)
		elif s.begins_with("--gb1="):
			_gb1 = s.substr(6)
		elif s.begins_with("--gb2="):
			_gb2 = s.substr(6)
		elif s.begins_with("--state="):
			_state_path = s.substr(8)
		elif s.begins_with("--ports="):
			_ports = int(s.substr(8))
		elif s.begins_with("--frames="):
			_target = int(s.substr(9))

	if _n64.is_empty() or _gb1.is_empty() or _gb2.is_empty():
		print("[tpb] FAIL need --n64 --gb1 --gb2")
		get_tree().quit(2)
		return
	print("[tpb] n64 %s" % _n64)
	print("[tpb] gb1 %s" % _gb1)
	print("[tpb] gb2 %s" % _gb2)

	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[tpb] FAIL timeout")
		get_tree().quit(1))

	_lib = Libretro.new()
	add_child(_lib)
	_lib.options_ready.connect(_on_options_ready)
	_lib.savestate_ready.connect(_on_savestate_ready)
	_lib.content_load_failed.connect(func(reason: String) -> void:
		print("[tpb] FAIL content_load_failed %s" % reason)
		get_tree().quit(1))

	if not _lib.has_method("SetTransferPak"):
		print("[tpb] FAIL this build has no SetTransferPak -- the bridge is missing")
		get_tree().quit(1)
		return

	var root := CoreDownloadManager.default_core_root()
	var sav_dir := "%s/save/%s" % [root, CORE]
	DirAccess.make_dir_recursive_absolute(sav_dir)

	# Answer for two ports, with two DIFFERENT cartridges. Set before the load,
	# so the table is already populated when the core first asks.
	_lib.SetTransferPak(0, _gb1, "%s/%s.sav" % [sav_dir, _gb1.get_file().get_basename()])
	if _ports > 1:
		_lib.SetTransferPak(1, _gb2, "%s/%s.sav" % [sav_dir, _gb2.get_file().get_basename()])
	print("[tpb] ports=%d" % _ports)
	print("[tpb] SetTransferPak port0=%s" % _gb1.get_file())
	if _ports > 1:
		print("[tpb] SetTransferPak port1=%s" % _gb2.get_file())

	# PLAIN load. No subsystem, no sidecar -- so the globals stay empty and the
	# only way a cartridge reaches a pak is the interface.
	print("[tpb] StartContent (plain, no subsystem)")
	_lib.StartContent(root, CORE, _n64)


func _on_options_ready(_categories: Dictionary, definitions: Dictionary, current: Dictionary) -> void:
	# By SUFFIX, never composed: the prefix is whatever CORE_NAME this core was
	# built with.
	for p in range(1, 5):
		for key: String in definitions:
			if key.ends_with("-pak%d" % p):
				_keys.append(key)
				break
	if _keys.size() < 2:
		print("[tpb] FAIL core published fewer than two pak options")
		get_tree().quit(1)
		return
	for i in _ports:
		_lib.SetCoreOption(_keys[i], "transfer")
		print("[tpb] %s = transfer (was %s)" % [_keys[i], current.get(_keys[i], "<unset>")])


func _on_savestate_ready(data: PackedByteArray, frame: int) -> void:
	print("[tpb] savestate %d bytes at frame %d" % [data.size(), frame])
	if not _state_path.is_empty():
		var f := FileAccess.open(_state_path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(data)
			f.close()

	var fp1 := _fingerprint(_gb1)
	var fp2 := _fingerprint(_gb2)
	if fp1.is_empty() or fp2.is_empty():
		print("[tpb] FAIL cannot read one of the cartridges")
		_finish(1)
		return
	if fp1 == fp2:
		print("[tpb] FAIL the two cartridges are identical -- this proves nothing")
		_finish(1)
		return

	var h1 := _find_all(data, fp1)
	var h2 := _find_all(data, fp2)
	print("[tpb] gb1 '%s' x%d %s" % [fp1.slice(0, 11).get_string_from_ascii(), h1.size(), h1])
	print("[tpb] gb2 '%s' x%d %s" % [fp2.slice(0, 11).get_string_from_ascii(), h2.size(), h2])

	# Both present is the whole point: one cartridge in one pak, a DIFFERENT one
	# in another, in the same state. Impossible through the shared globals.
	var ok := not h1.is_empty() if _ports == 1 else (not h1.is_empty() and not h2.is_empty())
	print("[tpb] %s" % ("PASS both ports carry their own cartridge" if ok
		else "FAIL per-port media did not reach the core"))
	_finish(0 if ok else 1)


func _fingerprint(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	f.seek(0x134)
	var b := f.get_buffer(0x1c)
	f.close()
	return b if b.size() == 0x1c else PackedByteArray()


func _find_all(hay: PackedByteArray, needle: PackedByteArray) -> PackedInt64Array:
	var out := PackedInt64Array()
	var at := 0
	while true:
		var i := hay.find(needle[0], at)
		if i < 0 or i + needle.size() > hay.size():
			break
		if hay.slice(i, i + needle.size()) == needle:
			out.append(i)
			at = i + needle.size()
		else:
			at = i + 1
	return out


func _finish(code: int) -> void:
	_lib.StopContent()
	get_tree().create_timer(1.0).timeout.connect(func() -> void: get_tree().quit(code))


## Gate on the CORE's frame count, never on this scene's. Headless Godot runs
## _process as fast as it can, so 900 of these elapse in a couple of seconds --
## long before StartContent has even finished bringing the core up, which is
## asynchronous. Counting them asked for a savestate from a core that had run
## nothing and got 0 bytes back.
func _process(_d: float) -> void:
	_frames += 1
	if _frames == 1:
		print("[tpb] running")
	if _asked or _lib == null:
		return
	var cf: int = _lib.GetFrameCount()
	if cf > 0 and not _saw_core:
		_saw_core = true
		print("[tpb] core came up after %d scene frames" % _frames)
	if cf >= _target:
		_asked = true
		print("[tpb] core frames %d" % cf)
		_lib.RequestSaveState()

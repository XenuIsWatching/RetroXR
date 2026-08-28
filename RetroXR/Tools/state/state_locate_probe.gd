## WHICH memory does a savestate load fail to put back?
##
##   "$godot" --headless --path RetroXR res://Tools/state/state_locate_probe.tscn -- \
##       --core=gambatte "--rom=C:/path/rom.gb" [--opt=key=value] [--frame=300]
##
## Snapshot the exact bytes the netplay CRC hashes, save a state, load it back,
## snapshot again, and report every difference BY GUEST ADDRESS.
##
## This is the tool that ends an argument. netplay_spike says two runs diverged;
## state_roundtrip_probe says the state's own bytes differ; neither says which
## memory the frontend is actually watching went wrong. On mGBA this took a
## constant CRC XOR across 1200 frames down to one byte at 0x04000134 in a
## single run, after three wrong diagnoses from reading source.
##
## It reports what a load did NOT restore, which is not the same question as
## whether the core is deterministic — a region the core never serializes at
## all shows up here and not in state_roundtrip_probe.
extends Node

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

var root_dir := _home + "/retroxr/libretro"
var core := "gambatte"
var rom := ""
var at_frame := 300

var _lib: Node = null
var _phase := "run"
var _before: Dictionary = {}
var _feed := 0
var _opts: Dictionary = {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--core="):
			core = a.trim_prefix("--core=")
		elif a.begins_with("--rom="):
			rom = a.trim_prefix("--rom=")
		elif a.begins_with("--root="):
			root_dir = a.trim_prefix("--root=")
		elif a.begins_with("--frame="):
			at_frame = int(a.trim_prefix("--frame="))
		elif a.begins_with("--opt="):
			var kv := a.trim_prefix("--opt=").split("=", true, 1)
			if kv.size() == 2:
				_opts[kv[0]] = kv[1]
	if rom.is_empty():
		print("[loc] need --rom=")
		get_tree().quit(2)
		return
	get_tree().create_timer(400.0).timeout.connect(func() -> void:
		print("[loc] TIMEOUT")
		get_tree().quit(2))
	var o: Object = ClassDB.instantiate("Libretro")
	_lib = o as Node
	add_child(_lib)
	if not _lib.has_method("SnapshotMappedRam"):
		print("[loc] the extension has no SnapshotMappedRam; rebuild it")
		get_tree().quit(2)
		return
	_lib.savestate_ready.connect(_on_saved)
	_lib.savestate_loaded.connect(_on_loaded)
	for k: Variant in _opts:
		_lib.SetCoreOption(str(k), str(_opts[k]))
	# Gated, so the core can be PARKED before each snapshot: reading core memory
	# from this thread races an emulation thread that is still running.
	_lib.SetNetplayMode(true, 0x1, 0)
	_lib.StartContent(root_dir, core, rom)
	print("[loc] %s / %s" % [core, rom.get_file()])


func _process(_d: float) -> void:
	if _lib == null or _phase != "run":
		return
	var cur: int = _lib.GetFrameCount()
	# Only two frames of slack, so "parked" means parked.
	while _feed < cur + 2:
		var a := PackedInt32Array()
		a.resize(35)
		_lib.PostNetplayInputs(_feed, a)
		_feed += 1
	if cur >= at_frame:
		_phase = "wait"
		await get_tree().create_timer(1.5).timeout
		_before = _lib.SnapshotMappedRam()
		print("[loc] snapshot: %d bytes over %d regions at frame %d" % [
			(_before["data"] as PackedByteArray).size(),
			(_before["regions"] as Array).size(), _lib.GetFrameCount()])
		_lib.RequestSaveState()


func _on_saved(data: PackedByteArray, frame: int) -> void:
	print("[loc] state %d bytes at frame %d" % [data.size(), frame])
	_lib.RequestLoadState(data, frame)


func _on_loaded(ok: bool) -> void:
	await get_tree().create_timer(1.5).timeout
	var after: Dictionary = _lib.SnapshotMappedRam()
	var a: PackedByteArray = _before["data"]
	var b: PackedByteArray = after["data"]
	print("[loc] load ok=%s" % ok)
	if a.size() != b.size():
		print("[loc] region layout changed across the load; cannot compare")
		get_tree().quit(1)
		return
	var total := 0
	for r: Dictionary in (_before["regions"] as Array):
		var off := int(r["offset"])
		var ln := int(r["len"])
		var start := int(r["start"])
		var n := 0
		var shown := 0
		for i in range(off, off + ln):
			if a[i] != b[i]:
				n += 1
				total += 1
				if shown < 12:
					print("[loc]   guest 0x%08X: %02X -> %02X" % [start + (i - off), a[i], b[i]])
					shown += 1
		print("[loc] %-8s 0x%08X len %-8d : %d differing byte(s)" % [
			"DIFFERS" if n > 0 else "same", start, ln, n])
	print("[loc] TOTAL %d differing byte(s)" % total)
	_lib.StopContent()
	await get_tree().create_timer(2.0).timeout
	get_tree().quit(0 if total == 0 else 1)

## WHERE does a rewind put the machine somewhere else?
##
##   "$godot" --headless --path RetroXR res://Tools/netplay/rewind_probe.tscn -- \
##       --core=gambatte "--rom=C:/path/rom.gb" [--opt=key=value] \
##       [--from=100] [--to=1200] [--depth=4]
##
## Rollback is save -> run -> rewind -> replay, thousands of times a session.
## netplay_spike proves a run against a run; this proves the ONE rewind, at
## every anchor in a range: save at f, run `depth` frames and keep their CRCs,
## load that state back, run the same `depth` frames again, compare.
##
## A core that passes here can be rolled back. A core that fails names the
## anchor frame it fails at, which is the thing a single mid-run reload cannot
## find -- gambatte survives 164 rewinds and loses a frame on one of them.
##
## The report says HOW a mismatch failed. `slip` means the replay's CRC at
## frame n is the first pass's at n+1 (or n-1): the machine is a whole frame
## out, which is a pacing or frame-boundary fault rather than corrupted memory.
## `differs` means the bytes genuinely disagree.
extends Node

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

var root_dir := _home + "/retroxr/libretro"
var core := "gambatte"
var rom := ""
var from_frame := 100
var to_frame := 1200
var depth := 4
var _opts: Dictionary = {}

var _lib: Node = null
var _phase := "warmup"          # warmup -> pass1 -> reloading -> pass2
var _anchor := -1
var _state := PackedByteArray()
var _pass1: Dictionary = {}
var _pass2: Dictionary = {}
var _crcs: Dictionary = {}      # every CRC of pass 1, for the slip test
var _feed := 0
var _anchors := 0
var _bad := 0
var _done := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--core="):
			core = a.trim_prefix("--core=")
		elif a.begins_with("--rom="):
			rom = a.trim_prefix("--rom=")
		elif a.begins_with("--root="):
			root_dir = a.trim_prefix("--root=")
		elif a.begins_with("--from="):
			from_frame = int(a.trim_prefix("--from="))
		elif a.begins_with("--to="):
			to_frame = int(a.trim_prefix("--to="))
		elif a.begins_with("--depth="):
			depth = int(a.trim_prefix("--depth="))
		elif a.begins_with("--opt="):
			var kv := a.trim_prefix("--opt=").split("=", true, 1)
			if kv.size() == 2:
				_opts[kv[0]] = kv[1]
	if rom.is_empty():
		print("[rewind] RESULT=FAIL (no --rom)")
		get_tree().quit(2)
		return
	get_tree().create_timer(900.0).timeout.connect(func() -> void:
		print("[rewind] TIMEOUT at anchor %d phase %s" % [_anchor, _phase])
		get_tree().quit(2))
	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	add_child(_lib)
	_lib.connect("netplay_crc", _on_crc)
	_lib.connect("savestate_ready", _on_state_ready)
	_lib.connect("savestate_loaded", _on_state_loaded)
	_lib.SetNetplayMode(true, 0x1, 0)
	_lib.SetNetplayCrcInterval(1)
	for k: Variant in _opts:
		_lib.SetCoreOption(str(k), str(_opts[k]))
	_lib.StartContent(root_dir, core, rom)
	print("[rewind] %s / %s — anchors %d..%d, depth %d"
		% [core, rom.get_file(), from_frame, to_frame, depth])


## The same scripted timeline the spike uses: a pure function of the frame, so
## a replayed frame is fed exactly what it was fed the first time.
func _input_for_frame(f: int) -> int:
	var btn := 0
	if (f >= 180 and f < 195) or (f >= 300 and f < 320):
		btn |= 1 << 3
	if f >= 400:
		btn |= 1 << 7
		if (f % 90) < 25:
			btn |= 1 << 8
		if (f % 51) < 10:
			btn |= 1 << 0
	return btn


func _flat(f: int) -> PackedInt32Array:
	var arr := PackedInt32Array()
	arr.resize(20)
	arr[0] = _input_for_frame(f)
	return arr


func _process(_delta: float) -> void:
	if _done or _lib == null or _phase == "reloading":
		return
	var cur: int = _lib.GetFrameCount()
	while _feed < cur + 90:
		_lib.PostNetplayInputs(_feed, _flat(_feed))
		_feed += 1
	if _phase == "warmup":
		if cur >= from_frame:
			_phase = "saving"
			_lib.RequestSaveState()
	elif _phase == "pass1" and cur >= _anchor + depth:
		_phase = "reloading"
		_lib.RequestLoadState(_state, _anchor)
	elif _phase == "pass2" and cur >= _anchor + depth:
		_compare()


func _on_crc(frame: int, crc: int) -> void:
	if _phase == "pass1":
		_pass1[frame] = crc
		_crcs[frame] = crc
	elif _phase == "pass2":
		_pass2[frame] = crc


func _on_state_ready(data: PackedByteArray, frame: int) -> void:
	if data.is_empty():
		print("[rewind] RESULT=FAIL (core has no savestate support)")
		_done = true
		get_tree().quit(1)
		return
	_state = data
	_anchor = frame
	_pass1.clear()
	_pass2.clear()
	_phase = "pass1"


func _on_state_loaded(ok: bool) -> void:
	if not ok:
		print("[rewind] anchor %d: unserialize FAILED" % _anchor)
		_bad += 1
		_done = true
		get_tree().quit(1)
		return
	_feed = _anchor
	_phase = "pass2"


func _compare() -> void:
	_anchors += 1
	var verdict := ""
	for f: int in range(_anchor + 1, _anchor + depth + 1):
		if not _pass1.has(f) or not _pass2.has(f):
			continue
		if _pass1[f] == _pass2[f]:
			continue
		# A whole frame out reads as the neighbouring checkpoint, which is a
		# different fault from memory coming back wrong.
		if _crcs.get(f + 1, -1) == _pass2[f]:
			verdict = "slip +1 at frame %d" % f
		elif _crcs.get(f - 1, -1) == _pass2[f]:
			verdict = "slip -1 at frame %d" % f
		else:
			verdict = "differs at frame %d (%08x vs %08x)" % [f, _pass1[f], _pass2[f]]
		break
	if not verdict.is_empty():
		_bad += 1
		print("[rewind] anchor %d: %s" % [_anchor, verdict])
	if _anchor + depth >= to_frame:
		print("[rewind] %d anchors, %d bad" % [_anchors, _bad])
		print("[rewind] RESULT=%s" % ("PASS" if _bad == 0 else "FAIL"))
		_done = true
		_lib.StopContent()
		get_tree().create_timer(1.0).timeout.connect(func() -> void: get_tree().quit(1 if _bad else 0))
		return
	_phase = "saving"
	_lib.RequestSaveState()

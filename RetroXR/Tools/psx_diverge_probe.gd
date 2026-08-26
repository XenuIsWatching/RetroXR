## WHICH guest memory diverges after a state load, once the drift has developed?
##
##   "$godot" --headless --path RetroXR res://Tools/psx_diverge_probe.tscn -- \
##       --core=pcsx_rearmed "--rom=Z:/roms/psx/Crash Bandicoot (USA).cue" \
##       --save-at=600 --check-at=700
##
## state_locate_probe answers a different question: what a load fails to put
## back AT THE INSTANT it lands. For pcsx_rearmed that answer is "nothing" --
## all 2.6 MB of RAM, scratchpad and BIOS come back byte-identical -- and yet
## the replay diverges within ten frames. So the fault is in state that is not
## in the memory map at all, and the only way to see it is to let the machine
## RUN and watch where the difference first surfaces.
##
## Phase A runs straight through and snapshots at check_at. Phase B loads the
## state taken at save_at and runs to the same frame. Any address that differs
## is guest memory the re-derived subsystem state has already contaminated, and
## WHICH address it is usually names the subsystem.
extends Node3D

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

var root_dir := _home + "/retroxr/libretro"
var core := "pcsx_rearmed"
var rom := ""
var save_at := 600
var check_at := 700

var _lib: Node = null
var _phase := "A"
var _feed := 0
var _state := PackedByteArray()
var _state_frame := -1
var _ref: Dictionary = {}
var _ref_frame := -1
var _opts: Dictionary = {}
## Drive the pad, unless asked not to. An idle machine replays almost perfectly
## whatever is broken underneath it, so zeros here would make this probe green
## against faults netplay_spike catches 180 frames after the save.
var idle := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--core="):
			core = a.trim_prefix("--core=")
		elif a.begins_with("--rom="):
			rom = a.trim_prefix("--rom=")
		elif a.begins_with("--save-at="):
			save_at = int(a.trim_prefix("--save-at="))
		elif a.begins_with("--check-at="):
			check_at = int(a.trim_prefix("--check-at="))
		elif a == "--idle":
			idle = true
		elif a.begins_with("--opt="):
			var kv := a.trim_prefix("--opt=").split("=", true, 1)
			if kv.size() == 2:
				_opts[kv[0]] = kv[1]
	if rom.is_empty():
		print("[div] need --rom=")
		get_tree().quit(2)
		return
	get_tree().create_timer(900.0).timeout.connect(func() -> void:
		print("[div] TIMEOUT phase=%s" % _phase)
		get_tree().quit(2))
	var o: Object = ClassDB.instantiate("Libretro")
	_lib = o as Node
	add_child(_lib)
	_lib.savestate_ready.connect(_on_saved)
	_lib.savestate_loaded.connect(_on_loaded)
	# Gated so the core can be PARKED for a snapshot: reading core memory from
	# this thread races an emulation thread that is still running.
	_lib.SetNetplayMode(true, 0x1, 0)
	for k: Variant in _opts:
		_lib.SetCoreOption(str(k), str(_opts[k]))
		print("[div] option %s = %s" % [str(k), str(_opts[k])])
	_lib.StartContent(root_dir, core, rom)
	print("[div] %s / %s  save@%d check@%d" % [core, rom.get_file(), save_at, check_at])


## netplay_spike's timeline, verbatim. The two probes have to drive the same
## machine or a mismatch there cannot be localised by an address here.
func _input_for_frame(f: int) -> int:
	if idle:
		return 0
	var btn := 0
	if (f >= 180 and f < 195) or (f >= 300 and f < 320):
		btn |= 1 << 3          # START
	if f >= 400:
		btn |= 1 << 7          # RIGHT
		if (f % 90) < 25:
			btn |= 1 << 8      # A
		if (f % 51) < 10:
			btn |= 1 << 0      # B
	return btn


func _process(_d: float) -> void:
	if _lib == null or _phase.ends_with("_wait"):
		return
	var cur: int = _lib.GetFrameCount()
	while _feed < cur + 40:
		var a := PackedInt32Array()
		a.resize(20)
		a[0] = _input_for_frame(_feed)
		_lib.PostNetplayInputs(_feed, a)
		_feed += 1
	if _phase == "A" and cur >= save_at and _state.is_empty():
		_phase = "A_wait"
		_lib.RequestSaveState()
	elif _phase == "A2" and cur >= check_at:
		_phase = "A2_wait"
		await get_tree().create_timer(1.5).timeout
		_ref = _lib.SnapshotMappedRam()
		_ref_frame = int(_lib.GetFrameCount())
		print("[div] phase A snapshot at frame %d" % _ref_frame)
		_phase = "B_wait"
		_lib.RequestLoadState(_state, _state_frame)
	elif _phase == "B" and cur >= check_at:
		_phase = "B_wait"
		await get_tree().create_timer(1.5).timeout
		_compare(_lib.SnapshotMappedRam())


func _on_saved(data: PackedByteArray, frame: int) -> void:
	_state = data
	_state_frame = frame
	print("[div] state %d bytes at frame %d" % [data.size(), frame])
	_phase = "A2"


func _on_loaded(ok: bool) -> void:
	print("[div] load ok=%s — replaying to %d" % [ok, check_at])
	_feed = _state_frame
	_phase = "B"


func _compare(after: Dictionary) -> void:
	# Both snapshots MUST be at the same emulated frame. The core is gated and
	# parks after consuming its feed lead, so both phases stop at the same
	# place -- but a comparison across two different frames would report the
	# game's own progress as a divergence, which is a green light for a bug.
	var b_frame := int(_lib.GetFrameCount())
	print("[div] phase B snapshot at frame %d (A was %d)" % [b_frame, _ref_frame])
	if b_frame != _ref_frame:
		print("[div] FRAMES DIFFER — comparison is meaningless, aborting")
		get_tree().quit(2)
		return
	var a: PackedByteArray = _ref["data"]
	var b: PackedByteArray = after["data"]
	if a.size() != b.size():
		print("[div] region layout changed; cannot compare")
		get_tree().quit(1)
		return
	var total := 0
	for r: Dictionary in (_ref["regions"] as Array):
		var off := int(r["offset"])
		var ln := int(r["len"])
		var start := int(r["start"])
		var n := 0
		var shown := 0
		for i in range(off, off + ln):
			if a[i] != b[i]:
				n += 1
				total += 1
				if shown < 16:
					print("[div]   guest 0x%08X: %02X -> %02X" % [start + (i - off), a[i], b[i]])
					shown += 1
		print("[div] %-8s 0x%08X len %-8d : %d differing byte(s)" % [
			"DIFFERS" if n > 0 else "same", start, ln, n])
	print("[div] TOTAL %d differing byte(s) at frame %d" % [total, check_at])
	_lib.StopContent()
	await get_tree().create_timer(2.0).timeout
	get_tree().quit(0)

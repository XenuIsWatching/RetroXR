extends Node
## Does this core's savestate ROUND-TRIP? save -> load -> save, no frames run.
##
##   "$godot" --headless --path RetroXR res://Tools/state/state_roundtrip_probe.tscn -- ##       --core=fceumm "--rom=C:/path/rom.nes"
##
## A precondition for netplay, and much cheaper and sharper than the full
## netplay_spike: if a core cannot reproduce its own state with NOTHING run in
## between, no amount of determinism elsewhere will save a late join or a desync
## resync, and the spike's RAM-CRC oracle cannot tell that apart from the
## emulation drifting.
##
## Run it against fceumm first. A core that passes the spike must round-trip
## here, so a red fceumm means the probe is wrong, not the core.
##
## FINDINGS 2026-08-21. fceumm: exact. dolphin (retroxr.0.dolphin+2e3ff4a20f,
## Four Swords Adventures): 196608 bytes differ and EVERY ONE is the exact
## bitwise complement of its counterpart - 65536 uniform 3-byte fields on a
## 4-byte stride, all 000080 -> ffff7f, inside a repeating 2436-byte record.
## A single value before and a single value after is a table being re-derived
## with inverted polarity on load, not emulated data drifting. Plus two
## save-counters (27->28, 42->43), which are benign.
##
## If a core's serialization round-trips, the second blob is byte-identical to
## the first: nothing advanced, so nothing may differ. A difference localises
## the fault to serialize/unserialize rather than to emulation, which the CRC
## oracle alone cannot tell apart.
var _lib: Node = null
var _phase := "run"
var _s1 := PackedByteArray()
var _core := "dolphin"
var _rom := ""

func _ready() -> void:
	var home := OS.get_environment("USERPROFILE").replace("\\", "/")
	_rom = home + "/retroxr/roms/gamecube/Legend of Zelda, The - Four Swords Adventures (USA).rvz"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--core="): _core = a.trim_prefix("--core=")
		elif a.begins_with("--rom="): _rom = a.trim_prefix("--rom=")
		elif a.begins_with("--lookahead="): _lookahead = int(a.trim_prefix("--lookahead="))
	get_tree().create_timer(300.0).timeout.connect(func(): print("[rt] TIMEOUT"); get_tree().quit(2))
	var o: Object = ClassDB.instantiate("Libretro")
	_lib = o as Node
	add_child(_lib)
	_lib.savestate_ready.connect(_on_saved)
	_lib.savestate_loaded.connect(_on_loaded)
	_lib.SetNetplayMode(true, 0x1, 0)
	_lib.StartContent(home + "/retroxr/libretro", _core, _rom)
	print("[rt] %s / %s" % [_core, _rom.get_file()])

var _feed := 0
## How far the gate is fed past the current frame. This is not a speed knob: it
## is how far the core RUNS between the save and the load, and a field the
## deserializer fails to overwrite keeps its advanced value. Widen it and an
## unrestored counter's delta grows with it; a properly restored field stays
## identical however wide it is.
var _lookahead := 90
func _process(_d: float) -> void:
	if _lib == null or _phase == "wait": return
	var cur: int = _lib.GetFrameCount()
	while _feed < cur + _lookahead:
		var arr := PackedInt32Array(); arr.resize(35)
		_lib.PostNetplayInputs(_feed, arr); _feed += 1
	if _phase == "run" and cur >= 300:
		_phase = "wait"; _lib.RequestSaveState()

func _on_saved(data: PackedByteArray, frame: int) -> void:
	if _s1.is_empty():
		_s1 = data
		print("[rt] S1 %d bytes at frame %d" % [data.size(), frame])
		_phase = "wait"
		_lib.RequestLoadState(_s1, frame)
		return
	# S2, taken immediately after loading S1 with nothing run in between.
	print("[rt] S2 %d bytes at frame %d" % [data.size(), frame])
	if data.size() != _s1.size():
		print("[rt] VERDICT: sizes differ (%d vs %d) — serialization is not stable" % [_s1.size(), data.size()])
	else:
		var diff := 0
		var first := -1
		var last := -1
		var runs := 0
		var prev := false
		for i in range(data.size()):
			var d: bool = data[i] != _s1[i]
			if d:
				diff += 1
				if first < 0: first = i
				last = i
				if not prev: runs += 1
			prev = d
		print("[rt] %d of %d bytes differ (%.4f%%), %d run(s), first @%d last @%d" % [
			diff, data.size(), 100.0 * diff / data.size(), runs, first, last])
		if diff == 0:
			print("[rt] VERDICT: serialization round-trips exactly")
		else:
			print("[rt] VERDICT: save->load->save is NOT stable")
			# A complement is a POLARITY fault in one field, not corruption:
			# it says a value is being re-derived rather than restored, and
			# that is a far more findable bug than "some bytes changed".
			var complemented := 0
			for i in range(data.size()):
				if data[i] != _s1[i] and data[i] == 255 - _s1[i]:
					complemented += 1
			print("[rt] %d of %d differing bytes are exact bitwise complements (%.1f%%)" % [
				complemented, diff, 100.0 * complemented / maxi(diff, 1)])
			# A handful of bytes in a state's first kilobyte is almost always a
			# HEADER - a counter, a timestamp, the emulator's own bookkeeping -
			# and says nothing about the emulated machine. Hundreds of thousands
			# spread through a table is the machine. The verdict cannot tell
			# them apart, so print the fields and let a human decide.
			if runs <= 24:
				print("[rt] the differing fields:")
				var shown := 0
				var i2 := 0
				while i2 < data.size() and shown < 24:
					if data[i2] != _s1[i2]:
						var j := i2
						while j < data.size() and data[j] != _s1[j]:
							j += 1
						print("[rt]   @%-8d len %-3d  before %s  after %s" % [
							i2, j - i2,
							_s1.slice(i2, j).hex_encode(), data.slice(i2, j).hex_encode()])
						shown += 1
						i2 = j
					else:
						i2 += 1
			var tmp := OS.get_environment("TEMP").replace("\\", "/")
			var f1 := FileAccess.open(tmp + "/s1.bin", FileAccess.WRITE)
			f1.store_buffer(_s1); f1.close()
			var f2 := FileAccess.open(tmp + "/s2.bin", FileAccess.WRITE)
			f2.store_buffer(data); f2.close()
			print("[rt] wrote %s/s1.bin and s2.bin for analysis" % tmp)
	_lib.StopContent()
	await get_tree().create_timer(2.0).timeout
	get_tree().quit(0)

func _on_loaded(ok: bool) -> void:
	print("[rt] load ok=%s — saving again with nothing run" % ok)
	if not ok:
		get_tree().quit(1); return
	_lib.RequestSaveState()

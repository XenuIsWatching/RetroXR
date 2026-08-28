## Netplay determinism spike (M4a) — vets a core for lockstep netplay.
##
## Runs the core under the netplay frame gate with a deterministic scripted
## input timeline, savestates mid-run, replays from the state, and compares
## RAM CRC checkpoints. A core PASSES when the replay CRCs are identical.
## Run the tool twice and diff the [crc] lines to also verify cold-start
## determinism across processes (and across machines/architectures).
##
## Usage (windowed; needs the GDExtension + a real core/ROM):
##   godot --path RetroXR --rendering-driver opengl3 res://Tools/netplay/netplay_spike.tscn \
##     -- --spike-core=fceumm "--spike-rom=C:/path/to/rom.nes"
##
## THE CROSS-MACHINE LEG. Everything above proves determinism WITHIN one build.
## It does not prove that a savestate crosses between two, and that is the one
## thing a lockstep session actually posts on the wire: a late join and every
## desync resync ship the host's serialized state for another peer to load. A
## libretro state is a struct dump for most cores, so alignment, padding and a
## nightly's own churn can all break it while the CRC streams agree perfectly.
##
##   machine 1:  ... res://Tools/netplay/netplay_spike.tscn -- --spike-state-out=Z:/np.bin
##   machine 2:  ... res://Tools/netplay/netplay_spike.tscn -- --spike-state-in=Z:/np.bin
##
## Machine 1 writes its state, the frame it was taken at, its core identity and
## its whole phase-A CRC table. Machine 2 loads THAT state into its own core and
## replays the same input timeline, checking its CRCs against machine 1's. Run
## it x86_64 -> arm64 and back: those are the two that have never been tested
## together, and they are exactly the pair a Windows player and a Quest player
## form.
##
## --spike-rollback runs the same input timeline through the ROLLBACK engine:
## confirmations are posted LAGGED behind execution, so every scripted input
## transition is first mispredicted (hold-last) and then corrected by a
## rewind+replay. The [crc] stream MUST be identical to a lockstep run of the
## same timeline — diff the two runs to prove rollback correctness.
extends Node3D

## Defaults assume the standard data root; override both with --spike-root=
## and --spike-rom=.
static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

var root_dir := _home + "/retroxr/libretro"
var core := "fceumm"
var rom := _home + "/retroxr/roms/nes/probe.nes"
var rollback := false
var crc_interval := 60   ## 1 finds the FIRST diverging frame, not merely that one exists
var timeout_s := 110.0   ## a heavy core needs far more than the default
## --spike-option=key=value, repeatable. Vetting a core often means vetting one
## of its DRIVERS: mGBA carries a Game Boy, a Game Boy Color and a Game Boy
## Advance, and which one runs is a core option, not a different core.
##
## These are written into the player's real core_options/<core>.opt when the
## core shuts down, so snapshot that file before a run and put it back after.
var options: Dictionary = {}
var state_out := ""      # write this run's state + CRC table here
var state_in := ""       # load another machine's state instead of self-saving
## Confirmations trail execution by this many frames. 0 is the isolating case:
## the engine still serializes EVERY frame, and never mispredicts, so a run that
## differs from lockstep at lag 0 blames retro_serialize rather than the rewind.
var rollback_lag := 3
const ROLLBACK_MAX_AHEAD := 8

var save_at := 600
const END_AT := 1800

var _lib: Node = null
var _mesh: MeshInstance3D = null
var _next_feed := 0
var _crc_a := {}
var _crc_b := {}
var _phase := "A"
var _state_data := PackedByteArray()
var _state_frame := -1
var _saved := false
var _done := false

# The imported bundle (--spike-state-in): another machine's state, the frame it
# was taken at, its CRC table from that frame on, and who it says it is.
var _import_frame := -1
var _import_crcs: Dictionary = {}
var _import_ident: Dictionary = {}
var _import_from := "?"
var _wrote_bundle := false


func _ready() -> void:
	# Android/adb path: args come from user://spike.cfg (one --spike-* per
	# line), planted by NetworkManager's QA hook. Delete it IMMEDIATELY so a
	# crashing run can't wedge the app into spike mode.
	var cfg_args: PackedStringArray = []
	if FileAccess.file_exists("user://spike.cfg"):
		var f := FileAccess.open("user://spike.cfg", FileAccess.READ)
		if f:
			cfg_args = f.get_as_text().split("\n", false)
			f.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://spike.cfg"))
	for arg: String in OS.get_cmdline_user_args() + cfg_args:
		arg = arg.strip_edges()
		if arg.begins_with("--spike-core="):
			core = arg.trim_prefix("--spike-core=")
		elif arg.begins_with("--spike-rom="):
			rom = arg.trim_prefix("--spike-rom=")
		elif arg.begins_with("--spike-root="):
			root_dir = arg.trim_prefix("--spike-root=")
		elif arg.begins_with("--spike-save-at="):
			save_at = int(arg.trim_prefix("--spike-save-at="))
		elif arg.begins_with("--spike-crc-interval="):
			crc_interval = int(arg.trim_prefix("--spike-crc-interval="))
		elif arg.begins_with("--spike-option="):
			var kv := arg.trim_prefix("--spike-option=").split("=", true, 1)
			if kv.size() == 2:
				options[kv[0]] = kv[1]
		elif arg.begins_with("--spike-timeout="):
			timeout_s = float(arg.trim_prefix("--spike-timeout="))
		elif arg.begins_with("--spike-state-out="):
			state_out = arg.trim_prefix("--spike-state-out=")
		elif arg.begins_with("--spike-state-in="):
			state_in = arg.trim_prefix("--spike-state-in=")
		elif arg == "--spike-rollback":
			rollback = true
		elif arg.begins_with("--spike-lag="):
			rollback_lag = int(arg.trim_prefix("--spike-lag="))
	if not state_in.is_empty():
		if not _load_bundle(state_in):
			return
		_phase = "IMPORT"
	get_tree().create_timer(timeout_s).timeout.connect(func() -> void:
		var f: int = _lib.GetFrameCount() if _lib else -1
		print("[spike] TIMEOUT phase=%s frame=%d" % [_phase, f])
		get_tree().quit(1))
	_mesh = MeshInstance3D.new()
	_mesh.mesh = QuadMesh.new()
	add_child(_mesh)
	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	add_child(_lib)
	_lib.connect("netplay_crc", _on_crc)
	_lib.connect("savestate_ready", _on_state_ready)
	_lib.connect("savestate_loaded", _on_state_loaded)
	# Gate BEFORE starting content: the core holds at frame 0 until inputs post.
	_lib.SetNetplayMode(true, 0x1, 0)
	if _lib.has_method("SetNetplayCrcInterval"):
		_lib.SetNetplayCrcInterval(crc_interval)
	# Rollback mode: port 0 is REMOTE (local_mask 0) so the engine predicts it
	# and our lagged confirmations force rewind+replay corrections.
	_lib.SetNetplayRollback(rollback, 0, ROLLBACK_MAX_AHEAD)
	for k: Variant in options:
		_lib.SetCoreOption(str(k), str(options[k]))
		print("[spike] option %s = %s" % [str(k), str(options[k])])
	_lib.StartContent(root_dir, core, rom)
	print("[spike] started %s / %s%s" % [core, rom.get_file(), " (ROLLBACK)" if rollback else ""])
	if _phase == "IMPORT":
		print("[spike] waiting for the core, then loading %s's state @%d"
			% [_import_from, _import_frame])


## Deterministic scripted play: START to get in-game, then run right with
## periodic jumps — same function drives both phases.
func _input_for_frame(f: int) -> int:
	var btn := 0
	if (f >= 180 and f < 195) or (f >= 300 and f < 320):
		btn |= 1 << 3          # START
	if f >= 400:
		btn |= 1 << 7          # RIGHT
		if (f % 90) < 25:
			btn |= 1 << 8      # A (jump)
		if (f % 51) < 10:
			btn |= 1 << 0      # B (run)
	return btn


func _flat(f: int) -> PackedInt32Array:
	var arr := PackedInt32Array()
	arr.resize(20)
	arr[0] = _input_for_frame(f)
	return arr


func _process(_delta: float) -> void:
	if _done or _lib == null or _phase == "B_LOADING":
		return
	if _phase == "IMPORT":
		_try_import()
		return
	var cur: int = _lib.GetFrameCount()
	if rollback:
		# Confirmations trail execution — the engine must predict first, then
		# get corrected. (The speculation throttle keeps this from deadlocking:
		# execution stalls at watermark + max_ahead, which keeps cur - LAG
		# ahead of the feed pointer.)
		while _next_feed <= cur - rollback_lag:
			_lib.PostNetplayInputs(_next_feed, _flat(_next_feed))
			_next_feed += 1
	else:
		while _next_feed < cur + 90:
			_lib.PostNetplayInputs(_next_feed, _flat(_next_feed))
			_next_feed += 1
	if _phase == "A" and not _saved and cur >= save_at:
		_saved = true
		_lib.RequestSaveState()
	elif _phase == "B" and cur >= END_AT + 30:
		_finish()


func _on_crc(frame: int, crc: int) -> void:
	if _phase == "A":
		print("[crc] %d %08x" % [frame, crc])
		_crc_a[frame] = crc
		if frame >= END_AT and _state_frame >= 0:
			_write_bundle()
			_phase = "B_LOADING"
			print("[spike] phase A done (%d checkpoints) — loading state @%d" % [_crc_a.size(), _state_frame])
			_lib.RequestLoadState(_state_data, _state_frame)
	elif _phase == "B":
		_crc_b[frame] = crc
		print("[crcB] %d %08x" % [frame, crc])
		if _import_frame >= 0 and frame >= END_AT:
			_finish()


# ── The cross-machine leg ─────────────────────────────────────────────────────

## Wait for the core to be up, then load the OTHER machine's state into it.
##
## Waiting is not optional and there is no signal for it: StartContent returns
## the moment the emulation thread is spawned, and a state loaded into a core
## that has not finished retro_load_game is a state loaded into nothing.
## GetCoreIdentity is empty until the load has succeeded, which makes it the
## readiness test as well as the thing being compared.
func _try_import() -> void:
	if not _lib.has_method("GetCoreIdentity"):
		print("[spike] RESULT=FAIL (extension has no GetCoreIdentity; rebuild it)")
		_done = true
		get_tree().quit(1)
		return
	var ident: Dictionary = _lib.GetCoreIdentity()
	if ident.is_empty():
		return
	print("[spike] local core:  %s %s (%d-byte states, API %d)" % [
		str(ident.get("library_name", "?")), str(ident.get("library_version", "?")),
		int(ident.get("serialize_size", 0)), int(ident.get("api_version", 0))])
	print("[spike] remote core: %s %s (%d-byte states, API %d) from %s" % [
		str(_import_ident.get("library_name", "?")), str(_import_ident.get("library_version", "?")),
		int(_import_ident.get("serialize_size", 0)), int(_import_ident.get("api_version", 0)),
		_import_from])
	# Deliberately NOT fatal. Two nightlies of the same core disagreeing here is
	# the very thing this run exists to characterise, and refusing to try would
	# turn a measurement into an assumption.
	if str(ident.get("library_version", "")) != str(_import_ident.get("library_version", "")):
		print("[spike] NOTE: the two builds report different versions")
	if int(ident.get("serialize_size", 0)) != int(_import_ident.get("serialize_size", 0)):
		print("[spike] NOTE: the two builds disagree about savestate size")
	_phase = "B_LOADING"
	_state_frame = _import_frame
	_lib.RequestLoadState(_state_data, _import_frame)


func _load_bundle(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("[spike] RESULT=FAIL (cannot read %s)" % path)
		get_tree().quit(1)
		return false
	var raw := f.get_buffer(f.get_length())
	f.close()
	var v: Variant = bytes_to_var(raw)
	if typeof(v) != TYPE_DICTIONARY:
		print("[spike] RESULT=FAIL (%s is not a spike bundle)" % path)
		get_tree().quit(1)
		return false
	var b: Dictionary = v
	_state_data = b.get("state", PackedByteArray())
	_import_frame = int(b.get("frame", -1))
	_import_crcs = b.get("crcs", {})
	_import_ident = b.get("identity", {})
	_import_from = str(b.get("from", "?"))
	core = str(b.get("core", core))
	if _state_data.is_empty() or _import_frame < 0 or _import_crcs.is_empty():
		print("[spike] RESULT=FAIL (%s is incomplete)" % path)
		get_tree().quit(1)
		return false
	print("[spike] bundle: %d state bytes @frame %d, %d checkpoints, core '%s'"
		% [_state_data.size(), _import_frame, _import_crcs.size(), core])
	return true


## Written once phase A has run to END_AT, so the CRC table covers the whole
## stretch the importing machine is going to replay.
func _write_bundle() -> void:
	if state_out.is_empty() or _wrote_bundle or _state_data.is_empty():
		return
	_wrote_bundle = true
	var ident: Dictionary = _lib.GetCoreIdentity() if _lib.has_method("GetCoreIdentity") else {}
	var bundle := {
		"state": _state_data,
		"frame": _state_frame,
		"crcs": _crc_a,
		"identity": ident,
		"core": core,
		"from": "%s/%s" % [OS.get_name(), Engine.get_architecture_name()],
	}
	var f := FileAccess.open(state_out, FileAccess.WRITE)
	if f == null:
		print("[spike] WARNING: cannot write %s" % state_out)
		return
	f.store_buffer(var_to_bytes(bundle))
	f.close()
	print("[spike] wrote bundle to %s (%d state bytes @%d, %d checkpoints, %s)"
		% [state_out, _state_data.size(), _state_frame, _crc_a.size(),
			NetplaySession.identity_str(ident)])


func _on_state_ready(data: PackedByteArray, frame: int) -> void:
	print("[spike] savestate captured: %d bytes at frame %d" % [data.size(), frame])
	if data.is_empty():
		print("[spike] RESULT=FAIL (core has no savestate support)")
		get_tree().quit(1)
		return
	_state_data = data
	_state_frame = frame


func _on_state_loaded(ok: bool) -> void:
	print("[spike] state loaded ok=%s — replaying from %d" % [ok, _state_frame])
	if not ok:
		print("[spike] RESULT=FAIL (unserialize failed)")
		get_tree().quit(1)
		return
	_next_feed = _state_frame
	_phase = "B"


func _finish() -> void:
	_done = true
	# Against our own phase A normally; against the OTHER machine's table when a
	# bundle was imported, which is the only comparison that says anything about
	# two builds.
	var reference: Dictionary = _import_crcs if _import_frame >= 0 else _crc_a
	var mismatches := 0
	var compared := 0
	for f: int in _crc_b:
		if f <= _state_frame or f > END_AT:
			continue
		if reference.has(f):
			compared += 1
			if int(reference[f]) != int(_crc_b[f]):
				mismatches += 1
				print("[spike] MISMATCH frame %d: ref=%08x here=%08x"
					% [f, int(reference[f]), int(_crc_b[f])])
	var ok := compared >= 15 and mismatches == 0
	if _import_frame >= 0:
		print("[spike] cross-machine: %s -> %s/%s" % [_import_from, OS.get_name(),
			Engine.get_architecture_name()])
	print("[spike] compared %d CRC checkpoints after reload, %d mismatches" % [compared, mismatches])
	if rollback:
		var rb: int = _lib.GetNetplayRollbackCount() if _lib.has_method("GetNetplayRollbackCount") else -1
		print("[spike] rollbacks performed: %d" % rb)
		if rb <= 0:
			ok = false
			print("[spike] FAIL: rollback mode ran but no rollbacks happened")
	print("[spike] RESULT=%s" % ("PASS" if ok else "FAIL"))
	_lib.StopContent()
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if ok else 1)

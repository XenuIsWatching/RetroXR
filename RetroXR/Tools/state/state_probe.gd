## Save-state round trip against a real core, and the cost of it.
##
## A: capture — three files land, the thumbnail is a real picture at the core's
##    aspect, and the sidecar knows the frame it was taken at.
## B: restore — run the game on, load the state back, and the core is where it
##    was. The oracle is the frame counter, which a load rewinds to the state's.
## C: overwrite — capturing into an existing id keeps the id, keeps created_at,
##    advances the mtime, and does not add a row.
## D: cold load — a state loaded into a machine that is OFF powers it on and
##    lands, in one press. This is the case the startup-race fix bought.
## E: delete — all three files go.
## F: nothing blocks a frame. Samples the wall gap between frames across a
##    capture and a load. Only asserts on a state big enough that writing it on
##    the main thread would beat the headless frame floor — see the case.
##
##   godot --headless --path RetroXR res://Tools/state/state_probe.tscn \
##     -- --state-rom=C:/path/to/game.nes --state-core=fceumm
extends Node3D

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

var core := "fceumm"
var systemid := "nes"
var rom := _home + "/retroxr/roms/nes/Super Mario Bros. (World).nes"

var _sys: RetroSystem = null
var _fail := false
var _phase := "-"
## Frame times sampled while something heavy is meant to be off the main thread.
var _watching := false
var _worst := 0.0
var _baseline := 0.0
var state_bytes := 0
var _last_tick := 0

## Under this, a main-thread write is quicker than the headless frame floor.
const FRAME_COST_FLOOR_BYTES := 16 * 1024 * 1024


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--state-rom="):
			rom = arg.trim_prefix("--state-rom=")
		elif arg.begins_with("--state-core="):
			core = arg.trim_prefix("--state-core=")
		elif arg.begins_with("--state-system="):
			systemid = arg.trim_prefix("--state-system=")
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("[state] TIMEOUT phase=%s" % _phase)
		get_tree().quit(1))
	if not FileAccess.file_exists(rom):
		print("[state] SKIP: rom not found (%s) — pass --state-rom=" % rom)
		get_tree().quit(0)
		return
	# Uncapped, so nothing is hidden behind a sleep the engine would have taken
	# anyway.
	Engine.max_fps = 0
	get_tree().current_scene = self
	_run()


## Wall time between frames, measured here rather than taken from `delta`.
## Under a frame cap the engine just sleeps less, so main-thread work that fits
## inside the budget never shows up in delta at all — a 4 MB state written on the
## main thread measured exactly the same 6.9 ms as an idle frame. The probe runs
## uncapped and times the gap itself.
func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _watching and _last_tick > 0:
		_worst = maxf(_worst, (now - _last_tick) / 1000000.0)
	_last_tick = now


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail = true
	print("[state] %s  %s: %s" % ["PASS" if ok else "FAIL", _phase, msg])


func _wait_frames(n: int) -> void:
	var lib: Node = _sys.get_libretro_node()
	var target: int = int(lib.GetFrameCount()) + n
	var deadline := Time.get_ticks_msec() + int(n * 1000.0 / 50.0) + 3000
	while int(lib.GetFrameCount()) < target and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _idle(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


## The next state_captured / state_loaded, as {id, ok, reason}. Never hangs: the
## machine answers both of these exactly once, by contract.
func _next(sig: Signal) -> Dictionary:
	var got: Array = []
	var cb := func(a, b, c) -> void:
		got.append({"id": a, "ok": b, "reason": c})
	sig.connect(cb, CONNECT_ONE_SHOT)
	var frames := 0
	while got.is_empty() and frames < 4000:
		await get_tree().process_frame
		frames += 1
	if sig.is_connected(cb):
		sig.disconnect(cb)
	return got[0] if not got.is_empty() else {"id": "", "ok": false, "reason": "no answer"}


func _run() -> void:
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	_sys = sys_scene.instantiate() as RetroSystem
	_sys.systemid = systemid
	_sys.core_name = core
	_sys.freeze = true
	add_child(_sys)
	_sys.add_to_group("spawned")
	await _idle(30)

	# ── A: capture ────────────────────────────────────────────────────────────
	_phase = "A capture"
	_sys.rom_path = rom
	_sys.power_on()
	if not _sys.is_powered_on:
		print("[state] SKIP: the machine would not power on")
		get_tree().quit(0)
		return
	await _wait_frames(120)

	# Measure an idle frame first, so "did the capture stand out" has something
	# to stand out FROM. A headless run's frame time is not a Quest's, but the
	# question here is relative.
	_worst = 0.0
	_last_tick = 0
	_watching = true
	await _idle(60)
	_baseline = _worst
	_worst = 0.0

	_sys.capture_state()
	var cap := await _next(_sys.state_captured)
	var capture_worst := _worst
	_watching = false
	_check(bool(cap["ok"]), "the capture succeeded (%s)" % cap["reason"])
	if not bool(cap["ok"]):
		return _finish()
	var id: String = cap["id"]
	var rows := StatePaths.list_states(core, rom)
	_check(rows.size() == 1, "one state is listed, got %d" % rows.size())
	state_bytes = int(rows[0]["bytes"]) if not rows.is_empty() else 0
	_check(FileAccess.file_exists(StatePaths.state_path(core, rom, id)), "the .state exists")
	_check(FileAccess.file_exists(StatePaths.shot_path(core, rom, id)), "the thumbnail exists")
	var meta := StatePaths.read_meta(core, rom, id)
	_check(int(meta.get("frame", -1)) > 0,
		"the sidecar records the frame it was taken at (%s)" % str(meta.get("frame", "-")))
	var shot := Image.load_from_file(StatePaths.shot_path(core, rom, id))
	_check(shot != null and not shot.is_empty(), "the thumbnail decodes")
	if shot != null and not shot.is_empty():
		print("[state]       thumbnail %dx%d, %d bytes"
			% [shot.get_width(), shot.get_height(),
			   NetFileTransfer.size_of(StatePaths.shot_path(core, rom, id))])
		_check(shot.get_width() <= StatePaths.THUMB_MAX_W, "and is not upscaled past the box")
		# The core's frame arrives alpha 0; a thumbnail that kept the channel
		# would be a fully transparent rectangle. This is the case that catches it.
		var opaque := false
		for y in range(0, shot.get_height(), maxi(1, shot.get_height() / 12)):
			for x in range(0, shot.get_width(), maxi(1, shot.get_width() / 12)):
				var c := shot.get_pixel(x, y)
				if c.a > 0.9 and (c.r + c.g + c.b) > 0.05:
					opaque = true
		_check(opaque, "and is an opaque picture rather than a transparent rectangle")

	# ── B: restore ────────────────────────────────────────────────────────────
	_phase = "B restore"
	var lib: Node = _sys.get_libretro_node()
	var at_capture := int(meta.get("frame", 0))
	await _wait_frames(400)
	var before := int(lib.GetFrameCount())
	_check(before > at_capture + 300, "the game ran on past the capture (%d -> %d)"
		% [at_capture, before])
	_worst = 0.0
	_last_tick = 0
	_watching = true
	_sys.load_state(id)
	var ld := await _next(_sys.state_loaded)
	var load_worst := _worst
	_watching = false
	_check(bool(ld["ok"]), "the state loaded (%s)" % ld["reason"])
	_check(int(lib.GetFrameCount()) < before,
		"and the core is back where it was (frame %d, was %d)"
			% [int(lib.GetFrameCount()), before])

	# ── C: overwrite ──────────────────────────────────────────────────────────
	_phase = "C overwrite"
	var born := int(meta.get("created_at", 0))
	var first_mtime := FileAccess.get_modified_time(StatePaths.state_path(core, rom, id))
	await _wait_frames(120)
	# Sleep so the mtime can actually differ: a one-second filesystem stamp makes
	# "it was rewritten" unmeasurable if both writes land in the same second.
	await get_tree().create_timer(1.6).timeout
	_sys.capture_state(id)
	var over := await _next(_sys.state_captured)
	_check(bool(over["ok"]), "the overwrite succeeded (%s)" % over["reason"])
	_check(str(over["id"]) == id, "and kept the row's id")
	_check(StatePaths.list_states(core, rom).size() == 1, "and did not add a row")
	var meta2 := StatePaths.read_meta(core, rom, id)
	_check(int(meta2.get("created_at", -1)) == born,
		"and kept the row's birthday (%d vs %d)" % [int(meta2.get("created_at", -1)), born])
	_check(int(meta2.get("frame", 0)) > at_capture, "and holds the newer frame")
	_check(FileAccess.get_modified_time(StatePaths.state_path(core, rom, id)) > first_mtime,
		"and rose to the top of the list")

	# ── D: cold load ──────────────────────────────────────────────────────────
	_phase = "D cold load"
	_sys.power_off()
	await get_tree().create_timer(1.5).timeout
	_check(not _sys.is_powered_on, "the machine is off")
	_sys.load_state(id)
	var cold := await _next(_sys.state_loaded)
	_check(bool(cold["ok"]), "a state loaded into a machine that was off (%s)" % cold["reason"])
	_check(_sys.is_powered_on, "and it powered itself on to do it")

	# ── E: delete ─────────────────────────────────────────────────────────────
	_phase = "E delete"
	_check(StatePaths.delete_state(core, rom, id), "delete reports success")
	_check(StatePaths.list_states(core, rom).is_empty(), "and the list is empty")
	_check(not FileAccess.file_exists(StatePaths.shot_path(core, rom, id)),
		"and the thumbnail went with it")
	_check(not FileAccess.file_exists(StatePaths.meta_path(core, rom, id)),
		"and so did the sidecar")

	# ── F: nothing blocks a frame ─────────────────────────────────────────────
	#
	# Only meaningful once the state is big enough for its write to be visible.
	# A 13 KB NES state costs well under a millisecond wherever it is written, so
	# asserting on it would be a case that cannot fail — the honest thing is to
	# say so and name the run that does prove it.
	_phase = "F frame cost"
	print("[state]       %s state | idle worst %.1f ms | capture worst %.1f ms | load worst %.1f ms"
		% [String.humanize_size(state_bytes), _baseline * 1000.0,
		   capture_worst * 1000.0, load_worst * 1000.0])
	# A headless run has a hard ~6.9 ms floor between frames that neither
	# Engine.max_fps nor the vsync mode can lift — the dummy display server
	# ignores both. So anything cheaper than that is invisible here, and a 4 MB
	# state written on the main thread measured exactly like an idle frame.
	# Below the floor this case cannot fail, so it does not pretend to pass.
	if state_bytes < FRAME_COST_FLOOR_BYTES:
		print("[state] SKIP  %s: a %s state writes faster than a headless frame (~7 ms), "
			% [_phase, String.humanize_size(state_bytes)]
			+ "so this cannot fail. It bites on a GameCube-sized state, and on device "
			+ "with the perf HUD open.")
	else:
		_check(capture_worst < maxf(_baseline * 2.0, 0.02),
			"the capture did not stall the main thread")
		_check(load_worst < maxf(_baseline * 2.0, 0.02), "nor did the load")
	_finish()


func _finish() -> void:
	_sys.power_off()
	await get_tree().create_timer(1.0).timeout
	print("[state] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)

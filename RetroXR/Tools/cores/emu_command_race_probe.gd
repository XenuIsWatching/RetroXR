## Does a request made before the core is running get queued, or refused?
##
## RequestLoadState / RequestDiskInfo used to early-out on `m_running`, which the
## EMULATION thread raises, later. Every caller that asked on the same frame as
## StartContent therefore lost the race and was told "no" — netplay's late join
## does exactly that. The guard now also accepts "a thread is starting and will
## drain this", and a thread that gives up answers what it never ran.
##
##   godot --headless --path RetroXR res://Tools/cores/emu_command_race_probe.tscn \
##     -- --race-rom=C:/path/to/game.nes
extends Node3D

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

var root_dir := _home + "/retroxr/libretro"
var core := "fceumm"
var rom := _home + "/retroxr/roms/nes/Super Mario Bros. (World).nes"
## Phase E needs a cart with battery RAM; SMB has none.
var battery_rom := _home + "/retroxr/roms/nes/Legend of Zelda, The (USA).nes"

var _lib: Node = null
var _fail := false
var _phase := "-"


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--race-rom="):
			rom = arg.trim_prefix("--race-rom=")
		elif arg.begins_with("--race-core="):
			core = arg.trim_prefix("--race-core=")
		elif arg.begins_with("--race-battery-rom="):
			battery_rom = arg.trim_prefix("--race-battery-rom=")
		elif arg.begins_with("--race-root="):
			root_dir = arg.trim_prefix("--race-root=")
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[race] TIMEOUT phase=%s" % _phase)
		get_tree().quit(1))
	if not FileAccess.file_exists(rom):
		print("[race] SKIP: rom not found (%s) — pass --race-rom=" % rom)
		get_tree().quit(0)
		return
	var obj: Object = ClassDB.instantiate("Libretro")
	_lib = obj as Node
	add_child(_lib)
	_run()


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail = true
	print("[race] %s  %s: %s" % ["PASS" if ok else "FAIL", _phase, msg])


## Wait for one signal, reporting how many idle frames it took. -1 = never came.
func _await_signal(sig: Signal, budget := 600) -> Array:
	# APPEND, never assign: a lambda captures by value, so rebinding `got` inside
	# it would leave the copy out here empty forever.
	var got: Array = []
	var frames := 0
	# Four defaults: disk_control_ready carries four arguments, and a callable
	# that takes fewer is simply never invoked.
	var cb := func(a = null, b = null, c = null, d = null) -> void:
		got.append([a, b, c, d])
	sig.connect(cb, CONNECT_ONE_SHOT)
	while got.is_empty() and frames < budget:
		await get_tree().process_frame
		frames += 1
	if sig.is_connected(cb):
		sig.disconnect(cb)
	if got.is_empty():
		return [-1, [null, null, null, null]]
	return [frames, got[0]]


## Bounded in SECONDS, not in idle frames: headless idles far faster than a core
## runs, so an idle-frame budget generous enough for 90 core frames gives up long
## before 700 of them.
func _wait_core_frames(n: int) -> void:
	var target: int = int(_lib.GetFrameCount()) + n
	var deadline := Time.get_ticks_msec() + int(n * 1000.0 / 50.0) + 3000
	while int(_lib.GetFrameCount()) < target and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if int(_lib.GetFrameCount()) < target:
		print("[race]       WARN %s: wanted frame %d, the core only reached %d"
			% [_phase, target, int(_lib.GetFrameCount())])


func _run() -> void:
	# ── A: nothing has ever been started — the refusal must still be instant ──
	_phase = "A cold node"
	_lib.RequestLoadState(PackedByteArray([1, 2, 3]), 0)
	var a: Array = await _await_signal(_lib.savestate_loaded, 30)
	_check(a[0] >= 0, "a load with no core answered (after %d idle frames)" % a[0])
	_check(a[1][0] == false, "and answered false")

	# ── B: capture a state, restart, ask on the SAME frame as StartContent ────
	_phase = "B late join"
	_lib.StartContent(root_dir, core, rom)
	await _wait_core_frames(90)
	_lib.RequestSaveState()
	var cap: Array = await _await_signal(_lib.savestate_ready, 300)
	var data: PackedByteArray = cap[1][0] if cap[0] >= 0 else PackedByteArray()
	var frame: int = int(cap[1][1]) if cap[0] >= 0 else -1
	print("[race]       captured %d bytes at frame %d" % [data.size(), frame])
	if data.is_empty():
		print("[race] SKIP: this core cannot serialize — nothing to race with")
		get_tree().quit(1 if _fail else 0)
		return
	_lib.StopContent()
	await get_tree().create_timer(1.0).timeout

	# The whole point: no awaits between these two lines. This is what
	# NetplaySession._np_savestate does.
	_lib.StartContent(root_dir, core, rom)
	_lib.RequestLoadState(data, frame)
	var b: Array = await _await_signal(_lib.savestate_loaded, 900)
	_check(b[0] >= 0, "a load issued in the StartContent frame answered (after %d idle frames)" % b[0])
	_check(b[0] > 1, "and waited for the core rather than refusing on the spot")
	_check(b[1][0] == true, "and the core actually unserialized it")

	# ── C: disk info on the same frame — the answer must be the core's ────────
	_phase = "C disk info"
	_lib.StopContent()
	await get_tree().create_timer(1.0).timeout
	_lib.StartContent(root_dir, core, rom)
	_lib.RequestDiskInfo()
	var c: Array = await _await_signal(_lib.disk_control_ready, 900)
	_check(c[0] >= 0, "disk info issued in the StartContent frame answered (after %d idle frames)" % c[0])
	_check(c[0] > 1, "and waited for the core rather than refusing on the spot")
	_lib.StopContent()
	await get_tree().create_timer(1.0).timeout

	# ── D: a start that FAILS must still answer what it never ran ─────────────
	_phase = "D failed start"
	_lib.StartContent(root_dir, "no_such_core_exists", rom)
	_lib.RequestLoadState(data, frame)
	var d: Array = await _await_signal(_lib.savestate_loaded, 600)
	_check(d[0] >= 0, "a load queued against a core that never loads answered (after %d idle frames)" % d[0])
	_check(d[1][0] == false, "and answered false rather than hanging")
	_lib.StopContent()
	await get_tree().create_timer(0.5).timeout

	await _video_image()
	await _sram_rewind()

	print("[race] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)


## F: the CPU-side frame a savestate thumbnail is cut from.
##
## GetVideoImage() hands back the buffer the texture was uploaded FROM, so a
## thumbnail costs a memcpy instead of a GPU readback. It has to be a real frame
## at the core's own resolution, and it has to be the SAME object frame after
## frame — UpdateTexture refreshes it in place, which is exactly why anything
## outliving the frame must duplicate it.
func _video_image() -> void:
	_phase = "F video image"
	_lib.StartContent(root_dir, core, rom)
	await _wait_core_frames(60)
	var img: Image = _lib.GetVideoImage()
	var tex: Texture2D = _lib.GetVideoTexture()
	_check(img != null and not img.is_empty(), "the running core hands back a CPU-side frame")
	if img == null or img.is_empty():
		_lib.StopContent()
		await get_tree().create_timer(1.0).timeout
		return
	print("[race]       %dx%d %s" % [img.get_width(), img.get_height(), img.get_format()])
	_check(tex != null and img.get_size() == Vector2i(tex.get_size()),
		"and it is the size of the texture the room samples")
	# The alpha the thumbnail has to drop: cores draw opaque and never write it.
	var px := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	print("[race]       centre pixel a=%.2f (0 means the thumbnail must convert to RGB8)" % px.a)
	await _wait_core_frames(30)
	_check(_lib.GetVideoImage() == img, "and the next frame refreshes it in place")
	_lib.StopContent()
	await get_tree().create_timer(1.0).timeout
	_check(_lib.GetVideoImage() == null, "a machine with no core hands back nothing")


## E: does the battery save survive a savestate load?
##
## The periodic flush was `frame - last_flush >= 600` on a counter a load rewinds,
## so restoring a state taken at frame 60 into a session at frame 700 left the
## difference at -600 and the .srm was never written again for the rest of the run.
##
## Making that measurable needs SAVE_RAM to genuinely differ from the shadow copy
## the dirty check compares against, which a state carries for free: boot once
## with a known .srm, capture, then load that state into a run whose SAVE_RAM is
## blank. The rewind and the dirt arrive in the same call.
func _sram_rewind() -> void:
	_phase = "E sram rewind"
	if not FileAccess.file_exists(battery_rom):
		print("[race] SKIP %s: no battery-backed rom (%s)" % [_phase, battery_rom])
		return
	var stem := root_dir.path_join("save").path_join(core).path_join("race_probe")
	DirAccess.make_dir_recursive_absolute(stem)
	var seeded := stem.path_join("seed_%d.srm" % Time.get_ticks_msec())
	var target := stem.path_join("target_%d.srm" % Time.get_ticks_msec())
	var f := FileAccess.open(seeded, FileAccess.WRITE)
	var pattern := PackedByteArray()
	pattern.resize(8192)
	pattern.fill(0xAA)
	f.store_buffer(pattern)
	f.close()

	# Run one: a save file full of 0xAA, captured into a state.
	_lib.SetSramPath(seeded)
	_lib.StartContent(root_dir, core, battery_rom)
	await _wait_core_frames(60)
	_lib.RequestSaveState()
	var cap: Array = await _await_signal(_lib.savestate_ready, 300)
	var data: PackedByteArray = cap[1][0] if cap[0] >= 0 else PackedByteArray()
	var frame: int = int(cap[1][1]) if cap[0] >= 0 else -1
	_lib.StopContent()
	await get_tree().create_timer(1.0).timeout
	if data.is_empty():
		print("[race] SKIP %s: this core cannot serialize" % _phase)
		DirAccess.remove_absolute(seeded)
		return

	# Run two: a blank save file, run well past one flush window so the counter
	# is high, then rewind it by loading the state.
	_lib.SetSramPath(target)
	_lib.StartContent(root_dir, core, battery_rom)
	# Long enough for one ordinary flush to have happened, so the question below
	# is whether flushing CONTINUES past a rewind, not whether it ever ran.
	await _wait_core_frames(700)
	var before := _read(target)
	_lib.RequestLoadState(data, frame)
	var ld: Array = await _await_signal(_lib.savestate_loaded, 900)
	_check(ld[1][0] == true, "the state loaded into the second run")
	# A full flush window past the rewound frame. The pre-fix arithmetic needs
	# twice this before it fires again.
	await _wait_core_frames(700)
	var after := _read(target)

	# The positive control: the stop's final flush ignores the counter entirely,
	# so if even that leaves the file unchanged then this rom's SAVE_RAM never
	# differed and the case proves nothing either way.
	_lib.StopContent()
	await get_tree().create_timer(1.5).timeout
	var at_stop := _read(target)
	print("[race]       %d bytes before the rewind, %d after, %d at the stop"
		% [before.size(), after.size(), at_stop.size()])
	if at_stop == before:
		print("[race] SKIP %s: the state carried identical SAVE_RAM — nothing to detect" % _phase)
	else:
		_check(after != before,
			"the periodic flush still ran after a savestate rewound the frame counter")
	DirAccess.remove_absolute(seeded)
	DirAccess.remove_absolute(target)


func _read(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_buffer(f.get_length()) if f else PackedByteArray()

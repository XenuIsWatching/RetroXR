## BS-X broadcast probe — does the Satellaview actually receive, and does ACCESS blink?
##
## Two questions, one run, both through the path RetroXR really uses: the "bsx"
## subsystem, shell plus memory pack, retro_load_game_special.
##
## Connection is not directly observable from this side. Reception itself was
## confirmed at core level -- an instrumented snes9x opened 2391 broadcast files
## out of the satellaview directory in one six-thousand-frame run -- but nothing
## of that reaches GDScript, so this probe watches the ACCESS lamp instead.
##
## WHAT THE LAMP ACTUALLY MEANS. It is $2194 bit 2, reported over libretro's LED
## interface, and it blinks during a DOWNLOAD. It does NOT light for the channel
## directory the shell reads on its own at boot: through all 2391 of those reads
## the shell wrote $2194 exactly once, as 0x01, and never set bit 2. So a dark
## lamp here does not mean no signal -- it means this run never reached a
## download, which is inside the town, at the Broadcast Station.
##
## Which is why the lamp half of this probe is not automated. Scripted input
## walks the town blind and does not reliably arrive at the tower; a red result
## from that proves nothing about the lamp, and reading it as proof is exactly
## the mistake this comment exists to stop. Drive it by hand to a download and
## the edges below are the record of it.
##
## THE BATTERY SAVE IS LOAD-BEARING. With no .srm the shell boots into first-run
## name entry and sits on that keyboard for ever: the tuner never runs, the lamp
## never lights, and the probe goes red for a reason that has nothing to do with
## the broadcast. SetSramPath must be called BEFORE the content starts.
##
## A probe, not a test: it wants the real snes9x core, a real BS-X shell, a pack,
## a battery save and a downloaded broadcast, none of which CI has.
##
## Run: godot --headless --path RetroXR res://Tools/cores/bsx_signal_probe.tscn
extends Node3D

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

var root_dir := _home + "/retroxr/libretro"
var core := "snes9x"
var sat_dir := _home + "/retroxr/roms/satellaview"
var shell_rom := ""
var pack_rom := ""
var srm := ""

## snes9x reports index 0 as ACCESS — the same constant SatellaviewPanel uses.
const CORE_LED_ACCESS := 0
## Core frames to watch after the shell is up. The lamp does NOT light merely
## because the shell is tuning at boot -- the channel-directory reads it does on
## its own leave $2194 bit 2 clear. It lights on a real transfer, which is inside
## the town, so the run has to be long enough to walk there.
const WATCH_FRAMES := 20000

## RetroPad bits, in libretro's order.
const BTN_B := 1 << 0
const BTN_START := 1 << 3
const BTN_UP := 1 << 4
const BTN_DOWN := 1 << 5
const BTN_LEFT := 1 << 6
const BTN_RIGHT := 1 << 7
const BTN_A := 1 << 8

## A walk, not a button masher. Each entry is held for HOLD_FRAMES: four
## directions to cover the town, then A/START to talk to whatever it reached.
const WALK := [BTN_UP, BTN_A, BTN_RIGHT, BTN_A, BTN_DOWN, BTN_A, BTN_LEFT, BTN_A,
	BTN_START, BTN_A, 0, BTN_UP, BTN_UP, BTN_A, BTN_A, 0]
const HOLD_FRAMES := 30

var _lib: Node = null
var _edges: Array[Dictionary] = []
var _done := false


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--bsx-root="):
			root_dir = arg.trim_prefix("--bsx-root=")
		elif arg.begins_with("--bsx-core="):
			core = arg.trim_prefix("--bsx-core=")
		elif arg.begins_with("--bsx-sat="):
			sat_dir = arg.trim_prefix("--bsx-sat=")
	if shell_rom.is_empty():
		shell_rom = sat_dir + "/BS-X.sfc"
	if pack_rom.is_empty():
		pack_rom = sat_dir + "/MEMORY PACK.bs"
	if srm.is_empty():
		srm = root_dir.path_join("save").path_join(core).path_join("bsx_cart") \
			.path_join("bsx_cart.srm")

	get_tree().create_timer(600.0).timeout.connect(func() -> void:
		print("[bsx] TIMEOUT")
		get_tree().quit(1))

	for p: String in [shell_rom, pack_rom]:
		if not FileAccess.file_exists(p):
			print("[bsx] SKIP: missing %s" % p)
			get_tree().quit(0)
			return
	if not FileAccess.file_exists(srm):
		print("[bsx] SKIP: no battery save at %s — the shell would stop at name entry" % srm)
		get_tree().quit(0)
		return

	var bins := 0
	var d := DirAccess.open(sat_dir)
	if d != null:
		for f: String in d.get_files():
			if f.begins_with("BSX") and f.ends_with(".bin"):
				bins += 1
	print("[bsx] broadcast files: %d in %s" % [bins, sat_dir])
	if bins == 0:
		print("[bsx] SKIP: no BSX????-?.bin — nothing to receive")
		get_tree().quit(0)
		return

	var obj: Object = ClassDB.instantiate("Libretro")
	_lib = obj as Node
	add_child(_lib)
	_lib.connect("led_state", _on_led)
	_lib.connect("content_load_failed", _on_load_failed)
	_run()


## The shell is a TOWN, not a menu that runs itself: left alone it waits on a
## prompt for ever. Tap START then A on a slow cycle -- enough to clear a title
## or a dialogue, slow enough that a screen settles before the next press.
func _process(_delta: float) -> void:
	if _lib == null or _done:
		return
	var f: int = int(_lib.GetFrameCount())
	var step: int = (f / HOLD_FRAMES) % WALK.size()
	# Release for the last third of each hold: a direction never let go reads as
	# one long push, and a menu never sees a fresh press.
	var buttons: int = 0 if (f % HOLD_FRAMES) >= (HOLD_FRAMES * 2 / 3) else int(WALK[step])
	_lib.SetJoypadState(0, buttons, 0, 0, 0, 0)


func _wait_frames(n: int) -> void:
	var target: int = int(_lib.GetFrameCount()) + n
	while int(_lib.GetFrameCount()) < target and not _done:
		await get_tree().process_frame


func _run() -> void:
	print("[bsx] SetSramPath(%s)" % srm)
	_lib.SetSramPath(srm)

	# The pack is the medium itself: a flush REWRITES the player's .bs in place.
	# Point it at a copy so a probe run can never damage the real one, while the
	# plumbing (watch, dirty check, flush) is exercised exactly as it ships.
	var pack_copy := OS.get_environment("TEMP").replace("\\", "/") + "/bsx_probe_pack.bs"
	var src := FileAccess.open(pack_rom, FileAccess.READ)
	var dst := FileAccess.open(pack_copy, FileAccess.WRITE)
	if src != null and dst != null:
		dst.store_buffer(src.get_buffer(src.get_length()))
		dst.close()
		src.close()
		print("[bsx] SetPackPath(%s)  [copy — the real pack is not touched]" % pack_copy)
		_lib.SetPackPath(pack_copy)
	else:
		print("[bsx] WARN: could not stage a pack copy; skipping SetPackPath")
	print("[bsx] StartSubsystemContent(ident=bsx, shell + pack)")
	_lib.StartSubsystemContent(root_dir, core, pack_rom, "bsx",
		PackedStringArray([shell_rom, pack_rom]))

	# The core comes up asynchronously; identity is the readiness test.
	var waited := 0
	while int(_lib.GetFrameCount()) < 1 and waited < 600 and not _done:
		await get_tree().process_frame
		waited += 1
	var ident: Dictionary = _lib.GetCoreIdentity()
	print("[bsx] core up: %s %s (after %d godot frames)" % [
		str(ident.get("library_name", "?")), str(ident.get("library_version", "?")), waited])
	if ident.is_empty():
		_finish("core never came up")
		return

	await _wait_frames(WATCH_FRAMES)
	_finish("")


func _on_led(led: int, on: bool) -> void:
	if led != CORE_LED_ACCESS:
		return
	_edges.append({"frame": int(_lib.GetFrameCount()), "on": on})
	print("[bsx] ACCESS %s at core frame %d" % ["ON " if on else "OFF", int(_lib.GetFrameCount())])
	# One ON and one OFF after it is a blink; a couple more makes it unambiguous.
	# Stop there rather than walking the town for another ten thousand frames.
	var ons := 0
	var offs := 0
	for e: Dictionary in _edges:
		if bool(e["on"]):
			ons += 1
		else:
			offs += 1
	if ons >= 2 and offs >= 2:
		_finish("")


func _on_load_failed(reason: String) -> void:
	_finish("content load failed: %s" % reason)


func _finish(err: String) -> void:
	if _done:
		return
	_done = true
	var ons := 0
	var offs := 0
	for e: Dictionary in _edges:
		if bool(e["on"]):
			ons += 1
		else:
			offs += 1
	print("[bsx] ran %d core frames" % int(_lib.GetFrameCount()))
	print("[bsx] ACCESS edges=%d (on=%d off=%d)" % [_edges.size(), ons, offs])

	var bad := err
	if bad.is_empty() and ons == 0:
		# NOT "no signal": the lamp only lights for a download, and a scripted
		# walk does not reliably reach the Broadcast Station. Say which of the
		# two this is, rather than blaming reception for a walk that got lost.
		bad = "ACCESS never lit — no download was reached this run (the boot-time"
		bad += " channel reads leave $2194 bit 2 clear, so this is NOT proof of no signal)"
	if bad.is_empty() and offs == 0:
		bad = "ACCESS lit but never went out again — lit, not blinking"
	if bad.is_empty():
		print("[bsx] PASS: connected, and ACCESS blinked (%d on / %d off)" % [ons, offs])
	else:
		print("[bsx] FAIL: %s" % bad)
	_lib.StopContent()
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if bad.is_empty() else 1)

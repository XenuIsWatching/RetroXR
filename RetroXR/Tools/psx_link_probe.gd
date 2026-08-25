## Two real PlayStations on one link cable, running WipEout two-player.
##
##   "$godot" --headless --path RetroXR res://Tools/psx_link_probe.tscn -- \
##       "--rom=Z:/roms/psx/WipEout (Europe) (Rev 1).cue"
##
## A probe, not a test: it wants the RetroXR pcsx_rearmed fork, a PS1 BIOS and a
## commercial disc, so it cannot gate a commit.
##
## What it proves is the claim no headless suite reaches — that two instances of
## the core, each loaded from its own copy of the shared library, find each other
## through the frontend's bus and trade real bytes for a real game. A link cable
## never crosses the network: LinkCoordinator joins two cores in ONE process, so
## this is also what a cabled netplay session runs on every peer.
##
## Two things it is careful about.
##
## The machines are driven ONE AT A TIME. Two consoles fed frame-identical input
## both call and neither listens, so a rendezvous that real hardware settles by
## human sloppiness can deadlock a script for ever. The menu walk therefore
## offsets the two sides deliberately.
##
## And traffic is the oracle, not the picture. A menu that LOOKS like it reached
## two-player proves nothing about the wire; LinkTraffic/LinkSent moving on both
## ends is the thing that cannot be faked by a core drawing a screen.
extends Node3D

const CORE := "pcsx_rearmed"
const OPT := "pcsx_rearmed_link_cable"

# RetroPad bits, as PostNetplayInputs/press expects them.
# libretro maps the PlayStation pad as B=Cross, A=Circle, Y=Square, X=Triangle,
# so "confirm" is bit 0 and not the bit an Xbox-shaped mental model reaches for.
const B_CROSS := 1 << 0
const B_START := 1 << 3
const B_UP := 1 << 4
const B_DOWN := 1 << 5

var rom := ""
var boot_frames := 900
var input_check := false
var no_cable := false       # BIOS + licence screen + intro before a menu exists
var _a: Node = null
var _b: Node = null
var _pass := 0
var _fail := 0


func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("[psx-link] PASS  %s" % name)
	else:
		_fail += 1
		print("[psx-link] FAIL  %s%s" % [name, "  — " + detail if detail else ""])


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--rom="):
			rom = a.trim_prefix("--rom=")
		elif a == "--no-cable":
			no_cable = true
		elif a == "--input-check":
			input_check = true
		elif a.begins_with("--boot-frames="):
			boot_frames = int(a.trim_prefix("--boot-frames="))
	if rom.is_empty():
		print("[psx-link] need --rom=")
		get_tree().quit(2)
		return
	get_tree().create_timer(900.0).timeout.connect(func() -> void:
		print("[psx-link] TIMEOUT")
		get_tree().quit(2))
	await _run()


## Hold a button on ONE machine, then release. Deliberately not applied to both
## at once — see the header.
func _press(lib: Node, mask: int, frames := 40) -> void:
	lib.SetJoypadState(0, mask, 0, 0, 0, 0)
	# Read it straight back: this separates "the write never stuck" from "the
	# game ignored a button it did receive", which look identical on screen.
	var peek: PackedInt32Array = lib.PeekJoypadState(0)
	print("[psx-link]   press mask=%d -> peek=%d  (frame %d)"
		% [mask, peek[0] if peek.size() > 0 else -1, int(lib.GetFrameCount())])
	await _wait(frames)
	lib.SetJoypadState(0, 0, 0, 0, 0, 0)
	await _wait(20)


## Wait `n` frames of EMULATED time, not the host's. A headless run has no audio
## device to pace against and two PlayStations share one machine here, so wall
## clock and emulated time drift apart by a factor that moves between runs.
func _wait(n: int) -> void:
	var target_a: int = int(_a.GetFrameCount()) + n
	var target_b: int = int(_b.GetFrameCount()) + n
	var guard := n * 120
	while (int(_a.GetFrameCount()) < target_a or int(_b.GetFrameCount()) < target_b) and guard > 0:
		guard -= 1
		await get_tree().process_frame


var _shots := 0


## Both screens side by side. Watching the PAIR is the point: a link that half
## works shows two consoles that disagree about where they are.
func _shot(name: String) -> void:
	var a: Image = _a.GetVideoImage()
	var b: Image = _b.GetVideoImage()
	if a == null or b == null or a.is_empty() or b.is_empty():
		print("[psx-link] shot %s: no picture" % name)
		return
	var w := a.get_width()
	var h := a.get_height()
	var pair := Image.create_empty(w * 2 + 8, h, false, a.get_format())
	pair.fill(Color(0.1, 0.1, 0.12))
	pair.blit_rect(a, Rect2i(0, 0, w, h), Vector2i(0, 0))
	pair.blit_rect(b, Rect2i(0, 0, w, h), Vector2i(w + 8, 0))
	var dir := "res://probe_out/psx"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	_shots += 1
	pair.save_png("%s/%02d_%s.png" % [dir, _shots, name])
	print("[psx-link] shot %02d %s  (%dx%d)" % [_shots, name, w, h])


## Tap a button until the picture actually changes, or give up.
##
## Timing a PlayStation title screen from the outside does not work: WipEout
## only takes START during part of its attract cycle, so a press of any fixed
## length lands in the dead part often enough to look like input is broken. A
## human solves this by pressing again. So does this.
func _press_until_change(lib: Node, mask: int, tries := 20) -> bool:
	var was: Image = lib.GetVideoImage()
	for i in range(tries):
		lib.SetJoypadState(0, mask, 0, 0, 0, 0)
		await _wait(10)
		lib.SetJoypadState(0, 0, 0, 0, 0, 0)
		await _wait(40)
		var now: Image = lib.GetVideoImage()
		if was != null and now != null and not was.is_empty() and not now.is_empty():
			var d0: PackedByteArray = was.get_data()
			var d1: PackedByteArray = now.get_data()
			var diff := 0
			var step := 97          # sparse sample; the whole buffer is 320*256*n
			var idx := 0
			var seen := 0
			while idx < d0.size() and idx < d1.size():
				seen += 1
				if d0[idx] != d1[idx]:
					diff += 1
				idx += step
			# An animated title moves a few percent between frames. A screen
			# CHANGE moves most of it, so the bar is set where animation cannot
			# reach and a real transition cannot miss.
			if seen > 0 and float(diff) / float(seen) > 0.55:
				print("[psx-link]   screen changed after %d press(es) (%d%% moved)"
					% [i + 1, int(100.0 * float(diff) / float(seen))])
				return true
	print("[psx-link]   no change after %d presses" % tries)
	return false


## The sequence that actually got a console off the title screen, kept verbatim
## because it was found empirically and the reasons are the game's, not ours: a
## long hold through the attract transition, then taps. Detecting "the screen
## changed" does not work here -- WipEout's attract flips between the title and
## a demo, and either flip moves most of the picture.
func _enter_menu(lib: Node) -> void:
	lib.SetJoypadState(0, B_START, 0, 0, 0, 0)
	await _wait(240)
	lib.SetJoypadState(0, 0, 0, 0, 0, 0)
	await _wait(180)
	for i in range(8):
		lib.SetJoypadState(0, B_START, 0, 0, 0, 0)
		await _wait(6)
		lib.SetJoypadState(0, 0, 0, 0, 0, 0)
		await _wait(24)


func _enter_menus(libs: Array) -> void:
	for lib: Node in libs:
		lib.SetJoypadState(0, B_START, 0, 0, 0, 0)
	await _wait(240)
	for lib: Node in libs:
		lib.SetJoypadState(0, 0, 0, 0, 0, 0)
	await _wait(180)
	for i in range(8):
		for lib: Node in libs:
			lib.SetJoypadState(0, B_START, 0, 0, 0, 0)
		await _wait(6)
		for lib: Node in libs:
			lib.SetJoypadState(0, 0, 0, 0, 0, 0)
		await _wait(24)


func _traffic(lib: Node) -> Array:
	return [int(lib.LinkTraffic(0)), int(lib.LinkSent(0))]


func _run() -> void:
	var root: String = CoreDownloadManager.default_core_root()
	print("[psx-link] rom  %s" % rom.get_file())
	print("[psx-link] root %s" % root)

	var oa: Object = ClassDB.instantiate("Libretro")
	var ob: Object = ClassDB.instantiate("Libretro")
	_a = oa as Node
	_b = ob as Node
	add_child(_a)
	add_child(_b)

	# Runtime option, but set it before start so neither console ever runs a
	# frame believing it has the fixed no-cable port status.
	_a.SetCoreOption(OPT, "enabled")
	_b.SetCoreOption(OPT, "enabled")
	_a.StartContent(root, CORE, rom)
	_b.StartContent(root, CORE, rom)

	# A bare probe wires nothing up for itself, so port 0 has no pad on it and
	# every press goes nowhere. system.gd does this for a real machine; here it
	# has to be said out loud, and its absence looks exactly like a game
	# ignoring input on a title screen.
	await _wait(300)
	# AFTER the core is actually up: StartContent spins the emulation thread and
	# returns, so a port device set on the line after it reaches nothing.
	_a.SetControllerPortDevice(0, 1)   # RETRO_DEVICE_JOYPAD
	_b.SetControllerPortDevice(0, 1)
	await _wait(60)
	_ok("both cores came up",
		int(_a.GetFrameCount()) > 0 and int(_b.GetFrameCount()) > 0,
		"A=%d B=%d" % [_a.GetFrameCount(), _b.GetFrameCount()])

	_ok("uncabled, neither sees a peer",
		int(_a.LinkPeerCount(0)) == 0 and int(_b.LinkPeerCount(0)) == 0)

	# The discriminator. If a menu is reachable uncabled and not cabled, the
	# cable is what changed the game, not the timing of the presses.
	if no_cable:
		print("[psx-link] NO CABLE — control leg")
	else:
		_ok("cabling them together succeeds", bool(_a.LinkConnect(_b, 0, 0)))
	await _wait(4)
	_ok("both ends see the bus",
		int(_a.LinkPeerCount(0)) == 2 and int(_b.LinkPeerCount(0)) == 2,
		"A=%d B=%d" % [_a.LinkPeerCount(0), _b.LinkPeerCount(0)])

	if input_check:
		# ONE console, no cable, START held down hard. If this cannot leave the
		# title screen then nothing about the link is the problem, and every
		# menu theory above it is wasted effort.
		await _wait(2400)
		await _shot("ic_title")
		print("[psx-link] holding START for 240 emulated frames")
		_a.SetJoypadState(0, B_START, 0, 0, 0, 0)
		await _wait(240)
		await _shot("ic_held")
		_a.SetJoypadState(0, 0, 0, 0, 0, 0)
		await _wait(180)
		await _shot("ic_released")
		# And again, as short taps, in case the title wants an edge not a level.
		for i in range(6):
			_a.SetJoypadState(0, B_START, 0, 0, 0, 0)
			await _wait(6)
			_a.SetJoypadState(0, 0, 0, 0, 0, 0)
			await _wait(24)
		await _shot("ic_tapped")
		_a.StopContent()
		_b.StopContent()
		await _wait(60)
		get_tree().quit(0)
		return

	print("[psx-link] booting to the title")
	await _wait(2400)
	await _shot("at_title")

	var before := [_traffic(_a), _traffic(_b)]
	print("[psx-link] traffic at title: A=%s B=%s" % [before[0], before[1]])

	# Keep both machines on the same title/attract phase. Advancing one through
	# the menu while the other watches its demo made the later DOWN press select
	# TWO PLAYER on only one console, so the old probe tested a linked console
	# against a peer that was still on a loading screen.
	print("[psx-link] both machines into the menu")
	await _enter_menus([_a, _b])
	# The attract-to-menu loading screen outlasts the input sequence. Do not
	# send DOWN while either machine can still interpret it as demo input.
	await _wait(600)
	await _shot("after_start")

	# SELECT NUMBER OF PLAYERS: ONE PLAYER / TWO PLAYER / OPTIONS, confirmed
	# with Cross. One DOWN moves off ONE PLAYER onto TWO PLAYER. Both consoles
	# have to choose it -- a linked race is two machines each in two-player
	# mode, not one host offering it.
	for m in [_a, _b]:
		m.SetJoypadState(0, B_DOWN, 0, 0, 0, 0)
		await _wait(10)
		m.SetJoypadState(0, 0, 0, 0, 0, 0)
		await _wait(40)
	await _shot("two_player_highlighted")

	for m in [_a, _b]:
		m.SetJoypadState(0, B_CROSS, 0, 0, 0, 0)
		await _wait(10)
		m.SetJoypadState(0, 0, 0, 0, 0, 0)
		await _wait(120)
	await _shot("two_player_chosen")

	# Class, team, track: each player confirms their own, and the two consoles
	# are deliberately at different points in the flow, so both get pressed
	# every round rather than in lockstep.
	for i in range(9):
		for m in [_a, _b]:
			m.SetJoypadState(0, B_CROSS, 0, 0, 0, 0)
			await _wait(8)
			m.SetJoypadState(0, 0, 0, 0, 0, 0)
			await _wait(30)
		await _wait(240)
		var t := [_traffic(_a), _traffic(_b)]
		print("[psx-link] round %d: A=%s B=%s" % [i, t[0], t[1]])
		await _shot("race_%d" % i)

	await _wait(600)
	await _shot("final")
	var after := [_traffic(_a), _traffic(_b)]
	print("[psx-link] traffic after: A=%s B=%s" % [after[0], after[1]])

	# THE ORACLE, and it has to be a demanding one. "Traffic increased" is
	# satisfied by the dozen bytes a PlayStation spends probing its own serial
	# port at boot, so a probe asserting that passes with no game on the wire at
	# all -- which is how this one read 8/8 while both consoles sat on PRESS
	# START. A linked race trades thousands (the GameCube/GBA probe moves 6247),
	# so the bar is set where only a real conversation clears it.
	const REAL_TRAFFIC := 500
	_ok("machine A sent a game's worth of bytes", after[0][1] - before[0][1] >= REAL_TRAFFIC,
		"sent %d, want >= %d" % [after[0][1] - before[0][1], REAL_TRAFFIC])
	_ok("machine B sent a game's worth of bytes", after[1][1] - before[1][1] >= REAL_TRAFFIC,
		"sent %d, want >= %d" % [after[1][1] - before[1][1], REAL_TRAFFIC])
	_ok("machine A received what B sent", after[0][0] - before[0][0] >= REAL_TRAFFIC,
		"received %d, want >= %d" % [after[0][0] - before[0][0], REAL_TRAFFIC])
	_ok("machine B received what A sent", after[1][0] - before[1][0] >= REAL_TRAFFIC,
		"received %d, want >= %d" % [after[1][0] - before[1][0], REAL_TRAFFIC])

	_a.StopContent()
	_b.StopContent()
	await get_tree().create_timer(2.0).timeout
	print("[psx-link] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)

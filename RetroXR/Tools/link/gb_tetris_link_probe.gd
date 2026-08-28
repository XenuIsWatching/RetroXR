## Tetris, two Game Boys, one lead — the compatibility check the synthetic ROMs
## cannot be.
##
##     "$godot" --headless --path RetroXR res://Tools/link/gb_tetris_link_probe.tscn -- --roms=Z:/roms
##
## gb_link_probe proves a byte crosses the bus and gb_link_room_probe proves the
## room seats the lead that carries it. Both use ROMs written for the purpose,
## which is what makes them precise and also what limits them: they exercise the
## serial port the way the driver expects it to be exercised.
##
## Tetris does not care what the driver expects. Its two-player mode negotiates
## over the wire before it will move at all -- pick 2 PLAYERS with nothing on the
## other end and the screen simply stays there -- so reaching the game type
## screen at all is the assertion, and reaching it on BOTH machines is the proof
## that the negotiation went both ways.
##
## The lead is seated before either machine is switched on, which is what the box
## tells you to do and what a restored room does.
extends Node

## Which core, and how its link is switched on. Both are asked for by name
## because a Game Boy game runs on more than one: gambatte is the room's default
## and mGBA carries a Game Boy core too, and a cable has to work on either.
const LINK_OPTION := {
	"gambatte": ["gambatte_gb_link_mode", "Link Cable"],
	"mgba": ["mgba_link_cable", "ON"],
}

## One per machine, because they need not be the same. The two cores agree on
## the protocol id and the message layout, so a Game Boy run by one and a Game
## Boy run by the other are joined by the same cable -- and if that ever stops
## being true, this is where it shows.
var _cores: Array[String] = ["gambatte", "gambatte"]
var _rom_override := ""

const BTN_A := 1 << 8
const BTN_START := 1 << 3
const BTN_DOWN := 1 << 5
const BTN_RIGHT := 1 << 7
const BTN_LEFT := 1 << 6

var _pass := 0
var _fail := 0
var _m: Array[Libretro] = []
var _opt_backup: Dictionary = {}
var _restored := false
var _shots := 0


func _ready() -> void:
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[tetris] TIMEOUT")
		_restore()
		get_tree().quit(1))
	await _run()


func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--core="):
			_cores = [arg.substr(7), arg.substr(7)]
		elif arg.begins_with("--core2="):
			_cores[1] = arg.substr(8)
		elif arg.begins_with("--rom="):
			_rom_override = arg.substr(6)
	for core in _cores:
		if not LINK_OPTION.has(core):
			print("[tetris] SKIP  no link option known for %s" % core)
			get_tree().quit(0)
			return
	print("[tetris] cores %s and %s" % [_cores[0], _cores[1]])

	var rom := _rom_override if not _rom_override.is_empty() else _find_rom()
	if rom.is_empty():
		print("[tetris] SKIP  no Tetris (World) found; pass --roms=<library>")
		get_tree().quit(0)
		return
	print("[tetris] rom  %s" % rom)

	var root := CoreDownloadManager.default_core_root()
	for core in _cores:
		var have := FileAccess.file_exists(root.path_join("cores").path_join(core + "_libretro.dll"))
		if not have:
			have = FileAccess.file_exists(root.path_join("cores").path_join(core + "_libretro.so"))
		if not have:
			print("[tetris] SKIP  the %s core is not installed" % core)
			get_tree().quit(0)
			return
	if not _enable_link(root):
		print("[tetris] SKIP  could not write the core options file")
		get_tree().quit(0)
		return

	for i in range(2):
		var lib := Libretro.new()
		add_child(lib)
		_m.append(lib)

	# Cable first, then both machines. A Game Boy samples nothing at boot, so this
	# ought to be the easy ordering rather than the hard one -- but it is the one
	# the box asks for and the one a restored room produces, so it is the one
	# that gets tested.
	_ok("the lead goes in before either is switched on", _m[0].LinkConnect(_m[1], 0, 0))
	for i in range(2):
		_m[i].StartContent(root, _cores[i], rom)
	await _frames(600)

	_eq("machine 0 is on the wire", _m[0].LinkPeerCount(0), 2)
	_eq("machine 1 is on the wire", _m[1].LinkPeerCount(0), 2)

	# Deliberately NOT calling SetInputEnabled: that flag lets the wrapper poll
	# the global Godot Input singleton, which overwrites the joypad every frame
	# and throws away everything SetJoypadState puts there.
	await _shot("title")

	# One machine at a time, and this is not politeness -- it is the case.
	#
	# Tetris settles which unit drives the clock by having both send 0x29 until
	# one of them is listening when the other calls. Two machines driven on the
	# same emulated frame both call and neither ever listens: the trace reads as
	# two masters clocking the same tick for ever, each getting the 0xFF of a
	# cable nobody is holding. Real hardware cannot stay in that state because two
	# people are never frame-perfect and two crystals never agree; this can, and
	# will, if a script presses both at once.
	await _one(0, BTN_RIGHT, 8, 20)
	await _one(0, BTN_START, 8, 90)
	await _shot("first_calling")
	var sent_before := _m[0].LinkSent(0)
	await _one(1, BTN_RIGHT, 8, 20)
	await _one(1, BTN_START, 8, 180)
	await _shot("joined")

	var sent := _m[0].LinkSent(0)
	var got := _m[1].LinkTraffic(0)
	print("[tetris] machine 0 sent %d, machine 1 took %d" % [sent, got])
	_ok("the second machine joining puts traffic on the wire", sent > sent_before,
		"sent %d, was %d" % [sent, sent_before])

	var moved0 := await _changed(0, 60)
	var moved1 := await _changed(1, 0)
	_ok("machine 0 left the title screen", moved0)
	_ok("machine 1 left the title screen", moved1)

	# Through the game type and level screens, and into the match.
	#
	# Pressing START a fixed number of times does not survive: the same button
	# picks a game type, confirms a level, starts the match AND pauses it, so one
	# press too many leaves two machines sitting on a frozen board that looks
	# exactly like a link that never started. Press, then LOOK -- which is what a
	# person does anyway.
	await _one(0, BTN_START, 8, 60)
	await _one(1, BTN_START, 8, 150)
	await _shot("level")

	await _one(0, BTN_START, 8, 60)
	await _one(1, BTN_START, 8, 200)
	await _shot("play")

	# And no more START. The same button picks a game type, confirms a level,
	# starts the match AND pauses it, and the pause travels down the wire, so one
	# press too many leaves two machines on a frozen board that looks exactly
	# like a link which never started.
	#
	# Two people playing, which is two different sets of inputs. Each machine
	# draws its OWN board beside its opponent's, so once the two have been played
	# differently the two screens must stop matching -- and each is showing a
	# board it can only have got over the wire.
	var before := _m[0].GetVideoImage().duplicate()
	for round in range(10):
		await _one(0, BTN_LEFT, 6, 14)
		await _one(1, BTN_RIGHT, 6, 14)
		await _one(0, BTN_A, 6, 14)
	await _frames(120)
	await _shot("playing")

	var pic0 := _m[0].GetVideoImage()
	var pic1 := _m[1].GetVideoImage()
	_ok("the match answers the controls", pic0 != null and pic0.get_data() != before.get_data())
	_ok("each machine is showing its own game",
		pic0 != null and pic1 != null and pic0.get_data() != pic1.get_data())

	var busy0 := _m[0].LinkSent(0) - sent
	print("[tetris] %d more messages while the game ran" % busy0)
	_ok("and they keep talking while it plays", busy0 > 0, "sent %d" % busy0)

	for lib in _m:
		lib.StopContent()
	await _frames(120)
	_finish()


## Whether a machine's picture has moved on from the title screen.
func _changed(index: int, settle: int) -> bool:
	if settle > 0:
		await _frames(settle)
	var img := _m[index].GetVideoImage()
	var was: Image = _title_shot[index]
	if img == null or was == null or img.is_empty():
		return false
	return img.get_data() != was.get_data()


var _title_shot: Array = [null, null]


## Both screens, side by side, into one PNG. Watching the pair is the point: a
## link that half works shows two screens that disagree.
func _shot(name: String) -> void:
	var a := _m[0].GetVideoImage()
	var b := _m[1].GetVideoImage()
	if a == null or b == null or a.is_empty() or b.is_empty():
		print("[tetris] shot %s: no picture" % name)
		return
	if name == "title":
		_title_shot = [a.duplicate(), b.duplicate()]
	var w := a.get_width()
	var h := a.get_height()
	var pair := Image.create_empty(w * 2 + 8, h, false, a.get_format())
	pair.fill(Color(0.1, 0.1, 0.12))
	pair.blit_rect(a, Rect2i(0, 0, w, h), Vector2i(0, 0))
	pair.blit_rect(b, Rect2i(0, 0, w, h), Vector2i(w + 8, 0))
	var dir := "res://probe_out/tetris"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	_shots += 1
	pair.save_png("%s/%02d_%s.png" % [dir, _shots, name])
	print("[tetris] shot %s" % name)


func _one(index: int, mask: int, press_frames: int, gap_frames: int) -> void:
	_m[index].SetJoypadState(0, mask, 0, 0, 0, 0)
	await _frames(press_frames)
	_m[index].SetJoypadState(0, 0, 0, 0, 0, 0)
	await _frames(gap_frames)


func _hold(mask: int, press_frames: int, gap_frames: int) -> void:
	for lib in _m:
		lib.SetJoypadState(0, mask, 0, 0, 0, 0)
	await _frames(press_frames)
	for lib in _m:
		lib.SetJoypadState(0, 0, 0, 0, 0, 0)
	await _frames(gap_frames)


## Wait `n` frames of EMULATED time, not of the host's.
##
## A headless run has no audio device to pace against and two cores in one
## process share a machine, so a Game Boy here runs at a fraction of real time
## and by a factor that moves. Counting host frames means a script written
## against a stopwatch and re-timed on every machine it runs on; counting the
## core's own frames means the same script every time.
func _frames(n: int) -> void:
	var target: int = _m[0].GetFrameCount() + n
	var guard := n * 40
	while _m[0].GetFrameCount() < target and guard > 0:
		guard -= 1
		await get_tree().process_frame


func _find_rom() -> String:
	var roots: PackedStringArray = [RomLibrary.default_roms_root()]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--roms="):
			roots.append(arg.substr(7))
	for root in roots:
		for systemid in ["game_boy", "gb"]:
			var dir_path: String = root.path_join(systemid)
			var dir := DirAccess.open(dir_path)
			if dir == null:
				continue
			for f in dir.get_files():
				var low := f.to_lower()
				if low.begins_with("tetris (world)") and low.ends_with(".gb"):
					return dir_path.path_join(f)
	return ""


func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("[tetris] PASS  %s" % name)
	else:
		_fail += 1
		print("[tetris] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])


func _finish() -> void:
	_restore()
	print("[tetris] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _enable_link(root: String) -> bool:
	for core in _cores:
		if _opt_backup.has(core):
			continue
		var path: String = "%s/core_options/%s.opt" % [root, core]
		var existing := ""
		var had := FileAccess.file_exists(path)
		if had:
			var reader := FileAccess.open(path, FileAccess.READ)
			if reader != null:
				existing = reader.get_as_text()
				reader.close()
		_opt_backup[core] = existing if had else null

		var key: String = LINK_OPTION[core][0]
		var lines: PackedStringArray = []
		for line in existing.split("\n", false):
			if not line.begins_with(key):
				lines.append(line)
		lines.append('%s = "%s"' % [key, LINK_OPTION[core][1]])

		var writer := FileAccess.open(path, FileAccess.WRITE)
		if writer == null:
			return false
		writer.store_string("\n".join(lines) + "\n")
		writer.close()
	return true

func _restore() -> void:
	if _restored:
		return
	_restored = true
	var root := CoreDownloadManager.default_core_root()
	for core in _opt_backup:
		var path: String = "%s/core_options/%s.opt" % [root, core]
		if _opt_backup[core] == null:
			DirAccess.remove_absolute(path)
			continue
		var writer := FileAccess.open(path, FileAccess.WRITE)
		if writer != null:
			writer.store_string(str(_opt_backup[core]))
			writer.close()

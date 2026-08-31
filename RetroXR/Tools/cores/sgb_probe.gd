## Super Game Boy probe: does this core really run a Game Boy game as a Super
## Game Boy, and does it need the subsystem to do it?
##
## The one question the catalog row cannot be written from source alone.
## bsnes_libretro.info notes that "SGB Emulation needs No-Intro Super Game Boy
## ROMs renamed to SGB1.sfc or SGB2.sfc" in the system directory, which reads as
## though a plain .gb load would enter SGB mode by itself -- and if it does, the
## `subsystem` block on the ExpansionCatalog row is unnecessary. The source shows
## an sgb subsystem and no such lookup. Rather than pick a reading, measure it.
##
## THE ORACLE IS THE FRAME SIZE, and it is one that cannot pass by accident: a
## Game Boy frame is 160x144 and a Super Game Boy frame is 256x224, because in
## SGB mode the SNES is the machine drawing. A run that comes back 160x144 has no
## border whatever else it prints, and no amount of the core reporting success
## changes that. It also does not depend on the ROM having any SGB support: a
## game that sends no border packets still gets the adapter's default frame, so
## even a generated test ROM answers the question.
##
## ONE CORE PER PROCESS and one LEG per process, the bios_boot_survey rule. A
## core handed content it did not expect runs paths its author may never have
## exercised, and the extension is built -fno-exceptions with no sandbox around
## it. Restarting a core in-process is its own hazard besides.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/cores/sgb_probe.tscn -- \
##       --core=bsnes --rom="$HOME/retroxr/roms/game_boy/game.gb" --leg=subsystem
##
## Windowed rather than --headless when a picture is wanted: the dummy renderer
## gives a HW-render core nowhere to draw. bsnes is software-rendered, so the
## frame size is readable headless too -- but the BORDER is the point of the
## feature, so pass --shot and look at it.
##
## Prints one machine-parsable line:
##   [sgbprobe] RESULT core=<name> leg=<leg> loaded=<yes|no> frames=<n> size=<WxH> sgb=<yes|no>
extends Node3D

## A Game Boy frame, and a Super Game Boy one. The adapter draws the handheld's
## 160x144 into the middle of a full SNES field, so the two are never confused.
const GB_SIZE := Vector2i(160, 144)
const SGB_MIN := Vector2i(256, 224)

## Long enough for the adapter's own program to get past its boot and hand the
## screen to the game. The border arrives in SGB packets during that hand-over,
## so a sample taken too early can be a full-size frame that is still black.
const SAMPLE_AT := [2.0, 5.0, 9.0]

## Where the adapter's program has finished booting and handed the screen over.
## The frame SIZE is right from the first frame -- the SNES is drawing either way
## -- so an early shot can be a full-size blank and prove nothing about the
## border, which is the thing worth looking at. Overridable with --at=2,9,20.
var sample_at: Array = SAMPLE_AT.duplicate()

var core := "bsnes"
## Which load to measure. "subsystem" hands the core the pair through
## retro_load_game_special; "plain" hands it the .gb alone and lets the core find
## its own adapter cartridge, which is the reading being tested.
var leg := "subsystem"
var rom := ""
## The adapter's own cartridge. Defaults to whatever the catalog says the Super
## Game Boy runs, so the probe measures the same file the room would use.
var sgb_rom := ""
var root_dir := ""
var shot := ""

var _lib: Node = null
var _load_failed := ""
var _size := Vector2i.ZERO
var _frames := 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var a := String(arg).strip_edges()
		if a.begins_with("--core="):
			core = a.trim_prefix("--core=")
		elif a.begins_with("--leg="):
			leg = a.trim_prefix("--leg=")
		elif a.begins_with("--rom="):
			rom = a.trim_prefix("--rom=")
		elif a.begins_with("--sgb="):
			sgb_rom = a.trim_prefix("--sgb=")
		elif a.begins_with("--root="):
			root_dir = a.trim_prefix("--root=")
		elif a.begins_with("--shot="):
			shot = a.trim_prefix("--shot=")
		elif a.begins_with("--at="):
			var times: Array = []
			for piece: String in a.trim_prefix("--at=").split(",", false):
				times.append(piece.strip_edges().to_float())
			if not times.is_empty():
				times.sort()
				sample_at = times
	if root_dir.is_empty():
		root_dir = CoreDownloadManager.default_core_root()
	if sgb_rom.is_empty():
		sgb_rom = ExpansionCatalog.firmware_rom_path("super_game_boy")

	get_tree().create_timer(sample_at[-1] + 30.0).timeout.connect(func() -> void:
		print("[sgbprobe] TIMEOUT")
		_report(false)
		get_tree().quit(1))

	if rom.is_empty():
		print("[sgbprobe] SKIP: need --rom=<game>.gb")
		get_tree().quit(2)
		return
	if not FileAccess.file_exists(rom):
		print("[sgbprobe] SKIP: no such Game Boy ROM: %s" % rom)
		get_tree().quit(2)
		return
	# The subsystem leg is refused rather than measured without the adapter's
	# cartridge: there would be nothing to pair the game with, and a core handed a
	# path to a file that is not there is a worse question than no question.
	#
	# The plain leg still runs, and is worth running, but only as a CONTROL. With
	# no cartridge installed the core has nothing to find, so 160x144 there is the
	# expected answer and says nothing about whether the core would have entered
	# SGB mode had the dump been present. Say so rather than let the line be read
	# as a measurement -- it is the most misleading result this probe can print.
	var have_sgb := FileAccess.file_exists(sgb_rom)
	if not have_sgb:
		print("[sgbprobe] no Super Game Boy cartridge at %s" % sgb_rom)
		print("[sgbprobe]   Install it through OPTIONS > Cores > BIOS / Extras, or pass --sgb=<path>.")
		if leg == "subsystem":
			print("[sgbprobe] SKIP: the pairing needs it")
			get_tree().quit(2)
			return
		print("[sgbprobe] CONTROL RUN ONLY: with no dump installed a Game Boy frame is")
		print("[sgbprobe]   the expected result and is NOT evidence about SGB support.")
	if CoreDownloadManager.installed_core_lib(core).is_empty():
		print("[sgbprobe] SKIP: core '%s' is not installed" % core)
		get_tree().quit(2)
		return

	await _measure()


func _measure() -> void:
	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	if _lib == null:
		print("[sgbprobe] FAIL: could not instantiate Libretro node")
		get_tree().quit(1)
		return
	add_child(_lib)
	_lib.connect("content_load_failed", func(reason: String) -> void: _load_failed = reason)

	print("[sgbprobe] core=%s leg=%s root=%s" % [core, leg, root_dir])
	print("[sgbprobe] gb  = %s" % rom)
	print("[sgbprobe] sgb = %s" % sgb_rom)
	if leg == "subsystem":
		# Order is the core's: bsnes declares sgb_roms[] as { "Game Boy ROM",
		# "Super Game Boy ROM" }. The extension logs whatever table the core
		# actually published as it loads, so a mismatch between that and this
		# shows up in the run rather than as a silent wrong-order load.
		_lib.StartSubsystemContent(root_dir, core, rom, "sgb",
			PackedStringArray([rom, sgb_rom]))
	else:
		_lib.StartContent(root_dir, core, rom)

	var t0 := Time.get_ticks_msec()
	for at: float in sample_at:
		while (Time.get_ticks_msec() - t0) < int(at * 1000.0):
			await get_tree().process_frame
			if not _load_failed.is_empty():
				break
		if not _load_failed.is_empty():
			break
		_sample(at)

	if not _load_failed.is_empty():
		print("[sgbprobe] refused: %s" % _load_failed)
	_report_subsystems()
	_report(_load_failed.is_empty())

	_lib.StopContent()
	await get_tree().create_timer(2.0).timeout
	print("[sgbprobe] survived the stop")
	get_tree().quit(_exit_code())


## The frame's colour only, alpha discarded. get_pixel rather than a buffer
## reinterpret because the core's own format is not guaranteed and this runs
## three times a probe, not per frame.
func _rgb_bytes(img: Image) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(img.get_width() * img.get_height() * 3)
	var i := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			out[i] = int(c.r * 255.0)
			out[i + 1] = int(c.g * 255.0)
			out[i + 2] = int(c.b * 255.0)
			i += 3
	return out


func _sample(at: float) -> void:
	_frames = maxi(_frames, int(_lib.GetFrameCount()))
	var img: Image = _lib.GetVideoImage()
	if img != null and not img.is_empty():
		_size = Vector2i(img.get_width(), img.get_height())
		# One PNG PER SAMPLE, not one overwritten file. The frame size is right
		# from the very first frame -- the SNES draws the whole field whether or
		# not the border has arrived -- so a single shot taken at a fixed moment
		# can be a full-size blank, which looks like a failure and is not one.
		# The border lands when the game sends its SGB packets, and when that is
		# depends on the title.
		if not shot.is_empty():
			# Flattened to RGB8 before saving. The core's frame arrives with an
			# alpha channel it never fills, so a straight save_png writes a fully
			# transparent image: 13 KB of real picture that every viewer paints as
			# a blank white rectangle. The border is the entire point of looking,
			# and it was invisible until this line.
			var flat := Image.create_from_data(img.get_width(), img.get_height(),
				false, Image.FORMAT_RGB8, _rgb_bytes(img))
			flat.save_png(shot.get_basename() + ("_%05.1f." % at).replace(" ", "0")
				+ shot.get_extension())
	print("[sgbprobe] t=%4.1f frames=%-6d size=%s" % [
		at, _frames, ("%dx%d" % [_size.x, _size.y]) if _size != Vector2i.ZERO else "(no image)"])


## Is this the adapter drawing, or the handheld?
##
## Compared with >=, not ==: a core is free to hand back a larger buffer than the
## visible field, and what matters is that it is not the handheld's own 160x144.
func _is_sgb() -> bool:
	return _size.x >= SGB_MIN.x and _size.y >= SGB_MIN.y


func _report(loaded: bool) -> void:
	print("[sgbprobe] RESULT core=%s leg=%s loaded=%s frames=%d size=%dx%d sgb=%s" % [
		core, leg, "yes" if loaded else "no", _frames, _size.x, _size.y,
		"yes" if _is_sgb() else "no"])
	if _size == GB_SIZE:
		print("[sgbprobe] that is a bare Game Boy frame -- no adapter, no border")


## Non-zero on anything that would make the catalog row wrong.
##
## The plain leg is a QUESTION rather than a requirement: a "no" there is the
## expected answer and means the subsystem is doing real work, so it is not a
## failure. Only the subsystem leg has to come back as SGB.
func _exit_code() -> int:
	if not _load_failed.is_empty():
		return 1
	if _frames <= 0:
		return 1
	if leg == "subsystem" and not _is_sgb():
		return 1
	return 0


## What the core actually published, which is the half of the row that can be
## checked without owning a copyrighted cartridge.
##
## SET_SUBSYSTEM_INFO arrives during retro_set_environment, inside the core load,
## so the extension has already logged the whole table by the time any content is
## touched. Printed here as well so the RESULT line has the ident beside it and a
## survey does not have to scrape the extension's own log lines.
func _report_subsystems() -> void:
	print("[sgbprobe] (the extension logs each published subsystem above as it loads;")
	print("[sgbprobe]  'sgb' with 2 rom(s) is what the ExpansionCatalog row names)")

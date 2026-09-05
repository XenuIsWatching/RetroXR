## Boot the e-Reader, hand it a real dotcode card, and photograph the result.
##
## Wants the e-Reader cartridge dump and a real .raw strip, so a probe.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##     res://Tools/cores/ereader_scan_probe.tscn -- --core=mgba_ereader \
##     "--rom=<ereader.gba>" "--card=<strip.raw>" --at=2,4,6,8,10,12
##
## WINDOWED, not --headless: the dummy renderer hands back a correctly sized
## frame with nothing drawn into it, so a size check passes while every shot is
## blank. The card decoding is the whole point of looking.
##
## THE SHOT IS THE ORACLE, and there is no assertion here on purpose. What a card
## did is a screen -- a title, "Now Reading...", a prompt for the next strip, a
## read error -- and nothing the frontend can query says which. `--expect` states
## what the run is looking for so the footage can be read against an intention
## rather than after the fact; it is not checked, and must not be made to look as
## though it were.
extends Node

const BTN_A := 1 << 8
const BTN_B := 1 << 0
const BTN_START := 1 << 3
const BTN_DOWN := 1 << 5

var _lib: Node = null
var _core := "mgba_ereader"
var _rom := ""
var _card := ""
var _shot := "res://probe_out/ereader"
var _at: Array[float] = [2.0, 4.0, 6.0, 8.0, 10.0, 12.0]
## When each strip is drawn past the head, one entry per strip in `--card` order.
## A single value with several strips delivers them all at that moment, which is
## a swipe of every card at once -- only the last one survives. Give each its own.
var _scan_at: Array[float] = [6.0]
var _press_every := 1.5
## Nothing is pressed before this. The e-Reader spends about five seconds on its
## boot logos, and a press that lands there walks into the scan prompt with no
## card at the head, which reads a bare scanner and reports a read error.
var _press_from := 6.0
## What this run is looking for, printed and not checked. See the header.
var _expect := ""
var _sram := ""
var _bios := true
var _presses := 2
var _pressed := 0
## When to press B. A multi-strip card asks for the next strip on the CARD READ
## command, which is B on the application screen.
var _b_at: Array[float] = []
var _b_done := 0
## Late A presses, for the START command once every strip is in.
var _a_at: Array[float] = []
var _a_done := 0
## Menu cursor moves, for a reader whose saved-data entry is not the first row.
var _down_at: Array[float] = []
var _down_done := 0
var _failed := ""
## How many strips have been delivered so far.
var _scanned := 0
var _size := Vector2i.ZERO


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--core="):
			_core = a.substr(7)
		elif a.begins_with("--rom="):
			_rom = a.substr(6)
		elif a.begins_with("--card="):
			_card = a.substr(7)
		elif a.begins_with("--shot="):
			_shot = a.substr(7)
		elif a.begins_with("--scan-at="):
			_scan_at.clear()
			for p in a.substr(10).split(","):
				_scan_at.append(p.to_float())
		elif a.begins_with("--expect="):
			_expect = a.substr(9)
		elif a.begins_with("--press-every="):
			_press_every = a.substr(14).to_float()
		elif a.begins_with("--press-from="):
			_press_from = a.substr(13).to_float()
		elif a.begins_with("--sram="):
			_sram = a.substr(7)
		elif a == "--no-bios":
			_bios = false
		elif a.begins_with("--presses="):
			_presses = a.substr(10).to_int()
		elif a.begins_with("--b-at="):
			for p in a.substr(7).split(","):
				_b_at.append(p.to_float())
		elif a.begins_with("--a-at="):
			for p in a.substr(7).split(","):
				_a_at.append(p.to_float())
		elif a.begins_with("--down-at="):
			for p in a.substr(10).split(","):
				_down_at.append(p.to_float())
		elif a.begins_with("--at="):
			_at.clear()
			for p in a.substr(5).split(","):
				_at.append(p.to_float())

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://probe_out"))

	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	add_child(_lib)
	_lib.connect("content_load_failed", func(r: String) -> void: _failed = r)
	_lib.connect("disk_control_ready",
		func(h: bool, c: int, i: int, e: bool) -> void:
			print("[scan] disk has=%s images=%d index=%d ejected=%s" % [h, c, i, e]))

	# The e-Reader keeps its own state in FLASH1M. Booting on blank flash is a
	# machine that has never been set up, which is not the same machine.
	if not _sram.is_empty() and _lib.has_method("SetSramPath"):
		_lib.SetSramPath(_sram)
		print("[scan] sram=%s" % _sram)
	# The real BIOS, which is what BiosBoot pins for this core. The e-Reader
	# raises a GAMEPAK IRQ while scanning and drives the scanner on hardware
	# timing, so an HLE BIOS is not the machine this cartridge expects.
	if _bios and _lib.has_method("SetCoreOption"):
		_lib.SetCoreOption("mgba_use_bios", "ON")
		_lib.SetCoreOption("mgba_skip_bios", "OFF")
		print("[scan] bios=ON")
	print("[scan] core=%s" % _core)
	print("[scan] rom=%s" % _rom)
	for p in _card.split(";"):
		var s := p.strip_edges()
		if not s.is_empty():
			print("[scan] card=%s (%d bytes)" % [s.get_file(), _size_of(s)])
	_lib.StartContent(CoreDownloadManager.default_core_root(), _core, _rom)

	await _drive()
	_report()


func _size_of(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return int(n)


## Run the machine on a clock.
##
## THE CARD GOES IN WHILE THE READER IS ASKING FOR ONE, and this ordering is the
## whole of the probe. There is no queue: `GBACartEReaderQueueCard` decodes the
## strip straight into the dot buffer if the scanner is powered and drops it on
## the floor if it is not, so a strip delivered during the boot logos or on a
## menu is simply gone. Navigate to the card-read screen FIRST, then deliver --
## the reverse of the order this probe used when a card could sit in a FIFO.
##
## One swipe is also one read: after the pass the dot code goes with the card, so
## a multi-strip title asks for its next strip and gets it only from a second
## delivery. That is why `--scan-at` takes one time per strip rather than one
## time for the lot.
func _drive() -> void:
	# Seeded from press_from, not press_every: starting it at the interval makes
	# the release deadline already past on the first press, so the button is held
	# for no emulated frames at all and the menu never sees it.
	var next_press := _press_from
	var shot_i := 0
	var held := false
	while true:
		await get_tree().process_frame
		if not _failed.is_empty():
			return
		# EMULATED frames, not wall clock. Frame pacing varies enough between runs
		# that a menu driven on seconds lands on a different screen each time --
		# which is how the same invocation reached "Read Start" once and the title
		# the next. Frames are what the machine actually counts.
		var t := float(_lib.GetFrameCount()) / 60.0
		if t > (_at[_at.size() - 1] + 1.0):
			return

		# These walk the reader to its card-read screen. They are what has to land
		# FIRST: a strip delivered before the scanner is powered is dropped, so
		# every --scan-at belongs after the menu has arrived.
		if _press_every > 0.0 and t >= _press_from and _pressed < _presses:
			# A short press, then release. A button held for ever is a button the
			# menu never sees a fresh edge from.
			if not held and t >= next_press:
				_lib.SetJoypadState(0, BTN_A, 0, 0, 0, 0)
				held = true
			elif held and t >= next_press + 0.2:
				_lib.SetJoypadState(0, 0, 0, 0, 0, 0)
				held = false
				next_press += _press_every
				_pressed += 1
		elif held:
			_lib.SetJoypadState(0, 0, 0, 0, 0, 0)
			held = false

		var cards := _cards()
		while _scanned < cards.size() and _scanned < _scan_at.size() and t >= _scan_at[_scanned]:
			var path := cards[_scanned]
			print("[scan] t=%.1f delivering %s" % [t, path.get_file()])
			_lib.SetDiskEjectState(true)
			_lib.ReplaceDiskImage(0, path)
			_lib.SetDiskEjectState(false)
			_lib.RequestDiskInfo()
			_scanned += 1

		if _down_done < _down_at.size() and t >= _down_at[_down_done]:
			if t < _down_at[_down_done] + 0.2:
				_lib.SetJoypadState(0, BTN_DOWN, 0, 0, 0, 0)
			else:
				_lib.SetJoypadState(0, 0, 0, 0, 0, 0)
				_down_done += 1
				print("[scan] t=%.1f pressed DOWN" % t)

		if _a_done < _a_at.size() and t >= _a_at[_a_done]:
			if t < _a_at[_a_done] + 0.2:
				_lib.SetJoypadState(0, BTN_A, 0, 0, 0, 0)
			else:
				_lib.SetJoypadState(0, 0, 0, 0, 0, 0)
				_a_done += 1
				print("[scan] t=%.1f pressed A (start)" % t)

		if _b_done < _b_at.size() and t >= _b_at[_b_done]:
			if t < _b_at[_b_done] + 0.2:
				_lib.SetJoypadState(0, BTN_B, 0, 0, 0, 0)
			else:
				_lib.SetJoypadState(0, 0, 0, 0, 0, 0)
				_b_done += 1
				print("[scan] t=%.1f pressed B (card read)" % t)

		while shot_i < _at.size() and t >= _at[shot_i]:
			_sample(_at[shot_i])
			shot_i += 1


## Every strip to queue, in order. A two-strip card is two entries.
func _cards() -> PackedStringArray:
	var out := PackedStringArray()
	for p in _card.split(";"):
		var s := p.strip_edges()
		if not s.is_empty():
			out.append(s)
	return out


func _sample(at: float) -> void:
	var img: Image = _lib.GetVideoImage()
	var frames: int = int(_lib.GetFrameCount())
	if img != null and not img.is_empty():
		_size = Vector2i(img.get_width(), img.get_height())
		# Flattened to RGB8: the core never fills alpha, so a straight save_png
		# writes a fully transparent image that every viewer paints blank.
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
		var flat := Image.create_from_data(img.get_width(), img.get_height(),
			false, Image.FORMAT_RGB8, out)
		var path := "%s_%05.1f.png" % [_shot, at]
		flat.save_png(path.replace(" ", "0"))
	print("[scan] t=%4.1f frames=%-6d size=%s" % [
		at, frames, ("%dx%d" % [_size.x, _size.y]) if _size != Vector2i.ZERO else "(none)"])


func _report() -> void:
	if not _failed.is_empty():
		print("[scan] FAIL: %s" % _failed)
		get_tree().quit(1)
		return
	print("[scan] RESULT frames=%d size=%dx%d delivered=%d/%d expect=%s" % [
		int(_lib.GetFrameCount()), _size.x, _size.y, _scanned, _cards().size(),
		_expect if not _expect.is_empty() else "(unstated)"])
	get_tree().quit(0)

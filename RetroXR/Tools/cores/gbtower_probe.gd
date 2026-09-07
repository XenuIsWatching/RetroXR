extends Node

## Drive Pokemon Stadium to the GB Tower with a cartridge in the Transfer Pak,
## and PHOTOGRAPH it. The failure being chased is a message on screen -- "The
## Transfer Pak is not set properly" -- which no log line and no savestate byte
## reports, so the only oracle is the picture.
##
## Windowed, never --headless: the dummy renderer hands back a correctly sized
## frame with nothing drawn into it, so a headless run photographs a blank and
## calls it a pass.
##
##     "$godot" --path RetroXR --resolution 640x480 --position 20,20 \
##         res://Tools/cores/gbtower_probe.tscn -- \
##         --n64="Z:/roms/n64/Pokemon Stadium (USA).z64" --gb="<a .gb>" \
##         --out=res://probe_out/gbt --secs=70

const CORE := "mupen64plus_next"

const BTN_B     := 1 << 0
const BTN_START := 1 << 3
const BTN_UP    := 1 << 4
const BTN_DOWN  := 1 << 5
const BTN_LEFT  := 1 << 6
const BTN_RIGHT := 1 << 7
const BTN_A     := 1 << 8

var _lib: Libretro
var _n64 := ""
var _gb := ""
var _out := "res://probe_out/gbt"
var _secs := 70.0
## "bridge" = the per-port interface this project added.
## "subsystem" = the core's own upstream route, which sets one pair of
## globals shared by all four ports. Running both is the only way to tell
## a bug in the bridge from a bug in the core's pak emulation.
var _leg := "bridge"
## Which RDP plugin to pin. GLideN64 is known not to run the GB Tower
## (GLideN64 issue 1846); the core's own option text says to use
## Angrylion for compatibility and GLideN64 only for performance.
var _rdp := ""
## Which RSP plugin to pin. The GB Tower is a candidate for custom
## microcode, and an HLE RSP that does not implement it would leave the
## CPU running at full speed while the framebuffer stays entirely blank --
## which is exactly what is measured here, and is independent of the RDP.
var _rsp := ""
var _t := 0.0
var _shot_at := 0.0
var _held := 0
var _release_at := -1.0
var _steps: Array = []
var _step := 0
var _started := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--n64="):
			_n64 = s.substr(6)
		elif s.begins_with("--gb="):
			_gb = s.substr(5)
		elif s.begins_with("--out="):
			_out = s.substr(6)
		elif s.begins_with("--leg="):
			_leg = s.substr(6)
		elif s.begins_with("--rdp="):
			_rdp = s.substr(6)
		elif s.begins_with("--rsp="):
			_rsp = s.substr(6)
		elif s.begins_with("--secs="):
			_secs = float(s.substr(7))
	if _n64.is_empty() or _gb.is_empty():
		print("[gbt] FAIL need --n64 and --gb")
		get_tree().quit(2)
		return

	DirAccess.make_dir_recursive_absolute(_out.get_base_dir())
	print("[gbt] n64 %s" % _n64)
	print("[gbt] gb  %s" % _gb)

	_lib = Libretro.new()
	add_child(_lib)
	_lib.options_ready.connect(_on_options_ready)
	_lib.content_load_failed.connect(func(r: String) -> void:
		print("[gbt] FAIL load %s" % r); get_tree().quit(1))

	var root := CoreDownloadManager.default_core_root()
	var sav_dir := "%s/save/%s" % [root, CORE]
	DirAccess.make_dir_recursive_absolute(sav_dir)
	_lib.SetTransferPak(0, _gb, "%s/%s.sav" % [sav_dir, _gb.get_file().get_basename()])
	print("[gbt] SetTransferPak port0=%s" % _gb.get_file())
	# Announce a pad on port 1, which the room does on every bind and this
	# probe was not doing. The core copies pad_present[] into
	# control->Present when it initialises the controllers, and a port with
	# no controller has no pak either -- so without this the probe was
	# testing a machine with nothing plugged into it.
	_lib.SetControllerPortDevice(0, 1)   # RETRO_DEVICE_JOYPAD

	# Pin the pak option into the core's own option file BEFORE it boots.
	# Setting it once the core is up is too late for anything that reads the
	# pak while starting: Stadium runs its Game Pak Check during boot and shows
	# "Game Pak None" for a pak switched on afterwards. The core reads this file
	# as it comes up, so a pak decided here is there for that first read.
	#
	# The key comes from what the core wrote on a previous run rather than being
	# composed -- the prefix is whatever CORE_NAME it was built with.
	if not _rsp.is_empty():
		CoreOptionsStore.merge_values(root, CORE, {"mupen64plus-rsp-plugin": _rsp})
		print("[gbt] pinned rsp-plugin = %s before boot" % _rsp)
	if not _rdp.is_empty():
		CoreOptionsStore.merge_values(root, CORE, {"mupen64plus-rdp-plugin": _rdp})
		print("[gbt] pinned rdp-plugin = %s before boot" % _rdp)
	var saved: Dictionary = CoreOptionsStore.load_values(root, CORE)
	for key: String in saved:
		if key.ends_with("-pak1"):
			CoreOptionsStore.merge_values(root, CORE, {key: "transfer"})
			print("[gbt] pinned %s = transfer before boot" % key)
			break

	if _leg == "subsystem":
		# The core's own route: slot order is GB save, GB ROM, then the N64
		# cartridge LAST. The wrapper refuses a load whose declared slots do not
		# all exist, so the save has to be on disk before the call.
		var save := "%s/%s.sav" % [sav_dir, _gb.get_file().get_basename()]
		if not FileAccess.file_exists(save):
			var blank := PackedByteArray()
			blank.resize(0x8000)
			var f := FileAccess.open(save, FileAccess.WRITE)
			f.store_buffer(blank)
			f.close()
		print("[gbt] StartSubsystemContent ident=gb (core's own route)")
		_lib.StartSubsystemContent(root, CORE, _n64, "gb", PackedStringArray([save, _gb, _n64]))
	else:
		print("[gbt] StartContent (plain, per-port bridge)")
		_lib.StartContent(root, CORE, _n64)

	# The route by hand: mash through the attract sequence and the title, then
	# one RIGHT to move off the default menu entry onto the Game Boy tower, then
	# confirm. Timed rather than driven off the picture -- reading the menu would
	# need OCR, and a shot every second is enough to see where it actually got to.
	_steps = [
		# Attract sequence and title.
		{"t":  6.0, "b": BTN_START}, {"t":  8.0, "b": BTN_A},
		{"t": 10.0, "b": BTN_START}, {"t": 12.0, "b": BTN_A},
		{"t": 14.0, "b": BTN_START},
		# B acknowledges the Game Pak Check; A sits on its OK? button and re-runs
		# the check. B again on POKEMON STADIUM opens the row the tower is on.
		{"t": 17.0, "b": BTN_B},
		{"t": 21.0, "b": BTN_B},
		{"t": 25.0, "b": BTN_RIGHT},
		{"t": 29.0, "b": BTN_B},
		# Inside, the tower asks which Game Pak to use and shows one slot per
		# controller. Only port 1 holds a cartridge, so walk LEFT onto it before
		# confirming -- confirming an EMPTY slot is itself answered with "the
		# Transfer Pak is not set properly", which is indistinguishable from a
		# broken pak unless you know where the cursor was.
		{"t": 34.0, "b": BTN_LEFT},
		{"t": 36.0, "b": BTN_LEFT},
		{"t": 38.0, "b": BTN_LEFT},
		{"t": 41.0, "b": BTN_B},
		# And then NOTHING. The tower answers the confirm with "Loading. Please
		# wait..." and B during that load cancels it, which the game reports as the
		# pak not being set properly -- the same message as a real fault.
	]


func _on_options_ready(_c: Dictionary, definitions: Dictionary, current: Dictionary) -> void:
	for key: String in definitions:
		if key.ends_with("-pak1"):
			_lib.SetControllerPortDevice(0, 1)
			_lib.SetCoreOption(key, "transfer")
			print("[gbt] %s = transfer (was %s)" % [key, current.get(key, "<unset>")])
			return
	print("[gbt] FAIL no -pak1 option")


func _process(dt: float) -> void:
	if _lib == null:
		return
	if not _started:
		if _lib.GetFrameCount() > 0:
			_started = true
			print("[gbt] core running")
		return
	_t += dt

	# Buttons are pressed for a beat and released; a held button reads as a
	# repeat and walks straight past the entry it was meant to pick.
	if _release_at > 0.0 and _t >= _release_at:
		_lib.SetJoypadState(0, 0, 0, 0, 0, 0)
		_held = 0
		_release_at = -1.0
	if _step < _steps.size() and _t >= float(_steps[_step]["t"]):
		_held = int(_steps[_step]["b"])
		_lib.SetJoypadState(0, _held, 0, 0, 0, 0)
		_release_at = _t + 0.15
		_step += 1

	if _t >= _shot_at:
		_shot_at += 1.0
		_shoot()

	if _t >= _secs:
		print("[gbt] done, %d core frames" % _lib.GetFrameCount())
		_lib.StopContent()
		get_tree().create_timer(1.0).timeout.connect(func() -> void: get_tree().quit(0))
		set_process(false)


func _shoot() -> void:
	var img: Image = _lib.GetVideoImage()
	if img == null or img.is_empty():
		return
	# Flattened to RGB8 first. The core's frame carries an alpha channel it never
	# fills, so a straight save_png writes a fully transparent image that every
	# viewer paints as a blank white rectangle -- which is exactly what a broken
	# pak would also look like.
	var flat := Image.create_from_data(img.get_width(), img.get_height(),
		false, Image.FORMAT_RGB8, _rgb_bytes(img))
	var p := "%s_%03d.png" % [_out, int(_t)]
	flat.save_png(p)
	print("[gbt] t=%3ds %dx%d -> %s" % [int(_t), img.get_width(), img.get_height(), p])


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

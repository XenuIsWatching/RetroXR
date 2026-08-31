## Sufami Turbo probe: does snes9x really take two cartridges, and does it know
## they are Sufami Turbo cartridges rather than a generic multi-cart pair?
##
## THE ORACLE IS THE CORE'S OWN LOG, because the two things worth telling apart
## both draw a 256x224 Super Famicom field. snes9x's Multi-Cart Link case sniffs
## the FIRST cartridge and branches:
##
##   is_SufamiTurbo_Cart(A)  ->  "Cart is Sufami Turbo..."
##                               then LoadBIOS("STBIOS.bin"), and ONLY on success
##                               LoadMultiCartMem(A, B, bios) + Map_SufamiTurbo*
##   otherwise               ->  "Loading Multi-Cart link game"
##                               LoadMultiCartMem(A, B, NULL) -- no BIOS
##
## MEASURED, and it corrects the obvious guess: a missing STBIOS.bin does NOT
## fall through to the generic branch. `rom_loaded` simply stays false and the
## load is refused -- 0 frames, content_load_failed, exit 1. That is a much
## better failure than the silent wrong picture it was assumed to be.
##
## So "Cart is Sufami Turbo" prints in BOTH the working case and the missing-BIOS
## case and is not on its own a pass. What separates them:
##
##   worked          "Cart is Sufami Turbo" + "Map_SufamiTurboLoROMMap",
##                   loaded=yes, frames > 0
##   no STBIOS.bin   "Cart is Sufami Turbo", loaded=no, frames = 0
##   not ST carts    "Loading Multi-Cart link game"
##
## `--expect=sufami|generic` records which was intended; the caller greps for the
## line, since this process cannot read its own log (see _report).
##
## ONE CORE PER PROCESS, the bios_boot_survey rule.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/cores/sufami_probe.tscn -- \
##       --a="$HOME/retroxr/roms/sufami_turbo/SD Ultra Battle - Ultraman Densetsu (Japan).sfc" \
##       --b="$HOME/retroxr/roms/sufami_turbo/SD Ultra Battle - Seven Densetsu (Japan).sfc"
##
## Windowed when a picture is wanted: --headless returns a correctly SIZED frame
## with nothing drawn into it, so the shot comes back blank while every number
## reads correct.
##
## Prints one machine-parsable line:
##   [stprobe] RESULT core=<name> carts=<n> loaded=<yes|no> frames=<n> size=<WxH> branch=<sufami|generic|none>
extends Node3D

## Long enough for the adapter's shell to hand the screen to the cartridge.
const SAMPLE_AT := [3.0, 8.0, 14.0]

var core := "snes9x"
var cart_a := ""
var cart_b := ""
var root_dir := ""
var shot := ""
## Which branch the run is asserted to take. Empty measures without judging.
var expect := ""
## Where to flush the save, so its SIZE can be read back. Answers whether one
## file covers both cartridges of a linked pair.
var sram := ""

var _lib: Node = null
var _load_failed := ""
var _size := Vector2i.ZERO
var _frames := 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var a := String(arg).strip_edges()
		if a.begins_with("--core="):
			core = a.trim_prefix("--core=")
		elif a.begins_with("--a="):
			cart_a = a.trim_prefix("--a=")
		elif a.begins_with("--b="):
			cart_b = a.trim_prefix("--b=")
		elif a.begins_with("--root="):
			root_dir = a.trim_prefix("--root=")
		elif a.begins_with("--shot="):
			shot = a.trim_prefix("--shot=")
		elif a.begins_with("--expect="):
			expect = a.trim_prefix("--expect=")
		elif a.begins_with("--sram="):
			sram = a.trim_prefix("--sram=")
	if root_dir.is_empty():
		root_dir = CoreDownloadManager.default_core_root()

	get_tree().create_timer(SAMPLE_AT[-1] + 30.0).timeout.connect(func() -> void:
		print("[stprobe] TIMEOUT")
		_report(false)
		get_tree().quit(1))

	if cart_a.is_empty() or not FileAccess.file_exists(cart_a):
		print("[stprobe] SKIP: need --a=<cart>.sfc that exists")
		get_tree().quit(2)
		return
	if not cart_b.is_empty() and not FileAccess.file_exists(cart_b):
		print("[stprobe] SKIP: no such second cartridge: %s" % cart_b)
		get_tree().quit(2)
		return
	if CoreDownloadManager.installed_core_lib(core).is_empty():
		print("[stprobe] SKIP: core '%s' is not installed" % core)
		get_tree().quit(2)
		return

	# Said out loud rather than assumed, because its absence is exactly what
	# sends the load down the branch this probe exists to distinguish.
	var bios := FirmwareRequirements.destination(core, "STBIOS.bin")
	print("[stprobe] STBIOS.bin %s at %s"
		% ["present" if FileAccess.file_exists(bios) else "MISSING", bios])

	_check_headers()
	await _measure()


## The core decides what these files are from their headers, so read the same
## bytes it will and say so. A cartridge outside 0x80000-0x100000, or without the
## BANDAI magic, takes the generic branch no matter how it is named.
func _check_headers() -> void:
	for path: String in [cart_a, cart_b]:
		if path.is_empty():
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var head := f.get_buffer(0x20)
		var size := f.get_length()
		f.close()
		var magic := head.slice(0, 14).get_string_from_ascii()
		var backup := head.slice(0x10, 0x1E).get_string_from_ascii()
		var ok := size >= 0x80000 and size <= 0x100000 \
			and magic == "BANDAI SFC-ADX" and backup != "SFC-ADX BACKUP"
		print("[stprobe] %s  %d bytes  magic=%s  sufami_cart=%s"
			% [path.get_file(), size, magic, "yes" if ok else "NO"])


func _measure() -> void:
	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	if _lib == null:
		print("[stprobe] FAIL: could not instantiate Libretro node")
		get_tree().quit(1)
		return
	add_child(_lib)
	_lib.connect("content_load_failed", func(reason: String) -> void: _load_failed = reason)
	# How big the save actually is, which is the whole of the two-cartridge save
	# question. snes9x puts slot A's SRAM at the start of one block and slot B's
	# 0x10000 into the same block, so if the region handed over covers both then
	# one file already carries both cartridges -- and if it does not, a linked
	# pair loses half its progress with nothing to show for it.
	_lib.connect("sram_flushed", func(path: String, size: int, final_flush: bool) -> void:
		print("[stprobe] sram flushed: %d bytes%s -> %s"
			% [size, " (final)" if final_flush else "", path.get_file()]))
	if not sram.is_empty():
		_lib.SetSramPath(sram)

	var carts: Array[String] = [cart_a]
	if not cart_b.is_empty():
		carts.append(cart_b)
	print("[stprobe] core=%s carts=%d root=%s" % [core, carts.size(), root_dir])

	if carts.size() == 2:
		# Order is the core's: multicart_roms[] is { "Cart A", "Cart B" }, and it
		# is cart A whose header decides the branch.
		_lib.StartSubsystemContent(root_dir, core, cart_a, "multicart_addon",
			PackedStringArray(carts))
	else:
		# One cartridge is its own configuration, not half a pair: retro_load_game
		# sniffs the header itself and maps slot B empty.
		_lib.StartContent(root_dir, core, cart_a)

	var t0 := Time.get_ticks_msec()
	for at: float in SAMPLE_AT:
		while (Time.get_ticks_msec() - t0) < int(at * 1000.0):
			await get_tree().process_frame
			if not _load_failed.is_empty():
				break
		if not _load_failed.is_empty():
			break
		_sample(at)

	if not _load_failed.is_empty():
		print("[stprobe] refused: %s" % _load_failed)
	_report(_load_failed.is_empty())

	if not sram.is_empty():
		_lib.RequestSramFlush()
		await get_tree().create_timer(1.5).timeout

	_lib.StopContent()
	await get_tree().create_timer(2.0).timeout
	print("[stprobe] survived the stop")
	get_tree().quit(_exit_code())


func _sample(at: float) -> void:
	_frames = maxi(_frames, int(_lib.GetFrameCount()))
	var img: Image = _lib.GetVideoImage()
	if img != null and not img.is_empty():
		_size = Vector2i(img.get_width(), img.get_height())
		if not shot.is_empty():
			# Flattened to RGB8. The core's frame carries an alpha channel it
			# never fills, so a straight save_png writes a fully transparent
			# image -- real picture that every viewer paints as a blank white
			# rectangle.
			var flat := Image.create_from_data(img.get_width(), img.get_height(),
				false, Image.FORMAT_RGB8, _rgb_bytes(img))
			flat.save_png(shot.get_basename() + ("_%05.1f." % at).replace(" ", "0")
				+ shot.get_extension())
	print("[stprobe] t=%4.1f frames=%-6d size=%s" % [
		at, _frames, ("%dx%d" % [_size.x, _size.y]) if _size != Vector2i.ZERO else "(no image)"])


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


## No `branch=` field, deliberately.
##
## The branch is the one thing worth knowing and the one thing this process
## cannot see: the core reports it through the libretro log callback, which the
## extension forwards straight to stdout and exposes to GDScript through no
## signal at all (Libretro publishes savestate, netplay, led, sram, options and
## load-failure signals -- there is no log one). A `branch=` printed from in here
## could only ever be a guess, and a guess that read "none" on a run that had
## just taken the Sufami path would be worse than saying nothing.
##
## So the oracle lives in the CALLER, which greps this run's output. That is not
## a weaker check -- the lines are unambiguous and the wrong branch prints a
## different one -- it just is not this function's to make.
func _report(loaded: bool) -> void:
	print("[stprobe] RESULT core=%s carts=%d loaded=%s frames=%d size=%dx%d" % [
		core, 1 if cart_b.is_empty() else 2, "yes" if loaded else "no",
		_frames, _size.x, _size.y])
	print("[stprobe] BRANCH: grep this run for the core's own lines --")
	print("[stprobe]   \"Map_SufamiTurboLoROMMap\"   the adapter really mapped")
	print("[stprobe]   \"Cart is Sufami Turbo\"      cart A sniffed as one; prints")
	print("[stprobe]                                even when STBIOS.bin is absent")
	print("[stprobe]                                and the load is then REFUSED")
	print("[stprobe]   \"Loading Multi-Cart link\"   generic pair, not Sufami at all")
	if not expect.is_empty():
		print("[stprobe] EXPECTED: %s" % expect)


func _exit_code() -> int:
	if not _load_failed.is_empty():
		return 1
	if _frames <= 0:
		return 1
	return 0

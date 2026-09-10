## VMU overlay probe — WHERE in the frame flycast draws the VMU screen.
##
## flycast has no second video output: it burns each VMU's 48 x 32 LCD into the
## main framebuffer at a chosen corner, size and opacity. To put that screen on
## the card's own face in the room, RetroXR crops it back out with
## screen_window.gdshader — the same mechanism the 3DS bottom screen uses. That
## needs the rect, in the frame's own pixels, for each position and size the core
## offers.
##
##     "$godot" --path RetroXR --resolution 320x240 --position 20,20 \
##         res://Tools/cores/vmu_overlay_probe.tscn -- \
##         --rom="$HOME/retroxr/roms/dreamcast/Crazy Taxi 2 (USA).chd" \
##         [--position="Upper Left"] [--size=4x] [--at=6,12]
##
## **Measured, not eyeballed.** The LCD's OFF pixels are pinned to a colour no
## Dreamcast boot screen contains, and the rect is the bounding box of pixels
## matching it. A screenshot read by eye would give a rect to the nearest guess;
## this gives it to the pixel, and it fails loudly when the overlay is absent
## rather than quietly returning a plausible box.
##
## Run WINDOWED, not headless: the dummy renderer hands back a correctly sized
## frame with nothing drawn into it, so a probe that only checks the size passes
## on a blank image. That trap cost the Super Game Boy probe a round trip.
##
## MEASURED 2026-09-09, Flycast 5aa091f, 640x480 output, across Upper Left 1x,
## Upper Left 4x and Lower Right 2x. The rule is exact:
##
##     w = 48 * mult          h = 32 * mult
##     x = 8                  when the position is *Left
##       = frame_w - 8 - w    when it is *Right
##     y = 8                  when the position is Upper*
##       = frame_h - 8 - h    when it is Lower*
##
## The inset is a constant 8 px from the chosen corner in both axes, at every
## position and every multiplier, and the panel is a whole multiple of the LCD to
## the pixel (24576 = 192x128, 1536 = 48x32, 6144 = 96x64). So a source_rect can
## be derived from the live texture size alone — which it must be, since the
## frame's size follows the core's resolution.
##
## Two gates have to be open before any of this appears, and neither is obvious:
##
##   1. A CONTROLLER must be announced at load. A VMU is in the controller's
##      expansion socket, so no pad means no socket. RetroXR skipped announcing a
##      plain joypad until this probe found it.
##   2. flycast reads the per-slot device options ONLY when `!first_startup`, so
##      the load pass leaves MapleExpansionDevices at its static default and
##      creates no VMU. A SECOND update_variables() does read them, and the
##      frontend triggers one by marking a variable updated — SetCoreOption is
##      enough. Without that nudge there is a controller and still no card.
##
## Writes the player's real flycast.opt, and restores it on the way out.
extends Node

const KEY_SHOW     := "reicast_show_vmu_screen_settings"
const KEY_DISPLAY  := "reicast_vmu1_screen_display"
const KEY_POSITION := "reicast_vmu1_screen_position"
const KEY_SIZE     := "reicast_vmu1_screen_size_mult"
const KEY_OPACITY  := "reicast_vmu1_screen_opacity"
const KEY_ON       := "reicast_vmu1_pixel_on_color"
const KEY_OFF      := "reicast_vmu1_pixel_off_color"
const KEY_SLOT1    := "reicast_device_port1_slot1"

## The LCD is 48 x 32 dots. Anything the probe measures should be a whole
## multiple of that.
const LCD_W := 48
const LCD_H := 32

## RETRO_DEVICE_JOYPAD.
const DEVICE_JOYPAD := 1

## RETRO_DEVICE_ANALOG. See the --device note in _measure.
const DEVICE_ANALOG := 5

var rom := ""
var core := "flycast"
var screen_position := "Upper Left"
var size_mult := "4x"
var sample_at: Array[float] = [6.0, 12.0]
var shot := "res://probe_out/vmu_overlay.png"
var device := 1

var _lib: Node = null
var _root := ""
var _opt_backup := PackedByteArray()
var _load_failed := ""
var _found := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--rom="):
			rom = s.substr("--rom=".length())
		elif s.begins_with("--core="):
			core = s.substr("--core=".length())
		elif s.begins_with("--position="):
			screen_position = s.substr("--position=".length())
		elif s.begins_with("--size="):
			size_mult = s.substr("--size=".length())
		elif s.begins_with("--device="):
			device = int(s.substr("--device=".length()))
		elif s.begins_with("--shot="):
			shot = s.substr("--shot=".length())
		elif s.begins_with("--at="):
			sample_at.clear()
			for t in s.substr("--at=".length()).split(",", false):
				sample_at.append(float(t))
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[ovl] TIMEOUT")
		_restore()
		get_tree().quit(1))

	_root = CoreDownloadManager.default_core_root()
	if rom.is_empty() or not FileAccess.file_exists(rom):
		print("[ovl] SKIP: pass --rom=<a Dreamcast disc>")
		get_tree().quit(2)
		return
	if CoreDownloadManager.installed_core_lib(core).is_empty():
		print("[ovl] SKIP: core '%s' is not installed" % core)
		get_tree().quit(2)
		return
	await _measure()


func _opt_path() -> String:
	return _root.path_join("core_options/%s.opt" % core)


func _restore() -> void:
	if _opt_backup.is_empty():
		return
	var f := FileAccess.open(_opt_path(), FileAccess.WRITE)
	if f != null:
		f.store_buffer(_opt_backup)
		f.close()
	print("[ovl] restored the player's flycast.opt")


func _measure() -> void:
	var f := FileAccess.open(_opt_path(), FileAccess.READ)
	if f != null:
		_opt_backup = f.get_buffer(f.get_length())
		f.close()

	# The LCD's own colours, chosen to be findable rather than pretty. MAGENTA
	# for OFF means the whole 48 x 32 panel is that colour before a game writes
	# anything to it, so the rect can be found on the very first frame.
	CoreOptionsStore.merge_values(_root, core, {
		KEY_SLOT1: "VMU",
		# Defaults to disabled, and it is not merely a menu-visibility toggle:
		# with it off the screen options below have no effect at all.
		KEY_SHOW: "enabled",
		KEY_DISPLAY: "enabled",
		KEY_POSITION: screen_position,
		KEY_SIZE: size_mult,
		KEY_OPACITY: "100%",
		KEY_OFF: "MAGENTA 21",
		KEY_ON: "GREEN 05",
	})
	print("[ovl] pinned: position='%s' size=%s off=MAGENTA on=GREEN"
		% [screen_position, size_mult])

	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	if _lib == null:
		print("[ovl] FAIL: could not instantiate Libretro node")
		_restore()
		get_tree().quit(1)
		return
	add_child(_lib)
	_lib.connect("content_load_failed", func(reason: String) -> void: _load_failed = reason)
	# BEFORE StartContent, and that ordering is the whole trick.
	#
	# A VMU lives in a CONTROLLER's expansion socket, so with no controller there
	# is no socket, no VMU device and nothing to draw. Crazy Taxi 2 says so on its
	# own memory-card screen — first "The controller has been removed", then an
	# empty socket 1 and 2 once a pad is attached late. flycast builds its maple
	# devices at load and does not rebuild them (see vmu_slot_probe), so a
	# controller attached after the core is running gets a pad and no sockets.
	_lib.SetControllerPortDevice(0, device)
	print("[ovl] port 0 device=%d set BEFORE load" % device)
	_lib.StartContent(_root, core, rom)

	# flycast reads the per-slot device options ONLY when `!first_startup`, so the
	# load pass never populates MapleExpansionDevices at all — the slots stay at
	# their static default and no VMU is created. A second update_variables() does
	# read them, and the frontend triggers one by marking a variable updated.
	# SetCoreOption does exactly that, so re-asserting the value we already pinned
	# is what actually fits the card.
	await get_tree().create_timer(2.0).timeout
	_lib.SetCoreOption(KEY_SLOT1, "VMU")
	print("[ovl] nudged %s to force a second update_variables()" % KEY_SLOT1)

	var t0 := Time.get_ticks_msec()
	for at: float in sample_at:
		while (Time.get_ticks_msec() - t0) < int(at * 1000.0):
			# Held neutral. The core polls every frame and a port that never
			# answers is a port with nothing plugged into it.
			_lib.SetJoypadState(0, 0, 0, 0, 0, 0)
			await get_tree().process_frame
			if not _load_failed.is_empty():
				break
		if not _load_failed.is_empty():
			break
		_sample(at)

	if not _load_failed.is_empty():
		print("[ovl] refused: %s" % _load_failed)
	if _lib.has_method("StopContent"):
		_lib.StopContent()
	await get_tree().create_timer(1.0).timeout
	_restore()
	print("[ovl] ---- %s ----" % ("found the overlay" if _found else "OVERLAY NOT FOUND"))
	get_tree().quit(0 if _found else 1)


## Is this pixel part of the LCD panel — either its OFF dots or its ON dots?
##
## The two colours are MEASURED, not guessed, and the first attempt here failed
## on exactly that. flycast's "MAGENTA" renders (255, 0, 127) and its "GREEN"
## (0, 127, 0), both flat. A hand-written test for magenta that required blue
## above 0.55 missed it by 0.05 and reported the panel absent while a saved frame
## showed it plainly.
##
## Both dot states are matched, because either alone leaves holes wherever the
## LCD happens to be lit — and the bounding box wants the whole panel.
const OFF_DOT := Color8(255, 0, 127)
const ON_DOT := Color8(0, 127, 0)


func _is_marker(c: Color) -> bool:
	const TOL := 0.06
	return (absf(c.r - OFF_DOT.r) < TOL and absf(c.g - OFF_DOT.g) < TOL
			and absf(c.b - OFF_DOT.b) < TOL) \
		or (absf(c.r - ON_DOT.r) < TOL and absf(c.g - ON_DOT.g) < TOL
			and absf(c.b - ON_DOT.b) < TOL)


func _sample(at: float) -> void:
	var img: Image = _lib.GetVideoImage()
	if img == null or img.get_width() == 0:
		print("[ovl] t=%.1fs  no frame yet" % at)
		return
	var w := img.get_width()
	var h := img.get_height()

	var min_x := w
	var min_y := h
	var max_x := -1
	var max_y := -1
	var hits := 0
	for y in range(h):
		for x in range(w):
			if _is_marker(img.get_pixel(x, y)):
				hits += 1
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)

	if max_x < 0:
		print("[ovl] t=%.1fs  frame %dx%d  no marker pixels" % [at, w, h])
		_save(img, at)
		return

	var bw := max_x - min_x + 1
	var bh := max_y - min_y + 1
	print("[ovl] t=%.1fs  frame %dx%d  marker box x=%d y=%d w=%d h=%d  (%d px)"
		% [at, w, h, min_x, min_y, bw, bh, hits])
	# The box should be a whole multiple of the 48 x 32 LCD. Saying so here is
	# what turns "some magenta was on screen" into "that was the VMU panel".
	@warning_ignore("integer_division")
	var mx: float = float(bw) / float(LCD_W)
	@warning_ignore("integer_division")
	var my: float = float(bh) / float(LCD_H)
	print("[ovl]        that is %.2f x %.2f of a 48x32 LCD" % [mx, my])
	print("[ovl]        source_rect = Rect2(%.5f, %.5f, %.5f, %.5f)"
		% [float(min_x) / w, float(min_y) / h, float(bw) / w, float(bh) / h])
	print("[ovl]        insets: left=%d top=%d right=%d bottom=%d"
		% [min_x, min_y, w - 1 - max_x, h - 1 - max_y])
	_found = true

	_save(img, at)


## Always written, found or not: when the overlay is missing the frame is the
## only thing that says whether it is absent, mis-coloured or off-screen.
func _save(img: Image, at: float) -> void:
	if shot.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(shot.get_base_dir()))
	var out := img.duplicate() as Image
	# The core never fills alpha, so a straight save writes a fully transparent
	# PNG that every viewer paints as a blank white rectangle.
	out.convert(Image.FORMAT_RGB8)
	var path := "%s_%s.png" % [shot.trim_suffix(".png"), str(at).replace(".", "_")]
	out.save_png(path)
	print("[ovl]        wrote %s" % path)

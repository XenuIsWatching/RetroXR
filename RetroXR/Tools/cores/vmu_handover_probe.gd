## VMU handover probe — does the core give its VMU screen up, and does the
## television keep the pixels it used to lose?
##
## Stock flycast can publish a VMU screen only by compositing it into the
## finished frame, so putting that screen on the card in the room meant cropping
## it back out and leaving a 48 x 32 badge burned into the corner of the picture
## for good. Our fork exports `flycast_get_vmu_screen` and hands the panel over
## out of band instead; the extension binds that symbol optionally and publishes
## it as a texture of its own. This measures both halves of that.
##
##     "$godot" --path RetroXR --resolution 320x240 --position 20,20 \
##         res://Tools/cores/vmu_handover_probe.tscn -- \
##         "--rom=$HOME/retroxr/roms/dreamcast/game.chd" [--leg=handover|overlay]
##
## **The oracle is a colour the Dreamcast cannot draw.** The LCD's dots are
## pinned to flycast's MAGENTA (255, 0, 127) and GREEN (0, 127, 0) through the
## pixel_on/pixel_off options, which are read whether or not the overlay is on —
## so "is the panel in this image" is an exact test rather than a judgement, the
## same trick vmu_overlay_probe used to find the rect in the first place.
##
## Two legs, and the second is what makes the first mean anything:
##
##   handover  the shipping path. The panel must arrive as its own 48 x 32
##             texture carrying those dots, and the frame must carry NONE.
##   overlay   the old path, forced back on. The frame MUST carry them. Without
##             this leg, "no magenta in the frame" would also pass on a core that
##             drew no VMU at all, on a black screen, or on a probe whose options
##             never landed.
##
## Run WINDOWED, not headless: the dummy renderer hands back a correctly sized
## frame with nothing drawn into it, and every "no magenta here" check passes on
## a blank image. The frame's own colour count is asserted for the same reason.
##
## **The disc has to be one that reaches a VMU, and most of a boot is not.** A
## card's panel stays all zeros until the game touches it, and Goin' Quackers
## touches nothing in the first fourteen seconds — both legs then read an empty
## panel and no dots in the frame, which looks exactly like a broken handover.
## Crazy Taxi 2 opens on its memory-card screen and draws one straight away,
## which is why vmu_overlay_probe uses it too. Run the control leg before
## believing a failure: if IT finds nothing in the frame either, no card was
## fitted and the handover is not what is being measured.
##
## Writes the player's real flycast.opt and restores it on the way out.
extends Node

const KEY_SHOW     := "reicast_show_vmu_screen_settings"
const KEY_DISPLAY  := "reicast_vmu1_screen_display"
const KEY_POSITION := "reicast_vmu1_screen_position"
const KEY_SIZE     := "reicast_vmu1_screen_size_mult"
const KEY_OPACITY  := "reicast_vmu1_screen_opacity"
const KEY_ON       := "reicast_vmu1_pixel_on_color"
const KEY_OFF      := "reicast_vmu1_pixel_off_color"
const KEY_SLOT1    := "reicast_device_port1_slot1"

const LCD_W := 48
const LCD_H := 32
const DEVICE_JOYPAD := 1

## flycast renders these two flat, and they were measured rather than guessed —
## see vmu_overlay_probe, where a hand-written magenta test missed by 0.05.
const OFF_DOT := Color8(255, 0, 127)
const ON_DOT := Color8(0, 127, 0)

var rom := ""
var core := "flycast"
var leg := "handover"
var run_for := 14.0
var out_dir := "res://probe_out"

var _lib: Node = null
var _root := ""
var _opt_backup := PackedByteArray()
var _load_failed := ""
var _fail := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--rom="):
			rom = s.substr("--rom=".length())
		elif s.begins_with("--core="):
			core = s.substr("--core=".length())
		elif s.begins_with("--leg="):
			leg = s.substr("--leg=".length())
		elif s.begins_with("--seconds="):
			run_for = maxf(4.0, float(s.substr("--seconds=".length())))
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("[vmuho] TIMEOUT")
		_restore()
		get_tree().quit(1))

	_root = CoreDownloadManager.default_core_root()
	if rom.is_empty() or not FileAccess.file_exists(rom):
		print("[vmuho] SKIP: pass --rom=<a Dreamcast disc>")
		get_tree().quit(2)
		return
	if CoreDownloadManager.installed_core_lib(core).is_empty():
		print("[vmuho] SKIP: core '%s' is not installed" % core)
		get_tree().quit(2)
		return
	await _run()
	_restore()
	print("[vmuho] ---- %s ----"
		% ("all checks passed" if _fail == 0 else "%d FAILED" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if not cond:
		_fail += 1
	print("[vmuho] %s  %s%s" % ["PASS" if cond else "FAIL", what,
		"" if detail.is_empty() else "  - " + detail])


func _opt_path() -> String:
	return _root.path_join("core_options/%s.opt" % core)


func _restore() -> void:
	if _opt_backup.is_empty():
		return
	var f := FileAccess.open(_opt_path(), FileAccess.WRITE)
	if f != null:
		f.store_buffer(_opt_backup)
		f.close()
	print("[vmuho] restored the player's flycast.opt")


## How many pixels of this image are LCD dots, either state.
func _count_dots(img: Image) -> int:
	var n := 0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var c := img.get_pixel(x, y)
			if c.is_equal_approx(OFF_DOT) or c.is_equal_approx(ON_DOT):
				n += 1
	return n


func _distinct(img: Image) -> int:
	var seen := {}
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			seen[img.get_pixel(x, y).to_rgba32()] = true
	return seen.size()


func _save(img: Image, name: String, scale := 1) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var out := img.duplicate() as Image
	out.convert(Image.FORMAT_RGB8)
	if scale > 1:
		out.resize(out.get_width() * scale, out.get_height() * scale,
			Image.INTERPOLATE_NEAREST)
	out.save_png(out_dir.path_join(name))
	print("[vmuho] wrote %s" % out_dir.path_join(name))


func _run() -> void:
	var f := FileAccess.open(_opt_path(), FileAccess.READ)
	if f != null:
		_opt_backup = f.get_buffer(f.get_length())
		f.close()

	# The overlay leg is the control, so it pins the overlay ON exactly as the
	# shipping code used to. The handover leg pins it OFF, which is what
	# VmuStorage now does for itself once the core has answered.
	var overlay := leg == "overlay"
	CoreOptionsStore.merge_values(_root, core, {
		KEY_SLOT1: "VMU",
		KEY_SHOW: "enabled",
		KEY_DISPLAY: "enabled" if overlay else "disabled",
		KEY_POSITION: "Upper Left",
		KEY_SIZE: "1x",
		KEY_OPACITY: "100%",
		KEY_OFF: "MAGENTA 21",
		KEY_ON: "GREEN 05",
	})
	print("[vmuho] leg=%s  %s=%s" % [leg, KEY_DISPLAY, "enabled" if overlay else "disabled"])

	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	if _lib == null:
		_ok(false, "the Libretro node instantiates")
		return
	add_child(_lib)
	_lib.connect("content_load_failed", func(reason: String) -> void: _load_failed = reason)
	# A VMU sits in a controller's expansion socket, so the pad has to be
	# announced BEFORE the core builds its maple devices. See vmu_overlay_probe.
	_lib.SetControllerPortDevice(0, DEVICE_JOYPAD)
	_lib.StartContent(_root, core, rom)

	await get_tree().create_timer(2.0).timeout
	# flycast reads the per-slot device options only on a SECOND
	# update_variables(), so re-asserting a value it already has is what actually
	# fits the card.
	_lib.SetCoreOption(KEY_SLOT1, "VMU")

	var t0 := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t0) < int(run_for * 1000.0):
		_lib.SetJoypadState(0, 0, 0, 0, 0, 0)
		await get_tree().process_frame
		if not _load_failed.is_empty():
			break
	if not _load_failed.is_empty():
		_ok(false, "the core took the disc", _load_failed)
		return

	# --- Can the core hand a screen over at all? -----------------------------
	var handed: bool = bool(_lib.HasVmuScreens())
	_ok(handed, "the core publishes its VMU screens out of band",
		"HasVmuScreens()=%s" % str(handed))

	# --- The television's picture --------------------------------------------
	var tv: Texture2D = _lib.GetVideoTexture()
	_ok(tv != null, "the core is showing a picture")
	if tv == null:
		return
	var frame := tv.get_image()
	_ok(frame != null and frame.get_width() > 0, "with a readable frame",
		str(tv.get_size()))
	if frame == null:
		return
	# Guard against passing on a blank. A dummy-renderer frame is one flat
	# colour, and "no LCD dots in it" would be true of that too.
	var colours := _distinct(frame)
	_ok(colours > 8, "that is a real picture rather than a blank",
		"%d distinct colours" % colours)
	var in_frame := _count_dots(frame)
	_save(frame, "vmu_handover_frame_%s.png" % leg)

	if overlay:
		# The control. The old path MUST put the panel in the picture, or the
		# handover leg's "no dots" proves nothing about handover.
		_ok(in_frame >= LCD_W * LCD_H / 2,
			"the overlay leg burns the panel into the frame, as it always did",
			"%d LCD pixels in the frame" % in_frame)
		return

	_ok(in_frame == 0, "no VMU pixels anywhere in the frame, so nothing was drawn"
		+ " over the game", "%d LCD pixels found" % in_frame)

	# --- The card's own panel -------------------------------------------------
	var panel: Texture2D = _lib.GetVmuScreenTexture(0)
	_ok(panel != null, "the core hands slot 1's panel over as its own texture")
	if panel == null:
		return
	_ok(int(panel.get_size().x) == LCD_W and int(panel.get_size().y) == LCD_H,
		"which is the LCD's own 48 x 32", str(panel.get_size()))
	var lcd := panel.get_image()
	_ok(lcd != null, "and reads back as an image")
	if lcd == null:
		return
	var in_panel := _count_dots(lcd)
	_save(lcd, "vmu_handover_panel.png", 8)
	# Every dot of it, or the texture is something else that happens to be the
	# right size.
	_ok(in_panel == LCD_W * LCD_H,
		"and every pixel of it is an LCD dot in the colours we pinned",
		"%d of %d" % [in_panel, LCD_W * LCD_H])
	# A card that has drawn something has both states. All-off would also be a
	# card the core never wrote to.
	var lit := 0
	for y in range(lcd.get_height()):
		for x in range(lcd.get_width()):
			if lcd.get_pixel(x, y).is_equal_approx(ON_DOT):
				lit += 1
	print("[vmuho] %d of %d dots lit" % [lit, LCD_W * LCD_H])

## VmuStorage — binds the VMUs seated in a Dreamcast's controllers to the files
## flycast reads them from.
##
## Every other console here backs a card through SAVE_RAM and SetSramPath. That
## reaches nothing on a Dreamcast: flycast answers retro_get_memory_size with 0
## and keeps its own files, so this is the Dolphin situation rather than the
## PlayStation one — except that flycast takes no path option either, so there is
## nothing to point at a card. What it has instead is a fixed location:
##
##     <root>/system/<core>/dc/vmu_save_<Port><Slot>.bin      Port A-D, Slot 1-2
##
## So a card is STAGED into that location before content starts and drained back
## out afterwards. flycast holds the file open and flushes every block write
## immediately, which is what makes draining safe at any moment rather than a
## race — the file on disk is always current.
##
## **The binding is load-time.** flycast builds its maple devices during
## retro_load_game, so what is staged and pinned before the core starts is what
## the game sees; a card moved while the machine is on is recorded and applies at
## the next power-on.
##
## **Known blocker, and it is above this class rather than in it.** RetroXR never
## calls retro_set_controller_port_device for a plain joypad — WrapperEmuThread
## skips JOYPAD when applying pre-start devices — and flycast takes its main
## maple device from exactly that call. So a Dreamcast currently runs with no
## controller, hence no expansion socket, hence no VMU, whatever is staged here.
## Everything below is correct and inert until that is fixed. See
## Tools/cores/vmu_slot_probe for the measurement and the retraction that came
## with it.
class_name VmuStorage
extends Node

## The family whose images this stages. Cards live at
## save/memcards/vmu/<card_id>.vmu, with no core in the path, because a card is
## hardware and its raw image is the same whichever core reads it.
const FAMILY := "vmu"

## flycast's own option keys. The legacy `reicast_` prefix, not `flycast_`.
const SLOT_KEY := "reicast_device_port%d_slot%d"

## Per-content VMU files would re-key a card per game, which is exactly what a
## card is not: one image, many games. Pinned off.
const PER_CONTENT_KEY := "reicast_per_content_vmus"

## What an empty slot must say. "None" has to mean genuinely absent rather than a
## blank card, or a game offers to format something instead of reporting no
## memory card — the same distinction pcsx_rearmed's `_inserted` option draws.
const SLOT_EMPTY := "None"


# --- The VMU's own screen -----------------------------------------------------
#
# Two ways, and the better one needs our fork of the core.
#
# Stock flycast has no second video output: it burns each VMU's 48 x 32 LCD into
# the main framebuffer at a chosen corner, size and opacity, and RetroXR crops it
# back out onto the card's own face with screen_window.gdshader, the same way the
# 3DS bottom screen is cut out of a composite frame. It works, and it costs the
# television a 48 x 32 badge in the corner of every picture — those pixels are
# overwritten before the frame ever reaches us, so no crop can give them back.
#
# Our fork exports flycast_get_vmu_screen and hands the panels over instead, out
# of band. The data was always there — push_vmu_screen fills vmu_lcd_data from
# MapleConfigMap::SetImage whether or not an overlay is drawn — so the fork adds
# no emulation work, only a way to ask. Then every screen option stays off, the
# core draws nothing over the game, and the card gets a texture of its own.
#
# Which one is in play cannot be known at staging time: the symbol is resolved
# when the core loads, which is after the options are written. So the overlay is
# staged ON as it always was, and switched off in nudge_slots_after_start once
# the core has answered. A player on the buildbot's build keeps the crop and
# notices nothing.
#
# The screen options are indexed per PORT, not per slot, and flycast gates them
# on MapleExpansionDevices[i][0] — so only the card in SLOT 1 has a screen. That
# is the hardware, not a shortcut: only the front slot has a window in the
# controller's shell, and a VMU in the back one is buried.

const SCREEN_DISPLAY_KEY  := "reicast_vmu%d_screen_display"
const SCREEN_POSITION_KEY := "reicast_vmu%d_screen_position"
const SCREEN_SIZE_KEY     := "reicast_vmu%d_screen_size_mult"
const SCREEN_OPACITY_KEY  := "reicast_vmu%d_screen_opacity"

## Gates every option above, defaults to disabled, and is NOT merely a
## menu-visibility toggle: with it off the screen options do nothing at all.
const SHOW_SCREEN_KEY := "reicast_show_vmu_screen_settings"

## The LCD's true resolution.
const LCD_SIZE := Vector2i(48, 32)

## Where flycast puts the panel, MEASURED rather than assumed: a constant 8 px in
## from the chosen corner, on both axes, at every position and multiplier. See
## Tools/cores/vmu_overlay_probe, which pins the whole rule.
const SCREEN_INSET := 8

## 1x, so the crop is the LCD's own 48 x 32 pixels — the card's face is about
## 37 x 26 mm and wants no more than that. It is also the least the overlay can
## intrude on the picture the television is showing, which it shares until the
## core stops burning it in.
const SCREEN_MULT := 1

## Upper left. Any corner works; this one is picked so the rect is simply
## (8, 8) and does not move when the core changes resolution.
const SCREEN_POSITION := "Upper Left"


## The options that put one port's VMU screen where screen_rect expects it.
static func screen_options(port: int, enabled: bool) -> Dictionary:
	var n := port + 1
	return {
		SHOW_SCREEN_KEY: "enabled",
		SCREEN_DISPLAY_KEY % n: "enabled" if enabled else "disabled",
		SCREEN_POSITION_KEY % n: SCREEN_POSITION,
		SCREEN_SIZE_KEY % n: "%dx" % SCREEN_MULT,
		SCREEN_OPACITY_KEY % n: "100%",
	}


## The window into the core's frame that holds one VMU's LCD, in UV.
##
## Derived from the LIVE texture size every time, because flycast places the
## panel relative to the output resolution and that follows the core rather than
## anything here. An empty rect when the size is not known yet.
static func screen_rect(frame: Vector2i) -> Rect2:
	if frame.x <= 0 or frame.y <= 0:
		return Rect2()
	var w := LCD_SIZE.x * SCREEN_MULT
	var h := LCD_SIZE.y * SCREEN_MULT
	var x := SCREEN_INSET
	var y := SCREEN_INSET
	if SCREEN_POSITION.ends_with("Right"):
		x = frame.x - SCREEN_INSET - w
	if SCREEN_POSITION.begins_with("Lower"):
		y = frame.y - SCREEN_INSET - h
	return Rect2(float(x) / frame.x, float(y) / frame.y,
		float(w) / frame.x, float(h) / frame.y)

var _host: RetroSystem = null
## Which card id was staged into which "<Port><Slot>" name this run, so a drain
## knows where to put the bytes back even if the card has since been pulled.
var _staged: Dictionary = {}


func setup(host: RetroSystem) -> void:
	_host = host


## Does this machine use VMUs at all? Keyed on the console's OWN systemid rather
## than whatever disc is in the drive: a Dreamcast's pads have slots whatever it
## is running.
func _uses_vmus() -> bool:
	return is_instance_valid(_host) and _host.systemid == VmuPort.HOST_SYSTEMID


## Where flycast keeps one slot's flash. `port` is 0-based, `slot` 0-based.
static func core_vmu_path(root: String, core: String, port: int, slot: int) -> String:
	return root.path_join("system/%s/dc/vmu_save_%s%d.bin"
		% [core, char("A".unicode_at(0) + port), slot + 1])


func _read(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	return b


func _write(path: String, data: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[VmuStorage] cannot write %s" % path)
		return false
	f.store_buffer(data)
	f.close()
	return true


## Every (port, slot, card) this machine's controllers currently hold. A pad with
## no VMU slots contributes nothing, which is not the same as contributing empty
## slots — a Light Gun has one slot and a keyboard has none.
func _seated() -> Array:
	var out: Array = []
	if not _uses_vmus():
		return out
	var ports: Array = _host.get_port_controllers()
	for port in range(ports.size()):
		var ctrl: Node = ports[port]
		if not is_instance_valid(ctrl) or not ctrl.has_method("vmu_slot_count"):
			continue
		var slots: int = int(ctrl.call("vmu_slot_count"))
		for slot in range(slots):
			out.append({
				"port": port,
				"slot": slot,
				"card": ctrl.call("get_vmu", slot),
				"value": str(ctrl.call("vmu_slot_option_value", slot)),
			})
	return out


# --- Before the core starts ---------------------------------------------------

## Copy each seated card into the file flycast will read, and pin the per-slot
## device options to match. Called from the content-start path, before the core
## is told to run.
func stage_before_start(dir: String, core: String) -> void:
	_staged.clear()
	if not _uses_vmus() or not core.begins_with("flycast"):
		return

	var opts := {PER_CONTENT_KEY: "disabled"}
	for entry: Dictionary in _seated():
		var port: int = entry["port"]
		var slot: int = entry["slot"]
		opts[SLOT_KEY % [port + 1, slot + 1]] = str(entry["value"])
		# Only slot 1 has a screen, in the hardware and in the core.
		if slot == 0:
			opts.merge(screen_options(port, is_instance_valid(entry["card"])), true)

		var path := core_vmu_path(dir, core, port, slot)
		var card: Node = entry["card"]
		if not is_instance_valid(card):
			# Nothing seated. Leave whatever is there alone rather than deleting
			# it — the option says the slot is empty, and a file the core is not
			# reading is harmless. Deleting would throw away the last card's
			# saves for a player who simply pulled it out.
			continue

		var image := _card_image(card)
		if image.is_empty():
			continue
		if _write(path, image):
			_staged[_key(port, slot)] = str(card.get("card_id"))

	if not opts.is_empty() and CoreOptionsStore.merge_values(dir, core, opts):
		print("[VmuStorage] slots pinned before boot: %s" % str(opts))


## Make flycast read the per-slot device options, which the load pass does not.
##
## Measured, and not something the option file can do on its own: flycast guards
## that whole block with `!first_startup`, so the load pass leaves
## MapleExpansionDevices at its static default and creates no VMU at all — a
## controller with two empty sockets. A SECOND update_variables() does read them,
## and the frontend triggers one by marking any variable updated. Re-asserting
## the value already pinned is enough, and is a no-op on every other core.
##
## Called after the core is up, from the content-start path.
func nudge_slots_after_start() -> void:
	if not _uses_vmus():
		return
	var lib: Node = _host.get_libretro_node()
	if lib == null or not lib.has_method("SetCoreOption"):
		return
	for entry: Dictionary in _seated():
		var key := SLOT_KEY % [int(entry["port"]) + 1, int(entry["slot"]) + 1]
		lib.SetCoreOption(key, str(entry["value"]))
	print("[VmuStorage] re-asserted the slot options so the core reads them")
	_stop_burning_in_the_screen(lib)


## Take the VMU panel off the television, on a core that can hand it over.
##
## Here rather than in stage_before_start because the answer is not known until
## the core has loaded: the symbol is resolved at load, and the options are
## written before it. The badge is therefore on for the first frames of a boot,
## where a Dreamcast is showing its own swirl and nobody is looking at a corner.
##
## Only the display key is cleared. Position, size and opacity are left as they
## were, because they also colour vmu_lcd_data, which is what the fork hands over
## — turning the overlay off must not turn the card's picture monochrome.
func _stop_burning_in_the_screen(lib: Node) -> void:
	if not lib.has_method("HasVmuScreens") or not lib.HasVmuScreens():
		return
	for entry: Dictionary in _seated():
		if int(entry["slot"]) != 0:
			continue
		lib.SetCoreOption(SCREEN_DISPLAY_KEY % (int(entry["port"]) + 1), "disabled")
	print("[VmuStorage] the core hands its VMU screens over, so the overlay is off"
		+ " and the television keeps the whole picture")


## One card's image, creating it only for a card this session invented.
##
## A card restored from a saved room whose file has gone missing runs unbacked
## rather than being handed a blank: answering with a fresh empty card reads
## exactly like the saves were wiped.
func _card_image(card: Node) -> PackedByteArray:
	var card_id := str(card.get("card_id"))
	if card_id.is_empty():
		return PackedByteArray()
	var path := SramPaths.find_card(card_id, FAMILY)
	if path.is_empty():
		if not bool(card.get("minted")):
			push_warning("[VmuStorage] VMU '%s' has no image on disk - running without it rather than creating a blank" % card_id)
			return PackedByteArray()
		path = SramPaths.ensure_card(FAMILY, card_id)
	return _read(path)


static func _key(port: int, slot: int) -> String:
	return "%d:%d" % [port, slot]


# --- After it stops, and while it runs ----------------------------------------

## Copy what the core has written back into the cards it came from.
##
## Safe at any moment: flycast flushes each block write straight through, so the
## staged file is never half a save. A file that does not parse as a card is
## skipped rather than copied — a torn read must not overwrite a good image.
func drain(dir: String, core: String) -> void:
	if _staged.is_empty():
		return
	for key: String in _staged:
		var bits := key.split(":")
		if bits.size() != 2:
			continue
		var path := core_vmu_path(dir, core, int(bits[0]), int(bits[1]))
		var data := _read(path)
		if data.is_empty() or not VMUCard.is_card_image(data):
			continue
		var card_path := SramPaths.card_save_path(FAMILY, str(_staged[key]))
		if card_path.is_empty():
			continue
		if _read(card_path) != data:
			_write(card_path, data)


## Re-announce the slots on one controller. Called when a VMU is pushed into or
## pulled out of a slot, which the system cannot see for itself — the slot
## belongs to the controller, two objects away.
##
## It deliberately does NOT touch the running core: flycast builds its maple
## devices at load and a card is bound by staging a file before that. The seating
## is recorded and the next content start applies it.
func reapply(ctrl: Node) -> void:
	if not _uses_vmus() or not is_instance_valid(ctrl):
		return
	if not is_instance_valid(_host) or not _host.is_powered_on:
		return
	print("[VmuStorage] VMU change noted; it takes effect when the machine is next powered on")

## PadReceiver — a wireless receiver for one real gamepad.
##
## Plug it into any console's controller port and that port is driven by the
## physical pad this receiver was spawned for, with nothing held.
##
## Before this, a real pad only reached a core by being merged into whatever
## virtual controller you were HOLDING — so the pad and the prop were the same
## controller, both hands were occupied, and two pads could not be two players.
## That merge is gone (see GamepadBindings.poll, which now reads one named
## device). A pad drives exactly one destination and you say which: a console by
## plugging in its receiver, a handheld — which has no port — from that machine's
## own Controllers panel.
class_name PadReceiver
extends InputReceiver

const RETRO_DEVICE_JOYPAD := 1

## Which console moulds its own controller connector. A pad receiver is universal,
## so unlike every other peripheral it cannot know its plug until it seats.
##
## These mirror the plug_mesh_path exports on the pads that wear them
## (nes_controller.tscn, atari_2600_cx40.tscn). Two places now know each
## connector; a third would be one too many, so if this grows past a handful ask
## the console for its connector instead of listing it here.
const PORT_CONNECTORS := {
	"nes": "res://imported-assets/controllers/nes/nes_controller_plug.res",
	"atari2600": "res://Scenes/Objects/controllers/atari/atari_2600_plug_cx40.res",
}


func connector_for(sysid: String) -> String:
	return str(PORT_CONNECTORS.get(sysid, ""))

## The pad this receiver is for. GUID rather than device index because the index
## is a connection order that changes every session; `pad_ordinal` picks between
## two pads of the same model. `pad_name` is only ever shown to the player.
var pad_guid: String = ""
var pad_name: String = ""
var pad_ordinal: int = 0

# Bindings — the global physical-pad map, refreshed with everyone else's.
var _pad_button_map: Dictionary = GamepadBindings.DEFAULT_BUTTON_MAP.duplicate()
var _pad_stick_map:  Dictionary = GamepadBindings.DEFAULT_STICK_MAP.duplicate()

## The joypad index resolved last frame, or -1 while no pad answers. Cached so
## the LED and the rumble know what the input read.
var _device: int = -1


# The N64 expansion port on the boss on top of the case. Inert unless the scene
# authors an ExpansionPort node -- see N64PakPort.
var _pak_port := N64PakPort.new()


func _ready() -> void:
	device_type = RETRO_DEVICE_JOYPAD
	super._ready()
	add_to_group(ControllerBindings.CONSUMER_GROUP)
	reload_bindings()
	_pak_port.attach(self)


# ── The expansion port ────────────────────────────────────────────────────────

## A receiver carries the same port an N64 controller does, for the player who
## is using a REAL gamepad. That player holds no virtual pad, so without this
## the three paks have no socket they can reach: a Controller Pak's notes, a
## Rumble Pak's buzz and a Transfer Pak's cartridge were all reachable only by
## putting down the pad you were actually playing with.
##
## RetroSystem finds all of this by duck typing -- it asks a port controller for
## `pak_option_value` and `get_pak` and does not care what class answers -- so
## the two forwards below are the whole of the wiring on the system side.

## The pak fitted to this receiver, or null.
func get_pak() -> N64Pak:
	return _pak_port.get_pak()


## Put a pak back into the port after a load.
func restore_pak(pak: N64Pak) -> void:
	_pak_port.restore_pak(pak)


## The core option value this receiver's port should take. "" would mean no port
## at all, which is not the same as an empty one -- see N64PakPort.
func pak_option_value() -> String:
	return _pak_port.pak_option_value()


func receiver_glyph() -> String:
	return TransportGlyphs.glyph("gamepad")


func receiver_label() -> String:
	return pad_name if not pad_name.is_empty() else "NO PAD"


func is_bound() -> bool:
	return _device >= 0


func on_going_idle() -> void:
	_stop_rumble()


func _exit_tree() -> void:
	super._exit_tree()
	_stop_rumble()


# ── Binding to a pad ──────────────────────────────────────────────────────────

## The joypad this receiver should read, or -1 when none can be had.
##
## Its own pad first. Failing that it ADOPTS the first connected pad no sibling
## receiver has already taken, and remembers it — because the common case for a
## restored room is that the saved pad is switched off, out of battery, or has
## been replaced since, and a dongle that stays dead until you delete and respawn
## it would be a worse answer than one that binds to what you actually have.
func _resolve_or_adopt() -> int:
	var device := GamepadBindings.resolve_device(pad_guid, pad_ordinal)
	if device >= 0:
		return device
	var taken := _pads_taken_by_siblings()
	for candidate: int in GamepadBindings.usable_pads():
		if candidate in taken:
			continue
		var id := GamepadBindings.identify_device(candidate)
		pad_guid = str(id["guid"])
		pad_name = str(id["name"])
		pad_ordinal = int(id["ordinal"])
		refresh_label()
		print("[PadReceiver] adopted '%s'" % pad_name)
		return candidate
	return -1


## Device indices other live receivers resolved, so two dongles cannot both take
## the same pad when neither found the one it was saved with.
func _pads_taken_by_siblings() -> Array:
	var taken: Array = []
	for node in get_tree().get_nodes_in_group(GROUP):
		var other := node as PadReceiver
		if other != null and other != self and other._device >= 0:
			taken.append(other._device)
	return taken


## Reload this port's pad map. The systemid decides which profile applies, so a
## receiver moved from one console to another changes layout with it.
func reload_bindings() -> void:
	var sysid := ""
	if is_instance_valid(_connected_system):
		sysid = _connected_system.systemid
	var pad := GamepadBindings.get_for_system(sysid)
	_pad_button_map = pad["buttons"]
	_pad_stick_map  = pad["sticks"]


## The base class does not reload bindings on a plug, because a keyboard or a
## mouse receiver has no map to reload. This one does, and the map it wants
## depends on the console it just went into.
func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	super.on_plugged_in(system, port_index)
	reload_bindings()


func on_unplugged() -> void:
	super.on_unplugged()
	reload_bindings()


# ── Input ─────────────────────────────────────────────────────────────────────

## Unplugged it does nothing at all; unbound it shows red and still does nothing.
## Deliberately no zero-write in either case — a port with no receiver in it is
## not the same as one held at neutral.
func _process(_delta: float) -> void:
	if _connected_system == null or _port_index < 0:
		return
	_device = _resolve_or_adopt()
	set_led(_device >= 0)
	if _device < 0:
		return
	var p := GamepadBindings.poll(_pad_button_map, _pad_stick_map, _device)
	_send_joypad(p["btn"], p["alx"], p["aly"], p["arx"], p["ary"])


## Route input to the connected system's core, via netplay when a lockstep game
## is running (the gate applies the agreed frame on every peer), else directly.
## Verbatim from RetroController — the seam is the same for every pad.
func _send_joypad(btn: int, alx: int, aly: int, arx: int, ary: int) -> void:
	if NetworkManager.netplay_route(_connected_system, _port_index,
			{"btn": btn, "alx": alx, "aly": aly, "arx": arx, "ary": ary}):
		return
	_connected_system.get_libretro_node().SetJoypadState(_port_index, btn, alx, aly, arx, ary)


## Rumble from the core, on THIS receiver's pad alone. A held controller shakes
## every connected pad because it has no idea which one is driving it; a receiver
## knows, so a second player's pad stays still while the first one is hit.
func set_rumble(weak: float, strong: float) -> void:
	if _device < 0:
		return
	if weak <= 0.0 and strong <= 0.0:
		Input.stop_joy_vibration(_device)
		return
	Input.start_joy_vibration(_device, weak, strong, 0.0)


func _stop_rumble() -> void:
	if _device >= 0:
		Input.stop_joy_vibration(_device)

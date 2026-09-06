## GamepadBindings — physical gamepad (Xbox / 8BitDo / any HID pad) remapping.
##
## Mirrors ControllerBindings, but for real joypads read directly through the
## Godot Input singleton (Input.is_joy_button_pressed / get_joy_axis) rather than
## InputMap actions. Bindings are stored in user://gamepad_bindings.json and merged
## default → global → per-system, the same three layers ControllerBindings uses.
##
## One pad, one destination: poll() reads a single named device, and the caller
## decides which. A PadReceiver plugged into a console port names the pad it was
## spawned for; a handheld names the pad its own Controllers panel selects. The map
## itself is per-platform: a system with no profile of its own plays the global
## RetroPad layout.
class_name GamepadBindings
extends RefCounted

const SAVE_PATH := "user://gamepad_bindings.json"

# ── Tunables ──────────────────────────────────────────────────────────────────
const DEADZONE          := 0.15     # radial stick deadzone
const TRIGGER_THRESHOLD := 0.5      # axis magnitude to count a button-bound axis as pressed
const DPAD_THRESHOLD    := 0.35     # stick magnitude to fire a d-pad direction
const ANALOG_SCALE      := 0x7fff   # libretro analog full-scale

## When true (during rebind capture), poll() returns neutral so the captured
## press does not simultaneously drive a running game.
static var suspend_polling: bool = false

## Connected joypads the last [Pads] dump described.
static var _last_seen: Array = []

# ── RetroPad targets ──────────────────────────────────────────────────────────
## Ordered so index == RETRO_DEVICE_ID_JOYPAD bit (matches ControllerBindings.JOYPAD_*).
const TARGET_ORDER: Array = [
	"b", "y", "select", "start", "up", "down", "left", "right",
	"a", "x", "l", "r", "l2", "r2", "l3", "r3",
]

## RetroPad target → UI label.
const TARGET_LABELS: Dictionary = {
	"b": "B", "y": "Y", "select": "Select", "start": "Start",
	"up": "D-Up", "down": "D-Down", "left": "D-Left", "right": "D-Right",
	"a": "A", "x": "X", "l": "L", "r": "R",
	"l2": "L2", "r2": "R2", "l3": "L3", "r3": "R3",
}

# ── Binding encoding ──────────────────────────────────────────────────────────
# A binding is a string:
#   "btn:<JoyButton index>"        → Input.is_joy_button_pressed
#   "axis:<JoyAxis index>:<+|->"   → signed Input.get_joy_axis past ±TRIGGER_THRESHOLD
#   "none"                         → unbound

## Xbox/SDL button index → display name (physical position, not RetroPad role).
const JOY_BUTTON_NAMES: Dictionary = {
	0: "A (bottom)", 1: "B (right)", 2: "X (left)", 3: "Y (top)",
	4: "Back", 5: "Guide", 6: "Start",
	7: "L-Stick", 8: "R-Stick", 9: "LB", 10: "RB",
	11: "D-Up", 12: "D-Down", 13: "D-Left", 14: "D-Right",
}

## Xbox/SDL axis index → display name.
const JOY_AXIS_NAMES: Dictionary = {
	0: "LS-X", 1: "LS-Y", 2: "RS-X", 3: "RS-Y", 4: "LT", 5: "RT",
}

## Default map: standard libretro positional convention for an Xbox-layout pad.
## Xbox A(bottom)→B, B(right)→A, X(left)→Y, Y(top)→X.
const DEFAULT_BUTTON_MAP: Dictionary = {
	"b":      "btn:0",     # Xbox A (bottom)
	"a":      "btn:1",     # Xbox B (right)
	"y":      "btn:2",     # Xbox X (left)
	"x":      "btn:3",     # Xbox Y (top)
	"select": "btn:4",     # Back
	"start":  "btn:6",     # Start
	"l3":     "btn:7",     # Left-stick click
	"r3":     "btn:8",     # Right-stick click
	"l":      "btn:9",     # LB
	"r":      "btn:10",    # RB
	"up":     "btn:11",    # D-pad up
	"down":   "btn:12",    # D-pad down
	"left":   "btn:13",    # D-pad left
	"right":  "btn:14",    # D-pad right
	"l2":     "axis:4:+",  # Left trigger
	"r2":     "axis:5:+",  # Right trigger
}

## Default stick routing. Left stick doubles as the d-pad so single-stick
## retro cores (NES/SNES) work out of the box.
const DEFAULT_STICK_MAP: Dictionary = {
	"stick_left":  "left+dpad",
	"stick_right": "right",
}

# ── File I/O ──────────────────────────────────────────────────────────────────

## Save global (fallback) gamepad bindings.
static func save_global(button_map: Dictionary, stick_map: Dictionary) -> bool:
	var data := _load_file()
	if not data.has("global"):
		data["global"] = {}
	data["global"]["buttons"] = button_map
	data["global"]["sticks"] = stick_map
	return _save_file(data)


## Override bookkeeping is BindingStore's; see the rules on that class.
static func has_system_override(systemid: String) -> bool:
	return BindingStore.has_system_override(SAVE_PATH, "GamepadBindings", systemid)


static func clear_system_override(systemid: String) -> void:
	BindingStore.clear_system_override(SAVE_PATH, "GamepadBindings", systemid)


static func overridden_systems() -> Array[String]:
	return BindingStore.overridden_systems(SAVE_PATH, "GamepadBindings")


static func _load_file() -> Dictionary:
	return BindingStore.load_file(SAVE_PATH, "GamepadBindings")


static func _save_file(data: Dictionary) -> bool:
	return BindingStore.save_file(SAVE_PATH, "GamepadBindings", data)


static func _merge(base: Dictionary, overlay1: Dictionary,
		overlay2: Dictionary) -> Dictionary:
	return BindingStore.merge(base, overlay1, overlay2)

## Merged bindings for one system: per-system overrides global, which overrides
## defaults. Keys "buttons", "sticks". Mirrors ControllerBindings.get_for_system.
static func get_for_system(systemid: String) -> Dictionary:
	var data := _load_file()
	var global_data: Dictionary = data.get("global", {}) as Dictionary
	var sys_data: Dictionary = {}
	if not systemid.is_empty():
		var per_sys: Dictionary = data.get("per_system", {}) as Dictionary
		sys_data = per_sys.get(systemid, {}) as Dictionary
	return {
		"buttons": _merge(DEFAULT_BUTTON_MAP, global_data.get("buttons", {}), sys_data.get("buttons", {})),
		"sticks":  _merge(DEFAULT_STICK_MAP,  global_data.get("sticks",  {}), sys_data.get("sticks",  {})),
	}


## Merged global bindings (global overrides of defaults), with no per-system layer.
static func get_global() -> Dictionary:
	return get_for_system("")


## Save per-system bindings. Falls back to save_global when systemid is empty —
## the fall-through the shared binding editor relies on to serve both pages.
static func save_for_system(systemid: String, button_map: Dictionary, stick_map: Dictionary) -> bool:
	if systemid.is_empty():
		return save_global(button_map, stick_map)
	var data := _load_file()
	if not data.has("per_system"):
		data["per_system"] = {}
	data["per_system"][systemid] = {
		"buttons": button_map,
		"sticks":  stick_map,
	}
	return _save_file(data)


## Encode a captured joypad InputEvent into a binding string ("" if unsupported).
static func encode_event(event: InputEvent) -> String:
	if event is InputEventJoypadButton:
		return "btn:%d" % (event as InputEventJoypadButton).button_index
	if event is InputEventJoypadMotion:
		var m := event as InputEventJoypadMotion
		return "axis:%d:%s" % [m.axis, "+" if m.axis_value >= 0.0 else "-"]
	return ""


## Human-readable label for a binding string, for the remap UI.
static func binding_display_name(binding: String) -> String:
	if binding == "none" or binding.is_empty():
		return "(none)"
	if binding.begins_with("btn:"):
		var idx := binding.substr(4).to_int()
		return JOY_BUTTON_NAMES.get(idx, "Btn %d" % idx)
	if binding.begins_with("axis:"):
		var parts := binding.split(":")
		if parts.size() < 3:
			return binding
		var axis := parts[1].to_int()
		var axis_name: String = JOY_AXIS_NAMES.get(axis, "Axis %d" % axis)
		if axis == JOY_AXIS_TRIGGER_LEFT or axis == JOY_AXIS_TRIGGER_RIGHT:
			return axis_name   # triggers are one-directional
		return "%s %s" % [axis_name, "+" if parts[2] == "+" else "−"]
	return binding


## Poll ONE pad and return libretro-convention state: {btn, alx, aly, arx, ary}.
## Y is positive-down (no negation — joypad axes already match libretro's
## convention, unlike VR sticks).
##
## `device` is a Godot joypad index, and naming it is mandatory. This used to
## merge every connected pad into one virtual RetroPad and hand the result to
## whichever controller was held, which is why a real pad and the prop in your
## hand were the same controller — and why two pads could not be two players.
## Every caller now points its pad at one destination: a receiver at the port it
## is plugged into, a handheld at the pad its own panel names. A device of -1, or
## one that is not connected, is not an error — a receiver whose pad is switched
## off reads exactly that, every frame, until it comes back.
static func poll(button_map: Dictionary, stick_map: Dictionary, device: int) -> Dictionary:
	var zero := {"btn": 0, "alx": 0, "aly": 0, "arx": 0, "ary": 0}
	if suspend_polling or device < 0 or device not in usable_pads():
		return zero

	var btn := 0
	for i: int in TARGET_ORDER.size():
		var binding: String = button_map.get(TARGET_ORDER[i], "none")
		if binding == "none" or binding.is_empty():
			continue
		if _binding_active(binding, device):
			btn |= (1 << i)

	var left_vec := Vector2(Input.get_joy_axis(device, JOY_AXIS_LEFT_X),
							Input.get_joy_axis(device, JOY_AXIS_LEFT_Y))
	if left_vec.length() < DEADZONE:
		left_vec = Vector2.ZERO
	var right_vec := Vector2(Input.get_joy_axis(device, JOY_AXIS_RIGHT_X),
							 Input.get_joy_axis(device, JOY_AXIS_RIGHT_Y))
	if right_vec.length() < DEADZONE:
		right_vec = Vector2.ZERO

	# Route sticks through the map. Mirrors retro_controller._process ordering:
	# left assigns first, then right may overwrite an analog target.
	var alx := 0
	var aly := 0
	var arx := 0
	var ary := 0
	var lt: String = stick_map.get("stick_left", "left+dpad")
	var rt: String = stick_map.get("stick_right", "right")

	if "left" in lt:
		alx = int(left_vec.x * ANALOG_SCALE); aly = int(left_vec.y * ANALOG_SCALE)
	elif "right" in lt:
		arx = int(left_vec.x * ANALOG_SCALE); ary = int(left_vec.y * ANALOG_SCALE)
	if "dpad" in lt:
		btn |= _stick_to_dpad(left_vec)

	if "right" in rt:
		arx = int(right_vec.x * ANALOG_SCALE); ary = int(right_vec.y * ANALOG_SCALE)
	elif "left" in rt:
		alx = int(right_vec.x * ANALOG_SCALE); aly = int(right_vec.y * ANALOG_SCALE)
	if "dpad" in rt:
		btn |= _stick_to_dpad(right_vec)

	return {"btn": btn, "alx": alx, "aly": aly, "arx": arx, "ary": ary}

# ── Which joypads are actually gamepads ───────────────────────────────────────

## VR controller vendors. A Touch or a Knuckle can surface as an ordinary joypad
## on some Android/OpenXR builds, and everything downstream would then treat it as
## a gamepad: the SPAWN list would offer a "Oculus Touch Receiver" you could plug
## into an NES, a receiver could bind to the thing already in your hand, and the
## emulated pad would fight the hand that is meant to be free. The whole point of
## a receiver is that your VR controllers stay yours.
const XR_VENDORS := {
	0x2833: "Meta / Oculus",
	0x0BB4: "HTC",
	0x28DE: "Valve",
}

## Fallback for a platform that reports no vendor id. Matched case-insensitively
## against the device name — deliberately a substring test, because these arrive
## suffixed ("Oculus Touch (Left)") and prefixed by driver names.
const XR_NAME_HINTS := [
	"oculus", "quest", "meta ", "openxr", "vive", "valve index", "knuckles",
	"windows mixed reality", "wmr", "touch controller",
]

## Android gives Godot the InputDevice name and nothing else — no vendor id, no
## SDL GUID — and the Quest's own controllers carry no driver name, so they
## arrive as "Device 0x9873603F55A1038". A pad the player pairs advertises a
## product name.
const ANON_NAME_PREFIX := "device 0x"


## Joypads that are real gamepads: everything Godot reports, minus the VR
## controllers. THE gate — every enumeration in the project goes through here
## rather than calling Input.get_connected_joypads() directly, so a new caller
## cannot forget the question.
static func usable_pads() -> Array:
	var all := Input.get_connected_joypads()
	var out: Array = []
	for device: int in all:
		if not is_xr_device(device):
			out.append(device)
	if all != _last_seen:
		_last_seen = all.duplicate()
		for device: int in all:
			print("[Pads] %d '%s' guid='%s' vendor=0x%04x%s" % [device,
				Input.get_joy_name(device), Input.get_joy_guid(device),
				int(Input.get_joy_info(device).get("vendor_id",
					vendor_from_guid(Input.get_joy_guid(device)))),
				"" if device in out else "  [XR, not offered as a pad]"])
	return out


static func is_xr_device(device: int) -> bool:
	return is_xr_identity(Input.get_joy_name(device), Input.get_joy_guid(device),
		Input.get_joy_info(device))


## Split out from the device so it can be tested against real-world names and
## GUIDs without the hardware in hand.
##
## Vendor id first: it is the hardware speaking, and it does not change with a
## driver or a locale. `info` carries it where the platform fills it in; the SDL
## GUID embeds the same value at a fixed offset on the desktops. Android supplies
## neither, so there only the name tests can answer.
static func is_xr_identity(name: String, guid: String, info: Dictionary) -> bool:
	var vendor := int(info.get("vendor_id", 0))
	if vendor == 0:
		vendor = vendor_from_guid(guid)
	if XR_VENDORS.has(vendor):
		return true
	var lower := name.to_lower()
	for hint: String in XR_NAME_HINTS:
		if lower.contains(hint):
			return true
	return lower.begins_with(ANON_NAME_PREFIX)


## The vendor id an SDL joystick GUID carries, or 0 when it is not that shape.
## Layout is four little-endian 16-bit fields — bus, name CRC, vendor, then a
## zero — so the vendor is hex characters 8..12, low byte first.
static func vendor_from_guid(guid: String) -> int:
	if guid.length() < 12 or not guid.is_valid_hex_number():
		return 0
	return (guid.substr(10, 2) + guid.substr(8, 2)).hex_to_int()


# ── Device identity ───────────────────────────────────────────────────────────

## The live joypad index for a saved pad, or -1 when that pad is not connected.
##
## Keyed by GUID rather than index because the index is a connection order that
## changes every session, while the GUID describes the hardware. Two identical
## pads share a GUID, so `ordinal` picks the nth one of that model — stable within
## a session, and the only thing that can swap between them across sessions.
static func resolve_device(guid: String, ordinal: int = 0) -> int:
	if guid.is_empty():
		return -1
	var seen := 0
	for device: int in usable_pads():
		if Input.get_joy_guid(device) != guid:
			continue
		if seen == ordinal:
			return device
		seen += 1
	return -1


## GUID, name and ordinal for a live joypad index — what a receiver stores so it
## can find this pad again in a later session.
static func identify_device(device: int) -> Dictionary:
	var guid := Input.get_joy_guid(device)
	var ordinal := 0
	for other: int in usable_pads():
		if other == device:
			break
		if Input.get_joy_guid(other) == guid:
			ordinal += 1
	return {"guid": guid, "name": Input.get_joy_name(device), "ordinal": ordinal}


# ── Helpers ───────────────────────────────────────────────────────────────────

## Is the given binding currently active on the given device?
static func _binding_active(binding: String, device: int) -> bool:
	if binding.begins_with("btn:"):
		var idx := binding.substr(4).to_int()
		return Input.is_joy_button_pressed(device, idx as JoyButton)
	if binding.begins_with("axis:"):
		var parts := binding.split(":")
		if parts.size() < 3:
			return false
		var val := Input.get_joy_axis(device, parts[1].to_int() as JoyAxis)
		if parts[2] == "+":
			return val > TRIGGER_THRESHOLD
		return val < -TRIGGER_THRESHOLD
	return false


## Convert a stick vector to RetroPad d-pad bits (joy convention: +Y = down).
static func _stick_to_dpad(v: Vector2) -> int:
	var bits := 0
	if v.y < -DPAD_THRESHOLD: bits |= (1 << 4)   # UP
	if v.y >  DPAD_THRESHOLD: bits |= (1 << 5)   # DOWN
	if v.x < -DPAD_THRESHOLD: bits |= (1 << 6)   # LEFT
	if v.x >  DPAD_THRESHOLD: bits |= (1 << 7)   # RIGHT
	return bits



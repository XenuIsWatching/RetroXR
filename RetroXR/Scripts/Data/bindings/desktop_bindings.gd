## DesktopBindings — save, load, and apply keyboard/mouse bindings for desktop mode.
##
## Stored in user://desktop_bindings.json, merged project default → global →
## per-system, the same three layers ControllerBindings and GamepadBindings use.
## An entry is a serialised InputEvent, so a binding can be a key OR a mouse
## button; the capture in spawn_menu_controller accepts either.
##
## Unlike the other two stores this one cannot simply be READ per system: every
## consumer goes through Input.is_action_pressed(), and the InputMap those
## actions live in is global to the process. So a scope is APPLIED rather than
## looked up — apply_for_system() rewrites the map — and something has to decide
## when. That something is the Scroll Lock capture: exactly one controller can
## hold the keyboard at a time, so RetroController applies its system's profile
## when it takes the capture and puts the global map back when it lets go.
class_name DesktopBindings
extends RefCounted

const SAVE_PATH := "user://desktop_bindings.json"

## Gamepad button actions (joypad + trigger).
const JOYPAD_ACTIONS: Array = [
	"RETRO_JOYPAD_UP", "RETRO_JOYPAD_DOWN", "RETRO_JOYPAD_LEFT", "RETRO_JOYPAD_RIGHT",
	"RETRO_JOYPAD_A",  "RETRO_JOYPAD_B",    "RETRO_JOYPAD_X",    "RETRO_JOYPAD_Y",
	"RETRO_JOYPAD_L",  "RETRO_JOYPAD_R",    "RETRO_JOYPAD_L2",   "RETRO_JOYPAD_R2",
	"RETRO_JOYPAD_L3", "RETRO_JOYPAD_R3",   "RETRO_JOYPAD_SELECT","RETRO_JOYPAD_START",
	"trigger_left",
]

## Analog axis actions (each axis split into positive/negative actions).
const ANALOG_ACTIONS: Array = [
	"RETRO_ANALOG_LEFT_X_NEGATIVE",  "RETRO_ANALOG_LEFT_X_POSITIVE",
	"RETRO_ANALOG_LEFT_Y_NEGATIVE",  "RETRO_ANALOG_LEFT_Y_POSITIVE",
	"RETRO_ANALOG_RIGHT_X_NEGATIVE", "RETRO_ANALOG_RIGHT_X_POSITIVE",
	"RETRO_ANALOG_RIGHT_Y_NEGATIVE", "RETRO_ANALOG_RIGHT_Y_POSITIVE",
]

## Human-readable label for each action shown in the Controls UI.
const ACTION_LABELS: Dictionary = {
	"RETRO_JOYPAD_UP":     "D-pad Up",
	"RETRO_JOYPAD_DOWN":   "D-pad Down",
	"RETRO_JOYPAD_LEFT":   "D-pad Left",
	"RETRO_JOYPAD_RIGHT":  "D-pad Right",
	"RETRO_JOYPAD_A":      "A",
	"RETRO_JOYPAD_B":      "B",
	"RETRO_JOYPAD_X":      "X",
	"RETRO_JOYPAD_Y":      "Y",
	"RETRO_JOYPAD_L":      "L",
	"RETRO_JOYPAD_R":      "R",
	"RETRO_JOYPAD_L2":     "L2",
	"RETRO_JOYPAD_R2":     "R2",
	"RETRO_JOYPAD_L3":     "L3 (Click)",
	"RETRO_JOYPAD_R3":     "R3 (Click)",
	"RETRO_JOYPAD_SELECT": "Select",
	"RETRO_JOYPAD_START":  "Start",
	"trigger_left":        "Trigger / Shoot",
	"RETRO_ANALOG_LEFT_X_NEGATIVE":  "Left Stick \u2190",
	"RETRO_ANALOG_LEFT_X_POSITIVE":  "Left Stick \u2192",
	"RETRO_ANALOG_LEFT_Y_NEGATIVE":  "Left Stick \u2191",
	"RETRO_ANALOG_LEFT_Y_POSITIVE":  "Left Stick \u2193",
	"RETRO_ANALOG_RIGHT_X_NEGATIVE": "Right Stick \u2190",
	"RETRO_ANALOG_RIGHT_X_POSITIVE": "Right Stick \u2192",
	"RETRO_ANALOG_RIGHT_Y_NEGATIVE": "Right Stick \u2191",
	"RETRO_ANALOG_RIGHT_Y_POSITIVE": "Right Stick \u2193",
}


## Every action this class manages, in one list.
static func managed_actions() -> Array:
	return JOYPAD_ACTIONS + ANALOG_ACTIONS


static func _load_file() -> Dictionary:
	var data := JsonStore.read_dict(SAVE_PATH, "DesktopBindings")
	# Legacy shape: a flat action -> event dict, written before there were
	# layers. Read it as the global layer rather than discarding it, or every
	# desktop player loses their key map the first time they launch this build.
	if not data.is_empty() and not data.has("global") and not data.has("per_system"):
		return {"global": data}
	return data


static func _save_file(data: Dictionary) -> bool:
	return JsonStore.write_dict(SAVE_PATH, data, "DesktopBindings")


## Put one layer's events into the live InputMap.
static func _apply_layer(layer: Dictionary) -> void:
	for action: String in layer:
		if not InputMap.has_action(action):
			continue
		var ev := _dict_to_event(layer[action] as Dictionary)
		if ev == null:
			continue
		InputMap.action_erase_events(action)
		InputMap.action_add_event(action, ev)


## Rewrite the InputMap for one scope: project defaults, then the global layer,
## then that system's own. Reloading from project settings first is what stops a
## previous scope's keys lingering on actions the new scope does not name.
static func apply_for_system(systemid: String) -> void:
	InputMap.load_from_project_settings()
	var data := _load_file()
	_apply_layer(data.get("global", {}) as Dictionary)
	if not systemid.is_empty():
		var per_sys: Dictionary = data.get("per_system", {}) as Dictionary
		_apply_layer(per_sys.get(systemid, {}) as Dictionary)


## Load saved bindings and apply the global scope. Safe with no file present.
static func load_and_apply() -> void:
	apply_for_system("")


## The InputMap's current state for every managed action, as a storable layer.
static func _current_layer() -> Dictionary:
	var data: Dictionary = {}
	for action: String in managed_actions():
		_add_action_to_dict(data, action)
	return data


## Save the current InputMap state as the global layer.
static func save() -> void:
	var data := _load_file()
	data["global"] = _current_layer()
	_save_file(data)


## Save the current InputMap state as one system's profile. Falls through to
## save() on an empty systemid, the way the other two stores do, so one editor
## can serve both the global page and a platform page.
##
## The WHOLE map is written, not just the rows touched, which is what makes a
## profile an override rather than a patch — the same rule as the other stores.
static func save_for_system(systemid: String) -> void:
	if systemid.is_empty():
		save()
		return
	var data := _load_file()
	if not data.has("per_system"):
		data["per_system"] = {}
	data["per_system"][systemid] = _current_layer()
	_save_file(data)


## True when this system carries a key map of its own.
static func has_system_override(systemid: String) -> bool:
	if systemid.is_empty():
		return false
	var per_sys: Dictionary = _load_file().get("per_system", {}) as Dictionary
	return per_sys.has(systemid)


## Drop a system's key map so it falls back to global again.
static func clear_system_override(systemid: String) -> void:
	if systemid.is_empty():
		return
	var data := _load_file()
	var per_sys: Dictionary = data.get("per_system", {}) as Dictionary
	if not per_sys.has(systemid):
		return
	per_sys.erase(systemid)
	data["per_system"] = per_sys
	_save_file(data)


## Every systemid carrying a key map, for the per-platform tile badges.
static func overridden_systems() -> Array[String]:
	var out: Array[String] = []
	var per_sys: Dictionary = _load_file().get("per_system", {}) as Dictionary
	for sid: String in per_sys:
		out.append(sid)
	return out


static func _add_action_to_dict(data: Dictionary, action: String) -> void:
	if not InputMap.has_action(action):
		return
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return
	var d := _event_to_dict(events[0])
	if not d.is_empty():
		data[action] = d


## Returns a short human-readable string for the first binding of an action.
## E.g. "W", "LMB", "KP 2", "(none)".
static func event_display_name(action: String) -> String:
	if not InputMap.has_action(action):
		return "(none)"
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return "(none)"
	return _format_event(events[0])


static func _format_event(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var key := ev as InputEventKey
		var s := OS.get_keycode_string(key.physical_keycode)
		if s.is_empty():
			s = OS.get_keycode_string(key.keycode)
		return s if not s.is_empty() else "(key %d)" % key.physical_keycode
	if ev is InputEventMouseButton:
		match (ev as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT:   return "LMB"
			MOUSE_BUTTON_RIGHT:  return "RMB"
			MOUSE_BUTTON_MIDDLE: return "MMB"
			MOUSE_BUTTON_WHEEL_UP:   return "Wheel Up"
			MOUSE_BUTTON_WHEEL_DOWN: return "Wheel Down"
			var idx: return "MB%d" % idx
	return "?"


static func _event_to_dict(ev: InputEvent) -> Dictionary:
	if ev is InputEventKey:
		var key := ev as InputEventKey
		return {"type": "key", "physical_keycode": key.physical_keycode, "keycode": key.keycode}
	if ev is InputEventMouseButton:
		return {"type": "mouse", "button_index": (ev as InputEventMouseButton).button_index}
	return {}


static func _dict_to_event(d: Dictionary) -> InputEvent:
	match d.get("type", ""):
		"key":
			var ev := InputEventKey.new()
			ev.physical_keycode = int(d.get("physical_keycode", 0)) as Key
			ev.keycode          = int(d.get("keycode", 0)) as Key
			return ev
		"mouse":
			var ev := InputEventMouseButton.new()
			ev.button_index = int(d.get("button_index", MOUSE_BUTTON_LEFT)) as MouseButton
			ev.pressed = true
			return ev
	return null

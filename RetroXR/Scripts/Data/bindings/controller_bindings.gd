## ControllerBindings — load/save/query VR controller remapping profiles.
## Profiles are stored in user://controller_bindings.json.
## Lookup order: per-system → global → default (hardcoded).
class_name ControllerBindings
extends RefCounted

const SAVE_PATH := "user://controller_bindings.json"

## Every node that caches a binding map joins this group and exposes
## `reload_bindings()`. SpawnMenuController fans the save out over it, so a
## consumer is reached wherever it sits in the tree (HandheldInput is a child of
## its RetroSystem, not a spawned node in its own right).
const CONSUMER_GROUP := &"binding_consumers"

# ── Joypad button bit indices (RETRO_JOYPAD_*) ───────────────────────────────
const JOYPAD_NONE   := -1
const JOYPAD_B      := 0
const JOYPAD_Y      := 1
const JOYPAD_SELECT := 2
const JOYPAD_START  := 3
const JOYPAD_UP     := 4
const JOYPAD_DOWN   := 5
const JOYPAD_LEFT   := 6
const JOYPAD_RIGHT  := 7
const JOYPAD_A      := 8
const JOYPAD_X      := 9
const JOYPAD_L      := 10
const JOYPAD_R      := 11
const JOYPAD_L2     := 12
const JOYPAD_R2     := 13
const JOYPAD_L3     := 14
const JOYPAD_R3     := 15

## Human-readable names for joypad buttons (bit index → label).
const JOYPAD_NAMES: Dictionary = {
    -1: "None",
    0:  "B",
    1:  "Y",
    2:  "SELECT",
    3:  "START",
    4:  "D-Up",
    5:  "D-Down",
    6:  "D-Left",
    7:  "D-Right",
    8:  "A",
    9:  "X",
    10: "L",
    11: "R",
    12: "L2",
    13: "R2",
    14: "L3",
    15: "R3",
}

# ── Lightgun button IDs (RETRO_DEVICE_ID_LIGHTGUN_*) ─────────────────────────
const LIGHTGUN_NONE      := -1
const LIGHTGUN_TRIGGER   := 2
const LIGHTGUN_AUX_A     := 3
const LIGHTGUN_AUX_B     := 4
const LIGHTGUN_AUX_C     := 5
const LIGHTGUN_START     := 6
const LIGHTGUN_SELECT    := 7
const LIGHTGUN_DPAD_UP   := 8
const LIGHTGUN_DPAD_DOWN := 9
const LIGHTGUN_DPAD_LEFT := 10
const LIGHTGUN_DPAD_RIGHT := 11

## Human-readable names for lightgun buttons.
const LIGHTGUN_NAMES: Dictionary = {
    -1: "None",
    2:  "Trigger",
    3:  "Aux A",
    4:  "Aux B",
    5:  "Aux C",
    6:  "Start",
    7:  "Select",
    8:  "D-Up",
    9:  "D-Down",
    10: "D-Left",
    11: "D-Right",
}

# ── Default mappings ──────────────────────────────────────────────────────────

## Default joypad button map: "hand_source" → RETRO_JOYPAD bit index.
## Keys use "right_" or "left_" prefix + XRController input name.
## -1 = unassigned (button produces no output).
const DEFAULT_BUTTON_MAP: Dictionary = {
    "right_ax_button":     8,   # A
    "right_by_button":     0,   # B
    "right_grip":          11,  # R
    "right_trigger":       13,  # R2
    "right_primary_click": 3,   # START
    "left_ax_button":      9,   # X
    "left_by_button":      1,   # Y
    "left_grip":           10,  # L
    "left_trigger":        12,  # L2
    "left_primary_click":  2,   # SELECT
}

## Human-readable labels for each joypad button source.
const BUTTON_SOURCE_LABELS: Dictionary = {
    "right_ax_button":     "Right A",
    "right_by_button":     "Right B",
    "right_grip":          "Right Grip",
    "right_trigger":       "Right Trigger",
    "right_primary_click": "Right Stick Button",
    "left_ax_button":      "Left X",
    "left_by_button":      "Left Y",
    "left_grip":           "Left Grip",
    "left_trigger":        "Left Trigger",
    "left_primary_click":  "Left Stick Button",
}

## Default analog stick map: "stick_left"/"stick_right" → stick target string.
## Targets: "left", "right", "dpad", "left+dpad", "right+dpad"
const DEFAULT_STICK_MAP: Dictionary = {
    "stick_left":  "left+dpad",
    "stick_right": "right",
}

## Default lightgun button map: XRController input name → LIGHTGUN_* id.
## -1 = unassigned. "stick" key is special: value is "none" or "dpad" (string).
const DEFAULT_LIGHTGUN_MAP: Dictionary = {
    "trigger":       2,      # LIGHTGUN_TRIGGER
    "ax_button":     3,      # LIGHTGUN_AUX_A
    "by_button":     4,      # LIGHTGUN_AUX_B
    "grip":          -1,     # unassigned by default
    "primary_click": 6,      # LIGHTGUN_START
    "stick":         "dpad", # thumbstick → lightgun d-pad
}

## Default Wii Remote map: XRController input name → the remote's own control
## name. Named controls rather than joypad bit indices, because the bit a control
## lands on MOVES: attaching a Nunchuk shifts 1/2 off X/Y onto START/SELECT to
## free them for C/Z, which is how the core lays out its two descriptor tables.
## Wiimote._button_mask does that translation; this map only says which finger
## works which button. "stick" is special: "none" or "dpad".
##
## One hand carries five usable inputs and the remote has seven buttons, so this
## CANNOT cover all of them and is not meant to. It takes the four you need with
## a game running — A, B, 1 and 2 — plus + to start. The rest (-, HOME) are the
## ones you reach for between rounds, and those are poked on the shell itself
## with the free hand, which every button on the remote also answers to. Shake
## is left unbound: the remote's own motion drives the accelerometer.
const DEFAULT_WIIMOTE_MAP: Dictionary = {
    "trigger":       "b",       # index finger, on the underside — same as the real B
    "ax_button":     "a",
    "by_button":     "two",
    "grip":          "one",
    "primary_click": "plus",
    "stick":         "dpad",
}

## Two-hand Wii Remote map. Unlike the upright map, sources are hand-specific:
## the remote is physically a small pad now, so the left hand owns B/A/- and the
## D-pad while the right owns 1/2/+. Values are the PHYSICAL labels printed on
## the shell; Wiimote translates them to Dolphin's sideways RetroPad bits.
const DEFAULT_WIIMOTE_SIDEWAYS_MAP: Dictionary = {
    "left_trigger":        "b",
    "left_ax_button":      "a",
    "left_by_button":      "none",
    "left_grip":           "none",
    "left_primary_click":  "minus",
    "right_trigger":       "none",
    "right_ax_button":     "two",
    "right_by_button":     "one",
    "right_grip":          "none",
    "right_primary_click": "plus",
    "stick":               "dpad",
}

## Human-readable labels for each Wii Remote button source.
const WIIMOTE_SOURCE_LABELS: Dictionary = {
    "trigger":       "Trigger",
    "grip":          "Grip",
    "ax_button":     "A / X button",
    "by_button":     "B / Y button",
    "primary_click": "Stick Click",
    "stick":         "Thumbstick",
}

## The controls a Wii Remote can be bound to. "shake" is not a button on the
## hardware — the core takes a shake as one, so it is one here.
const WIIMOTE_CONTROLS: Array[String] = [
    "a", "b", "one", "two", "plus", "minus", "home", "shake",
    "up", "down", "left", "right",
]


## RetroPad target -> the Wii Remote control it drives, for the Controls page.
##
## The diagram is anchored on RetroPad targets because one table serves both the
## XR and the physical-pad sections, but the REMOTE is bound by control name, so
## the page needs to cross between them. Derived from Wiimote.DESKTOP_BUTTON_MAP
## would be circular here (this file is below that one), so it is stated, and
## binding_tests checks the two agree.
const WIIMOTE_CONTROL_OF_TARGET: Dictionary = {
    "b": "b", "a": "a", "x": "one", "y": "two",
    "start": "plus", "select": "minus", "r3": "home", "r2": "shake",
    "up": "up", "down": "down", "left": "left", "right": "right",
}

## Sideways RetroPad target -> physical label on the rotated Wii Remote.
const WIIMOTE_SIDEWAYS_CONTROL_OF_TARGET: Dictionary = {
    "b": "one", "a": "two", "x": "a", "y": "b",
    "start": "plus", "select": "minus", "r3": "home", "r2": "shake",
    "up": "right", "down": "left", "left": "up", "right": "down",
}

## Default Nunchuk map, read by the OFF hand. Only C and Z are bindable; the
## stick is always the stick and the shake is a real gesture, not an input.
const DEFAULT_NUNCHUK_MAP: Dictionary = {
    "c": "ax_button",
    "z": "trigger",
}

## Human-readable labels for each lightgun button source.
const LIGHTGUN_SOURCE_LABELS: Dictionary = {
    "trigger":       "Trigger",
    "grip":          "Grip",
    "ax_button":     "A / X button",
    "by_button":     "B / Y button",
    "primary_click": "Stick Click",
    "stick":         "Thumbstick",
}

# ── File I/O ──────────────────────────────────────────────────────────────────

## The upright Wiimote, sideways Wiimote and Nunchuk layers are OPTIONAL, and
## null means "leave whatever is stored alone" rather than "clear it".
static func save_global(button_map: Dictionary, stick_map: Dictionary, lightgun_map: Dictionary,
        wiimote_map: Variant = null, nunchuk_map: Variant = null,
        wiimote_sideways_map: Variant = null) -> void:
    var data := _load_file()
    if not data.has("global"):
        data["global"] = {}
    data["global"]["buttons"] = button_map
    data["global"]["sticks"] = stick_map
    data["global"]["lightgun"] = lightgun_map
    if wiimote_map != null:
        data["global"]["wiimote"] = wiimote_map
    if nunchuk_map != null:
        data["global"]["nunchuk"] = nunchuk_map
    if wiimote_sideways_map != null:
        data["global"]["wiimote_sideways"] = wiimote_sideways_map
    _save_file(data)


## Save per-system bindings. Falls back to save_global if systemid is empty.
##
## A profile is written WHOLE — that is what makes it pin a platform against
## later global edits — and the whole has six layers, not three. Replacing the
## entry with only buttons/sticks/lightgun is what used to destroy a stored
## Nunchuk map every time any other binding on that platform was saved: binding
## one thing silently reset another page, on a store the player never sees.
##
## So the three Wii layers are carried over from what is already there when the
## caller does not supply them. Everything else is still replaced outright.
static func save_for_system(systemid: String, button_map: Dictionary, stick_map: Dictionary,
        lightgun_map: Dictionary, wiimote_map: Variant = null,
        nunchuk_map: Variant = null, wiimote_sideways_map: Variant = null) -> void:
    if systemid.is_empty():
        save_global(button_map, stick_map, lightgun_map, wiimote_map, nunchuk_map,
            wiimote_sideways_map)
        return
    var data := _load_file()
    if not data.has("per_system"):
        data["per_system"] = {}
    var previous: Dictionary = (data["per_system"] as Dictionary).get(systemid, {}) as Dictionary
    var entry := {
        "buttons":  button_map,
        "sticks":   stick_map,
        "lightgun": lightgun_map,
    }
    var wiimote: Variant = wiimote_map if wiimote_map != null else previous.get("wiimote")
    var nunchuk: Variant = nunchuk_map if nunchuk_map != null else previous.get("nunchuk")
    var sideways: Variant = wiimote_sideways_map if wiimote_sideways_map != null \
        else previous.get("wiimote_sideways")
    if wiimote != null:
        entry["wiimote"] = wiimote
    if nunchuk != null:
        entry["nunchuk"] = nunchuk
    if sideways != null:
        entry["wiimote_sideways"] = sideways
    data["per_system"][systemid] = entry
    _save_file(data)


## Override bookkeeping is BindingStore's; see the rules on that class.
static func has_system_override(systemid: String) -> bool:
    return BindingStore.has_system_override(SAVE_PATH, "ControllerBindings", systemid)


static func clear_system_override(systemid: String) -> void:
    BindingStore.clear_system_override(SAVE_PATH, "ControllerBindings", systemid)


static func overridden_systems() -> Array[String]:
    return BindingStore.overridden_systems(SAVE_PATH, "ControllerBindings")


static func _load_file() -> Dictionary:
    return BindingStore.load_file(SAVE_PATH, "ControllerBindings")


static func _save_file(data: Dictionary) -> void:
    BindingStore.save_file(SAVE_PATH, "ControllerBindings", data)


static func _merge(base: Dictionary, overlay1: Dictionary,
        overlay2: Dictionary) -> Dictionary:
    return BindingStore.merge(base, overlay1, overlay2)

## Get merged bindings for a system: per-system overrides global, which overrides defaults.
## Returns a Dictionary with keys "buttons", "sticks", "lightgun".
static func get_for_system(systemid: String) -> Dictionary:
    var data := _load_file()
    var global_data: Dictionary = data.get("global", {}) as Dictionary
    var sys_data: Dictionary = {}
    if not systemid.is_empty():
        var per_sys: Dictionary = data.get("per_system", {}) as Dictionary
        sys_data = per_sys.get(systemid, {}) as Dictionary

    # All hardware-specific layers use the same default → global → system merge.
    return {
        "buttons":  _merge(DEFAULT_BUTTON_MAP,   global_data.get("buttons",  {}), sys_data.get("buttons",  {})),
        "sticks":   _merge(DEFAULT_STICK_MAP,     global_data.get("sticks",   {}), sys_data.get("sticks",   {})),
        "lightgun": _merge(DEFAULT_LIGHTGUN_MAP,  global_data.get("lightgun", {}), sys_data.get("lightgun", {})),
        "wiimote":  _merge(DEFAULT_WIIMOTE_MAP,   global_data.get("wiimote",  {}), sys_data.get("wiimote",  {})),
        "wiimote_sideways": _merge(DEFAULT_WIIMOTE_SIDEWAYS_MAP,
            global_data.get("wiimote_sideways", {}), sys_data.get("wiimote_sideways", {})),
        "nunchuk":  _merge(DEFAULT_NUNCHUK_MAP,   global_data.get("nunchuk",  {}), sys_data.get("nunchuk",  {})),
    }


## Get global bindings (global overrides of defaults, no per-system layer).
static func get_global() -> Dictionary:
    return get_for_system("")



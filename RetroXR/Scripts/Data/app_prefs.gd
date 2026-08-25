## AppPrefs — Autoload singleton holding the switches on the menu's OPTIONS tab,
## plus the player's hidden-systems list, persisted to user://app_prefs.json.
##
## Switches that back a global static (ControllerModel.draw_hands,
## SystemFilter.enabled) are pushed into it here at boot. The rest need the rig
## or the scene tree, so SpawnMenuController applies those once the menu is
## connected and the camera has been found.
##
## Defaults below are the values a fresh install starts with; a key missing from
## the JSON keeps its default rather than reading as false.
extends Node

const PREFS_PATH := "user://app_prefs.json"

var auto_save_scene:  bool = true
## Whether the room is also written back on a timer, not just when it is left.
## On by default: until this existed, quitting the app — or losing it to the
## Quest's own lifecycle — dropped everything placed since the last room change,
## and there is still no save-on-quit hook to fall back on.
var autosave_periodic: bool = true
## Seconds between periodic saves. Clamped to the slider's range on load so a
## hand-edited 0 cannot spin the timer every frame.
var autosave_interval: float = 60.0
const AUTOSAVE_INTERVAL_MIN := 15.0
const AUTOSAVE_INTERVAL_MAX := 300.0
var aim_crosshair:    bool = true
enum XRDisplayMode {
	CONTROLLERS,
	HANDS,
	BOTH,
}
## What the physical XR input devices look like. BOTH is deliberately the
## missing-key default too, so an existing install receives Capsense hands on
## its first run after the feature arrives rather than silently keeping the old
## controller-only presentation.
var xr_display_mode: XRDisplayMode = XRDisplayMode.BOTH
var controller_hands: bool = false
var system_filter:    bool = true
## Whether the spawn menu wraps onto a cylinder. Unlike the rest, this one is not
## an OPTIONS switch — it is the toggle on the menu's own lower-right corner.
var menu_curved:      bool = true
## Whether HeldHint pops its tooltip over a picked-up device.
var show_hints:       bool = true
## HeldHint row id -> times the player has used that verb. A row stops appearing
## past HeldHint.LEARNED_AFTER. A dictionary rather than a key per row so a new
## hint needs no change here.
var hint_uses:        Dictionary = {}
## Whether sound is spatialised by Meta XR Audio rather than Godot's own panning.
## Desktop only, and only offered there: on the Quest the SDK is the entire point,
## and its binaural rendering is right for a headset. On a desk it is not always —
## over speakers the HRTF is working against the room, and a surround rig gets no
## centre channel out of it, because the SDK renders two channels by design.
var spatial_audio_sdk: bool = true
## How the player gets around. Both verbs are on the LEFT stick and exactly one
## is live at a time — pushing the stick forward cannot mean "walk" and "aim a
## teleport" at once. False (smooth walking) is the default because it is the
## one that needs no explaining; teleport is the comfort option.
var locomotion_teleport: bool = false
## Whether the sticks still drive the player while passthrough is on. Sliding the
## world past you while you can see your actual room puts the two out of register,
## which is why it can be switched off — but the room you are standing in is rarely
## the size of the one you are furnishing, so walking alone is not enough to reach
## everything and the default is to leave locomotion working.
var passthrough_locomotion: bool = true
## Systemids the player has hidden from the Systems and Cartridges grids. One
## list for both: hiding a machine means "I don't care about this", not "not in
## this tab". Distinct from SystemFilter, which is our own opinion about which
## systemids are not consoles — this is the player's, and it survives a core
## being installed or removed.
var hidden_systems: PackedStringArray = []
## Show the hidden ones anyway, dimmed, so they can be unhidden. Not persisted
## as "off forever": a player who turns it on to unhide something and walks away
## should find the grid the way they left it.
var show_hidden_systems: bool = false
## Draw the Systems and Cartridges grids as squares of bare art — no name, no
## core count, no source badge. One pref for both, like the hidden list: it is a
## statement about how you want to read a grid, not about one tab.
var compact_tiles: bool = false

## The bedroom's time-of-day lever, 0 = morning .. 1 = night. 0.75 is the dusk the
## room was authored at, so an unset pref opens the room exactly as it always was.
##
## Here rather than in a save slot even though the bedroom now keeps slots:
## scene_persistence only tracks the "spawned" group, and the lever is an authored
## wall fixture that is not in it. A slot carries what the player put in the room;
## where they left the lever is a setting that outlives any one slot.
var bedroom_time_of_day: float = 0.75
## What GET_PREFERRED_HW_RENDER advertises to a core with no opinion of its own,
## matching the default the extension itself carries. A constant rather than a
## setting: there is no global switch for this, because the question is only
## ever interesting per core, and pushing this back is what stops the core that
## follows an overridden one from inheriting its API.
const DEFAULT_HW_RENDER := "vulkan"
## core_name -> a value from hw_render_choices(), for cores that need a
## different answer from the rest. Dolphin is the case that earns this: its
## Vulkan path hangs the Adreno GPU on Quest while GLES3 runs, and a single
## global would drag every other multi-API core off Vulkan to work around it.
## Set from CORES > Manager > (core) > FRONTEND; absent means the default above.
var hw_render_overrides: Dictionary = {}


## True when this systemid should be kept out of the grids.
func is_system_hidden(systemid: String) -> bool:
	return systemid in hidden_systems


## Hide or unhide a systemid and persist. No-op if already in that state.
func set_system_hidden(systemid: String, hidden: bool) -> void:
	if systemid.is_empty() or is_system_hidden(systemid) == hidden:
		return
	if hidden:
		hidden_systems.append(systemid)
	else:
		hidden_systems.remove_at(hidden_systems.find(systemid))
	save_prefs()


func _ready() -> void:
	_load_prefs()
	ControllerModel.draw_hands = controller_hands
	SystemFilter.enabled = system_filter
	_apply_spatial_audio()


## Which APIs this platform can hand a core, as [label, pref value,
## retro_hw_context_type]. Mirrors the switch in VideoHandler::SetHwRender:
## OpenGL is GLES3 on Android and the desktop core profile everywhere else, and
## the two D3D contexts exist only on Windows. Offering one the extension would
## reject is offering a black screen.
func hw_render_choices() -> Array:
	var out: Array = [["Vulkan", "vulkan", 6]]
	if OS.get_name() == "macOS":
		return out
	if OS.get_name() == "Android":
		out.append(["OpenGL ES 3", "opengl", 4])
	else:
		out.append(["OpenGL", "opengl", 3])
	if OS.get_name() == "Windows":
		out.append(["Direct3D 11", "d3d11", 7])
		out.append(["Direct3D 12", "d3d12", 9])
	return out


## The API this core will be offered: its own override, or the default.
func hw_render_for(core_name: String) -> String:
	var over := str(hw_render_overrides.get(core_name, ""))
	return over if not over.is_empty() else DEFAULT_HW_RENDER


## "" when this core has no override of its own.
func hw_render_override(core_name: String) -> String:
	return str(hw_render_overrides.get(core_name, ""))


## Set or, with an empty api, clear one core's override.
func set_hw_render_override(core_name: String, api: String) -> void:
	if core_name.is_empty():
		return
	if api.is_empty():
		hw_render_overrides.erase(core_name)
	else:
		hw_render_overrides[core_name] = api
	save_prefs()


## Push the answer for the core that is about to start. MUST run before
## StartContent: the static is read on the emulation thread while the core
## initialises, so a machine already switched on keeps the API it booted with.
func apply_hw_render_for(core_name: String) -> void:
	_push_hw_render(hw_render_for(core_name))


## A value naming an API this platform does not offer (a prefs file carried over
## from another one) pushes nothing, leaving whatever was set last standing —
## the extension's own default at boot.
func _push_hw_render(api: String) -> void:
	if not ClassDB.class_exists("Libretro"):
		return
	for choice: Array in hw_render_choices():
		if str(choice[1]) == api:
			ClassDB.class_call_static("Libretro", "SetPreferredHwRender", int(choice[2]))
			return


## Push the audio backend choice before anything builds an emitter. Ignored on
## Android, where the option is not offered and the pref could only be stale.
func _apply_spatial_audio() -> void:
	if OS.get_name() == "Android":
		return
	var listener := get_node_or_null("/root/SpatialAudioListener")
	if listener != null:
		listener.set_sdk_enabled(spatial_audio_sdk)
	elif Engine.has_singleton("MetaXRAudio"):
		Engine.get_singleton("MetaXRAudio").call("set_enabled", spatial_audio_sdk)


# ── Persistence ───────────────────────────────────────────────────────────────

func _load_prefs() -> void:
	if not FileAccess.file_exists(PREFS_PATH):
		return
	var file := FileAccess.open(PREFS_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed
	auto_save_scene  = _prefs_bool(data, "auto_save_scene",  auto_save_scene)
	autosave_periodic = _prefs_bool(data, "autosave_periodic", autosave_periodic)
	autosave_interval = clampf(_prefs_float(data, "autosave_interval", autosave_interval),
		AUTOSAVE_INTERVAL_MIN, AUTOSAVE_INTERVAL_MAX)
	# The performance HUD is deliberately absent: like the collision-shape
	# overlay it is a look at how the app is running, not a setting, so it lives
	# on PerfHud's statics and is off again every launch. A "show_fps" left in an
	# old file is simply ignored.
	aim_crosshair    = _prefs_bool(data, "aim_crosshair",    aim_crosshair)
	xr_display_mode = _prefs_xr_display_mode(data, "xr_display_mode", xr_display_mode)
	controller_hands = _prefs_bool(data, "controller_hands", controller_hands)
	system_filter    = _prefs_bool(data, "system_filter",    system_filter)
	menu_curved      = _prefs_bool(data, "menu_curved",      menu_curved)
	show_hints       = _prefs_bool(data, "show_hints",       show_hints)
	hint_uses        = _prefs_dict(data, "hint_uses",        hint_uses)
	spatial_audio_sdk = _prefs_bool(data, "spatial_audio_sdk", spatial_audio_sdk)
	locomotion_teleport = _prefs_bool(data, "locomotion_teleport", locomotion_teleport)
	passthrough_locomotion = _prefs_bool(data, "passthrough_locomotion", passthrough_locomotion)
	hidden_systems      = _prefs_strings(data, "hidden_systems")
	show_hidden_systems = _prefs_bool(data, "show_hidden_systems", show_hidden_systems)
	compact_tiles       = _prefs_bool(data, "compact_tiles",       compact_tiles)
	bedroom_time_of_day = clampf(_prefs_float(data, "bedroom_time_of_day",
		bedroom_time_of_day), 0.0, 1.0)
	hw_render_overrides = _prefs_dict(data, "hw_render_overrides", hw_render_overrides)


func save_prefs() -> void:
	var file := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("AppPrefs: cannot write %s" % PREFS_PATH)
		return
	file.store_string(JSON.stringify({
		"auto_save_scene":  auto_save_scene,
		"autosave_periodic": autosave_periodic,
		"autosave_interval": autosave_interval,
		"aim_crosshair":    aim_crosshair,
		"xr_display_mode":  xr_display_mode,
		"controller_hands": controller_hands,
		"system_filter":    system_filter,
		"menu_curved":      menu_curved,
		"show_hints":       show_hints,
		"hint_uses":        hint_uses,
		"spatial_audio_sdk": spatial_audio_sdk,
		"locomotion_teleport": locomotion_teleport,
		"passthrough_locomotion": passthrough_locomotion,
		"hidden_systems":    hidden_systems,
		"show_hidden_systems": show_hidden_systems,
		"compact_tiles":     compact_tiles,
		"bedroom_time_of_day": bedroom_time_of_day,
		"hw_render_overrides": hw_render_overrides,
	}, "\t"))
	file.close()


## A missing key or a JSON null must keep the default, not collapse to false.
func _prefs_bool(data: Dictionary, key: String, fallback: bool) -> bool:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_BOOL:
		return value
	return fallback


## Same contract as _prefs_bool. JSON numbers come back as floats, but a value
## written as a whole number can read as an int, so both are accepted.
func _prefs_float(data: Dictionary, key: String, fallback: float) -> float:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return float(value)
	return fallback


## Accept only the three named display modes. JSON numbers may be int or float;
## a stale or hand-edited value keeps the safe BOTH default.
func _prefs_xr_display_mode(data: Dictionary, key: String,
		fallback: XRDisplayMode) -> XRDisplayMode:
	var value: Variant = data.get(key)
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return fallback
	var mode := int(value)
	if mode < XRDisplayMode.CONTROLLERS or mode > XRDisplayMode.BOTH:
		return fallback
	return mode as XRDisplayMode


## JSON has no packed-array type, so a saved PackedStringArray reads back as a
## plain Array of whatever was in it. Rebuild it element by element and drop
## anything that is not a string rather than trusting the file.
func _prefs_strings(data: Dictionary, key: String) -> PackedStringArray:
	var out := PackedStringArray()
	var value: Variant = data.get(key)
	if typeof(value) != TYPE_ARRAY:
		return out
	for v: Variant in value as Array:
		if typeof(v) == TYPE_STRING and not (v as String).is_empty():
			out.append(v)
	return out


## Same contract as _prefs_bool. JSON gives back numbers as floats, so callers
## reading a count out of this must int() it.
func _prefs_dict(data: Dictionary, key: String, fallback: Dictionary) -> Dictionary:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_DICTIONARY:
		return value
	return fallback

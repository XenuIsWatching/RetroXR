## ControlsBindingEditor — the binding rows for ONE scope: the global map when
## `systemid` is empty, a single platform's own map otherwise.
##
## Three sections. Which of the first two appears depends on how the player is
## running: XR bindings in a headset, desktop key bindings at a desk. The
## physical-gamepad section is shown in both, because a USB or Bluetooth pad
## works either way.
##
## The desktop key section is global-only. DesktopBindings writes straight into
## Godot's InputMap, which has no notion of which machine you are standing at, so
## a platform-scoped editor shows a note there instead of rows.
##
## Rebinding needs help from outside — capturing "the next key press" or "the
## next pad button" has to happen where raw input arrives, not in a UI panel. So
## this asks by signal (rebind_started / pad_rebind_started) and the controller
## calls back into on_rebind_complete / on_pad_rebind_complete.
##
## Every change applies on the spot. There is no Save gate on the XR half: the
## button used to sit at the bottom of a scroll, below the joypad, stick AND
## lightgun sections, so a rebind looked like it had taken and silently had not.
class_name ControlsBindingEditor
extends VBoxContainer

## A row wants the next key/mouse press captured for `action_name`;
## spawn_menu_controller does the capturing and calls on_rebind_complete().
signal rebind_started(action_name: String)
## Same for a physical gamepad button, answered by on_pad_rebind_complete().
signal pad_rebind_started(target: String)
## Bindings were written — anything holding a copy should re-read them.
signal controller_bindings_changed

## Which scope this editor writes. Empty is the global map; anything else is that
## platform's profile, and writing one is what turns its override on.
var _systemid: String = ""

# XR working copies, applied on every change rather than gated behind a Save.
var _edit_button_map:   Dictionary = {}
var _edit_stick_map:    Dictionary = {}
var _edit_lightgun_map: Dictionary = {}
## The Nunchuk's own two keys. A separate map because it is keyed the other way
## round from the joypad one — control to source, not source to bit — and because
## it is stored under its own layer, which the writer keeps for us.
var _edit_nunchuk_map: Dictionary = {}
## The Wii Remote's own map, source -> control name. The remote resolves THIS and
## never the joypad one, so on the Wii page the picture edits this instead.
var _edit_wiimote_map: Dictionary = {}
var _edit_wiimote_sideways_map: Dictionary = {}

# Desktop rebinding: which action is listening, and action_name -> its Button so
# on_rebind_complete() can relabel it.
var _rebinding_action: String = ""
var _rebind_buttons: Dictionary = {}

## key -> VRDropdown, so a reset can move a dropdown without reopening it.
var _controls_opts: Dictionary = {}

# Physical gamepad: working copies, the diagram, and the fallback list.
var _edit_pad_button_map: Dictionary = {}
var _edit_pad_stick_map:  Dictionary = {}
var _pad_diagram: GamepadDiagram = null
var _pad_list_box: VBoxContainer = null
var _pad_rebinding_target: String = ""
var _pad_rebind_buttons: Dictionary = {}
var _pad_status_label: Label = null

# The console's own pad, when this platform has art for one. Null on the global
# page and on any platform ConsolePadArt does not cover.
var _console_xr_diagram: ConsolePadDiagram = null
## Every XR console diagram on the page — one per way the hardware is held. The
## Wii draws two; every other console draws one, which is _console_xr_diagram.
## They share a binding map, so a change on any of them refreshes all of them.
var _console_xr_diagrams: Array[ConsolePadDiagram] = []
var _console_pad_diagram: ConsolePadDiagram = null

## The desktop key map's diagram, and action -> control so a completed capture
## can find the row that asked for it.
var _desktop_diagram: ConsolePadDiagram = null
## Every desktop diagram on the page, for the same reason as _console_xr_diagrams.
var _desktop_diagrams: Array[ConsolePadDiagram] = []
var _desktop_control_of: Dictionary = {}


static func create(systemid: String = "") -> ControlsBindingEditor:
	var e := ControlsBindingEditor.new()
	e._systemid = systemid
	e._build()
	return e


## The scope this editor writes to.
func systemid() -> String:
	return _systemid


## Close the named inline dropdown.
func _close_dropdown(k: String) -> void:
	var drop := _controls_opts.get(k) as VRDropdown
	if drop:
		drop.close()


## Update an inline dropdown to reflect a new selection without reopening it.
func _reset_vr_dropdown(k: String, new_id: Variant) -> void:
	var drop := _controls_opts.get(k) as VRDropdown
	if drop:
		drop.select_id(new_id)


## Build a label + inline-expandable dropdown row. Thin wrapper over VRDropdown,
## which is shared with the core/TV/DVD panels — see vr_dropdown.gd for why an
## OptionButton cannot be used inside a VR viewport panel.
## options: Array of [display_name, id] where id is int or String.
func _make_vr_dropdown_row(
		key: String,
		label_text: String,
		options: Array,
		current_id: Variant,
		on_changed: Callable,
		grid_cols: int = 1
) -> VBoxContainer:
	var drop := VRDropdown.create(label_text, options, current_id,
		grid_cols, Vector2(220, 52), 20)
	drop.item_selected.connect(func(id: Variant) -> void: on_changed.call(id))
	_controls_opts[key] = drop
	return drop


# ── Controls remapping ────────────────────────────────────────────────────────

## Joypad button target choices: [display_name, bit_index].
const _JOYPAD_OPTIONS: Array = [
	["None",    -1],
	["B",        0], ["Y",       1], ["SELECT",  2], ["START",   3],
	["D-Up",     4], ["D-Down",  5], ["D-Left",  6], ["D-Right", 7],
	["A",        8], ["X",       9], ["L",       10], ["R",      11],
	["L2",      12], ["R2",     13], ["L3",      14], ["R3",     15],
]

## Analog stick target choices: [display_name, target_string].
const _STICK_OPTIONS: Array = [
	["Left Analog + D-pad",  "left+dpad"],
	["Left Analog",   "left"],
	["Right Analog + D-pad", "right+dpad"],
	["Right Analog",  "right"],
	["D-pad only",    "dpad"],
]

## Lightgun button target choices: [display_name, button_id].
const _LIGHTGUN_OPTIONS: Array = [
	["None",    -1],
	["Trigger",  2], ["Aux A",   3], ["Aux B",    4], ["Aux C",    5],
	["Start",    6], ["Select",  7],
	["D-Up",     8], ["D-Down",  9], ["D-Left",  10], ["D-Right", 11],
]

## Order in which joypad button sources appear in the Controls UI.
const _BUTTON_SOURCE_ORDER: Array = [
	"right_ax_button", "right_by_button", "right_grip", "right_trigger", "right_primary_click",
	"left_ax_button",  "left_by_button",  "left_grip",  "left_trigger",  "left_primary_click",
]

## Height reserved for the ControllerDiagram: five 56 px rows plus their gaps,
## with room for the art between the columns.
const _CONTROLS_DIAGRAM_H := 520.0

## Height reserved for a ConsolePadDiagram: a row of dropdowns above and below
## the art, with the picture between them.
const _CONSOLE_DIAGRAM_H := 470.0

## Height reserved for the desktop key map's diagram. Taller than a console
## pad's: the generic pad is roughly square and stacks eight rows a side.
const _DESKTOP_DIAGRAM_H := 620.0

## What can work the Nunchuk's C and Z: the same VR inputs the light gun offers,
## because it is the same hand and the same controller. "None" is included so a
## player can put a button beyond reach deliberately rather than only by accident.
const _NUNCHUK_OPTIONS: Array = [
	["None", "none"],
	["Trigger", "trigger"], ["Grip", "grip"],
	["A / X button", "ax_button"], ["B / Y button", "by_button"],
	["Thumbstick click", "primary_click"],
]

## Order in which lightgun sources appear in the Controls UI.
const _LIGHTGUN_SOURCE_ORDER: Array = [
	"trigger", "grip", "ax_button", "by_button", "primary_click",
]


func _build() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 14)

	if MenuStyle.is_vr_mode():
		_build_xr_controls(self)
	else:
		_build_desktop_controls(self)

	# Physical gamepad section — shown in both modes (a real pad works whether
	# the player is in VR or at the desktop). Added unconditionally because it
	# applies regardless of headset/desktop.
	add_child(HSeparator.new())
	_build_gamepad_controls(self)


func _build_xr_controls(vbox: VBoxContainer) -> void:
	# Load the bindings this scope currently resolves to as the working copy. For
	# a platform with no profile of its own that IS the global map, which is what
	# makes turning its override on a seed-from-global rather than a reset.
	var current := ControllerBindings.get_for_system(_systemid)
	_edit_button_map  = current["buttons"].duplicate()
	_edit_stick_map   = current["sticks"].duplicate()
	_edit_lightgun_map = current["lightgun"].duplicate()
	_edit_nunchuk_map = (current["nunchuk"] as Dictionary).duplicate()
	_edit_wiimote_map = (current["wiimote"] as Dictionary).duplicate()
	_edit_wiimote_sideways_map = (current["wiimote_sideways"] as Dictionary).duplicate()

	# ── Joypad Buttons ────────────────────────────────────────────────────────
	if ConsolePadArt.has(_systemid):
		# This platform's own controller, asked the way an override is meant to
		# be read: for each button the hardware HAS, what drives it. The generic
		# picture below offers all sixteen RetroPad bits, which on a console with
		# four buttons is mostly choices that do nothing.
		# The d-pad rows read None on a fresh map and that is not a fault: the
		# thumbstick drives the d-pad through the stick routing below, not through
		# any button source. Say so, rather than leaving four empty-looking rows.
		vbox.add_child(_hint("Pick which VR controller input works each button. "
			+ "The D-pad is driven by the thumbstick unless you bind a button to it."))

		# One diagram per way the hardware is HELD, not per platform. A Wii Remote
		# upright and the same remote turned sideways drive the same RetroPad bits
		# and print different names on them, so one picture cannot be right for
		# both. Every other console answers with a single key and is untouched.
		#
		# Upright has one unprefixed holding-hand map; sideways has a separate map
		# with left/right sources because both hands are active at once.
		for art_key: String in ConsolePadArt.variants_for(_systemid):
			var row := ConsolePadArt.row(art_key)
			vbox.add_child(MenuStyle.label(String(row["label"]), 18, MenuStyle.COLOR_LICENSE))

			var diagram := ConsolePadDiagram.new()
			diagram.custom_minimum_size = Vector2(0, _CONSOLE_DIAGRAM_H)
			diagram.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			vbox.add_child(diagram)
			diagram.setup(art_key, _console_source_options(art_key),
				_xr_current_by_control(art_key))
			diagram.binding_changed.connect(_on_console_xr_changed.bind(art_key))
			_console_xr_diagrams.append(diagram)
			# The first one is the platform's own, and is what the rest of this
			# class means when it says "the" console diagram.
			if _console_xr_diagram == null:
				_console_xr_diagram = diagram

			# Some pads carry a note about how the hardware is actually handled —
			# the Wii Remote's buttons being pokeable with the free hand, for one.
			# It lives on the ConsolePadArt row next to the art it describes, so
			# adding one for another console needs no change here.
			var pad_note := String(row.get("note", ""))
			if not pad_note.is_empty():
				vbox.add_child(_hint(pad_note))
	else:
		vbox.add_child(MenuStyle.label("XR Joypad Buttons", 18, MenuStyle.COLOR_LICENSE))

		# Picture of both controllers with a leader line from each input to its own
		# dropdown, instead of ten unillustrated "Left Grip"-style rows. Its
		# dropdowns register under the same "btn:<src>" keys, so reset still drives
		# them through _reset_vr_dropdown.
		var diagram := ControllerDiagram.new()
		diagram.custom_minimum_size = Vector2(0, _CONTROLS_DIAGRAM_H)
		diagram.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		diagram.setup(_edit_button_map, _JOYPAD_OPTIONS)
		diagram.binding_changed.connect(func(src: String, bit: int) -> void:
			_edit_button_map[src] = bit
			_apply_xr_bindings())
		vbox.add_child(diagram)

		for src: String in _BUTTON_SOURCE_ORDER:
			_controls_opts["btn:" + src] = diagram.get_dropdown(src)

	# ── Analog Sticks ─────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())

	# A Wii Remote has no analog stick, so it is offered none. The two rows below
	# route a thumbstick to the RetroPad's left or right analog, and a Wii Remote
	# has a D-PAD and nothing else — its Nunchuk's one stick is the Nunchuk's, and
	# is not bindable either.
	#
	# They were not merely meaningless there, they were INERT: the remote resolves
	# its own layer and reads _wiimote_map["stick"], never the joypad stick map,
	# so moving either dropdown changed nothing at all. Two controls that look
	# live and do nothing are worse than two that are missing.
	if _systemid == "wii":
		vbox.add_child(MenuStyle.label("Control Stick", 18, MenuStyle.COLOR_LICENSE))
		vbox.add_child(_hint("The Wii Remote has a D-pad and no analog stick, so "
			+ "the thumbstick of the hand holding it works the D-pad. A Nunchuk "
			+ "brings its own stick, on the hand holding that."))
	else:
		vbox.add_child(MenuStyle.label("Analog Sticks", 18, MenuStyle.COLOR_LICENSE))

		for stick: String in ["stick_left", "stick_right"]:
			var s_label := "Left Stick" if stick == "stick_left" else "Right Stick"
			var def_target := "left+dpad" if stick == "stick_left" else "right"
			var current_target: String = _edit_stick_map.get(stick, def_target)
			var captured_stick := stick
			vbox.add_child(_make_vr_dropdown_row(
				"stick:" + stick, s_label, _STICK_OPTIONS, current_target,
				func(v: Variant) -> void:
					_edit_stick_map[captured_stick] = v as String
					_apply_xr_bindings(),
				3
			))

	# ── The Nunchuk ───────────────────────────────────────────────────────────
	# Only for the platform that has one. Rows and not a diagram: there are three
	# controls, one of which cannot be bound at all, and a picture of a Nunchuk
	# seen side-on shows two buttons edge-on — all the cost of art for less than a
	# list gives.
	if _systemid == "wii":
		vbox.add_child(HSeparator.new())
		vbox.add_child(MenuStyle.label("Nunchuk", 18, MenuStyle.COLOR_LICENSE))
		vbox.add_child(_hint("The Nunchuk is held in your other hand, so its "
			+ "buttons are bound on that hand's controller. Plugging one in also "
			+ "moves the remote's own 1 and 2 onto the buttons + and - were on, "
			+ "and puts C and Z where 1 and 2 were — the console does that, not "
			+ "the room."))

		for key: String in ["c", "z"]:
			var captured_key := key
			vbox.add_child(_make_vr_dropdown_row(
				"nc:" + key, key.to_upper() + " Button", _NUNCHUK_OPTIONS,
				str(_edit_nunchuk_map.get(key, "none")),
				func(v: Variant) -> void:
					_edit_nunchuk_map[captured_key] = str(v)
					_apply_xr_bindings(),
				3
			))

		# The stick is not a choice. It is whichever hand is holding the Nunchuk,
		# read straight off that controller — see Nunchuk.get_state. Saying so is
		# worth a row: left out, the section looks like it forgot the stick.
		var stick_row := HBoxContainer.new()
		stick_row.add_theme_constant_override("separation", 12)
		var stick_name := Label.new()
		stick_name.text = "Control Stick"
		stick_name.custom_minimum_size = Vector2(220, 0)
		stick_row.add_child(stick_name)
		var stick_value := Label.new()
		stick_value.text = "Thumbstick of the hand holding it"
		stick_value.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
		stick_row.add_child(stick_value)
		vbox.add_child(stick_row)

	# ── Light Gun Buttons ─────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	vbox.add_child(MenuStyle.label("Light Gun Buttons", 18, MenuStyle.COLOR_LICENSE))

	for src: String in _LIGHTGUN_SOURCE_ORDER:
		var label: String = ControllerBindings.LIGHTGUN_SOURCE_LABELS.get(src, src)
		var current_id: int = _edit_lightgun_map.get(src, -1)
		var captured_src := src
		vbox.add_child(_make_vr_dropdown_row(
			"gun:" + src, label, _LIGHTGUN_OPTIONS, current_id,
			func(v: Variant) -> void:
				_edit_lightgun_map[captured_src] = v as int
				_apply_xr_bindings(),
			4
		))

	# Thumbstick mode row
	var stick_label: String = ControllerBindings.LIGHTGUN_SOURCE_LABELS.get("stick", "Thumbstick")
	var cur_stick_mode: String = str(_edit_lightgun_map.get("stick", "dpad"))
	vbox.add_child(_make_vr_dropdown_row(
		"gun:stick", stick_label,
		[["None", "none"], ["D-pad", "dpad"]],
		cur_stick_mode,
		func(v: Variant) -> void:
			_edit_lightgun_map["stick"] = v as String
			_apply_xr_bindings(),
		2
	))

	# ── Action buttons ────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 10)
	action_row.custom_minimum_size = Vector2(0, 60)
	vbox.add_child(action_row)

	var reset_btn := Button.new()
	reset_btn.text = _reset_label()
	reset_btn.custom_minimum_size = Vector2(220, 52)
	reset_btn.add_theme_font_size_override("font_size", 18)
	reset_btn.pressed.connect(_on_controls_reset)
	action_row.add_child(reset_btn)

	# No Save button any more: every dropdown above applies itself. It used to sit
	# here, at the bottom of a scroll, below the joypad, stick AND lightgun
	# sections — so a rebind looked like it had taken and silently had not.


## Reset drops this scope back to the layer beneath it: the hardcoded defaults
## for the global map, the global map for a platform.
func _reset_label() -> String:
	return "Reset to Default" if _systemid.is_empty() else "Reset to Global"


## The keyboard and mouse map, drawn on a pad rather than listed.
##
## This scope's bindings are pushed into the InputMap first, because that map IS
## the store here — every row reads its label back out of it. Leaving the page
## puts the right scope back; see SpawnMenuControlsView.
func _build_desktop_controls(vbox: VBoxContainer) -> void:
	_rebind_buttons.clear()
	_desktop_control_of.clear()
	_desktop_diagrams.clear()
	_desktop_diagram = null
	DesktopBindings.apply_for_system(_systemid)

	# A platform with a pad of its own gets it; anything else binds the generic
	# RetroPad, which is what the core sees regardless.
	var pad_id := _systemid if ConsolePadArt.has(_systemid) else ConsolePadArt.RETROPAD

	vbox.add_child(MenuStyle.label("Keyboard & Mouse", 18, MenuStyle.COLOR_LICENSE))
	vbox.add_child(_hint("Press a button below, then press the key or mouse button "
		+ "you want on it. Escape cancels."))

	# One picture per way the hardware is HELD, same as the XR section. The keys
	# are bound once and every picture shows them, because the console is what
	# relabels the bits — see ConsolePadArt.variants_for.
	var pad_keys: Array = ConsolePadArt.variants_for(_systemid)
	if pad_keys.is_empty():
		pad_keys = [pad_id]
	for i: int in pad_keys.size():
		var key: String = pad_keys[i]
		var diagram := ConsolePadDiagram.new()
		diagram.custom_minimum_size = Vector2(0, _DESKTOP_DIAGRAM_H)
		diagram.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if i > 0:
			vbox.add_child(MenuStyle.label(String(ConsolePadArt.row(key)["label"]),
				18, MenuStyle.COLOR_LICENSE))
		vbox.add_child(diagram)
		diagram.setup(key, [], _desktop_current_by_control(key),
			ConsolePadDiagram.RowKind.BIND)
		diagram.bind_requested.connect(_on_desktop_bind_requested)
		_desktop_diagrams.append(diagram)
		# The FIRST picture owns the action lookup. Every variant shows the same
		# actions under different names, so letting a later one overwrite the map
		# would point a completed capture at the row that happens to be last.
		if _desktop_diagram == null:
			_desktop_diagram = diagram
			for control: String in diagram.controls():
				_desktop_control_of[_desktop_action_for(control)] = control
		var pad_note := String(ConsolePadArt.row(key).get("note", ""))
		if i > 0 and not pad_note.is_empty():
			vbox.add_child(_hint(pad_note))

	# Anything the generic pad has no anchor for — the analog stick directions and
	# the light-gun trigger — still has to be bindable, so it stays a list.
	#
	# ONLY under the generic pad. A console's own page must not offer the buttons
	# its hardware never had: a NES has no X, no shoulders and no sticks, and
	# listing them there would put back exactly the noise this whole feature
	# exists to remove.
	var rest: Array = []
	if pad_id == ConsolePadArt.RETROPAD:
		for action: String in DesktopBindings.managed_actions():
			if not _desktop_control_of.has(action):
				rest.append(action)
	if not rest.is_empty():
		vbox.add_child(HSeparator.new())
		vbox.add_child(MenuStyle.label("Analog Sticks & Trigger", 18, MenuStyle.COLOR_LICENSE))
		for action: String in rest:
			vbox.add_child(_make_rebind_row(action))

	# ── Reset ─────────────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 10)
	action_row.custom_minimum_size = Vector2(0, 60)
	vbox.add_child(action_row)

	var reset_btn := Button.new()
	reset_btn.text = _reset_label()
	reset_btn.custom_minimum_size = Vector2(220, 52)
	reset_btn.add_theme_font_size_override("font_size", 18)
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.pressed.connect(_on_desktop_controls_reset)
	action_row.add_child(reset_btn)

	# No Save button: every capture writes on the spot, the way the XR and pad
	# halves do. It used to need one, and a rebind that looked applied but was
	# not is exactly what Tools/input/binding_live_probe.tscn exists to catch.


## The InputMap action a console control binds. Control keys are RetroPad target
## strings and the actions are named for the same targets, so this is the whole
## mapping.
func _desktop_action_for(control: String) -> String:
	return "RETRO_JOYPAD_" + control.to_upper()


func _desktop_current_by_control(pad_id: String) -> Dictionary:
	var out: Dictionary = {}
	var anchors: Dictionary = ConsolePadArt.row(pad_id).get("anchors", {})
	for control: String in anchors:
		out[control] = DesktopBindings.event_display_name(_desktop_action_for(control))
	return out


func _on_desktop_bind_requested(control: String) -> void:
	_rebinding_action = _desktop_action_for(control)
	rebind_started.emit(_rebinding_action)


## Creates a single rebind row: [Label: action display name] [Button: current key]
func _make_rebind_row(action: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 48)

	var lbl := Label.new()
	lbl.text = DesktopBindings.ACTION_LABELS.get(action, action)
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var btn := Button.new()
	btn.text = DesktopBindings.event_display_name(action)
	btn.custom_minimum_size = Vector2(140, 44)
	btn.add_theme_font_size_override("font_size", 18)
	_rebind_buttons[action] = btn

	var captured_action := action
	btn.pressed.connect(func() -> void:
		# Cancel any in-progress rebind first.
		if _rebinding_action != "" and _rebinding_action != captured_action:
			var old_btn: Button = _rebind_buttons.get(_rebinding_action) as Button
			if is_instance_valid(old_btn):
				old_btn.text = DesktopBindings.event_display_name(_rebinding_action)
		_rebinding_action = captured_action
		btn.text = "[ Press a key… ]"
		rebind_started.emit(captured_action)
	)
	row.add_child(btn)
	return row


## Called by spawn_menu_controller after a key/mouse press is captured.
## The event is null when the user cancelled with Escape; the binding is read
## back from DesktopBindings either way.
func on_rebind_complete(action: String, _event: InputEvent) -> void:
	_rebinding_action = ""
	var label := DesktopBindings.event_display_name(action)

	# The capture wrote straight into the InputMap, so the binding is already
	# live; what is left is telling the row and putting it on disk in THIS
	# editor's scope rather than always the global one.
	# Every picture, not just the first. The variants show the same key under
	# different names, so relabelling one leaves the others reading the key that
	# was there before the capture.
	if _desktop_control_of.has(action):
		var control := String(_desktop_control_of[action])
		for d: ConsolePadDiagram in _desktop_diagrams:
			if is_instance_valid(d) and d.controls().has(control):
				d.set_bind_label(control, label)
	var btn: Button = _rebind_buttons.get(action) as Button
	if is_instance_valid(btn):
		btn.text = label

	DesktopBindings.save_for_system(_systemid)
	controller_bindings_changed.emit()


## Reset drops this scope back to the layer beneath it, like the other two: the
## project defaults for the global map, the global map for a platform.
func _on_desktop_controls_reset() -> void:
	if _systemid.is_empty():
		InputMap.load_from_project_settings()
		DesktopBindings.save()
	else:
		DesktopBindings.clear_system_override(_systemid)
		DesktopBindings.apply_for_system(_systemid)

	for d: ConsolePadDiagram in _desktop_diagrams:
		if is_instance_valid(d):
			d.refresh(_desktop_current_by_control(d.systemid()))
	for action: String in _rebind_buttons:
		var btn: Button = _rebind_buttons[action] as Button
		if is_instance_valid(btn):
			btn.text = DesktopBindings.event_display_name(action)
	controller_bindings_changed.emit()


## Write this scope's XR bindings and push them to everything holding a copy.
## Called from every dropdown, so a change is live the moment it is made — which
## is what a dropdown implies, and what the missing Save button used to gate.
## The Nunchuk map rides along on every write, and must: save_for_system carries
## a stored layer over only when the caller offers nothing, so passing it here is
## what makes a change to C or Z actually land. Passing it on the OTHER writes
## costs nothing and keeps one path.
func _apply_xr_bindings() -> void:
	ControllerBindings.save_for_system(_systemid,
		_edit_button_map, _edit_stick_map, _edit_lightgun_map,
		_edit_wiimote_map, _edit_nunchuk_map, _edit_wiimote_sideways_map)
	controller_bindings_changed.emit()


## Write both halves out without the player touching a row. Materialises a
## platform's profile the moment its override switch goes on.
func apply_all() -> void:
	if MenuStyle.is_vr_mode():
		ControllerBindings.save_for_system(_systemid,
			_edit_button_map, _edit_stick_map, _edit_lightgun_map,
			_edit_wiimote_map, _edit_nunchuk_map, _edit_wiimote_sideways_map)
	GamepadBindings.save_for_system(_systemid, _edit_pad_button_map, _edit_pad_stick_map)
	if not MenuStyle.is_vr_mode():
		DesktopBindings.save_for_system(_systemid)
	controller_bindings_changed.emit()


func _on_controls_reset() -> void:
	if _systemid.is_empty():
		_edit_button_map   = ControllerBindings.DEFAULT_BUTTON_MAP.duplicate()
		_edit_stick_map    = ControllerBindings.DEFAULT_STICK_MAP.duplicate()
		_edit_lightgun_map = ControllerBindings.DEFAULT_LIGHTGUN_MAP.duplicate()
		_edit_nunchuk_map  = ControllerBindings.DEFAULT_NUNCHUK_MAP.duplicate()
		_edit_wiimote_map = ControllerBindings.DEFAULT_WIIMOTE_MAP.duplicate()
		_edit_wiimote_sideways_map = \
			ControllerBindings.DEFAULT_WIIMOTE_SIDEWAYS_MAP.duplicate()
	else:
		# The layer beneath a platform is the global map, not the shipped default.
		var g := ControllerBindings.get_global()
		_edit_button_map   = (g["buttons"] as Dictionary).duplicate()
		_edit_stick_map    = (g["sticks"] as Dictionary).duplicate()
		_edit_lightgun_map = (g["lightgun"] as Dictionary).duplicate()
		_edit_nunchuk_map  = (g["nunchuk"] as Dictionary).duplicate()
		_edit_wiimote_map = (g["wiimote"] as Dictionary).duplicate()
		_edit_wiimote_sideways_map = (g["wiimote_sideways"] as Dictionary).duplicate()
	for src: String in _BUTTON_SOURCE_ORDER:
		_reset_vr_dropdown("btn:" + src, _edit_button_map.get(src, -1))
	for stick: String in ["stick_left", "stick_right"]:
		var def := "left+dpad" if stick == "stick_left" else "right"
		_reset_vr_dropdown("stick:" + stick, _edit_stick_map.get(stick, def))
	for src: String in _LIGHTGUN_SOURCE_ORDER:
		_reset_vr_dropdown("gun:" + src, _edit_lightgun_map.get(src, -1))
	_reset_vr_dropdown("gun:stick", str(_edit_lightgun_map.get("stick", "dpad")))
	for key: String in ["c", "z"]:
		_reset_vr_dropdown("nc:" + key, str(_edit_nunchuk_map.get(key, "none")))
	_refresh_console_xr_diagrams()
	_apply_xr_bindings()


# ── The console's own pad ─────────────────────────────────────────────────────
#
# Both sections anchor on the console's controls and choose a SOURCE for each,
# which is the inverse of how the two stores are keyed on the XR side and the
# same as how they are keyed on the gamepad side. The conversions live here
# rather than in the diagram, so the widget stays about drawing.

func _hint(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return lbl


## The VR inputs a console control can be driven by, as glyphs. Falls back to
## the input's name for anything the glyph set does not cover, so a new source
## still appears rather than becoming a blank row.
## The inputs a console control can be driven by on this page.
##
## Upright Wii uses five unprefixed inputs from whichever hand holds it. Its
## sideways variant uses both controllers, so it offers the ten hand-prefixed
## sources used by an ordinary two-hand pad.
func _console_source_options(art_key: String = "") -> Array:
	if not _uses_wiimote_layer():
		return _xr_source_options()
	if art_key == ConsolePadArt.WII_SIDEWAYS:
		return _xr_source_options()
	# "" and not "none" for the empty choice, matching _xr_source_options. The
	# diagram selects by matching the current value against an option id, and
	# _wiimote_source_for answers "" for a control nothing is bound to — so an id
	# of "none" matches nothing and every unbound row renders BLANK rather than
	# saying None.
	var out: Array = [["None", ""]]
	for src: String in ["trigger", "grip", "ax_button", "by_button", "primary_click"]:
		out.append([String(ControllerBindings.WIIMOTE_SOURCE_LABELS.get(src, src)), src])
	return out


func _xr_source_options() -> Array:
	var out: Array = [["None", ""]]
	for src: String in _BUTTON_SOURCE_ORDER:
		var label := String(ControllerBindings.BUTTON_SOURCE_LABELS.get(src, src))
		var tex := _glyph(String(ControllerDiagram.GLYPHS.get(src, "")))
		out.append(["", src, tex] if tex else [label, src])
	return out


## The physical-pad buttons a console control can be driven by, as glyphs.
func _pad_source_options() -> Array:
	var out: Array = [["None", "none"]]
	for input: String in GamepadDiagram.INPUTS:
		var row: Dictionary = GamepadDiagram.INPUTS[input]
		var label := String(GamepadDiagram.INPUT_LABELS.get(input, input))
		var tex := _glyph(String(row.get("glyph", "")))
		out.append(["", String(row["bind"]), tex] if tex else [label, String(row["bind"])])
	return out


func _glyph(name_text: String) -> Texture2D:
	if name_text.is_empty():
		return null
	return load(ConsolePadDiagram.GLYPH_DIR + name_text
		+ ConsolePadDiagram.GLYPH_EXT) as Texture2D


## The VR input currently driving a RetroPad bit, or "" for none. The stored map
## runs source -> bit, so this is a reverse lookup; where two sources share a bit
## the first in _BUTTON_SOURCE_ORDER wins, and picking anything on that control
## collapses the pair.
func _xr_source_for_bit(bit: int) -> String:
	if bit < 0:
		return ""
	for src: String in _BUTTON_SOURCE_ORDER:
		if int(_edit_button_map.get(src, -1)) == bit:
			return src
	return ""


## Repaint every console diagram from the map belonging to that variant.
func _refresh_console_xr_diagrams() -> void:
	for d: ConsolePadDiagram in _console_xr_diagrams:
		if is_instance_valid(d):
			d.refresh(_xr_current_by_control(d.systemid()))


## True when this scope's own hardware is bound through the wiimote layer rather
## than the generic joypad one.
##
## Worth a named question rather than an inline == : the whole defect this fixes
## was the page editing a map its hardware does not read, and the fix is only as
## good as every site agreeing on which map that is.
func _uses_wiimote_layer() -> bool:
	return _systemid == "wii"


## Which VR input works a given Wii Remote control, "" for none.
func _wiimote_source_for(control: String, art_key: String = "") -> String:
	var sideways := art_key == ConsolePadArt.WII_SIDEWAYS
	var crossing := ControllerBindings.WIIMOTE_SIDEWAYS_CONTROL_OF_TARGET \
		if sideways else ControllerBindings.WIIMOTE_CONTROL_OF_TARGET
	var wii := String(crossing.get(control, ""))
	if wii.is_empty():
		return ""
	var binding_map := _edit_wiimote_sideways_map if sideways else _edit_wiimote_map
	for src: String in binding_map:
		if src != "stick" and String(binding_map[src]) == wii:
			return src
	return ""


## What each control on ONE picture currently reads.
##
## Keyed by art key rather than by systemid, because a variant carries a
## different set of controls in a different order — and asking the platform for
## them would fill a sideways diagram from the upright one's list, which is a
## picture whose rows do not match its own anchors.
func _xr_current_by_control(art_key: String = "") -> Dictionary:
	if art_key.is_empty():
		art_key = _systemid
	var out: Dictionary = {}
	for control: String in ConsolePadArt.controls(art_key):
		out[control] = _wiimote_source_for(control, art_key) if _uses_wiimote_layer() \
			else _xr_source_for_bit(ConsolePadArt.bit_of(control))
	return out


func _pad_current_by_control() -> Dictionary:
	var out: Dictionary = {}
	for control: String in ConsolePadArt.controls(_systemid):
		out[control] = String(_edit_pad_button_map.get(control, "none"))
	return out


## One source per control: free whatever drove this button, then assign. Taking a
## source off another button is correct — one finger cannot do two jobs — and the
## whole diagram is refreshed because the button it left now reads None.
func _on_console_xr_changed(control: String, id: Variant, art_key: String = "") -> void:
	if _uses_wiimote_layer():
		_on_wiimote_control_changed(control, id, art_key)
		return
	var bit := ConsolePadArt.bit_of(control)
	if bit < 0:
		return
	for other: String in _BUTTON_SOURCE_ORDER:
		if int(_edit_button_map.get(other, -1)) == bit:
			_edit_button_map[other] = ControllerBindings.JOYPAD_NONE
	var src := String(id)
	if not src.is_empty():
		_edit_button_map[src] = bit
	_apply_xr_bindings()
	_refresh_console_xr_diagrams()


## The same rule as the joypad one, over the remote's own map: one source works
## one control, so choosing a source for a control takes it off whatever it was
## on. Keyed the other way round from the joypad map -- source to control, not
## source to bit -- which is why it cannot share that code.
func _on_wiimote_control_changed(control: String, id: Variant, art_key: String = "") -> void:
	var sideways := art_key == ConsolePadArt.WII_SIDEWAYS
	var crossing := ControllerBindings.WIIMOTE_SIDEWAYS_CONTROL_OF_TARGET \
		if sideways else ControllerBindings.WIIMOTE_CONTROL_OF_TARGET
	var wii := String(crossing.get(control, ""))
	if wii.is_empty():
		return
	var binding_map := _edit_wiimote_sideways_map if sideways else _edit_wiimote_map
	for src: String in binding_map.keys():
		if src != "stick" and String(binding_map[src]) == wii:
			binding_map[src] = "none"
	var chosen := String(id)
	if not chosen.is_empty() and chosen != "none":
		binding_map[chosen] = wii
	_apply_xr_bindings()
	_refresh_console_xr_diagrams()


## Same rule, but duplicates are cleared only across the controls this pad SHOWS.
## A hidden target holding the same button is left alone: the console has no such
## button, so nothing it drives is visible, and silently clearing a binding the
## player cannot see would be worse than the duplicate.
func _on_console_pad_changed(control: String, id: Variant) -> void:
	var binding := String(id)
	if binding != "none" and not binding.is_empty():
		for other: String in ConsolePadArt.controls(_systemid):
			if other != control and String(_edit_pad_button_map.get(other, "none")) == binding:
				_edit_pad_button_map[other] = "none"
	_edit_pad_button_map[control] = binding
	_on_pad_controls_save()
	if is_instance_valid(_console_pad_diagram):
		_console_pad_diagram.refresh(_pad_current_by_control())


# ── Physical gamepad remapping ────────────────────────────────────────────────

func _build_gamepad_controls(vbox: VBoxContainer) -> void:
	_pad_rebind_buttons.clear()
	var pad := GamepadBindings.get_for_system(_systemid)
	_edit_pad_button_map = pad["buttons"].duplicate()
	_edit_pad_stick_map  = pad["sticks"].duplicate()

	# ── Header ────────────────────────────────────────────────────────────────
	vbox.add_child(MenuStyle.label("GAME CONTROLLER", 22, MenuStyle.COLOR_TITLE))

	# ── Hardware a gamepad cannot stand in for ────────────────────────────────
	# Some controllers are not a pad with the buttons moved around. The Wii Remote
	# is pointed and swung: its IR pointer, accelerometer and gyro have nothing on
	# a gamepad to map onto, and drawing the usual grid would say an ordinary pad
	# plays these the way they were meant to be played. Where a ConsolePadArt row
	# says so, the whole remapping section is that sentence instead — including the
	# connected-pad status, which would otherwise report a pad that cannot help.
	var no_pad := String(ConsolePadArt.row(_systemid).get("gamepad_note", ""))
	if not no_pad.is_empty():
		vbox.add_child(_hint(no_pad))
		return

	# ── Connected-pad status line ─────────────────────────────────────────────
	var status := Label.new()
	status.add_theme_font_size_override("font_size", 16)
	status.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(status)
	_pad_status_label = status
	_refresh_pad_status()
	if not Input.joy_connection_changed.is_connected(_on_pad_connection_changed):
		Input.joy_connection_changed.connect(_on_pad_connection_changed)

	# ── Diagram ───────────────────────────────────────────────────────────────
	if ConsolePadArt.has(_systemid):
		vbox.add_child(_hint("Pick which button on your gamepad works each one."))
		_console_pad_diagram = ConsolePadDiagram.new()
		_console_pad_diagram.custom_minimum_size = Vector2(0, _CONSOLE_DIAGRAM_H)
		_console_pad_diagram.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(_console_pad_diagram)
		_console_pad_diagram.setup(_systemid, _pad_source_options(),
			_pad_current_by_control())
		_console_pad_diagram.binding_changed.connect(_on_console_pad_changed)
	else:
		_pad_diagram = GamepadDiagram.new()
		_pad_diagram.custom_minimum_size = Vector2(0, 580)
		_pad_diagram.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(_pad_diagram)
		_pad_diagram.setup(_edit_pad_button_map)
		_pad_diagram.binding_changed.connect(_on_pad_diagram_changed)

	# ── Buttons (press-to-rebind; joypad presses reach us in VR and desktop) ──
	# Behind a switch, because the diagram covers it for an Xbox-layout pad. It
	# stays reachable for the ones it cannot: a pad with paddles or extra buttons
	# reports indices the picture has nowhere to point at, and Guide is left off
	# the diagram on purpose.
	var list_row := HBoxContainer.new()
	list_row.add_theme_constant_override("separation", 10)
	list_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(list_row)

	var btn_hdr := Label.new()
	btn_hdr.text = "Button list (for pads the diagram can't show)"
	btn_hdr.add_theme_font_size_override("font_size", 18)
	btn_hdr.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	btn_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_row.add_child(btn_hdr)

	var list_box := VBoxContainer.new()
	list_box.visible = false
	vbox.add_child(list_box)
	_pad_list_box = list_box

	list_row.add_child(VRToggle.create(false, func(on: bool) -> void:
		if is_instance_valid(_pad_list_box):
			_pad_list_box.visible = on
	))

	for target: String in GamepadBindings.TARGET_ORDER:
		list_box.add_child(_make_pad_rebind_row(target))

	# ── Analog Sticks ─────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	vbox.add_child(MenuStyle.label("Analog Sticks", 18, MenuStyle.COLOR_LICENSE))

	for stick: String in ["stick_left", "stick_right"]:
		var s_label := "Left Stick" if stick == "stick_left" else "Right Stick"
		var def_target := "left+dpad" if stick == "stick_left" else "right"
		var current_target: String = _edit_pad_stick_map.get(stick, def_target)
		var captured_stick := stick
		vbox.add_child(_make_vr_dropdown_row(
			"padstick:" + stick, s_label, _STICK_OPTIONS, current_target,
			func(v: Variant) -> void:
				_edit_pad_stick_map[captured_stick] = v as String
				_on_pad_controls_save(),
			3
		))

	# ── Action buttons ────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 10)
	action_row.custom_minimum_size = Vector2(0, 60)
	vbox.add_child(action_row)

	var reset_btn := Button.new()
	reset_btn.text = _reset_label()
	reset_btn.custom_minimum_size = Vector2(220, 52)
	reset_btn.add_theme_font_size_override("font_size", 18)
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.pressed.connect(_on_pad_controls_reset)
	action_row.add_child(reset_btn)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.custom_minimum_size = Vector2(220, 52)
	save_btn.add_theme_font_size_override("font_size", 18)
	save_btn.focus_mode = Control.FOCUS_NONE
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_on_pad_controls_save)
	action_row.add_child(save_btn)


## Creates a single gamepad rebind row: [Label: RetroPad target] [Button: binding].
func _make_pad_rebind_row(target: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 48)

	var lbl := Label.new()
	lbl.text = GamepadBindings.TARGET_LABELS.get(target, target)
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var binding: String = _edit_pad_button_map.get(target, "none")
	var btn := Button.new()
	btn.text = GamepadBindings.binding_display_name(binding)
	btn.custom_minimum_size = Vector2(160, 44)
	btn.add_theme_font_size_override("font_size", 18)
	btn.focus_mode = Control.FOCUS_NONE
	_pad_rebind_buttons[target] = btn

	var captured_target := target
	btn.pressed.connect(func() -> void:
		# Cancel any in-progress pad rebind first.
		if _pad_rebinding_target != "" and _pad_rebinding_target != captured_target:
			var old_btn: Button = _pad_rebind_buttons.get(_pad_rebinding_target) as Button
			if is_instance_valid(old_btn):
				var prev: String = _edit_pad_button_map.get(_pad_rebinding_target, "none")
				old_btn.text = GamepadBindings.binding_display_name(prev)
		_pad_rebinding_target = captured_target
		btn.text = "[ Press gamepad… ]"
		pad_rebind_started.emit(captured_target)
	)
	row.add_child(btn)
	return row


## Called by spawn_menu_controller after a joypad press is captured.
## binding is "" when the user cancelled.
func on_pad_rebind_complete(target: String, binding: String) -> void:
	_pad_rebinding_target = ""
	if binding != "":
		_edit_pad_button_map[target] = binding
		_on_pad_controls_save()
		# The same binding is shown in both places; a capture must move the
		# diagram too or the two disagree until the tab is rebuilt.
		_refresh_pad_diagram()
		if is_instance_valid(_console_pad_diagram):
			_console_pad_diagram.refresh(_pad_current_by_control())
	var btn: Button = _pad_rebind_buttons.get(target) as Button
	if is_instance_valid(btn):
		var cur: String = _edit_pad_button_map.get(target, "none")
		btn.text = GamepadBindings.binding_display_name(cur)


## The diagram edits input -> target; the stored map is target -> binding. One
## input drives one target, so assigning a target that another input already held
## takes it away from that one, and the diagram is refreshed to show it released.
func _on_pad_diagram_changed(input: String, target: String) -> void:
	var by_input := GamepadDiagram.invert(_edit_pad_button_map)
	if target != "":
		for other: String in by_input.keys():
			if other != input and String(by_input[other]) == target:
				by_input.erase(other)
	by_input[input] = target
	_edit_pad_button_map = GamepadDiagram.to_button_map(by_input)
	_on_pad_controls_save()
	_refresh_pad_diagram()
	_refresh_pad_list()


func _refresh_pad_diagram() -> void:
	if not is_instance_valid(_pad_diagram):
		return
	var by_input := GamepadDiagram.invert(_edit_pad_button_map)
	for key: String in GamepadDiagram.INPUTS:
		_pad_diagram.set_binding(key, String(by_input.get(key, "")))


func _refresh_pad_list() -> void:
	for target: String in GamepadBindings.TARGET_ORDER:
		var btn: Button = _pad_rebind_buttons.get(target) as Button
		if is_instance_valid(btn):
			btn.text = GamepadBindings.binding_display_name(
				_edit_pad_button_map.get(target, "none"))


func _on_pad_controls_reset() -> void:
	if _systemid.is_empty():
		_edit_pad_button_map = GamepadBindings.DEFAULT_BUTTON_MAP.duplicate()
		_edit_pad_stick_map  = GamepadBindings.DEFAULT_STICK_MAP.duplicate()
	else:
		var g := GamepadBindings.get_global()
		_edit_pad_button_map = (g["buttons"] as Dictionary).duplicate()
		_edit_pad_stick_map  = (g["sticks"] as Dictionary).duplicate()
	_refresh_pad_diagram()
	if is_instance_valid(_console_pad_diagram):
		_console_pad_diagram.refresh(_pad_current_by_control())
	for target: String in GamepadBindings.TARGET_ORDER:
		var btn: Button = _pad_rebind_buttons.get(target) as Button
		if is_instance_valid(btn):
			var cur: String = _edit_pad_button_map.get(target, "none")
			btn.text = GamepadBindings.binding_display_name(cur)
	for stick: String in ["stick_left", "stick_right"]:
		var def := "left+dpad" if stick == "stick_left" else "right"
		_reset_vr_dropdown("padstick:" + stick, _edit_pad_stick_map.get(stick, def))
	_on_pad_controls_save()


func _on_pad_controls_save() -> void:
	GamepadBindings.save_for_system(_systemid, _edit_pad_button_map, _edit_pad_stick_map)
	if not MenuStyle.is_vr_mode():
		DesktopBindings.save_for_system(_systemid)
	controller_bindings_changed.emit()


func _refresh_pad_status() -> void:
	if not is_instance_valid(_pad_status_label):
		return
	var pads := GamepadBindings.usable_pads()
	if pads.is_empty():
		_pad_status_label.text = "No gamepad detected — connect one via USB or Bluetooth."
		return
	var names: Array[String] = []
	for device: int in pads:
		names.append(Input.get_joy_name(device))
	_pad_status_label.text = "%d pad(s): %s" % [pads.size(), ", ".join(names)]


func _on_pad_connection_changed(_device: int, _connected: bool) -> void:
	_refresh_pad_status()

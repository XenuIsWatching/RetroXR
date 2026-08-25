## SpawnMenuSceneView — the menu's SCENE tab: pick a room, or manage a room's
## save slots.
##
## Two panels stacked in one Control, one visible at a time: the room picker, and
## the slot grid you reach through the card of any room in SceneManager.SLOT_ROOMS.
## Everything it wants done it asks for by signal — SpawnMenu2D relays these to
## its own, so the controller on the far side is unchanged.
class_name SpawnMenuSceneView
extends Control

signal scene_change_requested(scene_id: String)
## The slot signals all name the room whose grid is open. Each room in
## SceneManager.SLOT_ROOMS keeps its own set, and this panel shows one at a time.
signal slot_load_requested(slot_id: String, room_id: String)
signal slot_save_requested(slot_id: String, room_id: String)
signal slot_delete_requested(slot_id: String, room_id: String)
signal slot_create_requested(room_id: String)
signal slot_rename_requested(slot_id: String, new_name: String, room_id: String)
## Which of the two panels' scrolls the thumbstick should now drive. The menu
## owns _active_scroll, and this view switches panels on its own.
signal scroll_changed(scroll: ScrollContainer)

## Room id -> the name shown on its card and over its slot grid. One table for
## both, so a card and the header you reach through it cannot drift apart.
## SceneManager.SCENE_TITLES is the loading screen's copy and is upper-case; these
## are the menu's own casing.
const ROOM_TITLES := {
	"bedroom":     "90s Bedroom",
	"arcade":      "Arcade Room",
	"den":         "Cozy Den",
	"test":        "Test Hallway",
	"passthrough": "Passthrough AR",
}

var _rooms_panel:   Control         = null
var _states_panel:  Control         = null
var _rooms_grid:    GridContainer   = null
var _passthrough_card: Control      = null
var _rooms_scroll:  ScrollContainer = null
var _states_scroll: ScrollContainer = null
var _states_vbox:   VBoxContainer   = null
## slot_id -> pending-hide. A card's action row is revealed on hover and hidden a
## frame late, so moving between the card and its own buttons does not flicker.
var _hover_pending: Dictionary      = {}
var _rename_slot_id: String         = ""
var _rename_edit:   LineEdit        = null
## Which room's slots the states panel is showing.
var _slot_room:     String          = "bedroom"
var _states_title:  Label           = null
## The bottom "+ Save New" bar. Hidden for a room the player is not standing in:
## saving writes the CURRENT scene's contents, which are not that room's.
var _save_bar:      Control         = null


static func create() -> SpawnMenuSceneView:
	var v := SpawnMenuSceneView.new()
	v._build()
	return v


static func _scene_manager() -> Node:
	return Engine.get_main_loop().root.get_node_or_null("SceneManager")


## The scroll the currently visible panel owns.
func active_scroll() -> ScrollContainer:
	return _states_scroll if _states_panel != null and _states_panel.visible else _rooms_scroll


func _build() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	# ── Level 1: Rooms panel ──────────────────────────────────────────────────
	var rooms_scroll := MenuStyle.vscroll()
	rooms_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rooms_scroll = rooms_scroll
	_rooms_panel = rooms_scroll
	add_child(rooms_scroll)

	var rooms_vbox := MenuStyle.vbox(14)
	rooms_scroll.add_child(rooms_vbox)

	rooms_vbox.add_child(MenuStyle.spacer(10))
	rooms_vbox.add_child(MenuStyle.header("SCENES", 24))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	rooms_vbox.add_child(grid)
	_rooms_grid = grid

	# 90s Bedroom card → navigates to its state grid. Leads the grid: it is the
	# room the player boots into and the one they furnish.
	grid.add_child(_make_room_card(ROOM_TITLES["bedroom"], Color(0.30, 0.16, 0.36),
		show_states.bind("bedroom")))

	# Arcade Room card → navigates to its state grid
	grid.add_child(_make_room_card(ROOM_TITLES["arcade"], Color(0.15, 0.13, 0.35),
		show_states.bind("arcade")))

	# Cozy Den card → direct scene switch
	grid.add_child(_make_room_card(ROOM_TITLES["den"], Color(0.4, 0.25, 0.12),
		func(): scene_change_requested.emit("den")))

	# Test Hallway card → direct scene switch
	grid.add_child(_make_room_card("Test Hallway", Color(0.12, 0.32, 0.30),
		func(): scene_change_requested.emit("test")))

	# Passthrough card (only if supported) → direct scene switch. Added late: see
	# _sync_passthrough_card.
	_sync_passthrough_card()

	# ── Level 2: States panel ─────────────────────────────────────────────────
	var states_root := VBoxContainer.new()
	states_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	states_root.add_theme_constant_override("separation", 0)
	states_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	states_root.visible = false
	_states_panel = states_root
	add_child(states_root)

	# Back / title row
	var back_row := MenuStyle.hbox(8)
	back_row.custom_minimum_size = Vector2(0, 52)
	states_root.add_child(back_row)

	var back_btn := Button.new()
	back_btn.add_theme_font_override("font", MenuIcons.symbols())
	back_btn.text = "%s Back" % String.chr(MenuIcons.BACK)
	back_btn.add_theme_font_size_override("font_size", 20)
	back_btn.pressed.connect(show_rooms)
	back_row.add_child(back_btn)

	var title_lbl := MenuStyle.header(ROOM_TITLES["bedroom"])
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	back_row.add_child(title_lbl)
	_states_title = title_lbl

	# Spacer so title stays centered despite back button width
	var back_spacer := Control.new()
	back_spacer.custom_minimum_size = back_btn.custom_minimum_size
	back_spacer.size_flags_horizontal = Control.SIZE_SHRINK_END
	back_row.add_child(back_spacer)

	# Slot scroll
	_states_scroll = MenuStyle.vscroll()
	states_root.add_child(_states_scroll)

	_states_vbox = MenuStyle.vbox(10)
	_states_scroll.add_child(_states_vbox)

	# Bottom bar: Save New
	var bottom_bar := HBoxContainer.new()
	bottom_bar.custom_minimum_size = Vector2(0, 64)
	bottom_bar.add_theme_constant_override("separation", 0)
	states_root.add_child(bottom_bar)
	_save_bar = bottom_bar

	var save_new_btn := Button.new()
	save_new_btn.text = "  + Save New  "
	save_new_btn.add_theme_font_size_override("font_size", 22)
	save_new_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_new_btn.custom_minimum_size = Vector2(0, 64)
	save_new_btn.add_theme_stylebox_override("normal",
		MenuStyle.rounded(MenuStyle.COLOR_BTN_SAVE, 6))
	save_new_btn.pressed.connect(func(): slot_create_requested.emit(_slot_room))
	bottom_bar.add_child(save_new_btn)


# ── Panel navigation ──────────────────────────────────────────────────────────

func show_rooms() -> void:
	_sync_passthrough_card()
	if _rooms_panel:
		_rooms_panel.visible = true
	if _states_panel:
		_states_panel.visible = false
	scroll_changed.emit(_rooms_scroll)


## Whether the runtime offers an alpha-blend mode is only knowable once the
## OpenXR session is up, and this view is built from the player rig's _ready() —
## early enough that a headset which does support passthrough still answers no.
## So the question is re-asked every time the tab is opened, and the card appears
## as soon as the answer changes.
func _sync_passthrough_card() -> void:
	if _passthrough_card != null or _rooms_grid == null:
		return
	var sm := _scene_manager()
	if sm == null or not sm.is_passthrough_supported():
		return
	# Straight to its state grid, like the arcade: passthrough is the other room
	# whose whole contents were spawned, so it keeps slots of its own and picking
	# one is how you enter it. "Clean Room" is the empty-handed way in.
	_passthrough_card = _make_room_card("Passthrough AR", Color(0.85, 0.85, 0.9),
		show_states.bind("passthrough"))
	_rooms_grid.add_child(_passthrough_card)


## Open the slot grid for one room. Bound into that room's card, so which grid
## this is stays with the card rather than being inferred from where the player
## happens to be standing.
func show_states(room_id: String = "bedroom") -> void:
	_slot_room = room_id
	if _states_title != null:
		_states_title.text = _room_title(room_id)
	if _rooms_panel:
		_rooms_panel.visible = false
	if _states_panel:
		_states_panel.visible = true
	scroll_changed.emit(_states_scroll)
	rebuild_states_grid()


func _room_title(room_id: String) -> String:
	return ROOM_TITLES.get(room_id, room_id)


## True while the player is standing in the room whose grid is open — the only
## time the current scene's contents are this room's to write.
func _in_shown_room() -> bool:
	var sm := _scene_manager()
	return sm != null and sm.is_room_ready(_slot_room)


# ── Cards ─────────────────────────────────────────────────────────────────────

func _make_room_card(label_text: String, thumb_color: Color, on_press: Callable) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, 120)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var card_vbox := VBoxContainer.new()
	card_vbox.add_theme_constant_override("separation", 6)
	card_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(card_vbox)

	var thumb := PanelContainer.new()
	thumb.custom_minimum_size = Vector2(0, 70)
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb.add_theme_stylebox_override("panel", MenuStyle.rounded(thumb_color, 4))
	card_vbox.add_child(thumb)

	var lbl := MenuStyle.label(label_text, 18, MenuStyle.COLOR_TITLE)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card_vbox.add_child(lbl)

	btn.pressed.connect(on_press)
	return btn


## Rebuild the slot grid. Public because a save, load or delete lands on
## SceneManager rather than here, and the menu asks for a repaint afterwards.
func rebuild_states_grid() -> void:
	if not _states_vbox:
		return
	for child in _states_vbox.get_children():
		child.queue_free()
	_hover_pending.clear()

	var persistence := ScenePersistence.new(_slot_room)
	var slots := persistence.get_slots()
	var sm := _scene_manager()
	var active_id: String = sm.active_slot(_slot_room) if sm else "clean"
	if _save_bar != null:
		_save_bar.visible = _in_shown_room()

	for slot: Dictionary in slots:
		_states_vbox.add_child(_make_state_card(slot, active_id))

	_states_vbox.add_child(MenuStyle.spacer(8))


func _make_state_card(slot: Dictionary, active_slot_id: String) -> Control:
	var slot_id: String   = slot.get("id", "")
	var slot_name: String = slot.get("name", "")
	var readonly: bool    = slot.get("readonly", false)
	var is_active: bool   = (slot_id == active_slot_id)
	var is_renaming: bool = (slot_id == _rename_slot_id)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 90)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var card_style := MenuStyle.rounded(
		MenuStyle.COLOR_SLOT_ACTIVE if is_active else MenuStyle.COLOR_SLOT_NORMAL, 6)
	if is_active:
		card_style.border_width_top = 2
		card_style.border_width_bottom = 2
		card_style.border_width_left = 2
		card_style.border_width_right = 2
		card_style.border_color = Color(0.5, 0.8, 0.5)
	panel.add_theme_stylebox_override("panel", card_style)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)
	inner.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_child(inner)

	# Name row
	var name_row := MenuStyle.hbox(6)
	name_row.mouse_filter = Control.MOUSE_FILTER_PASS
	inner.add_child(name_row)

	if is_renaming:
		var edit := LineEdit.new()
		edit.text = slot_name
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.add_theme_font_size_override("font_size", 20)
		_rename_edit = edit
		edit.text_submitted.connect(func(_t: String) -> void:
			_finish_rename()
		)
		edit.focus_exited.connect(func() -> void:
			_finish_rename()
		)
		name_row.add_child(edit)
	elif readonly:
		var name_lbl := MenuStyle.label(slot_name, 20, MenuStyle.COLOR_TITLE)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_row.add_child(name_lbl)
	else:
		var name_btn := Button.new()
		name_btn.text = slot_name
		name_btn.add_theme_font_size_override("font_size", 20)
		name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_btn.flat = true
		name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_btn.pressed.connect(_start_rename.bind(slot_id, slot_name))
		name_btn.mouse_entered.connect(_on_card_hover_enter.bind(slot_id, null))
		name_btn.mouse_exited.connect(_on_card_hover_exit.bind(slot_id, null))
		name_row.add_child(name_btn)

	if is_active:
		var dot := MenuStyle.label(String.chr(MenuIcons.DOT), 18, Color(0.4, 0.9, 0.4))
		dot.add_theme_font_override("font", MenuIcons.symbols())
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_row.add_child(dot)

	# Action row (hidden until hover)
	var action_row := MenuStyle.hbox(8)
	action_row.visible = false
	action_row.mouse_filter = Control.MOUSE_FILTER_PASS
	inner.add_child(action_row)

	var load_btn := _make_action_btn("Load", MenuStyle.COLOR_BTN_LOAD)
	load_btn.pressed.connect(func(): slot_load_requested.emit(slot_id, _slot_room))
	load_btn.mouse_entered.connect(_on_card_hover_enter.bind(slot_id, action_row))
	load_btn.mouse_exited.connect(_on_card_hover_exit.bind(slot_id, action_row))
	action_row.add_child(load_btn)

	if not readonly:
		# Save only where it means something: overwriting a slot writes the CURRENT
		# scene, so offering it while standing somewhere else is offering to fill an
		# arcade slot with a passthrough room. Delete is not like that — a slot can
		# be binned from anywhere, and Load is how you travel to one.
		if _in_shown_room():
			var save_btn := _make_action_btn("Save", MenuStyle.COLOR_BTN_SAVE)
			save_btn.pressed.connect(func(): slot_save_requested.emit(slot_id, _slot_room))
			save_btn.mouse_entered.connect(_on_card_hover_enter.bind(slot_id, action_row))
			save_btn.mouse_exited.connect(_on_card_hover_exit.bind(slot_id, action_row))
			action_row.add_child(save_btn)

		var del_btn := _make_action_btn("Delete", MenuStyle.COLOR_BTN_CLEAR)
		del_btn.pressed.connect(func(): slot_delete_requested.emit(slot_id, _slot_room))
		del_btn.mouse_entered.connect(_on_card_hover_enter.bind(slot_id, action_row))
		del_btn.mouse_exited.connect(_on_card_hover_exit.bind(slot_id, action_row))
		action_row.add_child(del_btn)

	# Hover on the outer panel itself
	panel.mouse_entered.connect(_on_card_hover_enter.bind(slot_id, action_row))
	panel.mouse_exited.connect(_on_card_hover_exit.bind(slot_id, action_row))

	return panel


func _make_action_btn(label_text: String, bg_color: Color) -> Button:
	var btn := Button.new()
	btn.text = label_text
	btn.add_theme_font_size_override("font_size", 18)
	btn.custom_minimum_size = Vector2(80, 36)
	btn.add_theme_stylebox_override("normal", MenuStyle.rounded(bg_color, 4))
	return btn


func _on_card_hover_enter(slot_id: String, action_row: HBoxContainer) -> void:
	_hover_pending[slot_id] = false
	if action_row:
		action_row.visible = true


func _on_card_hover_exit(slot_id: String, action_row: HBoxContainer) -> void:
	_hover_pending[slot_id] = true
	(func(): _deferred_card_hide(slot_id, action_row)).call_deferred()


func _deferred_card_hide(slot_id: String, action_row: HBoxContainer) -> void:
	if _hover_pending.get(slot_id, false):
		if is_instance_valid(action_row):
			action_row.visible = false
		_hover_pending.erase(slot_id)


func _start_rename(slot_id: String, _current_name: String) -> void:
	_rename_slot_id = slot_id
	_rename_edit = null
	rebuild_states_grid()
	# Don't programmatically grab_focus() — it causes Android EditText desync
	# (Godot #72969). The user taps the LineEdit to focus it, which naturally
	# opens the overlay keyboard via virtual_keyboard_enabled (default true).


func _finish_rename() -> void:
	# Guard: if already cleared (e.g. called twice), bail immediately.
	if _rename_slot_id.is_empty():
		return
	var edit := _rename_edit
	var slot_id := _rename_slot_id
	# Clear state first so any re-entrant calls are no-ops.
	_rename_slot_id = ""
	_rename_edit = null
	var new_name := edit.text.strip_edges() if edit else ""
	if not new_name.is_empty():
		slot_rename_requested.emit(slot_id, new_name, _slot_room)
	rebuild_states_grid()

## CoreOptions2D — 2D UI for libretro core options and controller port configuration.
## Loaded into CoreOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Builds its entire UI programmatically (same pattern as SpawnMenu2D).
##
## Two tabs:
##   Options   — cycle < / > through each core option value
##   Controllers — OptionButton per port to choose the active device type
##
## Emits:
##   option_changed(key, value)     — user changed a core option
##   port_device_changed(port, id)  — user changed a port's device type
##   close_requested                — user pressed ✕
class_name CoreOptions2D
extends Control

signal option_changed(key: String, value: String)
## User pressed "Reset all to defaults" at the top of the Options tab.
signal options_reset_requested
signal port_device_changed(port: int, device_id: int)
## Which physical gamepad drives this machine. Handhelds only — everything with a
## controller port takes a PadReceiver plugged into it instead.
signal pad_device_changed(guid: String, ordinal: int)
## System-tab toggle: show/hide the console's video-out cables.
signal video_out_toggled(enabled: bool)
## System-tab toggle: float in place where dropped (no gravity).
signal ignore_gravity_toggled(enabled: bool)
signal close_requested

# ── Palette ────────────────────────────────────────────────────────────────────
const COLOR_BG    := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9,  0.9,  1.0)
const COLOR_ROW   := Color(0.65, 0.65, 0.80)
## Matches MenuIcons.TINT_WARN so the "you can't change this" cue reads the same
## here as it does everywhere else in the menus.
const COLOR_LOCKED := Color(1.00, 0.72, 0.20)

# ── State ──────────────────────────────────────────────────────────────────────
var _options_scroll: ScrollContainer
var _options_rows: VBoxContainer
## Substring the Options tab is filtered by. A core can publish well over a
## hundred keys, and the list is alphabetical by description, so finding one by
## scrolling means knowing what its author called it.
var _options_filter: String = ""
var _options_search: LineEdit = null
var _controllers_scroll: ScrollContainer
var _controllers_rows: VBoxContainer
## Handhelds only — see _add_pad_row.
var _show_pad_picker := false
var _pad_guid := ""
var _pad_ordinal := 0
var _system_scroll: ScrollContainer
var _video_out_row: HBoxContainer = null
var _video_out_check: VRToggle = null
var _ignore_grav_check: VRToggle = null
var _tabs: TabContainer = null
## The slotted cartridge's UI, embedded as a tab. Driven by the cartridge's own
## CartridgeOptionsPanel, which owns all the save/sync/achievement logic.
var _cart_ui: CartridgeOptions2D = null
var _cart_tab_idx: int = -1
var _system_tab_idx := -1
var _active_scroll: ScrollContainer = null
# Guard so populate_system() doesn't re-emit when it sets control values.
var _suppress_signal := false

var _definitions: Dictionary = {}
var _values: Dictionary = {}
## The core this machine will run, for the FRONTEND row. Empty until the first
## populate(), and empty for a system whose core cannot be resolved at all.
var _core_name: String = ""
# Options the system model pins; shown locked rather than hidden, so it is clear
# why they cannot be changed instead of leaving them unexplained absences.
var _forced: Dictionary = {}
# Set when there are no options AND there is a reason worth stating.
var _unavailable: String = ""
# Array of Dictionaries: [{port, controllers: [{name, id}], current_id}]
var _controller_info: Array = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	print("[CoreOptions2D] UI built")


# ── UI construction ────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Rounded panel backdrop — same approach as SpawnMenu2D
	var margin := MenuStyle.panel_root(self, COLOR_BG, 10, 12)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)
	margin.add_child(root_vbox)

	# ── Title row ──────────────────────────────────────────────────────────────
	var title_row := HBoxContainer.new()
	root_vbox.add_child(title_row)

	var title_lbl := Label.new()
	title_lbl.text = "System Settings"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_font_size_override("font_size", 26)
	title_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	title_row.add_child(title_lbl)

	var close_btn := Button.new()
	close_btn.add_theme_font_override("font", MenuIcons.symbols())
	close_btn.text = "  %s  " % String.chr(MenuIcons.CLOSE)
	close_btn.add_theme_font_size_override("font_size", 22)
	close_btn.pressed.connect(func(): close_requested.emit())
	title_row.add_child(close_btn)

	root_vbox.add_child(HSeparator.new())

	# ── Tab container ──────────────────────────────────────────────────────────
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_font_size_override("font_size", 18)
	root_vbox.add_child(tabs)

	# Options tab
	var opts_outer := VBoxContainer.new()
	opts_outer.name = "Options"
	tabs.add_child(opts_outer)

	_options_search = LineEdit.new()
	_options_search.placeholder_text = "Search options"
	_options_search.clear_button_enabled = true
	_options_search.custom_minimum_size = Vector2(0, 44)
	_options_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options_search.add_theme_font_size_override("font_size", 16)
	_options_search.text_changed.connect(_on_options_filter_changed)
	opts_outer.add_child(_options_search)

	_options_scroll = ScrollContainer.new()
	_options_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_options_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_options_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	MenuStyle.fat_vscroll_bar(_options_scroll)
	opts_outer.add_child(_options_scroll)

	_options_rows = VBoxContainer.new()
	_options_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options_rows.add_theme_constant_override("separation", 2)
	_options_scroll.add_child(_options_rows)

	# Controllers tab
	var ctrl_outer := VBoxContainer.new()
	ctrl_outer.name = "Controllers"
	tabs.add_child(ctrl_outer)

	_controllers_scroll = ScrollContainer.new()
	_controllers_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_controllers_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_controllers_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	MenuStyle.fat_vscroll_bar(_controllers_scroll)
	ctrl_outer.add_child(_controllers_scroll)

	_controllers_rows = VBoxContainer.new()
	_controllers_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_controllers_rows.add_theme_constant_override("separation", 4)
	_controllers_scroll.add_child(_controllers_rows)

	# System tab (device-level settings, not core options). The video-out row
	# only shows for handhelds — consoles' cables are always on.
	_tabs = tabs
	var sys_outer := VBoxContainer.new()
	sys_outer.name = "System"
	tabs.add_child(sys_outer)
	_system_tab_idx = tabs.get_tab_count() - 1

	# Cartridge tab — the slotted cartridge's own saves and achievements, so they
	# are reachable without fishing the cartridge back out of the machine. The
	# whole tab is hidden when the slot is empty (see set_cartridge_tab_visible).
	#
	# An embedded CartridgeOptions2D rather than a reimplementation: the save
	# recovery, RomM sync and achievement list are already written there, and
	# CartridgeOptionsPanel drives this copy through adopt_external_ui().
	var cart_outer := VBoxContainer.new()
	cart_outer.name = "Cartridge"
	tabs.add_child(cart_outer)
	_cart_tab_idx = tabs.get_tab_count() - 1

	_cart_ui = CartridgeOptions2D.create_embedded()
	cart_outer.add_child(_cart_ui)

	_system_scroll = ScrollContainer.new()
	_system_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_system_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_system_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	MenuStyle.fat_vscroll_bar(_system_scroll)
	sys_outer.add_child(_system_scroll)

	var sys_rows := VBoxContainer.new()
	sys_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sys_rows.add_theme_constant_override("separation", 4)
	_system_scroll.add_child(sys_rows)

	_video_out_row = HBoxContainer.new()
	_video_out_row.custom_minimum_size = Vector2(0, 56)
	_video_out_row.add_theme_constant_override("separation", 8)
	sys_rows.add_child(_video_out_row)

	var vo_lbl := Label.new()
	vo_lbl.text = "Enable Video Out"
	vo_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vo_lbl.add_theme_font_size_override("font_size", 18)
	vo_lbl.add_theme_color_override("font_color", COLOR_ROW)
	vo_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_video_out_row.add_child(vo_lbl)

	_video_out_check = VRToggle.create(false, func(on: bool):
		if not _suppress_signal:
			video_out_toggled.emit(on))
	_video_out_row.add_child(_video_out_check)

	var grav_row := HBoxContainer.new()
	grav_row.custom_minimum_size = Vector2(0, 56)
	grav_row.add_theme_constant_override("separation", 8)
	sys_rows.add_child(grav_row)

	var grav_lbl := Label.new()
	grav_lbl.text = "Ignore Gravity"
	grav_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grav_lbl.add_theme_font_size_override("font_size", 18)
	grav_lbl.add_theme_color_override("font_color", COLOR_ROW)
	grav_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	grav_row.add_child(grav_lbl)

	_ignore_grav_check = VRToggle.create(false, func(on: bool):
		if not _suppress_signal:
			ignore_gravity_toggled.emit(on))
	grav_row.add_child(_ignore_grav_check)

	# Track which scroll container is active for stick-driven scrolling
	_active_scroll = _options_scroll
	tabs.tab_changed.connect(func(idx: int):
		match idx:
			0: _active_scroll = _options_scroll
			1: _active_scroll = _controllers_scroll
			2: _active_scroll = _system_scroll
			# The Cartridge tab hosts a whole CartridgeOptions2D with ribbons of
			# its own, so it knows which of them is showing and this does not.
			# Clearing the reference is what makes scroll_active hand over.
			# Without this the stick scrolled the System tab while you were
			# looking at the cartridge page.
			_: _active_scroll = null
	)

	_show_options_placeholder()
	_show_controllers_placeholder()


# ── Public API ─────────────────────────────────────────────────────────────────

## Fill or refresh all tabs.
## controller_info: Array of Dicts [{port, controllers:[{name,id}], current_id}]
func populate(definitions: Dictionary, current_values: Dictionary, controller_info: Array,
		forced: Dictionary = {}, unavailable: String = "", core_name: String = "") -> void:
	_definitions = definitions
	_values = current_values
	_controller_info = controller_info
	_forced = forced
	_unavailable = unavailable
	_core_name = core_name
	print("[CoreOptions2D] populate() — %d options, %d ports" % [definitions.size(), controller_info.size()])
	_refresh_options()
	_refresh_controllers()


## Sync the System tab to the device's current state (no signal re-emit).
## `show_video_out` false (consoles) hides just that row — their cable is
## always on; the tab stays for the other device toggles.
## The embedded cartridge UI, for CartridgeOptionsPanel.adopt_external_ui().
func cartridge_ui() -> CartridgeOptions2D:
	return _cart_ui


## Show the Cartridge tab only while something is in the slot. Hidden rather
## than removed so the index stays put and the UI never has to be rebuilt.
func set_cartridge_tab_visible(shown: bool) -> void:
	if _tabs == null or _cart_tab_idx < 0:
		return
	_tabs.set_tab_hidden(_cart_tab_idx, not shown)


## The pad picker rides `show_video_out`: both are "this machine is a handheld".
func populate_system(video_out: bool, show_video_out: bool, ignore_grav: bool,
		pad_guid: String = "", pad_ordinal: int = 0) -> void:
	_suppress_signal = true
	var picker_changed := _show_pad_picker != show_video_out 		or _pad_guid != pad_guid or _pad_ordinal != pad_ordinal
	_show_pad_picker = show_video_out
	_pad_guid = pad_guid
	_pad_ordinal = pad_ordinal
	if picker_changed and _controllers_rows != null:
		_refresh_controllers()
	if _video_out_row:
		_video_out_row.visible = show_video_out
	if _video_out_check:
		_video_out_check.button_pressed = video_out
	if _ignore_grav_check:
		_ignore_grav_check.button_pressed = ignore_grav
	_suppress_signal = false


## Drive the active scroll container from an external stick input (pixels > 0 = down).
func scroll_active(pixels: float) -> void:
	if _active_scroll:
		_active_scroll.scroll_vertical += int(pixels)
	elif _cart_ui != null and is_instance_valid(_cart_ui):
		# The Cartridge tab: its own ribbon strip decides which list scrolls.
		_cart_ui.scroll_active(pixels)


# ── Options tab ────────────────────────────────────────────────────────────────

## Appended, never clearing: the FRONTEND row above it is a setting in its own
## right and outlives "this core has published nothing yet".
func _show_options_placeholder() -> void:
	var lbl := Label.new()
	lbl.text = _unavailable if not _unavailable.is_empty() \
		else "No options available.\n(Start emulation first.)"
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", COLOR_ROW)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(0, 80)
	_options_rows.add_child(lbl)


## Typing filters the list, so both this and the FRONTEND/reset rows above it
## are dropped while a filter is set: they are not core options and would sit
## between the box and whatever the search actually found.
func _on_options_filter_changed(text: String) -> void:
	_options_filter = text.strip_edges()
	_refresh_options()


## Matched against the key as well as the shown description: a core's own
## documentation and its forum threads name the key, not the label.
func _matches_filter(key: String, defn) -> bool:
	if _options_filter.is_empty():
		return true
	var needle := _options_filter.to_lower()
	if key.to_lower().contains(needle):
		return true
	return _option_desc(key, defn).to_lower().contains(needle)


## The description the row shows, falling back the same way the row itself does.
func _option_desc(key: String, defn) -> String:
	var desc: String = defn.GetDescriptionCategorized()
	if desc.is_empty():
		desc = defn.GetDescription()
	if desc.is_empty():
		desc = key
	return desc


func _refresh_options() -> void:
	for c in _options_rows.get_children():
		c.queue_free()

	var filtering := not _options_filter.is_empty()
	if not filtering:
		_add_frontend_row()

	if _definitions.is_empty():
		_show_options_placeholder()
		return

	if not filtering:
		_add_reset_row()

	var keys: Array = _definitions.keys()
	keys.sort()
	var shown := 0
	for key in keys:
		if not _matches_filter(key, _definitions[key]):
			continue
		_add_option_row(key, _definitions[key], String(_values.get(key, "")))
		shown += 1

	if shown == 0:
		var none := Label.new()
		none.text = "No option matches \"%s\"." % _options_filter
		none.add_theme_font_size_override("font_size", 16)
		none.add_theme_color_override("font_color", COLOR_ROW)
		none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		none.custom_minimum_size = Vector2(0, 60)
		_options_rows.add_child(none)

	print("[CoreOptions2D] %d of %d option rows built" % [shown, keys.size()])


## Which API this core is told the frontend would rather render with — the same
## setting as CORES > Manager > (core) > FRONTEND in the spawn menu, reachable
## from the machine as well.
##
## Above the core's own options and outside the reset, because it is not one of
## them: every row below is a key the core publishes about itself and is written
## to that core's option file, while this is our answer to
## GET_PREFERRED_HW_RENDER, kept per core in AppPrefs. Built whether or not the
## core has published anything, since a machine that has never been switched on
## is exactly when this gets set.
func _add_frontend_row() -> void:
	if _core_name.is_empty():
		return

	var head := Label.new()
	head.text = "FRONTEND"
	head.add_theme_font_size_override("font_size", 15)
	head.add_theme_color_override("font_color", COLOR_TITLE)
	_options_rows.add_child(head)

	# "" is no override — the entry names the global, so the row says what this
	# core will actually get rather than merely that it is following something.
	var default_label := "Default"
	var options: Array = []
	for choice: Array in AppPrefs.hw_render_choices():
		if str(choice[1]) == AppPrefs.DEFAULT_HW_RENDER:
			default_label = "Default (%s)" % str(choice[0])
		options.append([str(choice[0]), str(choice[1])])
	options.push_front([default_label, ""])

	# VRDropdown, never OptionButton — every Viewport2Din3D click fires twice.
	var drop := VRDropdown.create("Preferred HW Render", options,
		AppPrefs.hw_render_override(_core_name), 1, Vector2(300, 48), 16)
	drop.item_selected.connect(func(id: Variant) -> void:
		print("[CoreOptions2D] hw render for '%s' → '%s'" % [_core_name, str(id)])
		AppPrefs.set_hw_render_override(_core_name, str(id))
	)
	_options_rows.add_child(drop)

	# One line: this page is 600x500 and the core's own options are what it is
	# for. The full explanation lives on the spawn menu's copy of this row.
	var note := Label.new()
	note.text = "Applied as the core starts."
	note.add_theme_font_size_override("font_size", 12)
	note.add_theme_color_override("font_color", COLOR_ROW)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_options_rows.add_child(note)

	_options_rows.add_child(HSeparator.new())


## Sits above the list rather than at the bottom: it acts on everything below it,
## and a list this long would otherwise bury it past the scroll.
func _add_reset_row() -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 52)
	row.add_theme_constant_override("separation", 4)
	_options_rows.add_child(row)

	var label := Label.new()
	label.text = "Restore this core's defaults"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", COLOR_TITLE)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	row.add_child(label)

	var btn := Button.new()
	btn.text = "Reset all"
	btn.custom_minimum_size = Vector2(120, 44)
	btn.add_theme_font_size_override("font_size", 14)
	btn.pressed.connect(func() -> void: options_reset_requested.emit())
	row.add_child(btn)

	_options_rows.add_child(HSeparator.new())


## Build a single option row: [description label] [<] [current value] [>]
## defn is a LibretroOptionDefinition (untyped to allow dynamic ClassDB dispatch).
func _add_option_row(key: String, defn, current_val: String) -> void:
	# A pinned option shows what the SYSTEM enforces, not what happens to be
	# sitting in the .opt. The stored value can be stale — a core that renamed
	# its values leaves one that matches nothing, and the index search below
	# then falls back to entry 0, so the row would advertise a setting the
	# system is actively overriding.
	if _forced.has(key):
		current_val = str(_forced[key])

	var desc := _option_desc(key, defn)

	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 52)
	row.add_theme_constant_override("separation", 4)
	_options_rows.add_child(row)

	var label := Label.new()
	label.text = desc
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", COLOR_ROW)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	row.add_child(label)

	# values_arr elements are LibretroOptionValue objects (RefCounted from C++).
	# Kept untyped so GDScript uses dynamic ClassDB dispatch for GetValue/GetLabel.
	var values_arr: Array = defn.GetValues()
	if values_arr.is_empty():
		return

	var cur_idx := 0
	for i in range(values_arr.size()):
		if values_arr[i].GetValue() == current_val:
			cur_idx = i
			break

	# A pinned option shows its value but no way to move it, and says so. The
	# hardware depends on it (the 3DS's side-by-side framebuffer, the Virtual Boy's
	# stereo split), so an editable control here would only offer a broken screen.
	# Its own Label rather than appended to the description: the note is the part
	# that needs to stand out, and a single Label can only carry one colour.
	var is_forced := _forced.has(key)
	if is_forced:
		var note := Label.new()
		note.text = "(fixed by this system)"
		note.add_theme_font_size_override("font_size", 13)
		note.add_theme_color_override("font_color", COLOR_LOCKED)
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(note)

	var prev_btn := Button.new()
	prev_btn.text = " < "
	prev_btn.custom_minimum_size = Vector2(48, 48)
	prev_btn.disabled = is_forced
	row.add_child(prev_btn)

	var val_lbl := Label.new()
	val_lbl.custom_minimum_size = Vector2(140, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val_lbl.add_theme_font_size_override("font_size", 13)
	val_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	val_lbl.clip_text = true
	var initial_v = values_arr[cur_idx]
	val_lbl.text = _value_label(initial_v)
	row.add_child(val_lbl)

	var next_btn := Button.new()
	next_btn.text = " > "
	next_btn.custom_minimum_size = Vector2(48, 48)
	next_btn.disabled = is_forced
	row.add_child(next_btn)

	var idx_ref := [cur_idx]
	prev_btn.pressed.connect(func():
		idx_ref[0] = (idx_ref[0] - 1 + values_arr.size()) % values_arr.size()
		var v = values_arr[idx_ref[0]]
		val_lbl.text = _value_label(v)
		var new_val: String = v.GetValue()
		print("[CoreOptions2D] '%s' → '%s' (prev)" % [key, new_val])
		option_changed.emit(key, new_val)
	)
	next_btn.pressed.connect(func():
		idx_ref[0] = (idx_ref[0] + 1) % values_arr.size()
		var v = values_arr[idx_ref[0]]
		val_lbl.text = _value_label(v)
		var new_val: String = v.GetValue()
		print("[CoreOptions2D] '%s' → '%s' (next)" % [key, new_val])
		option_changed.emit(key, new_val)
	)


## Return a LibretroOptionValue's display label, falling back to the raw value.
## Parameter intentionally untyped — see _add_option_row note.
func _value_label(v) -> String:
	var lbl: String = v.GetLabel()
	return lbl if not lbl.is_empty() else v.GetValue()


# ── Controllers tab ────────────────────────────────────────────────────────────

func _show_controllers_placeholder() -> void:
	for c in _controllers_rows.get_children():
		c.queue_free()
	var lbl := Label.new()
	lbl.text = "No controller info available.\n(Start emulation first.)"
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", COLOR_ROW)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(0, 80)
	_controllers_rows.add_child(lbl)


func _refresh_controllers() -> void:
	for c in _controllers_rows.get_children():
		c.queue_free()

	# Before the placeholder, not after: a handheld has no port rows at all, and
	# the pad picker is the only controller setting it has.
	if _show_pad_picker:
		_add_pad_row()

	if _controller_info.is_empty():
		if not _show_pad_picker:
			_show_controllers_placeholder()
		return

	for entry in _controller_info:
		_add_controller_row(entry)

	print("[CoreOptions2D] %d controller port rows built" % _controller_info.size())


## Build one row per port: [Port N] [inline dropdown of device types].
## Uses VRDropdown rather than OptionButton — an OptionButton's PopupMenu is a
## Window, and the VR viewport's duplicated press dismisses it on the same click
## it opens on (see vr_dropdown.gd).
func _add_controller_row(entry: Dictionary) -> void:
	var port: int = entry["port"]
	var controllers: Array = entry["controllers"]
	var current_id: int = entry["current_id"]

	if controllers.is_empty():
		return

	var options: Array = []
	for ctrl: Dictionary in controllers:
		options.append([str(ctrl["name"]), int(ctrl["id"])])

	var drop := VRDropdown.create("Port %d" % (port + 1), options, current_id,
		1, Vector2(300, 48), 16)
	drop.set_placeholder("(device %d)" % current_id)
	drop.item_selected.connect(func(device_id: Variant) -> void:
		print("[CoreOptions2D] port %d → device %d" % [port, int(device_id)])
		port_device_changed.emit(port, int(device_id))
	)

	_controllers_rows.add_child(drop)
	_controllers_rows.add_child(HSeparator.new())


## Which real gamepad drives this handheld.
##
## A handheld IS its own controller — system.gd gives it no external port zones —
## so there is nothing to plug a PadReceiver into and the pad has to be named
## here instead. Everything with a port does it the other way round, by plugging
## a receiver in, which is why this row appears on nothing else.
func _add_pad_row() -> void:
	var options: Array = [["None", ""]]
	var current := ""
	for device: int in GamepadBindings.usable_pads():
		var id := GamepadBindings.identify_device(device)
		var value := "%s:%d" % [str(id["guid"]), int(id["ordinal"])]
		options.append([str(id["name"]), value])
		if str(id["guid"]) == _pad_guid and int(id["ordinal"]) == _pad_ordinal:
			current = value

	var drop := VRDropdown.create("Physical Controller", options, current,
		1, Vector2(300, 48), 16)
	drop.item_selected.connect(func(value: Variant) -> void:
		var parts := str(value).split(":")
		var guid := parts[0] if parts.size() > 0 else ""
		var ordinal := int(parts[1]) if parts.size() > 1 else 0
		_pad_guid = guid
		_pad_ordinal = ordinal
		pad_device_changed.emit(guid, ordinal)
	)
	_controllers_rows.add_child(drop)
	_controllers_rows.add_child(HSeparator.new())

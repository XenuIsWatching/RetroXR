## TVOptions2D — 2D UI for a TV's settings.
## Loaded into TVOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring BookOptions2D.
##
## Emits:
##   scale_changed(scale)   — size slider moved (fires live while dragging)
##   scale_committed(scale) — size slider drag finished (for net replication)
##   close_requested        — user pressed ✕
class_name TVOptions2D
extends Control

signal scale_changed(scale: float)
signal scale_committed(scale: float)
## Float-in-place toggled.
signal ignore_gravity_toggled(enabled: bool)
## A CRT display-stage uniform was changed (pname, value). Applied live.
signal crt_param_changed(pname, value)
signal close_requested
## A row in the channel list was clicked.
signal channel_selected(index: int)
## The tuner's auto/address settings were edited; write them to channels.json.
signal tuner_settings_changed(auto: bool, host: String)
## Refresh pressed — re-read channels.json and go looking for the tuner again.
signal channels_refresh_requested

# ── Palette (matches BookOptions2D / CoreOptions2D) ──────────────────────────────
const COLOR_BG    := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9,  0.9,  1.0)
const COLOR_ROW   := Color(0.65, 0.65, 0.80)

const MIN_SCALE := 0.2
const MAX_SCALE := 5.0

var _size_slider: HSlider = null
var _size_val: Label = null
var _float_check: VRToggle = null
var _options_scroll: ScrollContainer = null
var _crt_scroll: ScrollContainer = null
var _active_scroll: ScrollContainer = null
# CRT controls, keyed by shader uniform name → {slider, val_label, fmt}.
var _crt_sliders: Dictionary = {}
var _crt_mask_opt: VRDropdown = null
# Guard so populate() doesn't re-emit signals when it sets control values.
var _suppress_signal := false

# Channels tab.
var _channels_scroll: ScrollContainer = null
var _channel_list: VirtualRowList = null
var _auto_toggle: VRCheck = null
var _host_edit: LineEdit = null
var _tuner_status: Label = null
var _channels: Array[Dictionary] = []
var _current_channel := -1
# The address discovered by the tuner, shown greyed while auto is on so the box
# always says where it is even when nobody typed it.
var _discovered_host := ""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _build_ui() -> void:
	var margin := MenuStyle.panel_root(self, COLOR_BG, 10, 12)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)
	margin.add_child(root_vbox)

	MenuStyle.close_button(MenuStyle.title_row(root_vbox, "TV Settings"),
		func() -> void: close_requested.emit())

	root_vbox.add_child(HSeparator.new())

	# ── Tab container (mirrors VCROptions2D): Options | CRT ────────────────────
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_font_size_override("font_size", 18)
	root_vbox.add_child(tabs)

	var opts_outer := VBoxContainer.new()
	opts_outer.name = "Options"
	tabs.add_child(opts_outer)

	_options_scroll = ScrollContainer.new()
	_options_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_options_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_options_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	MenuStyle.fat_vscroll_bar(_options_scroll)
	opts_outer.add_child(_options_scroll)
	_active_scroll = _options_scroll

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 4)
	_options_scroll.add_child(rows)

	# Size slider row: [label + value] then a full-width slider under it.
	var size_header := HBoxContainer.new()
	size_header.add_theme_constant_override("separation", 8)
	rows.add_child(size_header)

	var size_lbl := Label.new()
	size_lbl.text = "TV size"
	size_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_lbl.add_theme_font_size_override("font_size", 18)
	size_lbl.add_theme_color_override("font_color", COLOR_ROW)
	size_header.add_child(size_lbl)

	_size_val = Label.new()
	_size_val.text = "1.0×"
	_size_val.add_theme_font_size_override("font_size", 18)
	_size_val.add_theme_color_override("font_color", COLOR_TITLE)
	_size_val.custom_minimum_size = Vector2(70, 0)
	_size_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	size_header.add_child(_size_val)

	_size_slider = HSlider.new()
	_size_slider.min_value = MIN_SCALE
	_size_slider.max_value = MAX_SCALE
	_size_slider.step = 0.1
	_size_slider.value = 1.0
	_size_slider.custom_minimum_size = Vector2(0, 48)
	_size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_child(_size_slider)

	# value_changed fires continuously while dragging → live resize; the
	# commit signal on drag end is what gets replicated to other players.
	_size_slider.value_changed.connect(func(v: float):
		_size_val.text = "%.1f×" % v
		if not _suppress_signal:
			scale_changed.emit(v)
	)
	_size_slider.drag_ended.connect(func(value_changed_flag: bool):
		if not _suppress_signal and value_changed_flag:
			scale_committed.emit(_size_slider.value)
	)

	_float_check = MenuStyle.float_toggle(rows)
	_float_check.toggled.connect(func(on: bool):
		if not _suppress_signal:
			ignore_gravity_toggled.emit(on)
	)

	_build_channels_tab(tabs)
	_build_crt_tab(tabs)

	# Stick-scroll drives whichever tab is visible.
	tabs.tab_changed.connect(_on_tab_changed)


## A named method, not a lambda: a multi-line `match` inside one does not parse.
func _on_tab_changed(idx: int) -> void:
	match idx:
		0:
			_active_scroll = _options_scroll
		1:
			_active_scroll = _channels_scroll
		_:
			_active_scroll = _crt_scroll


# ── Channels (the built-in tuner) ─────────────────────────────────────────────

## Tuner settings on top, channel list below. The list is virtualised because a
## broadcast lineup runs to 80-odd rows and building that many real Controls in a
## Viewport2DIn3D is not free.
func _build_channels_tab(tabs: TabContainer) -> void:
	var outer := VBoxContainer.new()
	outer.name = "Channels"
	outer.add_theme_constant_override("separation", 6)
	tabs.add_child(outer)

	# --- tuner box ---
	var tuner_box := VBoxContainer.new()
	tuner_box.add_theme_constant_override("separation", 4)
	outer.add_child(tuner_box)

	# No "TUNER" header: the tab is already called Channels and the controls say
	# what they are. Vertical space here comes straight out of the channel list,
	# which is the thing with 80-odd rows to show.
	# Caption on the left, box on the right — the shape the book and VCR panels
	# already use, and the reason VRCheck carries no text of its own.
	var auto_row := HBoxContainer.new()
	auto_row.add_theme_constant_override("separation", 8)
	auto_row.custom_minimum_size = Vector2(0, 52)
	tuner_box.add_child(auto_row)

	var auto_lbl := Label.new()
	auto_lbl.text = "Find tuner automatically"
	auto_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	auto_lbl.add_theme_font_size_override("font_size", 18)
	auto_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	auto_row.add_child(auto_lbl)

	_auto_toggle = VRCheck.create(true, _on_auto_toggled)
	auto_row.add_child(_auto_toggle)

	var addr_row := HBoxContainer.new()
	addr_row.add_theme_constant_override("separation", 8)
	tuner_box.add_child(addr_row)

	var addr_lbl := Label.new()
	addr_lbl.text = "Address"
	addr_lbl.add_theme_font_size_override("font_size", 18)
	addr_lbl.add_theme_color_override("font_color", COLOR_ROW)
	addr_lbl.custom_minimum_size = Vector2(90, 0)
	addr_row.add_child(addr_lbl)

	_host_edit = LineEdit.new()
	_host_edit.placeholder_text = "192.168.0.100"
	_host_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host_edit.custom_minimum_size = Vector2(0, 38)
	_host_edit.add_theme_font_size_override("font_size", 18)
	_host_edit.text_submitted.connect(func(_t: String) -> void: _commit_tuner())
	_host_edit.focus_exited.connect(_commit_tuner)
	addr_row.add_child(_host_edit)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.add_theme_font_size_override("font_size", 18)
	refresh_btn.custom_minimum_size = Vector2(105, 38)
	refresh_btn.focus_mode = Control.FOCUS_NONE
	refresh_btn.pressed.connect(_on_refresh)
	addr_row.add_child(refresh_btn)

	_tuner_status = Label.new()
	_tuner_status.text = "—"
	_tuner_status.add_theme_font_size_override("font_size", 15)
	_tuner_status.add_theme_color_override("font_color", COLOR_ROW)
	_tuner_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tuner_box.add_child(_tuner_status)

	outer.add_child(HSeparator.new())

	# --- channel list ---
	_channels_scroll = ScrollContainer.new()
	_channels_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_channels_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_channels_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	MenuStyle.fat_vscroll_bar(_channels_scroll)
	outer.add_child(_channels_scroll)

	_channel_list = VirtualRowList.new()
	_channel_list.row_height = 46
	_channel_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_channel_list.set_row_builder(_build_channel_row)
	_channel_list.set_row_binder(_bind_channel_row)
	_channels_scroll.add_child(_channel_list)


func _build_channel_row() -> Control:
	var btn := Button.new()
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_font_size_override("font_size", 18)
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(0, 44)
	return btn


func _bind_channel_row(row: Control, index: int) -> void:
	var btn := row as Button
	if index < 0 or index >= _channels.size():
		btn.text = ""
		btn.disabled = true
		return
	var ch: Dictionary = _channels[index]
	var number := str(ch.get("number", ""))
	var label := str(ch.get("name", ""))
	var hd := "  HD" if bool(ch.get("hd", false)) else ""
	btn.disabled = false
	btn.text = "  %s  %s%s" % [number.rpad(6), label, hd]
	btn.add_theme_color_override("font_color",
		COLOR_TITLE if index == _current_channel else COLOR_ROW)
	# Rebound on every scroll, so the old row's connection has to go first or the
	# button ends up tuning several different channels at once.
	for c in btn.pressed.get_connections():
		btn.pressed.disconnect(c["callable"])
	btn.pressed.connect(func() -> void: channel_selected.emit(index))


# ── CRT filter controls (own tab, like the VCR panel's VHS tab) ───────────────

func _build_crt_tab(tabs: TabContainer) -> void:
	var outer := VBoxContainer.new()
	outer.name = "CRT"
	tabs.add_child(outer)

	_crt_scroll = ScrollContainer.new()
	_crt_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_crt_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_crt_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	MenuStyle.fat_vscroll_bar(_crt_scroll)
	outer.add_child(_crt_scroll)

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 4)
	_crt_scroll.add_child(rows)

	# Mask mode dropdown. VRDropdown, not OptionButton — see vr_dropdown.gd for
	# why PopupMenu can't be clicked in a VR panel.
	_crt_mask_opt = VRDropdown.create("RGB mask",
		[["Off", 0], ["Grille", 1], ["Slot", 2], ["Shadow", 3]], 1)
	_crt_mask_opt.item_selected.connect(func(id: Variant) -> void:
		if not _suppress_signal:
			crt_param_changed.emit("crt_mask_mode", int(id))
	)
	rows.add_child(_crt_mask_opt)

	# Sliders: [uniform, label, min, max, step, value-format].
	#
	# "Phosphor pitch" is in millimetres on the glass, not pixels: the mask is
	# locked to the tube, so the triad count follows from the pitch and the TV's
	# world size. Measured on a 0.35 m tube at Quest 3 density, triads start
	# resolving at ~2.5 px and are solid by ~4 px, which puts the default 2.0 mm
	# at "visible from 0.8 m, obvious by 0.5 m". 0.6 mm is a physically real
	# arcade tube and stays invisible until you are almost touching the glass.
	var specs := [
		["crt_mask_strength",     "Mask strength",    0.0, 1.0,  0.05, "%.2f"],
		["crt_mask_pitch_mm",     "Phosphor pitch",   0.4, 3.0,  0.1,  "%.1f mm"],
		["crt_scanline_strength", "Scanlines",        0.0, 1.0,  0.05, "%.2f"],
		["crt_beam_min",          "Beam (dark)",      0.05, 0.5, 0.01, "%.2f"],
		["crt_beam_max",          "Beam (bright)",    0.05, 0.8, 0.01, "%.2f"],
		["crt_gamma",             "Tube gamma",       0.8, 1.4,  0.01, "%.2f"],
		["crt_halation",          "Halation",         0.0, 0.5,  0.01, "%.2f"],
		["crt_persistence",       "Persistence",      0.0, 0.6,  0.05, "%.2f"],
		["crt_notch",             "Composite blend",  0.0, 1.0,  0.05, "%.2f"],
		["crt_curvature",         "Extra curvature",  0.0, 0.3,  0.01, "%.2f"],
		["crt_grain",             "Grain",            0.0, 1.0,  0.02, "%.2f"],
		["crt_smear",             "Smear",            0.0, 1.0,  0.05, "%.2f"],
		["crt_wiggle",            "Wiggle",           0.0, 0.2,  0.02, "%.2f"],
		["crt_vignette",          "Vignette",         0.0, 1.0,  0.05, "%.2f"],
		["crt_brightness",        "Brightness",       0.5, 2.0,  0.05, "%.2f"],
		["crt_glass_reflection",  "Glass reflection",  0.0, 1.0,  0.05, "%.2f"],
		["crt_glass_roughness",   "Glass roughness",   0.02, 0.6, 0.02, "%.2f"],
		["crt_glass_wear",        "Glass wear",        0.0, 3.0,  0.05, "%.2f×"],
		["crt_character",         "CRT character",     0.0, 1.0,  0.05, "%.2f"],
	]
	for s: Array in specs:
		_add_crt_slider(rows, s[0], s[1], s[2], s[3], s[4], s[5])


func _add_crt_slider(rows: VBoxContainer, key: String, label: String,
		minv: float, maxv: float, step: float, fmt: String) -> void:
	var built := MenuStyle.slider_row(rows, label, minv, maxv, step, 70)
	var slider := built[0] as HSlider
	var val_lbl := built[1] as Label
	slider.value_changed.connect(func(v: float):
		val_lbl.text = fmt % v
		if not _suppress_signal:
			crt_param_changed.emit(key, v)
	)
	_crt_sliders[key] = {"slider": slider, "val": val_lbl, "fmt": fmt}


# ── Public API ─────────────────────────────────────────────────────────────────

## Sync the UI to the TV's current state without re-emitting signals.
func populate(scale_factor := 1.0, ignore_gravity := false) -> void:
	_suppress_signal = true
	if _size_slider:
		_size_slider.value = scale_factor
		_size_val.text = "%.1f×" % scale_factor
	if _float_check:
		_float_check.button_pressed = ignore_gravity
	_suppress_signal = false


## Sync the CRT controls to the TV's current uniform values (no signal re-emit).
func populate_crt(params: Dictionary) -> void:
	_suppress_signal = true
	if _crt_mask_opt and params.has("crt_mask_mode"):
		_crt_mask_opt.select_id(int(params["crt_mask_mode"]))
	for key: String in _crt_sliders:
		if not params.has(key):
			continue
		var entry: Dictionary = _crt_sliders[key]
		var v := float(params[key])
		(entry["slider"] as HSlider).value = v
		(entry["val"] as Label).text = str(entry["fmt"]) % v
	_suppress_signal = false


## Drive the active scroll container from an external stick input.
func scroll_active(pixels: float) -> void:
	if _active_scroll:
		_active_scroll.scroll_vertical += int(pixels)


# ── Channels tab: driven by TVOptionsPanel from the tuner ─────────────────────

## Refresh the list and which row is lit.
func populate_channels(channels: Array, current: int) -> void:
	_channels.clear()
	for c: Variant in channels:
		if c is Dictionary:
			_channels.append(c as Dictionary)
	_current_channel = current
	if _channel_list:
		_channel_list.set_row_count(_channels.size())
		_channel_list.rebind_visible()


## Sync the tuner controls. `status` is already-worded text for the status line.
func populate_tuner(auto: bool, host: String, discovered: String, status: String) -> void:
	_suppress_signal = true
	_discovered_host = discovered
	if _auto_toggle:
		_auto_toggle.button_pressed = auto
	if _host_edit:
		# While auto is on the field shows what discovery found, greyed: the
		# address stays visible even when nobody typed it, and switching to manual
		# starts from something that works rather than an empty box.
		_host_edit.editable = not auto
		_host_edit.text = discovered if auto else host
		_host_edit.modulate = Color(1, 1, 1, 0.55 if auto else 1.0)
	if _tuner_status:
		_tuner_status.text = status
	_suppress_signal = false


func _on_auto_toggled(pressed: bool) -> void:
	if _suppress_signal:
		return
	if _host_edit:
		_host_edit.editable = not pressed
		_host_edit.modulate = Color(1, 1, 1, 0.55 if pressed else 1.0)
		if pressed and not _discovered_host.is_empty():
			_host_edit.text = _discovered_host
	_commit_tuner()


func _commit_tuner() -> void:
	if _suppress_signal or _auto_toggle == null or _host_edit == null:
		return
	tuner_settings_changed.emit(_auto_toggle.button_pressed, _host_edit.text.strip_edges())


func _on_refresh() -> void:
	channels_refresh_requested.emit()

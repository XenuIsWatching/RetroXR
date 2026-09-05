## VRDropdown — a label + inline expanding option list, for use inside the
## XRToolsViewport2DIn3D panels.
##
## Why this exists instead of OptionButton — two separate hazards, both caused
## by viewport_2d_in_3d_body.gd pushing BOTH an InputEventScreenTouch AND an
## InputEventMouseButton for the same pointer press, so one VR click arrived as
## TWO presses:
##
##  1. OptionButton opens a PopupMenu — a separate embedded Window. The first
##     press opens it; the second lands outside the popup's rect and reads as
##     click-away, dismissing it on the same click. It never appears.
##  2. ACTION_MODE_BUTTON_PRESS makes a Button fire `pressed` TWICE per click
##     (measured), so any toggle built that way opens and closes instantly.
##
## The duplicate itself is fixed now — the body sends the mouse pointer mouse
## events only — but everything below stays. The addon is vendored, so an update
## can silently take the fix away, and hazard 1 is a reason to keep the list
## inline regardless of how many presses arrive.
##
## So this control keeps the list inline (an ordinary PanelContainer in the
## Control tree — no Window), leaves every button on the default
## ACTION_MODE_BUTTON_RELEASE, and drops any second activation that lands in the
## SAME process frame. A user cannot physically click twice in one frame, so the
## guard costs nothing now that it never fires. Do NOT set
## ACTION_MODE_BUTTON_PRESS on these buttons.
##
## Usage:
##   var d := VRDropdown.create("Port 1", [["Gamepad", 1], ["Zapper", 258]], 1)
##   d.item_selected.connect(func(id: Variant) -> void: ...)
##   row.add_child(d)
class_name VRDropdown
extends VBoxContainer

## Emitted only on real user selection, never from set_options()/select_id().
signal item_selected(id: Variant)

const COLOR_TITLE := Color(0.9, 0.9, 1.0)

## Only one dropdown may be expanded at a time, across every panel.
static var _open_dropdown: VRDropdown = null

var _label: Label
var _icon: TextureRect = null
var _toggle: Button
## Open the list as a quad in front of the host panel. Falls back to the
## in-panel list wherever there is no Viewport2Din3D to pop out of.
var popout_3d := true
## The panel's own visibility no longer tracks this: a popout leaves it hidden.
var _is_open := false
var _popout: DropdownPanel = null
## Overlay the option list instead of growing this control. Set before use.
var float_panel := false
## With float_panel on, a value > 0 makes the list open upward rather than
## cross this global Y. Lets a fixed-height host keep the list in its band.
var float_max_bottom := 0.0
var _panel_home: Node = null
var _floated_to: Control = null

var _panel: PanelContainer
var _list: GridContainer
var _opt_btns: Array[Button] = []
var _ids: Array = []
var _options: Array = []
var _current_id: Variant = null
var _grid_cols := 1
var _font_size := 18
var _placeholder := ""
var _toggle_glyph := 0
# Frame of the last accepted activation, to swallow the duplicate press that
# xr-tools delivers in the same frame.
var _last_activate_frame := -1


## options: Array of [display_name: String, id: Variant] — with an optional
## third element, a Texture2D glyph shown on that option and on the toggle when
## it is the current value. Entries without one behave exactly as before.
static func create(
		label_text: String,
		options: Array,
		current_id: Variant,
		grid_cols: int = 1,
		toggle_min_size: Vector2 = Vector2(220, 52),
		font_size: int = 18) -> VRDropdown:
	var d := VRDropdown.new()
	d._grid_cols = maxi(1, grid_cols)
	d._font_size = font_size
	d._build(label_text, toggle_min_size)
	d.set_options(options, current_id)
	return d


func _build(label_text: String, toggle_min_size: Vector2) -> void:
	add_theme_constant_override("separation", 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 56)
	add_child(row)

	_label = Label.new()
	_label.text = label_text
	_label.add_theme_font_size_override("font_size", _font_size)
	_label.add_theme_color_override("font_color", COLOR_TITLE)
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_label)

	_toggle = Button.new()
	# The open/closed chevron is a Nerd Font glyph, so the toggle carries the
	# symbol font whether or not a caller sets a leading glyph of its own.
	_toggle.add_theme_font_override("font", MenuIcons.symbols())
	_toggle.custom_minimum_size = toggle_min_size
	_toggle.add_theme_font_size_override("font_size", _font_size)
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.pressed.connect(_on_toggle_pressed)
	row.add_child(_toggle)

	_panel = PanelContainer.new()
	_panel.visible = false
	var ps := StyleBoxFlat.new()
	ps.bg_color = Color(0.10, 0.10, 0.22, 0.97)
	ps.border_color = Color(0.35, 0.35, 0.65)
	for side in ["border_width_left", "border_width_right",
			"border_width_top", "border_width_bottom"]:
		ps.set(side, 2)
	for corner in ["corner_radius_top_left", "corner_radius_top_right",
			"corner_radius_bottom_left", "corner_radius_bottom_right"]:
		ps.set(corner, 6)
	_panel.add_theme_stylebox_override("panel", ps)
	add_child(_panel)

	_list = GridContainer.new()
	_list.columns = _grid_cols
	_list.add_theme_constant_override("h_separation", 4)
	_list.add_theme_constant_override("v_separation", 2)
	_panel.add_child(_list)


# ── Public API ─────────────────────────────────────────────────────────────────

## Rebuild the option list. Does not emit item_selected.
func set_options(options: Array, current_id: Variant) -> void:
	_options = options
	_current_id = current_id
	_ids.clear()
	_opt_btns.clear()
	for c in _list.get_children():
		c.queue_free()
		_list.remove_child(c)

	for entry: Array in _options:
		var opt_label := entry[0] as String
		var opt_id: Variant = entry[1]
		_ids.append(opt_id)

		var btn := Button.new()
		btn.add_theme_font_override("font", MenuIcons.symbols())
		btn.text = _tick(opt_id) + opt_label
		var glyph := _icon_for(entry)
		if glyph:
			btn.icon = glyph
			# icon_max_width, not expand_icon: expand_icon fights the label for
			# space, so glyphs came out at wildly different sizes across a grid
			# of varying text widths. This caps width and keeps aspect.
			btn.add_theme_constant_override("icon_max_width", 26 if _grid_cols > 1 else 32)
		btn.custom_minimum_size = Vector2(0, 40 if _grid_cols > 1 else 48)
		btn.add_theme_font_size_override("font_size", 16 if _grid_cols > 1 else _font_size)
		btn.focus_mode = Control.FOCUS_NONE
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var captured: Variant = opt_id
		btn.pressed.connect(func() -> void: _on_item_pressed(captured))
		_list.add_child(btn)
		_opt_btns.append(btn)

	_refresh_labels()
	close()


## Select by id without emitting item_selected (for populate()-style calls).
func select_id(current_id: Variant) -> void:
	_current_id = current_id
	_refresh_labels()


func get_selected_id() -> Variant:
	return _current_id


## Shown on the toggle when no option matches the current id.
func set_placeholder(text: String) -> void:
	_placeholder = text
	_refresh_labels()


func set_label(text: String) -> void:
	_label.text = text


## Put a font glyph on the toggle itself and drop the separate label, so the
## control reads as one unit. `font` must resolve both the glyph and ordinary
## text — a FontVariation with the symbols font as a fallback does.
func set_toggle_glyph(codepoint: int, font: Font) -> void:
	_toggle_glyph = codepoint
	_toggle.add_theme_font_override("font", font)
	_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_label.visible = false
	_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_refresh_toggle_arrow()


## Show a glyph to the left of the label, e.g. a Kenney input prompt. Pass null
## to remove it. Optional — a dropdown without one is unchanged.
func set_icon(tex: Texture2D, px: float = 40.0) -> void:
	if tex == null:
		if _icon:
			_icon.queue_free()
			_icon = null
		return
	if _icon == null:
		_icon = TextureRect.new()
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var row := _label.get_parent() as HBoxContainer
		row.add_child(_icon)
		row.move_child(_icon, 0)
	_icon.texture = tex
	_icon.custom_minimum_size = Vector2(px, px)


func close() -> void:
	_stow_panel()
	if _open_dropdown == self:
		_open_dropdown = null
	_refresh_toggle_arrow()


func is_open() -> bool:
	return _is_open


# ── Internals ──────────────────────────────────────────────────────────────────

func _tick(id: Variant) -> String:
	return "%s  " % String.chr(MenuIcons.CHECK) if id == _current_id else "    "


func _current_label() -> String:
	for entry: Array in _options:
		if entry[1] == _current_id:
			return entry[0] as String
	return _placeholder


## Optional third element of an options entry: the glyph for that value.
func _icon_for(entry: Array) -> Texture2D:
	return (entry[2] as Texture2D) if entry.size() > 2 else null


func _current_icon() -> Texture2D:
	for entry: Array in _options:
		if entry[1] == _current_id:
			return _icon_for(entry)
	return null


func _refresh_labels() -> void:
	for i in range(_opt_btns.size()):
		_opt_btns[i].text = _tick(_ids[i]) + (_options[i][0] as String)
	_refresh_toggle_arrow()


func _refresh_toggle_arrow() -> void:
	var prefix := (String.chr(_toggle_glyph) + "   ") if _toggle_glyph != 0 else ""
	var arrow := String.chr(MenuIcons.COLLAPSE if _is_open else MenuIcons.EXPAND)
	_toggle.text = prefix + _current_label() + " " + arrow
	var glyph := _current_icon()
	_toggle.icon = glyph
	if glyph:
		_toggle.add_theme_constant_override("icon_max_width", 34)


## True for the first activation in a frame; false for xr-tools' duplicate.
func _accept_activation() -> bool:
	var frame := Engine.get_process_frames()
	if frame == _last_activate_frame:
		return false
	_last_activate_frame = frame
	return true


func _on_toggle_pressed() -> void:
	if not _accept_activation():
		return
	var opening := not _is_open
	if _open_dropdown != null and _open_dropdown != self \
			and is_instance_valid(_open_dropdown):
		_open_dropdown.close()
	if opening:
		_open_panel()
	else:
		_stow_panel()
	_open_dropdown = self if opening else null
	_refresh_toggle_arrow()


## In a fixed-height row the panel must overlay what follows, not push it: the
## list is a sibling below the toggle, so simply showing it grows this control
## and the row it sits in. Floating takes it out of layout and reparents it to
## the top-most Control so it also draws above later siblings.
func _open_panel() -> void:
	_is_open = true
	if popout_3d and _open_popout():
		return
	if not float_panel:
		_panel.visible = true
		return

	var host := _float_host_for(self)
	if host != null and _panel.get_parent() != host:
		_panel_home = _panel.get_parent()
		_panel_home.remove_child(_panel)
		host.add_child(_panel)
		_floated_to = host

	_panel.top_level = true
	_panel.visible = true
	_panel.custom_minimum_size.x = _toggle.size.x
	_panel.reset_size()
	var below := _toggle.global_position.y + _toggle.size.y + 2.0
	var flip := float_max_bottom > 0.0 and below + _panel.size.y > float_max_bottom
	_panel.global_position = Vector2(
		_toggle.global_position.x,
		(_toggle.global_position.y - _panel.size.y - 2.0) if flip else below)


func _stow_panel() -> void:
	_is_open = false
	if is_instance_valid(_popout):
		_popout.hide_panel()
	_panel.visible = false
	if not float_panel or _floated_to == null:
		return
	if is_instance_valid(_floated_to) and _panel.get_parent() == _floated_to:
		_floated_to.remove_child(_panel)
		if is_instance_valid(_panel_home):
			_panel_home.add_child(_panel)
	_panel.top_level = false
	_floated_to = null


## Build the popout ahead of the first tap. Everything it does — instancing the
## viewport scene, the arc mesh, the option list — otherwise lands in the frame
## where the user opens a dropdown for the first time.
func prewarm() -> void:
	if _ensure_popout() != null:
		_popout.prewarm()


func _ensure_popout() -> DropdownPanel:
	var host := _host_viewport()
	if host == null:
		return null
	if _popout == null or not is_instance_valid(_popout):
		_popout = DropdownPanel.new()
		_popout.name = "DropdownPopout"
		host.add_child(_popout)
		_popout.option_chosen.connect(_on_popout_chosen)
	return _popout


## Open the list as its own quad in front of the host panel. Returns false when
## there is no 3D host (flat/desktop mode, or a plain 2D scene), so the caller
## falls back to the in-panel list.
func _open_popout() -> bool:
	var host := _host_viewport()
	if _ensure_popout() == null:
		return false

	var rect := Rect2(_toggle.global_position, _toggle.size)
	_popout.show_for(host, rect, _options, _current_id,
		_label.get_theme_font("font"), _grid_cols)
	_panel.visible = false
	return true


func _on_popout_chosen(id: Variant) -> void:
	_current_id = id
	_refresh_labels()
	close()
	item_selected.emit(id)


## The Viewport2Din3D this control is rendering inside, if any. xr-tools parents
## the SubViewport directly under it, so one hop out of our own viewport lands
## on the 3D node.
func _host_viewport() -> XRToolsViewport2DIn3D:
	var vp := get_viewport()
	if vp == null:
		return null
	var parent := vp.get_parent()
	return parent as XRToolsViewport2DIn3D


## Outermost Control ancestor — children added there draw over everything else.
static func _float_host_for(node: Node) -> Control:
	var host: Control = null
	var n: Node = node.get_parent()
	while n != null:
		if n is Control:
			host = n
		n = n.get_parent()
	return host


func _on_item_pressed(id: Variant) -> void:
	if not _accept_activation():
		return
	_current_id = id
	_refresh_labels()
	close()
	item_selected.emit(id)


func _exit_tree() -> void:
	if _open_dropdown == self:
		_open_dropdown = null

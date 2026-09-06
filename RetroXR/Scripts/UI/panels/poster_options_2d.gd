## PosterOptions2D — 2D UI for a Poster's settings.
## Loaded into PosterOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring MouseOptions2D.
##
## Emits:
##   fit_selected(mode)      — Flat / Conform / Decal picked
##   size_changed(value)     — slider moved (fires live while dragging)
##   size_committed(value)   — slider drag finished
##   peel_requested          — take it off the surface
##   close_requested         — user pressed ✕
class_name PosterOptions2D
extends Control

signal fit_selected(mode: int)
signal size_changed(value: float)
signal size_committed(value: float)
signal rotate_requested(clockwise: bool)
signal peel_requested
signal close_requested

const COLOR_BG := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9, 0.9, 1.0)
const COLOR_ROW := Color(0.65, 0.65, 0.80)
const COLOR_ON := Color(0.25, 0.45, 0.85)

const MIN_SIZE := 0.05
const MAX_SIZE := 3.0

var _size_slider: HSlider = null
var _size_val: Label = null
var _fit_buttons: Array[Button] = []
var _peel_btn: Button = null
var _rot_btns: Array[Button] = []
var _suppress_signal := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _build_ui() -> void:
	var margin := MenuStyle.panel_root(self, COLOR_BG, 10, 12)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	MenuStyle.close_button(MenuStyle.title_row(vbox, "Poster", 22),
		func() -> void: close_requested.emit(), false, 36.0, 0)

	# Fit row: three segmented buttons. Reads better than a dropdown at this size,
	# and the whole choice is visible without opening anything.
	var fit_row := HBoxContainer.new()
	fit_row.add_theme_constant_override("separation", 6)
	vbox.add_child(fit_row)
	var fit_lbl := Label.new()
	fit_lbl.text = "Fit"
	fit_lbl.add_theme_color_override("font_color", COLOR_ROW)
	fit_lbl.add_theme_font_size_override("font_size", 18)
	fit_lbl.custom_minimum_size = Vector2(52, 0)
	fit_row.add_child(fit_lbl)
	var names := ["Flat", "Conform", "Decal"]
	for i in range(names.size()):
		var b := Button.new()
		b.text = names[i]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 38)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void:
			if not _suppress_signal:
				fit_selected.emit(i)
		)
		fit_row.add_child(b)
		_fit_buttons.append(b)

	# Size row.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vbox.add_child(row)
	var lbl := Label.new()
	lbl.text = "Size"
	lbl.add_theme_color_override("font_color", COLOR_ROW)
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.custom_minimum_size = Vector2(52, 0)
	row.add_child(lbl)
	_size_slider = HSlider.new()
	_size_slider.min_value = MIN_SIZE
	_size_slider.max_value = MAX_SIZE
	_size_slider.step = 0.01
	_size_slider.custom_minimum_size = Vector2(200, 32)
	_size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_size_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_size_slider.value_changed.connect(_on_size_changed)
	_size_slider.drag_ended.connect(_on_size_drag_ended)
	row.add_child(_size_slider)
	_size_val = Label.new()
	_size_val.custom_minimum_size = Vector2(64, 0)
	_size_val.add_theme_color_override("font_color", COLOR_TITLE)
	_size_val.add_theme_font_size_override("font_size", 18)
	row.add_child(_size_val)

	# Turning it in the plane of the wall. Two arrows rather than a slider: this is
	# nudged to taste against what is around it, not dialled to a number.
	var rot_row := HBoxContainer.new()
	rot_row.add_theme_constant_override("separation", 6)
	vbox.add_child(rot_row)
	var rot_lbl := Label.new()
	rot_lbl.text = "Turn"
	rot_lbl.add_theme_color_override("font_color", COLOR_ROW)
	rot_lbl.add_theme_font_size_override("font_size", 18)
	rot_lbl.custom_minimum_size = Vector2(52, 0)
	rot_row.add_child(rot_lbl)
	for spec: Array in [[MenuIcons.ROTATE_CCW, false], [MenuIcons.ROTATE_CW, true]]:
		var rb := Button.new()
		rb.add_theme_font_override("font", MenuIcons.symbols())
		rb.text = String.chr(spec[0] as int)
		rb.custom_minimum_size = Vector2(0, 40)
		rb.add_theme_font_size_override("font_size", 22)
		rb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cw: bool = spec[1]
		rb.pressed.connect(func() -> void: rotate_requested.emit(cw))
		rot_row.add_child(rb)
		_rot_btns.append(rb)

	_peel_btn = Button.new()
	_peel_btn.text = "Peel off"
	_peel_btn.custom_minimum_size = Vector2(0, 40)
	_peel_btn.pressed.connect(func() -> void: peel_requested.emit())
	vbox.add_child(_peel_btn)


## Fill the controls from the poster's state, firing nothing.
##
## `stuck` greys the rows that only mean something on a surface: a poster in the
## hand has nothing to conform to and nothing to peel off.
func populate(fit_mode: int, size_scale: float, stuck: bool) -> void:
	_suppress_signal = true
	for i in range(_fit_buttons.size()):
		var b := _fit_buttons[i]
		b.button_pressed = (i == fit_mode)
		b.disabled = not stuck and i != 0
		b.add_theme_color_override("font_color",
			COLOR_ON if i == fit_mode else COLOR_ROW)
	_size_slider.value = clampf(size_scale, MIN_SIZE, MAX_SIZE)
	_size_val.text = "%.2f×" % _size_slider.value
	_peel_btn.disabled = not stuck
	for rb: Button in _rot_btns:
		rb.disabled = not stuck
	_suppress_signal = false


func _on_size_changed(value: float) -> void:
	_size_val.text = "%.2f×" % value
	if not _suppress_signal:
		size_changed.emit(value)


func _on_size_drag_ended(changed: bool) -> void:
	if changed and not _suppress_signal:
		size_committed.emit(_size_slider.value)

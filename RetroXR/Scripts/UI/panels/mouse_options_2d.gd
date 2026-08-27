## MouseOptions2D — 2D UI for a RetroMouse's settings.
## Loaded into MouseOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring TVOptions2D.
##
## Emits:
##   sensitivity_changed(value)   — slider moved (fires live while dragging)
##   sensitivity_committed(value) — slider drag finished (persisted by owner)
##   stick_changed(value)         — stick-distance slider moved, in METRES
##   stick_committed(value)       — stick-distance drag finished
##   close_requested              — user pressed ✕
class_name MouseOptions2D
extends Control

signal sensitivity_changed(value: float)
signal sensitivity_committed(value: float)
signal stick_changed(value: float)
signal stick_committed(value: float)
signal close_requested

# ── Palette (matches TVOptions2D / BookOptions2D) ────────────────────────────
const COLOR_BG := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9, 0.9, 1.0)
const COLOR_ROW := Color(0.65, 0.65, 0.80)

const MIN_SENS := 400.0
const MAX_SENS := 6000.0
# The stick slider works in MILLIMETRES: a metre slider at this range steps in
# hundredths and reads 0.03, which tells the player nothing.
const MIN_STICK_MM := 10.0
const MAX_STICK_MM := 100.0

var _sens_slider: HSlider = null
var _sens_val: Label = null
var _stick_slider: HSlider = null
var _stick_val: Label = null
# Guard so populate() doesn't re-emit signals when it sets control values.
var _suppress_signal := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _build_ui() -> void:
	var margin := MenuStyle.panel_root(self, COLOR_BG, 10, 12)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Title row with ✕.
	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)
	var title := Label.new()
	title.text = "Mouse"
	title.add_theme_color_override("font_color", COLOR_TITLE)
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var close_btn := Button.new()
	close_btn.add_theme_font_override("font", MenuIcons.symbols())
	close_btn.text = String.chr(MenuIcons.CLOSE)
	close_btn.custom_minimum_size = Vector2(36, 36)
	close_btn.pressed.connect(func() -> void: close_requested.emit())
	title_row.add_child(close_btn)

	# Sensitivity row: label + slider + value.
	_sens_slider = _add_row(vbox, "Sensitivity", MIN_SENS, MAX_SENS, 100.0)
	_sens_val = _sens_slider.get_parent().get_child(2) as Label
	_sens_slider.value_changed.connect(_on_sens_changed)
	_sens_slider.drag_ended.connect(_on_sens_drag_ended)

	# Snap distance: how close the mouse has to get before it glues down.
	_stick_slider = _add_row(vbox, "Snap distance", MIN_STICK_MM, MAX_STICK_MM, 5.0)
	_stick_val = _stick_slider.get_parent().get_child(2) as Label
	_stick_slider.value_changed.connect(_on_stick_changed)
	_stick_slider.drag_ended.connect(_on_stick_drag_ended)


## One label + slider + value row. Returns the slider; the value Label is its
## sibling at index 2.
func _add_row(vbox: VBoxContainer, text: String, lo: float, hi: float,
		step: float) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vbox.add_child(row)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", COLOR_ROW)
	lbl.add_theme_font_size_override("font_size", 18)
	# Fixed name column so every row's slider starts at the same x.
	lbl.custom_minimum_size = Vector2(118, 0)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.custom_minimum_size = Vector2(200, 32)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)
	var val := Label.new()
	val.custom_minimum_size = Vector2(78, 0)
	val.add_theme_color_override("font_color", COLOR_TITLE)
	val.add_theme_font_size_override("font_size", 18)
	row.add_child(val)
	return slider


## Fill the controls from the mouse's current state (no signals fired).
## stick_distance arrives in metres and is shown in millimetres.
func populate(sensitivity: float, stick_distance: float) -> void:
	_suppress_signal = true
	_sens_slider.value = clampf(sensitivity, MIN_SENS, MAX_SENS)
	_sens_val.text = str(int(_sens_slider.value))
	_stick_slider.value = clampf(stick_distance * 1000.0, MIN_STICK_MM, MAX_STICK_MM)
	_stick_val.text = "%d mm" % int(_stick_slider.value)
	_suppress_signal = false


func _on_sens_changed(value: float) -> void:
	_sens_val.text = str(int(value))
	if not _suppress_signal:
		sensitivity_changed.emit(value)


func _on_sens_drag_ended(changed: bool) -> void:
	if changed and not _suppress_signal:
		sensitivity_committed.emit(_sens_slider.value)


func _on_stick_changed(value: float) -> void:
	_stick_val.text = "%d mm" % int(value)
	if not _suppress_signal:
		stick_changed.emit(value / 1000.0)


func _on_stick_drag_ended(changed: bool) -> void:
	if changed and not _suppress_signal:
		stick_committed.emit(_stick_slider.value / 1000.0)

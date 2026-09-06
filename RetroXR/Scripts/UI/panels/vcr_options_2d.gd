## VCROptions2D — 2D UI for the VCR player's settings.
## Loaded into VCROptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring CoreOptions2D.
##
## One tab:
##   Options — toggles for the VCR player (currently just the VHS effect shader)
##
## Emits:
##   effect_toggled(enabled) — user toggled the VHS effect checkbox
##   close_requested         — user pressed ✕
class_name VCROptions2D
extends Control

signal effect_toggled(enabled: bool)
## Float-in-place toggled.
signal ignore_gravity_toggled(enabled: bool)
signal scan_speed_changed(value: float)
## A VHS shader uniform was changed (pname, value). Applied live to the screen.
signal vcr_param_changed(pname, value)
signal close_requested

# ── Palette (matches CoreOptions2D) ─────────────────────────────────────────────
const COLOR_BG    := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9,  0.9,  1.0)
const COLOR_ROW   := Color(0.65, 0.65, 0.80)

# Fast-forward / rewind scan-rate presets (×).
const SCAN_SPEEDS: Array[float] = [2.0, 4.0, 8.0, 16.0, 32.0]

# ── State ──────────────────────────────────────────────────────────────────────
var _options_scroll: ScrollContainer
var _options_rows: VBoxContainer
var _vhs_scroll: ScrollContainer = null
var _active_scroll: ScrollContainer = null
var _effect_check: VRCheck = null
var _float_check: VRToggle = null
var _scan_idx: int = 2   # default 8×
var _scan_val_lbl: Label = null
# VHS shader controls, keyed by uniform name → {slider, val_label, fmt}.
var _vhs_sliders: Dictionary = {}
var _pixelate_check: VRCheck = null
# Guard so populate() doesn't re-emit effect_toggled when it sets the checkbox.
var _suppress_signal := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	print("[VCROptions2D] UI built")


# ── UI construction ────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var margin := MenuStyle.panel_root(self, COLOR_BG, 10, 12)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)
	margin.add_child(root_vbox)

	MenuStyle.close_button(MenuStyle.title_row(root_vbox, "VCR Settings"),
		func() -> void: close_requested.emit())

	root_vbox.add_child(HSeparator.new())

	# ── Tab container ──────────────────────────────────────────────────────────
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

	_options_rows = VBoxContainer.new()
	_options_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options_rows.add_theme_constant_override("separation", 4)
	_options_scroll.add_child(_options_rows)

	_active_scroll = _options_scroll

	_build_option_rows()
	_build_vhs_tab(tabs)

	# Stick-scroll drives whichever tab is visible.
	tabs.tab_changed.connect(func(idx: int) -> void:
		_active_scroll = _options_scroll if idx == 0 else _vhs_scroll)


func _build_option_rows() -> void:
	# VHS effect toggle row: [label] [checkbox]
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 56)
	row.add_theme_constant_override("separation", 8)
	_options_rows.add_child(row)

	var label := Label.new()
	label.text = "Enable VCR shader"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", COLOR_ROW)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	_effect_check = VRCheck.create(true, func(pressed: bool) -> void:
		if _suppress_signal:
			return
		print("[VCROptions2D] VCR shader → ", pressed)
		effect_toggled.emit(pressed)
	)
	row.add_child(_effect_check)

	_float_check = MenuStyle.float_toggle(_options_rows)
	_float_check.toggled.connect(func(on: bool):
		if not _suppress_signal:
			ignore_gravity_toggled.emit(on)
	)

	# Scan speed stepper row: [label] [<] [value] [>]
	var srow := HBoxContainer.new()
	srow.custom_minimum_size = Vector2(0, 56)
	srow.add_theme_constant_override("separation", 8)
	_options_rows.add_child(srow)

	var slabel := Label.new()
	slabel.text = "FF / REW scan speed"
	slabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slabel.add_theme_font_size_override("font_size", 18)
	slabel.add_theme_color_override("font_color", COLOR_ROW)
	slabel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	srow.add_child(slabel)

	var prev_btn := Button.new()
	prev_btn.text = " < "
	prev_btn.custom_minimum_size = Vector2(48, 48)
	srow.add_child(prev_btn)

	_scan_val_lbl = Label.new()
	_scan_val_lbl.custom_minimum_size = Vector2(80, 0)
	_scan_val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scan_val_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_scan_val_lbl.add_theme_font_size_override("font_size", 18)
	_scan_val_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	_scan_val_lbl.text = _scan_text()
	srow.add_child(_scan_val_lbl)

	var next_btn := Button.new()
	next_btn.text = " > "
	next_btn.custom_minimum_size = Vector2(48, 48)
	srow.add_child(next_btn)

	prev_btn.pressed.connect(func(): _step_scan(-1))
	next_btn.pressed.connect(func(): _step_scan(1))


# ── VHS Effect tab ───────────────────────────────────────────────────────────

func _build_vhs_tab(tabs: TabContainer) -> void:
	var outer := VBoxContainer.new()
	outer.name = "VHS Effect"
	tabs.add_child(outer)

	_vhs_scroll = ScrollContainer.new()
	_vhs_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vhs_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_vhs_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	MenuStyle.fat_vscroll_bar(_vhs_scroll)
	outer.add_child(_vhs_scroll)

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 4)
	_vhs_scroll.add_child(rows)

	# Pixelate toggle row: [label] [checkbox].
	var prow := HBoxContainer.new()
	prow.custom_minimum_size = Vector2(0, 48)
	prow.add_theme_constant_override("separation", 8)
	rows.add_child(prow)
	var plabel := Label.new()
	plabel.text = "Pixelate"
	plabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plabel.add_theme_font_size_override("font_size", 18)
	plabel.add_theme_color_override("font_color", COLOR_ROW)
	plabel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	prow.add_child(plabel)
	_pixelate_check = VRCheck.create(true, func(pressed: bool) -> void:
		if not _suppress_signal:
			vcr_param_changed.emit("pixelate", pressed))
	prow.add_child(_pixelate_check)

	# Sliders: [uniform, label, min, max, step, value-format].
	var specs := [
		["effect_amount",        "Effect mix",   0.0, 1.0,   0.05,   "%.2f"],
		["aberration",           "Aberration",   0.0, 0.01,  0.0005, "%.4f"],
		["scanline_strength",    "Scanlines",    0.0, 1.0,   0.05,   "%.2f"],
		["noise_strength",       "Tape grain",   0.0, 1.0,   0.02,   "%.2f"],
		["wobble_strength",      "Wobble",       0.0, 0.02,  0.001,  "%.3f"],
		["tracking_strength",    "Tracking",     0.0, 0.1,   0.005,  "%.3f"],
		["roll_amount",          "Roll amount",  0.0, 0.05,  0.002,  "%.3f"],
		["roll_speed",           "Roll speed",   0.0, 2.0,   0.05,   "%.2f"],
		["banded_noise_opacity", "Banded noise", 0.0, 1.0,   0.05,   "%.2f"],
		["noise_speed",          "Band speed",   0.0, 16.0,  1.0,    "%.0f"],
		["desaturation",         "Desaturate",   0.0, 1.0,   0.05,   "%.2f"],
		["vhs_contrast",         "Contrast",     0.5, 2.0,   0.05,   "%.2f"],
		["brightness",           "Brightness",   0.5, 2.0,   0.05,   "%.2f"],
	]
	for s: Array in specs:
		_add_vhs_slider(rows, s[0], s[1], s[2], s[3], s[4], s[5])


func _add_vhs_slider(rows: VBoxContainer, key: String, label: String,
		minv: float, maxv: float, step: float, fmt: String) -> void:
	var built := MenuStyle.slider_row(rows, label, minv, maxv, step, 80)
	var slider := built[0] as HSlider
	var val_lbl := built[1] as Label
	slider.value_changed.connect(func(v: float):
		val_lbl.text = fmt % v
		if not _suppress_signal:
			vcr_param_changed.emit(key, v))
	_vhs_sliders[key] = {"slider": slider, "val": val_lbl, "fmt": fmt}


func _step_scan(dir: int) -> void:
	_scan_idx = clampi(_scan_idx + dir, 0, SCAN_SPEEDS.size() - 1)
	_scan_val_lbl.text = _scan_text()
	if not _suppress_signal:
		scan_speed_changed.emit(SCAN_SPEEDS[_scan_idx])


func _scan_text() -> String:
	return "%d×" % int(SCAN_SPEEDS[_scan_idx])


func _nearest_scan_idx(value: float) -> int:
	var best := 0
	var best_d := INF
	for i in SCAN_SPEEDS.size():
		var d: float = absf(SCAN_SPEEDS[i] - value)
		if d < best_d:
			best_d = d
			best = i
	return best


# ── Public API ─────────────────────────────────────────────────────────────────

## Sync the UI to the VCR player's current state without re-emitting signals.
func populate(effect_enabled: bool, scan_speed: float, ignore_gravity := false) -> void:
	_suppress_signal = true
	if _effect_check:
		_effect_check.button_pressed = effect_enabled
	if _float_check:
		_float_check.button_pressed = ignore_gravity
	_scan_idx = _nearest_scan_idx(scan_speed)
	if _scan_val_lbl:
		_scan_val_lbl.text = _scan_text()
	_suppress_signal = false


## Sync the VHS tab's controls to the VCR's current uniform values (no re-emit).
func populate_vcr(params: Dictionary) -> void:
	_suppress_signal = true
	if _pixelate_check and params.has("pixelate"):
		_pixelate_check.button_pressed = bool(params["pixelate"])
	for key: String in _vhs_sliders:
		if not params.has(key):
			continue
		var entry: Dictionary = _vhs_sliders[key]
		var v := float(params[key])
		(entry["slider"] as HSlider).value = v
		(entry["val"] as Label).text = str(entry["fmt"]) % v
	_suppress_signal = false


## Drive the active scroll container from an external stick input (pixels > 0 = down).
func scroll_active(pixels: float) -> void:
	if _active_scroll:
		_active_scroll.scroll_vertical += int(pixels)

## ObjectOptions2D — 2D UI for the generic object menu.
##
## Deliberately almost empty: a title, a ✕, and whatever FloatingObjectPanel3D
## adds. It exists so that a table, a trash can or any other plain pickable has
## a menu to put the "lock in place" row into, rather than that row being the
## privilege of the ten objects that happened to grow a settings panel.
##
## Emits:
##   close_requested — user pressed ✕
class_name ObjectOptions2D
extends Control

signal close_requested

const COLOR_BG := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9, 0.9, 1.0)

var _title: Label = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _build_ui() -> void:
	var margin := MenuStyle.panel_root(self, COLOR_BG, 10, 12)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)
	_title = Label.new()
	_title.text = "Object"
	_title.add_theme_color_override("font_color", COLOR_TITLE)
	_title.add_theme_font_size_override("font_size", 22)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_title)
	var close_btn := Button.new()
	close_btn.add_theme_font_override("font", MenuIcons.symbols())
	close_btn.text = String.chr(MenuIcons.CLOSE)
	close_btn.custom_minimum_size = Vector2(36, 36)
	close_btn.pressed.connect(func() -> void: close_requested.emit())
	title_row.add_child(close_btn)


func populate(title: String) -> void:
	if _title != null:
		_title.text = title

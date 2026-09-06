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

	var title_row := MenuStyle.title_row(vbox, "Object", 22)
	_title = title_row.get_child(0) as Label
	MenuStyle.close_button(title_row, func() -> void: close_requested.emit(),
		22, 36.0)


func populate(title: String) -> void:
	if _title != null:
		_title.text = title

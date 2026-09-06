## AudioOptions2D — 2D UI for a CD or cassette player's settings.
## Loaded into AudioOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring MouseOptions2D.
##
## The decks had no panel at all until float-in-place needed somewhere to live.
## Kept deliberately thin: the transport is on the unit's own face and on the
## remote, so this is for the properties of the OBJECT, not of the playback.
##
## Emits:
##   ignore_gravity_toggled(enabled) — float-in-place toggled
##   close_requested                 — user pressed ✕
class_name AudioOptions2D
extends Control

signal ignore_gravity_toggled(enabled: bool)
signal close_requested

const COLOR_BG    := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9,  0.9,  1.0)

var _title_lbl: Label = null
var _float_check: VRToggle = null
## Guard so populate() doesn't re-emit while it sets the control.
var _suppress := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _build_ui() -> void:
	var margin := MenuStyle.panel_root(self, COLOR_BG, 10, 12)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var title_row := MenuStyle.title_row(root, "Player")
	_title_lbl = title_row.get_child(0) as Label
	MenuStyle.close_button(title_row, func() -> void: close_requested.emit())

	root.add_child(HSeparator.new())

	_float_check = MenuStyle.float_toggle(root)
	_float_check.toggled.connect(func(on: bool):
		if not _suppress:
			ignore_gravity_toggled.emit(on)
	)


## Sync to the player's current state without re-emitting signals.
func populate(title: String, ignore_gravity: bool) -> void:
	_suppress = true
	if _title_lbl and not title.is_empty():
		_title_lbl.text = title
	if _float_check:
		_float_check.button_pressed = ignore_gravity
	_suppress = false

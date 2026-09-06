## DVDOptions2D — 2D UI for a DVDPlayer's settings (audio track + subtitles).
## Loaded into DVDOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring VCROptions2D.
##
## Emits:
##   audio_track_selected(id) — user picked an audio track (libVLC track id)
##   subtitle_selected(id)    — user picked a subtitle track (-1 = off)
##   close_requested          — user pressed ✕
class_name DVDOptions2D
extends Control

signal audio_track_selected(id: int)
signal subtitle_selected(id: int)
## Float-in-place toggled.
signal ignore_gravity_toggled(enabled: bool)
signal close_requested

# ── Palette (matches VCROptions2D) ──────────────────────────────────────────────
const COLOR_BG    := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9,  0.9,  1.0)
const COLOR_ROW   := Color(0.65, 0.65, 0.80)

var _audio_opt: VRDropdown = null
var _sub_opt: VRDropdown = null
var _float_check: VRToggle = null
var _suppress := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _build_ui() -> void:
	var margin := MenuStyle.panel_root(self, COLOR_BG, 10, 12)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	MenuStyle.close_button(MenuStyle.title_row(root, "DVD Settings"),
		func() -> void: close_requested.emit())

	root.add_child(HSeparator.new())

	_audio_opt = _add_dropdown_row(root, "Audio track")
	_audio_opt.item_selected.connect(func(id: Variant) -> void:
		if not _suppress:
			audio_track_selected.emit(int(id)))

	_sub_opt = _add_dropdown_row(root, "Subtitles")
	_sub_opt.item_selected.connect(func(id: Variant) -> void:
		if not _suppress:
			subtitle_selected.emit(int(id)))

	root.add_child(HSeparator.new())
	_float_check = MenuStyle.float_toggle(root)
	_float_check.toggled.connect(func(on: bool):
		if not _suppress:
			ignore_gravity_toggled.emit(on)
	)


## VRDropdown, not OptionButton — a PopupMenu can't be clicked inside the VR
## panel (see vr_dropdown.gd).
func _add_dropdown_row(root: VBoxContainer, label_text: String) -> VRDropdown:
	var drop := VRDropdown.create(label_text, [], -1, 1, Vector2(240, 48))
	drop.set_placeholder("—")
	root.add_child(drop)
	return drop


# ── Public API ──────────────────────────────────────────────────────────────────

## Fill the dropdowns from VlcPlayer track lists (each entry {id:int, name:String})
## and select the current ids, without re-emitting selection signals.
func populate(audio_tracks: Array, cur_audio: int, sub_tracks: Array, cur_sub: int,
		ignore_gravity := false) -> void:
	_suppress = true
	if _float_check:
		_float_check.button_pressed = ignore_gravity
	_fill(_audio_opt, audio_tracks, cur_audio, "")
	# libVLC's subtitle list already includes a "Disable" entry (id -1); add one
	# as a fallback if the disc didn't provide it.
	_fill(_sub_opt, sub_tracks, cur_sub, "Off")
	_suppress = false


func _fill(opt: VRDropdown, tracks: Array, cur_id: int, off_label: String) -> void:
	if opt == null:
		return
	var options: Array = []
	var have_off := false
	for t: Dictionary in tracks:
		var id := int(t.get("id", 0))
		if id == -1:
			have_off = true
		options.append([str(t.get("name", "")), id])
	if not off_label.is_empty() and not have_off:
		options.append([off_label, -1])

	# Fall back to the first entry when the current id isn't in the list.
	var selected: Variant = cur_id
	var found := false
	for entry: Array in options:
		if entry[1] == cur_id:
			found = true
			break
	if not found and not options.is_empty():
		selected = (options[0] as Array)[1]

	opt.set_options(options, selected)

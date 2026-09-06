## CartridgeOptions2D — 2D UI for a cartridge's battery-save management.
## Loaded into CartridgeOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
##
## Lists every .srm that exists for this game (save recovery — files are never
## deleted) plus "New blank save". Selecting an entry re-binds this cartridge's
## save_id; nothing on disk is touched until the console next flushes.
##
## Saves the RomM server holds but this device does not are listed separately
## and can be pulled down; a local save can be toggled to keep syncing.
##
## Emits:
##   save_selected(save_id) — user picked an existing save ("" = new blank)
##   sync_toggled(save_id, on)
##   server_save_requested(slot) — pull a save that only exists on the server
##   new_synced_save_requested   — start a fresh save already set to sync
##   close_requested        — user pressed ✕
class_name CartridgeOptions2D
extends Control

signal save_selected(save_id: String)
signal sync_toggled(save_id: String, on: bool)
## Delete this save's file. The list only reports the press — arming and
## confirming belong to the owner, which is what knows whether the game holding
## it is running. Same division as the memory card's list.
signal save_delete_requested(save_id: String)
signal server_save_requested(slot: String)
signal new_synced_save_requested
## Save states. Capture and overwrite are the same act with and without a row to
## write into; the view only reports the press, and the owner does the arming —
## the same division the delete bin already follows.
signal state_capture_requested
signal state_overwrite_requested(state_id: String)
signal state_load_requested(state_id: String)
signal state_delete_requested(state_id: String)
signal server_state_requested(state_id: String)
signal close_requested

const COLOR_BG      := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE   := Color(0.9,  0.9,  1.0)
const COLOR_ROW     := Color(0.65, 0.65, 0.80)
const COLOR_CURRENT := Color(0.35, 0.85, 0.45)
const COLOR_MUTED   := Color(0.45, 0.45, 0.58)
const COLOR_SYNC    := Color(0.45, 0.70, 1.00)
const COLOR_WARN    := Color(1.00, 0.72, 0.20)

# Glyph names and the font itself come from MenuIcons, so a cloud means the
# same thing here as in the spawn menu. This panel kept a private copy of the
# table AND of the FontVariation that loads it, while already reaching for
# MenuIcons.ERROR in one place -- two tables of the same codepoints, one of
# which was free to drift.
#
# Two glyphs it needed were only in the copy and are now shared: PLUS, and
# SAVE_OVER -- a floppy rather than a refresh arrow, because writing over a
# state saves a file, it does not re-run anything.

var _title_lbl: Label = null
## The ROM's path on disk, under the game's name. Small and muted: it is there to
## tell two dumps of the same game apart, not to be read at a glance.
var _path_lbl: Label = null
var _rows_box: VBoxContainer = null
var _active_scroll: ScrollContainer = null

## Ribbons. The saves list was the whole panel until achievements arrived; both
## are properties of the game in your hand, so both belong here rather than in
## the app's settings.
var _tabs: TabContainer = null
var _saves_scroll: ScrollContainer = null
var _states_scroll: ScrollContainer = null
var _states_box: VBoxContainer = null
var _state_capture_btn: Button = null
var _state_total_lbl: Label = null
var _state_notice_lbl: Label = null
var _ach_scroll: ScrollContainer = null
var _ach_box: VBoxContainer = null
var _ach_summary: Label = null


## Set BEFORE the node enters the tree to drop the panel background and the ✕ —
## what only makes sense when this is a window of its own. The core options panel
## hosts one of these inside its Cartridge tab, where it has both from the panel
## around it. The game's name and path are kept either way: the host's title is
## the console, so nothing else there says which cartridge is in the slot.
var embedded := false

## Can a save be made the current one from here? True whenever there is a
## cartridge to bind it to. The spawn menu's library shows the same saves for a
## ROM with no cartridge in the room: they can be synced and downloaded, but there
## is nothing to make one "current", so the rows are read as a list rather than
## offered as a choice that would quietly do nothing.
var selectable := true

## save_ids RomM is known to hold, as a set. Decides which trash can a row
## shows — the plain one when a copy survives the delete, the crossed-out one
## when this is the last one. Same rule and same glyphs as a memory card's saves.
var backed_up: Dictionary = {}
## save_id whose delete is armed and waiting for a second press, or "".
var armed_id := ""

## The state waiting on a second press, and which action is waiting. ONE slot,
## not one per action: arming either disarms the other, so a row can never be
## waiting on two different confirmations at once.
var states_armed_id := ""
var states_armed_action := ""
## Why a state cannot be taken right now, or "". Greys out both capture and
## overwrite, since both of them write.
var capture_blocked := ""
## Why saves must not be deleted right now, or "". A game writes its .srm as it
## plays, so deleting one under a running console loses whatever it flushes next.
var delete_blocked := ""


static func create_embedded() -> CartridgeOptions2D:
	var ui := CartridgeOptions2D.new()
	ui.embedded = true
	ui.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return ui


func _ready() -> void:
	if not embedded:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _build_ui() -> void:
	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)

	if embedded:
		root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(root_vbox)
		# The host panel's title says "System Settings" and its tab says
		# "Cartridge", so nothing here named the game actually in the slot.
		_build_embedded_header(root_vbox)
	else:
		var margin := MenuStyle.panel_root(self, COLOR_BG, 10, 12)
		margin.add_child(root_vbox)

		_build_title(root_vbox)
		_path_lbl = _make_path_label()
		root_vbox.add_child(_path_lbl)
		root_vbox.add_child(HSeparator.new())

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_saves_scroll = _ribbon("Saves")
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 4)
	_saves_scroll.add_child(_rows_box)

	_build_states_page()

	_ach_scroll = _ribbon("Achievements")
	# The fat VR scrollbar is 40 px and overlays the content, so the points column
	# needs to end before it — without this margin the score sits under the bar.
	var ach_margin := MarginContainer.new()
	ach_margin.add_theme_constant_override("margin_right", 48)
	ach_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ach_scroll.add_child(ach_margin)

	var ach_vbox := VBoxContainer.new()
	ach_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ach_vbox.add_theme_constant_override("separation", 4)
	ach_margin.add_child(ach_vbox)

	_ach_summary = Label.new()
	_ach_summary.add_theme_font_size_override("font_size", 16)
	_ach_summary.add_theme_color_override("font_color", COLOR_MUTED)
	_ach_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ach_vbox.add_child(_ach_summary)

	_ach_box = VBoxContainer.new()
	_ach_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ach_box.add_theme_constant_override("separation", 4)
	ach_vbox.add_child(_ach_box)

	# The thumbstick drives whichever ribbon is showing, the way the spawn menu's
	# active_scroll() does — a stale reference scrolls the hidden page.
	_tabs.tab_changed.connect(func(_i: int) -> void: _sync_active_scroll())
	_active_scroll = _saves_scroll

	root_vbox.add_child(TabStrip.wrap(_tabs))


func _build_title(root_vbox: VBoxContainer) -> void:
	# Not "Battery Save" any more — the saves list is one ribbon of several, and
	# the panel as a whole is about the cartridge.
	var title_row := MenuStyle.title_row(root_vbox, "Cartridge", 24)
	_title_lbl = title_row.get_child(0) as Label
	MenuStyle.close_button(title_row, func() -> void: close_requested.emit())


## Name and path for the embedded copy, which has no title row of its own. Sits
## above the ribbons so it heads the whole tab rather than one page of it.
func _build_embedded_header(root_vbox: VBoxContainer) -> void:
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 0)
	root_vbox.add_child(head)

	_title_lbl = Label.new()
	_title_lbl.add_theme_font_size_override("font_size", 20)
	_title_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	_title_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(_title_lbl)

	_path_lbl = _make_path_label()
	head.add_child(_path_lbl)


## Wrapped rather than trimmed: the filename is the end of a path and the part
## worth reading, so an ellipsis would eat exactly what the line is for. Two
## lines is the ceiling — a third would push the ribbons down the panel.
func _make_path_label() -> Label:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", COLOR_MUTED)
	lbl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	lbl.max_lines_visible = 2
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl.visible = false
	return lbl


func _ribbon(title: String) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	MenuStyle.fat_vscroll_bar(scroll)
	_tabs.add_child(scroll)
	return scroll


## Whichever ScrollContainer the visible page owns.
##
## This used to be `_ach_scroll if current_tab == 1 else _saves_scroll`, which
## is a landmine: inserting any tab silently re-points the thumbstick at the
## wrong page, and correcting the constant would only re-arm it. Ask the page.
func _sync_active_scroll() -> void:
	var page := _tabs.get_current_tab_control()
	_active_scroll = _find_scroll(page) if page != null else _saves_scroll


static func _find_scroll(node: Node) -> ScrollContainer:
	if node is ScrollContainer:
		return node as ScrollContainer
	for child in node.get_children():
		var found := _find_scroll(child)
		if found != null:
			return found
	return null


## Rebuild the list.
##   rom_path    : the ROM on disk, shown under the name ("" hides the line)
##   saves       : SramPaths.list_saves() entries
##   current_id  : the cartridge's bound save_id
##   sync_states : save_id -> "off" | "on" | "busy" | "conflict"
##   server_only : [{slot, size, updated_at}] the server has and this device
##                 does not
func populate(game_label: String, rom_path: String, saves: Array, current_id: String,
			  core_known: bool, sync_states: Dictionary = {}, server_only: Array = [],
			  romm_available: bool = false) -> void:
	_title_lbl.text = game_label if not game_label.is_empty() else "Cartridge"
	_path_lbl.text = rom_path
	_path_lbl.visible = not rom_path.is_empty()
	for child in _rows_box.get_children():
		child.queue_free()

	if not core_known:
		var note := Label.new()
		note.text = "Insert this cartridge into a console once\nto discover its saves."
		note.add_theme_font_size_override("font_size", 18)
		note.add_theme_color_override("font_color", COLOR_ROW)
		_rows_box.add_child(note)
		return

	if selectable:
		_add_new_row(current_id.is_empty() or not _has_id(saves, current_id), romm_available)
	else:
		# Starting a save needs something to start it on. Say so once, above the
		# list, rather than leaving rows that look pressable and are not.
		var note := Label.new()
		note.text = "Spawn this cartridge to choose which save it uses."
		note.add_theme_font_size_override("font_size", 16)
		note.add_theme_color_override("font_color", COLOR_MUTED)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_rows_box.add_child(note)
		if saves.is_empty() and server_only.is_empty():
			var empty := Label.new()
			empty.text = "No saves for this game yet."
			empty.add_theme_font_size_override("font_size", 18)
			empty.add_theme_color_override("font_color", COLOR_ROW)
			_rows_box.add_child(empty)

	for s: Variant in saves:
		var d := s as Dictionary
		var save_id := str(d.get("save_id", ""))
		# The date is the title: it is the one thing that tells two saves of the
		# same game apart at a glance. The id and the size are the detail line,
		# where a memory card puts its serial and block count.
		var when := Time.get_datetime_string_from_unix_time(int(d.get("mtime", 0))).replace("T", "  ")
		_add_row(when, "%s   ·   %.1f KB" % [save_id.left(8), int(d.get("size", 0)) / 1024.0],
			save_id, save_id == current_id,
			str(sync_states.get(save_id, "off")), romm_available)

	if server_only.is_empty():
		return

	var head := Label.new()
	head.text = "  On RomM"
	head.add_theme_font_size_override("font_size", 16)
	head.add_theme_color_override("font_color", COLOR_MUTED)
	_rows_box.add_child(head)

	for e: Variant in server_only:
		_add_server_row(e as Dictionary)


## Starting a fresh save. The synced variant mints the same kind of identity
## and turns sync on before anything is written, so the first flush uploads
## rather than the user having to remember to come back and toggle it.
func _add_new_row(is_current: bool, romm_available: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_rows_box.add_child(row)

	var blank := Button.new()
	blank.custom_minimum_size = Vector2(0, 52)
	blank.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blank.add_theme_font_size_override("font_size", 18)
	blank.alignment = HORIZONTAL_ALIGNMENT_LEFT
	blank.add_theme_font_override("font", MenuIcons.symbols())
	var mark := "%s  " % String.chr(MenuIcons.DOT) if is_current else "    "
	blank.text = mark + "%s  New blank save" % String.chr(MenuIcons.PLUS)
	if is_current:
		blank.add_theme_color_override("font_color", COLOR_CURRENT)
	blank.pressed.connect(func(): save_selected.emit(""))
	row.add_child(blank)

	if not romm_available:
		return

	var synced := Button.new()
	synced.custom_minimum_size = Vector2(0, 52)
	synced.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	synced.add_theme_font_size_override("font_size", 18)
	synced.alignment = HORIZONTAL_ALIGNMENT_LEFT
	synced.add_theme_font_override("font", MenuIcons.symbols())
	synced.text = "  %s  New synced save" % String.chr(MenuIcons.SYNC_ON)
	synced.add_theme_color_override("font_color", COLOR_SYNC)
	synced.tooltip_text = "Start a save that is kept on RomM from the first write"
	synced.pressed.connect(func(): new_synced_save_requested.emit())
	row.add_child(synced)


func _has_id(saves: Array, id: String) -> bool:
	for s: Variant in saves:
		if str((s as Dictionary).get("save_id", "")) == id:
			return true
	return false


## One save, on the same plate a memory card's saves sit on: a title line, a
## detail line, and the actions on the right.
func _add_row(title: String, detail: String, save_id: String, is_current: bool,
			  sync_state: String = "", romm_available: bool = false) -> void:
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", MenuStyle.save_plate_box())
	_rows_box.add_child(plate)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	plate.add_child(row)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var t := Label.new()
	t.add_theme_font_override("font", MenuIcons.symbols())
	t.text = ("%s  " % String.chr(MenuIcons.DOT) if is_current else "") + title
	t.add_theme_font_size_override("font_size", 19)
	t.add_theme_color_override("font_color", COLOR_CURRENT if is_current else COLOR_TITLE)
	col.add_child(t)

	var sub := Label.new()
	var armed: bool = armed_id == save_id
	sub.text = ("Press the bin again to delete this save" if armed else detail)
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", COLOR_WARN if armed else COLOR_MUTED)
	col.add_child(sub)

	if selectable:
		# The plate is the "use this save" target, so the text sits inside a flat
		# button filling it rather than beside one. A Button lays out no children,
		# hence the full-rect anchors and the height it cannot measure itself.
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(0, 52)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.flat = true
		btn.tooltip_text = "Use this save"
		btn.pressed.connect(func(): save_selected.emit(save_id))
		row.add_child(btn)
		col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(col)
	else:
		row.add_child(col)

	# "New blank save" has no file yet, so nothing to sync or delete until it does.
	if save_id.is_empty():
		return
	if romm_available:
		row.add_child(_sync_toggle(save_id, sync_state))
	row.add_child(_delete_button(save_id))


## Delete this save's file — the same act, the same two bins and the same second
## press a memory card's saves ask for.
func _delete_button(save_id: String) -> Button:
	var armed: bool = armed_id == save_id
	# Which bin: RomM holding a copy is the difference between removing one of two
	# and erasing the only one there is.
	var forever := not backed_up.has(save_id)
	var b := Button.new()
	b.custom_minimum_size = Vector2(64, 52)
	b.add_theme_font_override("font", MenuIcons.symbols())
	b.add_theme_font_size_override("font_size", 22)
	if not delete_blocked.is_empty():
		b.disabled = true
		b.text = String.chr(MenuIcons.DELETE_FOREVER)
		b.add_theme_color_override("font_color", COLOR_MUTED)
		b.tooltip_text = delete_blocked
		return b
	b.text = String.chr(MenuIcons.ERROR if armed
		else (MenuIcons.DELETE_FOREVER if forever else MenuIcons.DELETE))
	b.add_theme_color_override("font_color",
		Color(0.95, 0.55, 0.35) if armed else Color(0.85, 0.5, 0.5))
	if armed:
		b.tooltip_text = "Press again to delete permanently" if forever \
			else "Press again — RomM keeps its copy"
	else:
		b.tooltip_text = "Delete this save permanently" if forever \
			else "Delete this save from the device — RomM keeps its copy"
	b.pressed.connect(func(): save_delete_requested.emit(save_id))
	return b


func _sync_toggle(save_id: String, sync_state: String) -> Button:
	var toggle := Button.new()
	toggle.custom_minimum_size = Vector2(64, 52)
	toggle.add_theme_font_override("font", MenuIcons.symbols())
	toggle.add_theme_font_size_override("font_size", 22)
	match sync_state:
		"on":
			toggle.text = String.chr(MenuIcons.SYNC_ON)
			toggle.add_theme_color_override("font_color", COLOR_SYNC)
			toggle.tooltip_text = "Synced with RomM — press to stop"
		"busy":
			toggle.text = String.chr(MenuIcons.BUSY)
			toggle.add_theme_color_override("font_color", COLOR_WARN)
			toggle.tooltip_text = "Syncing…"
		"conflict":
			toggle.text = String.chr(MenuIcons.ERROR)
			toggle.add_theme_color_override("font_color", COLOR_WARN)
			toggle.tooltip_text = "Both copies changed — the server's was kept as a separate save"
		_:
			toggle.text = String.chr(MenuIcons.SYNC_OFF)
			toggle.add_theme_color_override("font_color", COLOR_MUTED)
			toggle.tooltip_text = "Not synced — press to keep this save on RomM"
	var want_on := sync_state != "on"
	toggle.pressed.connect(func(): sync_toggled.emit(save_id, want_on))
	return toggle


## A save that exists only on the server. Pressing it downloads a copy and
## binds this cartridge to it.
func _add_server_row(e: Dictionary) -> void:
	var slot := str(e.get("slot", ""))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_rows_box.add_child(row)

	var when := str(e.get("updated_at", "")).replace("T", "  ").left(19)
	var lbl := Button.new()
	lbl.custom_minimum_size = Vector2(0, 52)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.alignment = HORIZONTAL_ALIGNMENT_LEFT
	lbl.add_theme_color_override("font_color", COLOR_ROW)
	lbl.text = "    %s    %s    %.1f KB" % [slot.left(8), when, int(e.get("size", 0)) / 1024.0]
	lbl.pressed.connect(func(): server_save_requested.emit(slot))
	row.add_child(lbl)

	var get_btn := Button.new()
	get_btn.custom_minimum_size = Vector2(64, 52)
	get_btn.add_theme_font_override("font", MenuIcons.symbols())
	get_btn.add_theme_font_size_override("font_size", 22)
	get_btn.text = String.chr(MenuIcons.DOWNLOAD)
	get_btn.add_theme_color_override("font_color", COLOR_SYNC)
	get_btn.tooltip_text = "Download this save and bind the cartridge to it"
	get_btn.pressed.connect(func(): server_save_requested.emit(slot))
	row.add_child(get_btn)


## Fill the Achievements ribbon.
##   entries : RA.achievements() rows, already in bucket order (locked first)
##   summary : RA.game_info(), or {} when this cartridge is not the live session
##   state   : a sentence for the empty case — why there is nothing to show
func populate_achievements(entries: Array, summary: Dictionary, state: String) -> void:
	for child in _ach_box.get_children():
		child.queue_free()

	if entries.is_empty():
		_ach_summary.text = state
		return

	# Counted from the rows actually listed, not from get_user_game_summary. That
	# summary covers the primary set only, while the list includes bonus subsets —
	# Super Mario Bros. reports 76 there and returns 111 here, and a header that
	# disagrees with the list beneath it reads as a bug whichever number is right.
	var num_unlocked := 0
	var points_total := 0
	var points_unlocked := 0
	for e: Variant in entries:
		var row: Dictionary = e
		var pts := int(row.get("points", 0))
		points_total += pts
		if bool(row.get("unlocked", false)):
			num_unlocked += 1
			points_unlocked += pts

	_ach_summary.text = "%s — %d of %d unlocked, %d of %d points" % [
		str(summary.get("title", "")),
		num_unlocked, entries.size(), points_unlocked, points_total,
	]

	for entry_variant: Variant in entries:
		var entry: Dictionary = entry_variant
		var unlocked := bool(entry.get("unlocked", false))

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.custom_minimum_size = Vector2(0, 52)
		_ach_box.add_child(row)

		# The badge arrives late — RA caches it to disk on first sight, so the row
		# is built without one and filled in when the fetch lands.
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(44, 44)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(icon)
		var url := str(entry.get("badge_url" if unlocked else "badge_locked_url", ""))
		RA.fetch_badge(url, func(badge: Texture2D) -> void:
			if is_instance_valid(icon) and badge != null:
				icon.texture = badge)

		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.add_theme_constant_override("separation", 0)
		row.add_child(text)

		var title := Label.new()
		title.text = str(entry.get("title", ""))
		title.add_theme_font_size_override("font_size", 17)
		title.add_theme_color_override("font_color",
			COLOR_CURRENT if unlocked else COLOR_ROW)
		text.add_child(title)

		var desc := Label.new()
		desc.text = str(entry.get("description", ""))
		desc.add_theme_font_size_override("font_size", 13)
		desc.add_theme_color_override("font_color", COLOR_MUTED)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.add_child(desc)

		# Progress towards a measured achievement ("12/40"), when there is any.
		var measured := str(entry.get("measured_progress", ""))
		if not unlocked and not measured.is_empty():
			var progress := Label.new()
			progress.text = measured
			progress.add_theme_font_size_override("font_size", 13)
			progress.add_theme_color_override("font_color", COLOR_SYNC)
			text.add_child(progress)

		var points := Label.new()
		points.text = "%d" % int(entry.get("points", 0))
		points.add_theme_font_size_override("font_size", 17)
		points.add_theme_color_override("font_color",
			COLOR_CURRENT if unlocked else COLOR_MUTED)
		points.custom_minimum_size = Vector2(40, 0)
		points.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		points.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(points)


## Drive the active scroll container from an external stick input.
func scroll_active(pixels: float) -> void:
	if _active_scroll:
		_active_scroll.scroll_vertical += int(pixels)


# ── States ────────────────────────────────────────────────────────────────────
#
# Not a bare _ribbon(): "Save state now" is the verb the page exists for and
# must not scroll away under forty rows, so the page is a VBox with a fixed
# header above the list.

## The picture box, and the thumbnails written at twice it so they stay sharp.
const _THUMB_BOX := Vector2(96, 72)

## path -> texture, for the life of this Control. Repopulate runs on every sync
## result and every capture; decoding the same PNGs each time is the stutter
## RommArtCache exists to avoid.
var _thumb_cache: Dictionary = {}


func _build_states_page() -> void:
	var page := VBoxContainer.new()
	# The node name IS the tab title, and add_child order IS the tab order.
	page.name = "States"
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 6)
	_tabs.add_child(page)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	page.add_child(head)

	_state_capture_btn = Button.new()
	_state_capture_btn.custom_minimum_size = Vector2(0, 52)
	_state_capture_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_state_capture_btn.add_theme_font_size_override("font_size", 18)
	_state_capture_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_state_capture_btn.add_theme_font_override("font", MenuIcons.symbols())
	_state_capture_btn.text = "    %s  Save state now" % String.chr(MenuIcons.PLUS)
	# Inside a Viewport2Din3D every click arrives twice. The Saves tab's bin gets
	# away with it because _populate() frees the button between the two presses;
	# a capture has no such protection and one click would write two states.
	_state_capture_btn.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	_state_capture_btn.pressed.connect(func(): state_capture_requested.emit())
	head.add_child(_state_capture_btn)

	_state_total_lbl = Label.new()
	_state_total_lbl.add_theme_font_size_override("font_size", 15)
	_state_total_lbl.add_theme_color_override("font_color", COLOR_MUTED)
	_state_total_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(_state_total_lbl)

	_state_notice_lbl = Label.new()
	_state_notice_lbl.add_theme_font_size_override("font_size", 15)
	_state_notice_lbl.add_theme_color_override("font_color", COLOR_WARN)
	_state_notice_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_state_notice_lbl.visible = false
	page.add_child(_state_notice_lbl)

	_states_scroll = ScrollContainer.new()
	_states_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_states_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	MenuStyle.fat_vscroll_bar(_states_scroll)
	page.add_child(_states_scroll)

	_states_box = VBoxContainer.new()
	_states_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_states_box.add_theme_constant_override("separation", 4)
	_states_scroll.add_child(_states_box)


## Rebuild the States list.
##   rows         : StatePaths.list_states() entries
##   total        : bytes on disk for the whole list
##   backup_states: state_id -> "off" | "on" | "busy" | "failed"
##   server_only  : [{state_id, updated_at, size}] the server has and we do not
##   notice       : a sentence above the list, or "" — a failing backup, mostly
func populate_states(rows: Array, total: int, backup_states: Dictionary = {},
					 server_only: Array = [], notice: String = "",
					 romm_available: bool = false) -> void:
	_state_capture_btn.disabled = not capture_blocked.is_empty()
	_state_capture_btn.tooltip_text = capture_blocked if not capture_blocked.is_empty() \
		else "Take a save state of this game right now"
	_state_capture_btn.add_theme_color_override("font_color",
		COLOR_MUTED if _state_capture_btn.disabled else COLOR_TITLE)

	_state_total_lbl.text = "%d state%s  ·  %s" % [rows.size(),
		"" if rows.size() == 1 else "s", MenuStyle.human_bytes(total)]
	_state_notice_lbl.text = notice
	_state_notice_lbl.visible = not notice.is_empty()

	for child in _states_box.get_children():
		child.queue_free()

	if rows.is_empty() and server_only.is_empty():
		var empty := Label.new()
		empty.text = ("No save states for this game yet." if capture_blocked.is_empty()
			else "No save states for this game yet — %s." % capture_blocked)
		empty.add_theme_font_size_override("font_size", 18)
		empty.add_theme_color_override("font_color", COLOR_ROW)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_states_box.add_child(empty)

	for r: Variant in rows:
		_add_state_row(r as Dictionary,
			str(backup_states.get(str((r as Dictionary).get("state_id", "")), "off")),
			romm_available)

	if server_only.is_empty():
		return
	var head := Label.new()
	head.text = "  On RomM"
	head.add_theme_font_size_override("font_size", 16)
	head.add_theme_color_override("font_color", COLOR_MUTED)
	_states_box.add_child(head)
	for e: Variant in server_only:
		_add_server_state_row(e as Dictionary)


## One state: its own picture, when it was last written, and the three things
## that can be done to it. The whole plate loads it.
func _add_state_row(row: Dictionary, backup_state: String, romm_available: bool) -> void:
	var state_id := str(row.get("state_id", ""))
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", MenuStyle.save_plate_box())
	_states_box.add_child(plate)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	plate.add_child(hbox)

	var armed_here: bool = states_armed_id == state_id
	var detail := ""
	match states_armed_action if armed_here else "":
		"overwrite":
			detail = "Press again to save over this state"
		"delete":
			detail = "Press the bin again to delete this state"
		_:
			detail = "%s  ·  %s" % [MenuStyle.human_bytes(int(row.get("bytes", 0))),
				_backup_word(backup_state, romm_available)]

	# The plate is the load target, so its content sits inside a flat button
	# filling it — the same trick a save row uses. A Button lays out no children,
	# hence the full-rect anchors.
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, _THUMB_BOX.y + 10)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.flat = true
	btn.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	btn.tooltip_text = "Load this save state"
	btn.pressed.connect(func(): state_load_requested.emit(state_id))
	hbox.add_child(btn)

	var content := HBoxContainer.new()
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_theme_constant_override("separation", 10)
	# A Label ignores the mouse by default; a TextureRect does not, and one that
	# does not would eat the press meant for the plate.
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(content)
	content.add_child(_thumb_frame(str(row.get("shot", ""))))

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(col)

	var t := Label.new()
	t.text = _when(int(row.get("mtime", 0)))
	t.add_theme_font_size_override("font_size", 19)
	t.add_theme_color_override("font_color", COLOR_TITLE)
	col.add_child(t)

	var sub := Label.new()
	sub.text = detail
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", COLOR_WARN if armed_here else COLOR_MUTED)
	col.add_child(sub)

	hbox.add_child(_overwrite_button(state_id, armed_here
		and states_armed_action == "overwrite"))
	if romm_available:
		hbox.add_child(_backup_glyph(backup_state))
	hbox.add_child(_state_delete_button(state_id, armed_here
		and states_armed_action == "delete"))


## The picture, in a faintly recessed box so an empty one reads as "no picture"
## rather than as a hole in the layout. Fixed size, so the row never reflows.
func _thumb_frame(shot_path: String) -> Control:
	var frame := PanelContainer.new()
	frame.custom_minimum_size = _THUMB_BOX
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := MenuStyle.rounded(Color(0, 0, 0, 0.35), 4)
	frame.add_theme_stylebox_override("panel", box)

	var tex := _thumb(shot_path)
	if tex == null:
		return frame
	var rect := TextureRect.new()
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# NOT nearest, despite the memory card's icons: those are 16x16 upscales,
	# where nearest is right. These are downscales, where it shimmers.
	frame.add_child(rect)
	return frame


func _thumb(shot_path: String) -> Texture2D:
	if shot_path.is_empty():
		return null
	if _thumb_cache.has(shot_path):
		return _thumb_cache[shot_path]
	var img := Image.load_from_file(shot_path)
	var tex: Texture2D = null
	if img != null and not img.is_empty():
		tex = ImageTexture.create_from_image(img)
	_thumb_cache[shot_path] = tex
	return tex


## Drop one picture from the cache, so an overwritten row shows its NEW frame.
## The path does not change across an overwrite, which is exactly why a cache
## keyed on it has to be told.
func forget_thumb(shot_path: String) -> void:
	_thumb_cache.erase(shot_path)


func _when(unix: int) -> String:
	if unix <= 0:
		return "unknown"
	var t := Time.get_datetime_dict_from_unix_time(unix)
	return "%02d:%02d  %d %s" % [t["hour"], t["minute"], t["day"],
		["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct",
		 "Nov", "Dec"][int(t["month"]) - 1]]


## RomM's ISO 8601 timestamp as unix seconds, or 0. Its `updated_at` carries no
## zone, and the server is normally the same box on the same LAN, so it is read
## as local time rather than pretending to know better.
func _unix_of(iso: String) -> int:
	if iso.is_empty():
		return 0
	return int(Time.get_unix_time_from_datetime_string(iso))


func _backup_word(backup_state: String, romm_available: bool) -> String:
	if not romm_available:
		return "On this device"
	match backup_state:
		"on": return "On RomM"
		"busy": return "Uploading…"
		"failed": return "Not backed up"
		_: return "On this device"


## Save over this state, keeping its place in the list. Armed like the bin: this
## is the one action that both writes a file AND destroys what the row held.
func _overwrite_button(state_id: String, armed: bool) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(64, 52)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_override("font", MenuIcons.symbols())
	b.add_theme_font_size_override("font_size", 22)
	b.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	b.text = String.chr(MenuIcons.ERROR if armed else MenuIcons.SAVE_OVER)
	if not capture_blocked.is_empty():
		b.disabled = true
		b.add_theme_color_override("font_color", COLOR_MUTED)
		b.tooltip_text = capture_blocked
		return b
	b.add_theme_color_override("font_color", COLOR_WARN if armed else COLOR_SYNC)
	b.tooltip_text = "Press again to save over this state" if armed \
		else "Save over this state, keeping its place in the list"
	b.pressed.connect(func(): state_overwrite_requested.emit(state_id))
	return b


func _state_delete_button(state_id: String, armed: bool) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(64, 52)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_override("font", MenuIcons.symbols())
	b.add_theme_font_size_override("font_size", 22)
	b.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	b.text = String.chr(MenuIcons.ERROR if armed else MenuIcons.DELETE_FOREVER)
	b.add_theme_color_override("font_color",
		Color(0.95, 0.55, 0.35) if armed else Color(0.85, 0.5, 0.5))
	b.tooltip_text = "Press again to delete this state" if armed \
		else "Delete this save state"
	b.pressed.connect(func(): state_delete_requested.emit(state_id))
	return b


## Backup is a global switch now, so a row reports rather than offers.
func _backup_glyph(backup_state: String) -> Control:
	var lbl := Label.new()
	lbl.custom_minimum_size = Vector2(40, 52)
	lbl.add_theme_font_override("font", MenuIcons.symbols())
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	match backup_state:
		"on":
			lbl.text = String.chr(MenuIcons.SYNC_ON)
			lbl.add_theme_color_override("font_color", COLOR_SYNC)
			lbl.tooltip_text = "Backed up to RomM"
		"busy":
			lbl.text = String.chr(MenuIcons.UPLOAD)
			lbl.add_theme_color_override("font_color", COLOR_WARN)
			lbl.tooltip_text = "Uploading to RomM…"
		"failed":
			lbl.text = String.chr(MenuIcons.ERROR)
			lbl.add_theme_color_override("font_color", COLOR_WARN)
			lbl.tooltip_text = "This state could not be backed up"
		_:
			lbl.text = String.chr(MenuIcons.SYNC_OFF)
			lbl.add_theme_color_override("font_color", COLOR_MUTED)
			lbl.tooltip_text = "Not backed up yet"
	return lbl


## A state that exists only on the server. Pressing it pulls it down, after
## which it is an ordinary row.
func _add_server_state_row(e: Dictionary) -> void:
	var state_id := str(e.get("state_id", ""))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_states_box.add_child(row)

	var lbl := Button.new()
	lbl.custom_minimum_size = Vector2(0, 52)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.alignment = HORIZONTAL_ALIGNMENT_LEFT
	lbl.add_theme_color_override("font_color", COLOR_ROW)
	lbl.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	# Through _when(), like a local row: the server's ISO string trimmed to a
	# fixed width lost its last digit ("21:14:0"), and two halves of one list
	# reading in two different date formats is worse than either.
	lbl.text = "    %s    %s" % [_when(_unix_of(str(e.get("updated_at", "")))),
		MenuStyle.human_bytes(int(e.get("size", 0)))]
	lbl.pressed.connect(func(): server_state_requested.emit(state_id))
	row.add_child(lbl)

	var get_btn := Button.new()
	get_btn.custom_minimum_size = Vector2(64, 52)
	get_btn.add_theme_font_override("font", MenuIcons.symbols())
	get_btn.add_theme_font_size_override("font_size", 22)
	get_btn.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	get_btn.text = String.chr(MenuIcons.DOWNLOAD)
	get_btn.add_theme_color_override("font_color", COLOR_SYNC)
	get_btn.tooltip_text = "Download this save state"
	get_btn.pressed.connect(func(): server_state_requested.emit(state_id))
	row.add_child(get_btn)

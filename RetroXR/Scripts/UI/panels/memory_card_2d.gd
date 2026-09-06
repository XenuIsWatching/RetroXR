## MemoryCard2D — 2D UI listing what is actually saved on a PS1 memory card.
## Loaded into MemoryCardPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring MouseOptions2D / TVOptions2D.
##
## One row per save, each showing the game's own 16x16 icon animated at the
## rate the PlayStation used, its Shift-JIS title, and how many of the card's
## 15 blocks it takes.
##
## Emits:
##   name_committed(text) — card name committed
##   close_requested — user pressed ✕
class_name MemoryCard2D
extends Control

signal name_committed(text: String)
## Move this save to a different card.
signal save_move_requested(save: Dictionary)
## Delete this save. The list only reports the press — arming and confirming
## belong to the owner, which is what knows whether the card is safe to change.
signal save_delete_requested(save: Dictionary)
## Back one save up to RomM, or stop. Off by default — sending a save to a
## server is the player's call, and it is made per save because a card is shared
## between games.
signal save_sync_toggled(save: Dictionary, on: bool)
## Show what RomM holds for this card. The owner does the asking; this only says
## the button was pressed.
signal restore_requested
## Bring one of RomM's saves down onto this card.
signal restore_picked(save: Dictionary)
## Leave the restore list for the card's own saves.
signal restore_closed
signal close_requested

const COLOR_BG := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9, 0.9, 1.0)
const COLOR_ROW := Color(0.65, 0.65, 0.80)
const COLOR_DIM := Color(0.45, 0.45, 0.58)

## The PS1 cycled icon frames at about 6 Hz.
const ICON_FPS := 6.0
const ICON_PX := 48

## Show the rename field and the ✕. The spawn menu reuses this as a read-only
## save list inside its own page, where both would be wrong: it has its own back
## button, and the card being read may not even be in the room to rename.
var show_name_field := true

## This card had an image and it is gone, as opposed to never having had one.
var missing := false

## Offer the per-save actions. Both menus that manage cards turn this on.
var show_save_actions := false
## Include "move to another card" among them. Off for the card's own panel: the
## destination is picked from a list of every other card, which is the shelf's
## business — the card in your hand only manages itself.
var show_move_action := true
## Offer restoring a save from RomM under the list. The spawn menu draws its own
## button for this on the page around us, so it leaves this off.
var show_restore_action := false
## Slot whose delete is armed and awaiting a second press, or "".
var armed_slot := ""
## Save names already opted in to RomM backup, as a set, and whether a server
## exists at all — set like the other view state, before populate().
var synced_slots: Dictionary = {}
var sync_available := false
## Save names the server is known to hold. Opted in is not the same as uploaded,
## so this is its own set: it decides which trash can a row shows, and that is a
## promise about whether the bytes survive the press.
var backed_up_slots: Dictionary = {}
## Why the actions are unavailable, shown in place of the buttons. Empty when
## they work — a card being played is the case that matters.
var actions_blocked := ""

## The family the current listing came from, for the words the rows use. Set by
## populate(); null only before the first one.
var _fmt: CardFormat = null

var _list: VBoxContainer = null
var _scroll: ScrollContainer = null
var _name_edit: LineEdit = null
var _usage: Label = null
var _restore_btn: Button = null

# Each entry: {rect: TextureRect, frames: Array[ImageTexture]}
var _animated: Array[Dictionary] = []
var _clock := 0.0
var _frame := -1


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


## What one unit of card space is called on the family currently listed.
func _unit() -> String:
	return _fmt.unit_noun() if _fmt != null else "block"


func _process(delta: float) -> void:
	if _animated.is_empty():
		return
	_clock += delta
	var f := int(_clock * (_fmt.icon_fps() if _fmt != null else ICON_FPS))
	# 6 Hz of animation does not need 120 Hz of texture assignment; each one
	# dirties the panel and forces its viewport to redraw.
	if f == _frame:
		return
	_frame = f
	for a in _animated:
		var frames: Array = a["frames"]
		var rect: TextureRect = a["rect"]
		rect.texture = frames[f % frames.size()]


func _build_ui() -> void:
	var margin := MenuStyle.panel_root(self, COLOR_BG, 10, 14)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Embedded in a page that already names the card in its own header, the title
	# and its ✕ are a second heading for the same thing.
	var title_row := MenuStyle.title_row(vbox, "Memory Card")
	title_row.visible = show_name_field
	if show_name_field:
		MenuStyle.close_button(title_row,
			func() -> void: close_requested.emit(), false, 0.0, 0)

	var name_row := HBoxContainer.new()
	name_row.visible = show_name_field
	name_row.add_theme_constant_override("separation", 8)
	vbox.add_child(name_row)
	var name_lbl := Label.new()
	name_lbl.text = "Name"
	name_lbl.add_theme_color_override("font_color", COLOR_ROW)
	name_row.add_child(name_lbl)
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_submitted.connect(func(t: String) -> void: name_committed.emit(t))
	_name_edit.focus_exited.connect(func() -> void: name_committed.emit(_name_edit.text))
	name_row.add_child(_name_edit)

	_usage = Label.new()
	_usage.add_theme_color_override("font_color", COLOR_DIM)
	vbox.add_child(_usage)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	# A card holds up to 15 saves and about four rows are in view, so this list
	# scrolls on any well-used card. The bar is widened like every other panel's:
	# the default 8 px is under 6 mm on a panel this size, which a laser cannot
	# hold. 22 px matches the ~15 mm the menu's own bars present.
	_scroll = ScrollContainer.new()
	var scroll := _scroll
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	MenuStyle.fat_vscroll_bar(scroll, 22, 40)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

	_restore_btn = Button.new()
	_restore_btn.text = "Restore a save from RomM"
	_restore_btn.custom_minimum_size = Vector2(0, 44)
	_restore_btn.visible = false
	_restore_btn.pressed.connect(func() -> void: restore_requested.emit())
	vbox.add_child(_restore_btn)


## Fill from a parsed card. `saves` is CardFormat.list_saves() output; `total` is
## how many units this card holds and `free` how many are left.
##
## `fmt` is required rather than defaulted. A default would quietly print a
## PlayStation's fifteen blocks under a GameCube card, and `total` is passed in
## rather than derived because only a card's own image knows its size — a
## GameCube 59 and a 251 are both ordinary.
func populate(card_name: String, saves: Array, free: int, total: int,
		fmt: CardFormat) -> void:
	_name_edit.text = card_name
	_clear_list()
	_fmt = fmt

	_usage.text = "%d of %d %ss used   ·   %d save%s" \
		% [maxi(total - free, 0), total, fmt.unit_noun(),
			saves.size(), "" if saves.size() == 1 else "s"]
	# A card being played must not be edited, and restoring into it is an edit.
	_restore_btn.visible = show_restore_action and sync_available \
		and actions_blocked.is_empty() and not missing

	if show_save_actions and not actions_blocked.is_empty():
		var why := Label.new()
		why.text = actions_blocked
		why.add_theme_font_size_override("font_size", 15)
		why.add_theme_color_override("font_color", Color(0.85, 0.62, 0.4))
		_list.add_child(why)

	if saves.is_empty():
		var empty := Label.new()
		# A card whose image is gone is NOT an empty card. Saying "empty" would
		# invite formatting or overwriting it, when the saves are probably still
		# on disk under whatever the card was renamed to.
		if missing:
			empty.text = "This card's saves are missing.\n\nIts image is not on disk — it may have been\n" \
				+ "renamed, or moved out of the memory card folder.\nNothing has been created in its place."
			empty.add_theme_color_override("font_color", Color(0.85, 0.62, 0.4))
		else:
			empty.text = "This card is formatted and empty."
			empty.add_theme_color_override("font_color", COLOR_DIM)
		_list.add_child(empty)
		return

	for s: Dictionary in saves:
		_list.add_child(_make_row(s))


## Drive the list from an external stick input (pixels > 0 = down), the way every
## other options panel does — SpawnMenuController finds this by name on whatever
## panel a pointer is aimed at.
func scroll_active(pixels: float) -> void:
	if _scroll != null:
		_scroll.scroll_vertical += int(pixels)


## Show what RomM holds for this card in place of the card's own saves.
##
## `note` covers every state with nothing to list — asking, unreachable, holding
## none — so the page always says why it is blank instead of showing an empty
## box. Each save carries the "blocks" it needs and the "reason" it cannot be
## taken, worked out by the owner against this card.
func show_restore(saves: Array, note: String) -> void:
	_clear_list()
	_usage.text = "Saves on RomM"
	_restore_btn.visible = false
	# A different list, read from the top. (populate() deliberately does not do
	# this: deleting the twelfth save should not throw you back to the first.)
	_scroll.scroll_vertical = 0

	var back := Button.new()
	back.text = "‹   Back to this card"
	back.custom_minimum_size = Vector2(0, 44)
	back.pressed.connect(func() -> void: restore_closed.emit())
	_list.add_child(back)

	if not note.is_empty():
		var lbl := Label.new()
		lbl.text = note
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.add_theme_font_size_override("font_size", 16)
		lbl.add_theme_color_override("font_color", COLOR_DIM)
		_list.add_child(lbl)

	for s: Dictionary in saves:
		_list.add_child(_restore_row(s))


## Built like the card's own rows rather than as one wide button: a Button draws
## its text on one line, and a game's name, its size and why it will not fit do
## not fit on one line of a panel this narrow.
func _restore_row(s: Dictionary) -> Control:
	var reason := str(s.get("reason", ""))
	var row := _row_panel()
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	row.add_child(h)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(col)

	var t := Label.new()
	var rom_name := str(s.get("rom_name", ""))
	t.text = rom_name if not rom_name.is_empty() else str(s.get("slot", ""))
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.add_theme_font_size_override("font_size", 19)
	t.add_theme_color_override("font_color", COLOR_TITLE if reason.is_empty() else COLOR_DIM)
	col.add_child(t)

	var blocks: int = int(s.get("blocks", 1))
	var sub := Label.new()
	sub.text = "%d %s%s%s" % [blocks, _unit(), "" if blocks == 1 else "s",
		"" if reason.is_empty() else "   ·   " + reason]
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", COLOR_DIM)
	col.add_child(sub)

	if reason.is_empty():
		h.add_child(_action(MenuIcons.DOWNLOAD, "Put this save on the card",
			MenuIcons.TINT_DOWNLOAD,
			func() -> void: restore_picked.emit(s)))
	return row


func _clear_list() -> void:
	_animated.clear()
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()


## One row's tinted plate. Shared so a save on the card and a save on the server
## read as the same kind of thing.
func _row_panel() -> PanelContainer:
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", MenuStyle.save_plate_box())
	return row


func _make_row(s: Dictionary) -> Control:
	var row := _row_panel()

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	row.add_child(h)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(ICON_PX, ICON_PX)
	# The art is 16x16 on a PlayStation and 32x32 on a GameCube; keep it crisp
	# rather than smearing it up to 48.
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# KEEP_ASPECT, not SCALE, and shrunk to its own height rather than filling
	# the row. A row is as tall as its title, and a GameCube title runs to two or
	# three lines where a PlayStation one fits on one -- under SCALE that stretched
	# every GameCube icon into a tall smear, while the PlayStation's short rows
	# had hidden the same bug for as long as it has been there.
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(icon)

	var frames: Array = []
	for img: Image in s.get("icons", []):
		frames.append(ImageTexture.create_from_image(img))
	if not frames.is_empty():
		icon.texture = frames[0]
		if frames.size() > 1:
			_animated.append({"rect": icon, "frames": frames})

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(col)

	var t := Label.new()
	var title_text := str(s.get("title", ""))
	t.text = title_text if not title_text.is_empty() else str(s.get("name", ""))
	# Wrapping is what lets the row narrow: an unwrapped Label's minimum width is
	# its whole title, so one long name ("PARAPPA THE RAPPER") pushed the buttons
	# and the scrollbar off the edge of the panel.
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.add_theme_font_size_override("font_size", 20)
	t.add_theme_color_override("font_color", COLOR_TITLE)
	col.add_child(t)

	var sub := Label.new()
	var blocks: int = int(s.get("blocks", 1))
	sub.text = "%s   ·   %d %s%s" \
		% [str(s.get("serial", "")), blocks, _unit(),
			"" if blocks == 1 else "s"]
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", COLOR_DIM)
	col.add_child(sub)

	# actions_blocked is a fact about the card, said once above the list rather
	# than repeated on every row.
	if show_save_actions and actions_blocked.is_empty():
		if show_move_action:
			h.add_child(_action(MenuIcons.MOVE, "Move to another card",
				Color(0.72, 0.76, 0.92),
				func() -> void: save_move_requested.emit(s)))
		if sync_available:
			var on: bool = synced_slots.has(str(s.get("name", "")))
			h.add_child(_action(
				MenuIcons.SYNC_ON if on else MenuIcons.SYNC_OFF,
				# Opted in is not the same as uploaded — a save whose game is
				# not in the library stays on and waiting. Claiming "backed
				# up" here would be a promise the button cannot keep.
				"Backing this save up to RomM" if on
					else "Back this save up to RomM",
				Color(0.55, 0.78, 0.95) if on else Color(0.5, 0.5, 0.62),
				func() -> void: save_sync_toggled.emit(s, not on)))
		# Armed shows the warning glyph and says so, matching how a ROM row
		# asks twice before deleting.
		#
		# And which trash can, on the same rule those rows use: the plain one
		# when RomM holds a copy of this save, the crossed-out one when the
		# card is the only place it exists.
		var armed: bool = armed_slot == str(s.get("name", ""))
		var forever: bool = not backed_up_slots.has(str(s.get("name", "")))
		var glyph := MenuIcons.DELETE_FOREVER if forever else MenuIcons.DELETE
		var tip := "Delete this save permanently" if forever \
			else "Delete this save from the card — RomM keeps its copy"
		h.add_child(_action(
			MenuIcons.ERROR if armed else glyph,
			("Press again to delete permanently" if forever
				else "Press again — RomM keeps its copy") if armed else tip,
			Color(0.95, 0.55, 0.35) if armed else Color(0.85, 0.5, 0.5),
			func() -> void: save_delete_requested.emit(s)))

	return row


func _action(glyph: int, tip: String, tint: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(56, 56)
	b.text = String.chr(glyph)
	b.add_theme_font_override("font", MenuIcons.symbols())
	b.add_theme_font_size_override("font_size", 26)
	b.add_theme_color_override("font_color", tint)
	b.tooltip_text = tip
	b.pressed.connect(on_press)
	return b

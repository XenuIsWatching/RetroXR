## BsxPackContents2D — what is written on a Satellaview 8M Memory Pack.
##
## A pack is a MEDIUM, not a game. Pointing at one and asking about it used to
## open the cartridge menu — Saves, States, Achievements — none of which a pack
## has. What it does have is up to eight blocks of flash with programmes written
## across them, and that is what this shows: each programme's title, which blocks
## it holds, and how much of the pack is left.
##
## ONE Control, shown two ways, which is the CartridgeOptions2D arrangement:
## create_embedded() drops the background and the ✕ so the spawn menu can host it
## inside its own overlay, while the default form carries both for BsxPackPanel to
## float beside the pack in the room. Two presentations of one list, so a fix to
## the list is a fix to both.
##
## READ-ONLY on purpose. BsxPackFormat can list a pack but not rearrange one: the
## block-erase semantics have not been watched, and a wrong guess destroys a
## download obtainable only from the live broadcast. There is deliberately no
## delete here to grow a confirm dialog onto later.
class_name BsxPackContents2D
extends Control

signal close_requested

const COLOR_BG := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9, 0.9, 1.0)
const COLOR_ROW := Color(0.82, 0.82, 0.95)
const COLOR_DIM := Color(0.55, 0.55, 0.68)
const COLOR_FREE := Color(0.45, 0.85, 0.45)

## Hosted inside another panel's overlay: no background of its own, no ✕.
var embedded := false

var _list: VBoxContainer = null
var _scroll: ScrollContainer = null
var _heading: Label = null
var _usage: Label = null


static func create_embedded() -> BsxPackContents2D:
	var ui := BsxPackContents2D.new()
	ui.embedded = true
	return ui


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _build_ui() -> void:
	if not embedded:
		var bg := ColorRect.new()
		bg.color = COLOR_BG
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	add_child(margin)

	var col := MenuStyle.vbox(8)
	margin.add_child(col)

	var head := MenuStyle.hbox(8)
	col.add_child(head)

	_heading = MenuStyle.label("", 24, COLOR_TITLE)
	_heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# symbols() so the pack glyph and the Latin/Shift-JIS title share one label.
	_heading.add_theme_font_override("font", MenuIcons.symbols())
	head.add_child(_heading)

	if not embedded:
		var close := Button.new()
		close.text = String.chr(MenuIcons.CLOSE)
		close.custom_minimum_size = Vector2(52, 52)
		close.add_theme_font_override("font", MenuIcons.symbols())
		close.add_theme_font_size_override("font_size", 26)
		close.pressed.connect(func() -> void: close_requested.emit())
		head.add_child(close)

	_usage = MenuStyle.label("", 17, COLOR_DIM)
	col.add_child(_usage)

	_scroll = MenuStyle.vscroll()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	MenuStyle.fat_vscroll_bar(_scroll)
	col.add_child(_scroll)

	_list = MenuStyle.vbox(6)
	_scroll.add_child(_list)


## Show what is on this pack.
##
## `programmes` is BsxPack.programmes_of shape — title, block, blocks, offset,
## lorom. `pack_name` is the medium's own name, not a programme's.
func populate(pack_name: String, programmes: Array, free: int, total: int) -> void:
	if _list == null:
		return
	for c: Node in _list.get_children():
		_list.remove_child(c)
		c.queue_free()

	_heading.text = "%s  %s" % [String.chr(MenuIcons.BSX_MEMORY_PACK), pack_name]

	var named: Array[Dictionary] = []
	for p: Dictionary in programmes:
		var t := str(p["title"])
		if not t.is_empty() and t != BsxPack.BLANK_TITLE:
			named.append(p)

	var used: int = total - free
	_usage.text = "%d of %d blocks used · %d free" % [used, total, free]
	_usage.add_theme_color_override("font_color", COLOR_FREE if free > 0 else COLOR_DIM)

	if named.is_empty():
		# An untouched pack, said plainly. The placeholder header a blank is
		# minted with names no programme, so listing it would invent one.
		var empty := MenuStyle.label(
			"Nothing written on this pack yet.", 20, COLOR_DIM)
		_list.add_child(empty)
		_list.add_child(MenuStyle.spacer(6))
		_list.add_child(MenuStyle.hint(
			"Take it to the Broadcast Station in the BS-X town and download something."))
		return

	for p: Dictionary in named:
		_list.add_child(_programme_row(p))


## One programme: what it is called, and which blocks it holds.
func _programme_row(p: Dictionary) -> Control:
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", MenuStyle.save_plate_box())

	var pad := MarginContainer.new()
	for side: String in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 10)
	for side: String in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 8)
	plate.add_child(pad)

	var col := MenuStyle.vbox(2)
	pad.add_child(col)

	var title := MenuStyle.label(str(p["title"]), 21, COLOR_ROW)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(title)

	var blocks: Array = p["blocks"]
	col.add_child(MenuStyle.label(
		"%s · %d of %d blocks" % [_span(blocks), blocks.size(), BsxPack.BLOCK_COUNT],
		16, COLOR_DIM))
	return plate


## "block 3" / "blocks 0-3" / "blocks 0-1, 4-7" — runs, not a list of eight.
## A programme's blocks are contiguous in every pack seen so far, but the field is
## a bitmap and nothing in the format promises that, so this reads either way.
static func _span(blocks: Array) -> String:
	if blocks.is_empty():
		return "no blocks"
	var runs: Array[String] = []
	var start: int = int(blocks[0])
	var prev: int = start
	for i in range(1, blocks.size()):
		var b := int(blocks[i])
		if b != prev + 1:
			runs.append(str(start) if start == prev else "%d-%d" % [start, prev])
			start = b
		prev = b
	runs.append(str(start) if start == prev else "%d-%d" % [start, prev])
	var word := "block" if blocks.size() == 1 else "blocks"
	return "%s %s" % [word, ", ".join(runs)]


## Thumbstick / mouse-wheel scroll, the contract spawn_menu_controller looks for.
func scroll_active(pixels: float) -> void:
	if _scroll != null:
		_scroll.scroll_vertical += int(pixels)

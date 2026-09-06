## ConsolePadDiagram — a remap view anchored on a picture of a pad, with a
## leader line from every control to its own row.
##
## The third of the family, after ControllerDiagram (XR) and GamepadDiagram
## (physical pads), and the only one not tied to one piece of hardware: the art,
## anchors and orders arrive from ConsolePadArt, keyed by systemid. The
## "retropad" row there is the generic pad, for scopes that are not one console.
##
## Direction is the inverse of the other two. Those anchor on the thing in your
## hands and ask "what does this input do?"; this anchors on the pad the CORE
## sees and asks "what drives this button?" — which is the question a platform
## override is about, and the reason the choices are sources rather than RetroPad
## targets. It also means only the controls the hardware has are offered: a NES
## page has no L3 to bind, so it shows none.
##
## Two layouts, chosen by the art's shape. A console pad is wide and short, so
## its rows run along the TOP and BOTTOM — a column beside it would put every
## lead nearly horizontal across the picture. The generic pad is roughly square
## and uses side COLUMNS, the way GamepadDiagram always has.
##
## Two row kinds. DROPDOWN picks from a fixed list of sources. BIND waits for the
## player to press what they want, which is the only workable shape for a
## keyboard: the list of choices is every key on it, plus the mouse.
##
## A DROPDOWN row carries no words: the glyph on its left names the control and
## the one on its toggle names whatever drives it. The four d-pad glyphs are the
## weak case — they differ only by which arm of the same cross is filled — so the
## leader line, which points at the arm itself, is what disambiguates them.
class_name ConsolePadDiagram
extends Control

## DROPDOWN rows only: the player picked a new source for `control`.
## `control` is a GamepadBindings target string; `id` is an entry from the
## options array the owner supplied, or "" for unbound.
signal binding_changed(control: String, id: Variant)
## BIND rows only: the player wants the next key/mouse press to land on
## `control`. The owner does the capturing and calls set_bind_label() back.
signal bind_requested(control: String)

enum RowKind { DROPDOWN, BIND }

## Applied only to line art. A colour illustration is shown as drawn — see
## ConsolePadArt.tints().
const ART_TINT := Color(0.74, 0.78, 0.87)
const LEAD_COLOR := Color(1.0, 0.69, 0.29)
const DOT_COLOR := Color(1.0, 0.80, 0.47)
const LEAD_WIDTH := 2.0
const DOT_RADIUS := 5.0

## Kenney Input Prompts 1.5 (CC0), the same set the other two diagrams use.
const GLYPH_DIR := "res://Textures/InputPrompts/"
## Kenney ships these as vectors and Godot rasterises them at IMPORT, so the
## extension is not a runtime detail — it decides which file the seven glyph
## lookups scattered across four panels reach for. One constant, because six of
## them said ".png" independently and adding a set in the other format meant
## finding all six.
const GLYPH_EXT := ".svg"

## Larger than the sibling diagrams' 42: the four d-pad glyphs differ only by
## which arm of the same cross is filled, and the pack has no single-arrow
## variant. The leader line to the arm itself is still the primary cue.
const GLYPH_PX := 46.0

## Mirrored in Tools/art/nes_pad_anchors.py, which verifies that no two leads cross
## at any panel size. Changing one without the other invalidates that check.
const MAX_W := 1520.0
const SLOT_W := 180.0
const ROW_H := 50.0
const ROW_PAD := 14.0
const STUB := 18.0

## Gutter between adjacent slots. SLOT_W is the spacing the layout reserves; a
## row is drawn narrower than that so two pushed hard against each other still
## read as two rows and not one.
const SLOT_GAP := 18.0

## Side-column layout, matching GamepadDiagram's proportions.
const COL_W := 210.0
const COL_GAP := 16.0
const EDGE_PAD := 24.0

var _systemid := ""


## The ConsolePadArt key this diagram was built from. Not always a systemid:
## a platform held more than one way draws a variant key per way, and a
## caller repainting the page needs to ask for the right one's controls.
func systemid() -> String:
	return _systemid
var _row: Dictionary = {}
var _rows: Dictionary = {}      # control -> VRDropdown (DROPDOWN) or HBox (BIND)
var _anchor_px: Dictionary = {}
var _kind := RowKind.DROPDOWN

# The art is DRAWN rather than parented as a TextureRect. A Control renders its
# own _draw() behind its children, so a child would have covered the leader
# lines and the anchor dots — invisible with line art, whose body is nearly
# transparent, and total with a colour illustration.
var _art_tex: Texture2D = null
var _art_rect := Rect2()
var _tint := true


## `options` is the VRDropdown options array of sources (DROPDOWN rows only);
## `current` maps control -> the id driving it, or the label for a BIND row.
func setup(systemid: String, options: Array, current: Dictionary,
		kind: RowKind = RowKind.DROPDOWN) -> void:
	for c in get_children():
		c.queue_free()
		remove_child(c)
	_rows.clear()

	_systemid = systemid
	_kind = kind
	_row = ConsolePadArt.row(systemid)
	if _row.is_empty():
		return

	_art_tex = ConsolePadArt.texture(systemid)
	_tint = ConsolePadArt.tints(systemid)

	# Rows are children, so they draw over the art either way.
	for control: String in controls():
		var label: String = GamepadBindings.TARGET_LABELS.get(control, control)
		var glyph := _control_glyph(control)
		var node: Control
		if kind == RowKind.BIND:
			node = _bind_row(control, String(current.get(control, "(none)")), glyph)
		else:
			var drop := VRDropdown.create("", options, current.get(control, ""),
				3, Vector2(96, ROW_H - 6), 16)
			if glyph:
				drop.set_icon(glyph, GLYPH_PX)
			drop.float_panel = true
			var captured := control
			drop.item_selected.connect(func(id: Variant) -> void:
				binding_changed.emit(captured, id))
			node = drop
		node.tooltip_text = "What drives %s" % label
		add_child(node)
		_rows[control] = node

	_relayout()


## A BIND row: the control's glyph, then a button naming its binding. Built by
## hand rather than from VRDropdown, because press-to-bind has no list to open.
func _bind_row(control: String, text: String, glyph: Texture2D) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)

	if glyph:
		var ico := TextureRect.new()
		ico.texture = glyph
		ico.custom_minimum_size = Vector2(GLYPH_PX, GLYPH_PX)
		ico.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ico.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ico.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(ico)

	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", 16)
	btn.focus_mode = Control.FOCUS_NONE
	btn.clip_text = true
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.custom_minimum_size = Vector2(0, ROW_H - 8)
	var captured := control
	btn.pressed.connect(func() -> void:
		btn.text = "[ press… ]"
		bind_requested.emit(captured))
	box.add_child(btn)

	box.set_meta("bind_button", btn)
	return box


## The glyph for a control: this pad's OWN if it declares one, else the shared
## RetroPad picture.
##
## The fallback is right for a console whose controls are RetroPad-shaped — a NES
## Start really is a Start — and wrong the moment the hardware has buttons the
## RetroPad has no name for. The Wii Remote binds Home to r3 and plus to start
## because that is what reaches the core, and taking the picture from that map too
## labelled the diagram with a PlayStation R3 and a PlayStation Start: names for
## buttons this remote does not have. A row that knows better says so.
##
## GamepadDiagram is left alone. It draws an actual gamepad, where the shared map
## is the right answer, and the two panels agreeing about a real pad is the thing
## that comment was protecting.
func _control_glyph(control: String) -> Texture2D:
	var own: Dictionary = _row.get("glyphs", {})
	var name_text := String(own.get(control, GamepadDiagram.TARGET_GLYPHS.get(control, "")))
	if name_text.is_empty():
		return null
	return load(GLYPH_DIR + name_text + GLYPH_EXT) as Texture2D


## True when this art lays its rows down the sides rather than along the top and
## bottom.
func _columns() -> bool:
	return String(_row.get("layout", "rows")) == "columns"


func _order(first: bool) -> Array:
	if _row.is_empty():
		return []
	if _columns():
		return _row["left"] if first else _row["right"]
	return _row["top"] if first else _row["bottom"]


## Every control this pad carries, in row order.
func controls() -> Array:
	return _order(true) + _order(false)


## The VRDropdown driving `control`, so the owning panel can register it.
func get_dropdown(control: String) -> VRDropdown:
	return _rows.get(control) as VRDropdown


## Relabel a BIND row — what the owner calls once a capture completes.
func set_bind_label(control: String, text: String) -> void:
	var box := _rows.get(control) as Control
	if box == null:
		return
	var btn := box.get_meta("bind_button", null) as Button
	if is_instance_valid(btn):
		btn.text = text


## Push a DROPDOWN selection into the UI without emitting binding_changed.
func set_binding(control: String, id: Variant) -> void:
	var drop := _rows.get(control) as VRDropdown
	if drop:
		drop.select_id(id)


## Push every row at once — what a reset needs. Works for both kinds.
func refresh(current: Dictionary) -> void:
	for control: String in _rows:
		if _kind == RowKind.BIND:
			set_bind_label(control, String(current.get(control, "(none)")))
		else:
			set_binding(control, current.get(control, ""))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_relayout()


## Slot centres for one top/bottom row.
##
## Each slot starts directly under (or over) its own anchor, so its lead is as
## short and as vertical as it can be; only where two would overlap are they
## pushed apart, order preserved. The forward pass can only push right, so it can
## run off the edge — hence the walk back.
func _slot_xs(order: Array, art: Rect2) -> Array:
	var anchors: Dictionary = _row["anchors"]
	var xs: Array = []
	for control: String in order:
		var uv: Vector2 = anchors[control]
		xs.append(art.position.x + uv.x * art.size.x)

	for i in range(1, xs.size()):
		if float(xs[i]) - float(xs[i - 1]) < SLOT_W:
			xs[i] = float(xs[i - 1]) + SLOT_W

	var over := float(xs[xs.size() - 1]) - (size.x - SLOT_W * 0.5)
	if over > 0.0:
		for i in xs.size():
			xs[i] = float(xs[i]) - over
		for i in range(xs.size() - 2, -1, -1):
			if float(xs[i + 1]) - float(xs[i]) < SLOT_W:
				xs[i] = float(xs[i + 1]) - SLOT_W

	var lo := SLOT_W * 0.5
	if float(xs[0]) < lo:
		var shift := lo - float(xs[0])
		for i in xs.size():
			xs[i] = float(xs[i]) + shift
	return xs


func _relayout() -> void:
	if _art_tex == null or _row.is_empty():
		return
	if _columns():
		_relayout_columns()
	else:
		_relayout_rows()
	_measure_anchors()
	queue_redraw()


func _relayout_rows() -> void:
	var band_w := minf(size.x, MAX_W)
	var art_h := size.y - 2.0 * (ROW_H + ROW_PAD)
	if art_h <= 0.0:
		return
	var aspect := float(_art_tex.get_width()) / float(_art_tex.get_height())
	var art_w := art_h * aspect
	if art_w > band_w:
		art_w = band_w
		art_h = art_w / aspect
	_art_rect = Rect2(Vector2((size.x - art_w) * 0.5, (size.y - art_h) * 0.5),
		Vector2(art_w, art_h))

	for top in [true, false]:
		var order := _order(top)
		var xs := _slot_xs(order, _art_rect)
		var row_y := 0.0 if top else size.y - ROW_H
		for i in order.size():
			var node := _rows.get(order[i]) as Control
			if node == null:
				continue
			node.position = Vector2(float(xs[i]) - (SLOT_W - SLOT_GAP) * 0.5, row_y)
			node.size = Vector2(SLOT_W - SLOT_GAP, ROW_H)
			if node is VRDropdown:
				(node as VRDropdown).float_max_bottom = global_position.y + size.y


func _relayout_columns() -> void:
	var band_w := minf(size.x, MAX_W)
	var band_x := (size.x - band_w) * 0.5
	var rows := maxi(_order(true).size(), _order(false).size())
	if rows <= 0:
		return
	var rows_h := rows * ROW_H + (rows - 1) * COL_GAP
	var rows_top := maxf((size.y - rows_h) * 0.5, 0.0)

	for side in 2:
		var order := _order(side == 0)
		var col_x := band_x if side == 0 else band_x + band_w - COL_W
		for i in order.size():
			var node := _rows.get(order[i]) as Control
			if node == null:
				continue
			node.position = Vector2(col_x, rows_top + i * (ROW_H + COL_GAP))
			node.size = Vector2(COL_W, ROW_H)
			if node is VRDropdown:
				(node as VRDropdown).float_max_bottom = global_position.y + size.y

	var avail_w := band_w - 2.0 * (COL_W + EDGE_PAD)
	var art_h := size.y - 20.0
	if art_h <= 0.0:
		return
	var aspect := float(_art_tex.get_width()) / float(_art_tex.get_height())
	var art_w := art_h * aspect
	if art_w > avail_w:
		art_w = avail_w
		art_h = art_w / aspect
	_art_rect = Rect2(
		Vector2(band_x + (band_w - art_w) * 0.5, (size.y - art_h) * 0.5),
		Vector2(art_w, art_h))


func _measure_anchors() -> void:
	_anchor_px.clear()
	var anchors: Dictionary = _row["anchors"]
	for control: String in anchors:
		var uv: Vector2 = anchors[control]
		_anchor_px[control] = _art_rect.position + uv * _art_rect.size


func _draw() -> void:
	if _row.is_empty():
		return
	if _art_tex != null and _art_rect.size.x > 0.0:
		draw_texture_rect(_art_tex, _art_rect, false,
			ART_TINT if _tint else Color.WHITE)

	var cols := _columns()
	for first in [true, false]:
		for control: String in _order(first):
			var node := _rows.get(control) as Control
			if node == null or not _anchor_px.has(control):
				continue
			var anchor: Vector2 = _anchor_px[control]
			var edge: Vector2
			var stub: Vector2
			if cols:
				# Meet the row, not an expanded option panel: the toggle is its
				# top row.
				edge = Vector2(node.position.x + (COL_W if first else 0.0),
					node.position.y + ROW_H * 0.5)
				stub = Vector2(edge.x + (STUB if first else -STUB), edge.y)
			else:
				var cx := node.position.x + (SLOT_W - SLOT_GAP) * 0.5
				edge = Vector2(cx, node.position.y + (ROW_H if first else 0.0))
				stub = Vector2(cx, edge.y + (STUB if first else -STUB))
			draw_line(edge, stub, LEAD_COLOR, LEAD_WIDTH, true)
			draw_line(stub, anchor, LEAD_COLOR, LEAD_WIDTH, true)
			draw_circle(anchor, DOT_RADIUS, DOT_COLOR, true)

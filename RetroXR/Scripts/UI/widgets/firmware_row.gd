## FirmwareRow — one declared firmware file as a row: status glyph, path,
## description, and a Required / Optional / Wrong file tag.
##
## Shared by the spawn menu's Cores > BIOS page and the machine's own BIOS
## ribbon, so a file reads the same in both. Callers append their own trailing
## cells (an action button, a scrollbar gutter).
##
## `r` is a row from FirmwareState.evaluate(): {path, desc, optional, status}.
class_name FirmwareRow
extends RefCounted


static func build(r: Dictionary, desc: String) -> HBoxContainer:
	var status := int(r.get("status", FirmwareState.Status.PRESENT))
	var optional: bool = bool(r.get("optional", true))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 56)

	var glyph := Label.new()
	glyph.add_theme_font_override("font", MenuIcons.symbols())
	glyph.add_theme_font_size_override("font_size", 26)
	glyph.custom_minimum_size = Vector2(40, 0)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	match status:
		FirmwareState.Status.PRESENT:
			glyph.text = String.chr(MenuIcons.CHECK)
			glyph.add_theme_color_override("font_color", MenuIcons.TINT_OK)
		FirmwareState.Status.MISMATCH:
			glyph.text = String.chr(MenuIcons.ERROR)
			glyph.add_theme_color_override("font_color", MenuIcons.TINT_WARN)
		FirmwareState.Status.MISSING_REQUIRED:
			glyph.text = String.chr(MenuIcons.CROSS)
			glyph.add_theme_color_override("font_color", MenuIcons.TINT_DELETE)
		_:
			glyph.text = String.chr(MenuIcons.DASH)
			glyph.add_theme_color_override("font_color", MenuIcons.TINT_MUTED)
	row.add_child(glyph)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 0)
	row.add_child(col)

	var name_lbl := Label.new()
	name_lbl.text = str(r.get("path", ""))
	name_lbl.add_theme_font_size_override("font_size", 19)
	name_lbl.add_theme_color_override("font_color",
		MenuStyle.COLOR_TITLE if status != FirmwareState.Status.MISSING_OPTIONAL else MenuStyle.COLOR_LICENSE)
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(name_lbl)

	if not desc.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = desc
		desc_lbl.add_theme_font_size_override("font_size", 15)
		desc_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
		desc_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col.add_child(desc_lbl)

	var tag := Label.new()
	tag.add_theme_font_size_override("font_size", 15)
	tag.custom_minimum_size = Vector2(170, 0)
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if status == FirmwareState.Status.MISMATCH:
		tag.text = "Wrong file"
		tag.add_theme_color_override("font_color", MenuIcons.TINT_WARN)
	elif optional:
		tag.text = "Optional"
		tag.add_theme_color_override("font_color", MenuIcons.TINT_MUTED)
	else:
		tag.text = "Required"
		tag.add_theme_color_override("font_color",
			MenuIcons.TINT_DELETE if status == FirmwareState.Status.MISSING_REQUIRED else MenuStyle.COLOR_LICENSE)
	row.add_child(tag)

	return row

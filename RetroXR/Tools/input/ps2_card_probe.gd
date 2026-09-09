## ps2_card_probe — renders the memory card panel for a PlayStation 2 card, so
## the 3-D save icons can be LOOKED at.
##
## Windowed, never --headless: the icons are SubViewports, and the dummy renderer
## gives back a blank image while the size oracle happily reports the right one.
##
##     "$godot" --path RetroXR --resolution 640x720 --position 20,20 \
##         res://Tools/input/ps2_card_probe.tscn
##
## PNGs land in res://probe_out/ (gitignored).
##
## The icons here are GENERATED, not lifted off a real save: a commercial PS2
## save's icon is the game's own artwork and this repo has no right to ship one.
## What the render therefore proves is the PIPELINE — that an .icn parses, builds
## a mesh, lights it, animates it and lands in a row — and not that any
## particular game's icon looks right. Point --card at a real .ps2 image for that.
extends Node

const OUT_DIR := "res://probe_out"
const PANEL := preload("res://Scenes/UI/memory_card_2d.tscn")

var _card_path := ""
## How many frames the icon gallery captures. A full turn at IDLE_SPIN_DEG needs
## a few hundred; the default is enough to see that it moves.
var _anim_frames := 48


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--card="):
			_card_path = s.substr("--card=".length())
		elif s.begins_with("--anim-frames="):
			_anim_frames = maxi(1, int(s.substr("--anim-frames=".length())))
	get_tree().create_timer(600.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var card := _card()
	if card.is_empty():
		print("[probe] no card image")
		get_tree().quit(1)
		return

	var fmt := CardFormats.for_family("playstation2")
	var saves := fmt.list_saves(card, true)
	print("[probe] card parses=%s saves=%d free=%d/%d"
		% [fmt.is_card_image(card), saves.size(), fmt.free_blocks(card),
			fmt.total_blocks(card)])
	for s: Dictionary in saves:
		var model: Dictionary = s.get("icon_model", {})
		print("[probe]   %-20s %-28s %4d %s  icon=%s"
			% [s["name"], s["title"], s["blocks"], fmt.unit_plural(),
				"none" if model.is_empty() else "%d verts, %d shapes, %d frames"
					% [model["vertex_count"], model["shape_count"],
						(model["frames"] as Array).size()]])

	var view: Control = PANEL.instantiate()
	var sv := SubViewport.new()
	sv.size = Vector2i(460, 640)
	sv.transparent_bg = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	sv.add_child(view)
	view.custom_minimum_size = Vector2(460, 640)
	view.size = Vector2(460, 640)

	view.show_name_field = true
	view.show_save_actions = true
	view.show_move_action = false
	view.show_restore_action = false
	view.sync_available = false
	await get_tree().process_frame
	view.populate("MEMORY CARD 1", saves, fmt.free_blocks(card),
		fmt.total_blocks(card), fmt)

	# The icons animate, so more than one moment is worth having.
	for shot in 3:
		for i in 24:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := sv.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		var path := "%s/ps2_card_panel_%d.png" % [OUT_DIR, shot]
		img.save_png(path)
		print("[probe] wrote %s  %dx%d" % [path, img.get_width(), img.get_height()])

	await _gallery(saves)
	get_tree().quit(0)


## A grid of icons at a size worth looking at. The panel shows them at the size
## the panel shows them at; this is for judging whether the models, the lighting
## and the morph are right, which 76 px cannot answer.
func _gallery(saves: Array) -> void:
	var with_icons: Array = []
	for s: Dictionary in saves:
		if not (s.get("icon_model", {}) as Dictionary).is_empty():
			with_icons.append(s)
	# Icons that MORPH first. Most saves carry a single shape and only turn, so a
	# grid filled in card order shows nothing of the animation path at all.
	with_icons.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int((a["icon_model"] as Dictionary)["shape_count"]) \
			> int((b["icon_model"] as Dictionary)["shape_count"]))
	if with_icons.is_empty():
		return
	const CELL := 190
	const COLS := 4
	var rows: int = mini(3, (with_icons.size() + COLS - 1) / COLS)

	var sv := SubViewport.new()
	sv.size = Vector2i(COLS * CELL, rows * (CELL + 26))
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.07, 0.11)
	bg.size = Vector2(sv.size)
	sv.add_child(bg)

	var grid := GridContainer.new()
	grid.columns = COLS
	sv.add_child(grid)
	for i in mini(with_icons.size(), COLS * rows):
		var s: Dictionary = with_icons[i]
		var col := VBoxContainer.new()
		col.custom_minimum_size = Vector2(CELL, CELL + 26)
		grid.add_child(col)
		var view := PS2IconView.new()
		view.custom_minimum_size = Vector2(CELL, CELL)
		col.add_child(view)
		view.show_model(s["icon_model"], CELL)
		var lab := Label.new()
		lab.text = str(s["title"]).substr(0, 26)
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lab.add_theme_font_size_override("font_size", 13)
		col.add_child(lab)

	# A sequence, because several of these morph and a still cannot show it.
	for f in _anim_frames:
		for i in 2:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := sv.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		img.save_png("%s/ps2_icons_%03d.png" % [OUT_DIR, f])
	print("[probe] wrote %d gallery frames  %dx%d"
		% [_anim_frames, sv.size.x, sv.size.y])


func _card() -> PackedByteArray:
	if not _card_path.is_empty():
		var real := FileAccess.get_file_as_bytes(_card_path)
		print("[probe] real card %s (%d bytes)" % [_card_path, real.size()])
		return real
	var card := PS2Card.blank_image()
	card = _add(card, "BASLUS-20488DEMO", "Ratchet & Clank", _cube_icn(), 12000)
	card = _add(card, "BESCES-50916DEMO", "Gran Turismo 4", _gem_icn(), 48000)
	card = _add(card, "BASLUS-21274DEMO", "Shadow of the Colossus", _spin_icn(), 3000)
	return card


func _add(card: PackedByteArray, dir_name: String, title: String,
		icn: PackedByteArray, payload: int) -> PackedByteArray:
	var psu := _psu(dir_name, [
		{"name": "icon.sys", "data": _icon_sys(title, "icon.icn")},
		{"name": "icon.icn", "data": icn},
		{"name": "game.dat", "data": _filler(payload)},
	])
	var out := PS2Card.insert_save(card, psu)
	if out.is_empty():
		print("[probe] FAILED to insert %s" % dir_name)
		return card
	return out


# --- containers ---------------------------------------------------------------

func _psu(dir_name: String, files: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.append_array(_psu_entry(0x8427, files.size() + 2, dir_name))
	out.append_array(_psu_entry(0x8427, 0, "."))
	out.append_array(_psu_entry(0x8427, 0, ".."))
	for f: Dictionary in files:
		var body: PackedByteArray = f["data"]
		out.append_array(_psu_entry(0x8497, body.size(), str(f["name"])))
		out.append_array(body)
		var pad := (1024 - (body.size() % 1024)) % 1024
		if pad > 0:
			var filler := PackedByteArray()
			filler.resize(pad)
			filler.fill(0)
			out.append_array(filler)
	return out


func _psu_entry(flags: int, size: int, entry_name: String) -> PackedByteArray:
	var e := PackedByteArray()
	e.resize(512)
	e.fill(0)
	e.encode_u32(0x00, flags)
	e.encode_u32(0x04, size)
	var raw := entry_name.to_ascii_buffer()
	for i in raw.size():
		e[0x40 + i] = raw[i]
	return e


func _icon_sys(title: String, icon_name: String) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(964)
	b.fill(0)
	var magic := "PS2D".to_ascii_buffer()
	for i in 4:
		b[i] = magic[i]
	b.encode_u16(0x06, 16)
	var t := title.to_ascii_buffer()
	for i in mini(t.size(), 67):
		b[0xC0 + i] = t[i]
	var n := icon_name.to_ascii_buffer()
	for slot in 3:
		for i in mini(n.size(), 63):
			b[0x104 + slot * 64 + i] = n[i]
	return b


func _filler(size: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(size)
	b.fill(0x5A)
	return b


# --- generated icons ----------------------------------------------------------

## An .icn from a list of triangles. `shapes` is one vertex array per morph
## target, all the same length; `colors` is per vertex.
func _icn(shapes: Array, colors: PackedColorArray, animated: bool) -> PackedByteArray:
	var first: PackedVector3Array = shapes[0]
	var count := first.size()
	var b := PackedByteArray()
	b.resize(20)
	b.encode_u32(0, 0x010000)
	b.encode_u32(4, shapes.size())
	b.encode_u32(8, 7)          # an uncompressed 128x128 texture
	b.encode_u32(12, 0)
	b.encode_u32(16, count)

	for v in count:
		for s in shapes.size():
			var p: Vector3 = (shapes[s] as PackedVector3Array)[v]
			var vert := PackedByteArray()
			vert.resize(8)
			vert.encode_s16(0, int(p.x * 4096.0))
			vert.encode_s16(2, int(p.y * 4096.0))
			vert.encode_s16(4, int(p.z * 4096.0))
			vert.encode_s16(6, 4096)
			b.append_array(vert)
		var n := first[v].normalized()
		var c: Color = colors[v] if v < colors.size() else Color.WHITE
		var attr := PackedByteArray()
		attr.resize(16)
		attr.encode_s16(0, int(n.x * 4096.0))
		attr.encode_s16(2, int(n.y * 4096.0))
		attr.encode_s16(4, int(n.z * 4096.0))
		attr.encode_s16(6, 4096)
		attr.encode_s16(8, int(fposmod(float(v) * 0.37, 1.0) * 4096.0))
		attr.encode_s16(10, int(fposmod(float(v) * 0.11, 1.0) * 4096.0))
		attr.encode_u32(12, int(c.r8) | (int(c.g8) << 8) | (int(c.b8) << 16) | (0x80 << 24))
		b.append_array(attr)

	# Animation header, then one frame per shape.
	var anim := PackedByteArray()
	anim.resize(20)
	anim.encode_u32(0, 1)
	anim.encode_u32(4, 60)      # frame_length
	anim.encode_float(8, 1.0)   # anim_speed
	anim.encode_u32(12, 0)      # play_offset
	anim.encode_u32(16, shapes.size() if animated else 0)
	b.append_array(anim)
	if animated:
		for s in shapes.size():
			var head := PackedByteArray()
			head.resize(8)
			head.encode_u32(0, s)
			head.encode_u32(4, 3)
			b.append_array(head)
			# A triangle in and out again, so the two shapes trade places.
			var keys := [[0.0, 1.0 if s == 0 else 0.0],
				[30.0, 0.0 if s == 0 else 1.0], [60.0, 1.0 if s == 0 else 0.0]]
			for k: Array in keys:
				var key := PackedByteArray()
				key.resize(8)
				key.encode_float(0, float(k[0]))
				key.encode_float(4, float(k[1]))
				b.append_array(key)

	b.append_array(_texture())
	return b


## A plain checker, so a UV that lands somewhere unexpected is visible rather
## than looking like a flat tint.
func _texture() -> PackedByteArray:
	var t := PackedByteArray()
	t.resize(128 * 128 * 2)
	for y in 128:
		for x in 128:
			var on := ((x / 16) + (y / 16)) % 2 == 0
			var v := 0x7FFF if on else 0x4210
			t.encode_u16((y * 128 + x) * 2, v)
	return t


func _tris(faces: Array, verts: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for f: Array in faces:
		for i in f:
			out.append(verts[int(i)])
	return out


func _cube_icn() -> PackedByteArray:
	var v := [Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1),
		Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1)]
	var faces := [[0, 1, 2], [0, 2, 3], [5, 4, 7], [5, 7, 6], [4, 0, 3], [4, 3, 7],
		[1, 5, 6], [1, 6, 2], [3, 2, 6], [3, 6, 7], [4, 5, 1], [4, 1, 0]]
	var pts := _tris(faces, v)
	var cols := PackedColorArray()
	var palette := [Color(0.90, 0.35, 0.30), Color(0.35, 0.65, 0.95),
		Color(0.95, 0.80, 0.30), Color(0.45, 0.85, 0.55),
		Color(0.75, 0.45, 0.90), Color(0.95, 0.60, 0.25)]
	for i in pts.size():
		cols.append(palette[(i / 6) % palette.size()])
	return _icn([pts], cols, false)


func _gem_icn() -> PackedByteArray:
	var v := [Vector3(0, 1.6, 0), Vector3(-1, 0, -1), Vector3(1, 0, -1),
		Vector3(1, 0, 1), Vector3(-1, 0, 1), Vector3(0, -1.6, 0)]
	var faces := [[0, 1, 2], [0, 2, 3], [0, 3, 4], [0, 4, 1],
		[5, 2, 1], [5, 3, 2], [5, 4, 3], [5, 1, 4]]
	var pts := _tris(faces, v)
	var cols := PackedColorArray()
	for i in pts.size():
		cols.append(Color(0.35, 0.75, 0.95).lerp(Color(0.95, 0.95, 1.0),
			float((i / 3) % 8) / 8.0))
	return _icn([pts], cols, false)


## Two shapes, so the morph path is exercised rather than only the static one.
func _spin_icn() -> PackedByteArray:
	var tall := [Vector3(-0.7, -1.4, -0.7), Vector3(0.7, -1.4, -0.7),
		Vector3(0.7, 1.4, -0.7), Vector3(-0.7, 1.4, -0.7),
		Vector3(-0.7, -1.4, 0.7), Vector3(0.7, -1.4, 0.7),
		Vector3(0.7, 1.4, 0.7), Vector3(-0.7, 1.4, 0.7)]
	var flat := [Vector3(-1.5, -0.5, -1.5), Vector3(1.5, -0.5, -1.5),
		Vector3(1.5, 0.5, -1.5), Vector3(-1.5, 0.5, -1.5),
		Vector3(-1.5, -0.5, 1.5), Vector3(1.5, -0.5, 1.5),
		Vector3(1.5, 0.5, 1.5), Vector3(-1.5, 0.5, 1.5)]
	var faces := [[0, 1, 2], [0, 2, 3], [5, 4, 7], [5, 7, 6], [4, 0, 3], [4, 3, 7],
		[1, 5, 6], [1, 6, 2], [3, 2, 6], [3, 6, 7], [4, 5, 1], [4, 1, 0]]
	var a := _tris(faces, tall)
	var b := _tris(faces, flat)
	var cols := PackedColorArray()
	for i in a.size():
		cols.append(Color(0.85, 0.75, 0.55).lerp(Color(0.45, 0.35, 0.25),
			float((i / 6) % 6) / 6.0))
	return _icn([a, b], cols, true)

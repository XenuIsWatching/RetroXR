## Renders BsxPackContents2D against the real packs, to PNG, so the list can be
## LOOKED at — Shift-JIS titles are the half a headless run cannot vouch for.
## Windowed, not --headless: the dummy renderer returns a blank image.
##
## Run: godot --path RetroXR --resolution 320x240 --position 20,20 \
##        res://Tools/cores/bsx_pack_render_probe.tscn
extends Node

const SHOT_SIZE := Vector2i(420, 480)


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[render] TIMEOUT")
		get_tree().quit(1))
	await _run()


func _run() -> void:
	var dir := RomLibrary.rom_dir_for_system("satellaview")
	var d := DirAccess.open(dir)
	if d == null:
		print("[render] SKIP: no satellaview folder")
		get_tree().quit(0)
		return
	var packs: Array[String] = []
	for f: String in d.get_files():
		if BsxPack.is_pack_path(f):
			packs.append(dir.path_join(f))
	packs.sort()
	if packs.is_empty():
		print("[render] SKIP: no packs")
		get_tree().quit(0)
		return

	DirAccess.make_dir_recursive_absolute("res://probe_out")
	for p: String in packs:
		await _shoot(p)
	# And a blank, so the empty-pack wording is seen too rather than assumed.
	await _shoot_blank()
	print("[render] done")
	get_tree().quit(0)


func _shoot(path: String) -> void:
	var data := FileAccess.get_file_as_bytes(path)
	await _render(path.get_file().get_basename(),
		BsxPack.programmes_of(data), BsxPack.free_blocks(data),
		"pack_" + path.get_file().get_basename().replace(" ", "_"))


func _shoot_blank() -> void:
	var data := BsxPack.blank_image()
	await _render("MEMORY PACK 9",
		BsxPack.programmes_of(data), BsxPack.free_blocks(data), "pack_blank")


func _render(pack_name: String, programmes: Array, free: int, tag: String) -> void:
	var sv := SubViewport.new()
	sv.size = SHOT_SIZE
	sv.transparent_bg = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var ui := BsxPackContents2D.new()
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sv.add_child(ui)
	# _ready built the tree; populate after it is in one.
	ui.populate(pack_name, programmes, free, BsxPack.BLOCK_COUNT)

	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame

	var img := sv.get_texture().get_image()
	var out := "res://probe_out/%s.png" % tag
	img.save_png(out)
	print("[render] %s -> %s (%d programmes, %d free)" % [
		pack_name, out, programmes.size(), free])
	sv.queue_free()

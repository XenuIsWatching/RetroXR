## Renders the Satellaview stack for the documentation site.
##
## Three modes, one per deliverable, because they want different cameras and one
## of them is not 3D at all:
##
##   --mode=pack    stills of an 8M Memory Pack on its own
##   --mode=stack   a 360 turntable of Satellaview + Super Famicom + BS-X + pack
##   --mode=panel   the pack contents list, populated from a real .bs
##
## Windowed, never --headless: the dummy renderer draws a correctly sized frame
## with nothing in it, which is the one failure a size check cannot catch.
##
##     "$godot" --path RetroXR --resolution 960x720 --position 20,20 \
##         res://Tools/models/satellaview_shot_probe.tscn -- --mode=stack --out=C:/frames
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const EXPANSION_SCENE := preload("res://Scenes/Objects/expansion.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")
const SPAWN_MENU_SCENE := preload("res://Scenes/UI/spawn_menu.tscn")

## Where the hardware sits. Everything is framed around this.
const STAGE := Vector3(0, 1.0, 0)
## Frames in one revolution. 96 at 24 fps is a four second lap, which is long
## enough to read a face and short enough that nobody waits for it.
const TURN_FRAMES := 96

var out_dir := ""
var mode := "stack"
var pack_path := ""
var audit := false
var _shot := 0
var _cam: Camera3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--out="):
			out_dir = s.trim_prefix("--out=")
		elif s.begins_with("--mode="):
			mode = s.trim_prefix("--mode=")
		elif s.begins_with("--pack="):
			pack_path = s.trim_prefix("--pack=")
		elif s == "--audit":
			audit = true
	if out_dir.is_empty():
		push_error("need --out=<dir>")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	# A probe that hangs is worse than one that fails: it holds a window open on
	# a machine nobody is watching.
	get_tree().create_timer(300.0).timeout.connect(func() -> void: get_tree().quit(2))
	await _drop_the_curtain()

	match mode:
		"panel":
			await _panel()
		"menu":
			await _menu_shelf()
		"pack":
			_light()
			await _pack()
		_:
			_light()
			await _stack()
	print("[shot] mode=%s wrote %d frames to %s" % [mode, _shot, out_dir])
	get_tree().quit(0)


## The boot loading screen is welded to the camera and never comes down here,
## because the owners that raised it are the boot warm and the slot restore and
## neither runs in a probe scene. It reads as a black wedge across half the frame
## with a hard diagonal edge, and no mesh in the tree accounts for it -- an audit
## for oversized visuals finds nothing, because the curtain is the panel scene's
## own geometry welded to the camera rather than something standing in the room.
##
## Ended through the real path, one end() per registered owner, so the panel is
## torn down by the code that owns it rather than freed out from under it.
func _drop_the_curtain() -> void:
	var owners: Variant = LoadingOverlay.get("_owners")
	if owners is Dictionary:
		for o: Variant in (owners as Dictionary).keys():
			LoadingOverlay.end(o)
	# HOLD_S is a 0.25 s grace before teardown, so the panel is still up on the
	# next frame. Waiting less than that films the curtain.
	await get_tree().create_timer(0.6).timeout


## Plain lighting on a mid-grey void, matching expansion_film_probe so the two
## reels look like they came off the same bench.
func _light() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.17, 0.20)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.52, 0.58)
	env.ambient_light_energy = 0.9
	# Hung on the CAMERA, not on a WorldEnvironment node. An autoload in this
	# project already contributes one, and with two in the tree which of them wins
	# is not defined -- the symptom was half the frame rendering pure black behind
	# a hard diagonal, with no oversized mesh anywhere in the tree to blame.

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, -38, 0)
	key.light_energy = 1.5
	add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, 130, 0)
	fill.light_energy = 0.5
	add_child(fill)

	_cam = Camera3D.new()
	_cam.environment = env
	add_child(_cam)


func _look_from(pos: Vector3, at := STAGE) -> void:
	_cam.position = pos
	_cam.look_at(at, Vector3.UP)


func _wait(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _grab() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	# The viewport carries an alpha channel it never fills, and a straight save
	# writes a fully transparent PNG that every viewer paints as blank white.
	img.convert(Image.FORMAT_RGB8)
	img.save_png("%s/f%04d.png" % [out_dir, _shot])
	_shot += 1


## A pack on its own, turned far enough to read the label and see the edge.
func _pack() -> void:
	var pack := _make_pack()
	add_child(pack)
	pack.global_position = STAGE
	await _wait(30)
	# The floating GameLabel is the room's name tag, not part of the medium, and
	# at this distance it is bigger than the pack it names.
	var tag := pack.get_node_or_null("GameLabel") as Label3D
	if tag != null:
		tag.visible = false
	var views := [
		Vector3(0.075, 1.045, 0.105),
		Vector3(0.000, 1.090, 0.090),
		Vector3(-0.085, 1.030, 0.090),
	]
	for v: Vector3 in views:
		_look_from(v)
		await _wait(4)
		await _grab()


## The whole stack, assembled bottom up, then one full revolution.
func _stack() -> void:
	var sat := EXPANSION_SCENE.instantiate() as RetroExpansion
	sat.expansion_id = "satellaview"
	sat.freeze = true
	add_child(sat)
	sat.global_position = STAGE
	await _wait(24)

	var host := SYSTEM_SCENE.instantiate() as RetroSystem
	host.systemid = "super_nes"
	host.freeze = true
	add_child(host)
	host.global_position = STAGE + Vector3(0.0, 0.16, 0.0)
	await _wait(24)
	host.restore_expansion(sat)
	await _wait(12)

	# The BS-X goes where a game would, in the console's own slot.
	var bsx := EXPANSION_SCENE.instantiate() as RetroExpansion
	bsx.expansion_id = "bsx_cart"
	bsx.rom_path = pack_path
	bsx.freeze = true
	add_child(bsx)
	bsx.global_position = host.global_position + Vector3(0.0, 0.22, 0.0)
	await _wait(24)
	host.restore_expansion(bsx)
	await _wait(12)

	# And the pack goes into the well in the BS-X's roof.
	var pack := _make_pack()
	add_child(pack)
	pack.global_position = bsx.global_position + Vector3(0.0, 0.16, 0.0)
	await _wait(18)
	bsx.restore_media(pack)
	await _wait(18)

	if audit:
		_report_big(get_tree().root)
		return

	# One lap. The camera is high enough to see the pack standing out of the
	# cartridge and low enough that the base station is not just a lid.
	for i in TURN_FRAMES:
		var a: float = TAU * float(i) / float(TURN_FRAMES)
		_look_from(STAGE + Vector3(cos(a) * 0.52, 0.28, sin(a) * 0.52), STAGE + Vector3(0, 0.11, 0))
		await _wait(1)
		await _grab()


func _make_pack() -> Node3D:
	var pack := CART_SCENE.instantiate() as RetroCartridge
	pack.systemid = "satellaview"
	pack.rom_path = pack_path
	pack.game_label = pack_path.get_file().get_basename() if not pack_path.is_empty() else "MEMORY PACK"
	pack.freeze = true
	return pack


## The contents list, which is an ordinary Control and wants no 3D at all.
func _panel() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var back := ColorRect.new()
	back.color = Color(0.10, 0.11, 0.16)
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(back)

	var ui := BsxPackContents2D.new()
	ui.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	ui.custom_minimum_size = Vector2(560, 420)
	ui.size = Vector2(560, 420)
	layer.add_child(ui)
	await get_tree().process_frame

	var data := FileAccess.get_file_as_bytes(pack_path)
	ui.populate(pack_path.get_file().get_basename(),
		BsxPack.programmes_of(data),
		BsxPack.free_blocks(data),
		BsxPack.BLOCK_COUNT)
	# Deliberately NOT repositioned. BsxPackContents2D anchors itself full-rect in
	# _ready, so nudging it to a centre computed from custom_minimum_size pushes it
	# off the top of a short window -- which reads as a clipped title, not as a
	# layout bug. Size the WINDOW to the content instead.
	await _wait(8)
	await _grab()


## The Satellaview shelf out of the spawn menu, which is where a pack is minted.
##
## The real menu is instantiated and its own spawn view is asked to build the
## shelf, rather than a stand-in being drawn here: the "+ New Memory Pack" button
## only exists because _populate_cartridges_detail special-cases this systemid,
## and a mock-up of it would be a picture of a button nobody can press.
##
## Reports the button's rect so the circle can be drawn over it afterwards from
## measured coordinates instead of eyeballed ones.
func _menu_shelf() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var back := ColorRect.new()
	back.color = Color(0.07, 0.08, 0.13)
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(back)

	var menu := SPAWN_MENU_SCENE.instantiate()
	menu.visible = false
	add_child(menu)
	await _wait(30)

	var view: Variant = menu.get("_spawn_view")
	if view == null:
		push_error("the spawn menu built no spawn view")
		return

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	layer.add_child(margin)
	var vbox := VBoxContainer.new()
	margin.add_child(vbox)

	view.call("_populate_cartridges_detail", "satellaview", vbox)
	await _wait(30)

	_report_button(vbox)
	await _grab()


## Prints the on-screen rect of the mint button, in pixels.
func _report_button(n: Node) -> void:
	var b := n as Button
	if b != null and b.text.contains("New Memory Pack"):
		var r := b.get_global_rect()
		print("[rect] new_pack x=%d y=%d w=%d h=%d" % [r.position.x, r.position.y, r.size.x, r.size.y])
	for c in n.get_children():
		_report_button(c)


## Names every visual bigger than a metre, which is how you find the thing that
## is quietly filling half the frame.
func _report_big(n: Node) -> void:
	var vi := n as VisualInstance3D
	if vi != null:
		var aabb := vi.get_aabb()
		var world := vi.global_transform * aabb
		if world.size.length() > 1.0:
			print("[big] %s (%s) size=%s at %s" % [vi.get_path(), vi.get_class(), world.size, world.position])
	for c in n.get_children():
		_report_big(c)

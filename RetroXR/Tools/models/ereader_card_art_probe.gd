## Photographs a dotcode card's front, so the art the library found for it can
## be looked at rather than taken on trust.
##
##     "$godot" --path RetroXR --resolution 720x720 --position 20,20 \
##         res://Tools/models/ereader_card_art_probe.tscn -- --out=C:/dir [--card=<stem>]
##
## Windowed, never --headless: the dummy renderer draws nothing.
##
## The card is spawned the way the spawn menu spawns one -- a cartridge carrying
## the card's first strip as its rom_path -- so the art it shows is the art the
## room would show, found by the same lookup and not handed to it here.
extends Node3D

const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")

var out_dir := ""
var want := ""
var _cam: Camera3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--out="):
			out_dir = s.trim_prefix("--out=")
		elif s.begins_with("--card="):
			want = s.trim_prefix("--card=")
	if out_dir.is_empty():
		push_error("need --out=<dir>")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)

	var overlay: Node = get_node_or_null("/root/LoadingOverlay")
	if overlay != null:
		for o: Variant in overlay.call("owners"):
			overlay.call("end", o)

	_light()
	await _shoot()
	get_tree().quit(0)


func _light() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.11, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.64, 0.70)
	env.ambient_light_energy = 1.0
	we.environment = env
	add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, 24, 0)
	key.light_energy = 1.4
	add_child(key)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true


func _shoot() -> void:
	var cards := EReaderCards.cards()
	var pick := {}
	for c: Dictionary in cards:
		var key := str(c["key"])
		if want.is_empty():
			if str(c["shape"]) == EReaderCards.SHAPE_LONG_SHORT:
				pick = c
				break
		elif key.findn(want) >= 0:
			pick = c
			break
	if pick.is_empty():
		push_error("no card matched '%s'" % want)
		get_tree().quit(1)
		return

	var strips: Array = pick["strips"]
	var first := str((strips[0] as Dictionary)["path"])
	var card := CART_SCENE.instantiate() as RetroCartridge
	card.systemid = EReaderCards.SYSTEMID
	card.rom_path = first
	card.game_label = str(pick["label"])
	card.freeze = true
	add_child(card)
	card.global_position = Vector3.ZERO
	await _wait(40)

	var size := card.get_card_size()
	var art := MediaDimensions.load_label_texture(EReaderCards.SYSTEMID, first)
	print("[art] card=%s" % str(pick["key"]))
	print("[art] shape=%s portrait=%s size=%s" % [pick["shape"], pick["portrait"], size])
	print("[art] label art found: %s" % (art != null))
	if art != null:
		print("[art] art is %dx%d" % [art.get_width(), art.get_height()])

	# Square on to the printed face, framed to the card.
	var dist: float = maxf(size.x, size.y) * 1.9
	_cam.global_position = Vector3(0, 0, dist)
	_cam.look_at(Vector3.ZERO)
	await _wait(4)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/card_front.png" % out_dir)

	# And at a glance, the way it is actually read in the room.
	_cam.global_position = Vector3(dist * 0.45, dist * 0.30, dist * 0.82)
	_cam.look_at(Vector3.ZERO)
	await _wait(4)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/card_angle.png" % out_dir)
	print("[art] wrote card_front.png and card_angle.png to %s" % out_dir)


func _wait(n: int) -> void:
	for i in n:
		await get_tree().process_frame

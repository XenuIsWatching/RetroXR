## Renders a GameCube and a PlayStation side by side with their cards seated, so
## the slots and the two cards can be LOOKED at rather than asserted about.
##
## Windowed, not --headless: the dummy renderer returns a blank image.
##
##     "$godot" --path RetroXR --resolution 320x240 --position 20,20 \
##         res://Tools/input/gc_card_probe.tscn
##
## PNGs land in res://probe_out/ (gitignored). Delete this probe when the look is
## settled; it exists to answer "does a GameCube card look like a GameCube card
## next to a PlayStation one", which no assertion can.
extends Node

const OUT_DIR := "res://probe_out"


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	await _run()
	get_tree().quit(0)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var sv := SubViewport.new()
	sv.size = Vector2i(1100, 620)
	sv.own_world_3d = true
	sv.transparent_bg = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.13)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.72, 0.78)
	e.ambient_light_energy = 0.65
	env.environment = e
	sv.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46, 38, 0)
	sun.light_energy = 1.5
	sv.add_child(sun)

	var gc := _system("gamecube", Vector3(-0.20, 0, 0))
	sv.add_child(gc)
	var psx := _system("playstation", Vector3(0.20, 0, 0))
	sv.add_child(psx)

	# Let the models load and RetroSystem run its slot setup.
	for i in 30:
		await get_tree().process_frame

	print("[probe] gamecube slots=%d family=%s"
		% [gc._card_slot_count(), gc._card_family()])
	print("[probe] playstation slots=%d family=%s"
		% [psx._card_slot_count(), psx._card_family()])

	# Seat a card in every slot each machine has, the way a hand would.
	_seat(gc, "res://Scenes/Objects/media/gc_memory_card.tscn", "GAMECUBE A", 0)
	_seat(gc, "res://Scenes/Objects/media/gc_memory_card.tscn", "GAMECUBE B", 1)
	_seat(psx, "res://Scenes/Objects/media/memory_card.tscn", "PLAYSTATION", 0)

	for i in 30:
		await get_tree().process_frame

	print("[probe] gc slot A seated=%s" % [gc.get_snapped_memcard(0) != null])
	print("[probe] gc slot B seated=%s" % [gc.get_snapped_memcard(1) != null])
	print("[probe] psx slot A seated=%s" % [psx.get_snapped_memcard(0) != null])
	print("[probe] psx slot B is absent=%s" % [psx.get_snapped_memcard(1) == null])

	await _shot(sv, Vector3(0, 0.30, 0.62), Vector3(0, 0.045, 0), "both")
	await _shot(sv, Vector3(-0.20, 0.16, 0.30), Vector3(-0.20, 0.045, 0.10), "gamecube")
	await _shot(sv, Vector3(0.20, 0.16, 0.30), Vector3(0.20, 0.045, 0.10), "playstation")
	print("[probe] done")


func _system(systemid: String, at: Vector3) -> Node3D:
	var sys: Node3D = preload("res://Scenes/Objects/system.tscn").instantiate()
	sys.set("systemid", systemid)
	sys.position = at
	sys.set("freeze", true)
	return sys


func _seat(sys: Node3D, scene_path: String, label: String, slot: int) -> void:
	var card: Node3D = load(scene_path).instantiate() as Node3D
	card.set("card_label", label)
	sys.get_parent().add_child(card)
	sys.call("restore_memory_card", card, slot)


func _shot(sv: SubViewport, from: Vector3, look_at: Vector3, name: String) -> void:
	var cam := sv.get_node_or_null("ProbeCam") as Camera3D
	if cam == null:
		cam = Camera3D.new()
		cam.name = "ProbeCam"
		sv.add_child(cam)
	cam.position = from
	cam.look_at(look_at, Vector3.UP)
	# make_current() does NOT work inside a SubViewport.
	cam.current = true
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	var path := "%s/gc_card_%s.png" % [OUT_DIR, name]
	sv.get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
	print("[probe] wrote %s" % path)

## A memory card seated in a console, measured and photographed.
##
## 42 x 8 x 63.5 mm — a PlayStation card, entering on its short edge. What the
## photo has to show is how much of it stays proud of the front face: enough to
## read as a tab you could pull, not so much that it looks unplugged.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/models/memcard_geom.tscn
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const CARD_SCENE := preload("res://Scenes/Objects/media/memory_card.tscn")
const OUT_DIR := "res://probe_out/memcard"
const SHOT := Vector2i(1200, 820)

var _sub: SubViewport = null
var _cam: Camera3D = null
var _caption: Label = null
var _shot := 0


func _ready() -> void:
	get_tree().create_timer(200.0).timeout.connect(func() -> void:
		print("[mc] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_build_world()

	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = "playstation"
	sys.position = Vector3(0, 1, 0)
	sys.ignore_gravity = true
	add_child(sys)
	sys.add_to_group("spawned")
	await _wait(50)
	_hold(sys)

	var card := CARD_SCENE.instantiate() as Node3D
	card.position = Vector3(0, 1.4, 0)
	add_child(card)
	await _wait(20)
	var zone: XRToolsSnapZone = null
	for n in sys.find_children("*", "Area3D", true, false):
		var z := n as XRToolsSnapZone
		if z != null and z.name.contains("MemoryCard"):
			zone = z
	zone.pick_up_object(card)
	await _wait(40)
	_hold(card)

	var inv := sys.global_transform.affine_inverse()
	var mesh_box := _mesh_aabb(inv, card)
	print("[mc] card mesh   x %5.1f..%5.1f  y %5.1f..%5.1f  z %5.1f..%5.1f mm"
		% [mesh_box.position.x*1000, mesh_box.end.x*1000,
			mesh_box.position.y*1000, mesh_box.end.y*1000,
			mesh_box.position.z*1000, mesh_box.end.z*1000])
	print("[mc] console front face at z 125.0 mm -> %.1f mm of the card stands proud"
		% ((mesh_box.end.z - 0.125) * 1000.0))

	_build_camera()
	var focus: Vector3 = sys.global_transform * Vector3(-0.09, 0.038, 0.115)
	await _shoot(focus, Vector3(-0.55, 0.35, 1.0), 0.13,
		"PS1 memory card, 42 x 8 x 63.5 mm, seated")
	# From above rather than side on: looking along the card's width just puts the
	# console's own body between the lens and the card.
	await _shoot(focus + Vector3(0, 0, 0.02), Vector3(0.0, 1.0, 0.02), 0.15,
		"From above — 33 mm of the card is in, 30 mm stands out")
	await _shoot(sys.global_position + Vector3(0, 0.02, 0), Vector3(-0.5, 0.5, 1.0), 0.34,
		"In context on the console's front face")

	# The card by itself, at the three-quarter angle every photo of one is taken
	# from — the view to hold against a real card when judging its proportions.
	zone.drop_object()
	var loose := CARD_SCENE.instantiate() as Node3D
	loose.position = Vector3(0.6, 1.0, 0)
	add_child(loose)
	await _wait(10)
	_hold(loose)
	var box := _mesh_aabb(loose.global_transform.affine_inverse(), loose)
	print("[mc] loose card %.1f x %.1f x %.1f mm"
		% [box.size.x * 1000, box.size.y * 1000, box.size.z * 1000])
	await _shoot(loose.global_position, Vector3(-0.45, 0.75, 0.9), 0.085,
		"The card alone — 42 mm across, 63.5 mm along, 8 mm thick")

	print("[mc] wrote %d shots to %s" % [_shot, ProjectSettings.globalize_path(OUT_DIR)])
	get_tree().quit(0)


func _mesh_aabb(inv: Transform3D, root: Node) -> AABB:
	var acc := AABB()
	var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false) + [root]:
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.visible:
			continue
		var a: AABB = (inv * mi.global_transform) * mi.get_aabb()
		acc = a if first else acc.merge(a)
		first = false
	return acc


func _shoot(focus: Vector3, dir: Vector3, size: float, caption: String) -> void:
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = size
	_cam.global_position = focus + dir.normalized() * 0.7
	_cam.look_at(focus, Vector3.UP)
	_caption.text = caption
	for i in range(2):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	_sub.get_texture().get_image().save_png("%s/shot%d.png" % [OUT_DIR, _shot])
	_shot += 1


func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.13)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.80, 0.82, 0.88)
	e.ambient_light_energy = 0.9
	env.environment = e
	add_child(env)
	for spec in [[Vector3(-38, -28, 0), 2.0], [Vector3(-12, 150, 0), 0.7]]:
		var light := DirectionalLight3D.new()
		light.rotation_degrees = spec[0]
		light.light_energy = spec[1]
		add_child(light)


func _build_camera() -> void:
	_sub = SubViewport.new()
	_sub.size = SHOT
	_sub.own_world_3d = false
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sub)
	_cam = Camera3D.new()
	_sub.add_child(_cam)
	_cam.current = true
	var bar := ColorRect.new()
	bar.color = Color(0, 0, 0, 0.62)
	bar.position = Vector2(0, SHOT.y - 74)
	bar.size = Vector2(SHOT.x, 74)
	_sub.add_child(bar)
	_caption = Label.new()
	_caption.position = Vector2(22, SHOT.y - 62)
	_caption.add_theme_font_size_override("font_size", 21)
	_caption.add_theme_color_override("font_color", Color(1, 1, 1))
	_sub.add_child(_caption)


func _hold(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var rb := n as RigidBody3D
		if rb != null:
			rb.freeze = true
			rb.linear_velocity = Vector3.ZERO


func _wait(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

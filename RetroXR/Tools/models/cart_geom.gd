## Renders a seated NES cartridge next to its own collision volumes.
##
## The cart's pointer box is its own body grown 20 mm in x and z, which leaves it
## standing 1.9 mm above the deck (95.9 mm against the deck's 94.0) across a
## 149 x 161 mm footprint — most of the console's top face. Aim anywhere in that
## footprint and the cart answers before the shell does.
##
## Measure a ROTATED box by putting every corner through its transform. Reading
## the unrotated size around the moved origin says the cart is 161 mm tall
## standing on end, which is how this was first misdiagnosed.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/models/cart_geom.tscn
##
## Windowed, not --headless: the dummy renderer hands back a blank image.
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")
const OUT_DIR := "res://probe_out/cart_geom"
const SHOT := Vector2i(1100, 800)

var _sub: SubViewport = null
var _cam: Camera3D = null
var _caption: Label = null
var _shot := 0


func _ready() -> void:
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("[cg] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_build_world()

	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = "nes"
	sys.model_id = "nes"
	sys.position = Vector3(0, 1, 0)
	sys.ignore_gravity = true
	add_child(sys)
	sys.add_to_group("spawned")
	await _wait(40)

	var cart := CART_SCENE.instantiate() as RetroCartridge
	cart.systemid = "nes"
	cart.game_label = "PROBE"
	cart.position = Vector3(0, 1.4, 0)
	add_child(cart)
	cart.add_to_group("spawned")
	await _wait(20)
	sys.restore_cartridge(cart)
	await _wait(40)
	sys.set_lid_angle_deg(105.0)
	await _wait(30)

	_build_camera()
	CollisionDebug.set_enabled(self, true)
	await _wait(5)
	_hide_spheres()
	_paint(cart, Color(1.0, 0.85, 0.1))     # the cart's own volumes, in amber
	_measure(sys, cart)
	await _wait(3)

	var focus := Vector3(0, 1.05, 0)
	await _side(focus, "NES with a cart seated — AMBER is the cartridge's own collision")
	await _side_at(focus, 90.0, "Side on: the amber top edge clears the deck by 1.9 mm")
	await _side_at(focus, 55.0, "It is the cart + 20 mm, spanning most of the deck: 149 x 161 mm")
	_ortho(false)
	await _orbit(focus, 35.0, 18.0, 0.45,
		"So most aims at the top face reach the cart before the shell")

	print("[cg] wrote %d shots to %s" % [_shot, ProjectSettings.globalize_path(OUT_DIR)])
	get_tree().quit(0)


## The snap zones' reach spheres are the largest volumes here and they drown the
## boxes this is about.
func _hide_spheres() -> void:
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		var overlay := node as MeshInstance3D
		if overlay == null or not overlay.name.begins_with("CollisionDebugShape"):
			continue
		var body := overlay.get_parent() as CollisionObject3D
		if body == null:
			continue
		var oid: int = overlay.get_meta(&"owner_id", 0)
		if body.shape_owner_get_shape_count(oid) == 0:
			continue
		overlay.visible = body.shape_owner_get_shape(oid, 0) is BoxShape3D


## Every corner through the transform, then the bounds — a box that is ROTATED
## cannot be measured by putting its unrotated size around its moved origin.
func _measure(sys: Node3D, cart: Node3D) -> void:
	var inv := sys.global_transform.affine_inverse()
	for root: Node in [cart, sys]:
		var stack: Array[Node] = [root]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			for c in n.get_children():
				stack.append(c)
			var body := n as CollisionObject3D
			if body == null:
				continue
			for oid_raw in body.get_shape_owners():
				var oid := int(oid_raw)
				for i in body.shape_owner_get_shape_count(oid):
					var sh := body.shape_owner_get_shape(oid, i)
					if not (sh is BoxShape3D):
						continue
					var t: Transform3D = inv * body.global_transform 						* body.shape_owner_get_transform(oid)
					var e: Vector3 = (sh as BoxShape3D).size * 0.5
					var out := AABB(t * Vector3(-e.x, -e.y, -e.z), Vector3.ZERO)
					for sx in [-1.0, 1.0]:
						for sy in [-1.0, 1.0]:
							for sz in [-1.0, 1.0]:
								out = out.expand(t * Vector3(e.x * sx, e.y * sy, e.z * sz))
					print("[cg] %-16s %-18s  x %6.1f..%6.1f  y %6.1f..%6.1f  z %6.1f..%6.1f"
						% [root.name, body.name,
							out.position.x*1000, out.end.x*1000,
							out.position.y*1000, out.end.y*1000,
							out.position.z*1000, out.end.z*1000])


## Repaint one object's collision overlays so they read apart from the shell's.
func _paint(root: Node, tint: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = tint
	mat.no_depth_test = true
	mat.render_priority = 6
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		var overlay := node as MeshInstance3D
		if overlay != null and overlay.name.begins_with("CollisionDebugShape"):
			overlay.material_override = mat


func _side(focus: Vector3, caption: String) -> void:
	await _side_at(focus, 90.0, caption)


func _side_at(focus: Vector3, yaw: float, caption: String) -> void:
	_ortho(true)
	_cam.size = 0.30
	_place(focus, yaw, 0.0, 0.8)
	await _grab(caption)


func _orbit(focus: Vector3, yaw: float, pitch: float, dist: float, caption: String) -> void:
	_place(focus, yaw, pitch, dist)
	await _grab(caption)


func _ortho(on: bool) -> void:
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL if on \
		else Camera3D.PROJECTION_PERSPECTIVE
	if not on:
		_cam.fov = 40.0


func _place(focus: Vector3, yaw: float, pitch: float, dist: float) -> void:
	var ry := deg_to_rad(yaw)
	var rp := deg_to_rad(pitch)
	_cam.global_position = focus + Vector3(
		cos(rp) * sin(ry), sin(rp), cos(rp) * cos(ry)) * dist
	_cam.look_at(focus, Vector3.UP)


func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.10, 0.12)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.72, 0.74, 0.80)
	e.ambient_light_energy = 0.85
	env.environment = e
	add_child(env)
	for spec in [[Vector3(-46, -30, 0), 1.9], [Vector3(-12, 150, 0), 0.7]]:
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
	bar.color = Color(0, 0, 0, 0.6)
	bar.position = Vector2(0, SHOT.y - 78)
	bar.size = Vector2(SHOT.x, 78)
	_sub.add_child(bar)
	_caption = Label.new()
	_caption.position = Vector2(22, SHOT.y - 66)
	_caption.add_theme_font_size_override("font_size", 21)
	_caption.add_theme_color_override("font_color", Color(1, 1, 1))
	_sub.add_child(_caption)

	var legend := Label.new()
	legend.position = Vector2(22, 18)
	legend.add_theme_font_size_override("font_size", 18)
	legend.add_theme_color_override("font_color", Color(0.88, 0.90, 0.94))
	legend.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	legend.add_theme_constant_override("outline_size", 5)
	legend.text = "amber = the CARTRIDGE's own boxes\n" \
		+ "green = console body   magenta = console pointer"
	_sub.add_child(legend)


func _grab(caption: String) -> void:
	_caption.text = caption
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_sub.get_texture().get_image().save_png("%s/shot%d.png" % [OUT_DIR, _shot])
	_shot += 1


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame

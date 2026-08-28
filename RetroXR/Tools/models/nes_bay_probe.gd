## Films the NES's collision volumes while its cartridge bay flap swings.
##
## The question it answers is whether the deck's boxes leave the bay mouth OPEN
## to the front with the flap up, and whether the flap's own box plugs that mouth
## when it comes down. Both are geometry you cannot check by reading numbers.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/models/nes_bay_probe.tscn
##
## Windowed, not --headless: the dummy renderer hands back a blank image. Frames
## land in res://probe_out/nes_bay/ for encoding.
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")

const OUT_DIR := "res://probe_out/nes_bay"
## Layers the console actually puts volumes on, in the order the legend lists them.
const LEGEND_LAYERS: Array[int] = [3, 17, 20, 21]
const SHOT := Vector2i(960, 720)
const FPS := 24

## Console centre, a little above its base — everything is framed on this.
const FOCUS := Vector3(0.0, 1.05, 0.0)

var _sys: RetroSystem = null
var _sub: SubViewport = null
var _cam: Camera3D = null
var _caption: Label = null
var _frame := 0


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_build_world()

	_sys = SYSTEM_SCENE.instantiate() as RetroSystem
	_sys.systemid = "nes"
	_sys.model_id = "nes"
	_sys.position = Vector3(0, 1, 0)
	_sys.ignore_gravity = true
	add_child(_sys)
	_sys.add_to_group("spawned")
	await _wait(30)

	_report_shapes()

	var cart := CART_SCENE.instantiate() as RetroCartridge
	cart.systemid = "nes"
	cart.game_label = "PROBE"
	cart.position = Vector3(0, 1.4, 0)
	add_child(cart)
	cart.add_to_group("spawned")
	await _wait(20)
	_sys.restore_cartridge(cart)
	await _wait(40)
	_sys.set_lid_angle_deg(0.0)
	await _wait(20)

	CollisionDebug.set_enabled(self, true)
	await _wait(40)

	_build_camera()
	await _wait(10)

	# The snap zones' grab spheres are the biggest volumes here and they sit right
	# over the bay, so the boxes are unreadable beside them. Boxes first, then a
	# lap with everything on rather than a film that quietly leaves them out.
	_show_spheres(false)

	await _orbit("FLAP SHUT — the flap's box plugs the bay mouth", 0.0, 360.0, 18.0, 0.40, 72)
	await _swing("FLAP OPENING — its box swings up out of the mouth", true, 30)
	await _orbit("FLAP OPEN — the mouth is a hole in the deck, open to the front",
		0.0, 360.0, 18.0, 0.40, 72)
	await _orbit("FLAP OPEN — nothing between the front face and the cart",
		-30.0, 30.0, 5.0, 0.30, 40)

	_show_spheres(true)
	await _orbit("EVERY VOLUME — the bay's grab sphere stands 51 mm out of the shell",
		-40.0, 40.0, 16.0, 0.44, 40)
	await _swing("FLAP CLOSING — the mouth seals again", false, 30)

	print("[probe] wrote %d frames to %s" % [_frame, ProjectSettings.globalize_path(OUT_DIR)])
	get_tree().quit(0)


func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.10, 0.12)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.62, 0.64, 0.70)
	e.ambient_light_energy = 0.55
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.9
	sun.rotation_degrees = Vector3(-48, -32, 0)
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.55
	fill.rotation_degrees = Vector3(-12, 148, 0)
	add_child(fill)


## The console lives under the probe root, not inside the SubViewport: a
## SubViewport with own_world_3d strands every cable a station spawns into
## get_tree().current_scene. This one shares the world and supplies the camera
## and the readback only.
func _build_camera() -> void:
	_sub = SubViewport.new()
	_sub.size = SHOT
	_sub.own_world_3d = false
	_sub.transparent_bg = false
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sub)

	_cam = Camera3D.new()
	_cam.fov = 42.0
	_sub.add_child(_cam)
	_cam.current = true

	var box := ColorRect.new()
	box.color = Color(0, 0, 0, 0.55)
	box.position = Vector2(0, SHOT.y - 90)
	box.size = Vector2(SHOT.x, 90)
	_sub.add_child(box)

	_caption = Label.new()
	_caption.position = Vector2(20, SHOT.y - 80)
	_caption.add_theme_font_size_override("font_size", 20)
	_caption.add_theme_color_override("font_color", Color(1, 1, 1))
	_sub.add_child(_caption)

	var legend := Label.new()
	legend.position = Vector2(20, 16)
	legend.add_theme_font_size_override("font_size", 17)
	legend.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	legend.add_theme_constant_override("outline_size", 5)
	legend.text = "collision layers\n"
	for layer in LEGEND_LAYERS:
		legend.text += "  %d %s\n" % [layer, _layer_name(layer)]
	legend.add_theme_color_override("font_color", Color(0.85, 0.87, 0.92))
	_sub.add_child(legend)
	for i in range(LEGEND_LAYERS.size()):
		var swatch := ColorRect.new()
		swatch.color = CollisionDebug.LAYER_COLORS.get(LEGEND_LAYERS[i], Color.WHITE)
		swatch.position = Vector2(174, 45 + i * 22)
		swatch.size = Vector2(30, 12)
		_sub.add_child(swatch)


## Hide or show every CollisionDebug overlay that is not a box.
func _show_spheres(on: bool) -> void:
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		var overlay := node as MeshInstance3D
		if overlay == null or overlay.name != "CollisionDebugShape":
			continue
		var body := overlay.get_parent() as CollisionObject3D
		if body == null:
			continue
		var oid: int = overlay.get_meta(&"owner_id", 0)
		if body.shape_owner_get_shape_count(oid) == 0:
			continue
		overlay.visible = on or body.shape_owner_get_shape(oid, 0) is BoxShape3D


func _layer_name(layer: int) -> String:
	return str(ProjectSettings.get_setting("layer_names/3d_physics/layer_%d" % layer, ""))


## Swing the camera round the console, capturing `count` frames.
func _orbit(caption: String, yaw_from: float, yaw_to: float, pitch: float,
		dist: float, count: int) -> void:
	_caption.text = caption
	for i in range(count):
		var t := float(i) / float(maxi(count - 1, 1))
		_place_camera(lerpf(yaw_from, yaw_to, t), pitch, dist)
		await _grab()


## Drive the flap end to end from head-on, capturing as it goes. Posed frame by
## frame rather than tweened so the film's timing is the frame count, not the
## wall clock.
func _swing(caption: String, opening: bool, count: int) -> void:
	_caption.text = caption
	for i in range(count):
		var t := float(i) / float(maxi(count - 1, 1))
		var amount: float = t if opening else 1.0 - t
		_sys.set_lid_angle_deg(amount * absf(RetroSystemModelNES.LID_OPEN_DEG))
		_place_camera(10.0, 16.0, 0.42)
		await _grab()


func _place_camera(yaw_deg: float, pitch_deg: float, dist: float) -> void:
	var ry := deg_to_rad(yaw_deg)
	var rp := deg_to_rad(pitch_deg)
	_cam.global_position = FOCUS + Vector3(
		cos(rp) * sin(ry), sin(rp), cos(rp) * cos(ry)) * dist
	_cam.look_at(FOCUS, Vector3.UP)


func _grab() -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := _sub.get_texture().get_image()
	img.save_png("%s/f%04d.png" % [OUT_DIR, _frame])
	_frame += 1


## Print every shape the console ended up with, so the film has numbers beside it.
func _report_shapes() -> void:
	for path in ["CollisionShape3D", "PointerArea"]:
		var node := _sys.get_node_or_null(path)
		if node == null:
			continue
		var body := (node if node is CollisionObject3D else node.get_parent()) as CollisionObject3D
		if body == null:
			continue
		print("[probe] %s — layer %d" % [body.name, body.collision_layer])
		for child in body.get_children():
			var cs := child as CollisionShape3D
			if cs == null or not (cs.shape is BoxShape3D):
				continue
			var size: Vector3 = (cs.shape as BoxShape3D).size
			print("[probe]   %-12s size %6.1f x %5.1f x %6.1f mm   at %7.1f, %6.1f, %7.1f mm"
				% [cs.name, size.x * 1000.0, size.y * 1000.0, size.z * 1000.0,
					cs.position.x * 1000.0, cs.position.y * 1000.0, cs.position.z * 1000.0])


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame

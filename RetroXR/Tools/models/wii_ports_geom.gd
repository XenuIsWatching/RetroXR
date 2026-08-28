## Draws the Wii's rear sockets to scale, against a hand and against the TV's.
##
## The phono row on a television uses a 60 mm reach; this panel was cut to 25 and
## 30 mm because at 60 the sockets swallowed each other. The question this answers
## is whether the cure went too far — so the same drawing carries a 125 mm hand
## sphere and, for comparison, a ring at the 60 mm the TV still uses.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/models/wii_ports_geom.tscn
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const OUT_DIR := "res://probe_out/wii_ports"
const SHOT := Vector2i(1200, 820)

const REACH := Color(0.25, 1.0, 0.45)         # the socket's own grab_distance
const TV_REF := Color(1.0, 0.35, 0.85)        # what a phono socket on the TV uses
const HAND := Color(0.35, 0.8, 1.0)           # a VR hand's grab sphere

var _sub: SubViewport = null
var _cam: Camera3D = null
var _caption: Label = null
var _rings: Node3D = null
var _shot := 0


func _ready() -> void:
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("[wp] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_build_world()

	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = "wii"
	sys.model_id = "wii"
	sys.position = Vector3(0, 1, 0)
	sys.ignore_gravity = true
	add_child(sys)
	sys.add_to_group("spawned")
	await _wait(60)
	_hold(sys)

	var zones: Array = []
	for node in sys.find_children("*", "Area3D", true, false):
		var zone := node as XRToolsSnapZone
		if zone != null:
			zones.append(zone)
			print("[wp] %-18s reach %5.1f mm at %v"
				% [zone.name, zone.grab_distance * 1000.0, zone.global_position])

	_rings = Node3D.new()
	add_child(_rings)
	_build_camera()

	# Centre on the rear cluster: whichever zones sit furthest back.
	var focus := Vector3.ZERO
	var count := 0
	for z in zones:
		var zone := z as XRToolsSnapZone
		if sys.to_local(zone.global_position).z < 0.0:
			focus += zone.global_position
			count += 1
	focus = focus / maxf(float(count), 1.0)

	# Looking FORWARD from behind the machine, and down from above it.
	for view in [Vector3(0, 0, 1), Vector3(0, -1, 0)]:
		_clear()
		for z in zones:
			var zone := z as XRToolsSnapZone
			if sys.to_local(zone.global_position).z >= 0.0:
				continue
			_ring(zone.global_position, zone.grab_distance, view, REACH)
			_ring(zone.global_position, 0.060, view, TV_REF)
		_ring(focus + Vector3(0.05, 0.06, -0.06), 0.125, view, HAND)
		_look(focus, view, 0.30)
		await _grab("Wii rear sockets — green is their real reach, magenta the TV's 60 mm")

	print("[wp] wrote %d shots to %s" % [_shot, ProjectSettings.globalize_path(OUT_DIR)])
	get_tree().quit(0)


func _ring(centre: Vector3, radius: float, view: Vector3, tint: Color) -> void:
	var n := view.normalized()
	var u := n.cross(Vector3.UP)
	if u.length() < 0.01:
		u = n.cross(Vector3.RIGHT)
	u = u.normalized()
	var v := n.cross(u).normalized()
	var mesh := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = tint
	mat.no_depth_test = true
	mat.render_priority = 8
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
	for i in range(81):
		var a := TAU * float(i) / 80.0
		mesh.surface_add_vertex(centre + (u * cos(a) + v * sin(a)) * radius)
	mesh.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rings.add_child(mi)


func _clear() -> void:
	for child in _rings.get_children():
		_rings.remove_child(child)
		child.queue_free()


func _look(focus: Vector3, dir: Vector3, size: float) -> void:
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = size
	_cam.global_position = focus - dir.normalized() * 0.9
	_cam.look_at(focus, Vector3.UP if absf(dir.normalized().y) < 0.9 else Vector3.BACK)


func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.10, 0.12)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.80, 0.82, 0.88)
	e.ambient_light_energy = 1.05
	env.environment = e
	add_child(env)
	for spec in [[Vector3(-40, -150, 0), 1.7], [Vector3(-25, 20, 0), 0.9]]:
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

	var legend := Label.new()
	legend.position = Vector2(22, 18)
	legend.add_theme_font_size_override("font_size", 19)
	legend.add_theme_color_override("font_color", Color(0.9, 0.92, 0.96))
	legend.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	legend.add_theme_constant_override("outline_size", 5)
	legend.text = "green   = this socket's reach\n" \
		+ "magenta = 60 mm, what the TV's phono sockets use\n" \
		+ "blue    = a VR hand's grab sphere, r 125 mm"
	_sub.add_child(legend)


func _grab(caption: String) -> void:
	_caption.text = caption
	for i in range(2):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	_sub.get_texture().get_image().save_png("%s/shot%d.png" % [OUT_DIR, _shot])
	_shot += 1


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


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame

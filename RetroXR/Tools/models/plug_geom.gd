## Draws the collision around a television's three composite sockets to scale.
##
## The sockets sit 18 mm apart. Each socket's reach sphere is 60 mm in radius and
## each seated plug's pointer sphere is 32 mm, so every volume swallows both its
## neighbours several times over. Any rule that picks between them is picking
## between overlapping guesses.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/models/plug_geom.tscn
##
## Each sphere is drawn as ONE circle in the view plane, which in an orthographic
## view IS its silhouette. CollisionDebug's own wireframes are far too dense to
## read six overlapping spheres through.
extends Node3D

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")
const CABLE_SCENE := preload("res://Scenes/Objects/cables/composite_cable.tscn")
const OUT_DIR := "res://probe_out/plug_geom"
const SHOT := Vector2i(1200, 820)

const SOCKET_TINT := Color(1.0, 0.35, 0.85)   # the port's reach sphere
const PLUG_TINT := Color(1.0, 0.82, 0.10)     # the seated plug's pointer sphere

var _sub: SubViewport = null
var _cam: Camera3D = null
var _caption: Label = null
var _rings: Node3D = null
var _shot := 0


func _ready() -> void:
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("[pg] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_build_world()

	var tv := TV_SCENE.instantiate() as Node3D
	tv.position = Vector3(0, 1, 0)
	add_child(tv)
	tv.add_to_group("spawned")
	# Hold everything still. The rings below are baked into world space, so a set
	# that is still falling leaves them hanging where it used to be — which is
	# exactly what made the first render look like the spheres sat too high.
	_hold(tv)
	await _wait(50)

	var ports: Array[RcaPort] = []
	for pname in ["CompositePort", "AudioLIn", "AudioRIn"]:
		var port := tv.get_node_or_null(pname) as RcaPort
		if port != null:
			ports.append(port)

	var cable := CABLE_SCENE.instantiate() as Node3D
	cable.position = Vector3(0, 1, -0.6)
	add_child(cable)
	cable.add_to_group("spawned")
	await _wait(40)
	_hold(cable)
	var plugs: Array[RcaPlug] = []
	for node in cable.find_children("*", "Node3D", true, false):
		var plug := node as RcaPlug
		if plug != null and not plugs.has(plug):
			plugs.append(plug)
	for i in range(mini(3, plugs.size())):
		ports[i].pick_up_object(plugs[i])
		await _wait(10)
	await _wait(30)

	for i in range(mini(3, plugs.size())):
		var pl := plugs[i] as RcaPlug
		var ar := pl.get_node_or_null("PointerArea") as CollisionObject3D
		var ac := Vector3.ZERO
		if ar != null:
			for oid_raw in ar.get_shape_owners():
				ac = ar.global_transform * ar.shape_owner_get_transform(int(oid_raw)).origin
		print("[pg] %-15s zone %v | plug %v | plug pointer %v | zone-plug dy %.1f mm"
			% [ports[i].name, ports[i].global_position, pl.global_position, ac,
				(ports[i].global_position.y - pl.global_position.y) * 1000.0])
		var jack := ports[i].get_node_or_null("RcaJack") as Node3D
		if jack != null:
			print("[pg]     socket mesh (RcaJack) at %v" % jack.global_position)

	_rings = Node3D.new()
	add_child(_rings)
	_build_camera()

	var focus: Vector3 = ports[1].global_position

	# Straight at the back panel: the sockets' own plane.
	_draw(ports, plugs, Vector3(0, 0, 1))
	_look(focus, Vector3(0, 0, 1), 0.20)
	await _grab("Back panel, to scale — sockets 18 mm apart, spheres 120 and 64 mm across")

	# Along the row, which is the aim that fails.
	_draw(ports, plugs, Vector3(-1, 0, 0))
	_look(focus, Vector3(-1, 0, 0), 0.20)
	await _grab("Along the row: every sphere contains both its neighbours")

	print("[pg] wrote %d shots to %s" % [_shot, ProjectSettings.globalize_path(OUT_DIR)])
	get_tree().quit(0)


## Freeze every rigid body in a subtree so nothing drifts while we draw.
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
			rb.angular_velocity = Vector3.ZERO


## One circle per sphere, in the plane facing the camera.
func _draw(ports: Array, plugs: Array, view: Vector3) -> void:
	for child in _rings.get_children():
		child.queue_free()
	for i in range(ports.size()):
		var port := ports[i] as RcaPort
		_ring(port.global_position, port.grab_distance, view, SOCKET_TINT)
		if i < plugs.size():
			var plug := plugs[i] as RcaPlug
			var area := plug.get_node_or_null("PointerArea") as CollisionObject3D
			if area != null:
				for oid_raw in area.get_shape_owners():
					var oid := int(oid_raw)
					for k in area.shape_owner_get_shape_count(oid):
						var sh := area.shape_owner_get_shape(oid, k)
						if sh is SphereShape3D:
							_ring(area.global_transform
								* area.shape_owner_get_transform(oid).origin,
								(sh as SphereShape3D).radius, view, PLUG_TINT)


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
	for i in range(65):
		var a := TAU * float(i) / 64.0
		mesh.surface_add_vertex(centre + (u * cos(a) + v * sin(a)) * radius)
	mesh.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rings.add_child(mi)


func _look(focus: Vector3, dir: Vector3, size: float) -> void:
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = size
	_cam.global_position = focus - dir.normalized() * 0.9
	_cam.look_at(focus, Vector3.UP)


func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.10, 0.12)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.78, 0.80, 0.86)
	e.ambient_light_energy = 1.0
	env.environment = e
	add_child(env)
	for spec in [[Vector3(-40, -150, 0), 1.7], [Vector3(-15, 20, 0), 0.8]]:
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
	legend.text = "magenta = socket reach, r 60 mm\n" \
		+ "amber   = seated plug pointer, r 32 mm\n" \
		+ "sockets are 18 mm apart"
	_sub.add_child(legend)


func _grab(caption: String) -> void:
	_caption.text = caption
	for i in range(2):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	_sub.get_texture().get_image().save_png("%s/shot%d.png" % [OUT_DIR, _shot])
	_shot += 1


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame

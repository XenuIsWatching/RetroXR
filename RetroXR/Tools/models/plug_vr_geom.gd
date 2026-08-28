## Draws, to scale, what a VR hand can and cannot grab of an RCA plug.
##
## VR pickup takes whatever overlaps a sphere on the hand, on layers 3 and 19
## only. A loose plug is on layer 3 and is grabbed by its own 25 mm sphere; the
## moment a socket takes it the plug moves to layer 17 and disappears from the
## hand's reach, leaving the socket's own 60 mm sphere as the whole affordance.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/models/plug_vr_geom.tscn
##
## Each sphere is one circle in the view plane, which in an orthographic view is
## exactly its silhouette.
extends Node3D

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")
const CABLE_SCENE := preload("res://Scenes/Objects/cables/composite_cable.tscn")
const OUT_DIR := "res://probe_out/plug_vr_geom"
const SHOT := Vector2i(1200, 820)

const GRABBABLE := Color(0.25, 1.0, 0.45)     # the hand's mask reaches this
const INERT := Color(0.55, 0.57, 0.62)        # present, but invisible to the hand
const HAND := Color(0.35, 0.8, 1.0)           # the hand's own grab sphere

var _sub: SubViewport = null
var _cam: Camera3D = null
var _caption: Label = null
var _rings: Node3D = null
var _shot := 0
var _grab_mask := 0


func _ready() -> void:
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("[vv] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_grab_mask = XRToolsFunctionPickup.DEFAULT_GRAB_MASK
	_build_world()

	var tv := TV_SCENE.instantiate() as Node3D
	tv.position = Vector3(0, 1, 0)
	add_child(tv)
	await _wait(45)
	_hold(tv)

	var cable := CABLE_SCENE.instantiate() as Node3D
	cable.position = Vector3(0, 1, -0.6)
	add_child(cable)
	await _wait(40)
	_hold(cable)

	var plugs: Array[RcaPlug] = []
	for node in cable.find_children("*", "Node3D", true, false):
		var plug := node as RcaPlug
		if plug != null and not plugs.has(plug):
			plugs.append(plug)

	var ports: Array[RcaPort] = []
	for pname in ["CompositePort", "AudioLIn", "AudioRIn"]:
		var port := tv.get_node_or_null(pname) as RcaPort
		if port != null:
			ports.append(port)

	_rings = Node3D.new()
	add_child(_rings)
	_build_camera()

	for i in range(mini(3, plugs.size())):
		ports[i].pick_up_object(plugs[i])
		await _wait(10)
	await _wait(30)
	_hold(cable)

	# In PROFILE, on one seated plug. Viewed down its own axis a sphere is just a
	# circle wherever it sits; only a side elevation shows whether it is centred on
	# the body. The cross marks the plug's ORIGIN, which is not its middle.
	var side: Vector3 = ports[0].global_transform.basis.x.normalized()
	var body_mid: Vector3 = ports[0].global_transform * Vector3(0, 0, 0.013)
	_clear()
	_plug_rings(plugs[0], side)
	_cross(plugs[0].global_position, 0.006, side, Color(1, 1, 1))
	_look(body_mid, side, 0.10)
	await _grab("One seated plug in profile — spheres on the body, cross = its origin")

	# SOCKETED — the plug has left the hand's mask; the socket is all there is.
	var focus: Vector3 = ports[1].global_position
	_clear()
	for i in range(ports.size()):
		_ring(ports[i].global_position, ports[i].grab_distance, Vector3(0, 0, 1),
			_tint(ports[i].collision_layer))
		if i < plugs.size():
			_plug_rings(plugs[i], Vector3(0, 0, 1))
	_ring(focus + Vector3(0.02, 0.09, 0.04), 0.125, Vector3(0, 0, 1), HAND)
	_look(focus, Vector3(0, 0, 1), 0.34)
	await _grab("SOCKETED — plug moved to layer 17 (grey); only the socket is grabbable")

	# Along the row, which is where the overlap costs you. Rolled a few degrees off
	# the axis on purpose: dead on, all three circles project onto each other and
	# read as one, which is true but shows nothing.
	var along := Vector3(-1, 0, 0.30).normalized()
	_clear()
	for i in range(ports.size()):
		_ring(ports[i].global_position, ports[i].grab_distance, along,
			_tint(ports[i].collision_layer))
		if i < plugs.size():
			_plug_rings(plugs[i], along)
	_ring(focus + Vector3(0.0, 0.085, 0.10), 0.125, along, HAND)
	_look(focus, along, 0.34)
	await _grab("Near enough along the row — the three socket spheres almost coincide")

	print("[vv] wrote %d shots to %s" % [_shot, ProjectSettings.globalize_path(OUT_DIR)])
	get_tree().quit(0)


## A small cross, for marking a point that has no volume of its own.
func _cross(at: Vector3, arm: float, view: Vector3, tint: Color) -> void:
	var n := view.normalized()
	var u := n.cross(Vector3.UP).normalized()
	var v := n.cross(u).normalized()
	for axis in [u, v]:
		var mesh := ImmediateMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = tint
		mat.no_depth_test = true
		mat.render_priority = 9
		mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
		mesh.surface_add_vertex(at - axis * arm)
		mesh.surface_add_vertex(at + axis * arm)
		mesh.surface_end()
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		_rings.add_child(mi)


## Every collision sphere a plug carries, tinted by whether the hand sees it.
func _plug_rings(plug: RcaPlug, view: Vector3) -> void:
	for node in plug.find_children("*", "CollisionObject3D", true, false) + [plug]:
		var body := node as CollisionObject3D
		if body == null:
			continue
		for oid_raw in body.get_shape_owners():
			var oid := int(oid_raw)
			for k in body.shape_owner_get_shape_count(oid):
				var sh := body.shape_owner_get_shape(oid, k)
				if not (sh is SphereShape3D):
					continue
				_ring(body.global_transform * body.shape_owner_get_transform(oid).origin,
					(sh as SphereShape3D).radius, view, _tint(body.collision_layer))


func _tint(layer: int) -> Color:
	return GRABBABLE if (layer & _grab_mask) != 0 else INERT


func _clear() -> void:
	for child in _rings.get_children():
		_rings.remove_child(child)
		child.queue_free()


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
	legend.text = "green = a VR hand can grab it (layers 3, 19)\n" \
		+ "grey  = collision the hand cannot see\n" \
		+ "blue  = the hand's own grab sphere, r 125 mm"
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

## The Wii's two rear connectors seated, in profile, with every volume drawn.
##
## Same treatment as the composite plug: a side elevation is the only view that
## shows whether a sphere sits on the thing it represents, because down the axis
## a sphere is a circle wherever it is.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/models/wii_seated_geom.tscn
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const SENSOR_BAR := preload("res://Scenes/Objects/system_models/wii/sensor_bar.tscn")
const AV_CABLE := preload("res://Scenes/Objects/system_models/wii/wii_av_cable.tscn")
const OUT_DIR := "res://probe_out/wii_seated"
const SHOT := Vector2i(1200, 820)

const REACH := Color(0.25, 1.0, 0.45)     # the socket's grab_distance
const GRAB := Color(1.0, 0.82, 0.10)      # the plug's own grab sphere
const POINT := Color(0.70, 0.72, 0.78)    # the plug's pointer sphere
const ORIGIN := Color(1, 1, 1)

var _sub: SubViewport = null
var _cam: Camera3D = null
var _caption: Label = null
var _rings: Node3D = null
var _shot := 0


func _ready() -> void:
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[ws] TIMEOUT")
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

	var bar := SENSOR_BAR.instantiate() as Node3D
	bar.position = Vector3(0.4, 1, -0.4)
	add_child(bar)
	var cable := AV_CABLE.instantiate() as Node3D
	cable.position = Vector3(-0.4, 1, -0.4)
	add_child(cable)
	await _wait(120)

	var sensor_port := _zone(sys, "SensorBarPort")
	var av_port := _zone(sys, "AvMultiOut")
	var seated: Array = []
	# Search the whole probe tree, not the peripheral: a cable is parented to the
	# current scene rather than to the object that spawned it, so the sensor bar's
	# plug is our sibling and never appears under the bar.
	for pair in [[sensor_port, self], [av_port, self]]:
		var port := pair[0] as XRToolsSnapZone
		var src := pair[1] as Node
		if port == null:
			continue
		var tried := 0
		for node in src.find_children("*", "Node3D", true, false):
			var pick := node as XRToolsPickable
			if pick == null:
				continue
			tried += 1
			if not port.can_preview(pick):
				print("[ws] %s refused %s (groups %s)"
					% [port.name, pick.name, str(pick.get_groups())])
				continue
			port.pick_up_object(pick)
			await _wait(15)
			if InteractionResolver.held_pickable(port) != null:
				seated.append([port, pick])
				break
		if tried == 0:
			print("[ws] %s: no pickables found under %s" % [port.name, src.name])
	_hold(bar)
	_hold(cable)
	await _wait(20)

	_rings = Node3D.new()
	add_child(_rings)
	_build_camera()

	for entry in seated:
		var port := entry[0] as XRToolsSnapZone
		var plug := entry[1] as XRToolsPickable
		_measure(port, plug)
		var side: Vector3 = port.global_transform.basis.x.normalized()
		_clear()
		_ring(port.global_position, port.grab_distance, side, REACH)
		_spheres(plug, side)
		_cross(plug.global_position, 0.005, side, ORIGIN)
		_look(_visible_centre(plug), side, 0.16)
		await _grab("%s + %s in profile — green socket reach, amber grab, grey pointer"
			% [port.name, plug.name])

	print("[ws] wrote %d shots to %s" % [_shot, ProjectSettings.globalize_path(OUT_DIR)])
	get_tree().quit(0)


func _zone(root: Node, wanted: String) -> XRToolsSnapZone:
	for node in root.find_children("*", "Area3D", true, false):
		if node.name == wanted:
			return node as XRToolsSnapZone
	return null


## Where the connector's own visible geometry actually is.
func _visible_centre(plug: Node3D) -> Vector3:
	var acc := AABB()
	var first := true
	for node in plug.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.visible:
			continue
		var a: AABB = mi.global_transform * mi.get_aabb()
		acc = a if first else acc.merge(a)
		first = false
	return plug.global_position if first else acc.get_center()


func _measure(port: XRToolsSnapZone, plug: XRToolsPickable) -> void:
	var inv := port.global_transform.affine_inverse()
	var vc: Vector3 = inv * _visible_centre(plug)
	print("[ws] %-16s socket reach %5.1f mm | plug visible centre z %6.1f mm"
		% [port.name, port.grab_distance * 1000.0, vc.z * 1000.0])
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
				var c: Vector3 = inv * (body.global_transform
					* body.shape_owner_get_transform(oid).origin)
				print("[ws]    %-14s r %5.1f mm at z %6.1f mm  (off visible centre %+.1f)"
					% [body.name, (sh as SphereShape3D).radius * 1000.0,
						c.z * 1000.0, (c.z - vc.z) * 1000.0])


func _spheres(plug: Node3D, view: Vector3) -> void:
	for node in plug.find_children("*", "CollisionObject3D", true, false) + [plug]:
		var body := node as CollisionObject3D
		if body == null:
			continue
		var tint := POINT if body.name == "PointerArea" else GRAB
		for oid_raw in body.get_shape_owners():
			var oid := int(oid_raw)
			for k in body.shape_owner_get_shape_count(oid):
				var sh := body.shape_owner_get_shape(oid, k)
				if sh is SphereShape3D:
					_ring(body.global_transform * body.shape_owner_get_transform(oid).origin,
						(sh as SphereShape3D).radius, view, tint)


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
	_cam.look_at(focus, Vector3.UP)


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
	legend.text = "green = socket reach   amber = plug grab\n" \
		+ "grey  = plug pointer   cross = plug origin"
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

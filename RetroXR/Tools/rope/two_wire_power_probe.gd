extends Node3D

const CORD_STANDARD := preload("res://Scenes/Objects/cables/nema_1_15_to_c7_cord.tscn")
const CORD_POLARIZED := preload("res://Scenes/Objects/cables/nema_1_15_polarized_to_c7_polarized_cord.tscn")
const PORT_STANDARD := preload("res://Scenes/Objects/cables/iec_c8_port.tscn")
const PORT_POLARIZED := preload("res://Scenes/Objects/cables/iec_c8_polarized_port.tscn")
const GROUNDED_CORD := preload("res://Scenes/Objects/cables/power_cord.tscn")
const WALL_PORT := preload("res://Scenes/Objects/cables/power_port.tscn")
const NEMA_STANDARD := preload("res://Scenes/Objects/cables/nema_1_15_plug.res")
const NEMA_POLARIZED := preload("res://Scenes/Objects/cables/nema_1_15_polarized_plug.res")
const C7_STANDARD := preload("res://Scenes/Objects/cables/iec_c7_plug.res")
const C7_POLARIZED := preload("res://Scenes/Objects/cables/iec_c7_polarized_plug.res")
const C8_STANDARD := preload("res://Scenes/Objects/cables/iec_c8_inlet.res")
const C8_POLARIZED := preload("res://Scenes/Objects/cables/iec_c8_polarized_inlet.res")

const OUT_REL := "../build_out/two_wire_power_cords"

var viewport: SubViewport
var camera: Camera3D
var failures := 0
var standard_cord: Node3D
var polarized_cord: Node3D
var cord_inlets: Node3D
var gallery: Node3D


func _ready() -> void:
	var out := ProjectSettings.globalize_path("res://%s" % OUT_REL)
	DirAccess.make_dir_recursive_absolute(out)
	_build_stage()
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	_run_checks()
	_shape_probe_cord(standard_cord)
	_shape_probe_cord(polarized_cord)
	(standard_cord.get_node("VerletRope") as Node).process_mode = Node.PROCESS_MODE_DISABLED
	(polarized_cord.get_node("VerletRope") as Node).process_mode = Node.PROCESS_MODE_DISABLED
	await _shoot(out,"two_wire_cords_overview",Vector3(0,0.08,1.78),Vector3(0,0.03,0),48.0)
	standard_cord.visible = false; polarized_cord.visible = false; cord_inlets.visible = false
	gallery.visible = true
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 0.13
	await _shoot(out,"nema_1_15_comparison",Vector3(-0.15,0,0.20),Vector3(-0.15,0,0),30.0)
	await _shoot(out,"c7_c8_comparison",Vector3(0.125,0,0.22),Vector3(0.125,0,0),30.0)
	print("[two-wire-power-probe] %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	get_tree().quit(failures)


func _build_stage() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(1200,800)
	viewport.own_world_3d = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	camera = Camera3D.new()
	camera.near = 0.025
	viewport.add_child(camera)
	camera.current = true

	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.045,0.050,0.065)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.76,0.80,0.92)
	env.ambient_light_energy = 0.85
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.environment = env
	add_child(world)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42,-24,0)
	key.light_color = Color(1.0,0.84,0.68)
	key.light_energy = 2.5
	key.shadow_enabled = true
	add_child(key)
	var fill := OmniLight3D.new()
	fill.position = Vector3(0,0.55,0.55)
	fill.light_color = Color(0.48,0.65,1.0)
	fill.light_energy = 2.2
	fill.omni_range = 3.0
	add_child(fill)

	standard_cord = CORD_STANDARD.instantiate()
	polarized_cord = CORD_POLARIZED.instantiate()
	add_child(standard_cord)
	add_child(polarized_cord)
	_pose_cord(standard_cord,0.74)
	_pose_cord(polarized_cord,0.08)

	# The matching appliance inlets sit beside their cable ends, facing camera.
	cord_inlets = Node3D.new(); cord_inlets.name = "CordInlets"; add_child(cord_inlets)
	_add_mesh(C8_STANDARD,Vector3(0.70,0.74,0.005),cord_inlets)
	_add_mesh(C8_POLARIZED,Vector3(0.70,0.08,0.005),cord_inlets)

	# A static face-on gallery keeps the close-ups independent of rope motion.
	gallery = Node3D.new(); gallery.name = "ConnectorGallery"; gallery.visible = false; add_child(gallery)
	_add_mesh(NEMA_STANDARD,Vector3(-0.15,0.040,0),gallery)
	_add_mesh(NEMA_POLARIZED,Vector3(-0.15,-0.040,0),gallery)
	_add_mesh(C7_STANDARD,Vector3(0.095,0.040,0),gallery)
	_add_mesh(C7_POLARIZED,Vector3(0.095,-0.040,0),gallery)
	_add_mesh(C8_STANDARD,Vector3(0.155,0.040,0),gallery)
	_add_mesh(C8_POLARIZED,Vector3(0.155,-0.040,0),gallery)

	var slab := MeshInstance3D.new()
	var box := BoxMesh.new(); box.size = Vector3(1.55,0.06,0.62)
	slab.mesh = box; slab.position = Vector3(0,-0.49,-0.10)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.23,0.25,0.30); mat.roughness = 0.88
	slab.material_override = mat
	add_child(slab)


func _pose_cord(cord: Node3D, y: float) -> void:
	var wall := cord.get_node("WallPlug") as RigidBody3D
	var appliance := cord.get_node("AppliancePlug") as RigidBody3D
	wall.freeze = true; appliance.freeze = true
	wall.position = Vector3(-0.50,y,0)
	wall.rotation_degrees = Vector3(0,180,-12)
	appliance.position = Vector3(0.50,y,0)
	appliance.rotation_degrees = Vector3(0,0,12)


func _shape_probe_cord(cord: Node3D) -> void:
	var wall := cord.get_node("WallPlug") as PowerPlug
	var appliance := cord.get_node("AppliancePlug") as PowerPlug
	var rope := cord.get_node("VerletRope") as VerletRope
	# The posed gallery curve runs across world X. Use world-up for the probe so
	# its two tubes stay readable; gameplay retains the connector-local X axis.
	rope.ribbon_axis = Vector3(0,1,0)
	var from := wall.global_transform * wall.cable_anchor
	var to := appliance.global_transform * appliance.cable_anchor
	var target_length := rope.segment_count*rope.segment_length
	# Solve the sag that uses the rope's full rest length, then resample the curve
	# by arc length. Equal-length particles let the constraint solver leave this
	# presentation pose smooth instead of bunching spare cable into ripples.
	var sag_lo := 0.0; var sag_hi := target_length
	for iteration in 20:
		var sag_mid := (sag_lo+sag_hi)*0.5
		if _curve_length(from,to,sag_mid) < target_length: sag_lo = sag_mid
		else: sag_hi = sag_mid
	var sag := (sag_lo+sag_hi)*0.5
	var samples := PackedVector3Array(); var lengths := PackedFloat32Array()
	var total := 0.0
	for i in 1001:
		var t := float(i)/1000.0
		var p := from.lerp(to,t)+Vector3(0,-sin(PI*t)*sag,0)
		if i > 0: total += p.distance_to(samples[-1])
		samples.append(p); lengths.append(total)
	var points := PackedVector3Array()
	for i in rope.segment_count+1:
		var wanted := total*float(i)/float(rope.segment_count)
		var at := 1
		while at < lengths.size()-1 and lengths[at] < wanted: at += 1
		var span := lengths[at]-lengths[at-1]
		var alpha := 0.0 if span <= 0.0 else (wanted-lengths[at-1])/span
		points.append(samples[at-1].lerp(samples[at],alpha))
	print("[two-wire-power-probe] %s pose sag=%.3f m length=%.3f m y=[%.3f, %.3f]" % [
		cord.name,sag,total,points[rope.segment_count/2].y,points[0].y])
	var restored := rope.restore_points(points)
	_check(restored,"%s accepted deterministic probe pose" % cord.name)
	if restored:
		# restore_points resets the simulation state; one explicit zero-time step
		# rolls that pose into the interpolation buffers before the probe freezes it.
		rope.step(0.0)
		rope.remesh()


func _curve_length(from: Vector3, to: Vector3, sag: float) -> float:
	var total := 0.0; var previous := from
	for i in 257:
		var t := float(i)/256.0
		var p := from.lerp(to,t)+Vector3(0,-sin(PI*t)*sag,0)
		if i > 0: total += p.distance_to(previous)
		previous = p
	return total


func _add_mesh(mesh: Mesh, at: Vector3, parent: Node3D) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	parent.add_child(mi)


func _run_checks() -> void:
	_check_cord(standard_cord,"nema_1_15_plug","iec_c7_plug")
	_check_cord(polarized_cord,"nema_1_15_polarized_plug","iec_c7_polarized_plug")
	_check(absf(_blade_width(NEMA_STANDARD,-1)-0.00635) < 0.00015,"standard neutral blade is 6.35 mm")
	_check(absf(_blade_width(NEMA_STANDARD,1)-0.00635) < 0.00015,"standard line blade is 6.35 mm")
	_check(absf(_blade_width(NEMA_POLARIZED,-1)-0.00790) < 0.00015,"polarized neutral blade is 7.90 mm")
	_check(absf(_blade_width(NEMA_POLARIZED,1)-0.00635) < 0.00015,"polarized line blade is 6.35 mm")
	_check(_has_square_key(C7_POLARIZED) and not _has_square_key(C7_STANDARD),"only C7P has the squared neutral lobe")
	_check(_has_square_key(C8_POLARIZED) and not _has_square_key(C8_STANDARD),"only C8P has the squared neutral lobe")

	var p0 := PORT_STANDARD.instantiate() as PowerPort
	var p1 := PORT_POLARIZED.instantiate() as PowerPort
	add_child(p0); add_child(p1)
	_check(p0.snap_require == "iec_c7_plug","C8 accepts ordinary C7")
	_check(p1.snap_require == "iec_c7_polarized_plug","C8P accepts only C7P")
	var c7 := standard_cord.get_node("AppliancePlug") as Node3D
	var c7p := polarized_cord.get_node("AppliancePlug") as Node3D
	_check(p0.can_preview(c7),"ordinary C7 previews in C8")
	_check(not p1.can_preview(c7),"ordinary C7 is rejected by C8P")
	_check(p1.can_preview(c7p),"C7P previews in C8P")
	_check(not p0.can_preview(c7p),"C7P is rejected by ordinary C8")
	p0.queue_free(); p1.queue_free()

	var grounded := GROUNDED_CORD.instantiate() as Node3D
	grounded.visible = false
	add_child(grounded)
	_check((grounded.get_node("VerletRope") as VerletRope).ribbon_count == 1,"existing grounded cord remains single-jacket")
	_check((grounded.get_node("WallPlug") as PowerPlug).connector_group == "nema_5_15_plug","existing grounded wall group is unchanged")
	_check((grounded.get_node("AppliancePlug") as PowerPlug).connector_group == "iec_c13_plug","existing grounded appliance group is unchanged")

	# A two-prong plug into a grounded wall outlet, which is what a real 5-15R
	# takes: the same two blade slots, ground hole left empty. Asserted in both
	# directions, because the value of the rule is the half it still refuses.
	var outlet := WALL_PORT.instantiate() as PowerPort
	var two_slot := WALL_PORT.instantiate() as PowerPort
	two_slot.accepted_plug = "nema_1_15_plug"
	add_child(outlet); add_child(two_slot)
	var nema1 := standard_cord.get_node("WallPlug") as Node3D
	var nema1p := polarized_cord.get_node("WallPlug") as Node3D
	var nema5 := grounded.get_node("WallPlug") as Node3D
	_check(outlet.snap_require == "nema_5_15_plug","a bare PowerPort is a 5-15R")
	_check(outlet.can_preview(nema1),"a plain 1-15P goes into a 5-15R")
	_check(outlet.can_preview(nema1p),"a polarized 1-15P goes into a 5-15R")
	_check(outlet.can_preview(nema5),"a 5-15P still goes into a 5-15R")
	_check(not outlet.can_preview(c7),"a C7 is still refused by a 5-15R")
	_check(not two_slot.can_preview(nema5),"a 5-15P is still refused by a two-slot outlet")
	_check(two_slot.can_preview(nema1),"a plain 1-15P still goes into a two-slot outlet")
	outlet.queue_free(); two_slot.queue_free()
	grounded.queue_free()

func _check_cord(cord: Node3D, wall_group: String, appliance_group: String) -> void:
	var rope := cord.get_node("VerletRope") as VerletRope
	var wall := cord.get_node("WallPlug") as PowerPlug
	var appliance := cord.get_node("AppliancePlug") as PowerPlug
	_check(rope.ribbon_count == 2,"%s uses two ribbon conductors" % cord.name)
	_check(is_equal_approx(rope.ribbon_spacing,0.0036),"%s has touching 3.6 mm centres" % cord.name)
	_check(rope.fray_segments_start == 0 and rope.fray_segments_end == 0,"%s has no exposed fray" % cord.name)
	_check(rope.mesh != null and rope.mesh.get_surface_count() == 2,"%s renders one surface per conductor" % cord.name)
	_check(rope.get_points().size() == rope.segment_count+1,"%s has a complete simulated chain" % cord.name)
	_check(wall.connector_group == wall_group and wall.is_in_group(wall_group),"%s wall-end group is correct" % cord.name)
	_check(appliance.connector_group == appliance_group and appliance.is_in_group(appliance_group),"%s appliance-end group is correct" % cord.name)


func _blade_width(mesh: ArrayMesh, side: int) -> float:
	var verts := mesh.surface_get_arrays(1)[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var lo := INF; var hi := -INF
	for v in verts:
		if signf(v.x) == float(side):
			lo = minf(lo,v.y); hi = maxf(hi,v.y)
	return hi-lo


func _has_square_key(mesh: ArrayMesh) -> bool:
	var verts := mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var inlet := mesh.get_aabb().end.z > 0.003
	var min_x := INF
	for v in verts:
		if (inlet and v.z > 0.003) or (not inlet and absf(v.z) < 0.0001):
			min_x = minf(min_x,v.x)
	var ys := PackedFloat32Array()
	for v in verts:
		if ((inlet and v.z > 0.003) or (not inlet and absf(v.z) < 0.0001)) and absf(v.x-min_x) < 0.00015:
			var unique := true
			for y in ys:
				if absf(y-v.y) < 0.0001: unique = false
			if unique: ys.append(v.y)
	return ys.size() >= 2


func _check(ok: bool, label: String) -> void:
	if ok:
		print("[two-wire-power-probe] OK: %s" % label)
	else:
		failures += 1
		push_error("[two-wire-power-probe] FAIL: %s" % label)


func _shoot(out: String, name: String, eye: Vector3, target: Vector3, fov: float) -> void:
	camera.position = eye; camera.fov = fov
	camera.look_at(target,Vector3.UP)
	for i in 35: await get_tree().process_frame
	var image := viewport.get_texture().get_image()
	if image == null:
		_check(false,"captured %s.png" % name)
		return
	var err := image.save_png(out.path_join("%s.png" % name))
	_check(err == OK,"wrote %s.png" % name)

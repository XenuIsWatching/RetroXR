## What a VR hand can actually grab of an RCA plug, loose and socketed.
##
## VR pickup does not use the interaction resolver. XRToolsFunctionPickup puts a
## sphere on the hand and takes whatever overlaps it on grab_collision_mask, so
## the only questions are which layers a plug is on in each state and how big the
## volumes are.
##
##   godot --headless --path RetroXR res://Tools/vr/plug_vr_grab.tscn
extends Node3D

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")
const CABLE_SCENE := preload("res://Scenes/Objects/cables/composite_cable.tscn")


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[vg] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	var grab_mask: int = XRToolsFunctionPickup.DEFAULT_GRAB_MASK
	print("[vg] hand grab sphere radius 0.125 m, mask %s (layers %s)"
		% [grab_mask, _layers(grab_mask)])
	print("[vg] ranged grab is disabled on both controllers in player_rig.tscn")

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

	print("[vg] ---- LOOSE (cable lying on the floor) ----")
	_report(plugs[0], null, grab_mask)

	var port := tv.get_node_or_null("CompositePort") as RcaPort
	port.pick_up_object(plugs[0])
	await _wait(30)
	print("[vg] ---- SOCKETED ----")
	_report(plugs[0], port, grab_mask)

	get_tree().quit(0)


func _report(plug: RcaPlug, port: RcaPort, grab_mask: int) -> void:
	var grabbable := false
	for node in plug.find_children("*", "CollisionObject3D", true, false) + [plug]:
		var body := node as CollisionObject3D
		if body == null:
			continue
		var seen := (body.collision_layer & grab_mask) != 0
		if seen:
			grabbable = true
		for oid_raw in body.get_shape_owners():
			var oid := int(oid_raw)
			for k in body.shape_owner_get_shape_count(oid):
				print("[vg]   %-14s %-14s layer %-8s %-18s hand can grab: %s"
					% [body.name, body.get_class(), _layers(body.collision_layer),
						_shape(body.shape_owner_get_shape(oid, k)), seen])
	if port != null:
		var pseen := (port.collision_layer & grab_mask) != 0
		print("[vg]   %-14s %-14s layer %-8s %-18s hand can grab: %s"
			% [port.name, "RcaPort(zone)", _layers(port.collision_layer),
				"sphere r=%d mm" % roundi(port.grab_distance * 1000.0), pseen])
		if pseen:
			grabbable = true
	print("[vg]   => the hand %s reach this plug"
		% ["CAN" if grabbable else "CANNOT"])


func _shape(sh: Shape3D) -> String:
	if sh is SphereShape3D:
		return "sphere r=%d mm" % roundi((sh as SphereShape3D).radius * 1000.0)
	if sh is BoxShape3D:
		var s: Vector3 = (sh as BoxShape3D).size * 1000.0
		return "box %d x %d x %d" % [roundi(s.x), roundi(s.y), roundi(s.z)]
	if sh is CylinderShape3D:
		return "cyl r=%d h=%d" % [roundi((sh as CylinderShape3D).radius * 1000.0),
			roundi((sh as CylinderShape3D).height * 1000.0)]
	return sh.get_class()


func _layers(mask: int) -> String:
	var out := PackedStringArray()
	for bit in 32:
		if mask & (1 << bit):
			out.append(str(bit + 1))
	return ",".join(out) if out.size() > 0 else "none"


func _hold(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var rb := n as RigidBody3D
		if rb != null:
			rb.freeze = true


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame

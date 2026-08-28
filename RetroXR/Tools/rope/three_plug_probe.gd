## Can you point at the middle one of three plugs seated side by side?
##
## A television's composite input is three phono sockets 18 mm apart, and each is
## a snap zone with a 60 mm reach radius — so every socket's sphere swallows both
## its neighbours whole. Whether you can pick out the one you are aiming at
## depends entirely on whether the resolver treats that sphere as a surface.
##
##   godot --headless --path RetroXR res://Tools/rope/three_plug_probe.tscn
extends Node3D

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")
const CABLE_SCENE := preload("res://Scenes/Objects/cables/composite_cable.tscn")

var _hand: Node3D = null
var _fail := 0


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[3p] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	_hand = Node3D.new()
	_hand.add_to_group("desktop_hand")
	add_child(_hand)

	var tv := TV_SCENE.instantiate() as Node3D
	tv.position = Vector3(0, 1, 0)
	add_child(tv)
	tv.add_to_group("spawned")
	await _wait(50)

	var ports: Array[RcaPort] = []
	for name in ["CompositePort", "AudioLIn", "AudioRIn"]:
		var port := tv.get_node_or_null(name) as RcaPort
		if port != null:
			ports.append(port)
	if ports.size() != 3:
		print("[3p] FAIL: found %d of 3 ports" % ports.size())
		get_tree().quit(1)
		return
	for port in ports:
		print("[3p] port %-16s at %v  reach radius %.3f m"
			% [port.name, port.global_position, port.grab_distance])

	var cable := CABLE_SCENE.instantiate() as Node3D
	cable.position = Vector3(0, 1, -0.6)
	add_child(cable)
	cable.add_to_group("spawned")
	await _wait(40)

	var plugs: Array[RcaPlug] = []
	for node in cable.find_children("*", "Node3D", true, false):
		var plug := node as RcaPlug
		if plug != null and not plugs.has(plug):
			plugs.append(plug)
	print("[3p] cable carries %d plugs" % plugs.size())
	if plugs.size() < 3:
		print("[3p] FAIL: need 3 plugs")
		get_tree().quit(1)
		return

	# One plug into each socket.
	for i in range(3):
		ports[i].pick_up_object(plugs[i])
		await _wait(10)
	await _wait(30)

	var seated := 0
	for port in ports:
		if InteractionResolver.held_pickable(port) != null:
			seated += 1
	print("[3p] %d of 3 sockets are holding a plug" % seated)
	if seated != 3:
		print("[3p] FAIL: could not seat all three")
		get_tree().quit(1)
		return

	# Square on. A centred ray enters its own plug's sphere at full radius, so it
	# always gets there first — this is the easy case and proves little.
	print("[3p] --- what collision does a seated plug have? ---")
	for i in range(3):
		var any := false
		for n in plugs[i].find_children("*", "CollisionObject3D", true, false) + [plugs[i]]:
			var body := n as CollisionObject3D
			if body == null:
				continue
			for oid_raw in body.get_shape_owners():
				for k in body.shape_owner_get_shape_count(int(oid_raw)):
					any = true
					var sh := body.shape_owner_get_shape(int(oid_raw), k)
					var desc := sh.get_class()
					if sh is BoxShape3D:
						var sz: Vector3 = (sh as BoxShape3D).size
						desc = "box %.0f x %.0f x %.0f mm" % [sz.x*1000, sz.y*1000, sz.z*1000]
					elif sh is CylinderShape3D:
						desc = "cyl r=%.0f h=%.0f mm" % [
							(sh as CylinderShape3D).radius*1000, (sh as CylinderShape3D).height*1000]
					elif sh is SphereShape3D:
						desc = "sphere r=%.0f mm" % ((sh as SphereShape3D).radius*1000)
					print("[3p]   %-14s %-14s layer=%-8d %-22s mask=%s"
						% [ports[i].name, body.name, body.collision_layer, desc,
							(body.collision_layer & InteractionResolver.QUERY_MASK) != 0])
		if not any:
			print("[3p]   %-14s (no collision shapes at all)" % ports[i].name)

	print("[3p] --- square on, 250 mm behind the set ---")
	for i in range(3):
		_aim(ports[i], plugs[i], Vector3.ZERO)

	# Obliquely along the row, which is how one plug ends up BEHIND another from
	# where you are standing. Now a neighbour's sphere is entered first.
	print("[3p] --- obliquely along the row (a plug behind a plug) ---")
	for i in range(3):
		_aim(ports[i], plugs[i], Vector3(0.34, 0.06, 0.0))
	for i in range(3):
		_aim(ports[i], plugs[i], Vector3(-0.34, -0.05, 0.0))

	print("[3p] %s" % ("PASS — each aim reaches its own plug" if _fail == 0
		else "%d FAILURE(S)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


## Aim square at one seated plug and see which one the resolver hands back.
func _aim(port: RcaPort, plug: RcaPlug, offset: Vector3) -> void:
	var at: Vector3 = plug.global_position
	# The sockets face out of the back of the set, along the port's local +Z.
	var out: Vector3 = port.global_transform.basis.z.normalized()
	var from: Vector3 = at + out * 0.25 + offset
	var target := InteractionResolver.resolve_desktop(
		get_world_3d().direct_space_state, from, at - out * 0.05, _hand)

	var who := "-"
	if is_instance_valid(target.action_node):
		who = String(target.action_node.name)
	var got_right := target.action_node == port or target.highlight_node == plug
	if not got_right:
		_fail += 1
	print("[3p] aim at %-16s off=%-5.2f -> %-14s %-16s  %s"
		% [port.name, offset.x, target.kind, who, "ok" if got_right else "WRONG"])


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame

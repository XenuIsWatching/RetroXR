## What the desktop resolver returns for a fixed set of aims.
##
## The cases that matter are the ones a line-of-sight rule changes: pointing at a
## machine through a wall, pointing at a control its own shell encloses, and
## pointing where a disabled grab zone hangs in the air. Two previous attempts at
## occlusion shipped and were reverted; this exists so the third can be diffed
## against the second rather than argued about.
##
##   godot --headless --path RetroXR res://Tools/vr/interaction_resolver_probe.tscn
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")
const KEYBOARD_SCENE := preload("res://Scenes/Objects/peripherals/retro_keyboard.tscn")

var _hand: Node3D = null
var _nes: RetroSystem = null
var _atari: RetroSystem = null
var _wall: StaticBody3D = null
var _trace := false


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[ir] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	_hand = Node3D.new()
	_hand.add_to_group("desktop_hand")
	add_child(_hand)

	_nes = _spawn("nes", "nes", Vector3(0, 1, 0))
	_atari = _spawn("atari_2600", "atari_2600", Vector3(4, 1, 0))
	await _wait(40)

	var cart := CART_SCENE.instantiate() as RetroCartridge
	cart.systemid = "nes"
	cart.game_label = "PROBE"
	cart.position = Vector3(0, 1.4, 0)
	add_child(cart)
	cart.add_to_group("spawned")
	await _wait(20)
	_nes.restore_cartridge(cart)
	await _wait(40)

	# A plain world-layer slab, exactly what a room's walls and furniture are.
	_wall = StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 2.0, 0.1)
	col.shape = box
	_wall.add_child(col)
	add_child(_wall)
	_wall.global_position = Vector3(0, 1.0, 0.30)
	_hide_wall()
	await _wait(10)

	for a in OS.get_cmdline_user_args():
		if a == "--trace":
			_trace = true
	print("[ir] case | kind | node | grab | activate")

	_nes.set_lid_angle_deg(105.0)
	await _wait(20)
	_aim("nes flap OPEN, front at cart height", Vector3(0, 1.075, 0.60), Vector3(0, 0, -1))
	_aim("nes flap OPEN, straight down on top", Vector3(0, 1.60, 0.02), Vector3(0, -1, 0))

	_nes.set_lid_angle_deg(0.0)
	await _wait(20)
	_aim("nes flap SHUT, front at cart height", Vector3(0, 1.075, 0.60), Vector3(0, 0, -1))
	_aim("nes flap SHUT, straight down on top", Vector3(0, 1.60, 0.02), Vector3(0, -1, 0))
	_aim("nes flap SHUT, down 45 from front  ", Vector3(0, 1.42, 0.36), Vector3(0, -1, -1))
	_aim("nes POWER button                   ", Vector3(-0.0737, 1.0189, 0.60), Vector3(0, 0, -1))
	_aim("nes RESET button                   ", Vector3(-0.0437, 1.0189, 0.60), Vector3(0, 0, -1))
	_aim("nes body, front                    ", Vector3(0.10, 1.02, 0.60), Vector3(0, 0, -1))

	_aim("atari POWER lever                  ", Vector3(3.875, 1.071, 0.40), Vector3(0, 0, -1))
	_aim("atari body, front                  ", Vector3(4.0, 1.02, 0.40), Vector3(0, 0, -1))

	# The case the bounded enclosure rule exists for: the key field sits INSIDE the
	# board's own grab body, so nearest-hit alone hands you the keyboard.
	var kb := KEYBOARD_SCENE.instantiate() as Node3D
	add_child(kb)
	kb.global_position = Vector3(-4, 1, 0)
	if "freeze" in kb:
		kb.set("freeze", true)
	await _wait(30)
	var field := kb.find_child("*KeyField*", true, false) as Node3D
	if field == null:
		for n in kb.find_children("*", "Area3D", true, false):
			if n is KeyboardKeyField:
				field = n
	if field != null:
		var above: Vector3 = field.global_position + Vector3(0, 0.30, 0)
		_aim("keyboard KEY FIELD from above     ", above, Vector3(0, -1, 0))
	else:
		print("[ir] keyboard KEY FIELD           | (not found)")
	_aim("keyboard body, from the side       ",
		kb.global_position + Vector3(0.40, 0.02, 0), Vector3(-1, 0, 0))
	# The key field is a slab over 95% of the board, so every face except the top
	# must still hand you the board — otherwise it cannot be picked up at all.
	_aim("keyboard from UNDERNEATH           ",
		kb.global_position + Vector3(0, -0.30, 0), Vector3(0, 1, 0))
	_aim("keyboard from BEHIND               ",
		kb.global_position + Vector3(0, 0.016, -0.30), Vector3(0, 0, 1))
	_aim("keyboard PALM REST                 ",
		kb.global_position + Vector3(0, 0.016, 0.30), Vector3(0, 0, -1))

	# The whole point. Same aims, with a wall in the way.
	_show_wall()
	await _wait(10)
	_aim("THROUGH WALL: nes body             ", Vector3(0.10, 1.02, 0.60), Vector3(0, 0, -1))
	_aim("THROUGH WALL: nes POWER button     ", Vector3(-0.0737, 1.0189, 0.60), Vector3(0, 0, -1))
	_aim("THROUGH WALL: empty air            ", Vector3(1.5, 1.02, 0.60), Vector3(0, 0, -1))
	_hide_wall()

	get_tree().quit(0)


func _spawn(sysid: String, model: String, pos: Vector3) -> RetroSystem:
	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = sysid
	sys.model_id = model
	sys.position = pos
	sys.ignore_gravity = true
	add_child(sys)
	sys.add_to_group("spawned")
	return sys


func _show_wall() -> void:
	_wall.collision_layer = 1
	_wall.set_collision_layer_value(1, true)


func _hide_wall() -> void:
	_wall.collision_layer = 0


func _aim(label: String, from: Vector3, dir: Vector3) -> void:
	var to := from + dir.normalized() * 1.5
	var t := InteractionResolver.resolve_desktop(
		get_world_3d().direct_space_state, from, to, _hand)
	var who := "-"
	if is_instance_valid(t.action_node):
		who = String(t.action_node.name)
	print("[ir] %s | %-14s | %-18s | %s | %s"
		% [label, t.kind, who, t.can_grab, t.can_activate])
	if _trace:
		_walk(from, to)


## Every hit along the ray in order, with what the resolver makes of it.
func _walk(from: Vector3, to: Vector3) -> void:
	var exclude: Array[RID] = []
	for i in range(8):
		var q := PhysicsRayQueryParameters3D.create(
			from, to, InteractionResolver.QUERY_MASK)
		q.collide_with_bodies = true
		q.collide_with_areas = true
		q.exclude = exclude
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty():
			print("[ir]      %d. (nothing)" % i)
			return
		var node := hit.collider as Node
		print("[ir]      %d. %-22s %-14s layer=%d d=%.3f %s"
			% [i, node.name, node.get_class(),
				(node as CollisionObject3D).collision_layer,
				from.distance_to(hit.position),
				"AREA" if node is Area3D else "body"])
		exclude.append(hit.rid)


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame

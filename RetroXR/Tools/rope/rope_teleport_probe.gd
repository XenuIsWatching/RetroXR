extends Node

## A cord hung between two mounts, then one mount TELEPORTED across the room — the
## restore case, where a socket takes a plug that was laid out somewhere else.
## Asserts the cord is laid out afresh between the new positions rather than being
## dragged there through everything in between.
##
##   godot --headless --path RetroXR res://Tools/rope/rope_teleport_probe.tscn

const CABLE := preload("res://Scenes/Objects/cables/cable.tscn")
const JUMP := Vector3(1.6, 0.0, 1.2)

var _fail := 0


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void: get_tree().quit(1))

	var lead: Node3D = CABLE.instantiate()
	add_child(lead)
	lead.global_position = Vector3(0, 1.0, 0)
	await get_tree().process_frame

	var rope := lead.get_node("VerletRope") as VerletRope
	var a := Node3D.new()
	a.position = Vector3(0, 1.0, 0)
	add_child(a)
	var b := Node3D.new()
	b.position = Vector3(0.3, 1.0, 0)
	add_child(b)
	rope.start_node = a
	rope.end_node = b
	# Long enough that it can still reach after the jump, so the test is about WHERE
	# the cord is and not about whether it can span the gap at all.
	rope.set_rope_length(3.0)
	rope._init_points()

	for i in range(180):
		await get_tree().physics_frame
	print("[tele] settled, cord sits %.2f m off the line between its mounts"
		% _off_axis(rope, a, b))

	b.global_position += JUMP
	await get_tree().physics_frame
	# A re-laid cord is seeded straight from one mount to the other, so every
	# particle is ON that line. A dragged one still has its whole length back where
	# the mount used to be.
	var off := _off_axis(rope, a, b)
	print("[tele] 1 tick after the jump: %.2f m off that line" % off)
	if off > 0.1:
		_bad("cord was dragged, not re-laid (%.2f m off the line)" % off)

	for i in range(120):
		await get_tree().physics_frame
	print("[tele] settled again, %.2f m off the line" % _off_axis(rope, a, b))
	print("[tele] %s" % ("PASS" if _fail == 0 else "%d FAILURE(S)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


## Mean distance of the cord's particles from the straight segment joining its two
## mounts.
func _off_axis(rope: VerletRope, a: Node3D, b: Node3D) -> float:
	var p0 := a.global_position
	var p1 := b.global_position
	var pts := rope.get_points()
	var sum := 0.0
	for p in pts:
		sum += p.distance_to(Geometry3D.get_closest_point_to_segment(p, p0, p1))
	return sum / maxi(pts.size(), 1)


func _bad(m: String) -> void:
	_fail += 1
	print("[tele] FAIL " + m)

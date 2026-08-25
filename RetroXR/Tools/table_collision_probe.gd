extends Node3D

## Does the table collide at LEG height?
##
## As inline arcade scenery it had one box over the top slab and nothing below, so
## a ray at knee height passed straight through where a leg visibly is. A render
## cannot tell the two apart — the legs were always drawn — so this asks the
## physics server directly.
##
## --no-legs disables the four leg shapes and re-asks. That leg MUST fail: a check
## that cannot go red proves nothing about the one that went green.

const TABLE := preload("res://Scenes/Objects/furniture/table.tscn")

var _fail := 0


func _ready() -> void:
	get_tree().create_timer(20.0).timeout.connect(func(): get_tree().quit(1))

	var no_legs := "--no-legs" in OS.get_cmdline_user_args()

	var table: Node3D = TABLE.instantiate()
	add_child(table)
	table.global_position = Vector3.ZERO
	table.freeze = true          # hold it still; we are asking about shapes, not physics

	if no_legs:
		for n in ["LegColFL", "LegColFR", "LegColBL", "LegColBR"]:
			(table.get_node(n) as CollisionShape3D).disabled = true

	await get_tree().physics_frame
	await get_tree().physics_frame

	var space := get_viewport().world_3d.direct_space_state

	# Each leg, struck side-on at mid-leg height. The top slab's collider spans
	# y 0.55-0.75, so a ray at 0.35 can only be stopped by a leg.
	for leg in [
		{"name": "front-left",  "z": 0.35,  "x": -0.95},
		{"name": "front-right", "z": 0.35,  "x": 0.95},
		{"name": "back-left",   "z": -0.35, "x": -0.95},
		{"name": "back-right",  "z": -0.35, "x": 0.95},
	]:
		var z: float = leg["z"]
		var x: float = leg["x"]
		var from := Vector3(x, 0.35, z + (0.6 if z > 0.0 else -0.6))
		var to := Vector3(x, 0.35, z)
		_expect(_hits(space, from, to), true, "leg %s is solid at knee height" % leg["name"])

	# Control: the gap between the legs must stay OPEN. If this hits, the probe is
	# striking the body rather than a leg and the four cases above mean nothing.
	_expect(_hits(space, Vector3(0.0, 0.35, 1.2), Vector3(0.0, 0.35, -1.2)), false,
		"the space between the legs is still open")

	# And the top is solid, as it always was.
	_expect(_hits(space, Vector3(0.0, 1.4, 0.0), Vector3(0.0, 0.6, 0.0)), true,
		"the table top is solid")

	if no_legs:
		print("[probe] --no-legs: %d failure(s) — expected 4" % _fail)
		# Inverted: with the legs off, the leg cases MUST fail.
		get_tree().quit(0 if _fail == 4 else 1)
	else:
		print("[probe] %s" % ("PASS" if _fail == 0 else "%d FAILURE(S)" % _fail))
		get_tree().quit(0 if _fail == 0 else 1)


func _hits(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 4          # the table's layer
	q.collide_with_areas = false
	return not space.intersect_ray(q).is_empty()


func _expect(got: bool, want: bool, label: String) -> void:
	if got == want:
		print("[probe] ok   %s" % label)
	else:
		_fail += 1
		print("[probe] FAIL %s (got %s, want %s)" % [label, got, want])

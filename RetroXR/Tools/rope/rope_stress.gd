## Rope stress suite — runs VerletRope through a spread of ordinary and abusive
## situations and reports objective metrics for each, so a change to the solver
## can be checked against all of them at once rather than against whichever case
## happened to be on screen.
##
##   godot --headless --path RetroXR res://Tools/rope/rope_stress.tscn
##
## Columns:
##   nan      non-finite components found in the point buffer (must be 0)
##   stretch  longest segment as a multiple of its rest length
##   squash   shortest segment as a multiple of its rest length
##   jitter   largest per-tick movement over the last JITTER_WINDOW ticks, mm
##   escape   furthest any point sits from the anchor midpoint, m
##   sleep    whether the rope parked by the end of the run
extends Node3D

const CABLE_SCENE := preload("res://Scenes/Objects/cables/cable.tscn")
const TICKS := 420
const JITTER_WINDOW := 60

## Each case: a start/end anchor offset pair, plus optional flags.
##   wall       anchors sit inside a solid block
##   floor      a slab under the cable at y = 0
##   ledge      a slab whose front edge the cable must wrap
##   free_end   no end anchor at all (the tail dangles)
##   drop       end anchor is teleported far away at tick 200
##   shake      end anchor is driven back and forth every tick
##   release    over-extended, then brought back to a normal span at tick 200
##   resize     set_rope_length() is halved at tick 200
##   nudge      nudge_point() is fired into the middle at tick 200
const CASES: Array = [
	{"name": "slack hang", "a": Vector3(-0.2, 1.2, 0), "b": Vector3(0.2, 1.2, 0)},
	{"name": "slack over floor", "a": Vector3(-0.2, 0.5, 0), "b": Vector3(0.2, 0.5, 0), "floor": true},
	{"name": "taut (span = rest)", "a": Vector3(-0.9, 1.2, 0), "b": Vector3(0.9, 1.2, 0)},
	{"name": "over-extended 1.5x", "a": Vector3(-1.35, 1.2, 0), "b": Vector3(1.35, 1.2, 0)},
	{"name": "over-extended 3x", "a": Vector3(-2.7, 1.2, 0), "b": Vector3(2.7, 1.2, 0)},
	{"name": "over-extended 20x", "a": Vector3(-18.0, 1.2, 0), "b": Vector3(18.0, 1.2, 0)},
	{"name": "coincident anchors", "a": Vector3(0, 1.2, 0), "b": Vector3(0, 1.2, 0)},
	{"name": "vertical stack", "a": Vector3(0, 1.6, 0), "b": Vector3(0, 0.4, 0)},
	{"name": "inside a wall", "a": Vector3(-0.2, 0.5, 0), "b": Vector3(0.2, 0.5, 0), "wall": true},
	{"name": "wrapped on a ledge", "a": Vector3(0, 0.78, -0.35), "b": Vector3(0, 0.10, 0.45), "ledge": true},
	{"name": "free dangling end", "a": Vector3(0, 1.6, 0), "b": Vector3(0, 1.6, 0), "free_end": true},
	{"name": "anchor teleported", "a": Vector3(-0.2, 1.2, 0), "b": Vector3(0.2, 1.2, 0), "drop": true},
	{"name": "anchor shaken hard", "a": Vector3(-0.2, 1.2, 0), "b": Vector3(0.2, 1.2, 0), "shake": true},
	{"name": "stretched then freed", "a": Vector3(-2.7, 1.2, 0), "b": Vector3(2.7, 1.2, 0), "release": true},
	{"name": "rope_length halved", "a": Vector3(-0.2, 1.2, 0), "b": Vector3(0.2, 1.2, 0), "resize": true},
	{"name": "nudged mid-span", "a": Vector3(-0.2, 1.2, 0), "b": Vector3(0.2, 1.2, 0), "nudge": true},
	{"name": "zero gravity", "a": Vector3(-0.2, 1.2, 0), "b": Vector3(0.2, 1.2, 0), "gravity": Vector3.ZERO},
	{"name": "gravity inverted 10x", "a": Vector3(-0.2, 1.2, 0), "b": Vector3(0.2, 1.2, 0),
		"gravity": Vector3(0, 98.0, 0)},
	{"name": "single segment", "a": Vector3(-0.2, 1.2, 0), "b": Vector3(0.2, 1.2, 0), "segments": 1},
	{"name": "two segments", "a": Vector3(-0.2, 1.2, 0), "b": Vector3(0.2, 1.2, 0), "segments": 2},
	{"name": "dragged through wall", "a": Vector3(-0.6, 1.2, 0), "b": Vector3(-0.3, 1.2, 0),
		"thin_wall": true, "through": true},
	{"name": "end anchor freed", "a": Vector3(-0.2, 1.2, 0), "b": Vector3(0.2, 1.2, 0), "kill_end": true},
]

var _idx := -1
var _tick := 0
var _rope: Node = null
var _a: Node3D = null
var _b: Node3D = null
var _case: Dictionary = {}
var _prev: PackedVector3Array = []
var _jitter := 0.0
var _lines := PackedStringArray()
var _x := 0.0


func _ready() -> void:
	print("[stress] %-22s %4s %8s %7s %9s %8s %6s" % [
		"case", "nan", "stretch", "squash", "jitter mm", "escape m", "sleep"])
	_next_case()


func _next_case() -> void:
	_idx += 1
	if _idx >= CASES.size():
		for l in _lines:
			print(l)
		get_tree().quit(0)
		return
	_case = CASES[_idx]
	_tick = 0
	_jitter = 0.0
	# Cases are laid out along X so their collision geometry cannot interact.
	_x += 60.0
	var base := Vector3(_x, 0, 0)

	if _case.get("thin_wall", false):
		var wall := StaticBody3D.new()
		wall.collision_layer = 1
		wall.collision_mask = 0
		add_child(wall)
		var wcol := CollisionShape3D.new()
		var wbox := BoxShape3D.new()
		wbox.size = Vector3(0.04, 3.0, 3.0)
		wcol.shape = wbox
		wcol.position = base + Vector3(0, 1.0, 0)
		wall.shape_owner_add_shape(wall.create_shape_owner(wall), wbox)
		wcol.queue_free()
		wall.shape_owner_set_transform(0, Transform3D(Basis(), base + Vector3(0, 1.0, 0)))

	if _case.get("floor", false) or _case.get("wall", false) or _case.get("ledge", false):
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		add_child(body)
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		if _case.get("wall", false):
			box.size = Vector3(4, 4, 4)
			col.position = base + Vector3(0, 0.5, 0)
		elif _case.get("ledge", false):
			box.size = Vector3(1.2, 0.5, 0.8)
			col.position = base + Vector3(0, 0.5, -0.1)
		else:
			box.size = Vector3(6, 0.2, 6)
			col.position = base + Vector3(0, -0.1, 0)
		col.shape = box
		body.add_child(col)

	_a = Node3D.new()
	_a.position = base + _case["a"]
	add_child(_a)
	_b = Node3D.new()
	_b.position = base + _case["b"]
	add_child(_b)

	var inst: Node3D = CABLE_SCENE.instantiate()
	add_child(inst)
	for c in inst.get_children():
		if c is RigidBody3D:
			c.queue_free()
	_rope = inst.get_node("VerletRope")
	if _case.has("gravity"):
		_rope.gravity = _case["gravity"]
	if _case.has("segments"):
		_rope.segment_count = _case["segments"]
	_rope.start_node = _a
	_rope.end_node = null if _case.get("free_end", false) else _b
	_rope.end_anchor_offset = Vector3.ZERO
	_rope.set_process(false)
	_rope.set_physics_process(false)
	_rope._init_points()
	_prev = _rope.get_points()


func _physics_process(delta: float) -> void:
	if _rope == null:
		return
	if _case.get("shake", false):
		_b.position.x += 0.35 * (1.0 if _tick % 2 == 0 else -1.0)
	if _tick == 200:
		if _case.get("through", false):
			# Yank the anchor clean through the slab in one tick.
			_b.position += Vector3(1.2, 0, 0)
		if _case.get("kill_end", false):
			_b.queue_free()
		if _case.get("drop", false):
			_b.position += Vector3(40.0, 25.0, -18.0)
		if _case.get("release", false):
			_b.position = _a.position + Vector3(0.4, 0, 0)
		if _case.get("resize", false):
			_rope.set_rope_length(_rope.rest_length() * 0.5)
		if _case.get("nudge", false):
			_rope.nudge_point(int(_rope.segment_count / 2), Vector3(0, -3.0, 0))

	_rope.step(delta)

	var pts: PackedVector3Array = _rope.get_points()
	if _tick >= TICKS - JITTER_WINDOW and pts.size() == _prev.size():
		for i in pts.size():
			var d: float = _prev[i].distance_to(pts[i])
			if d > _jitter:
				_jitter = d
	_prev = pts
	_tick += 1
	if _tick < TICKS:
		return
	_record(pts)
	_rope.get_parent().queue_free()
	_rope = null
	_next_case()


func _record(pts: PackedVector3Array) -> void:
	var nan_count := 0
	for p in pts:
		if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
			nan_count += 1
	var rest: float = _rope.segment_length
	var longest := 0.0
	var shortest := 1e9
	for i in range(pts.size() - 1):
		var l: float = pts[i].distance_to(pts[i + 1])
		if not is_finite(l):
			continue
		longest = maxf(longest, l)
		shortest = minf(shortest, l)
	var mid: Vector3 = _a.global_position
	if is_instance_valid(_b):
		mid = (_a.global_position + _b.global_position) * 0.5
	var escape := 0.0
	for p in pts:
		if is_finite(p.x) and is_finite(p.y) and is_finite(p.z):
			escape = maxf(escape, p.distance_to(mid))
	_lines.append("[stress] %-22s %4d %8.2f %7.2f %9.2f %8.2f %6s" % [
		_case["name"], nan_count, longest / rest,
		(shortest / rest) if shortest < 1e8 else 0.0,
		_jitter * 1000.0, escape, "yes" if _rope.is_sleeping() else "no"])

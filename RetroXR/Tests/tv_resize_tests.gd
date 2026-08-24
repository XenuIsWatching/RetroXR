extends Node

## Resizing a television: where the set ends up, and what happens to whatever was
## standing on it.
##
##   godot --headless --path RetroXR res://Tests/tv_resize_tests.tscn
##   godot --headless --path RetroXR res://Tests/tv_resize_tests.tscn -- --only=park
##
## Exits non-zero on failure, so it can gate a commit.
##
## Physics runs headless — the dummy renderer stubs RENDERING, not Jolt — so the
## rider, standing and jam cases are real shape queries against real bodies, and
## the park cases are the real freeze. What is NOT checked here is how a resize
## LOOKS mid-drag; that needs a windowed probe.
##
## Every case is a rule the block's own comments claim, and most of them record a
## bug: a set that sank through its table, one that walked across the room, one
## that swallowed the object on top of it and dropped it out of the bottom, and a
## persisted 2.1x set that lifted itself again on every load.
##
## The set is measured, not assumed: tv.tscn's pickup collider is a 0.5 x 0.4 x 0.3
## box centred on the origin, so the base sits 0.2 m below it. The lowest MESH is
## a metre down — TVOptionsPanel's viewport quad — which is why several cases
## below pin the collider reading specifically.

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")

const GROUPS := ["clamp", "anchor", "riders", "carry", "standing", "jam", "park"]

## Measured from tv.tscn. A case that hardcodes a distance derives it from these.
const BOX := Vector3(0.5, 0.4, 0.3)
const BOTTOM := -0.2

var _fail := 0
var _ran := 0
var _only := ""
var _spawned: Array[Node] = []


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func():
		print("[test] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.trim_prefix("--only=")

	if _want("clamp"):
		await _test_clamp()
	if _want("anchor"):
		await _test_anchor()
	if _want("riders"):
		await _test_riders()
	if _want("carry"):
		await _test_carry()
	if _want("standing"):
		await _test_standing()
	if _want("jam"):
		await _test_jam()
	if _want("park"):
		await _test_park()

	_clear()
	print("[test] %d cases, %s" % [_ran,
		"PASS" if _fail == 0 else "%d FAILURE(S)" % _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ── The clamp ─────────────────────────────────────────────────────────────────

func _test_clamp() -> void:
	var tv := await _tv()

	tv.set_tv_scale(0.01)
	_close(tv.scale_factor, RetroTV.MIN_SCALE, "clamp/below the floor clamps up")
	tv.set_tv_scale(99.0)
	_close(tv.scale_factor, RetroTV.MAX_SCALE, "clamp/above the ceiling clamps down")
	tv.set_tv_scale(1.4)
	_close(tv.scale_factor, 1.4, "clamp/an in-range size passes through")
	_close(tv.scale.y, 1.4, "clamp/the size reaches the node")
	_clear()


# ── The anchor: a set grows in place, upward ─────────────────────────────────

func _base_y(tv: RetroTV) -> float:
	return tv.global_position.y + BOTTOM * tv.scale_factor


func _test_anchor() -> void:
	var tv := await _tv()
	tv.global_position = Vector3(0, 1, 0)
	var before := _base_y(tv)

	tv.set_tv_scale(2.0)
	_close(_base_y(tv), before, "anchor/growing holds the base still")
	_close(tv.global_position.y, 1.0 + 0.2, "anchor/the extra height goes upward")

	tv.set_tv_scale(0.5)
	_close(_base_y(tv), before, "anchor/shrinking holds the base still")

	var flat := tv.global_position
	tv.set_tv_scale(0.5)
	_ok(tv.global_position.is_equal_approx(flat),
		"anchor/re-asserting the same size moves nothing")

	_close(tv.global_position.x, 0.0, "anchor/x is untouched")
	_close(tv.global_position.z, 0.0, "anchor/z is untouched")
	_clear()

	# The persisted-size bug: a set restored at 2.1x has ALREADY been placed where
	# that size belongs, so the first _apply_scale — the one _ready makes — must
	# only put the size on the node. Correcting a scale the node never wore lifts
	# the set again on every load.
	var restored := TV_SCENE.instantiate() as RetroTV
	restored.freeze = true
	restored.scale_factor = 2.1
	restored.position = Vector3(0, 1, 0)
	add_child(restored)
	_spawned.append(restored)
	await get_tree().process_frame
	_close(restored.global_position.y, 1.0,
		"anchor/a restored size does not lift the set on load")
	_close(restored.scale.y, 2.1, "anchor/but the restored size does reach the node")
	_clear()


# ── Riders: what is standing on the set ──────────────────────────────────────

func _test_riders() -> void:
	var tv := await _tv()
	tv.global_position = Vector3(0, 1, 0)

	# The collider's bottom, not the geometry's. tv.tscn's lowest mesh is the
	# options-panel quad about a metre down; answering with that lifts the set far
	# further than it grew and starts the standing ray inside the table.
	_close(tv._local_bottom_y(), BOTTOM, "riders/the bottom is the collider's")
	_close(tv._collider_height(), BOX.y, "riders/the height is the collider's")

	var top := tv.global_position.y + BOX.y * 0.5
	var on := _box(Vector3(0, top + 0.01, 0), Vector3(0.1, 0.1, 0.1))
	var beside := _box(Vector3(1.5, top + 0.01, 0), Vector3(0.1, 0.1, 0.1))
	var under := _box(Vector3(0, tv.global_position.y - 0.5, 0), Vector3(0.1, 0.1, 0.1))
	await _settle()

	var found := tv._riders(1.0)
	_ok(found.has(on), "riders/a box resting on top is found")
	_ok(not found.has(beside), "riders/a box beside the set is not")
	_ok(not found.has(under), "riders/a box under the set is not")
	_ok(not found.has(tv), "riders/the set is not its own rider")

	# Frozen means held, parked, or seated in one of our sockets — none of which
	# wants to be shoved.
	on.freeze = true
	await _settle()
	_ok(not tv._riders(1.0).has(on), "riders/a frozen body is left alone")
	on.freeze = false

	# World geometry cannot ride anything.
	var slab := _static_box(Vector3(0.15, top + 0.01, 0), Vector3(0.1, 0.1, 0.1))
	await _settle()
	var with_static := tv._riders(1.0)
	_ok(not with_static.has(slab), "riders/a static body is not a rider")
	_ok(with_static.has(on), "riders/and the real rider is still found beside it")

	# Measured at the size passed in, not the size the set is wearing: the query
	# runs BEFORE the scale write, over the cabinet it is about to stop being.
	var high := _box(Vector3(0, tv.global_position.y + BOX.y + 0.01, 0),
		Vector3(0.1, 0.1, 0.1))
	await _settle()
	_ok(tv._riders(2.0).has(high), "riders/the query uses the size it was given")
	_ok(not tv._riders(1.0).has(high), "riders/and not the one the set is wearing")
	_clear()


# ── Carrying them ────────────────────────────────────────────────────────────

func _test_carry() -> void:
	var tv := await _tv()
	tv.global_position = Vector3(0, 1, 0)
	var top := tv.global_position.y + BOX.y * 0.5
	var rider := _box(Vector3(0, top + 0.01, 0), Vector3(0.1, 0.1, 0.1))
	await _settle()
	var was := rider.global_position.y

	# Growing swallows whatever is on top in one step, and Jolt answers a body
	# suddenly deep inside another by ejecting it through the nearest face — out
	# of the BOTTOM of the set and onto the floor. The lift is the half of the
	# placement the solver cannot do.
	tv.set_tv_scale(2.0)
	_close(rider.global_position.y, was + BOX.y,
		"carry/growing lifts the rider by the top's travel")

	# Shrinking needs no move: the set slides out from under it and gravity does
	# the rest.
	var high := rider.global_position.y
	tv.set_tv_scale(1.0)
	_close(rider.global_position.y, high, "carry/shrinking leaves the rider where it is")
	_clear()

	# But shrinking DOES need the wake, or a body asleep on the cabinet hangs in
	# the air where the set used to be.
	var tv2 := await _tv()
	tv2.global_position = Vector3(0, 1, 0)
	tv2.set_tv_scale(2.0)
	var top2 := tv2.global_position.y + BOX.y
	var sleeper := _box(Vector3(0, top2 + 0.01, 0), Vector3(0.1, 0.1, 0.1))
	await _settle()
	sleeper.sleeping = true
	tv2.set_tv_scale(1.0)
	_ok(not sleeper.sleeping, "carry/shrinking wakes a sleeping rider")

	tv2.set_tv_scale(2.0)
	await _settle()
	sleeper.sleeping = true
	tv2.set_tv_scale(3.0)
	_ok(not sleeper.sleeping, "carry/so does growing")
	_clear()

	# A rider freed between the query and the carry is the ordinary teardown race.
	var tv3 := await _tv()
	var gone := _box(Vector3(9, 9, 9), Vector3(0.1, 0.1, 0.1))
	var list: Array[RigidBody3D] = [gone]
	gone.free()
	tv3._carry_riders(list, 0.5)
	_ok(true, "carry/a freed rider does not take the resize with it")
	_clear()


# ── Standing on something ────────────────────────────────────────────────────

func _test_standing() -> void:
	var tv := await _tv()
	_floor(0.0)
	tv.global_position = Vector3(0, -BOTTOM, 0)
	await _settle()
	_ok(tv._is_standing_on_something(), "standing/a set on the floor is standing")

	tv.global_position = Vector3(0, 2.0, 0)
	await _settle()
	_ok(not tv._is_standing_on_something(), "standing/a set in the air is not")

	# Cast from the BASE, not the origin. A big cabinet's origin is most of a
	# metre above its feet, so an origin cast reads a 5x set as standing while it
	# is still well clear — and resizing one on the way down parks it in the air.
	tv.set_tv_scale(5.0)
	tv.global_position = Vector3(0, 0.0, 0)
	await _settle()
	_ok(not tv._is_standing_on_something(),
		"standing/a big set with its ORIGIN on the floor is not standing")

	tv.global_position = Vector3(0, -BOTTOM * 5.0, 0)
	await _settle()
	_ok(tv._is_standing_on_something(),
		"standing/the same set standing on its base is")
	_clear()


# ── Jammed into the world ────────────────────────────────────────────────────

func _test_jam() -> void:
	var tv := await _tv()
	_floor(0.0)
	tv.global_position = Vector3(0, -BOTTOM, 0)
	await _settle()

	# The box is shrunk by _JAM_DEPTH and lifted off the supporting surface, so
	# merely standing on the floor is not a jam.
	_ok(not tv._is_jammed(), "jam/resting on a surface is not a jam")

	# A wall the set only reaches once it has grown.
	_wall()
	await _settle()
	_ok(not tv._is_jammed(), "jam/a wall the set does not reach is not a jam")

	tv.set_tv_scale(2.0)
	await _settle()
	_ok(tv._is_jammed(), "jam/the same wall once the set has grown into it is")

	# Static only. A prop that has come to rest against the cabinet also shows up
	# in the query, and counting it would park the set for as long as anything is
	# leaning on it — and the solver can push a loose prop out of the way anyway.
	tv.set_tv_scale(1.0)
	_box(Vector3(BOX.x * 0.5, -BOTTOM, 0), Vector3(0.3, 0.3, 0.3))
	await _settle()
	_ok(not tv._is_jammed(), "jam/a loose prop overlapping the set is not a jam")
	_clear()


# ── Parking ──────────────────────────────────────────────────────────────────

func _test_park() -> void:
	# Standing AND jammed: the overlap has nowhere to go, so the body is parked
	# and the penetration simply allowed. A big set can clip the wall behind it;
	# that beats it walking across the room.
	var tv := await _tv(false)
	_floor(0.0)
	_wall()
	tv.global_position = Vector3(0, -BOTTOM, 0)
	await _settle()

	tv.set_tv_scale(2.0)
	_ok(tv.freeze, "park/a standing, jammed set is parked")
	_ok(tv._parked_by_resize, "park/and the park is recorded as ours")

	# Released the moment it is not needed, or a set shrunk back sits frozen at
	# 1.0x with nothing holding it there.
	tv.set_tv_scale(1.0)
	_ok(not tv.freeze, "park/shrinking clear of the wall releases the park")
	_ok(not tv._parked_by_resize, "park/and clears the record")
	_clear()

	# On open floor there is no penetration to evict, so the body is left to
	# ordinary physics — the common case, and the one where a stuck freeze would
	# be most obvious.
	var open := await _tv(false)
	_floor(0.0)
	open.global_position = Vector3(0, -BOTTOM, 0)
	await _settle()
	open.set_tv_scale(3.0)
	_ok(not open.freeze, "park/a set growing on open floor is not parked")
	_clear()

	# Held: the grab driver owns the pose, so there is nothing to park and the
	# hold's own freeze must survive.
	var held := await _tv(false)
	_floor(0.0)
	_wall()
	held.global_position = Vector3(0, -BOTTOM, 0)
	await _settle()
	held.freeze = true
	held.set_tv_scale(2.0)
	_ok(held.freeze, "park/a held set keeps the hold's freeze")
	_ok(not held._parked_by_resize, "park/and is not recorded as parked by us")
	_clear()

	await _test_park_revalidation()


func _test_park_revalidation() -> void:
	var tv := await _tv(false)
	var ground := _floor(0.0)
	_wall()
	tv.global_position = Vector3(0, -BOTTOM, 0)
	await _settle()
	tv.set_tv_scale(2.0)
	_ok(tv._parked_by_resize, "park/parked, ready to revalidate")

	# A parked body is frozen, so it has no gravity to notice with — nothing else
	# would ever tell it the floor had gone.
	for i in range(20):
		tv._release_park_if_unsupported()
	_ok(tv._parked_by_resize, "park/a still-supported park survives revalidation")

	# The set revalidates itself every frame, so the interval case has to own the
	# counter and must not await: three physics frames of the TV's own _process is
	# most of the way through an interval on its own, and the release it then makes
	# is the RIGHT one arriving before the case can look.
	ground.free()
	tv._park_check_frame = 0
	tv._release_park_if_unsupported()
	_ok(tv._parked_by_resize, "park/the release waits for its check interval")
	for i in range(RetroTV._PARK_CHECK_FRAMES):
		tv._release_park_if_unsupported()
	_ok(not tv._parked_by_resize, "park/a park over an empty floor is released")
	_ok(not tv.freeze, "park/and the set is handed back to physics")

	# Nothing to do when the freeze was never ours.
	tv.freeze = true
	for i in range(20):
		tv._release_park_if_unsupported()
	_ok(tv.freeze, "park/revalidation leaves a freeze that is not ours alone")
	_clear()


# ── Harness ──────────────────────────────────────────────────────────────────

func _want(name: String) -> bool:
	return _only.is_empty() or _only == name


func _ok(cond: bool, what: String) -> void:
	_ran += 1
	if cond:
		print("[test] ok   %s" % what)
	else:
		_fail += 1
		print("[test] FAIL %s" % what)


func _close(got: float, want: float, what: String, eps := 0.005) -> void:
	_ok(absf(got - want) < eps,
		what if absf(got - want) < eps else "%s (got %.4f, want %.4f)" % [what, got, want])


## A set in the room. Frozen by default — most cases only ask the geometry
## questions, and a falling set answers them from wherever it has got to.
func _tv(frozen := true) -> RetroTV:
	var tv := TV_SCENE.instantiate() as RetroTV
	tv.freeze = frozen
	tv.position = Vector3(0, 1, 0)
	add_child(tv)
	_spawned.append(tv)
	await get_tree().process_frame
	await get_tree().physics_frame
	return tv


## A prop. Unfrozen, because _riders skips frozen bodies, but weightless so it
## stays where the case put it.
func _box(at: Vector3, size: Vector3) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.gravity_scale = 0.0
	rb.freeze = false
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	rb.add_child(cs)
	add_child(rb)
	rb.global_position = at
	_spawned.append(rb)
	return rb


func _static_box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	add_child(body)
	body.global_position = at
	_spawned.append(body)
	return body


## Ground at the given height, on collision layer 1 — which the TV's mask
## includes, and every query in this block filters by that mask.
func _floor(top_y: float) -> StaticBody3D:
	return _static_box(Vector3(0, top_y - 0.5, 0), Vector3(20, 1, 20))


## A wall just clear of a 1.0x set and well inside a 2.0x one. Half the wall's own
## width has to clear half the cabinet's before the 5 cm gap starts, which is the
## sum this got wrong first time round: a wall centred one gap out from the
## cabinet's face still reaches 20 cm INTO it, and every "not jammed yet" case
## read as jammed.
const WALL := Vector3(0.5, 2.0, 2.0)


func _wall() -> StaticBody3D:
	var clear := BOX.x * 0.5 + WALL.x * 0.5 + 0.05
	return _static_box(Vector3(clear, 1.0, 0), WALL)


func _settle() -> void:
	for i in range(3):
		await get_tree().physics_frame
	await get_tree().process_frame


func _clear() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.free()
	_spawned.clear()

## VerletRope behaviour tests — what a cord does when it meets the world.
##
##     "$godot" --headless --path RetroXR res://Tests/rope_tests.tscn
##     "$godot" --headless --path RetroXR res://Tests/rope_tests.tscn -- --only=contact
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## The rope already has two BIT-EXACT oracles — `Tools/rope/rope_bench.tscn --settle`
## and `Tools/rope/rope_stress.tscn` — and they are excellent at the one thing they do:
## catching arithmetic drift. Neither can tell you whether a cord lying on a table
## corner jitters, whether one draped over a pipe falls through it, or whether a
## lead dropped on a shelf tunnels. Those are the failures a player sees, and
## nothing asserted them until this file.
##
## So the assertions here are INVARIANTS WITH TOLERANCES, never poses. Settling is
## chaotic — the bench's own settle count is a chaotic integer — so "sleeps within
## 600 ticks" is a real claim and "sleeps at tick 412" is a coin toss. Every
## threshold below was measured first and then given margin; each case prints its
## measurement next to its verdict so a near-miss is visible before it fails.
##
## The rope is driven the way the bench drives it: `set_physics_process(false)` and
## `step()` called by hand, in batches inside one physics frame so the space-state
## queries the solver issues stay legal. That makes a 600-tick case cost a few
## frames rather than ten seconds.
##
## Cases are laid out along X, `CASE_PITCH` apart, so no case's geometry can reach
## another's — the same trick `rope_stress.gd` uses.
extends Node3D

const CABLE_SCENE := preload("res://Scenes/Objects/cables/cable.tscn")
const COMPOSITE_SCENE := preload("res://Scenes/Objects/cables/composite_cable.tscn")
const CONTROLLER_CABLE_SCENE := preload("res://Scenes/Objects/cables/controller_cable.tscn")
## A whole lead — two plug bodies with a cord between them, exactly as the room
## spawns it. Used by the loose/ group, where the ends have to be free to fall.
const LEAD_SCENE := preload("res://Scenes/Objects/cables/trs_cable.tscn")

## Ticks per physics frame. The solver's world queries are only legal inside a
## physics frame, so the batch runs there rather than in a tight loop of its own.
const BATCH := 30
## The window a "has it stopped moving?" question is asked over.
const STILL_WINDOW := 60
## A settled cord may still move this much per tick when it is denied sleep.
## Measured across every contact case below, over the tail window of the awake
## hold (see _awake_residual): 0.0003 mm/tick on a flat table up to 0.07 pulled
## taut round a corner. 0.5 is ~7x the worst of them, so ordinary variation
## passes and a contact that has started fighting itself does not.
const STILL_MM := 0.5
## No contact in this suite needs a looser bound than STILL_MM. That is worth
## recording, because an earlier version of the ledge case measured 8.9 mm/tick —
## an order of magnitude above everything else — and it was tempting to write that
## down as "a heaped cord churns". It was neither: the case had pinned its far end
## in MID-AIR beyond the table edge, and a cord loaded by a point floating in space
## is not a wiring the room can contain. Anchor the same cord at floor level, where
## a socket could be, and it settles quiet.
## The corner case is the one contact measured another way — see it for why a
## long free-hanging span cannot be held awake without pumping it.

var _pass := 0
var _fail := 0
var _only := ""
var _rope: VerletRope = null
var _holder: Node3D = null
var _case_geometry: Node3D = null
var _case_slot := 0
var _last_wait_motion := 0.0


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			_only = arg.trim_prefix("--only=")
	# A test scene must never hang a headless run.
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))
	_run()


func _run() -> void:
	await _group_contact()
	await _group_handling()
	await _group_integrity()
	await _group_anchors()
	await _group_sleep()
	await _group_loose()
	await _group_edges()
	await _group_budget()
	print("[test] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ── harness ───────────────────────────────────────────────────────────────────

func _wants(group: String) -> bool:
	return _only.is_empty() or _only == group


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s%s" % [name, "  (" + detail + ")" if detail else ""])
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [name, "  — " + detail if detail else ""])


## A patch of world for one case, far enough along X to be its own universe.
func _new_case() -> Vector3:
	# Tear down the previous case instead of marching cases kilometres away from
	# the origin. Jolt uses float world coordinates; at the old 60 m pitch a full
	# run reached several kilometres and identical contacts stopped being
	# numerically identical to their focused-test counterparts.
	if is_instance_valid(_case_geometry):
		_case_geometry.free()
	_case_geometry = Node3D.new()
	add_child(_case_geometry)
	_case_slot = 1 - _case_slot
	# Alternate two nearby patches. This leaves a whole frame of separation from
	# a queued-for-deletion lead without accumulating float error across the run.
	return Vector3(float(_case_slot) * 20.0, 0.0, 0.0)


## A static box. Everything the rope collides with is built here rather than
## authored, so a case reads as its own geometry.
func _box(centre: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	_case_geometry.add_child(body)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position = centre
	body.add_child(col)
	return body


## A static cylinder, lying along X unless `upright`.
func _cylinder(centre: Vector3, radius: float, height: float, upright := false) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	_case_geometry.add_child(body)
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	col.shape = shape
	col.position = centre
	if not upright:
		col.rotation_degrees = Vector3(0, 0, 90)   # long axis along X
	body.add_child(col)
	return body


## A bare rope between two plain Node3D anchors. Plain nodes, not RigidBodies:
## the rope treats a RigidBody anchor as a PLUG and rotates it to face the cord,
## which is a different behaviour and not what most of these cases are about.
func _rope_between(a: Vector3, b: Vector3, segments := 24, seg_len := 0.06) -> VerletRope:
	_holder = Node3D.new()
	_case_geometry.add_child(_holder)
	var na := Node3D.new()
	na.position = a
	_holder.add_child(na)
	var nb := Node3D.new()
	nb.position = b
	_holder.add_child(nb)
	var rope := VerletRope.new()
	_holder.add_child(rope)
	# Solver settings copied from cable.tscn. A bare VerletRope takes the C++
	# defaults, which are softer than anything that ships, and every threshold
	# below would then be measuring a cord the room does not contain.
	rope.constraint_iterations = 8
	rope.bend_stiffness = 0.2
	rope.collision_radius = 0.0045
	rope.surface_collision_mask = 7
	rope.self_collision = true
	rope.segment_count = segments
	rope.segment_length = seg_len
	rope.start_node = na
	rope.end_node = nb
	rope.set_process(false)
	rope.set_physics_process(false)
	rope._init_points()
	_rope = rope
	return rope


## A rope with one end loose, so it can be dropped onto something.
func _rope_from(a: Vector3, toward: Vector3, segments := 24, seg_len := 0.06) -> VerletRope:
	var rope := _rope_between(a, toward, segments, seg_len)
	rope.end_node = null
	rope._init_points()
	return rope


func _drop_case() -> void:
	if is_instance_valid(_case_geometry):
		_case_geometry.free()
	elif is_instance_valid(_holder):
		_holder.free()
	_holder = null
	_case_geometry = null
	_rope = null
	await get_tree().physics_frame


## Walk an anchor to `to` over `ticks` ticks, stepping the solver as it goes —
## a hand carrying a plug. Cases use this instead of initialising the cord in a
## state no hand can produce: a straight lay THROUGH furniture leaves particles
## born inside a solid with no contact plane to escape along (measured 11 mm
## wedged into a table), and a straight lay COMPRESSED between close anchors
## buckles upward into a standing arch and sleeps there.
func _carry(rope: VerletRope, node: Node3D, to: Vector3, ticks: int) -> void:
	var stride: Vector3 = (to - node.position) / float(ticks)
	var done := 0
	while done < ticks:
		await get_tree().physics_frame
		var n: int = mini(BATCH, ticks - done)
		for i in n:
			node.position += stride
			rope.step(1.0 / 90.0)
		done += n


## Run the solver `ticks` times, in batches inside physics frames.
func _settle(ticks: int) -> void:
	var done := 0
	while done < ticks:
		await get_tree().physics_frame
		var n: int = mini(BATCH, ticks - done)
		for i in n:
			_rope.step(1.0 / 90.0)
		done += n


## Largest distance any particle moved in a single tick, over `ticks` ticks.
func _max_step(ticks: int) -> float:
	var worst := 0.0
	var prev: PackedVector3Array = _rope.get_points()
	var done := 0
	while done < ticks:
		await get_tree().physics_frame
		var n: int = mini(BATCH, ticks - done)
		for i in n:
			_rope.step(1.0 / 90.0)
			var now: PackedVector3Array = _rope.get_points()
			if now.size() == prev.size():
				for p in now.size():
					worst = maxf(worst, prev[p].distance_to(now[p]))
			prev = now
		done += n
	return worst


## Step until the cord sleeps or `limit` ticks run out, and report how much it was
## still moving in the last `STILL_WINDOW` ticks IT WAS AWAKE.
##
## Measuring movement after it sleeps is how a jitter test quietly stops testing
## anything: `step()` on a sleeping rope is a no-op, so every particle is
## identical and the answer is a confident 0.000 mm no matter how badly the cord
## chattered on its way there. The two numbers that matter are whether it settled
## at all — a contact limit cycle shows up as a cord that never sleeps — and how
## small its movement had got just before it did.
##
## Returns {slept, tick, worst_awake, last_awake}: the largest single-tick
## movement anywhere in the window, and the largest in the final tick.
func _settle_profile(limit: int) -> Dictionary:
	var ring: Array[float] = []
	var prev: PackedVector3Array = _rope.get_points()
	var tick := 0
	while tick < limit and not _rope.is_sleeping():
		await get_tree().physics_frame
		for i in BATCH:
			if tick >= limit or _rope.is_sleeping():
				break
			_rope.step(1.0 / 90.0)
			tick += 1
			var now: PackedVector3Array = _rope.get_points()
			var worst := 0.0
			if now.size() == prev.size():
				for p in now.size():
					worst = maxf(worst, prev[p].distance_to(now[p]))
			prev = now
			ring.append(worst)
			if ring.size() > STILL_WINDOW:
				ring.remove_at(0)
	var window_worst := 0.0
	for v in ring:
		window_worst = maxf(window_worst, v)
	return {
		"slept": _rope.is_sleeping(),
		"tick": tick,
		"worst_awake": window_worst,
		"last_awake": ring[ring.size() - 1] if not ring.is_empty() else 0.0,
	}


## The jitter verdict, shared by every contact case. Two independent questions,
## because either one alone can be fooled:
##
## 1. DOES IT SETTLE AT ALL. The contact-chatter limit cycle this solver has had
##    before shows up as a cord that never sleeps — it twitches a fraction of a
##    millimetre a tick, forever, and burns a physics budget the Quest does not
##    have. "Still awake after N ticks" is that failure, stated directly.
##
## 2. IS IT ACTUALLY STILL. Sleep on its own proves nothing about jitter: a
##    sleeping rope's step() is a no-op, so movement reads a confident 0.000 mm
##    however badly it chattered on the way. So the cord is held AWAKE with
##    wake() for a further window and measured there. A settled contact reads
##    micrometres; a contact fighting itself reads millimetres, and the sleep
##    system can no longer hide it.
func _assert_settles(name: String, limit: int, still_mm: float) -> void:
	var prof := await _settle_profile(limit)
	_ok("contact/%s settles" % name, prof["slept"],
		"still awake after %d ticks, moving %.3f mm/tick"
			% [prof["tick"], float(prof["worst_awake"]) * 1000.0])
	var residual := await _awake_residual(240)
	_ok("contact/%s is still when it is settled" % name, residual * 1000.0 < still_mm,
		"%.4f mm/tick held awake (slept at tick %d)" % [residual * 1000.0, prof["tick"]])


## Largest per-tick movement in the LAST STILL_WINDOW ticks of an awake hold of
## `ticks`, with the rope forbidden to sleep. This is the chatter amplitude:
## whatever the cord is still doing once it has finished falling, measured where
## the sleep system cannot mask it.
##
## Only the tail of the hold counts. Sleep can catch a cord a moment early, so
## the first wakes let it finish a slump it was frozen in the middle of — a
## one-time transient, over in well under the hold. Chatter is the thing that is
## STILL going at the end; a corner case once read 12.3 mm/tick from a tail
## slumping on the first wake and 0.2 mm/tick once it had.
func _awake_residual(ticks: int) -> float:
	var worst := 0.0
	var prev: PackedVector3Array = _rope.get_points()
	var done := 0
	while done < ticks:
		await get_tree().physics_frame
		var n: int = mini(BATCH, ticks - done)
		for i in n:
			_rope.wake()
			_rope.step(1.0 / 90.0)
			done += 1
			if done <= ticks - STILL_WINDOW:
				prev = _rope.get_points()
				continue
			var now: PackedVector3Array = _rope.get_points()
			if now.size() == prev.size():
				for pt in now.size():
					worst = maxf(worst, prev[pt].distance_to(now[pt]))
			prev = now
	return worst


## Wake the settled cord once and watch: does it go back to sleep, how long did
## that take, and how far did anything move before it did?
func _wake_once(max_ticks: int) -> Dictionary:
	var before: PackedVector3Array = _rope.get_points()
	_rope.wake()
	var tick := 0
	while tick < max_ticks and not _rope.is_sleeping():
		await get_tree().physics_frame
		for i in BATCH:
			if tick >= max_ticks or _rope.is_sleeping():
				break
			_rope.step(1.0 / 90.0)
			tick += 1
	var after: PackedVector3Array = _rope.get_points()
	var drift := 0.0
	if after.size() == before.size():
		for p in after.size():
			drift = maxf(drift, before[p].distance_to(after[p]))
	return {"reslept": _rope.is_sleeping(), "tick": tick, "drift": drift}


func _points() -> PackedVector3Array:
	return _rope.get_points()


func _lowest_y() -> float:
	var y := 1e9
	for p: Vector3 in _points():
		y = minf(y, p.y)
	return y


func _all_finite() -> bool:
	for p: Vector3 in _points():
		if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
			return false
	return true


## Longest segment as a multiple of its rest length.
func _max_stretch() -> float:
	var pts := _points()
	var rest: float = _rope.segment_length
	var worst := 0.0
	for i in range(mini(pts.size(), _rope.segment_count + 1) - 1):
		worst = maxf(worst, pts[i].distance_to(pts[i + 1]) / rest)
	return worst


## How deep any particle sits inside an axis-aligned box, in metres. Zero means
## the cord stayed outside it.
func _deepest_in_box(centre: Vector3, size: Vector3) -> float:
	var half := size * 0.5
	var worst := 0.0
	for p: Vector3 in _points():
		var d := Vector3(half.x - absf(p.x - centre.x),
			half.y - absf(p.y - centre.y), half.z - absf(p.z - centre.z))
		if d.x > 0.0 and d.y > 0.0 and d.z > 0.0:
			worst = maxf(worst, minf(d.x, minf(d.y, d.z)))
	return worst


## _deepest_in_box for a rope the harness is not holding — the loose cases own
## their own lead rather than the shared _rope.
func _deepest_in_box_of(rope: VerletRope, centre: Vector3, size: Vector3) -> float:
	var half := size * 0.5
	var worst := 0.0
	for p: Vector3 in rope.get_points():
		var d := Vector3(half.x - absf(p.x - centre.x),
			half.y - absf(p.y - centre.y), half.z - absf(p.z - centre.z))
		if d.x > 0.0 and d.y > 0.0 and d.z > 0.0:
			worst = maxf(worst, minf(d.x, minf(d.y, d.z)))
	return worst


## How far inside a cylinder lying along X any particle sits.
func _deepest_in_cylinder(centre: Vector3, radius: float, half_len: float) -> float:
	var worst := 0.0
	for p: Vector3 in _points():
		if absf(p.x - centre.x) > half_len:
			continue
		var r := Vector2(p.y - centre.y, p.z - centre.z).length()
		worst = maxf(worst, radius - r)
	return worst


## Shortest distance between two finite 3D line segments. Self-collision has to
## keep the swept cord volumes apart, not merely their endpoint particles.
func _segment_distance(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> float:
	var u := b - a
	var v := d - c
	var w := a - c
	var aa := u.dot(u)
	var bb := u.dot(v)
	var cc := v.dot(v)
	var dd := u.dot(w)
	var ee := v.dot(w)
	var denom := aa * cc - bb * bb
	var sn := 0.0
	var sd := denom
	var tn := 0.0
	var td := denom
	if denom < 0.00000001:
		sn = 0.0
		sd = 1.0
		tn = ee
		td = cc
	else:
		sn = bb * ee - cc * dd
		tn = aa * ee - bb * dd
		if sn < 0.0:
			sn = 0.0
			tn = ee
			td = cc
		elif sn > sd:
			sn = sd
			tn = ee + bb
			td = cc
	if tn < 0.0:
		tn = 0.0
		if -dd < 0.0:
			sn = 0.0
		elif -dd > aa:
			sn = sd
		else:
			sn = -dd
			sd = aa
	elif tn > td:
		tn = td
		if -dd + bb < 0.0:
			sn = 0.0
		elif -dd + bb > aa:
			sn = sd
		else:
			sn = -dd + bb
			sd = aa
	var sc := 0.0 if absf(sn) < 0.00000001 else sn / sd
	var tc := 0.0 if absf(tn) < 0.00000001 else tn / td
	return (w + u * sc - v * tc).length()


func _centroid() -> Vector3:
	var pts := _points()
	var sum := Vector3.ZERO
	for p: Vector3 in pts:
		sum += p
	return sum / maxf(float(pts.size()), 1.0)


# ── contact ───────────────────────────────────────────────────────────────────
# What a cord does when it meets furniture. Every case here is something a player
# does to a lead without thinking about it.

func _group_contact() -> void:
	if not _wants("contact"):
		return

	# Slack cord between two sockets ON a table top. The floor of everything else:
	# if a cord cannot lie still on a flat surface, nothing below is worth reading.
	# The anchors sit just above the surface, where a socket could be — an earlier
	# version pinned them 200 mm up, and the video showed a cord dangling from two
	# points in empty space rather than lying on furniture.
	# Laid at full stretch and CARRIED into its socket (see _carry): initialising
	# it pre-compressed between the close sockets buckled it into a standing arch,
	# and it slept 318 mm in the air.
	var base := _new_case()
	_box(base + Vector3(0, 0.70, 0), Vector3(2.0, 0.10, 2.0))
	var table_rope := _rope_between(
		base + Vector3(-0.3, 0.76, 0), base + Vector3(0.66, 0.76, 0), 16)
	await _settle(120)
	await _carry(table_rope, table_rope.end_node, base + Vector3(0.3, 0.76, 0), 90)
	await _assert_settles("a cord on a table", 1500, STILL_MM)
	var top := base.y + 0.75
	var sink := top - _lowest_y()
	_ok("contact/lies on a table", sink < _rope.collision_radius + 0.005,
		"rests %.1f mm above the surface" % (-sink * 1000.0))
	# A cord pushed into its socket keeps a little standing pigtail where the
	# slack folded — measured 48 mm, and a real springy lead does the same. What
	# this bound rejects is the pre-compression buckle it was added for: a cord
	# sleeping in a 318 mm standing ARCH, clear off the table.
	var highest := -1e9
	for p: Vector3 in _points():
		highest = maxf(highest, p.y)
	_ok("contact/the cord lies down, pigtail and all", highest < top + 0.12,
		"tallest point %.0f mm above the surface" % ((highest - top) * 1000.0))
	await _drop_case()

	# THE JITTER CASE. A cord half on a table and half over its edge is the shape
	# that has produced a contact-chatter limit cycle in this solver before: the
	# overhang pulls, the contact pushes back, and the pair never agree. Measured
	# as movement, not as sleep, so it fails even if the sleep test is loosened.
	# Run from a socket on the table top, over the front edge, down the face to a
	# socket at floor level — everywhere the cord ends is somewhere a machine
	# could be, so the hanging weight is real cord and not a floating pin.
	#
	# Built the way a player builds it: laid over the edge first, then the free
	# end CARRIED down to the floor socket. Initialising the cord straight from
	# table top to floor lays it diagonally through the slab, and a particle born
	# inside a solid next to a pinned anchor has no contact plane and stays
	# wedged — measured 11 mm inside. The ledge case documents the same trap.
	base = _new_case()
	var slab_c := base + Vector3(-0.5, 0.70, 0)
	var slab_s := Vector3(1.0, 0.10, 1.0)
	_box(slab_c, slab_s)
	_box(base + Vector3(0, -0.05, 0), Vector3(4.0, 0.10, 4.0))    # the floor
	var corner_rope := _rope_between(
		base + Vector3(-0.9, 0.76, 0), base + Vector3(0.35, 0.76, 0), 34)
	await _settle(120)
	await _carry(corner_rope, corner_rope.end_node, base + Vector3(0.30, 0.03, 0), 90)
	var corner_prof := await _settle_profile(1500)
	_ok("contact/a cord over a table corner settles", corner_prof["slept"],
		"still awake after %d ticks, moving %.3f mm/tick"
			% [corner_prof["tick"], float(corner_prof["worst_awake"]) * 1000.0])
	# NOT the held-awake residual the other contacts use. This shape has a long
	# free-hanging span, and wake()-ing it every tick feeds the edge contact's
	# chatter into the span's pendulum mode: measured, the hold pumps a 0.4 m
	# sideways swing the room cannot contain — and cannot reach, because the
	# sleep system cuts the loop off. So the claim is the one the room makes:
	# brushed awake once, the cord lies straight back down (measured: asleep
	# again in 30 ticks, 7 mm of drift). A sleep test too broken to re-latch, or
	# a contact that genuinely churns, both still fail it.
	var w := await _wake_once(600)
	_ok("contact/a brushed corner cord lies back down",
		bool(w["reslept"]) and float(w["drift"]) < 0.03,
		"%s, drifted %.1f mm" % [
			"asleep again after %d ticks" % int(w["tick"]) if w["reslept"]
				else "still awake after %d ticks" % int(w["tick"]),
			float(w["drift"]) * 1000.0])
	var cut := _deepest_in_box(slab_c, slab_s)
	_ok("contact/the corner is wrapped, not cut", cut < 0.01,
		"deepest %.1f mm inside the table" % (cut * 1000.0))
	await _drop_case()

	# Wrapped over a ledge, anchored on both sides of it. The cord has to bend
	# round the edge and stay outside the solid.
	# Laid ALONG the top and over the front edge, not strung from one side to the
	# other: a straight lay between two sides cuts the corner, and a particle that
	# starts deep inside a solid has no contact plane to be pushed out along. This
	# is also how a lead actually gets there — dropped on the surface, and the
	# overhang drapes.
	base = _new_case()
	var ledge_c := base + Vector3(0, 0.50, -0.10)
	var ledge_s := Vector3(1.2, 0.50, 0.80)
	_box(ledge_c, ledge_s)
	var ledge_rope := _rope_between(base + Vector3(0, 0.80, -0.40),
		base + Vector3(0, 0.80, 0.80), 20)
	# Lay the cord at full length, then bring the far end inward as a hand would.
	# Initialising 250 mm of compression chooses an arbitrary standing buckle and
	# tests that synthetic pose rather than a cable routed over an edge.
	await _carry(ledge_rope, ledge_rope.end_node as Node3D,
		base + Vector3(0, 0.80, 0.55), 90)
	await _assert_settles("a cord wrapping a ledge", 1800, STILL_MM)
	var into := _deepest_in_box(ledge_c, ledge_s)
	_ok("contact/wrapping a ledge stays out of the solid", into < 0.01,
		"deepest %.1f mm inside" % (into * 1000.0))
	var over := false
	var over_lowest := 1e9
	for p: Vector3 in _points():
		if p.z > base.z + 0.32:
			over_lowest = minf(over_lowest, p.y)
			if p.y < base.y + 0.73:
				over = true
	_ok("contact/the overhang drapes down the face", over,
		"lowest overhang %.0f mm" % ((over_lowest - base.y) * 1000.0))
	await _drop_case()

	# Draped over a horizontal pipe. A round surface is where a plane-cache
	# contact model shows its seams: the contact normal turns under the cord.
	# The slack is sized to the shape: an earlier version hung 1.1 m of spare cord
	# from anchors 180 mm above the crown, and the bight slid off the top and
	# swung UNDERNEATH — the video showed a cord slung under the pipe, not draped
	# on it, while the old "rests on the pipe" check passed on a side graze.
	base = _new_case()
	var pipe := base + Vector3(0, 1.00, 0)
	_cylinder(pipe, 0.12, 1.6)
	_rope_between(base + Vector3(0, 1.16, -0.40), base + Vector3(0, 1.16, 0.40), 21)
	await _assert_settles("a cord draped on a pipe", 1800, STILL_MM)
	var into_pipe := _deepest_in_cylinder(pipe, 0.12, 0.8)
	_ok("contact/draping a pipe stays out of it", into_pipe < 0.02,
		"deepest %.1f mm inside" % (into_pipe * 1000.0))
	# "Not inside the pipe" is only half the claim: a cord that ignores collision
	# entirely falls PAST it and reads a clean zero. It has to be lying ON it —
	# and on the CROWN, not brushing a flank on its way underneath.
	var on_crown := false
	for pt: Vector3 in _points():
		if absf(pt.x - pipe.x) > 0.8 or pt.y < pipe.y + 0.06:
			continue
		var r := Vector2(pt.y - pipe.y, pt.z - pipe.z).length()
		if absf(r - 0.12) < 0.02:
			on_crown = true
	_ok("contact/the cord rests on top of the pipe", on_crown)
	await _drop_case()

	# Over a thin upright post: the cord must end up hanging down BOTH sides
	# rather than sliding off one.
	base = _new_case()
	_cylinder(base + Vector3(0, 0.50, 0), 0.05, 1.0, true)
	_rope_between(base + Vector3(-0.35, 1.15, 0), base + Vector3(0.35, 1.15, 0), 30)
	await _settle(900)
	var left := false
	var right := false
	for p: Vector3 in _points():
		if p.y < base.y + 0.95:
			if p.x < base.x - 0.05:
				left = true
			elif p.x > base.x + 0.05:
				right = true
	_ok("contact/a cord over a post hangs both sides", left and right)
	# "Both sides" alone cannot fail: with collision off the cord hangs straight
	# THROUGH the post and still has particles either side of it. The cord also
	# has to be leaning on the post — and not be inside it.
	var into_post := 0.0
	var on_post := false
	for p: Vector3 in _points():
		var d := Vector2(p.x - base.x, p.z - base.z).length()
		if p.y > base.y and p.y < base.y + 0.995:
			into_post = maxf(into_post, 0.05 - d)
			if absf(d - 0.05) < 0.02:
				on_post = true
		elif p.y >= base.y + 0.995 and p.y < base.y + 1.03 and d < 0.05:
			on_post = true            # resting across the top counts too
	_ok("contact/the cord leans on the post, not through it",
		on_post and into_post < 0.01,
		"deepest %.1f mm inside" % (into_post * 1000.0))
	await _drop_case()

	# Bridging two supports with a gap between them: it should sag into the gap
	# and stop, not sink through to the floor. Anchored on the support surfaces,
	# so the spare cord lies on them and only the span crosses the gap.
	base = _new_case()
	_box(base + Vector3(-0.45, 0.70, 0), Vector3(0.6, 0.10, 1.0))
	_box(base + Vector3(0.45, 0.70, 0), Vector3(0.6, 0.10, 1.0))
	_box(base + Vector3(0, -0.05, 0), Vector3(4.0, 0.10, 4.0))     # the floor
	_rope_between(base + Vector3(-0.5, 0.76, 0), base + Vector3(0.5, 0.76, 0), 30)
	await _settle(900)
	var sag := base.y + 0.75 - _lowest_y()
	_ok("contact/a bridged cord sags without reaching the floor",
		_lowest_y() > base.y + 0.1, "lowest point %.0f mm above the floor"
			% ((_lowest_y() - base.y) * 1000.0))
	_ok("contact/a bridged cord does sag into the gap", sag > 0.01,
		"sagged %.0f mm" % (sag * 1000.0))
	await _drop_case()

	# 2.4 m of cord piled on a 0.4 m span, both ends on the surface — a spare lead
	# dropped in a heap. Measured at 0.35 mm/tick held awake, i.e. a pile settles as
	# quietly as a single drape. Worth stating, because the obvious guess is that
	# self-collision in a heap is what makes a cord restless, and it is not.
	base = _new_case()
	_box(base + Vector3(0, 0.50, -0.10), Vector3(1.2, 0.50, 0.80))
	_rope_between(base + Vector3(0, 0.80, -0.30), base + Vector3(0, 0.80, 0.10), 40)
	await _assert_settles("a cord heaped on itself", 2400, STILL_MM)
	await _drop_case()


# ── handling ──────────────────────────────────────────────────────────────────
# What a player DOES to a cable, not just where one lies. The tow cases use the
# REAL lead scene with one plug frozen and walked like a held pickup, so the
# whole shipped stack answers — the rope, the plug bodies, and the reach clamp in
# composite_cable that brings the far plug along. A bare rope cannot express "a
# loose plug dragged behind the cord": its ends are always pinned, and a first
# draft of these cases proved it by laying the cord straight down through the
# floor (InitPoints hangs a null-end rope downward) and passing anyway.

func _group_handling() -> void:
	if not _wants("handling"):
		return

	# YANKED. A resting lead's plug snatched up and sideways at ~5 m/s — the
	# fastest thing a hand does to a cable. The cord must come with it without
	# turning elastic: PBD under-iterates under a fast pull, and this measures by
	# how much at the worst frame of the yank, not after it has recovered.
	var base := _new_case()
	_box(base + Vector3(0, -0.05, 0), Vector3(4.0, 0.10, 4.0))
	var lead := await _drop_lead(base + Vector3(0, 0.15, 0), 240)
	var rope: VerletRope = lead.get_node("VerletRope")
	var plug: RigidBody3D = lead.get_node("PlugA0")
	var worst_stretch := 0.0
	plug.freeze = true
	var yank_to: Vector3 = plug.global_position + Vector3(0.9, 0.9, 0)
	var stride: Vector3 = (yank_to - plug.global_position) / 18.0
	for f in 18:
		_move_held(plug, stride)
		await get_tree().physics_frame
		worst_stretch = maxf(worst_stretch, _lead_stretch(rope))
	for f in 60:
		await get_tree().physics_frame
	# Measured 2.18x at the worst frame of a ~5 m/s snatch — a momentary give the
	# 8-iteration solver cannot avoid on a one-tick pull. The bound is set from
	# that measurement; before the alignment-step cap in AlignAnchorPlug this
	# read 53x, because the far plug had been carried through the floor and the
	# last segment was strung down to it through the void.
	_ok("handling/a yanked lead follows without turning elastic", worst_stretch < 3.0,
		"worst segment %.2f x rest mid-yank" % worst_stretch)
	_ok("handling/a yanked lead recovers its length once the hand stops",
		_lead_stretch(rope) < 1.25, "%.2f x rest held still" % _lead_stretch(rope))
	plug.freeze = false
	var slept := await _wait_until_asleep(rope, 900)
	_ok("handling/a yanked lead settles when dropped", slept >= 0,
		"asleep after %d frames" % slept if slept >= 0
			else "never slept, moving %.3f mm/frame" % (_last_wait_motion * 1000.0))
	lead.queue_free()
	await get_tree().physics_frame

	# DRAGGED. A lead towed 2.5 m across the floor by one plug at hand speed.
	# The cord trails along the floor and the loose far plug comes along — that
	# last part is composite_cable's reach clamp, and it is being tested here on
	# purpose: it is how a dragged lead behaves in the room.
	base = _new_case()
	_box(base + Vector3(0, -0.05, 0), Vector3(8.0, 0.10, 4.0))
	lead = await _drop_lead(base + Vector3(-1.2, 0.15, 0), 240)
	rope = lead.get_node("VerletRope")
	plug = lead.get_node("PlugA0")
	var far: RigidBody3D = lead.get_node("PlugB0")
	plug.freeze = true
	var drag_stride: Vector3 = Vector3(2.5, 0, 0) / 120.0
	var drag_peak := -1e9
	for f in 120:
		_move_held(plug, drag_stride)
		await get_tree().physics_frame
		for p: Vector3 in rope.get_points():
			drag_peak = maxf(drag_peak, p.y - base.y)
	for f in 60:
		await get_tree().physics_frame
	_ok("handling/a dragged lead's cord stays on the floor", drag_peak < 0.35,
		"highest point %.0f mm mid-drag" % (drag_peak * 1000.0))
	var span: float = far.global_position.distance_to(plug.global_position)
	_ok("handling/a dragged lead's far plug is towed along, not left behind",
		span < 2.1, "plugs %.2f m apart after a 2.5 m drag" % span)
	plug.freeze = false
	slept = await _wait_until_asleep(rope, 900)
	_ok("handling/a dragged lead lies down afterwards", slept >= 0,
		"asleep after %d frames" % slept if slept >= 0 else "never slept")
	lead.queue_free()
	await get_tree().physics_frame

	# PULLED OUT THROUGH A SLOT. A lead lying through a 100 mm opening between
	# two walls — a cord run behind a cabinet — towed out from one side at an
	# angle. The slot is a fairlead: the cord has to slide through it and bend
	# around its edge, the far plug has to come through the opening, and neither
	# may saw into the walls.
	base = _new_case()
	_box(base + Vector3(0, -0.05, 0), Vector3(8.0, 0.10, 4.0))
	var wall_a_c := base + Vector3(0, 0.25, -0.30)
	var wall_b_c := base + Vector3(0, 0.25, 0.30)
	var wall_s := Vector3(0.10, 0.50, 0.50)
	_box(wall_a_c, wall_s)
	_box(wall_b_c, wall_s)
	lead = await _drop_lead(base + Vector3(0, 0.20, 0), 240, PI * 0.5)
	rope = lead.get_node("VerletRope")
	var pa: RigidBody3D = lead.get_node("PlugA0")
	var pb: RigidBody3D = lead.get_node("PlugB0")
	plug = pa if pa.global_position.x > pb.global_position.x else pb
	far = pb if plug == pa else pa
	plug.freeze = true
	var slot_stride: Vector3 = (base + Vector3(2.3, 0.35, 0.9) - plug.global_position) / 200.0
	for f in 200:
		_move_held(plug, slot_stride)
		await get_tree().physics_frame
	for f in 60:
		await get_tree().physics_frame
	_ok("handling/a lead pulled from a slot comes through", far.global_position.x - base.x > 0.15,
		"far plug at x=%.2f m, slot at 0" % (far.global_position.x - base.x))
	var wall_cut := maxf(_deepest_in_box_of(rope, wall_a_c, wall_s),
		_deepest_in_box_of(rope, wall_b_c, wall_s))
	_ok("handling/the slot walls are slid past, not cut", wall_cut < 0.01,
		"deepest %.1f mm inside a wall" % (wall_cut * 1000.0))
	plug.freeze = false
	slept = await _wait_until_asleep(rope, 900)
	_ok("handling/a lead pulled from a slot settles", slept >= 0,
		"asleep after %d frames" % slept if slept >= 0 else "never slept")
	lead.queue_free()
	await get_tree().physics_frame

	# CARRIED OVER A WALL. The held plug LIFTED and then taken across, the way a
	# hand actually clears a partition — the first draft towed it in a straight
	# line, which passes through the wall's middle, and a frozen body moved by
	# the harness goes wherever it is sent: the pinned anchor rode through the
	# solid and the cord sliced the wall after it while every particle-based
	# assertion read 0.0 (the particles sat legally on either side; it was the
	# SEGMENTS spanning between them that crossed). Hence the segment oracle
	# below, sampled every frame of the carry: the cord may only cross the
	# wall's plane above its top edge.
	base = _new_case()
	_box(base + Vector3(0, -0.05, 0), Vector3(6.0, 0.10, 3.0))
	var part_c := base + Vector3(0, 0.25, 0)
	var part_s := Vector3(0.10, 0.50, 1.6)
	_box(part_c, part_s)
	lead = await _drop_lead(base + Vector3(-0.9, 0.15, 0), 240)
	rope = lead.get_node("VerletRope")
	plug = lead.get_node("PlugA0")
	far = lead.get_node("PlugB0")
	plug.freeze = true
	var far_into := 0.0
	var pierced := false
	for leg: Vector3 in [base + Vector3(-0.4, 0.75, 0), base + Vector3(1.1, 0.75, 0)]:
		var legs := 75
		var over_stride: Vector3 = (leg - plug.global_position) / float(legs)
		for f in legs:
			_move_held(plug, over_stride)
			await get_tree().physics_frame
			var fp: Vector3 = far.global_position
			var dxp := Vector3(part_s.x * 0.5 - absf(fp.x - part_c.x),
				part_s.y * 0.5 - absf(fp.y - part_c.y), part_s.z * 0.5 - absf(fp.z - part_c.z))
			if dxp.x > 0.0 and dxp.y > 0.0 and dxp.z > 0.0:
				far_into = maxf(far_into, minf(dxp.x, minf(dxp.y, dxp.z)))
			if _pierces_below_top(rope, part_c, part_s):
				pierced = true
	for f in 60:
		await get_tree().physics_frame
	_ok("handling/a carry cannot pull the far plug through a wall", far_into < 0.005,
		"plug centre %.1f mm inside the partition at the worst frame" % (far_into * 1000.0))
	_ok("handling/the cord goes over the wall, never through it",
		not pierced and not _pierces_below_top(rope, part_c, part_s))
	var part_cut := _deepest_in_box_of(rope, part_c, part_s)
	_ok("handling/the cord ends up around the wall, not inside it", part_cut < 0.01,
		"deepest %.1f mm inside" % (part_cut * 1000.0))
	plug.freeze = false
	# 1800, not the 900 the other tow cases get: the release leaves the lead
	# draped over the partition with a plug swinging on each side, and the swing
	# has twice the pendulum to damp before the wake threshold lets it latch.
	slept = await _wait_until_asleep(rope, 1800)
	_ok("handling/a lead carried over a wall settles", slept >= 0,
		"asleep after %d frames" % slept if slept >= 0
			else "never slept, moving %.3f mm/frame" % (_last_wait_motion * 1000.0))
	lead.queue_free()
	await get_tree().physics_frame

	# WRAPPED ROUND A POST AND PULLED TIGHT. The far plug walked round an upright
	# post and then hauled away, so the cord has to turn ~135 degrees around it
	# under live tension — a lead routed round a table leg. The post must carry
	# the turn: cord touching it, not inside it, and segments still cord-length.
	base = _new_case()
	_cylinder(base + Vector3(0, 0.50, 0), 0.05, 1.0, true)
	rope = _rope_between(base + Vector3(-0.5, 0.5, 0.2), base + Vector3(0.5, 0.5, 0.2), 24)
	await _settle(200)
	await _carry(rope, rope.end_node, base + Vector3(0.5, 0.5, -0.3), 60)
	await _carry(rope, rope.end_node, base + Vector3(-0.3, 0.5, -0.3), 60)
	await _carry(rope, rope.end_node, base + Vector3(-0.62, 0.5, -0.45), 40)
	await _settle(300)
	var wrap_into := 0.0
	var wrap_touch := false
	for p: Vector3 in _points():
		if p.y < base.y or p.y > base.y + 0.995:
			continue
		var d := Vector2(p.x - base.x, p.z - base.z).length()
		wrap_into = maxf(wrap_into, 0.05 - d)
		if absf(d - 0.05) < 0.02:
			wrap_touch = true
	_ok("handling/a wrapped cord turns ON the post", wrap_touch and wrap_into < 0.01,
		"deepest %.1f mm inside" % (wrap_into * 1000.0))
	_ok("handling/a wrapped cord holds its length under tension", _max_stretch() < 1.25,
		"worst segment %.2f x rest" % _max_stretch())
	var prof := await _settle_profile(1500)
	_ok("handling/a wrapped cord settles under tension", prof["slept"],
		"still awake after %d ticks" % prof["tick"])
	await _drop_case()


# ── integrity ─────────────────────────────────────────────────────────────────
# The cord is a cord: it does not stretch, it does not explode, and it does the
# same thing twice.

func _group_integrity() -> void:
	if not _wants("integrity"):
		return

	# Hanging under its own weight is the everyday load. A rope that stretches
	# here reads as elastic in the room.
	var base := _new_case()
	_rope_from(base + Vector3(0, 2.0, 0), base + Vector3(0.3, 2.0, 0), 40)
	await _settle(600)
	var stretch := _max_stretch()
	var pts := _points()
	var span := 0.0
	for i in range(pts.size() - 1):
		span += pts[i].distance_to(pts[i + 1])
	var elong: float = span / (float(_rope.segment_count) * _rope.segment_length)
	_ok("integrity/hanging under its own weight does not stretch", stretch < 1.25,
		"worst segment %.3f x rest, whole cord %.3f x" % [stretch, elong])
	_ok("integrity/the cord as a whole keeps its length", elong < 1.12,
		"%.3f x rest" % elong)
	await _drop_case()

	# XPBD compliance is an explicit physical mode, not an iteration-dependent
	# stiffness tweak. A deliberately soft test cord should extend by a bounded,
	# finite amount under the same load; zero compliance above remains the exact
	# authored-stiffness compatibility path used by shipping cables today.
	base = _new_case()
	var compliant := _rope_from(base + Vector3(0, 2.0, 0),
		base + Vector3(0.3, 2.0, 0), 20)
	compliant.bend_stiffness = 0.0
	compliant.stretch_compliance = 0.00001
	await _settle(300)
	var compliant_stretch := _max_stretch()
	_ok("integrity/compliance produces bounded physical extension",
		compliant_stretch > 1.01 and compliant_stretch < 2.0,
		"worst segment %.3f x rest" % compliant_stretch)
	await _drop_case()

	# Abuse: anchors 20x further apart than the cord is long, then shaken. The
	# question is only whether the arithmetic survives it.
	base = _new_case()
	var rope := _rope_between(base + Vector3(-18.0, 1.2, 0), base + Vector3(18.0, 1.2, 0))
	var far_end: Node3D = rope.end_node
	for batch in 20:
		await get_tree().physics_frame
		for i in BATCH:
			far_end.position.x += 0.35 if i % 2 == 0 else -0.35
			rope.step(1.0 / 90.0)
	_ok("integrity/over-extended and shaken stays finite", _all_finite())
	await _drop_case()

	# Energy has to leave the system. Compared as movement early vs late, which
	# is the same measure the jitter cases use.
	base = _new_case()
	_rope_between(base + Vector3(-0.3, 1.4, 0), base + Vector3(0.3, 1.4, 0), 30)
	var early := await _max_step(60)
	await _settle(600)
	var late := await _max_step(60)
	_ok("integrity/a swinging cord loses energy", late < early * 0.05,
		"%.2f mm/tick early, %.4f mm/tick late" % [early * 1000.0, late * 1000.0])
	await _drop_case()

	# Two identical ropes, stepped identically, must land on identical points.
	# Anything that leaks uninitialised memory or reads a global clock fails here.
	base = _new_case()
	_rope_between(base + Vector3(-0.3, 1.2, 0), base + Vector3(0.3, 1.2, 0), 20)
	await _settle(300)
	var first := _points()
	var first_base := base
	await _drop_case()
	_new_case()
	base = first_base
	_rope_between(base + Vector3(-0.3, 1.2, 0), base + Vector3(0.3, 1.2, 0), 20)
	await _settle(300)
	var second := _points()
	var worst := 0.0
	if first.size() == second.size():
		for i in first.size():
			worst = maxf(worst, (first[i] - first_base).distance_to(second[i] - base))
	_ok("integrity/the same cord twice settles the same way",
		first.size() == second.size() and worst < 1e-9,
		"worst difference %.9f m" % worst)
	await _drop_case()


# ── anchors ───────────────────────────────────────────────────────────────────
# What the ends are for.

func _group_anchors() -> void:
	if not _wants("anchors"):
		return

	# A pinned particle IS its anchor, every tick — this is the property the
	# whole cable system leans on to keep a seated plug seated.
	var base := _new_case()
	var rope := _rope_between(base + Vector3(-0.4, 1.2, 0), base + Vector3(0.4, 1.2, 0))
	var a: Node3D = rope.start_node
	var b: Node3D = rope.end_node
	var drift := 0.0
	for batch in 10:
		await get_tree().physics_frame
		for i in BATCH:
			rope.step(1.0 / 90.0)
			var pts := rope.get_points()
			drift = maxf(drift, pts[0].distance_to(a.global_position))
			drift = maxf(drift, pts[rope.segment_count].distance_to(b.global_position))
	_ok("anchors/a pinned end never leaves its anchor", drift < 1e-6,
		"worst drift %.9f m" % drift)
	var saved_layout := rope.get_points()
	rope._init_points()
	var restored_ok := rope.restore_points(saved_layout)
	var restored_layout := rope.get_points()
	var restore_error := 0.0
	for i in saved_layout.size():
		restore_error = maxf(restore_error, saved_layout[i].distance_to(restored_layout[i]))
	_ok("anchors/a saved particle layout restores exactly",
		restored_ok and restore_error < 1e-9,
		"worst immediate error %.9f m" % restore_error)
	var corrupt := saved_layout.duplicate()
	corrupt[1] += Vector3(10.0, 0, 0)
	_ok("anchors/a corrupt saved layout is rejected", not rope.restore_points(corrupt))
	await _drop_case()

	# An anchor that jumps further than it could have travelled is a teleport —
	# a restore putting a machine back — and the cord is re-laid straight
	# between the new positions rather than swept. The straight lay can pass
	# through furniture, and a particle born inside a solid has no contact
	# plane: before DepenetrateLay it stayed wedged in the cabinet for ever
	# (an earlier wall variant measured 27 mm, this one 8 buried particles).
	# The cord has to end up draped ON the cabinet the lay crossed, and asleep.
	base = _new_case()
	_box(base + Vector3(0, -0.05, 0), Vector3(6.0, 0.10, 4.0))
	var cab_c := base + Vector3(0.75, 0.45, 0)
	var cab_s := Vector3(0.5, 0.9, 0.6)
	_box(cab_c, cab_s)
	rope = _rope_between(base + Vector3(0, 1.2, 0), base + Vector3(0.3, 1.2, 0), 34)
	await _settle(300)
	var moved: Node3D = rope.end_node
	moved.position = base + Vector3(1.5, 0.2, 0)     # a 1.6 m jump, through the cabinet
	await _settle(900)
	var wedged := _deepest_in_box(cab_c, cab_s)
	_ok("anchors/a teleported cord is freed from what it re-laid through",
		wedged < 0.01, "deepest %.1f mm inside the cabinet" % (wedged * 1000.0))
	var on_cab := false
	for p: Vector3 in _points():
		if absf(p.x - cab_c.x) < 0.25 and absf(p.z - cab_c.z) < 0.3 \
				and p.y > base.y + 0.9 and p.y < base.y + 0.94:
			on_cab = true
	_ok("anchors/the freed cord drapes over the cabinet", on_cab)
	await _drop_case()

	# A legacy save has no particle layout: both anchors appear in their restored
	# positions before the rope is built, so its first lay is the direct line
	# between them. With one socket on a tabletop and the other below it that line
	# crosses the slab. Repair must find a route around the inflated solid as one
	# coherent span; independently ejecting buried particles leaves neighbours on
	# opposite faces and creates the collision/stretch jitter seen in 00764aee.
	base = _new_case()
	_box(base + Vector3(0, -0.05, 0), Vector3(4.0, 0.10, 4.0))
	var restore_table_c := base + Vector3(0, 0.70, 0)
	var restore_table_s := Vector3(1.2, 0.10, 1.0)
	_box(restore_table_c, restore_table_s)
	rope = _rope_between(base + Vector3(-0.20, 0.76, 0),
		base + Vector3(0.20, 0.06, 0), 50, 0.036)
	await _settle(1800)
	var restore_wedged := _deepest_in_box(restore_table_c, restore_table_s)
	var restore_stretch := _lead_stretch(rope)
	_ok("anchors/a restored lay through a tabletop repairs and sleeps",
		rope.is_sleeping(), "sleeping=%s" % str(rope.is_sleeping()))
	_ok("anchors/a repaired restored lay leaves the tabletop",
		restore_wedged < 0.01, "deepest %.1f mm inside" % (restore_wedged * 1000.0))
	_ok("anchors/a repaired restored lay does not remain severely stretched",
		restore_stretch < 1.5, "worst segment %.2fx rest" % restore_stretch)
	await _drop_case()

	# set_rope_length is the one setter that rewrites the rest table. Halving it
	# must halve how far the free end can get — a cached rest length once made
	# this silently do nothing.
	base = _new_case()
	rope = _rope_from(base + Vector3(0, 2.0, 0), base + Vector3(0.3, 2.0, 0), 30)
	await _settle(900)
	var top_anchor := base + Vector3(0, 2.0, 0)
	var reach_before: float = _points()[rope.segment_count].distance_to(top_anchor)
	rope.set_rope_length(rope.rest_length() * 0.5)
	await _settle(900)
	var reach_after: float = _points()[rope.segment_count].distance_to(top_anchor)
	var new_rest: float = float(rope.segment_count) * rope.segment_length
	# The hard adjacent-joint bend limit prevents the shortened cable collapsing
	# into the old near-zero-radius coil within this window. Eight percent still
	# tightly bounds solver stretch while leaving an enormous gap to the original
	# stale-rest-table failure, which remained near the full 1.8 m length.
	_ok("anchors/a halved rope cannot reach past its new length",
		reach_after < new_rest * 1.08,
		"%.0f mm reach against %.0f mm of cord" % [reach_after * 1000.0, new_rest * 1000.0])
	# The regression this exists for: set_rope_length once wrote the length and
	# nothing else, so the solver kept using the old rest table and the reach did
	# not move at all. A tail that coils rather than hanging taut is why this is
	# "much shorter" rather than "exactly half".
	_ok("anchors/halving the rope really shortens it",
		reach_after < reach_before * 0.6,
		"%.0f mm -> %.0f mm" % [reach_before * 1000.0, reach_after * 1000.0])
	await _drop_case()


# ── sleep ─────────────────────────────────────────────────────────────────────
# A cord that never sleeps costs a Quest frame budget it does not have, and one
# that will not wake is a cable you cannot move.

func _group_sleep() -> void:
	if not _wants("sleep"):
		return

	var base := _new_case()
	_box(base + Vector3(0, 0.70, 0), Vector3(2.0, 0.10, 2.0))
	var rope := _rope_between(base + Vector3(-0.3, 0.95, 0), base + Vector3(0.3, 0.95, 0))
	await _settle(900)
	_ok("sleep/a settled cord sleeps", rope.is_sleeping())

	# Still asleep after being left alone — the anti-jitter claim in the cheap
	# form, and the one that catches a cord that re-wakes itself forever.
	await _settle(300)
	_ok("sleep/a sleeping cord stays asleep", rope.is_sleeping())

	# The smallest move a hand can make must bring it back.
	var a: Node3D = rope.start_node
	a.position += Vector3(0.002, 0, 0)
	await _settle(2)
	_ok("sleep/moving an anchor wakes it", not rope.is_sleeping())

	await _settle(900)
	_ok("sleep/it settles again", rope.is_sleeping())
	rope.nudge_point(int(rope.segment_count / 2), Vector3(0, -0.05, 0))
	await _settle(2)
	_ok("sleep/nudging a point wakes it", not rope.is_sleeping())
	await _drop_case()


# ── loose ─────────────────────────────────────────────────────────────────────
# Every case above pins both ends of the cord, because that is what the room
# normally does to a lead: a plug in a socket, a cord bolted to a console. But it
# means the cord is HANGING OVER the furniture rather than lying on it, and the
# contact is correspondingly light.
#
# A cord with nothing holding it is not expressible on a bare rope: InitPoints
# pins particle 0 whenever the start does not fray, so `start_node = null` gives a
# cord nailed to the air rather than a free one (measured: the first particle
# falls 0.000 m). What IS free is a whole lead — the ends are plug BODIES, and
# they fall, land and rest like any other rigid body.
#
# So these cases use the real lead scene and the engine's own physics tick rather
# than the hand-stepped solver: the plugs are simulated by the physics server, and
# the rope has to stay in step with them.

func _group_loose() -> void:
	if not _wants("loose"):
		return

	# A lead dropped flat onto a table. Nothing holds it up: if it ends up resting
	# on the surface, that is the plugs and the cord doing it between them.
	var base := _new_case()
	_box(base + Vector3(0, 0.70, 0), Vector3(1.6, 0.10, 1.6))
	var lead := await _drop_lead(base + Vector3(0, 1.10, 0), 420)
	var rope: VerletRope = lead.get_node("VerletRope")
	var lowest := 1e9
	for p: Vector3 in rope.get_points():
		lowest = minf(lowest, p.y)
	_ok("loose/a dropped lead comes to rest on the table",
		lowest > base.y + 0.74 and lowest < base.y + 0.80,
		"lowest point %.0f mm, table top at %.0f mm"
			% [(lowest - base.y) * 1000.0, 750.0])
	# Waited for rather than asserted at a fixed frame count: this case is ticked by
	# the ENGINE (the plugs are rigid bodies), so how many frames a settle takes
	# depends on what else the suite is doing that frame. Asserting is_sleeping()
	# at exactly 420 frames passed alone and failed in a full run — a flake, which
	# is worse than a failure because it teaches everyone to re-run the suite.
	var slept_at := await _wait_until_asleep(rope, 900)
	_ok("loose/a dropped lead settles", slept_at >= 0,
		"asleep after %d frames" % slept_at if slept_at >= 0 else "never slept")
	lead.queue_free()
	await get_tree().physics_frame

	# Dropped ACROSS the edge, so half lands on the table and half hangs off it.
	# The half in the air pulls on the half on the surface, and the cord has to
	# hold its own weight over the corner rather than sliding off.
	base = _new_case()
	_box(base + Vector3(-0.5, 0.70, 0), Vector3(1.0, 0.10, 1.6))
	_box(base + Vector3(0, -0.05, 0), Vector3(4.0, 0.10, 4.0))    # the floor to land on
	lead = await _drop_lead(base + Vector3(-0.20, 1.10, 0), 600, PI * 0.5)
	rope = lead.get_node("VerletRope")
	# What "stays put" means here, measured rather than assumed: the far plug goes
	# over the edge, drops, and swings back UNDER the table, so the cord hugs the
	# corner instead of extending out past it. The claims that matter are that some
	# cord is still up on the surface, that the rest hangs well below it, and above
	# all that none of it is INSIDE the table.
	var on_table := false
	var hanging := false
	for p: Vector3 in rope.get_points():
		if p.y > base.y + 0.72 and p.x < base.x:
			on_table = true
		if p.y < base.y + 0.55:
			hanging = true
	var through := _deepest_in_box_of(rope, base + Vector3(-0.5, 0.70, 0), Vector3(1.0, 0.10, 1.6))
	_ok("loose/a lead over an edge keeps its grip on the table", on_table)
	_ok("loose/a lead over an edge hangs down the other side", hanging)
	_ok("loose/a lead over an edge does not cut through the table", through < 0.01,
		"deepest %.1f mm inside" % (through * 1000.0))
	lead.queue_free()
	await get_tree().physics_frame

	# Dropped 1.5 m onto a thin plate. This is the motion-sweep path: a lead in
	# free fall is doing ~5 m/s by the time it arrives, which is 60 mm per tick
	# against a 20 mm plate, so a solver that only tested the END of a step would
	# put the cord through the table. It has to be a real lead — a bare rope keeps
	# particle 0 pinned wherever it was laid, so it dangles rather than falls.
	base = _new_case()
	_box(base + Vector3(0, 0.50, 0), Vector3(2.0, 0.02, 2.0))
	lead = await _drop_lead(base + Vector3(0, 2.00, 0), 480)
	rope = lead.get_node("VerletRope")
	var lowest2 := 1e9
	for p: Vector3 in rope.get_points():
		lowest2 = minf(lowest2, p.y)
	_ok("loose/a lead dropped from height does not go through the plate",
		lowest2 > base.y + 0.48,
		"lowest point %.0f mm, plate at 500 mm" % ((lowest2 - base.y) * 1000.0))
	lead.queue_free()
	await get_tree().physics_frame


## Advance a frozen plug one stride, the way a hand carries a pickup. The write
## goes through the physics server: repositioning a frozen body by
## `global_position` alone does not reliably reach it.
func _move_held(plug: RigidBody3D, stride: Vector3) -> void:
	var xf: Transform3D = plug.global_transform
	xf.origin += stride
	plug.global_transform = xf
	PhysicsServer3D.body_set_state(plug.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, xf)


## True when any trunk segment of `rope` crosses the mid-plane of an upright
## slab well BELOW its top face — a cord passing THROUGH a wall rather than
## over it. Particle-position checks cannot see this: two particles resting
## legally on opposite faces with a stretched segment strung between them read
## as 0.0 mm inside while the rendered cord slices the wall.
## The 20 mm allowance under the top is for the corner: a taut chord between
## two 30 mm-spaced particles riding the edge cuts it by a few millimetres
## (measured 2 mm) — that is discretisation, not a cord inside a wall, and a
## real slice crosses hundreds of millimetres down.
func _pierces_below_top(rope: VerletRope, centre: Vector3, size: Vector3) -> bool:
	var pts: PackedVector3Array = rope.get_points()
	var half := size * 0.5
	var n: int = mini(rope.segment_count, pts.size() - 1)
	for i in n:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[i + 1]
		if absf(b.x - a.x) < 0.0001:
			continue
		var t: float = (centre.x - a.x) / (b.x - a.x)
		if t < 0.0 or t > 1.0:
			continue
		var y: float = lerpf(a.y, b.y, t)
		var z: float = lerpf(a.z, b.z, t)
		if y < centre.y + half.y - 0.02 and absf(z - centre.z) < half.z:
			return true
	return false


## Worst trunk-segment stretch of a lead's rope, as a multiple of rest length.
## Trunk only — the points array carries fray-branch particles after it, at a
## different rest length.
func _lead_stretch(rope: VerletRope) -> float:
	var pts: PackedVector3Array = rope.get_points()
	var n: int = mini(rope.segment_count, pts.size() - 1)
	var worst := 0.0
	for i in n:
		worst = maxf(worst, pts[i].distance_to(pts[i + 1]) / rope.segment_length)
	return worst


## Wait for an engine-ticked rope to fall asleep. Returns the frame it slept on,
## or -1 if it never did.
func _wait_until_asleep(rope: VerletRope, max_frames: int) -> int:
	var previous := rope.get_points()
	_last_wait_motion = 0.0
	for f in max_frames:
		await get_tree().physics_frame
		var current := rope.get_points()
		if f >= max_frames - 60 and current.size() == previous.size():
			for i in current.size():
				_last_wait_motion = maxf(_last_wait_motion,
					current[i].distance_to(previous[i]))
		previous = current
		if rope.is_sleeping():
			return f
	return -1


## Drop a whole lead from `at` and let the ENGINE tick it — plug bodies are
## simulated by the physics server, so these cannot be hand-stepped.
func _drop_lead(at: Vector3, ticks: int, yaw := 0.0) -> Node3D:
	var lead: Node3D = LEAD_SCENE.instantiate()
	# Posed BEFORE it enters the tree. The ends are RigidBody3Ds, and once a body
	# is in the world the physics server owns its transform — moving the parent
	# node afterwards moves the node and not the body, so the lead would drop from
	# wherever it was built rather than from where it was put.
	#
	# The lead lies along its OWN z (its plugs sit at z = -0.75 and +0.75), so a
	# case that needs it across an x-running edge has to turn it.
	lead.position = at
	lead.rotation.y = yaw
	_case_geometry.add_child(lead)
	for f in ticks:
		await get_tree().physics_frame
	return lead


# ── edges ─────────────────────────────────────────────────────────────────────
# State changes that do not originate at a rope particle: furniture moves after
# a cord sleeps, an anchor disappears, or the simulated chain is a branched
# ribbon rather than the ordinary single cord exercised by the groups above.

func _group_edges() -> void:
	if not _wants("edges"):
		return

	# Removing a support changes no anchor. A sleeping query-only rope receives no
	# physics callback from the table, so it must still notice that gravity is no
	# longer balanced by a contact and fall instead of hovering in empty space.
	var base := _new_case()
	var support := _box(base + Vector3(0, 0.70, 0), Vector3(1.6, 0.10, 1.2))
	var rope := _rope_between(base + Vector3(-0.55, 0.82, 0), base + Vector3(0.55, 0.82, 0), 30, 0.04)
	await _settle(900)
	var supported_y := _lowest_y()
	var slept_on_support := rope.is_sleeping()
	support.queue_free()
	await get_tree().physics_frame
	var woke_without_support := false
	for tick in 180:
		if tick % BATCH == 0:
			await get_tree().physics_frame
		rope.step(1.0 / 90.0)
		woke_without_support = woke_without_support or not rope.is_sleeping()
	var unsupported_y := _lowest_y()
	_ok("edges/removing support wakes a sleeping cord", slept_on_support and woke_without_support,
		"lowest %.0f -> %.0f mm" % [(supported_y - base.y) * 1000.0,
			(unsupported_y - base.y) * 1000.0])
	_ok("edges/a cord falls when its support is removed", unsupported_y < supported_y - 0.05,
		"fell %.1f mm" % ((supported_y - unsupported_y) * 1000.0))
	await _drop_case()

	# The inverse operation: furniture pushed into a sleeping cord has to wake and
	# displace it. The rope is not a CollisionObject3D, so polling is its only way
	# to observe a collider whose motion begins outside the rope.
	base = _new_case()
	var mover := _box(base + Vector3(0, 0.10, 0), Vector3(1.0, 0.60, 0.8))
	rope = _rope_between(base + Vector3(-0.55, 0.75, 0), base + Vector3(0.55, 0.75, 0), 30, 0.04)
	await _settle(900)
	var before_push := _points()
	var before_high := -1e9
	for p: Vector3 in before_push:
		before_high = maxf(before_high, p.y)
	mover.position += Vector3(0, 0.55, 0)
	await get_tree().physics_frame
	var woke_for_furniture := false
	for tick in 180:
		if tick % BATCH == 0:
			await get_tree().physics_frame
		rope.step(1.0 / 90.0)
		woke_for_furniture = woke_for_furniture or not rope.is_sleeping()
	var after_high := -1e9
	for p: Vector3 in _points():
		after_high = maxf(after_high, p.y)
	var mover_c := base + Vector3(0, 0.65, 0)
	var mover_s := Vector3(1.0, 0.60, 0.8)
	var mover_depth := _deepest_in_box(mover_c, mover_s)
	_ok("edges/furniture wakes a sleeping cord when pushed into it", woke_for_furniture,
		"highest %.0f -> %.0f mm" % [(before_high - base.y) * 1000.0,
			(after_high - base.y) * 1000.0])
	_ok("edges/moving furniture pushes the cord out of its volume", mover_depth < 0.01,
		"deepest %.1f mm inside" % (mover_depth * 1000.0))
	await _drop_case()

	# An edge contact legitimately has two answers: the tabletop normal and the
	# vertical-face normal. The sleeping environment poll must accept either one
	# without deciding that the table moved, clearing the contact manifold and
	# kicking the cord awake. This is the static version of a controller lead
	# draped over the table edge; fixed anchors isolate the contact logic from any
	# rigid-body movement in the controller itself.
	base = _new_case()
	_box(base + Vector3(-0.5, 0.70, 0), Vector3(1.0, 0.10, 1.0))
	_box(base + Vector3(0, -0.05, 0), Vector3(4.0, 0.10, 4.0))
	rope = _rope_between(base + Vector3(-0.9, 0.76, 0),
		base + Vector3(0.35, 0.76, 0), 34)
	await _carry(rope, rope.end_node, base + Vector3(0.35, 0.06, 0), 90)
	var corner_settle := await _settle_profile(1800)
	var corner_prev := rope.get_points()
	var corner_wakes := 0
	var corner_worst := 0.0
	var corner_was_asleep := rope.is_sleeping()
	for tick in 120:
		if tick % BATCH == 0:
			await get_tree().physics_frame
		rope.step(1.0 / 90.0)
		var corner_now := rope.get_points()
		for i in corner_now.size():
			corner_worst = maxf(corner_worst,
				corner_prev[i].distance_to(corner_now[i]))
		if corner_was_asleep and not rope.is_sleeping():
			corner_wakes += 1
		corner_was_asleep = rope.is_sleeping()
		corner_prev = corner_now
	_ok("edges/a sleeping corner cord is not woken by alternating edge normals",
		corner_settle["slept"] and corner_wakes == 0,
		"%d false wakes in 120 ticks" % corner_wakes)
	_ok("edges/a sleeping corner cord does not kick at the environment-poll cadence",
		corner_worst * 1000.0 < STILL_MM,
		"worst movement %.3f mm/tick" % (corner_worst * 1000.0))
	await _drop_case()

	# A mounted controller, sensor bar, or seated plug owns an authored exit
	# direction: socketing must not make its moulded strain relief disappear.
	# Start the cords vertically so this tests authority rather than preserving an
	# already-correct initial lay.
	base = _new_case()
	rope = _rope_between(base + Vector3(0, 0.9, 0),
		base + Vector3(0, 0.1, 0), 8, 0.1)
	rope.surface_collision_mask = 0
	rope.self_collision = false
	rope.gravity = Vector3.ZERO
	rope.bend_stiffness = 0.0
	rope.end_stiffness = 1.0
	rope.end_stiff_segments = 2
	rope.start_endpoint_role = VerletRope.ENDPOINT_HOST
	rope.end_endpoint_role = VerletRope.ENDPOINT_SOCKETED_PLUG
	rope.start_exit_axis = Vector3.RIGHT
	rope._init_points()
	for tick in 8:
		rope.step(1.0 / 90.0)
	var host_points := rope.get_points()
	var host_exit := (host_points[1] - host_points[0]).normalized()
	_ok("edges/a host attachment holds its strain-relief exit direction",
		host_exit.dot(Vector3.RIGHT) > 0.8,
		"first segment alignment %.3f" % host_exit.dot(Vector3.RIGHT))
	await _drop_case()

	base = _new_case()
	rope = _rope_between(base + Vector3(0, 0.9, 0),
		base + Vector3(0, 0.1, 0), 8, 0.1)
	rope.surface_collision_mask = 0
	rope.self_collision = false
	rope.gravity = Vector3.ZERO
	rope.bend_stiffness = 0.0
	rope.end_stiffness = 1.0
	rope.end_stiff_segments = 2
	rope.start_endpoint_role = VerletRope.ENDPOINT_SOCKETED_PLUG
	rope.end_endpoint_role = VerletRope.ENDPOINT_FREE_PLUG
	rope.start_exit_axis = Vector3.RIGHT
	rope._init_points()
	for tick in 8:
		rope.step(1.0 / 90.0)
	var socket_points := rope.get_points()
	var socket_exit := (socket_points[1] - socket_points[0]).normalized()
	_ok("edges/a socketed plug keeps its strain-relief exit direction",
		socket_exit.dot(Vector3.RIGHT) > 0.8,
		"first segment alignment %.3f" % socket_exit.dot(Vector3.RIGHT))
	await _drop_case()

	# Build an exact-length 180-degree hairpin immediately after the boot. The old
	# midpoint bend solver was singular there: stretch restored the same fold
	# forever. Adjacent segments do not self-collide, so the angular solver must
	# both respect the hard limit and retain a stiffness-dependent response below
	# it.
	base = _new_case()
	rope = _rope_from(base, base + Vector3(0.8, 0, 0), 8, 0.1)
	rope.surface_collision_mask = 0
	rope.self_collision = false
	rope.gravity = Vector3.ZERO
	rope.bend_stiffness = 0.03
	rope.end_stiffness = 0.3
	rope.end_stiff_segments = 2
	rope.start_endpoint_role = VerletRope.ENDPOINT_HOST
	rope.start_exit_axis = Vector3.RIGHT
	var hairpin := PackedVector3Array()
	for i in 9:
		var x: float = float(i) * 0.1 if i <= 3 else 0.3 - float(i - 3) * 0.1
		hairpin.append(base + Vector3(x, 0, 0))
	var soft_restored := rope.restore_points(hairpin)
	rope.step(1.0 / 90.0)
	var soft_points := rope.get_points()
	var soft_before := (soft_points[3] - soft_points[2]).normalized()
	var soft_after := (soft_points[4] - soft_points[3]).normalized()
	var soft_turn := rad_to_deg(acos(clampf(soft_before.dot(soft_after), -1.0, 1.0)))
	await _drop_case()

	base = _new_case()
	rope = _rope_from(base, base + Vector3(0.8, 0, 0), 8, 0.1)
	rope.surface_collision_mask = 0
	rope.self_collision = false
	rope.gravity = Vector3.ZERO
	rope.bend_stiffness = 0.3
	rope.end_stiffness = 0.3
	rope.end_stiff_segments = 2
	rope.start_endpoint_role = VerletRope.ENDPOINT_HOST
	rope.start_exit_axis = Vector3.RIGHT
	hairpin = PackedVector3Array()
	for i in 9:
		var x: float = float(i) * 0.1 if i <= 3 else 0.3 - float(i - 3) * 0.1
		hairpin.append(base + Vector3(x, 0, 0))
	var stiff_restored := rope.restore_points(hairpin)
	rope.step(1.0 / 90.0)
	var stiff_points := rope.get_points()
	var stiff_before := (stiff_points[3] - stiff_points[2]).normalized()
	var stiff_after := (stiff_points[4] - stiff_points[3]).normalized()
	var stiff_turn := rad_to_deg(acos(clampf(stiff_before.dot(stiff_after), -1.0, 1.0)))
	_ok("edges/a 180-degree hinge is limited and resists by bend stiffness",
		soft_restored and stiff_restored
			and soft_turn <= rope.bend_limit_degrees + 2.0
			and stiff_turn < soft_turn - 4.0,
		"soft %.1f degrees, stiff %.1f degrees" % [soft_turn, stiff_turn])
	await _drop_case()

	# The shipped controller lead has a loose spherical plug at its far end. Its
	# cable anchor is off-centre, so microscopic rolling that never reaches Jolt's
	# body sleep can accumulate into enough anchor drift to wake an otherwise
	# settled rope over and over. Once the whole rope sleeps, that genuinely free
	# plug should latch asleep with it; the controller body is a mounted Node3D
	# anchor and must be left to the physics server.
	_new_case()
	# This case mixes two Jolt bodies with millimetre-scale rope contacts. Keep it
	# on a dedicated nearby patch rather than inheriting any previous geometry.
	base = Vector3(-120.0, 0, 0)
	_box(base + Vector3(-0.5, 0.70, 0), Vector3(1.0, 0.10, 1.2))
	_box(base + Vector3(0, -0.05, 0), Vector3(4.0, 0.10, 4.0))
	var controller := RigidBody3D.new()
	controller.mass = 0.2
	controller.linear_damp = 5.0
	controller.angular_damp = 8.0
	controller.collision_layer = 4
	controller.collision_mask = 1
	controller.position = base + Vector3(-0.55, 0.84, 0)
	_case_geometry.add_child(controller)
	var controller_collision := CollisionShape3D.new()
	var controller_box := BoxShape3D.new()
	controller_box.size = Vector3(0.16, 0.05, 0.09)
	controller_collision.shape = controller_box
	controller.add_child(controller_collision)
	var controller_attach := Node3D.new()
	controller_attach.position = Vector3(0.07, 0, 0)
	controller.add_child(controller_attach)
	var controller_cable: Node3D = CONTROLLER_CABLE_SCENE.instantiate()
	_case_geometry.add_child(controller_cable)
	var controller_plug := controller_cable.get_node("ControllerPlug") as ControllerPlug
	var controller_rope := controller_cable.get_node("VerletRope") as VerletRope
	controller_plug.global_position = base + Vector3(0.35, 0.85, 0)
	controller_plug.add_collision_exception_with(controller)
	controller_rope.start_node = controller_attach
	controller_rope.end_node = controller_plug
	controller_rope.end_anchor_offset = controller_plug.cable_anchor
	# Give the host its actual outward direction independently of the plug. Before
	# endpoint axes were separate, configuring the interchangeable plug also
	# changed this end and could drive the first particles into the tabletop.
	controller_rope.start_endpoint_role = VerletRope.ENDPOINT_HOST
	controller_rope.end_endpoint_role = VerletRope.ENDPOINT_AUTO
	controller_rope.start_exit_axis = controller_attach.global_basis.inverse() * Vector3.RIGHT
	controller_rope.end_exit_axis = controller_plug.cable_exit_axis
	_ok("edges/endpoint roles and axes are independent",
		controller_rope.start_endpoint_role == VerletRope.ENDPOINT_HOST
			and controller_rope.end_endpoint_role == VerletRope.ENDPOINT_AUTO
			and controller_rope.start_exit_axis != controller_rope.end_exit_axis,
		"start role/axis remain distinct from end role/axis")
	controller_rope._init_points()
	var controller_slept_at := -1
	for frame in 1200:
		await get_tree().physics_frame
		if controller_rope.is_sleeping() and controller.sleeping and controller_plug.sleeping:
			controller_slept_at = frame
			break
	_ok("edges/a settled controller lead sleeps its loose plug",
		controller_slept_at >= 0,
		"all asleep after %d frames" % controller_slept_at
			if controller_slept_at >= 0 else
			"rope=%s controller=%s plug=%s metrics=%s" % [
				controller_rope.is_sleeping(), controller.sleeping,
				controller_plug.sleeping, controller_rope.get_sleep_metrics()])
	var controller_prev := controller_rope.get_points()
	var controller_wakes := 0
	var controller_worst := 0.0
	var controller_was_asleep := controller_rope.is_sleeping()
	for frame in 180:
		await get_tree().physics_frame
		var controller_now := controller_rope.get_points()
		for i in controller_now.size():
			controller_worst = maxf(controller_worst,
				controller_prev[i].distance_to(controller_now[i]))
		if controller_was_asleep and not controller_rope.is_sleeping():
			controller_wakes += 1
		controller_was_asleep = controller_rope.is_sleeping()
		controller_prev = controller_now
	_ok("edges/a rested controller lead stays still beside the table edge",
		controller_wakes == 0 and controller_worst * 1000.0 < STILL_MM,
		"%d wakes, %.3f mm/tick worst movement" % [
			controller_wakes, controller_worst * 1000.0])
	controller_cable.queue_free()
	controller.queue_free()
	await get_tree().physics_frame

	# A true six-plug lead exercises both frayed ends and all six branch anchors.
	# The ordinary behaviour cases use trs_cable.tscn, which is deliberately a
	# single unfrayed cord and therefore cannot catch ribbon/fray regressions.
	base = _new_case()
	var composite: Node3D = COMPOSITE_SCENE.instantiate()
	composite.position = base + Vector3(0, 1.0, 0)
	# Keep the six physics bodies still so this assertion measures the rope's
	# branch pinning, not whether a body integrated after the rope this frame.
	for end in ["A", "B"]:
		for c in 3:
			(composite.get_node("Plug%s%d" % [end, c]) as RigidBody3D).freeze = true
	_case_geometry.add_child(composite)
	await get_tree().process_frame # CompositeCable builds its rope deferred.
	await get_tree().physics_frame
	var comp_rope := composite.get_node("VerletRope") as VerletRope
	var topology_ok := comp_rope.ribbon_count == 3 and comp_rope.get_points().size() == 81
	var anchor_error := 0.0
	for c in 3:
		var pa := composite.get_node("PlugA%d" % c) as RcaPlug
		var pb := composite.get_node("PlugB%d" % c) as RcaPlug
		anchor_error = maxf(anchor_error,
			comp_rope.get_fray_start_point(c).distance_to(pa.global_transform * pa.cable_anchor))
		anchor_error = maxf(anchor_error,
			comp_rope.get_fray_end_point(c).distance_to(pb.global_transform * pb.cable_anchor))
	_ok("edges/a six-plug composite builds three cords and six fray branches", topology_ok,
		"%d particles" % comp_rope.get_points().size())
	_ok("edges/all six composite branches are pinned to their plugs", anchor_error < 0.00001,
		"worst anchor error %.3f mm" % (anchor_error * 1000.0))
	composite.queue_free()
	await get_tree().physics_frame

	# Two non-neighbour segments cross at their midpoints while every particle is
	# well clear of every other particle. Particle-only self-collision cannot see
	# this; a cord-volume collision pass must separate the segments themselves.
	# Keep this numerical oracle near the origin. In the full suite _new_case() is
	# more than a kilometre out by now, where float world coordinates can round an
	# exact 300 mm bow-tie differently than the isolated --only=edges run.
	base = Vector3.ZERO
	rope = _rope_between(base + Vector3(-0.15, 0.8, -0.15),
		base + Vector3(0.15, 0.8, -0.15), 3, 0.30)
	rope.gravity = Vector3.ZERO
	rope.stretch_stiffness = 0.0
	rope.bend_stiffness = 0.0
	rope.surface_collision_mask = 0
	var crossed := [
		base + Vector3(-0.15, 0.8, -0.15),
		base + Vector3(0.15, 0.8, 0.15),
		base + Vector3(-0.15, 0.8, 0.15),
		base + Vector3(0.15, 0.8, -0.15),
	]
	var laid := rope.get_points()
	for i in range(1, 3):
		# nudge_point changes current but not previous, so the next Verlet integrate
		# repeats 99% of the displacement. Divide by 1.99 to land on the intended
		# bow-tie at the moment collision runs, with no accidental endpoint contact.
		rope.nudge_point(i, (crossed[i] - laid[i]) / 1.99)
	await get_tree().physics_frame
	rope.step(1.0 / 90.0)
	var cross_pts := rope.get_points()
	var crossing_gap := _segment_distance(cross_pts[0], cross_pts[1], cross_pts[2], cross_pts[3])
	_ok("edges/self-collision separates crossing segments, not only particles",
		crossing_gap >= rope.collision_radius * 1.8,
		"segment gap %.2f mm" % (crossing_gap * 1000.0))
	await _drop_case()

	# ObjectIDs protect the anchor lookup after a node is freed, but the endpoint's
	# inverse mass must also change. Otherwise it remains pinned to the last valid
	# transform forever, particularly when the rope was asleep at deletion time.
	base = _new_case()
	rope = _rope_between(base + Vector3(-0.4, 1.0, 0), base + Vector3(0.4, 1.0, 0), 24)
	await _settle(900)
	var removed_anchor: Node3D = rope.end_node
	var endpoint_before: Vector3 = rope.get_points()[rope.segment_count]
	removed_anchor.queue_free()
	await get_tree().physics_frame
	var woke_after_removal := false
	for tick in 180:
		if tick % BATCH == 0:
			await get_tree().physics_frame
		rope.step(1.0 / 90.0)
		woke_after_removal = woke_after_removal or not rope.is_sleeping()
	var endpoint_after: Vector3 = rope.get_points()[rope.segment_count]
	_ok("edges/removing an anchor wakes the rope", woke_after_removal)
	_ok("edges/a removed anchor releases its endpoint", endpoint_after.y < endpoint_before.y - 0.05,
		"endpoint fell %.1f mm" % ((endpoint_before.y - endpoint_after.y) * 1000.0))
	await _drop_case()


# ── budget ────────────────────────────────────────────────────────────────────

func _group_budget() -> void:
	if not _wants("budget"):
		return
	var base := _new_case()
	var ropes: Array[VerletRope] = []
	_holder = Node3D.new()
	_case_geometry.add_child(_holder)
	for i in 16:
		var na := Node3D.new()
		na.position = base + Vector3(float(i) * 0.5, 1.2, -0.3)
		_holder.add_child(na)
		var nb := Node3D.new()
		nb.position = base + Vector3(float(i) * 0.5, 1.2, 0.3)
		_holder.add_child(nb)
		var r := VerletRope.new()
		_holder.add_child(r)
		r.segment_count = 24
		r.segment_length = 0.06
		r.start_node = na
		r.end_node = nb
		r.set_process(false)
		r.set_physics_process(false)
		r._init_points()
		ropes.append(r)
	var ticks := 400
	var started := Time.get_ticks_usec()
	var done := 0
	while done < ticks:
		await get_tree().physics_frame
		var n: int = mini(BATCH, ticks - done)
		for i in n:
			for r in ropes:
				r.step(1.0 / 90.0)
		done += n
	var us_per := float(Time.get_ticks_usec() - started) / float(ticks * ropes.size())
	# A ceiling, not a target: this is a debug build on a desktop, and the point
	# is to catch a solver that got several times slower, not to police µs.
	_ok("budget/solver cost per rope-tick", us_per < 400.0, "%.0f us" % us_per)
	await _drop_case()

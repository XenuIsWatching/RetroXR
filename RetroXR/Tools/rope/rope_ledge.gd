## Cable-on-a-ledge rest test — does a lead draped over a table edge ever stop
## moving, with REAL RigidBody plugs on its ends?
##
##   godot --headless --path RetroXR res://Tools/rope/rope_ledge.tscn
##
## This exists because rope_stress structurally cannot cover it. Every case there
## anchors to a plain Node3D, and AlignAnchorPlug bails on anything that is not a
## RigidBody3D — so the whole plug-alignment path, and the feedback it has with
## the rope, is invisible to that suite. rope_stress reported 0.00 jitter on its
## own "wrapped on a ledge" case while both real cables in here shivered forever.
##
## What to read: `asleep N/200 of the tail`. A settled cable should be asleep for
## most of it. Jitter in the last 50 ticks is the amplitude of whatever is left.
## A cable that never sleeps with sub-millimetre jitter is in a limit cycle, not
## still settling — dump a single particle tick by tick and look for a repeating
## period, which is what identified this.
##
## Both leads are cut to a comparable length on purpose. At cable.tscn's full
## 1.8 m the plain one drapes 30 cm of edge and heaps the other 1.5 m on the
## floor, and the heap's damping hides exactly the effect being measured.


extends Node

const COMPOSITE := preload("res://Scenes/Objects/cables/composite_cable.tscn")
const PLAIN := preload("res://Scenes/Objects/cables/cable.tscn")

const TABLE_TOP := 0.75
const TICKS := 900
const WINDOW := 150

var _prev_anchor := {}
var _prev_org := {}
var _anchor_jitter := 0.0
var _asleep_ticks := {}
var _origin_jitter := 0.0


func _ready() -> void:
	get_tree().create_timer(240.0).timeout.connect(func() -> void: get_tree().quit(1))
	await _run()
	get_tree().quit(0)


func _build_world() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	for spec in [
		[Vector3(8.0, 0.2, 8.0), Vector3(0.0, -0.1, 0.0)],          # floor
		[Vector3(1.2, 0.05, 0.8), Vector3(0.0, TABLE_TOP - 0.025, 0.0)],  # table top
	]:
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = spec[0]
		col.shape = box
		col.position = spec[1]
		body.add_child(col)


func _run() -> void:
	_build_world()
	# Both leads laid across the table so their slack hangs off the +X edge.
	var comp: Node3D = COMPOSITE.instantiate()
	add_child(comp)
	comp.global_position = Vector3(-0.15, TABLE_TOP + 0.05, 0.0)
	var plain: Node3D = PLAIN.instantiate()
	add_child(plain)
	plain.global_position = Vector3(-0.15, TABLE_TOP + 0.05, 0.35)
	await get_tree().process_frame

	var ropes := {
		"composite": comp.get_node("VerletRope") as VerletRope,
		"plain": plain.get_node("VerletRope") as VerletRope,
	}
	# The plain lead has no owner to wire it, so give it two mounts on the table.
	var a := Node3D.new()
	a.position = Vector3(-0.45, TABLE_TOP + 0.02, 0.35)
	add_child(a)
	var pl: VerletRope = ropes["plain"]
	pl.start_node = a
	pl.end_node = plain.get_node("CablePlug")
	pl.end_anchor_offset = (plain.get_node("CablePlug") as Node3D).get("cable_anchor")
	# Match the composite's scale. Left at cable.tscn's 1.8 m this drapes 30 cm of
	# table edge and dumps the other 1.5 m in a self-colliding heap on the floor,
	# so what it measures is the heap settling, not the edge — and it is then no
	# control at all for a change that only touches the plug ends.
	pl.set_rope_length(0.62)
	pl._init_points()

	var prev := {}
	var worst := {}
	var slept := {}
	var trace: Array[float] = []
	for k in ropes:
		prev[k] = (ropes[k] as VerletRope).get_points()
		worst[k] = 0.0
		slept[k] = -1
		_asleep_ticks[k] = 0

	for t in range(TICKS):
		await get_tree().process_frame
		for k in ropes:
			var r: VerletRope = ropes[k]
			if r.is_sleeping() and slept[k] < 0:
				slept[k] = t
			var pts: PackedVector3Array = r.get_points()
			var pv: PackedVector3Array = prev[k]
			if t >= TICKS - 200 and r.is_sleeping():
				_asleep_ticks[k] = _asleep_ticks.get(k, 0) + 1
			if t >= TICKS - 50 and pts.size() == pv.size():
				var mx := 0.0
				for i in pts.size():
					mx = maxf(mx, pts[i].distance_to(pv[i]))
				worst[k] = maxf(worst[k], mx)
			prev[k] = pts
		# Who is actually moving? Trace the six plug ANCHOR POINTS (the rope reads
		# transform * cable_anchor, so a plug ROTATING moves its anchor as surely
		# as a plug translating), and how often the tether clamp writes a plug.
		var amax := 0.0
		var rmax := 0.0
		for n in ["PlugA0","PlugA1","PlugA2","PlugB0","PlugB1","PlugB2"]:
			var pg: Node3D = comp.get_node(n)
			var ap: Vector3 = pg.global_transform * (pg.get("cable_anchor") as Vector3)
			if _prev_anchor.has(n):
				amax = maxf(amax, ap.distance_to(_prev_anchor[n]))
				rmax = maxf(rmax, pg.global_position.distance_to(_prev_org[n]))
			_prev_anchor[n] = ap
			_prev_org[n] = pg.global_position
		if t >= TICKS - WINDOW:
			_anchor_jitter = maxf(_anchor_jitter, amax)
			_origin_jitter = maxf(_origin_jitter, rmax)
		if t >= TICKS - 40:
			trace.append((ropes["composite"] as VerletRope).get_points()[25].y)

	for k in ropes:
		print("[probe] %-10s jitter(last 50) = %.4f mm   asleep %d/200 of the tail   first_slept=%s" % [
			k, worst[k] * 1000.0, int(_asleep_ticks[k]),
			str(slept[k]) if slept[k] >= 0 else "NEVER"])
	print("[probe] plug ORIGIN jitter  = %.4f mm  (are the bodies moving?)" % (_origin_jitter * 1000.0))
	print("[probe] plug ANCHOR jitter  = %.4f mm  (origin + rotation about cable_anchor)" % (_anchor_jitter * 1000.0))
	var s := ""
	for v in trace:
		s += "%.5f " % (v * 1000.0)
	print("[probe] composite pt25.y mm, last 40 ticks: %s" % s)

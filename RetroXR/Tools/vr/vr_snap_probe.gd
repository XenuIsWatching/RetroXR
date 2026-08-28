## vr_snap_probe — fingertip contact snapping, widget stickiness and the touch
## smoother, all driven off a fake XRPositionalTracker so no headset is needed.
##
## Run: godot --headless --path RetroXR res://Tools/vr/vr_snap_probe.tscn
##
## The load-bearing assertions are the first ones: the obsolete controller-tip
## cone must stay gone, tip_of() must not move when contact feedback snaps, and
## the surface disc must still land on the claimed face.
extends Node3D

const LIFT := PokeTip.CONTACT_LIFT

var _fail := false
var _tracker: XRPositionalTracker = null
var _ctrl: XRController3D = null
var _poke: PokeTip = null
## Recorded host.feed_touch calls, for the TV surface tests.
var _touches: Array = []


func _check(ok: bool, msg: String) -> void:
	print("[probe] %s: %s" % ["PASS" if ok else "FAIL", msg])
	if not ok:
		_fail = true


## TVTouchSurface calls this on its host.
func feed_touch(uv: Vector2, pressed: bool) -> void:
	_touches.append({"uv": uv, "pressed": pressed})


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void: get_tree().quit(1))
	_run.call_deferred()


func _put_tip(p: Vector3) -> void:
	# Identity basis, so the PokeTip child at (0,0,-TIP_FORWARD) lands on `p`.
	_tracker.set_pose(&"default",
		Transform3D(Basis(), p + Vector3(0.0, 0.0, PokeTip.TIP_FORWARD)),
		Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _cap(size: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	return mi


func _run() -> void:
	# ── rig ──────────────────────────────────────────────────────────────────
	var origin := XROrigin3D.new()
	add_child(origin)
	_ctrl = XRController3D.new()
	_ctrl.tracker = &"left_hand"
	origin.add_child(_ctrl)
	_poke = PokeTip.new()
	_poke.name = "PokeTip"
	_ctrl.add_child(_poke)
	_tracker = XRPositionalTracker.new()
	_tracker.name = &"left_hand"
	_tracker.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(_tracker)
	_put_tip(Vector3(0.0, 1.0, 0.0))
	await _frames(6)
	_check(_ctrl.get_is_active(), "fake tracker drives the controller")

	# ── 1. no controller-tip cone; the contact disc remains ─────────────────
	await _frames(20)
	var disc: MeshInstance3D = _poke.get("_disc")
	_check(_poke.get_child_count() == 1 and _poke.get_child(0) == disc,
		"PokeTip contains only the contact disc (no cone mesh)")
	_check(not disc.visible, "contact disc is hidden without a claimed surface")

	# ── 2. tip_of() invariance while the disc is displaced ───────────────────
	var cap := _cap(Vector3(0.02, 0.01, 0.02))
	add_child(cap)
	cap.global_position = Vector3(0.0, 1.0, 0.0)
	await _frames(2)
	var tip_at := Vector3(0.004, 1.02, 0.004)
	_put_tip(tip_at)
	await _frames(2)
	for i in 12:
		PokeTip.claim_box_face(_ctrl, cap, PokeTip.tip_of(_ctrl), Vector3.UP,
			PokeTip.CONTACT_ENGAGED)
		await get_tree().process_frame
	_check(PokeTip.tip_of(_ctrl).distance_to(tip_at) < 1e-5,
		"tip_of() is unmoved by the snap (%v)" % PokeTip.tip_of(_ctrl))
	_check(disc.visible, "contact disc appears on a claimed surface")
	_check(disc.global_position.distance_to(Vector3(0.004, 1.006, 0.004)) < 0.003,
		"contact disc snaps to the claimed face (%v)" % disc.global_position)
	var finger_target: Variant = _poke.visual_contact_target()
	_check(finger_target is Vector3 \
			and (finger_target as Vector3).distance_to(Vector3(0.004, 1.005, 0.004)) < 0.003,
		"finger IK target sits on the surface without the disc lift (%v)" % finger_target)

	# ── 3. face projection ───────────────────────────────────────────────────
	PokeTip.claim_box_face(_ctrl, cap, Vector3(0.004, 1.02, 0.004), Vector3.UP,
		PokeTip.CONTACT_ENGAGED)
	var got: Vector3 = _poke.get("_claim_point")
	var want := Vector3(0.004, 1.005 + LIFT, 0.004)
	_check(got.distance_to(want) < 1e-5, "projects onto the +Y face (%v vs %v)" % [got, want])
	await get_tree().process_frame   # claims are frame-scoped; nearest wins within one
	PokeTip.claim_box_face(_ctrl, cap, Vector3(0.05, 1.02, 0.0), Vector3.UP,
		PokeTip.CONTACT_ENGAGED)
	got = _poke.get("_claim_point")
	_check(absf(got.x - (0.01 - PokeTip.FACE_INSET)) < 1e-5,
		"clamps into the footprint, inset (x = %.4f)" % got.x)
	cap.queue_free()

	# ── 4. button: hysteresis, then grace ────────────────────────────────────
	var btn := VRButton.new()
	btn.trigger_radius = 0.01
	var bm := _cap(Vector3(0.02, 0.006, 0.02))
	bm.name = "ButtonMesh"
	btn.add_child(bm)
	add_child(btn)
	btn.global_position = Vector3(0.0, 2.0, 0.0)
	var fires := [0]
	btn.button_pressed.connect(func() -> void: fires[0] += 1)
	_put_tip(Vector3(0.0, 2.0, 0.0) + Vector3(0.008, 0.0, 0.0))
	await _frames(6)
	_check(fires[0] == 1, "contact fires once (%d)" % fires[0])
	_put_tip(Vector3(0.0, 2.0, 0.0) + Vector3(0.015, 0.0, 0.0))
	await _frames(6)
	_check(bool(btn.get("_touch_pressed")),
		"still held past trigger_radius, inside the release scale")
	_check(fires[0] == 1, "and it did not re-fire (%d)" % fires[0])
	_put_tip(Vector3(0.0, 2.0, 0.0) + Vector3(0.05, 0.0, 0.0))
	await _frames(12)
	_check(not bool(btn.get("_touch_pressed")), "released well outside")
	_put_tip(Vector3(0.0, 2.0, 0.0) + Vector3(0.008, 0.0, 0.0))
	await _frames(6)
	_check(fires[0] == 2, "re-contact fires again (%d)" % fires[0])
	# One bad frame must not drop it — the actual request.
	_put_tip(Vector3(0.0, 2.0, 0.0) + Vector3(0.05, 0.0, 0.0))
	await _frames(1)
	var survived: bool = bool(btn.get("_touch_pressed"))
	_put_tip(Vector3(0.0, 2.0, 0.0) + Vector3(0.008, 0.0, 0.0))
	await _frames(4)
	_check(survived, "a single dropped frame does not break contact")
	_check(fires[0] == 2, "and nothing re-fired across it (%d)" % fires[0])
	btn.queue_free()

	# ── 5. slider: grab offset, then the freeze band ─────────────────────────
	var sl := VRSlider.new()
	sl.axis_local = Vector3(1, 0, 0)
	sl.travel = 0.1
	sl.engage_radius = 0.08   # comfortably clear of the test offsets, not on the boundary
	var km := _cap(Vector3(0.01, 0.006, 0.01))
	km.name = "KnobMesh"
	sl.add_child(km)
	add_child(sl)
	sl.global_position = Vector3(0.0, 3.0, 0.0)
	await _frames(3)
	sl.set_value_no_signal(0.5)
	# Contact at a point that projects to 0.9 must NOT move it.
	_put_tip(Vector3(0.0, 3.0, 0.0) + Vector3(0.04, 0.0, 0.0))
	await _frames(4)
	_check(absf(sl.value - 0.5) < 0.01,
		"taking hold off-centre does not jump the knob (%.3f)" % sl.value)
	# Then it tracks one-for-one: +0.01 m over 0.1 m travel = +0.1.
	_put_tip(Vector3(0.0, 3.0, 0.0) + Vector3(0.05, 0.0, 0.0))
	await _frames(4)
	_check(absf(sl.value - 0.6) < 0.02, "and then tracks one-for-one (%.3f)" % sl.value)
	# Withdraw with a deliberate ALONG-AXIS component. The value must freeze at
	# the moment contact was lost, not follow the hand out.
	var held: float = sl.value
	_put_tip(Vector3(0.0, 3.0, 0.0) + Vector3(0.09, 0.0, 0.09))
	await _frames(10)
	_check(absf(sl.value - held) < 0.001,
		"withdrawing does not drag the value (%.3f -> %.3f)" % [held, sl.value])
	# Lifting OFF the groove freezes it, while sliding ALONG it still drives the
	# full range. The old test used one distance for both, so the radius had to
	# exceed half the throw to allow sliding -- and a withdrawing hand then
	# dragged the knob most of its range before anything froze.
	sl.set_value_no_signal(0.5)
	_put_tip(Vector3(0.0, 3.0, 0.0))
	await _frames(4)
	var base: float = sl.value
	_put_tip(Vector3(0.0, 3.0, 0.0) + Vector3(0.012, 0.0, 0.030))   # 30 mm off the axis
	await _frames(6)
	_check(absf(sl.value - base) < 0.02,
		"lifting off the groove freezes it (%.3f -> %.3f)" % [base, sl.value])
	# PULLING AWAY must barely move it, even with the along-axis drift a real
	# withdrawal has. The reference is the DEEPEST press, so pressing in first
	# (as you would to take hold) must not buy the withdrawal any extra slack.
	_put_tip(Vector3(0.0, 3.0, 0.0) + Vector3(0.0, 0.0, 0.004))
	await _frames(4)
	_put_tip(Vector3(0.0, 3.0, 0.0))            # press in
	await _frames(4)
	base = sl.value
	for st in 17:
		var pull: float = float(st) * 0.001
		_put_tip(Vector3(0.0, 3.0, 0.0) + Vector3(pull * 0.35, 0.0, pull))
		await _frames(2)
	_check(absf(sl.value - base) < 0.10,
		"a 16 mm withdrawal drags it under 0.10 (%+.3f)" % (sl.value - base))
	_put_tip(Vector3(0.0, 3.0, 0.0))
	await _frames(6)
	var lo := 1.0
	var hi := 0.0
	for st in 15:
		_put_tip(Vector3(0.0, 3.0, 0.0) + Vector3((float(st) / 14.0 - 0.5) * 0.11, 0.0, 0.0))
		await _frames(2)
		lo = minf(lo, sl.value)
		hi = maxf(hi, sl.value)
	_check(lo < 0.05 and hi > 0.95,
		"sliding along it still reaches both ends (%.2f .. %.2f)" % [lo, hi])
	sl.queue_free()

	# ── 6. TouchSmoother, pure ───────────────────────────────────────────────
	var ts := TouchSmoother.new()
	ts.begin(Vector2.ZERO)
	var p1: Vector2 = ts.point(Vector2(TouchSmoother.DEADZONE * 0.5, 0.0), true, 1.0 / 90.0)
	_check(p1.length() < 1e-6, "sub-deadzone tremor moves nothing (%v)" % p1)
	var frozen: Vector2 = ts.point(Vector2(0.05, 0.0), false, 1.0 / 90.0)
	_check(frozen == p1, "not live returns the previous point exactly")
	var ts2 := TouchSmoother.new()
	ts2.begin(Vector2.ZERO)
	var step: Vector2 = ts2.point(Vector2(TouchSmoother.DEADZONE * 1.02, 0.0), true, 1.0)
	_check(step.x < TouchSmoother.DEADZONE * 0.5,
		"crossing the deadzone advances by ~0, not by a whole deadzone (%.6f)" % step.x)

	# ── 7. TV surface: glass plane and lift-off ──────────────────────────────
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.35, 0.25)
	quad.mesh = qm
	add_child(quad)
	quad.global_position = Vector3(0.0, 5.0, 0.0)
	var surf := TVTouchSurface.new()
	surf.setup(self, Rect2(0, 0, 1, 1), quad)
	quad.add_child(surf)
	await _frames(4)
	var centre := Vector3(0.0, 5.0, 0.0)
	_check(not surf._tip_on_screen(centre + Vector3(0, 0, 0.009), 1.0),
		"9 mm off the glass no longer engages")
	_check(surf._tip_on_screen(centre + Vector3(0, 0, 0.005), 1.0),
		"5 mm off the glass does")
	_touches.clear()
	_put_tip(centre + Vector3(0.0, 0.0, 0.003))
	await _frames(4)
	_check(not _touches.is_empty(), "fingertip on the glass reaches the core")
	_put_tip(centre + Vector3(0.10, 0.0, 0.003))
	await _frames(8)
	var last_true := Vector2.ZERO
	for t: Dictionary in _touches:
		if bool(t["pressed"]):
			last_true = t["uv"]
	# Slide clean off the right edge.
	_put_tip(centre + Vector3(0.30, 0.0, 0.003))
	await _frames(8)
	var releases: Array = _touches.filter(func(t: Dictionary) -> bool: return not bool(t["pressed"]))
	_check(not releases.is_empty(), "sliding off reports a release")
	if not releases.is_empty():
		var up_uv: Vector2 = (releases[releases.size() - 1] as Dictionary)["uv"]
		_check(up_uv.distance_to(last_true) < 1e-6,
			"release is the last in-window point (%v vs %v)" % [up_uv, last_true])
		_check(up_uv.x < 0.99, "and is NOT pinned to the border (x = %.4f)" % up_uv.x)
	_check(surf._claim_contact != null, "TV surface claims the disc on the glass")

	print("[probe] RESULT %s" % ("PASS" if not _fail else "FAIL"))
	get_tree().quit(1 if _fail else 0)

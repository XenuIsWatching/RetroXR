extends Node

## Exercises the TRIGGER-gated interaction mode on VRButton and VRSlider without
## a headset. Registers a real XRPositionalTracker so the rig's XRController3D
## goes ACTIVE (same trick as vr_poke_probe.gd), then drives the fingertip with
## set_pose() and the trigger with set_input(&"trigger", ...).
##
## PokeTip.tip_of() falls back to `global_position - basis.z * 0.06` when a
## controller has no PokeTip child, so parking the controller parks the tip.
##
## Run: godot --headless --path RetroXR res://Tools/vr/vr_trigger_probe.tscn

const TIP_FORWARD := 0.06   # PokeTip.TIP_FORWARD

var _fail := false
var _origin: XROrigin3D = null
var _tracker: XRPositionalTracker = null
var _ctrl: XRController3D = null

# Counters MUST be members, not locals captured by a lambda: GDScript closures
# capture locals BY VALUE, so `presses += 1` inside the callable would only ever
# bump the closure's private copy and every assertion would read 0.
var _presses := 0
var _presses2 := 0
var _changes := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[probe] PASS: %s" % msg)
	else:
		_fail = true
		print("[probe] FAIL: %s" % msg)


func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	_run.call_deferred()


## Park the controller so its poke tip lands exactly on `world_tip`.
func _put_tip(world_tip: Vector3) -> void:
	var world := Transform3D(Basis.IDENTITY, world_tip + Vector3(0, 0, TIP_FORWARD))
	var rel := _origin.global_transform.affine_inverse() * world
	_tracker.set_pose(&"default", rel, Vector3.ZERO, Vector3.ZERO,
		XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _set_trigger(v: float) -> void:
	_tracker.set_input(&"trigger", v)


func _make_button(where: Vector3) -> VRButton:
	var btn := VRButton.new()
	var mesh := MeshInstance3D.new()
	mesh.name = "ButtonMesh"
	var box := BoxMesh.new()
	box.size = Vector3(0.02, 0.01, 0.02)   # AABB +/- (0.01, 0.005, 0.01)
	mesh.mesh = box
	btn.add_child(mesh)                    # before entering the tree: @onready $ButtonMesh
	add_child(btn)
	btn.global_position = where
	return btn


func _make_slider(where: Vector3) -> VRSlider:
	var sl := VRSlider.new()
	var mesh := MeshInstance3D.new()
	mesh.name = "KnobMesh"
	var box := BoxMesh.new()
	box.size = Vector3(0.01, 0.01, 0.01)
	mesh.mesh = box
	sl.add_child(mesh)
	add_child(sl)
	sl.global_position = where
	sl.travel = 0.04
	sl.axis_local = Vector3(1, 0, 0)
	return sl


func _outline_color(w: WidgetOutline) -> Color:
	var mask: ShaderMaterial = w.material_override
	var outline: ShaderMaterial = mask.next_pass
	var c: Color = outline.get_shader_parameter("outline_color")
	return c


func _run() -> void:
	# ── Minimal XR rig so an XRController3D can go ACTIVE ─────────────────────
	_origin = XROrigin3D.new()
	add_child(_origin)
	_tracker = XRPositionalTracker.new()
	_tracker.name = &"left_hand"
	_tracker.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(_tracker)

	_ctrl = XRController3D.new()
	_ctrl.name = "LeftController"
	_ctrl.tracker = &"left_hand"
	_ctrl.pose = &"default"
	_origin.add_child(_ctrl)

	_put_tip(Vector3(0, 5, 0))   # parked far away
	_set_trigger(0.0)
	await get_tree().process_frame
	_check(_ctrl.get_is_active(), "XRController3D is ACTIVE via the fake tracker")

	var btn := _make_button(Vector3.ZERO)
	btn.button_pressed.connect(func() -> void: _presses += 1)

	var btn2 := _make_button(Vector3(0.2, 0, 0))
	btn2.button_pressed.connect(func() -> void: _presses2 += 1)

	# Widgets await one frame before collecting controllers.
	for i in 3:
		await get_tree().process_frame
	_check(btn._controllers.size() >= 1, "button collected the controller (%d)" % btn._controllers.size())
	_check(PokeTip.tip_of(_ctrl).distance_to(Vector3(0, 5, 0)) < 0.001,
		"poke tip tracks the steered controller (%s)" % PokeTip.tip_of(_ctrl))

	# ── 1. Interaction box: mesh AABB grown by interact_margin ────────────────
	btn.interact_margin = 0.02   # box becomes +/- (0.03, 0.025, 0.03)
	_check(btn._tip_in_box(Vector3(0.029, 0, 0)), "box: x=0.029 inside (limit 0.030)")
	_check(not btn._tip_in_box(Vector3(0.031, 0, 0)), "box: x=0.031 outside")
	_check(btn._tip_in_box(Vector3(0, 0.024, 0)), "box: y=0.024 inside (limit 0.025)")
	_check(not btn._tip_in_box(Vector3(0, 0.026, 0)), "box: y=0.026 outside")
	_check(btn._tip_in_box(Vector3(0, 0, -0.029)), "box: z=-0.029 inside")
	_check(not btn._tip_in_box(Vector3(0, 0, -0.031)), "box: z=-0.031 outside")
	# It is a BOX, not a sphere — the far corner is out even though a sphere of
	# the same reach would contain points that far along a single axis.
	_check(not btn._tip_in_box(Vector3(0.031, 0.026, 0.031)), "box: far corner outside")

	# ── 2. TOUCH mode still fires on proximity (no regression) ────────────────
	btn.require_trigger = false
	btn.trigger_radius = 0.01
	_put_tip(Vector3.ZERO)
	await get_tree().process_frame
	_check(_presses == 1, "TOUCH mode: fingertip alone fires once (got %d)" % _presses)
	_check(not btn._outline.visible, "TOUCH mode: no near-field outline (unchanged behaviour)")
	_put_tip(Vector3(0, 5, 0))
	await get_tree().process_frame
	_check(_presses == 1, "TOUCH mode: withdrawing does not re-fire (got %d)" % _presses)

	# ── 3. TRIGGER mode: proximity alone must NOT fire ────────────────────────
	_presses = 0
	btn.require_trigger = true
	_set_trigger(0.0)
	_put_tip(Vector3.ZERO)
	await get_tree().process_frame
	_check(_presses == 0, "TRIGGER mode: fingertip alone does NOT fire (got %d)" % _presses)
	_check(btn._armed, "TRIGGER mode: armed while inside the box")
	_check(btn._outline.visible, "TRIGGER mode: outline shown while armed")
	_check(_outline_color(btn._outline).is_equal_approx(WidgetOutline.HOVER_COLOR),
		"TRIGGER mode: armed outline is green %s" % _outline_color(btn._outline))

	# ── 4. The trigger's rising edge fires exactly once ───────────────────────
	_set_trigger(0.7)
	await get_tree().process_frame
	_check(_presses == 1, "TRIGGER mode: pulling the trigger fires (got %d)" % _presses)
	_check(_outline_color(btn._outline).is_equal_approx(WidgetOutline.ACTIVE_COLOR),
		"TRIGGER mode: engaged outline is amber %s" % _outline_color(btn._outline))
	_check(btn._mesh.position != Vector3.ZERO, "TRIGGER mode: mesh depressed while held")
	for i in 5:
		await get_tree().process_frame
	_check(_presses == 1, "TRIGGER mode: holding does not repeat (got %d)" % _presses)

	# ── 5. A held trigger must not sweep across a row of buttons ──────────────
	btn2.require_trigger = true
	btn2.interact_margin = 0.02
	_put_tip(Vector3(0.2, 0, 0))
	for i in 3:
		await get_tree().process_frame
	_check(_presses2 == 0, "re-arm: a HELD trigger does NOT fire the next button (got %d)" % _presses2)
	_check(btn2._armed, "re-arm: the next button is still armed (green) though")

	# ── 6. Releasing re-arms ──────────────────────────────────────────────────
	_set_trigger(0.0)
	await get_tree().process_frame
	_set_trigger(0.7)
	await get_tree().process_frame
	_check(_presses2 == 1, "re-arm: a fresh pull fires the second button (got %d)" % _presses2)
	_set_trigger(0.0)
	await get_tree().process_frame
	_check(not btn2._outline_amber, "release: outline drops back to green")

	# ── 7. Hysteresis: 0.5 sits between TRIGGER_OFF and TRIGGER_ON ────────────
	_presses = 0
	_put_tip(Vector3.ZERO)
	await get_tree().process_frame
	_set_trigger(0.5)
	for i in 3:
		await get_tree().process_frame
	_check(_presses == 0, "hysteresis: 0.5 is below TRIGGER_ON, no fire (got %d)" % _presses)
	_set_trigger(0.7)
	await get_tree().process_frame
	_check(_presses == 1, "hysteresis: 0.7 crosses TRIGGER_ON (got %d)" % _presses)
	_set_trigger(0.5)
	for i in 3:
		await get_tree().process_frame
	_set_trigger(0.7)
	await get_tree().process_frame
	_check(_presses == 1, "hysteresis: 0.5 never released it, so no re-fire (got %d)" % _presses)
	_set_trigger(0.0)
	await get_tree().process_frame

	# ── 8. One emit per frame, whatever the path (laser + hand overlap) ───────
	_presses = 0
	btn._activate()
	btn._activate()
	_check(_presses == 1, "dedupe: two activations in one frame emit once (got %d)" % _presses)

	# ── 9. Slider: latch on trigger, keep tracking outside the box ────────────
	_put_tip(Vector3(0, 5, 0))
	var sl := _make_slider(Vector3(0, 0, 0.5))
	sl.require_trigger = true
	sl.interact_margin = 0.02
	sl.value_changed.connect(func(_v: float) -> void: _changes += 1)
	for i in 3:
		await get_tree().process_frame
	_check(sl._controllers.size() >= 1, "slider collected the controller")

	# Fingertip on the knob, no trigger → armed and green, but no movement.
	sl.set_value_no_signal(0.5)
	_changes = 0
	_put_tip(sl.global_position)
	await get_tree().process_frame
	_check(_changes == 0, "slider TRIGGER mode: fingertip alone does not move it (got %d)" % _changes)
	_check(sl._armed, "slider: armed while inside the knob box")
	_check(sl._outline.visible, "slider: green outline while armed")

	# Pull the trigger, then drag well past the knob box along +X.
	_set_trigger(0.7)
	await get_tree().process_frame
	_check(sl._engaged_ctrl != null, "slider: the trigger latches the knob")
	_put_tip(sl.global_position + Vector3(0.3, 0, 0))
	for i in 3:
		await get_tree().process_frame
	_check(not sl._tip_in_box(PokeTip.tip_of(_ctrl)), "slider: the hand is now far outside the box")
	_check(sl._engaged_ctrl != null, "slider: the latch survives leaving the box mid-drag")
	_check(is_equal_approx(sl.value, 1.0), "slider: dragged to max (value %.3f)" % sl.value)
	_check(_outline_color(sl._outline).is_equal_approx(WidgetOutline.ACTIVE_COLOR),
		"slider: engaged outline is amber")

	# Releasing the trigger lets go.
	_set_trigger(0.0)
	await get_tree().process_frame
	_check(sl._engaged_ctrl == null, "slider: releasing the trigger disengages")

	# ── 10. Slider TOUCH mode unchanged ───────────────────────────────────────
	var sl2 := _make_slider(Vector3(0, 0, 1.0))
	sl2.require_trigger = false
	sl2.engage_radius = 0.035
	for i in 3:
		await get_tree().process_frame
	sl2.set_value_no_signal(0.5)
	_put_tip(sl2.global_position + Vector3(0.01, 0, 0))
	await get_tree().process_frame
	_check(sl2._engaged_ctrl != null, "slider TOUCH mode: proximity alone still engages")
	_check(not sl2._outline.visible, "slider TOUCH mode: no outline (unchanged behaviour)")

	print("[probe] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)

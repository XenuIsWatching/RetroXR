## grab_feel_probe — the two things that make picking something up feel right:
## the controller art gets out of the way, and the object comes to your hand.
##
## Run: godot --headless --path RetroXR res://Tools/vr/grab_feel_probe.tscn
extends Node3D

const PICKUP := preload("res://addons/godot-xr-tools/functions/function_pickup.tscn")
var _fail := false
var _tracker: XRControllerTracker = null


func _check(c: bool, m: String) -> void:
	print("[probe] %s: %s" % ["PASS" if c else "FAIL", m])
	if not c:
		_fail = true


func _ready() -> void:
	get_tree().create_timer(150.0).timeout.connect(func() -> void: get_tree().quit(1))
	_run.call_deferred()


func _run() -> void:
	var origin := XROrigin3D.new()
	add_child(origin)
	var ctrl := XRController3D.new()
	ctrl.set_script(load("res://Scripts/XR/controller_model.gd"))
	# The shipped default, and the case that matters: the fade must not depend on
	# the OPTIONS hands switch. Forcing it on here hid the fade being gated on it.
	ctrl.set("draw_hands", false)
	ctrl.tracker = &"left_hand"
	# The pickup has to exist BEFORE the controller enters the tree: its _ready is
	# where controller_model looks the child up and connects the grab signals.
	var pickup: Node3D = PICKUP.instantiate()
	ctrl.add_child(pickup)
	origin.add_child(ctrl)
	_tracker = XRControllerTracker.new()
	_tracker.name = &"left_hand"
	_tracker.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(_tracker)
	_tracker.set_pose(&"default", Transform3D(Basis.from_euler(Vector3(-0.5, 0.2, 0.1)),
		Vector3(0.0, 1.2, 0.0)),
		Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	for i in 8:
		await get_tree().process_frame

	var obj := XRToolsPickable.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.06, 0.09, 0.02)
	cs.shape = box
	obj.add_child(cs)
	add_child(obj)
	obj.freeze = true
	obj.global_transform = Transform3D(Basis.from_euler(Vector3(0.3, 0.7, 0.0)),
		Vector3(0.18, 1.12, -0.09))
	for i in 8:
		await get_tree().process_frame

	var hand_pos: Vector3 = pickup.global_position
	var start_basis: Basis = obj.global_transform.basis
	print("[probe] object starts %.0f mm from the grab point"
		% (obj.global_position.distance_to(hand_pos) * 1000.0))
	_check(obj.get("near_grab_speed") != null, "near_grab_speed export exists")

	# Exercise the NEAR branch: a ranged grab already snaps to the hand, the near
	# one is what used to keep the offset.
	pickup.set("picked_up_ranged", false)
	obj.pick_up(pickup)
	var drv: Node = obj.get("_grab_driver")
	if drv != null:
		print("[probe] driver state %s  lerp_duration %.4f s"
			% [drv.get("state"), float(drv.get("lerp_duration"))])
	await get_tree().process_frame
	var after_one: float = obj.global_position.distance_to(pickup.global_position)
	_check(after_one > 0.010,
		"it does not teleport on the first frame (%.0f mm out)" % (after_one * 1000.0))
	for i in 45:
		await get_tree().process_frame
	var settled: float = obj.global_position.distance_to(pickup.global_position)
	_check(settled < 0.010, "it arrives at the hand (%.1f mm)" % (settled * 1000.0))
	var turn: float = rad_to_deg(obj.global_transform.basis.get_rotation_quaternion().angle_to(
		start_basis.get_rotation_quaternion()))
	_check(turn < 2.0, "keeping the angle it was grabbed at (%.1f deg of spin)" % turn)
	# The controller art must fade out on a grab and back in on release. No model
	# loads headless (no XR profile), so this checks the fade state machine and
	# its wiring to the pickup signals, not the pixels.
	# pick_up was called directly above, so FunctionPickup never announced it.
	# Drive its signal: the wiring is what this is testing. picked_up_object has
	# to be set the way _pick_up_object sets it — controller_model polls it to
	# catch a held object freed under the hand, and reads null as "not holding".
	pickup.set("picked_up_object", obj)
	pickup.emit_signal("has_picked_up", obj)
	await get_tree().process_frame
	_check(float(ctrl.get("_fade_target")) < 0.01, "grabbing targets the art at 0 alpha")
	for i in 20:
		await get_tree().process_frame
	_check(float(ctrl.get("_fade")) < 0.01,
		"and it gets there (%.2f)" % float(ctrl.get("_fade")))
	obj.let_go(pickup, Vector3.ZERO, Vector3.ZERO)
	pickup.set("picked_up_object", null)
	pickup.emit_signal("has_dropped")
	await get_tree().process_frame
	_check(float(ctrl.get("_fade_target")) > 0.99, "releasing targets it back at 1")
	for i in 20:
		await get_tree().process_frame
	_check(float(ctrl.get("_fade")) > 0.99,
		"and it comes back (%.2f)" % float(ctrl.get("_fade")))
	print("[probe] RESULT %s" % ("PASS" if not _fail else "FAIL"))
	get_tree().quit(1 if _fail else 0)

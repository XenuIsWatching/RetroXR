## capsense_probe — synthetic coverage for XR display modes, hand fallback,
## fingertip routing and grab suppression. No headset or runtime mesh required.
##
## Run: godot --headless --path RetroXR res://Tools/vr/capsense_probe.tscn
extends Node3D

const PICKUP := preload("res://addons/godot-xr-tools/functions/function_pickup.tscn")
const FINGER_SNAP_SCRIPT := preload("res://Scripts/XR/capsense_finger_snap.gd")

var _fail := false
var _origin: XROrigin3D
var _ctrl: XRController3D
var _hand: CapsenseHand
var _pickup: XRToolsFunctionPickup
var _controller_tracker: XRControllerTracker
var _hand_tracker: XRHandTracker


func _check(ok: bool, message: String) -> void:
	print("[probe] %s: %s" % ["PASS" if ok else "FAIL", message])
	if not ok:
		_fail = true


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void: get_tree().quit(1))
	_run.call_deferred()


func _run() -> void:
	_check(AppPrefs._prefs_xr_display_mode({}, "xr_display_mode",
		AppPrefs.XRDisplayMode.BOTH) == AppPrefs.XRDisplayMode.BOTH,
		"a missing preference defaults to Controllers + Hands")
	_check(AppPrefs._prefs_xr_display_mode({"xr_display_mode": 99}, "xr_display_mode",
		AppPrefs.XRDisplayMode.BOTH) == AppPrefs.XRDisplayMode.BOTH,
		"an invalid saved display mode keeps the default")
	_build_rig()
	_check(not _hand.show_when_tracked,
		"Capsense owns visibility instead of XRNode3D tracking updates")
	_set_tracking(true, XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER)
	await _frames(5)

	var fallback := _ctrl.global_position - _ctrl.global_basis.z * PokeTip.TIP_FORWARD
	var expected_tip := Vector3(0.12, 1.03, -0.02)

	AppPrefs.xr_display_mode = AppPrefs.XRDisplayMode.CONTROLLERS
	_hand.apply_display_mode()
	_check(not _hand.visible, "Controllers hides the Capsense hand")
	_check(bool(_ctrl.get("_display_visible")), "Controllers shows controller art")
	_check(PokeTip.tip_of(_ctrl).distance_to(fallback) < 0.0001,
		"Controllers uses the forward poke fallback")

	AppPrefs.xr_display_mode = AppPrefs.XRDisplayMode.HANDS
	_hand.apply_display_mode()
	_check(_hand.visible, "Hands shows valid runtime geometry")
	_check(not bool(_ctrl.get("_display_visible")), "Hands hides controller art")
	_check(PokeTip.tip_of(_ctrl).distance_to(expected_tip) < 0.0001,
		"Hands uses the current index-tip joint (%v)" % PokeTip.tip_of(_ctrl))
	_check(_hand.active_motion_range() == OpenXRInterface.HAND_MOTION_RANGE_UNOBSTRUCTED,
		"Hands requests unobstructed motion")

	AppPrefs.xr_display_mode = AppPrefs.XRDisplayMode.BOTH
	_hand.apply_display_mode()
	_check(_hand.visible and bool(_ctrl.get("_display_visible")),
		"Controllers + Hands shows both for controller-sourced joints")
	_check(_hand.active_motion_range() == OpenXRInterface.HAND_MOTION_RANGE_CONFORM_TO_CONTROLLER,
		"Controllers + Hands conforms controller-sourced joints")

	_set_tracking(true, XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED)
	_hand.apply_display_mode()
	_check(_hand.visible and not bool(_ctrl.get("_display_visible")),
		"camera hand takes over when the controller is put down")
	_check(_hand.active_motion_range() == OpenXRInterface.HAND_MOTION_RANGE_UNOBSTRUCTED,
		"camera hand uses unobstructed motion")

	_hand.set_mesh_ready_override(false)
	_hand.apply_display_mode()
	_check(not _hand.visible and bool(_ctrl.get("_display_visible")),
		"missing runtime mesh falls back to controller art")
	_hand.set_mesh_ready_override(true)
	_set_tracking(false, XRHandTracker.HAND_TRACKING_SOURCE_NOT_TRACKED)
	_hand.apply_display_mode()
	_check(not _hand.visible and bool(_ctrl.get("_display_visible")),
		"missing joints fall back to controller art")

	_set_tracking(true, XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER)
	AppPrefs.xr_display_mode = AppPrefs.XRDisplayMode.HANDS
	_hand.apply_display_mode()
	var held := Node3D.new()
	add_child(held)
	_pickup.picked_up_object = held
	_pickup.has_picked_up.emit(held)
	_hand.apply_display_mode()
	_check(not _hand.visible and not PokeTip.is_poking(_ctrl),
		"a physical grab hides Capsense and suppresses poke")
	_pickup.picked_up_object = null
	_pickup.has_dropped.emit()
	_hand.apply_display_mode()
	_check(_hand.visible and not bool(_ctrl.get("_display_visible")),
		"drop restores Hands mode without restoring controller art")
	_check(float(_ctrl.get("_fade_target")) < 0.01,
		"drop cannot override the display-mode visibility gate")

	var ray_obj := XRToolsPickable.new()
	add_child(ray_obj)
	_pickup.set("_ray_grab_object", ray_obj)
	_hand.apply_display_mode()
	_check(not _hand.visible and not PokeTip.is_poking(_ctrl),
		"a ray grab hides Capsense and suppresses poke")
	_pickup.set("_ray_grab_object", null)
	_hand.apply_display_mode()
	_check(_hand.visible, "ending the ray grab restores the selected mode")

	await _check_finger_snap()

	print("[probe] RESULT %s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)


func _build_rig() -> void:
	_origin = XROrigin3D.new()
	add_child(_origin)
	_ctrl = XRController3D.new()
	_ctrl.name = "Controller"
	_ctrl.tracker = &"left_hand"
	_ctrl.set_script(load("res://Scripts/XR/controller_model.gd"))
	_pickup = PICKUP.instantiate()
	_pickup.name = "FunctionPickup"
	_ctrl.add_child(_pickup)
	var poke := PokeTip.new()
	poke.name = "PokeTip"
	_ctrl.add_child(poke)
	_origin.add_child(_ctrl)

	_hand = CapsenseHand.new()
	_hand.name = "CapsenseHand"
	_hand.tracker = &"/user/hand_tracker/left"
	# Reproduce the scene misconfiguration that caused pose_changed to briefly
	# resurrect a hand hidden by CapsenseHand while an object was held.
	_hand.show_when_tracked = true
	_hand.controller_path = NodePath("../Controller")
	_origin.add_child(_hand)
	_hand.set_mesh_ready_override(true)

	_controller_tracker = XRControllerTracker.new()
	_controller_tracker.name = &"left_hand"
	_controller_tracker.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(_controller_tracker)
	_controller_tracker.set_pose(&"default", Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)),
		Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)

	_hand_tracker = XRHandTracker.new()
	_hand_tracker.name = &"/user/hand_tracker/left"
	_hand_tracker.type = XRServer.TRACKER_HAND
	XRServer.add_tracker(_hand_tracker)
	_hand_tracker.set_pose(&"default", Transform3D(Basis.IDENTITY, Vector3(0.1, 1.0, 0.0)),
		Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	_hand_tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM,
		Transform3D(Basis.IDENTITY, Vector3(0.1, 1.0, 0.0)))
	_hand_tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
		Transform3D(Basis.IDENTITY, Vector3(0.12, 1.03, -0.02)))
	var flags := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID \
		| XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED
	_hand_tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM, flags)
	_hand_tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP, flags)


func _set_tracking(has_data: bool, source: int) -> void:
	_hand_tracker.has_tracking_data = has_data
	_hand_tracker.hand_tracking_source = source as XRHandTracker.HandTrackingSource


func _frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame


func _check_finger_snap() -> void:
	var skeleton := Skeleton3D.new()
	add_child(skeleton)
	for i in XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP + 1:
		skeleton.add_bone("Bone%d" % i)
	# A straight 80 mm index chain occupying the standard OpenXR joint indices.
	skeleton.set_bone_parent(6, 0)
	for i in range(7, 11):
		skeleton.set_bone_parent(i, i - 1)
		var segment := Transform3D(Basis.IDENTITY, Vector3(0.02, 0, 0))
		skeleton.set_bone_rest(i, segment)
		skeleton.set_bone_pose(i, segment)
	await get_tree().process_frame
	skeleton.force_update_all_bone_transforms()

	var before_lengths: Array[float] = []
	var before_scales: Array[Vector3] = []
	for i in range(7, 11):
		before_lengths.append(skeleton.get_bone_global_pose(i).origin.distance_to(
			skeleton.get_bone_global_pose(i - 1).origin))
		before_scales.append(skeleton.get_bone_global_pose(i).basis.get_scale())
	var raw_tip_before := PokeTip.tip_of(_ctrl)
	var start := skeleton.get_bone_global_pose(10).origin
	var target := start + Vector3(-0.004, 0.012, 0.0)
	var solver: SkeletonModifier3D = FINGER_SNAP_SCRIPT.new()
	var skin_target: Vector3 = solver._skin_target(Vector3.ZERO, Vector3.UP, 0.006)
	_check(skin_target.distance_to(Vector3(0, 0.006, 0)) < 1e-6,
		"fingertip joint stays one radius outside the contacted surface")
	solver._solve(skeleton, target)
	skeleton.force_update_all_bone_transforms()
	var end := skeleton.get_bone_global_pose(10).origin
	_check(end.distance_to(target) < start.distance_to(target) * 0.35,
		"finger IK moves the visual tip onto a nearby surface (%.2f -> %.2f mm)" % [
			start.distance_to(target) * 1000.0, end.distance_to(target) * 1000.0])
	var lengths_unchanged := true
	for i in range(7, 11):
		var after_pose := skeleton.get_bone_global_pose(i)
		var after := after_pose.origin.distance_to(
			skeleton.get_bone_global_pose(i - 1).origin)
		lengths_unchanged = lengths_unchanged and absf(after - before_lengths[i - 7]) < 1e-6
		lengths_unchanged = lengths_unchanged \
			and after_pose.basis.get_scale().distance_to(before_scales[i - 7]) < 1e-6
	_check(lengths_unchanged, "finger IK preserves every bone length and scale")
	_check(PokeTip.tip_of(_ctrl).distance_to(raw_tip_before) < 1e-6,
		"visual finger IK does not move the tracked interaction tip")

	var settled := skeleton.get_bone_global_pose(10).origin
	solver._solve(skeleton, settled + Vector3(0, float(solver.MAX_REACH) + 0.01, 0))
	skeleton.force_update_all_bone_transforms()
	_check(skeleton.get_bone_global_pose(10).origin.distance_to(settled) < 1e-6,
		"a surface outside the snap range leaves the finger untouched")
	skeleton.queue_free()

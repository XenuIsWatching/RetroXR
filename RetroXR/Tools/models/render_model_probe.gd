## render_model_probe — what the runtime-supplied controller art does when there
## is no runtime: it must resolve to nothing, quietly, and every contract the room
## depends on must still hold over an empty model.
##
## Also pins the two pieces of arithmetic that a headset would otherwise be the
## only way to check: the aim-to-grip correction, and re-applying a fade to
## geometry that arrived after the fade started.
##
## Run: godot --headless --path RetroXR res://Tools/models/render_model_probe.tscn
extends Node3D

var _fail := false
var _tracker: XRControllerTracker = null
## Each bone as the rig rests it, which is what a press is measured against.
var _baseline := {}


func _check(c: bool, m: String) -> void:
	print("[probe] %s: %s" % ["PASS" if c else "FAIL", m])
	if not c:
		_fail = true


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void: get_tree().quit(1))
	_run.call_deferred()


func _run() -> void:
	var origin := XROrigin3D.new()
	add_child(origin)
	var ctrl := XRController3D.new()
	ctrl.set_script(load("res://Scripts/XR/controller_model.gd"))
	ctrl.tracker = &"left_hand"
	# Deliberately no FunctionPickup: _check_hold_state exists to undo a fade that
	# was left hanging with nothing in hand, so with a pickup present every
	# set_model_visible(false) here would be reversed on the next frame. What a
	# grab does to the art is grab_feel_probe's subject; this one is about what
	# the art layer does with a fade level.
	origin.add_child(ctrl)

	_tracker = XRControllerTracker.new()
	_tracker.name = &"left_hand"
	_tracker.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(_tracker)
	_set_poses()
	for i in 8:
		await get_tree().process_frame

	var art := ctrl.get_node_or_null("ModelArt") as ControllerArt
	_check(art != null, "the controller builds a ControllerArt child")
	if art == null:
		_finish()
		return

	# ── No runtime ────────────────────────────────────────────────────────
	_check(art.source == ControllerArt.Source.NONE,
		"no OpenXR session resolves to no art source (got %d)" % art.source)
	_check(art.get_child_count() == 0,
		"nothing is instantiated without a session (%d children)" % art.get_child_count())
	_check(art.fade_materials.is_empty(), "no materials are claimed")

	# A profile arriving is what drives the retry; it must not throw where the
	# runtime classes are absent or idle.
	_tracker.profile = "/interaction_profiles/oculus/touch_controller"
	for i in 4:
		await get_tree().process_frame
	_check(art.source == ControllerArt.Source.NONE,
		"a controller profile alone does not conjure a model")

	# ── The fade contract over an empty model ─────────────────────────────
	ctrl.call("set_model_visible", false)
	for i in 12:
		await get_tree().process_frame
	_check(not art.visible, "fading out hides the art node")
	ctrl.call("set_model_visible", true)
	for i in 12:
		await get_tree().process_frame
	_check(art.visible, "fading back in shows it again")

	# ── Aim-to-grip correction ────────────────────────────────────────────
	# The controller follows the pose its `pose` property names, which this
	# project's action map binds to /input/aim/pose; a runtime model is authored
	# in grip space. Getting this wrong puts the controller in front of the hand.
	var aim := Transform3D(Basis.from_euler(Vector3(-0.5, 0.2, 0.1)), Vector3(0.0, 1.2, 0.0))
	var grip := Transform3D(Basis.from_euler(Vector3(-1.1, 0.05, -0.2)), Vector3(0.01, 1.17, 0.03))
	art.call("_ensure_grip_anchor")
	art.call("_update_grip_anchor")
	var anchor := art.get_node_or_null("GripAnchor") as Node3D
	_check(anchor != null, "the grip anchor is built on demand")
	if anchor != null:
		var want := aim.affine_inverse() * grip
		var got := anchor.transform
		_check(got.origin.distance_to(want.origin) < 0.0005,
			"grip anchor origin %.4f mm off" % (got.origin.distance_to(want.origin) * 1000.0))
		var dot: float = absf(got.basis.get_rotation_quaternion().dot(
			want.basis.get_rotation_quaternion()))
		_check(dot > 0.9999, "grip anchor rotation matches (dot %.5f)" % dot)
		# Composed back through the controller it must land on the grip pose.
		_check((aim * got).origin.distance_to(grip.origin) < 0.0005,
			"the art ends up at the grip pose, not the aim pose")

	# ── Geometry that arrives mid-fade ────────────────────────────────────
	# A runtime hands models over on its own schedule, and a grab in progress
	# must not be left with an opaque controller inside the held object.
	ctrl.call("set_model_visible", false)
	for i in 12:
		await get_tree().process_frame
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	var src := StandardMaterial3D.new()
	src.albedo_color = Color(0.8, 0.2, 0.1, 1.0)
	mesh.set_surface_override_material(0, src)
	art.add_child(mesh)
	art.call("_mark_dirty")
	for i in 6:
		await get_tree().process_frame

	var active := mesh.get_active_material(0) as BaseMaterial3D
	_check(active != null and active != src,
		"a runtime surface gets a material of our own, not the one it came with")
	if active != null:
		_check(active.albedo_color.a < 0.01,
			"late geometry inherits the current fade (alpha %.3f)" % active.albedo_color.a)
		_check(active.albedo_color.r > 0.7, "the duplicate keeps the original colour")
		_check(active.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA,
			"and is switched to alpha blending")
	_check(art.fade_materials.size() == 1,
		"one material is claimed, not one per walk (%d)" % art.fade_materials.size())

	ctrl.call("set_model_visible", true)
	for i in 12:
		await get_tree().process_frame
	var back := mesh.get_active_material(0) as BaseMaterial3D
	_check(back != null and back.albedo_color.a > 0.99, "and comes back opaque")
	_check(back != null and back.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED,
		"with alpha blending switched back off")

	# A surface the runtime shaded itself cannot take an alpha; it must be hidden
	# for the whole of a partial fade rather than left standing opaque.
	var shaded := MeshInstance3D.new()
	shaded.mesh = BoxMesh.new()
	shaded.set_surface_override_material(0, ShaderMaterial.new())
	art.add_child(shaded)
	art.call("_mark_dirty")
	ctrl.call("set_model_visible", false)
	for i in 12:
		await get_tree().process_frame
	_check(art.opaque_only.has(shaded), "an unfadeable surface is listed")
	_check(not shaded.visible, "and hidden instead of faded")

	# ── Driving a rig the way the runtime ships one ───────────────────────
	await _check_rig(ctrl, art)

	_finish()


## Meta ships the controller with an AnimationPlayer and lets it describe itself:
## one five-second clip in which each input actuates in turn, buttons press
## twice, and the thumbstick is swept round a circle because a clip has one
## timeline and a stick has two axes. This builds a rig of that shape - with a
## deliberately skewed bone frame, so nothing can pass by assuming identity - and
## checks what the inputs do to it.
func _check_rig(ctrl: XRController3D, art: ControllerArt) -> void:
	const LEAN := 27.0
	const TRIGGER := 18.0
	const PRESS := 0.001

	# The model hangs off a grip anchor tilted out of the hand, as the runtime's
	# does, and the hand itself is not at the origin.
	ctrl.transform = Transform3D(Basis.from_euler(Vector3(-0.25, 0.6, 0.1)), Vector3(0.2, 1.1, -0.3))
	art.transform = Transform3D(Basis.from_euler(Vector3(-1.05, 0.0, 0.0)), Vector3(0.0, -0.02, -0.046))

	var skel := Skeleton3D.new()
	skel.name = "Skeleton3D"
	art.add_child(skel)
	var root := skel.add_bone("controller_world")
	for bone_name: String in ["b_trigger_front", "b_button_x", "b_thumbstick"]:
		var idx := skel.add_bone(bone_name)
		skel.set_bone_parent(idx, root)
		skel.set_bone_rest(idx, Transform3D(
			Basis.from_euler(Vector3(0.4, -0.9, 0.25)), Vector3(0.01, 0.02, -0.03)))
		skel.set_bone_pose(idx, skel.get_bone_rest(idx))
	await get_tree().process_frame

	var clip := Animation.new()
	clip.length = 5.0
	var trigger_rest := Quaternion(Vector3(0.1, 0.2, 0.97).normalized(), deg_to_rad(13.0))
	var t := clip.add_track(Animation.TYPE_ROTATION_3D)
	clip.track_set_path(t, NodePath("Skeleton3D:b_trigger_front"))
	clip.rotation_track_insert_key(t, 0.0, trigger_rest)
	clip.rotation_track_insert_key(t, 0.60, trigger_rest)
	clip.rotation_track_insert_key(t, 0.67,
		trigger_rest * Quaternion(Vector3.RIGHT, deg_to_rad(TRIGGER)))
	clip.rotation_track_insert_key(t, 0.80, trigger_rest)

	# The bounce: pressed, released, pressed again. Playing this back as a
	# timeline makes a half-pressed button pop out again.
	var p := clip.add_track(Animation.TYPE_POSITION_3D)
	clip.track_set_path(p, NodePath("Skeleton3D:b_button_x"))
	var button_rest := Vector3(0.009, 0.005, 0.004)
	clip.position_track_insert_key(p, 0.0, button_rest)
	clip.position_track_insert_key(p, 0.20, button_rest)
	clip.position_track_insert_key(p, 0.25, button_rest + Vector3(0.0, 0.0, -PRESS))
	clip.position_track_insert_key(p, 0.30, button_rest)
	clip.position_track_insert_key(p, 0.45, button_rest + Vector3(0.0, 0.0, -PRESS))
	clip.position_track_insert_key(p, 0.55, button_rest)

	# A stick stands up out of the controller face, leaning back a little. The
	# shaft is authored in the hand's terms and carried into the bone's, rather
	# than picked to make the arithmetic easy.
	var stick_rest := Quaternion(Vector3(0.0, 0.5, 0.86).normalized(), deg_to_rad(16.0))
	var bone := skel.find_bone("b_thumbstick")
	var to_bone := ((ctrl.global_transform.affine_inverse() * skel.global_transform
		* skel.get_bone_global_pose(skel.get_bone_parent(bone))).basis * Basis(stick_rest)).inverse()
	var shaft: Vector3 = (to_bone * Vector3(0.0, 0.94, -0.34).normalized()).normalized()

	var sweep := clip.add_track(Animation.TYPE_ROTATION_3D)
	clip.track_set_path(sweep, NodePath("Skeleton3D:b_thumbstick"))
	clip.rotation_track_insert_key(sweep, 1.0, stick_rest)
	var u := shaft.cross(Vector3.RIGHT).normalized()
	var v := shaft.cross(u).normalized()
	for i in 16:
		var a: float = TAU * float(i) / 16.0
		# Leaning towards (u cos + v sin) is a turn about the shaft crossed with it.
		var lean: Vector3 = u * cos(a) + v * sin(a)
		clip.rotation_track_insert_key(sweep, 1.2 + 0.1 * float(i),
			stick_rest * Quaternion(shaft.cross(lean).normalized(), deg_to_rad(LEAN)))
	clip.rotation_track_insert_key(sweep, 3.0, stick_rest)

	var lib := AnimationLibrary.new()
	lib.add_animation("All Animations", clip)
	var anim := AnimationPlayer.new()
	art.add_child(anim)
	anim.add_animation_library("", lib)
	anim.play("All Animations")

	art.source = ControllerArt.Source.VENDOR_FB
	ctrl.call("_resolve_rig")
	await get_tree().process_frame
	_rebase(ctrl, skel)

	_check(not anim.is_playing(), "the rig's own clip is stopped, not left playing over the inputs")
	var driven: Dictionary = ctrl.get("_driven")
	_check(driven.size() == 3, "every animated bone is picked up (%d)" % driven.size())
	var stick: Dictionary = ctrl.get("_stick")
	_check(absf((stick.get("shaft", Vector3.ZERO) as Vector3).dot(shaft)) > 0.999,
		"the shaft is recovered from the sweep")

	# One input, one bone.
	ctrl.call("_on_float_changed", "trigger", 1.0)
	var turned := _turn(skel, "b_trigger_front")
	_check(absf(turned - TRIGGER) < 0.5,
		"a full pull turns the trigger as far as the rig does (%.1f of %.1f deg)" % [turned, TRIGGER])
	_check(_turn(skel, "b_thumbstick") < 0.2, "and leaves the stick alone")
	ctrl.call("_on_float_changed", "trigger", 0.5)
	_check(absf(_turn(skel, "b_trigger_front") - TRIGGER * 0.5) < 0.5,
		"half a pull is half the travel (%.1f deg)" % _turn(skel, "b_trigger_front"))
	ctrl.call("_on_float_changed", "trigger", 0.0)
	_check(_turn(skel, "b_trigger_front") < 0.2,
		"releasing puts it back (%.3f deg out)" % _turn(skel, "b_trigger_front"))

	# The bounce.
	ctrl.call("_on_button_pressed", "ax_button")
	var pressed := _shift(skel, "b_button_x")
	_check(absf(pressed - PRESS * 1000.0) < 0.02,
		"a press travels the rig's full 1 mm (%.3f mm)" % pressed)
	ctrl.call("_on_button_released", "ax_button")
	_check(_shift(skel, "b_button_x") < 0.005, "and comes back out")
	# Sampling the clip by time here would find the button already released.
	ctrl.call("_on_float_changed", "nonsense", 0.5)
	_check(_shift(skel, "b_button_x") < 0.005, "an unknown action moves nothing")

	# The stick leans where it is pushed.
	var leans: Array[float] = []
	for push: Vector2 in [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0),
			Vector2(0.7, 0.7)]:
		ctrl.call("_on_vec2_changed", "primary", push)
		leans.append(_tip_travel_3d(ctrl, skel, shaft).length())
		_check(_tip_travel(ctrl, skel, shaft).normalized().dot(push.normalized()) > 0.97,
			"pushed %s, tip goes %s" % [push, _tip_travel(ctrl, skel, shaft).normalized()])
	var spread: float = leans.max() - leans.min()
	_check(spread < 0.0005,
		"and leans the same distance whichever way (spread %.3f mm)" % (spread * 1000.0))

	ctrl.call("_on_vec2_changed", "primary", Vector2(0, 0.5))
	var half := _tip_travel_3d(ctrl, skel, shaft).length()
	_check(half < leans[0] * 0.75,
		"a half push leans less (%.2f vs %.2f mm)" % [half * 1000.0, leans[0] * 1000.0])

	# The hand moves after the rig was read. A model loads while the controllers
	# are still asleep, so whatever frame was current then is not the one the
	# stick is pushed in; the art also hangs off a grip anchor that stays at
	# identity until a pose arrives.
	ctrl.transform = Transform3D(Basis.from_euler(Vector3(0.15, -0.9, -0.2)), Vector3(-0.4, 1.3, 0.25))
	await get_tree().process_frame
	_rebase(ctrl, skel)
	for push: Vector2 in [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]:
		ctrl.call("_on_vec2_changed", "primary", push)
		var went := _tip_travel(ctrl, skel, shaft)
		_check(went.normalized().dot(push.normalized()) > 0.97,
			"hand moved, pushed %s, tip still goes %s" % [push, went.normalized()])

	# Runtime render-model nodes own their skeleton and can replace it between two
	# controller input signals. The cached reference then remains non-null but is
	# a previously freed instance — exactly the state that used to throw from
	# _stick_frame(). Both stick and button paths must discard it quietly.
	skel.free()
	ctrl.call("_on_vec2_changed", "primary", Vector2(0.6, 0.4))
	ctrl.call("_on_float_changed", "trigger", 1.0)
	_check(ctrl.get("_skeleton") == null,
		"a freed runtime skeleton is invalidated before the next input")
	_check((ctrl.get("_stick") as Dictionary).is_empty(),
		"and its stale stick geometry is discarded with it")


## Everything is measured from where the CLIP rests each bone, which is not where
## the skeleton's own rest puts it - a rig is free to disagree with itself, and
## this one deliberately does.
func _rebase(ctrl: XRController3D, skel: Skeleton3D) -> void:
	_settle(ctrl)
	_baseline.clear()
	for i in skel.get_bone_count():
		_baseline[skel.get_bone_name(i)] = {
			"rot": skel.get_bone_pose_rotation(i),
			"pos": skel.get_bone_pose_position(i),
			"global": skel.get_bone_global_pose(i),
		}


## Put every input back to nothing, so a measurement starts from the rig's rest.
func _settle(ctrl: XRController3D) -> void:
	ctrl.call("_on_float_changed", "trigger", 0.0)
	ctrl.call("_on_float_changed", "grip", 0.0)
	ctrl.call("_on_vec2_changed", "primary", Vector2.ZERO)
	for button: String in ["ax_button", "by_button", "menu_button"]:
		ctrl.call("_on_button_released", button)


## The whole distance the stick's tip travelled, in the hand's own frame. It
## swings on a cone, so it rises as well as leans and the flat shadow is short.
func _tip_travel_3d(ctrl: XRController3D, skel: Skeleton3D, shaft: Vector3) -> Vector3:
	var bone := skel.find_bone("b_thumbstick")
	var to_hand := ctrl.global_transform.affine_inverse() * skel.global_transform
	var tip := shaft * 0.02
	var was: Transform3D = _baseline["b_thumbstick"]["global"]
	return (to_hand * skel.get_bone_global_pose(bone) * tip) - (to_hand * was * tip)


## Which way the tip went, read the way a stick is pushed: +X right, +Y forward.
func _tip_travel(ctrl: XRController3D, skel: Skeleton3D, shaft: Vector3) -> Vector2:
	var moved := _tip_travel_3d(ctrl, skel, shaft)
	return Vector2(moved.x, -moved.z)


func _turn(skel: Skeleton3D, bone_name: String) -> float:
	var bone := skel.find_bone(bone_name)
	return rad_to_deg((_baseline[bone_name]["rot"] as Quaternion).angle_to(
		skel.get_bone_pose_rotation(bone)))


func _shift(skel: Skeleton3D, bone_name: String) -> float:
	var bone := skel.find_bone(bone_name)
	return (_baseline[bone_name]["pos"] as Vector3).distance_to(
		skel.get_bone_pose_position(bone)) * 1000.0


func _set_poses() -> void:
	_tracker.set_pose(&"default",
		Transform3D(Basis.from_euler(Vector3(-0.5, 0.2, 0.1)), Vector3(0.0, 1.2, 0.0)),
		Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	_tracker.set_pose(&"grip",
		Transform3D(Basis.from_euler(Vector3(-1.1, 0.05, -0.2)), Vector3(0.01, 1.17, 0.03)),
		Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _finish() -> void:
	print("[probe] %s" % ("FAILURES" if _fail else "all passed"))
	get_tree().quit(1 if _fail else 0)

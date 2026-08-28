## quest_render_model_probe — which controller-art tier a real headset serves,
## and what it hands over.
##
## Answers the questions no desktop run can: whether the runtime supplies a model
## at all, whether it arrives rigged (the core tier animates its own buttons, the
## Meta vendor tier hands back a plain glTF), where it sits relative to the
## controller's aim pose, and what it looks like.
##
## Ships as its own package (QuestRenderModelProbe preset, custom feature
## "rendermodelprobe") so the installed RetroXR is never disturbed. Read the
## [rmprobe] lines with: adb logcat -s 'godot:*'
extends Node3D

## Seconds at which the loaded model is re-described. A controller that is asleep
## when the session begins only turns up on a later pass.
const SAMPLES: Array[float] = [2.0, 6.0, 12.0, 20.0, 30.0]
const SHOT_PATH := "user://render_model.png"
const FINGER_SNAP_SCRIPT := preload("res://Scripts/XR/capsense_finger_snap.gd")

var _frames := 0
var _elapsed := 0.0
var _controllers: Array[XRController3D] = []
var _hands: Array[CapsenseHand] = []
## The thumbstick bone with nothing pushed, as a baseline for the lean readings.
var _rest_tip := Transform3D.IDENTITY


func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func() -> void: get_tree().quit(0))

	var xri: XRInterface = XRServer.find_interface("OpenXR")
	var initialized: bool = xri != null and xri.is_initialized()
	print("[rmprobe] OpenXR interface=%s initialized=%s" % [xri != null, initialized])
	if initialized:
		xri.set_play_area_mode(XRInterface.XR_PLAY_AREA_ROOMSCALE)
		get_viewport().use_xr = true
		if Engine.has_singleton("OpenXRMetaSimultaneousHandsAndControllersExtension"):
			var simultaneous: Object = Engine.get_singleton(
				"OpenXRMetaSimultaneousHandsAndControllersExtension")
			if simultaneous.call("is_simultaneous_hands_and_controllers_supported"):
				simultaneous.call("resume_simultaneous_hands_and_controllers_tracking")
	AppPrefs.xr_display_mode = AppPrefs.XRDisplayMode.BOTH

	print("[rmprobe] settings core=%s meta=%s" % [
		ProjectSettings.get_setting("xr/openxr/extensions/render_model", false),
		ProjectSettings.get_setting("xr/openxr/extensions/meta/render_model", false)])
	_report_classes()

	var origin := XROrigin3D.new()
	add_child(origin)
	var cam := XRCamera3D.new()
	origin.add_child(cam)
	for hand: StringName in [&"left_hand", &"right_hand"]:
		var ctrl := XRController3D.new()
		ctrl.name = "LeftController" if hand == &"left_hand" else "RightController"
		ctrl.set_script(load("res://Scripts/XR/controller_model.gd"))
		ctrl.tracker = hand
		origin.add_child(ctrl)
		_controllers.append(ctrl)
	for i in 2:
		var capsense := CapsenseHand.new()
		capsense.name = "LeftCapsenseHand" if i == 0 else "RightCapsenseHand"
		capsense.tracker = &"/user/hand_tracker/left" if i == 0 \
			else &"/user/hand_tracker/right"
		capsense.controller_path = NodePath("../%s" % _controllers[i].name)
		capsense.hand = i
		var mesh: Node = ClassDB.instantiate("OpenXRFbHandTrackingMesh")
		mesh.name = "OpenXRFbHandTrackingMesh"
		mesh.set("hand", i)
		mesh.set("material", load("res://Scenes/Objects/hand_poses/held_hand_material.tres"))
		capsense.add_child(mesh)
		var modifier := XRHandModifier3D.new()
		modifier.hand_tracker = capsense.tracker
		mesh.add_child(modifier)
		var finger_snap: SkeletonModifier3D = FINGER_SNAP_SCRIPT.new()
		mesh.add_child(finger_snap)
		origin.add_child(capsense)
		_hands.append(capsense)

	_run.call_deferred()


func _process(delta: float) -> void:
	_frames += 1
	_elapsed += delta


func _run() -> void:
	for t: float in SAMPLES:
		await get_tree().create_timer(maxf(0.1, t - _elapsed)).timeout
		print("[rmprobe] alive t=%.1fs frames=%d" % [_elapsed, _frames])
		for ctrl in _controllers:
			_describe(ctrl)
			_exercise(ctrl)
		for hand in _hands:
			_describe_hand(hand)
	await _shoot()
	print("[rmprobe] ===== done =====")
	get_tree().quit(0)


func _report_classes() -> void:
	for name: String in ["OpenXRRenderModelExtension", "OpenXRRenderModelManager",
			"OpenXRFbRenderModel", "OpenXRFbRenderModelExtension",
			"OpenXRFbHandTrackingMesh", "XRHandModifier3D",
			"OpenXRMetaSimultaneousHandsAndControllersExtension"]:
		print("[rmprobe] class %s exists=%s" % [name, ClassDB.class_exists(name)])
	var has_core := Engine.has_singleton("OpenXRRenderModelExtension")
	var ext: Object = Engine.get_singleton("OpenXRRenderModelExtension") if has_core else null
	print("[rmprobe] core singleton=%s is_active=%s" % [
		ext != null, ext != null and ext.call("is_active")])


func _describe_hand(hand: CapsenseHand) -> void:
	var tracker := hand.hand_tracker()
	var source := hand.hand_source()
	var valid := hand.joints_valid()
	var ready := hand.mesh_ready()
	var tip: Variant = hand.index_tip_position()
	var ctrl := hand.get_node_or_null(hand.controller_path) as XRController3D
	var separation := -1.0
	if tip is Vector3 and ctrl != null:
		separation = (tip as Vector3).distance_to(ctrl.global_position) * 1000.0
	print(("[rmprobe] %s: hand_tracker=%s source=%d mesh_ready=%s joints_valid=%s "
		+ "motion_range=%d visible=%s tip_controller_mm=%.1f") % [
		hand.name, tracker != null, source, ready, valid,
		hand.active_motion_range(), hand.visible, separation])


func _describe(ctrl: XRController3D) -> void:
	var art := ctrl.get_node_or_null("ModelArt") as ControllerArt
	if art == null:
		print("[rmprobe] %s: no ModelArt" % ctrl.tracker)
		return
	var tracker := XRServer.get_tracker(ctrl.tracker) as XRPositionalTracker
	var profile: String = tracker.profile if tracker != null else "<no tracker>"
	print("[rmprobe] %s: source=%d profile=%s mats=%d unfadeable=%d" % [
		ctrl.tracker, art.source, profile, art.fade_materials.size(), art.opaque_only.size()])

	var anchor := art.get_node_or_null("GripAnchor") as Node3D
	if anchor != null:
		print("[rmprobe] %s: grip anchor origin=%s basis=%s" % [
			ctrl.tracker, anchor.transform.origin,
			anchor.transform.basis.get_euler() * (180.0 / PI)])

	# The shape of what arrived: an articulated model brings a Skeleton3D or an
	# AnimationPlayer, a static one is meshes only.
	var counts := {"MeshInstance3D": 0, "Skeleton3D": 0, "AnimationPlayer": 0, "Node3D": 0}
	var aabb := AABB()
	var first := true
	for node in _walk(art):
		var cls := node.get_class()
		counts[cls] = int(counts.get(cls, 0)) + 1
		var mesh := node as MeshInstance3D
		if mesh != null and mesh.mesh != null:
			var box: AABB = mesh.global_transform * mesh.mesh.get_aabb()
			aabb = box if first else aabb.merge(box)
			first = false
	print("[rmprobe] %s: nodes=%s" % [ctrl.tracker, counts])
	if not first:
		print("[rmprobe] %s: world aabb pos=%s size=%s" % [ctrl.tracker, aabb.position, aabb.size])
	print("[rmprobe] %s: tree=%s" % [ctrl.tracker, _tree_names(art)])
	_describe_rig(ctrl, art)


## What the runtime model can be made to do. The bundled art moved bones named
## left_b_trigger_front and friends; if these match, the same input handlers can
## drive a runtime model.
func _describe_rig(ctrl: XRController3D, art: Node) -> void:
	for node in _walk(art):
		var skel := node as Skeleton3D
		if skel != null:
			var bones: PackedStringArray = []
			for i in skel.get_bone_count():
				bones.append(skel.get_bone_name(i))
			print("[rmprobe] %s: bones=%s" % [ctrl.tracker, ", ".join(bones)])
			# Bone-local units decide how far a button press should travel; the
			# bundled art was authored in centimetres and a metre-scale rig would
			# push a button clean through the shell.
			print("[rmprobe] %s: skel scale=%s motion_scale=%.4f" % [
				ctrl.tracker, skel.global_transform.basis.get_scale(), skel.motion_scale])
			for i in skel.get_bone_count():
				print("[rmprobe] %s:   bone %s rest=%s euler=%s" % [
					ctrl.tracker, skel.get_bone_name(i), skel.get_bone_rest(i).origin,
					skel.get_bone_rest(i).basis.get_euler() * (180.0 / PI)])
		var anim := node as AnimationPlayer
		if anim != null:
			print("[rmprobe] %s: animations=%s playing=%s autoplay=%s current=%s" % [
				ctrl.tracker, anim.get_animation_list(), anim.is_playing(),
				anim.autoplay, anim.current_animation])
			_dump_animation(ctrl, anim)
		var n3 := node as Node3D
		if n3 != null and node.name in ["root", "grip", "model"]:
			print("[rmprobe] %s: %s local origin=%s euler=%s" % [ctrl.tracker, node.name,
				n3.transform.origin, n3.transform.basis.get_euler() * (180.0 / PI)])


## What the rig says about itself, in one line per track rather than 151.
func _dump_animation(ctrl: XRController3D, anim: AnimationPlayer) -> void:
	for clip_name: String in anim.get_animation_list():
		var clip: Animation = anim.get_animation(clip_name)
		print("[rmprobe] %s: clip '%s' len=%.3f tracks=%d" % [
			ctrl.tracker, clip_name, clip.length, clip.get_track_count()])
		for t in clip.get_track_count():
			var count := clip.track_get_key_count(t)
			if count == 0:
				continue
			var rest: Variant = clip.track_get_key_value(t, 0)
			var far: Variant = rest
			var far_at := 0.0
			var worst := 0.0
			var moving := 0
			for k in count:
				var v: Variant = clip.track_get_key_value(t, k)
				var dist: float = (rest as Quaternion).angle_to(v) if rest is Quaternion 					else (rest as Vector3).distance_to(v)
				if dist > 0.0001:
					moving += 1
				if dist > worst:
					worst = dist
					far = v
					far_at = clip.track_get_key_time(t, k)
			var travel: String = "%.2f deg" % (worst * 180.0 / PI) if rest is Quaternion 				else "%.2f mm" % (worst * 1000.0)
			print("[rmprobe] %s:   %s kind=%d travel=%s at t=%.2f (%d/%d keys move)" % [
				ctrl.tracker, clip.track_get_path(t).get_concatenated_subnames(),
				clip.track_get_type(t), travel, far_at, moving, count])


## Drive every input and watch the rig answer. A bone that does not move, or one
## that moves when a different input was actuated, is the bug the headset would
## otherwise have to find.
func _exercise(ctrl: XRController3D) -> void:
	var art := ctrl.get_node_or_null("ModelArt") as ControllerArt
	var skel: Skeleton3D = art.skeleton() if art != null else null
	if skel == null:
		print("[rmprobe] %s: no skeleton to exercise" % ctrl.tracker)
		return
	var stick: Dictionary = ctrl.get("_stick")
	print("[rmprobe] %s: stick measured=%s lean=%.1fdeg" % [ctrl.tracker, not stick.is_empty(),
		(stick.get("lean", 0.0) as float) * 180.0 / PI])
	_report_swing(ctrl, art, stick)

	var rest := _pose_of(skel)
	for probe: Array in [["trigger", 1.0], ["grip", 1.0]]:
		ctrl.call("_on_float_changed", probe[0], probe[1])
		_report_move(ctrl, skel, rest, str(probe[0]))
		ctrl.call("_on_float_changed", probe[0], 0.0)
	for button: String in ["ax_button", "by_button", "menu_button"]:
		ctrl.call("_on_button_pressed", button)
		_report_move(ctrl, skel, rest, button)
		ctrl.call("_on_button_released", button)
	# Where the tip sits with the stick centred, which every push is measured from.
	ctrl.call("_on_vec2_changed", "primary", Vector2.ZERO)
	_rest_tip = skel.get_bone_global_pose(skel.find_bone("b_thumbstick"))
	for dir: Vector2 in [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]:
		ctrl.call("_on_vec2_changed", "primary", dir)
		_report_move(ctrl, skel, rest, "stick %s" % dir)
		_report_lean(ctrl, skel, dir)
	ctrl.call("_on_vec2_changed", "primary", Vector2.ZERO)


## Where the stick's tip actually went, in the hand's own frame. The tip has to
## be a point ON the shaft: turning about an axis moves every other point in its
## own direction, so picking "whichever axis moved furthest" reads a different
## direction from one push to the next and none of them comparable.
func _report_lean(ctrl: XRController3D, skel: Skeleton3D, pushed: Vector2) -> void:
	var bone := skel.find_bone("b_thumbstick")
	var stick: Dictionary = ctrl.get("_stick")
	if bone < 0 or stick.is_empty():
		return
	var tip: Vector3 = (stick["shaft"] as Vector3) * 0.02
	var to_hand := ctrl.global_transform.affine_inverse() * skel.global_transform
	var moved: Vector3 = (to_hand * skel.get_bone_global_pose(bone) * tip) \
		- (to_hand * _rest_tip * tip)
	var went := Vector2(moved.x, -moved.z)
	print("[rmprobe] %s: pushed %s -> tip went %s (%.2f mm, agreement %.2f)" % [
		ctrl.tracker, pushed, went.normalized(), moved.length() * 1000.0,
		went.normalized().dot(pushed.normalized())])


## What the rig's sweep is made of: how much of each key turns the stick over its
## face (swing, which is what leans it) and how much spins it about its own shaft
## (twist, which moves the tip nowhere).
func _report_swing(ctrl: XRController3D, art: ControllerArt, stick: Dictionary) -> void:
	if stick.is_empty():
		return
	var anim := art.animation_player()
	if anim == null:
		return
	var clip: Animation = anim.get_animation(anim.get_animation_list()[0])
	var track := -1
	for t in clip.get_track_count():
		if String(clip.track_get_path(t).get_concatenated_subnames()) == "b_thumbstick":
			track = t
	if track < 0:
		return
	var rest: Quaternion = stick["rest"]
	var shaft: Vector3 = stick["shaft"]
	var rows: PackedStringArray = []
	for k in clip.track_get_key_count(track):
		var delta := rest.inverse() * (clip.track_get_key_value(track, k) as Quaternion)
		var total: float = rad_to_deg(2.0 * acos(clampf(absf(delta.w), -1.0, 1.0)))
		if total < 0.5:
			continue
		var along := Vector3(delta.x, delta.y, delta.z).dot(shaft)
		var twist := Quaternion(shaft.x * along, shaft.y * along, shaft.z * along, delta.w).normalized()
		var swing := delta * twist.inverse()
		rows.append("%.1f/%.1f" % [total,
			rad_to_deg(2.0 * acos(clampf(absf(swing.w), -1.0, 1.0)))])
	print("[rmprobe] %s: sweep total/swing deg: %s" % [ctrl.tracker, ", ".join(rows)])


func _pose_of(skel: Skeleton3D) -> Array:
	var out: Array = []
	for i in skel.get_bone_count():
		out.append(skel.get_bone_pose(i))
	return out


## Which bones moved, and how far, measured at the mesh rather than in the pose:
## a bone pose means nothing until it is composed down the chain.
func _report_move(ctrl: XRController3D, skel: Skeleton3D, rest: Array, what: String) -> void:
	var moved: PackedStringArray = []
	for i in skel.get_bone_count():
		var before: Transform3D = rest[i]
		var after := skel.get_bone_pose(i)
		var shift: float = before.origin.distance_to(after.origin) * 1000.0
		var turn: float = before.basis.get_rotation_quaternion().angle_to(
			after.basis.get_rotation_quaternion()) * 180.0 / PI
		if shift > 0.005 or turn > 0.05:
			moved.append("%s %.2fmm/%.1fdeg" % [skel.get_bone_name(i), shift, turn])
	print("[rmprobe] %s: %s -> %s" % [ctrl.tracker, what,
		", ".join(moved) if moved.size() > 0 else "NOTHING MOVED"])


func _walk(node: Node, out: Array[Node] = []) -> Array[Node]:
	for child in node.get_children():
		out.append(child)
		_walk(child, out)
	return out


func _tree_names(art: Node) -> String:
	var parts: PackedStringArray = []
	for node in _walk(art):
		parts.append("%s(%s)" % [node.name, node.get_class()])
	return ", ".join(parts)


## A render of whatever the runtime gave us, taken through a SubViewport sharing
## the live world — the headset's own eye buffers cannot be read back.
func _shoot() -> void:
	var art: Node3D = _controllers[0].get_node_or_null("ModelArt")
	if art == null:
		return
	var sv := SubViewport.new()
	sv.size = Vector2i(720, 540)
	sv.transparent_bg = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.world_3d = get_viewport().world_3d
	add_child(sv)
	var cam := Camera3D.new()
	sv.add_child(cam)
	cam.global_transform = Transform3D(Basis(), art.global_position + Vector3(0.0, 0.12, 0.28))
	cam.look_at(art.global_position, Vector3.UP)
	cam.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	sv.add_child(light)
	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	var err := sv.get_texture().get_image().save_png(SHOT_PATH)
	print("[rmprobe] screenshot %s err=%d" % [SHOT_PATH, err])

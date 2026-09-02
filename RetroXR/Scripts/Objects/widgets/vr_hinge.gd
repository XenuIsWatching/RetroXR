## VRHinge — a physical, trigger-latched hinge: a grabbable lid that rotates a
## target node about the target's local X axis, clamped between two angles (a
## clamshell lid or a console flap).
##
## Interaction (VR + desktop), unified:
##   • HOVER — a controller tip inside the configured reach region, or the desktop
##     reticle over the grab box, shows a floating OPEN-HAND icon ("grab here").
##   • HELD  — pull the TRIGGER (VR) / press-drag the reticle (desktop) to LATCH;
##     the icon becomes a FIST and the lid rotates toward the hand/pointer. Once
##     latched the hand need NOT stay in the grab box — the latch holds until the
##     trigger is released (VR) / the click is released (desktop).
##
## The TRIGGER, not the grip, and that is what keeps lids out of everything
## else's way. Grip is how XRToolsFunctionPickup grabs a pickable, and a handheld
## or console IS one — so a grip-latched lid meant one squeeze near the lid both
## swung it and lifted the whole device off the table. On the trigger the two
## never compete: grip picks the device up, trigger works its lid.
##
## `grip_engages` opts a hinge back into the grip for hardware you never lift (the
## NES's cartridge flap). It does not reintroduce the clash: a hand inside the grab
## BOX has its pickup muted for as long as it stays there, so the squeeze works the
## lid INSTEAD of taking the console, not as well as.
##
## Engagement also requires PokeTip.is_poking(), i.e. a hand NOT already holding
## something — the same gate VRButton and VRSlider use. Without it, pulling the
## trigger to fire a held object's action would swing any lid the hand was near.
##
## Attach to an Area3D with a child CollisionShape3D covering the grab region (the
## desktop reticle ray hits this; VR engages on tip proximity to the Area origin).
## The angle reported is the target's rotation about local X, in degrees.
class_name VRHinge
extends Area3D

signal rotation_changed(degrees: float)

const POINTABLE_LAYER := 1 << 20
## Analog trigger action, read as a float — same contract as VRButton/VRSlider.
const TRIGGER_ACTION := "trigger"
const TRIGGER_ON := 0.6   # trigger float that latches the hinge
const TRIGGER_OFF := 0.4  # trigger float that releases it (hysteresis)
## Analog grip, the same action XRToolsFunctionPickup takes hold with. Only read
## when grip_engages is on.
const GRIP_ACTION := "grip"
const GRIP_ON := 0.6
const GRIP_OFF := 0.4
## Box-face bits for direct fingertip pushing. These are in the authored
## CollisionShape3D's LOCAL frame, so a moving lid carries its faces with it.
const FACE_X_NEG := 1 << 0
const FACE_X_POS := 1 << 1
const FACE_Y_NEG := 1 << 2
const FACE_Y_POS := 1 << 3
const FACE_Z_NEG := 1 << 4
const FACE_Z_POS := 1 << 5
const POKE_TORQUE := 0
const POKE_OPEN := 1
const POKE_CLOSE := -1
const HAPTIC_POKE_KEY := &"vr_hinge_poke"
## Faces within this distance are effectively the same seam. Prefer the larger
## physical face there, so a broad front press does not become a thin-edge press.
const POKE_FACE_TIE_MARGIN := 0.002
const POKE_APPROACH_MIN := 0.0001
const POKE_APPROACH_DOT_EPS := 0.05
## Slack around the grab box for the grip test, in metres. The grip is deliberately
## judged on the BOX and not on engage_radius: the sphere is sized to make the
## trigger easy to hit and on the NES it swallows most of the console's front, which
## is far too much of the machine to stop being able to pick up.
const GRIP_BOX_MARGIN := 0.015
const ICON_HOVER := 0xF256   # Nerd Font: open palm — "grab here"
const ICON_HELD := 0xF255    # Nerd Font: closed fist — "holding"
const SYMBOL_FONT_PATH := "res://fonts/SymbolsNerdFont-Regular.ttf"

## Node whose local-X rotation this hinge drives (e.g. a clamshell lid pivot).
@export var target: Node3D
## Rotation limits about the target's local X, in degrees.
@export var min_deg: float = 0.0
@export var max_deg: float = 180.0
## Controller tip distance (m) that engages the handle.
@export var engage_radius: float = 0.04
## Use the child BoxShape3D as the VR trigger/hover region instead of the legacy
## sphere around this node. Runtime-built controls can then expose only the face
## a hand can physically reach without activating through the surrounding shell.
@export var box_engages: bool = false
## Faces from which a bare fingertip may push the hinge toward OPEN/CLOSED.
## Zero preserves the old trigger/grip-only behaviour.
@export_flags("-X", "+X", "-Y", "+Y", "-Z", "+Z") var poke_open_faces: int = 0
@export_flags("-X", "+X", "-Y", "+Y", "-Z", "+Z") var poke_close_faces: int = 0
## Bidirectional faces follow the torque implied by fingertip travel instead of
## forcing the hinge toward one end. Useful for a broad front face that can be
## swept either upward or downward.
@export_flags("-X", "+X", "-Y", "+Y", "-Z", "+Z") var poke_torque_faces: int = 0
## Distance either side of a configured face that starts/keeps a fingertip push.
@export var poke_face_margin: float = 0.012
@export var poke_release_margin: float = 0.025
## Carry a fingertip poke's angular motion into the hinge when contact breaks.
## Disabled by default; lightweight doors such as the NES lid opt in.
@export var poke_release_momentum: bool = false
@export var poke_momentum_max_deg_per_sec: float = 240.0
@export var poke_momentum_min_deg_per_sec: float = 12.0
@export var poke_momentum_damping_deg_per_sec2: float = 600.0
@export var poke_momentum_response: float = 18.0
## Non-empty enables concise state-transition logging for this hinge.
@export var state_log_name: String = ""
## Also take hold on the GRIP, for a lid on hardware the player never picks up.
##
## Reaching into a console and squeezing is what a player actually does, and on a
## table-top console that squeeze lifted the whole machine. Left OFF for the
## clamshell handhelds — a closed DS is picked up BY its lid, and that has to keep
## working — so this is opt-in, one line in the model that wants it.
@export var grip_engages: bool = false
## Desktop: degrees the mouse wheel rolls the hinge per notch while held.
@export var wheel_step_deg: float = 10.0
## Icon glyph height, roughly, in metres.
@export var icon_size: float = 0.028

var _trigger_ctrl: XRController3D = null   # latched controller (trigger/grip held)
# Which analog action the latched controller took hold with, so the release test
# watches the one that is actually down.
var _grab_action: String = TRIGGER_ACTION
# Drag bookkeeping: how far the lid sat from the angle the hand implied when it
# took hold, and the last raw hand angle (the unwrap reference).
var _grab_offset_deg: float = 0.0
var _grab_raw_prev: float = 0.0
# Controller instance ids whose trigger has dropped since they last latched.
var _rearmed: Dictionary = {}
# The same, for the grip.
var _rearmed_grip: Dictionary = {}
# FunctionPickups this hinge has muted, so it can hand each one back.
var _muted_pickups: Array[Node] = []
# The grab box, resolved lazily: a runtime-built rig (NES) adds its
# CollisionShape3D after the hinge has already entered the tree.
var _grab_shape: CollisionShape3D = null
var _pointer_held := false               # desktop pointer latched
var _held_prev := false                  # held state at the END of last _process
var _pointer_hover := false              # desktop reticle over the grab box
var _controllers: Array[XRController3D] = []
var _icon: Label3D = null
var _poke_ctrl: XRController3D = null
var _poke_shape: CollisionShape3D = null
var _poke_face: int = 0
var _poke_mode: int = 0
var _skip_next_release := false
var _poke_shapes_cache: Array[CollisionShape3D] = []
var _poke_rearm_required: Dictionary = {}
var _poke_prev_tips: Dictionary = {}
var _poke_release_velocity_deg := 0.0
var _release_angular_velocity_deg := 0.0


func _ready() -> void:
	collision_layer |= POINTABLE_LAYER
	_build_icon()
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node as XRController3D)


## Set the target rotation without emitting (restore/populate use).
func set_rotation_deg_no_signal(deg: float) -> void:
	_release_angular_velocity_deg = 0.0
	_apply(deg, false)


## Apply a network-authored angle through the normal signal path. Model-specific
## listeners (the NES flap is the important one) still have to move their visible
## geometry; NetObjectSync suppresses the resulting echo while applying it.
func set_rotation_deg_remote(deg: float) -> void:
	_release_angular_velocity_deg = 0.0
	_apply(deg, true)


func get_rotation_deg() -> float:
	return rad_to_deg(target.rotation.x) if target != null else min_deg


func _process(delta: float) -> void:
	# NB: the previous held state is remembered ACROSS frames (_held_prev, set at the
	# bottom). Sampling it here instead missed every desktop release — pointer_event
	# clears _pointer_held between frames, so by the time _process ran the "was held"
	# read was already false and _on_released() never fired (a lid wheeled shut then
	# released sprang straight back open instead of latching).
	var was_held := _held_prev
	# A hand nowhere near the hinge is asked nothing: no trigger, grip or poke
	# polling until a tip comes within reach. A latched or poking hand keeps
	# driving the hinge wherever it roams. The lid's own motion (release,
	# idle, momentum) runs either way, further down.
	var near := _trigger_ctrl != null or _poke_ctrl != null \
		or PokeTip.any_tip_within(_controllers, global_position, PokeTip.WIDGET_NEAR)
	if not near:
		if not _muted_pickups.is_empty():
			_sync_pickup_mutes()
		_poke_prev_tips.clear()
	else:
		# A trigger already down cannot grab lid after lid as the hand sweeps
		# across a console — it has to fall below TRIGGER_OFF first. Same re-arm
		# guard VRSlider uses.
		for ctrl in _controllers:
			if ctrl == null:
				continue
			if ctrl.get_float(TRIGGER_ACTION) < TRIGGER_OFF:
				_rearmed[ctrl.get_instance_id()] = true
			if ctrl.get_float(GRIP_ACTION) < GRIP_OFF:
				_rearmed_grip[ctrl.get_instance_id()] = true
		_sync_pickup_mutes()
		_process_poke(delta)
		_remember_poke_tips()
	# VR: button-latched engagement. A latched controller drives the hinge until
	# it lets the button go — however far the hand roams from the grab box.
	if _trigger_ctrl != null:
		var off := TRIGGER_OFF if _grab_action == TRIGGER_ACTION else GRIP_OFF
		if not is_instance_valid(_trigger_ctrl) or not _trigger_ctrl.get_is_active() \
				or _trigger_ctrl.get_float(_grab_action) < off:
			_trigger_ctrl = null
		else:
			_track_world_point(PokeTip.tip_of(_trigger_ctrl))
	elif near and not _pointer_held and _poke_ctrl == null and _can_engage():
		# Not latched (and desktop isn't dragging): latch a hovering hand that
		# pulls the trigger. A hand holding something is skipped, so firing a held
		# object's action never swings a lid as a side effect.
		for ctrl in _controllers:
			if ctrl == null or not ctrl.get_is_active() or not PokeTip.is_poking(ctrl):
				continue
			var id := ctrl.get_instance_id()
			var tip: Vector3 = PokeTip.tip_of(ctrl)
			if _rearmed.get(id, false) \
					and _tip_in_activation_region(tip) \
					and ctrl.get_float(TRIGGER_ACTION) > TRIGGER_ON:
				_rearmed[id] = false
				_latch(ctrl, TRIGGER_ACTION, tip)
				break
			# The grip is judged on the box, not the sphere — see GRIP_BOX_MARGIN.
			if grip_engages and _rearmed_grip.get(id, false) and _tip_in_grab_box(tip) \
					and ctrl.get_float(GRIP_ACTION) > GRIP_ON:
				_rearmed_grip[id] = false
				_latch(ctrl, GRIP_ACTION, tip)
				break
	var held := _trigger_ctrl != null or _pointer_held or _poke_ctrl != null
	if was_held and not held:
		if _skip_next_release:
			_skip_next_release = false
		else:
			_on_released()
	elif not held:
		_on_idle(delta)
	if not held:
		_step_release_momentum(delta)
	_held_prev = held
	_update_icon()


## Desktop reticle / VR laser support (same contract as VRButton/VRSlider). Press
## latches; the latch holds through MOVED even if the ray leaves the box, and only
## RELEASED lets go — EXITED just clears the hover highlight, never the drag.
##
## On DESKTOP a press only latches (fist icon) — the mouse WHEEL then rolls the
## angle while held (see _unhandled_input), which is finer and steadier than
## dragging the ray. In VR the laser pointer keeps its press-drag.
func pointer_event(event: XRToolsPointerEvent) -> void:
	var vr := get_viewport().use_xr
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_pointer_hover = true
		XRToolsPointerEvent.Type.PRESSED:
			if _can_engage():
				_release_angular_velocity_deg = 0.0
				_pointer_held = true
				if vr:
					_begin_track(event.position)
		XRToolsPointerEvent.Type.MOVED:
			if _pointer_held and vr:
				_track_world_point(event.position)
		XRToolsPointerEvent.Type.RELEASED:
			_pointer_held = false
		XRToolsPointerEvent.Type.EXITED:
			_pointer_hover = false
			# NB: keep _pointer_held — a drag is allowed to leave the grab box.
	_update_icon()


## Desktop: while the lid is held (reticle pressed on the grab box), the mouse
## wheel rolls the hinge open/closed. Wheel up opens, wheel down closes. Gated on
## _pointer_held, so other wheel consumers (held-object push/pull) only see the
## event when no hinge is grabbed. rotation.x grows toward SHUT on both the
## clamshells (0 open → 180 shut) and the NES flap driver (0 shut → -105 open),
## so "open" is -step there; the disc lids grow toward OPEN and flip the sign via
## _open_toward_max(). Wheel UP always opens, wheel DOWN always closes.
func _unhandled_input(event: InputEvent) -> void:
	if not _pointer_held or target == null:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return
	var open_step := wheel_step_deg if _open_toward_max() else -wheel_step_deg
	var step := 0.0
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		step = open_step
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		step = -open_step
	else:
		return
	_apply(rad_to_deg(target.rotation.x) + step, true)
	get_viewport().set_input_as_handled()


func _latch(ctrl: XRController3D, action: String, tip: Vector3) -> void:
	_release_angular_velocity_deg = 0.0
	_trigger_ctrl = ctrl
	_grab_action = action
	_begin_track(tip)


# --- grip engagement -----------------------------------------------------------

## The grab box, whichever child carries it. Resolved on demand because the NES
## builds its rig in code and adds the shape after the hinge is already in the tree.
func _grab_box() -> CollisionShape3D:
	if _grab_shape != null and is_instance_valid(_grab_shape):
		return _grab_shape
	for child in get_children():
		var cs := child as CollisionShape3D
		if cs != null and cs.shape is BoxShape3D:
			_grab_shape = cs
			return cs
	return null


func _tip_in_grab_box(tip: Vector3, margin: float = GRIP_BOX_MARGIN) -> bool:
	var cs := _grab_box()
	if cs == null:
		return false
	var half: Vector3 = (cs.shape as BoxShape3D).size * 0.5 \
		+ Vector3.ONE * margin
	var p: Vector3 = cs.global_transform.affine_inverse() * tip
	return absf(p.x) <= half.x and absf(p.y) <= half.y and absf(p.z) <= half.z


## VR trigger/hover reach. Box mode is exact: any deliberate reach padding belongs
## in the authored box, where each face can grow independently.
func _tip_in_activation_region(tip: Vector3) -> bool:
	if box_engages:
		return _tip_in_grab_box(tip, 0.0)
	return global_position.distance_to(tip) <= engage_radius


# --- direct fingertip pushing -------------------------------------------------

func _process_poke(delta: float) -> void:
	if poke_open_faces == 0 and poke_close_faces == 0 and poke_torque_faces == 0:
		return
	_update_poke_rearm()
	if _poke_ctrl != null:
		var tip := PokeTip.tip_of(_poke_ctrl)
		var previous: Vector3 = _poke_prev_tips.get(_poke_ctrl.get_instance_id(), tip)
		if _qualified_poke(_poke_ctrl):
			_update_active_poke_face(tip, tip - previous)
		if not _qualified_poke(_poke_ctrl) \
				or not _tip_on_face(tip, _poke_shape, _poke_face, poke_release_margin):
			_end_poke()
		else:
			_claim_poke_face(_poke_ctrl, tip, _poke_shape, _poke_face,
				PokeTip.CONTACT_ENGAGED)
			_on_poke_motion(tip, _poke_mode)
			_sample_poke_release_velocity(tip, previous, delta)
		return
	if _trigger_ctrl != null or _pointer_held or not _can_engage():
		return
	for ctrl in _controllers:
		if not _qualified_poke(ctrl):
			continue
		if not _poke_can_begin(ctrl):
			continue
		var tip := PokeTip.tip_of(ctrl)
		var previous: Vector3 = _poke_prev_tips.get(ctrl.get_instance_id(), tip)
		var contact := _poke_contact_at(tip, poke_face_margin, -1, tip - previous)
		if contact.is_empty():
			continue
		var shape := contact["shape"] as CollisionShape3D
		var face: int = contact["face"]
		_claim_poke_face(ctrl, tip, shape, face, PokeTip.CONTACT_ENGAGED)
		_begin_poke(ctrl, shape, face, tip)
		break


func _qualified_poke(ctrl: XRController3D) -> bool:
	return is_instance_valid(ctrl) and ctrl.get_is_active() and PokeTip.is_poking(ctrl)


func _begin_poke(ctrl: XRController3D, shape: CollisionShape3D,
		face: int, tip: Vector3) -> void:
	_release_angular_velocity_deg = 0.0
	_poke_release_velocity_deg = 0.0
	_poke_ctrl = ctrl
	_poke_shape = shape
	_poke_face = face
	_poke_mode = _poke_mode_for_face(shape, face)
	_begin_track(tip)
	_on_poke_started(tip, _face_world_normal(face, shape), _poke_mode)
	_state_log("poke %s -> %s at %.2f deg" % [
		_face_name(face), _poke_mode_name(_poke_mode),
		rad_to_deg(target.rotation.x) if target != null else 0.0])
	Haptics.click(ctrl, true, HAPTIC_POKE_KEY)


## The initial face is only a seam-safe starting choice, not a gesture-long lock.
## Once the fingertip is clearly on another authored surface (or its motion resolves
## an ambiguous seam), transfer the poke and its open/close intent without jumping.
func _update_active_poke_face(tip: Vector3, approach: Vector3) -> void:
	var contact := _poke_contact_at(tip, poke_face_margin, -1, approach)
	if contact.is_empty():
		return
	var shape := contact["shape"] as CollisionShape3D
	var face: int = contact["face"]
	if shape == _poke_shape and face == _poke_face:
		return
	_poke_shape = shape
	_poke_face = face
	_poke_mode = _poke_mode_for_face(shape, face)
	_begin_track(tip)
	_on_poke_started(tip, _face_world_normal(face, shape), _poke_mode)
	_state_log("poke crossed to %s -> %s at %.2f deg" % [
		_face_name(face), _poke_mode_name(_poke_mode),
		rad_to_deg(target.rotation.x) if target != null else 0.0])


func _poke_mode_for_face(shape: CollisionShape3D, face: int) -> int:
	if (_shape_faces(shape, &"poke_torque_faces", poke_torque_faces) & face) != 0:
		return POKE_TORQUE
	return POKE_OPEN \
		if (_shape_faces(shape, &"poke_open_faces", poke_open_faces) & face) != 0 \
		else POKE_CLOSE


func _end_poke(skip_release: bool = false) -> void:
	if _poke_ctrl == null:
		return
	var old := _poke_ctrl
	if poke_release_momentum and not skip_release \
			and absf(_poke_release_velocity_deg) >= poke_momentum_min_deg_per_sec:
		_release_angular_velocity_deg = clampf(_poke_release_velocity_deg,
			-poke_momentum_max_deg_per_sec, poke_momentum_max_deg_per_sec)
		_state_log("poke released with %.1f deg/s momentum" \
			% _release_angular_velocity_deg)
	else:
		_release_angular_velocity_deg = 0.0
	_poke_release_velocity_deg = 0.0
	if skip_release and is_instance_valid(old):
		_require_poke_exit(old)
	_poke_ctrl = null
	_poke_shape = null
	_poke_face = 0
	_poke_mode = 0
	_skip_next_release = _skip_next_release or skip_release
	_on_poke_ended()
	_state_log("poke released%s at %.2f deg" % [
		" (state transition owns release)" if skip_release else "",
		rad_to_deg(target.rotation.x) if target != null else 0.0])
	Haptics.click(old, false, HAPTIC_POKE_KEY)


## Convert world fingertip motion into angular velocity about the actual hinge
## axis. Radial motion contributes nothing; only motion carrying angular momentum
## around the pivot survives into the release.
func _sample_poke_release_velocity(tip: Vector3, previous: Vector3,
		delta: float) -> void:
	if not poke_release_momentum or target == null or delta <= 0.0:
		return
	var axis := target.global_transform.basis.x.normalized()
	var radial := tip - target.global_position
	radial -= axis * radial.dot(axis)
	var radius_sq := radial.length_squared()
	if radius_sq < 0.000001:
		return
	var velocity := (tip - previous) / delta
	var instant := rad_to_deg(axis.dot(radial.cross(velocity)) / radius_sq)
	instant = clampf(instant, -poke_momentum_max_deg_per_sec,
		poke_momentum_max_deg_per_sec)
	var blend := 1.0 - exp(-poke_momentum_response * delta)
	_poke_release_velocity_deg = lerpf(_poke_release_velocity_deg, instant, blend)


func _step_release_momentum(delta: float) -> void:
	if not poke_release_momentum or target == null \
			or is_zero_approx(_release_angular_velocity_deg):
		return
	var cur := rad_to_deg(target.rotation.x)
	var wanted := cur + _release_angular_velocity_deg * delta
	var next := clampf(wanted, min_deg, max_deg)
	_apply(next, true)
	if not is_equal_approx(next, wanted):
		_release_angular_velocity_deg = 0.0
		return
	_release_angular_velocity_deg = move_toward(_release_angular_velocity_deg, 0.0,
		poke_momentum_damping_deg_per_sec2 * delta)


func _face_at_tip(tip: Vector3, margin: float, allowed_faces: int = -1,
		approach: Vector3 = Vector3.ZERO) -> int:
	var contact := _poke_contact_at(tip, margin, allowed_faces, approach)
	return 0 if contact.is_empty() else int(contact["face"])


func _poke_contact_at(tip: Vector3, margin: float,
		allowed_faces: int = -1, approach: Vector3 = Vector3.ZERO) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	var best_area := -INF
	var best_external := false
	var best_alignment := -INF
	var has_approach := approach.length() >= POKE_APPROACH_MIN
	for cs in _poke_shapes():
		var shape_allowed := allowed_faces if allowed_faces >= 0 else (
			_shape_faces(cs, &"poke_open_faces", poke_open_faces)
			| _shape_faces(cs, &"poke_close_faces", poke_close_faces)
			| _shape_faces(cs, &"poke_torque_faces", poke_torque_faces))
		var hit := _face_on_shape(tip, cs, margin, shape_allowed, approach)
		if hit.is_empty():
			continue
		var d: float = hit["distance"]
		var area: float = hit["area"]
		var external: bool = hit["external"]
		var alignment: float = hit["alignment"]
		if best.is_empty() or _poke_candidate_better(external, d, alignment, area,
				best_external, best_d, best_alignment, best_area, has_approach):
			best = hit
			best_d = d
			best_area = area
			best_external = external
			best_alignment = alignment
	return best


func _face_on_shape(tip: Vector3, cs: CollisionShape3D, margin: float,
		allowed_faces: int = -1, approach: Vector3 = Vector3.ZERO) -> Dictionary:
	var p: Vector3 = cs.global_transform.affine_inverse() * tip
	var half: Vector3 = (cs.shape as BoxShape3D).size * 0.5
	var allowed := (poke_open_faces | poke_close_faces | poke_torque_faces) \
		if allowed_faces < 0 else allowed_faces
	var best_face := 0
	var best_d := INF
	var best_area := -INF
	var best_external := false
	var best_alignment := -INF
	var has_approach := approach.length() >= POKE_APPROACH_MIN
	var approach_dir := approach.normalized() if has_approach else Vector3.ZERO
	for face in [FACE_X_NEG, FACE_X_POS, FACE_Y_NEG, FACE_Y_POS,
			FACE_Z_NEG, FACE_Z_POS]:
		if (allowed & face) == 0:
			continue
		var axis := _face_axis(face)
		var sign := _face_sign(face)
		var d: float = absf(p[axis] - sign * half[axis])
		if d > margin:
			continue
		var inside := true
		for other in 3:
			if other != axis and absf(p[other]) > half[other] + margin:
				inside = false
				break
		if inside:
			var area := _face_area(half, axis)
			var external := sign * p[axis] >= half[axis] - 0.0005
			var alignment := approach_dir.dot(-_face_world_normal(face, cs)) \
				if has_approach else 0.0
			if best_face == 0 or _poke_candidate_better(external, d, alignment, area,
					best_external, best_d, best_alignment, best_area, has_approach):
				best_face = face
				best_d = d
				best_area = area
				best_external = external
				best_alignment = alignment
	return {} if best_face == 0 else {
		"shape": cs,
		"face": best_face,
		"distance": best_d,
		"area": best_area,
		"external": best_external,
		"alignment": best_alignment,
	}


func _poke_candidate_better(external: bool, distance: float, alignment: float,
		area: float, best_external: bool, best_distance: float,
		best_alignment: float, best_area: float, has_approach: bool) -> bool:
	if distance < best_distance - POKE_FACE_TIE_MARGIN:
		return true
	if distance > best_distance + POKE_FACE_TIE_MARGIN:
		return false
	# At a seam, infer intent from the inward normal nearest the fingertip's travel.
	if has_approach:
		if alignment > best_alignment + POKE_APPROACH_DOT_EPS:
			return true
		if alignment < best_alignment - POKE_APPROACH_DOT_EPS:
			return false
	if external != best_external:
		return external
	return area > best_area


func _face_area(half: Vector3, axis: int) -> float:
	if axis == 0:
		return half.y * half.z * 4.0
	if axis == 1:
		return half.x * half.z * 4.0
	return half.x * half.y * 4.0


## Authored poke surfaces are marked on their CollisionShape3D. A hinge without
## any keeps the legacy behaviour and pokes against its trigger/grip box.
func _poke_shapes() -> Array[CollisionShape3D]:
	var valid: Array[CollisionShape3D] = []
	for cs in _poke_shapes_cache:
		if is_instance_valid(cs):
			valid.append(cs)
	if not valid.is_empty():
		_poke_shapes_cache = valid
		return _poke_shapes_cache
	for node in find_children("*", "CollisionShape3D", true, false):
		var cs := node as CollisionShape3D
		if cs != null and cs.shape is BoxShape3D and cs.get_meta(&"poke_surface", false):
			_poke_shapes_cache.append(cs)
	if _poke_shapes_cache.is_empty():
		var fallback := _grab_box()
		if fallback != null:
			_poke_shapes_cache.append(fallback)
	return _poke_shapes_cache


## A poke surface may narrow the hinge-wide face policy with authored metadata.
## This keeps thin edge faces intentional instead of incidental.
func _shape_faces(shape: CollisionShape3D, key: StringName, fallback: int) -> int:
	return int(shape.get_meta(key, fallback)) if shape != null else fallback


## A push-push state transition consumes the current poke. The same fingertip
## must physically leave every poke surface before it may begin the next cycle.
func _update_poke_rearm() -> void:
	for ctrl in _controllers:
		if ctrl == null:
			continue
		var id := ctrl.get_instance_id()
		if not _poke_rearm_required.get(id, false):
			continue
		if not _qualified_poke(ctrl) \
				or _poke_contact_at(PokeTip.tip_of(ctrl), poke_release_margin).is_empty():
			_poke_rearm_required.erase(id)


func _require_poke_exit(ctrl: XRController3D) -> void:
	if is_instance_valid(ctrl):
		_poke_rearm_required[ctrl.get_instance_id()] = true


func _poke_can_begin(ctrl: XRController3D) -> bool:
	return is_instance_valid(ctrl) \
		and not _poke_rearm_required.get(ctrl.get_instance_id(), false)


func _remember_poke_tips() -> void:
	for ctrl in _controllers:
		if is_instance_valid(ctrl):
			_poke_prev_tips[ctrl.get_instance_id()] = PokeTip.tip_of(ctrl)


func _tip_on_face(tip: Vector3, shape: CollisionShape3D,
		face: int, margin: float) -> bool:
	if face == 0 or shape == null:
		return false
	# Stay on the exact physical plane that began this push. Sliding round the seam
	# onto the other plane releases rather than silently changing interaction mode.
	var hit := _face_on_shape(tip, shape, margin, face)
	return not hit.is_empty() and int(hit["face"]) == face


func _face_axis(face: int) -> int:
	if face == FACE_X_NEG or face == FACE_X_POS:
		return 0
	return 1 if face == FACE_Y_NEG or face == FACE_Y_POS else 2


func _face_sign(face: int) -> float:
	return -1.0 if face == FACE_X_NEG or face == FACE_Y_NEG or face == FACE_Z_NEG else 1.0


func _face_name(face: int) -> String:
	match face:
		FACE_X_NEG: return "-X"
		FACE_X_POS: return "+X"
		FACE_Y_NEG: return "-Y"
		FACE_Y_POS: return "+Y"
		FACE_Z_NEG: return "-Z"
		FACE_Z_POS: return "+Z"
	return "?"


func _poke_mode_name(mode: int) -> String:
	if mode == POKE_OPEN:
		return "OPEN"
	if mode == POKE_CLOSE:
		return "CLOSE"
	return "TORQUE"


func _state_log(message: String) -> void:
	if not state_log_name.is_empty():
		print("[NES state] %s: %s" % [state_log_name, message])


func _face_world_normal(face: int, shape: CollisionShape3D = null) -> Vector3:
	var cs := shape if shape != null else (_poke_shape if _poke_shape != null else _grab_box())
	if cs == null:
		return Vector3.ZERO
	var local := Vector3.ZERO
	local[_face_axis(face)] = _face_sign(face)
	return (cs.global_transform.basis * local).normalized()


func _claim_poke_face(ctrl: XRController3D, tip: Vector3,
		shape: CollisionShape3D, face: int, priority: int) -> void:
	var cs := shape
	if cs == null:
		return
	var p: Vector3 = cs.global_transform.affine_inverse() * tip
	var half: Vector3 = (cs.shape as BoxShape3D).size * 0.5
	var axis := _face_axis(face)
	p[axis] = _face_sign(face) * half[axis]
	for other in 3:
		if other != axis:
			p[other] = clampf(p[other], -half[other], half[other])
	PokeTip.set_contact(ctrl, cs.global_transform * p, _face_world_normal(face), priority)


## Default poke motion is the trigger drag constrained to the direction named by
## the contacted face. Subclasses may replace it (push-push overtravel does).
func _on_poke_motion(world_pos: Vector3, mode: int) -> void:
	var wanted := _poke_wanted_deg(world_pos, true)
	if is_nan(wanted) or target == null:
		return
	if mode == POKE_TORQUE:
		_apply(wanted, true)
		return
	var cur := rad_to_deg(target.rotation.x)
	var increasing_opens := _open_toward_max()
	var toward_open := mode == POKE_OPEN
	var allowed := wanted >= cur if toward_open == increasing_opens else wanted <= cur
	if allowed:
		_apply(wanted, true)


## Angle implied by the active fingertip drag. Push-push subclasses request the
## unclamped value so a tray can travel slightly beyond its nominal closed limit.
func _poke_wanted_deg(world_pos: Vector3, clamp_to_limits: bool) -> float:
	var raw := _angle_at(world_pos, _grab_raw_prev)
	if is_nan(raw):
		return NAN
	_grab_raw_prev = raw
	var wanted := raw + _grab_offset_deg
	return clampf(wanted, min_deg, max_deg) if clamp_to_limits else wanted


func _on_poke_started(_tip: Vector3, _outward_normal: Vector3,
		_mode: int) -> void:
	pass


func _on_poke_ended() -> void:
	pass


## Mute the pickup of every free hand sitting in the grab box, and of the hand
## currently holding the lid — that one keeps its mute even after it roams out of
## the box, or letting go would hand a still-squeezed grip straight to the console.
##
## Only ever applied to a hand holding NOTHING (PokeTip.is_poking), so a mute can
## never strand something already in a player's grasp.
func _sync_pickup_mutes() -> void:
	var want: Array[Node] = []
	if grip_engages:
		for ctrl in _controllers:
			if ctrl == null or not is_instance_valid(ctrl) or not ctrl.get_is_active():
				continue
			if ctrl != _trigger_ctrl and not (PokeTip.is_poking(ctrl)
					and _tip_in_grab_box(PokeTip.tip_of(ctrl))):
				continue
			var pickup := ctrl.get_node_or_null("FunctionPickup")
			if pickup != null:
				want.append(pickup)
	for pickup in _muted_pickups:
		if is_instance_valid(pickup) and not want.has(pickup):
			pickup.set("enabled", true)
	for pickup in want:
		pickup.set("enabled", false)
	_muted_pickups = want


## Hand every muted pickup back — a lid that leaves with its console must not take
## the player's grip with it.
func _exit_tree() -> void:
	for pickup in _muted_pickups:
		if is_instance_valid(pickup):
			pickup.set("enabled", true)
	_muted_pickups.clear()


## Angle about the hinge axis implied by a world point, or NAN where it is
## undefined. The point is measured in the target's PARENT frame relative to the
## pivot origin; the panel points -Z at rotation 0 and folds toward +Z as the
## angle grows (theta = atan2(y, -z)).
##
## atan2 wraps at ±180°, so near a limit a tiny cross-axis jitter can flip the
## sign (e.g. +179° → -179°) and snap the hinge to the opposite end. `near_deg`
## unwraps the result onto the branch nearest a reference angle, keeping the
## drag continuous end-to-end.
func _angle_at(world_pos: Vector3, near_deg: float) -> float:
	if target == null:
		return NAN
	var parent := target.get_parent() as Node3D
	if parent == null:
		return NAN
	# Measure in the PIVOT'S OWN rest frame, not the parent's. A pivot built by
	# VRSpringLatchedHinge.mount carries Basis(Vector3.UP, PI) — a 180° yaw, so
	# that +rotation lifts the lid's front — which points its local X the opposite
	# way to the parent's. Reading the angle in the parent frame then gives it the
	# opposite SIGN to target.rotation.x, and the lid tracks the hand backwards:
	# you have to move away from the console to shut the door.
	#
	# Rest frame = the pivot's basis with the hinge rotation taken out. Node3D
	# Euler order is YXZ, so dropping the X term leaves Ry * Rz.
	var rest := Basis.from_euler(Vector3(0.0, target.rotation.y, target.rotation.z))
	var rel: Vector3 = rest.inverse() * (parent.to_local(world_pos) - target.position)
	if Vector2(rel.y, rel.z).length() < 0.001:
		return NAN   # hand at the pivot — angle undefined
	var deg := rad_to_deg(atan2(rel.y, -rel.z))
	while deg - near_deg > 180.0:
		deg -= 360.0
	while deg - near_deg < -180.0:
		deg += 360.0
	return deg


## Take hold WITHOUT moving the lid. The grab box sits on the hinge, so the angle
## a hand implies at the moment it grabs is whatever direction it happens to be
## off the pivot — near a limit, and nothing to do with where the lid is. Driving
## the lid straight to it teleported the lid on contact: a trigger tap near a disc
## door slammed it shut and _on_released then latched it there, so a click read as
## "close" and you could never drag one.
##
## Remember the difference instead, and carry it through the drag. The lid then
## stays put until the hand actually moves, and moves with it one-for-one.
func _begin_track(world_pos: Vector3) -> void:
	if target == null:
		return
	var cur := rad_to_deg(target.rotation.x)
	var raw := _angle_at(world_pos, cur)
	_grab_offset_deg = 0.0 if is_nan(raw) else cur - raw
	_grab_raw_prev = cur if is_nan(raw) else raw


func _track_world_point(world_pos: Vector3) -> void:
	# Unwrap against the PREVIOUS raw angle, not the lid's: once an offset is in
	# play the two are no longer near each other, and unwrapping against the lid
	# would fold a large offset into a 360° jump.
	var raw := _angle_at(world_pos, _grab_raw_prev)
	if is_nan(raw):
		return
	_grab_raw_prev = raw
	_apply(raw + _grab_offset_deg, true)


func _apply(deg: float, emit: bool) -> void:
	if target == null:
		return
	deg = clampf(deg, min_deg, max_deg)
	target.rotation.x = deg_to_rad(deg)
	if emit:
		rotation_changed.emit(deg)


# --- floating hint icon --------------------------------------------------------

## Build the open-hand / fist hint. It is parented to this Area3D (a child of the
## lid pivot), so it rides the lid as it swings. The Symbols Nerd Font is chained
## as a fallback so the PUA glyphs resolve (same recipe as tv_remote.gd).
##
## WHERE it sits is the scene's business, not this script's: an authored
## "HingeHint" child keeps the position it was given, dialled in the 3D editor.
## Nothing here moves it. A rig built at runtime (no scene node to author) makes
## its own and calls place_hint() — see VRSpringLatchedHinge.mount.
func _build_icon() -> void:
	var existing := get_node_or_null("HingeHint") as Label3D
	if existing != null:
		_icon = existing
	else:
		_icon = Label3D.new()
		_icon.name = "HingeHint"
		add_child(_icon)
	var fv := FontVariation.new()
	fv.base_font = ThemeDB.fallback_font
	var symbols: Font = load(SYMBOL_FONT_PATH)
	if symbols:
		fv.fallbacks = [symbols]
	_icon.font = fv
	_icon.font_size = 96
	_icon.pixel_size = icon_size / 96.0
	_icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_icon.no_depth_test = true
	_icon.render_priority = 2
	_icon.outline_size = 18
	_icon.outline_modulate = Color(0.0, 0.0, 0.0, 0.7)
	_icon.visible = false


## Show the fist while held, the open hand while hovering, nothing otherwise.
func _update_icon() -> void:
	if _icon == null:
		return
	var held := _trigger_ctrl != null or _pointer_held or _poke_ctrl != null
	if held:
		_icon.text = String.chr(ICON_HELD)
		_icon.modulate = Color(1.0, 0.82, 0.28)   # fist — amber "holding"
		_icon.visible = true
		return
	if _pointer_hover or _vr_hovering():
		_icon.text = String.chr(ICON_HOVER)
		_icon.modulate = Color(0.92, 0.96, 1.0)    # open hand — cool white
		_icon.visible = true
		return
	_icon.visible = false


## Position the hint, for rigs assembled in code rather than authored in a scene.
## `local_pos` is in this hinge's own frame, the same as the node position an
## authored HingeHint carries.
func place_hint(local_pos: Vector3) -> void:
	if _icon != null:
		_icon.position = local_pos


func _vr_hovering() -> bool:
	if not _can_engage():
		return false
	for ctrl in _controllers:
		if ctrl and ctrl.get_is_active() and _tip_in_activation_region(PokeTip.tip_of(ctrl)):
			return true
	return false


# --- override hooks (VRSpringLatchedHinge) -------------------------------------

## Whether the hand/pointer may currently grab the hinge. Base: always. The spring
## subclass returns false while latched shut so the hand can't start an open.
func _can_engage() -> bool:
	return true


## Called the frame a grab ends (grip released / pointer released). Base: no-op.
func _on_released() -> void:
	pass


## Called every frame the hinge is NOT held. Base: no-op (the lid stays put). The
## spring subclass uses this to ease the lid back toward fully open.
func _on_idle(_delta: float) -> void:
	pass


## Which end of the range is "open", so the desktop mouse wheel rolls the right
## way. Base: min_deg (the clamshells/NES flap grow toward shut). The disc lids
## open toward max_deg and override this.
func _open_toward_max() -> bool:
	return false

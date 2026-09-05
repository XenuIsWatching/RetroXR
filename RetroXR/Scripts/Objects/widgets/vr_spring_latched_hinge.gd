## VRSpringLatchedHinge — a spring-loaded, button-opened console CD/GD-ROM lid.
##
## Behaviour (on top of VRHinge's grab plumbing):
##   • Boots CLOSED and LATCHED. The console's OPEN button (model.play_open) calls
##     open() → the lid springs FULLY OPEN.
##   • While open, the hand (VR grip) / desktop pointer can grab the lid and pull it
##     DOWN toward closed. On release: near the closed limit → LATCH shut (and report
##     it, via rotation_changed, so the host closes the tray); anywhere else → the
##     lid SPRINGS back fully open.
##   • The hand can NOT start an open from closed — engagement is gated while latched
##     (_can_engage), so only the button opens it.
##
## closed = min_deg (0), open = max_deg (>0). The spring eases toward max_deg; the
## latch snaps to min_deg. Direction is set by the lid rig (see mount()), which
## rotates the lid UP about its real back-edge hinge — replacing the broken GLB
## Open animation that made these lids swing the wrong way.
class_name VRSpringLatchedHinge
extends VRHinge

## Degrees/sec the lid eases back toward fully open when released mid-swing.
@export var spring_speed_deg: float = 260.0
## Release within this many degrees of the closed limit (min_deg) → latch shut.
@export var close_latch_deg: float = 12.0
## Consoles boot with the tray shut, so the lid starts latched closed.
@export var start_closed: bool = true
## Push-push, as a cartridge tray latches: a hand may take hold of it while it is
## LATCHED, and doing so releases it. A lid leaves this off — only its OPEN button
## may unlatch one, which is what keeps a hand from prising a closed drive open.
@export var push_push: bool = false
## A latched push-push tray travels this far under the fingertip before its latch
## releases. The visible hinge overtravels slightly, then the spring takes it up.
@export var push_push_unlatch_depth: float = 0.006
@export var push_push_overtravel_deg: float = 2.0
## Speed of the small upward rebound after the latch catches below its rest angle.
@export var push_push_rebound_speed_deg: float = 40.0

const LATCH_CATCH_HAPTIC_MAGNITUDE := 0.5
const LATCH_REST_HAPTIC_MAGNITUDE := 0.2
const LATCH_HAPTIC_MS := 10
const LATCH_CATCH_HAPTIC_KEY := &"push_push_latch_catch"
const LATCH_REST_HAPTIC_KEY := &"push_push_latch_rest"

var _latched_closed := false
var _poke_overtravel := false
var _poke_latching := false
var _poke_consumed := false
var _poke_start_tip := Vector3.ZERO
var _poke_outward_normal := Vector3.ZERO
var _spring_logged_open := true
var _latch_rebound := false
var _latch_feedback_ctrl: XRController3D = null


func _ready() -> void:
	super._ready()
	_latched_closed = start_closed
	_apply(min_deg if _latched_closed else max_deg, false)
	_set_interactive(not _latched_closed)


## Button-driven open (model.play_open): unlatch so the spring pulls it fully open.
func open() -> void:
	var was_latched := _latched_closed
	_latched_closed = false
	_latch_rebound = false
	_latch_feedback_ctrl = null
	_set_interactive(true)
	_spring_logged_open = false
	if was_latched:
		_state_log("latch RELEASED -> SPRINGING_OPEN")


## Latch fully shut (model.play_close, or the hand pushed it home). Emits so the
## host can mark the tray closed.
func latch_closed(rebound_from_overtravel: bool = false,
		preserve_poke: bool = false) -> void:
	_latched_closed = true
	_trigger_ctrl = null
	if not preserve_poke:
		_end_poke(true)
	_pointer_held = false
	# A push-push tray keeps its grab box: a hand has to be able to reach a latched
	# one to let it up again.
	_set_interactive(push_push)
	_state_log("LATCHED_CLOSED")
	_latch_rebound = rebound_from_overtravel
	if rebound_from_overtravel:
		# Report the state change without erasing the visible below-home press. Idle
		# processing eases it back to `min_deg` over the next few frames.
		rotation_changed.emit(rad_to_deg(target.rotation.x) if target != null else min_deg)
	else:
		_latch_feedback_ctrl = null
		_apply(min_deg, true)
	_spring_logged_open = false


## A latched-shut lid genuinely can't be interacted with — only the OPEN
## button unlatches it (_can_engage() already blocks a grab from starting)
## — so hide the hover/held hint icon and disable the grab-box collision
## entirely rather than leaving a dead hitbox a hand can bump into.
func _set_interactive(active: bool) -> void:
	for c in get_children():
		if c is CollisionShape3D:
			(c as CollisionShape3D).disabled = not active
	if not active and _icon != null:
		_icon.visible = false


func _update_icon() -> void:
	# A normal spring lid is dead while latched, so it has no hint. A push-push
	# cradle remains interactive while latched and must keep running the base hover
	# test; returning here used to freeze the poke's fist glyph on forever.
	if _latched_closed and not push_push:
		if _icon != null:
			_icon.visible = false
		return
	super._update_icon()


func is_latched_closed() -> bool:
	return _latched_closed


## Restore/network application needs both the visible angle and the mechanism's
## latch state. An open-looking lid that still thinks it is latched cannot be
## grabbed and will not spring; an unlatched closed-looking one pops open again.
func set_state_remote(degrees: float, latched: bool) -> void:
	_latched_closed = latched
	_latch_rebound = false
	_latch_feedback_ctrl = null
	_set_interactive(push_push or not latched)
	_spring_logged_open = latched or is_equal_approx(degrees, max_deg)
	_apply(degrees, true)


# The hand can only grab an OPEN (unlatched) lid — button-only opening. A
# push-push tray is the exception: a hand may take hold of a latched one, which is
# how it is let up. Pure: this is polled every frame, so the unlatch belongs to the
# grab actually starting (see _process), not to being asked whether it could.
func _can_engage() -> bool:
	return push_push or not _latched_closed


func _process(delta: float) -> void:
	super._process(delta)
	if push_push and _latched_closed and (_trigger_ctrl != null or _pointer_held):
		open()


## A second top-face press on a latched push-push tray is not a drag open: the
## fingertip first drives it a few millimetres farther DOWN until the latch trips.
func _on_poke_started(tip: Vector3, outward_normal: Vector3,
		mode: int) -> void:
	_poke_consumed = false
	_poke_overtravel = push_push and _latched_closed and mode == POKE_CLOSE
	_poke_latching = push_push and not _latched_closed and mode == POKE_CLOSE
	_poke_start_tip = tip
	_poke_outward_normal = outward_normal
	if _poke_overtravel:
		_state_log("LATCHED_CLOSED -> PRESSING_RELEASE")
	elif _poke_latching:
		_spring_logged_open = false
		_state_log("SPRUNG_OPEN -> PRESSING_LATCH")


func _on_poke_motion(world_pos: Vector3, mode: int) -> void:
	if _poke_consumed:
		_follow_consumed_poke(world_pos)
		return
	if _poke_latching:
		if target == null:
			return
		var wanted := _poke_wanted_deg(world_pos, false)
		if is_nan(wanted):
			return
		var bottom := min_deg - push_push_overtravel_deg
		wanted = clampf(wanted, bottom, max_deg)
		target.rotation.x = deg_to_rad(wanted)
		rotation_changed.emit(wanted)
		if wanted <= bottom + 0.001:
			_poke_latching = false
			_poke_consumed = true
			_state_log("latch overtravel reached -> LATCHED_CLOSED")
			_latch_feedback_ctrl = _poke_ctrl if is_instance_valid(_poke_ctrl) else null
			if _latch_feedback_ctrl != null and _latch_feedback_ctrl.get_is_active():
				Haptics.pulse(_latch_feedback_ctrl, LATCH_CATCH_HAPTIC_MAGNITUDE,
					LATCH_HAPTIC_MS, LATCH_CATCH_HAPTIC_KEY)
			latch_closed(true, true)
			# Re-anchor at the catch point. From here the locked cradle follows the
			# fingertip back toward its rest angle instead of rebounding through it.
			_begin_track(world_pos)
		return
	if not _poke_overtravel:
		super._on_poke_motion(world_pos, mode)
		return
	if target == null:
		return
	var depth := maxf((_poke_start_tip - world_pos).dot(_poke_outward_normal), 0.0)
	var t := clampf(depth / maxf(push_push_unlatch_depth, 0.0001), 0.0, 1.0)
	target.rotation.x = deg_to_rad(min_deg - push_push_overtravel_deg * t)
	if t >= 1.0:
		_state_log("release overtravel %.1f mm reached" % (depth * 1000.0))
		_poke_overtravel = false
		_poke_consumed = true
		open()
		# Re-anchor at the release point. The spring-loaded cradle remains constrained
		# by the fingertip until that fingertip physically leaves the moving top face.
		_begin_track(world_pos)


## A latch transition consumes the gesture so it cannot immediately trigger the
## opposite state, but it does not consume the physical contact. Keep the cradle
## on the fingertip: stationary finger means stationary cradle; retreating finger
## lets it rise. Once contact ends, idle spring/rebound motion finishes the travel.
func _follow_consumed_poke(world_pos: Vector3) -> void:
	if target == null:
		return
	var wanted := _poke_wanted_deg(world_pos, false)
	if is_nan(wanted):
		return
	var bottom := min_deg - push_push_overtravel_deg
	wanted = clampf(wanted, bottom, min_deg if _latched_closed else max_deg)
	target.rotation.x = deg_to_rad(wanted)
	rotation_changed.emit(wanted)
	if _latched_closed and is_equal_approx(wanted, min_deg):
		_latch_rebound = false
		_finish_latch_feedback()


func _on_poke_ended() -> void:
	if _poke_consumed:
		# The state transition already decided the mechanism's outcome; physical
		# separation merely ends the gesture and must not invoke the release latch.
		_skip_next_release = true
	elif _poke_latching and not _latched_closed:
		# A poke that only reaches the normal home angle has not crossed the latch.
		# Skip the generic near-closed release rule and let the spring take it back.
		_skip_next_release = true
		_spring_logged_open = false
		_state_log("latch press released early -> SPRINGING_OPEN")
	_poke_overtravel = false
	_poke_latching = false
	_poke_consumed = false


# closed = min_deg, open = max_deg: wheel UP opens, wheel DOWN closes.
func _open_toward_max() -> bool:
	return true


# On release: close if the hand left it near shut, else let the spring take over.
func _on_released() -> void:
	if target == null:
		return
	var cur := rad_to_deg(target.rotation.x)
	if absf(cur - min_deg) <= close_latch_deg:
		latch_closed()


# Ease back toward fully open whenever it's neither held nor latched shut. Silent
# (no signal) — only latch_closed reports state; the spring return isn't "an event".
func _on_idle(delta: float) -> void:
	if target == null:
		return
	if _latched_closed:
		_step_latch_rebound(delta)
		return
	_step_spring_open(delta)


func _step_latch_rebound(delta: float) -> void:
	if not _latch_rebound or target == null:
		return
	var rebound_cur := rad_to_deg(target.rotation.x)
	var rebound_next := move_toward(rebound_cur, min_deg,
		push_push_rebound_speed_deg * delta)
	target.rotation.x = deg_to_rad(rebound_next)
	if is_equal_approx(rebound_next, min_deg):
		_latch_rebound = false
		_state_log("latch rebound settled at %.2f deg" % min_deg)
		_finish_latch_feedback()


func _finish_latch_feedback() -> void:
	if is_instance_valid(_latch_feedback_ctrl) and _latch_feedback_ctrl.get_is_active():
		Haptics.pulse(_latch_feedback_ctrl, LATCH_REST_HAPTIC_MAGNITUDE,
			LATCH_HAPTIC_MS, LATCH_REST_HAPTIC_KEY)
	_latch_feedback_ctrl = null


func _step_spring_open(delta: float) -> void:
	if target == null:
		return
	var cur := rad_to_deg(target.rotation.x)
	if is_equal_approx(cur, max_deg):
		return
	var next := move_toward(cur, max_deg, spring_speed_deg * delta)
	_apply(next, false)
	if is_equal_approx(next, max_deg) and not _spring_logged_open:
		_spring_logged_open = true
		_state_log("SPRUNG_OPEN at %.2f deg" % max_deg)


## Build a spring lid rig on `host` from an already-placed lid mesh: a DiscLidPivot
## at the lid's real back-edge hinge, the lid reparented onto it, and a
## VRSpringLatchedHinge with a grab box over the lid. `open_deg` is how far up it
## swings. Mirrors playstation_one_model._mount_lid (the recipe that opens the right
## way): pivot at the lid's back-bottom edge, 180° yaw so +rotation lifts the front.
## Returns the hinge (connect rotation_changed for tray-state reporting).
static func mount(host: Node3D, lid: MeshInstance3D, open_deg: float) -> VRSpringLatchedHinge:
	if host == null or lid == null:
		return null
	# In the HOST's own frame, never the world's. An axis-aligned world box picks
	# its back edge by world -Z, so a console standing at any yaw but zero gets its
	# hinge on whichever side happens to face away — at 180 deg that is the FRONT,
	# and the lid swings down over it. A restored room sets the saved rotation
	# before adding the child, so the shell is already turned when this runs.
	var to_host := host.global_transform.affine_inverse()
	var ab: AABB = (to_host * lid.global_transform) * lid.get_aabb()
	var pivot := Node3D.new()
	pivot.name = "DiscLidPivot"
	host.add_child(pivot)
	pivot.transform = Transform3D(Basis(Vector3.UP, PI),
		Vector3(ab.get_center().x, ab.position.y, ab.position.z))
	var world := lid.global_transform
	lid.reparent(pivot, false)
	lid.global_transform = world
	var hinge := VRSpringLatchedHinge.new()
	hinge.name = "DiscLidHinge"
	hinge.target = pivot
	hinge.min_deg = 0.0
	hinge.max_deg = open_deg
	hinge.engage_radius = clampf(maxf(ab.size.x, ab.size.z) * 0.4, 0.03, 0.09)
	pivot.add_child(hinge)
	# Grab box over the lid (in pivot-local), thin along the lid's normal.
	hinge.position = pivot.transform.affine_inverse() * ab.get_center()
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(ab.size.x, 0.02), maxf(ab.size.z, 0.02), maxf(ab.size.y, 0.01) + 0.02)
	col.shape = box
	hinge.add_child(col)
	# Hint in the lid's OWN plane, just past the grab box — the authored lids
	# carry this as their HingeHint node position; a code-built rig sets its own.
	# The line is pivot -> hinge, which for this rig is simply hinge.position.
	var away := hinge.position.normalized() if hinge.position.length() > 0.0001 else Vector3.UP
	var reach: float = (absf(away.x) * box.size.x + absf(away.y) * box.size.y \
		+ absf(away.z) * box.size.z) * 0.5
	hinge.place_hint(away * (reach + 0.014))
	return hinge

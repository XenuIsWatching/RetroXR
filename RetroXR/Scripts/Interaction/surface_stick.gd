## SurfaceStick — sticks a pickable to whatever surface it is released against, and
## makes it ride whatever it stuck to.
##
## A child component rather than a base class, for the reason FloatLock gives: the
## things that want this already extend XRToolsPickable and GDScript has one
## inheritance slot.
##
## THE RELEASE IS NOT THE `dropped` SIGNAL. A ray grab is a second, parallel hold:
## XRToolsFunctionPickup._end_ray_grab restores the body itself and never calls
## let_go(), so `dropped` never fires and is_picked_up() is false for the whole
## hold — the addon says as much in its own comment there, which is why a snap zone
## has to be handed a ray-released object explicitly. Since placing a poster on a
## far wall by ray is the main gesture, a dropped-driven stick would work in
## hand-testing and fail in use. The predicate true for ALL THREE holds (hand, snap
## zone, ray) is `freeze`, so the hold is tracked by polling that instead.
class_name SurfaceStick
extends Node

## Emitted after the body has stuck to `target`, and again with null when peeled.
signal stuck_changed(target: Node3D)
## The landing adopted an angle from how the sheet was being held.
signal roll_inherited(degrees: float)

## How far in front of the sheet to look for a surface when it is let go.
## How far to look for a surface when the sheet is let go.
##
## Generous on purpose. A player holds a poster UP TO a wall at arm's length and
## lets go; they do not press it against the plaster first. At 0.12 m — which is
## what a test that placed the sheet 2 cm out and perfectly square was happy with
## — every real release missed and the poster fell on the floor.
const REACH := 0.35
## How far along the laser to look. A poster is placed across a room with it.
const AIM_REACH := 6.0
## Clear of the surface, against z-fighting. The room's own framed posters sit 17 mm
## off the wall; a bare sheet only needs enough to not fight the plaster.
const SKIN := 0.002
## What counts as something to stick to: World (1) for the room shell and its
## furniture, and Pickable (3) for the machines and decks standing in it.
##
## Pickable is not optional — a television is an XRToolsPickable on layer 3, not
## world geometry, so a probe that searched only World found the walls and went
## straight through every object in the room.
const SURFACE_MASK := (1 << 0) | (1 << 2)

var target: Node3D = null
var anchor_position := Vector3.ZERO
var anchor_normal := Vector3.FORWARD

var _body: RigidBody3D = null
var _ray: RayCast3D = null
var _was_held := false
var _orig_freeze_mode: int = RigidBody3D.FREEZE_MODE_STATIC
## Where the holder was AIMING when it let go, in world space, or zero.
##
## Set by the owner while a laser holds it. A ray-held poster floats at the
## beam's hold distance with whatever facing it was grabbed with, so probing out
## of its own face finds empty room — the surface the player means is the one
## under the laser, which can be metres away. Aim wins when it is set.
var aim_direction := Vector3.ZERO
## In-plane spin, in radians about the surface normal. Sticking squares a sheet
## up to world-up, which is right for a first placement and wrong as the only
## option — a poster hung on a slant is a deliberate look.
var roll := 0.0


static func attach(body: RigidBody3D, ray: RayCast3D) -> SurfaceStick:
	var s := SurfaceStick.new()
	s.name = "SurfaceStick"
	body.add_child(s)
	s._bind(body, ray)
	return s


func _bind(body: RigidBody3D, ray: RayCast3D) -> void:
	_body = body
	_ray = ray
	_orig_freeze_mode = body.freeze_mode
	set_physics_process(true)


func is_stuck() -> bool:
	return is_instance_valid(target)


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(_body):
		return
	# `freeze` is the one predicate every hold sets — see the class comment.
	var held := _body.freeze and not is_stuck()
	if held:
		_was_held = true
		return
	if _was_held:
		_was_held = false
		# Deferred: the release restores a freeze snapshot and applies throw
		# velocity, and both would land on top of anything done here.
		try_stick.call_deferred()


## Look straight out of the sheet's face. Not from the hand: under a ray grab the
## body floats metres away from the controller, so a controller-origin probe finds
## whatever is in front of the PLAYER instead of what the poster is against.
## Where this body would stick if it were let go right now: {position, normal,
## collider}, or empty when nothing is in reach.
##
## Shared by the preview and the commit on purpose — a preview drawn from
## different arithmetic than the placement is a preview that lies.
func predict() -> Dictionary:
	if not is_instance_valid(_body) or not _body.is_inside_tree():
		return {}
	var space := _body.get_world_3d().direct_space_state
	if space == null:
		return {}
	var from := _body.global_position

	# The laser first, when there is one: that is the surface the player chose, and
	# a ray-held sheet floats at the beam's hold distance facing however it was
	# grabbed, so its own face usually looks at nothing.
	if aim_direction.length_squared() > 0.0001:
		var ah := _cast(space, from, aim_direction, AIM_REACH)
		if not ah.is_empty():
			return ah

	# Otherwise both faces, nearest wins. Which way round a sheet is held is
	# arbitrary — a poster has a front but a hand does not — so looking only out of
	# its -Z made "held back-to-front" a poster that fell on the floor. Sticking
	# squares it up either way, so the two cases end identically.
	var best: Dictionary = {}
	var best_d := REACH + 1.0
	for dir: Vector3 in [-_body.global_transform.basis.z, _body.global_transform.basis.z]:
		var hit := _cast(space, from, dir, REACH)
		if hit.is_empty():
			continue
		var d: float = from.distance_to(hit["position"] as Vector3)
		if d < best_d:
			best_d = d
			best = hit
	return best


func _cast(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3,
		reach: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir.normalized() * reach)
	q.collision_mask = SURFACE_MASK
	q.exclude = [_body.get_rid()]
	return space.intersect_ray(q)


## The pose the sheet would take on `hit`, for a preview or for the commit.
func pose_for(hit: Dictionary) -> Transform3D:
	var n := (hit["normal"] as Vector3).normalized()
	return _surface_basis(n, (hit["position"] as Vector3) + n * SKIN)


func try_stick() -> void:
	if is_stuck():
		return
	var hit := predict()
	if hit.is_empty():
		return
	# Keep the angle it was being held at, but only off the BEAM. The off-hand
	# stick already turns a ray-held object — that is xr-tools' own gesture — and
	# squaring up on landing threw the result away, so the rotation the player just
	# made was pointless. A HAND placement is left to square up: a wrist is not a
	# deliberate angle, and baking its wobble in would make every poster crooked.
	if aim_direction.length_squared() > 0.0001:
		inherit_roll_from_pose((hit["normal"] as Vector3).normalized())
	stick_to(hit["collider"] as Node3D, hit["position"] as Vector3,
		(hit["normal"] as Vector3).normalized())


## Commit against a surface. `point`/`normal` are world space.
func stick_to(collider: Node3D, point: Vector3, normal: Vector3) -> void:
	var host := _host_for(collider)
	if host == null:
		return
	var n := normal.normalized()
	_body.global_transform = _surface_basis(n, point + n * SKIN)

	# Ride it. Same recipe MediaSlot uses to make a disc ride the tray: static
	# freeze, reparent, and an exception so the two colliders do not shove each
	# other. Everything after this is expressed in the host's frame, so carrying
	# the host costs nothing.
	_body.linear_velocity = Vector3.ZERO
	_body.angular_velocity = Vector3.ZERO
	_body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	_body.freeze = true
	if _body.get_parent() != host:
		_body.reparent(host, true)
	if host is CollisionObject3D:
		_body.add_collision_exception_with(host)
	# Physics interpolation is on project-wide; without this the first drawn frame
	# slides in from wherever the body was before the reparent.
	_body.reset_physics_interpolation()

	target = host
	anchor_position = host.to_local(_body.global_position)
	anchor_normal = host.global_transform.basis.inverse() * n
	stuck_changed.emit(host)


## Hand the body back to the room.
##
## `held` says something is holding it right now — a hand or a beam — in which
## case the hold owns `freeze` and this must not fight it. What this ALWAYS does
## is correct the hold's snapshot: every grab copies `freeze` into
## `restore_freeze` and hands it back on release, and a parked poster is frozen,
## so an uncorrected snapshot restores the park and the poster hangs in mid-air
## wherever it was let go. Correct the snapshot, not just the flag — the same
## correction RetroTV._on_tv_grabbed makes for its own park.
func peel(held: bool = false) -> void:
	if not is_stuck():
		if is_instance_valid(_body) and held:
			_body.restore_freeze = false
		return
	var host := target
	target = null
	if is_instance_valid(_body):
		if is_instance_valid(host) and host is CollisionObject3D:
			_body.remove_collision_exception_with(host)
		var scene := _body.get_tree().current_scene if _body.is_inside_tree() else null
		if scene != null and _body.get_parent() != scene:
			_body.reparent(scene, true)
		_body.freeze_mode = _orig_freeze_mode
		_body.restore_freeze = false
		if not held:
			_body.freeze = false
			_body.sleeping = false
		_body.reset_physics_interpolation()
	stuck_changed.emit(null)


## Adopt the sheet's current in-plane angle as its roll, so a landing keeps the
## orientation the player set rather than snapping upright.
##
## Measured against the same world-up reference _surface_basis starts from, so
## the two cannot disagree about where zero is.
func inherit_roll_from_pose(n: Vector3) -> void:
	if not is_instance_valid(_body):
		return
	var base_up := Vector3.UP - n * Vector3.UP.dot(n)
	if base_up.length_squared() < 0.0001:
		base_up = Vector3.FORWARD - n * Vector3.FORWARD.dot(n)
	base_up = base_up.normalized()
	# The held sheet's own up, flattened into the surface it is about to lie on.
	var held_up := _body.global_transform.basis.y
	held_up = held_up - n * held_up.dot(n)
	if held_up.length_squared() < 0.0001:
		return      # edge-on: no in-plane angle to read
	held_up = held_up.normalized()
	var angle := base_up.signed_angle_to(held_up, n)
	roll = angle
	roll_inherited.emit(rad_to_deg(angle))


## Re-apply the pose after the roll changed, keeping the anchor. Nothing about
## what it is stuck TO changes, so this must not go back through stick_to and
## re-parent or re-probe.
func reapply_roll() -> void:
	if not is_stuck() or not is_instance_valid(_body) or not is_instance_valid(target):
		return
	var n := (target.global_transform.basis * anchor_normal).normalized()
	var at := target.to_global(anchor_position)
	_body.global_transform = _surface_basis(n, at)
	_body.reset_physics_interpolation()


## Re-park after a slot restore. The restore's own _let_go hands gravity back to
## everything it froze, so a poster that was saved stuck has to re-assert itself
## after that sweep rather than during it.
func repark() -> void:
	if not is_instance_valid(_body) or not is_stuck():
		return
	_body.linear_velocity = Vector3.ZERO
	_body.angular_velocity = Vector3.ZERO
	_body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	_body.freeze = true


## The node a poster should hang off: the nearest ancestor that is a spawned object
## or a pickable, else the body that was hit. A wall's StaticBody3D is its own host,
## which is what makes a wall poster reparent to something that never moves.
func _host_for(collider: Node3D) -> Node3D:
	var node: Node = collider
	while node != null:
		if node is XRToolsPickable or node.is_in_group("spawned"):
			return node as Node3D
		if node is StaticBody3D:
			return node as Node3D
		node = node.get_parent()
	return collider


## The sheet's +Z along the surface normal, up as near world-up as the surface
## allows. Same construction retro_mouse uses to lie a mouse on a desk, turned for
## a face rather than a base.
func _surface_basis(n: Vector3, origin: Vector3) -> Transform3D:
	var up := Vector3.UP - n * Vector3.UP.dot(n)
	if up.length_squared() < 0.0001:
		# Floor or ceiling: no world-up component survives, so pick any axis in
		# the plane and let the sheet lie flat.
		up = Vector3.FORWARD - n * Vector3.FORWARD.dot(n)
	up = up.normalized()
	var basis := Basis(up.cross(n), up, n).orthonormalized()
	if not is_zero_approx(roll):
		# About the normal, so the sheet spins in the surface it is lying on rather
		# than lifting a corner off it.
		basis = Basis(n, roll) * basis
	return Transform3D(basis, origin)

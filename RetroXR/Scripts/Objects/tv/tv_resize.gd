## TvResize — growing and shrinking a television, and what that does to the room
## around it.
##
## A child of the RetroTV it serves, created unconditionally in _init because
## _ready applies the authored size before anything else, in the same shape as
## SaveStateController and HandheldInput.
##
## Lifted out of tv.gd whole, and it was the cleanest seam in that file: 274
## lines reaching the set for six names, none of them CRT, OSD or tuner state.
## The public surface is two calls — apply() when the size changes, and
## revalidate_park() every frame — plus RetroTV.set_tv_scale, which stays where
## it is because the options panel and object_sync both call it by name.
##
## scale_factor stays on RetroTV too: scene_persistence writes it by name and a
## peer's resize arrives as a property on the set, not on this.
##
## What is worth knowing before editing: a resize is a PLACEMENT, not a
## collision. Almost every rule below exists because the solver, left to answer
## a resize on its own, gives an answer no player would call correct — it sinks
## the set through its table, walks it across the room, or ejects whatever was
## standing on top of it out through the bottom. Tests/tv_resize_tests pins all
## of it.
class_name TvResize
extends Node

## The set this resizes. Every property write below lands on it.
var _tv: RetroTV = null


func setup(tv: RetroTV) -> void:
	_tv = tv


## Drop the park without touching the body, because the caller is taking the pose
## over — picking the set up ends a park by definition.
##
## Answers whether there WAS one. XRToolsPickable snapshots freeze into
## restore_freeze before `grabbed` fires and its release_mode is ORIGINAL, so a
## park left in that snapshot is restored on release and the set hangs wherever it
## was let go. Correcting the snapshot needs the pickable, so the set does that
## half and this reports whether it has to.
func clear_park() -> bool:
	if not _parked_by_resize:
		return false
	_parked_by_resize = false
	return true


## Put the set's current scale_factor on the node, and everything that follows
## from having done so.
func apply() -> void:
	# A set grows in place: same spot on the floor, same footprint centre, the
	# extra size going straight up. Two things have to be true for that to hold.
	#
	# One, the bottom is pinned rather than the origin. Scaling about the centre
	# drives the base into whatever the set is standing on, and the solver answers
	# a penetration by ejecting the body downward — the TV sinks through the
	# surface. Holding the lowest point fixed keeps the contact intact.
	#
	# Two, nothing may push it sideways. Nothing here does, and the freeze below
	# stops the solver doing it: enlarging a set against a wall, or over the edge of
	# the table it stands on, leaves an overlap the solver evicts, which walks the
	# set across the room. Resizing something that is standing somewhere is a
	# placement, not a collision, so the body is parked and the overlap is simply
	# allowed. A big set can clip the wall behind it; that beats it walking away.
	#
	# Parked means frozen, not asleep. Sleeping looks like it works and does not
	# last: anything that disturbs the body's island wakes it — a footstep away,
	# an object landing nearby — and it is evicted then instead, so the set sits
	# still through the whole drag and lurches half a metre once you let go.
	#
	# The offset is an unscaled local constant rather than a world measurement taken
	# after the write: a child's global_transform is still stale in the frame its
	# parent's scale changes, so re-measuring reads back pre-scale values and the
	# correction cancels to nothing.
	#
	# previous is tracked here, not read back off scale.y, because the authored or
	# restored position already sits where the anchoring puts it. Correcting a
	# scale the node has never actually worn would lift a persisted 2.1x set again
	# on every load.
	var previous := _anchored_scale
	_anchored_scale = _tv.scale_factor
	# Measured before the scale write, which is what leaves the children stale —
	# and unconditionally, so the very first call, from _ready, is the one that
	# fills the cache while every transform is still coherent.
	var bottom := _local_bottom_y()
	# bottom_world = origin_y + s * local_bottom, so holding it fixed means
	# shifting the origin by (old_s - new_s) * local_bottom.
	var delta := previous - _tv.scale_factor
	# Whatever is standing on the set, found while the cabinet is still its old
	# size — see _carry_riders for why they cannot be left to the solver. Skipped
	# when the size is not actually moving: _on_tv_dropped reasserts the current
	# scale on every release, and that must not cost a shape query.
	var resizing := not is_nan(previous) and not is_zero_approx(delta)
	var riders: Array[RigidBody3D] = []
	if resizing:
		riders = _riders(previous)
	_tv.scale = Vector3.ONE * _tv.scale_factor
	if not resizing:
		return
	_tv.global_position.y += delta * bottom
	# The bottom is pinned, so the top moved by exactly the change in height.
	_carry_riders(riders, _collider_height() * (_tv.scale_factor - previous))
	# Held: the grab driver owns the pose, so there is nothing to park.
	if _tv.freeze and not _parked_by_resize:
		return
	# Only a set that is BOTH standing on something and jammed into something needs
	# parking. On open floor the enlarged cabinet touches nothing, there is no
	# penetration to evict, and the body is left as ordinary physics — which is the
	# common case, and the one where a stuck freeze would be most obvious.
	#
	# The park is released again the moment it is not needed, so shrinking a set
	# back down hands it straight to physics. Parking on the way up and never
	# undoing it leaves a set frozen at 1.0x with nothing holding it there.
	#
	# force_update_transform either way: the write above only queues a transform
	# notification, and the flush at the end of the frame is what hands the pose to
	# the physics server. Freezing before that flush parks the body at its old pose,
	# and unfreezing before it resumes gravity from a stale one.
	if _is_standing_on_something() and _is_jammed():
		_tv.linear_velocity = Vector3.ZERO
		_tv.angular_velocity = Vector3.ZERO
		_tv.force_update_transform()
		_tv.freeze = true
		_parked_by_resize = true
	elif _parked_by_resize:
		_tv.force_update_transform()
		_tv.freeze = false
		_parked_by_resize = false


## How thick a slab above the cabinet's top face counts as "standing on it".
const _RIDER_SLAB := 0.03


## Height of the pickup collider at scale 1.
func _collider_height() -> float:
	var col := _tv.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or not (col.shape is BoxShape3D):
		return 0.0
	return (col.shape as BoxShape3D).size.y


## The bodies standing on top of the set, measured with the cabinet at `at_scale`.
##
## A thin slab just above the top face: a box resting on the cabinet is caught and
## the cabinet itself is not. Dynamic bodies only — world geometry cannot ride
## anything, and a frozen body is either held, parked, or seated in one of our own
## sockets, none of which wants to be shoved.
func _riders(at_scale: float) -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	var col := _tv.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or not (col.shape is BoxShape3D) or _tv.get_world_3d() == null \
			or is_nan(at_scale):
		return out
	var full: Vector3 = (col.shape as BoxShape3D).size * at_scale
	var slab := BoxShape3D.new()
	# Shy of the footprint on the horizontal axes so a set standing against a wall
	# does not count the wall, which is static anyway but also not free.
	slab.size = Vector3(maxf(full.x - 0.01, 0.01), _RIDER_SLAB, maxf(full.z - 0.01, 0.01))
	var axes := _tv.global_basis.orthonormalized()
	var centre: Vector3 = _tv.global_position + axes * (col.position * at_scale) \
		+ Vector3.UP * (full.y * 0.5 + _RIDER_SLAB * 0.5)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = slab
	query.transform = Transform3D(axes, centre)
	query.exclude = [_tv.get_rid()]
	query.collide_with_areas = false
	for hit: Dictionary in _tv.get_world_3d().direct_space_state.intersect_shape(query, 16):
		var rb := hit.get("collider") as RigidBody3D
		if rb == null or rb == _tv or rb.freeze or _tv.is_ancestor_of(rb):
			continue
		if not out.has(rb):
			out.append(rb)
	return out


## Move what was standing on the set by however far the top face just moved.
##
## Resizing is a PLACEMENT, and this is the half of that the solver cannot do for
## you. Growing the cabinet in one step — a committed slider value, a size restored
## from a save, a peer's resize — swallows whatever was on top, and Jolt answers a
## body that is suddenly deep inside another by ejecting it through the nearest
## face: it drops out of the bottom of the set and lands on the floor. Dragging the
## slider hid this, because a 0.1 step only grows the box a couple of centimetres
## and the solver pushes the object back UP each tick.
##
## Only lifted on the way up. Shrinking needs no move — the set slides out from
## under whatever was on it and gravity does the rest — but it does need the WAKE
## below, because a body that fell asleep resting on the cabinet is not disturbed
## by the cabinet leaving, and it hangs in the air where the set used to be.
func _carry_riders(riders: Array[RigidBody3D], lift: float) -> void:
	for rb in riders:
		if not is_instance_valid(rb):
			continue
		if lift > 0.0:
			rb.global_position.y += lift
			# Teleports and physics interpolation: without this the object renders
			# sliding up from where it was rather than arriving with the cabinet.
			rb.reset_physics_interpolation()
		rb.sleeping = false


## Scale the anchor correction was last applied at. NAN until the first
## apply(), whose job is only to put the authored/restored scale on the node.
var _anchored_scale: float = NAN

## Whether the freeze on this body is ours, from a resize, rather than the one
## XRToolsPickable puts on while the set is held.
var _parked_by_resize: bool = false

## How close the base has to be to a surface to count as standing on it, and how
## far the cabinet has to be inside something else to count as jammed.
const _STANDING_GAP := 0.04
const _JAM_DEPTH := 0.01

## Frames between park revalidations. A parked body is frozen, so it has no
## gravity to notice with — nothing else would ever tell it the floor is gone.
const _PARK_CHECK_FRAMES := 12
var _park_check_frame: int = 0


## A park only holds while the set is still standing on something. Re-checked a
## few times a second rather than at the next resize, because what it stands on can
## go away — carried off, deleted with the scene, or scaled out from under it — and
## a frozen set left over an empty floor just hangs there. This is the invariant
## that keeps the freeze from ever reading as a bug: frozen implies supported.
func revalidate_park() -> void:
	if not _parked_by_resize:
		return
	_park_check_frame += 1
	if _park_check_frame < _PARK_CHECK_FRAMES:
		return
	_park_check_frame = 0
	if _is_standing_on_something():
		return
	_tv.force_update_transform()
	_tv.freeze = false
	_parked_by_resize = false


## Whether the set is resting on a surface rather than in flight. Asked fresh per
## resize rather than tracked off the sleep state: a set put down and resized
## straight away — the usual way anyone reaches for the size slider — has not had
## time to fall asleep, and gating on sleep left exactly that case unprotected.
##
## Cast from the base, over a fixed gap. Casting from the origin over a reach that
## grows with the set instead means a big cabinet reads as standing while it is
## still a metre up, so resizing one on the way down parks it in the air.
func _is_standing_on_something() -> bool:
	var world := _tv.get_world_3d()
	if world == null:
		return false
	var base: Vector3 = _tv.global_position + Vector3.UP * (_local_bottom_y() * _tv.scale_factor)
	var query := PhysicsRayQueryParameters3D.create(
		base + Vector3.UP * _STANDING_GAP, base + Vector3.DOWN * _STANDING_GAP)
	query.exclude = [_tv.get_rid()]
	query.collision_mask = _tv.collision_mask
	return not world.direct_space_state.intersect_ray(query).is_empty()


## Whether the cabinet at its new size is inside the world — the wall behind it,
## the table it now overhangs. The box is shrunk by _JAM_DEPTH so the surface the
## set merely rests on does not read as a jam, and the base is lifted clear of it.
##
## Static bodies only. A prop that has come to rest against the cabinet also shows
## up in the query, and counting it would leave the set parked for as long as
## anything is lying on it. A loose prop is also not the problem being solved: the
## solver pushes it out of the way, which is fine. It is immovable world geometry
## that turns an overlap into an eviction the set can never win.
func _is_jammed() -> bool:
	var col := _tv.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or not (col.shape is BoxShape3D) or _tv.get_world_3d() == null:
		return false
	var full: Vector3 = (col.shape as BoxShape3D).size * _tv.scale_factor
	var box := BoxShape3D.new()
	box.size = Vector3(
		maxf(full.x - 2.0 * _JAM_DEPTH, 0.01),
		maxf(full.y - 2.0 * _JAM_DEPTH, 0.01),
		maxf(full.z - 2.0 * _JAM_DEPTH, 0.01))
	var axes := _tv.global_basis.orthonormalized()
	# Nudged up off the supporting surface, which sits exactly at the pinned base.
	var centre: Vector3 = _tv.global_position + axes * (col.position * _tv.scale_factor) \
		+ Vector3.UP * _JAM_DEPTH
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = Transform3D(axes, centre)
	query.exclude = [_tv.get_rid()]
	query.collision_mask = _tv.collision_mask
	for hit: Dictionary in _tv.get_world_3d().direct_space_state.intersect_shape(query, 8):
		if hit.get("collider") is StaticBody3D:
			return true
	return false


## Bottom of the pickup COLLIDER along Y, in local space at scale 1 — the point
## the resize anchor holds still and the point the standing ray casts from.
##
## The collider, not the geometry: what a set rests on is its collision box, and
## the two are not the same height. The 90s cabinet's lowest mesh sits 4.5 cm
## under its box, which is enough to break both callers at once. The anchor lifts
## further than the box actually grew, so the solver spends every slider tick
## shoving the set back down into the table; and the standing ray starts INSIDE
## that table, where Godot reports no hit at all, so `standing` reads false for
## every set on furniture and the park never engages.
##
## Reading the shape also keeps this honest about WHEN it is asked. A sweep of the
## meshes answers with whatever happened to be visible at the time, and
## TVOptionsPanel's viewport quad — most of a metre below the origin — joins the
## tree a frame or two after _ready.
##
## Cheap enough to leave uncached: two property reads, and _resize_body_collision
## swaps the shape out from under any cache when a shell is fitted.
func _local_bottom_y() -> float:
	var col := _tv.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or not (col.shape is BoxShape3D):
		return 0.0
	return col.position.y - (col.shape as BoxShape3D).size.y * 0.5

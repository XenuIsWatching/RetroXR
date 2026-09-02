class_name XRToolsGrabDriver
extends RemoteTransform3D


## Grab state
enum GrabState {
	LERP,
	SNAP,
}


## Drive state
var state : GrabState = GrabState.SNAP

## Target pickable
var target : XRToolsPickable

## Primary grab information
var primary : Grab = null

## Secondary grab information
var secondary : Grab = null

## Lerp start position
var lerp_start : Transform3D

## Lerp total duration
var lerp_duration : float = 1.0

## Lerp time
var lerp_time : float = 0.0

# LOCAL PATCH (RetroXR): snap-zone preview state. While the hand holds a
# compatible object within a socket's grab range, the object blends onto the
# socket pose so the user sees exactly where it will seat. Releasing there
# lets the zone capture it (standard DROPPED snap); pulling the hand away
# blends the object back to the hand.
const PREVIEW_BLEND_SPEED := 8.0    # blend/sec (~0.12 s each way)
var _preview_zone : XRToolsSnapZone = null
## LOCAL PATCH (RetroXR): false until this driver has driven its target at
## least once. See the early-out in _physics_process.
var _pushed_once := false

var _preview_blend : float = 0.0
# Cached bounding radius of the target so the preview engages at the same range
# the socket's ghost used to (object surface reaching the grab sphere).
var _preview_radius : float = -1.0
# While previewing, the object is driven onto a socket that overlaps its owner
# body (e.g. a cartridge into the console the socket is a child of). Their
# collision shapes fight and the console — a dynamic RigidBody — is shoved, and
# because the socket rides that same body the result is a feedback jitter. We
# suppress collisions between the two while previewing, mirroring grab.gd.
var _preview_collisions_on : bool = false
var _preview_exc_target : Array[RID] = []
# LOCAL PATCH (RetroXR): the holder-graph epoch this driver's physics priority
# was computed for. -1 so the first physics frame always recomputes.
var _priority_epoch : int = -1
var _preview_exc_owner : Array[RID] = []
# Whether the object is currently in snap-preview range; drives the pickable's
# orange snap-preview outline. Notify the highlight only on transitions.
var _prev_previewing : bool = false
# An object taken straight out of a socket starts the grab already AT that
# socket's seated pose, so the preview is seeded engaged instead of blending up
# from zero — see the first-frame seed below.
const PREVIEW_SEATED_EPSILON := 0.002   # m; "was sitting in this zone"
var _preview_seed_pending : bool = true
# How much of the zone's stand-off the ghost is currently drawn at. A grab that
# starts from the SEAT eases this up from nothing, so taking hold of seated media
# slides it out to the mouth instead of flicking it there — the stand-off can be
# tens of millimetres, which is a jump you would see.
var _perch_ease : float = 1.0
# LOCAL PATCH (RetroXR): `primary.by is XRToolsSnapZone`, resolved once per
# Grab object instead of twice per physics tick. Keyed on the Grab itself so any
# reassignment of `primary` (create_*, add_grab, remove_grab, or a release fired
# from set_arrived mid-tick) refreshes it before the next use.
var _primary_cached : Grab = null
var _primary_by_zone : bool = false

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta : float) -> void:
	# Skip if no primary node or its grabber has been freed
	if not is_instance_valid(primary) or not is_instance_valid(primary.by):
		return

	# Set destination from primary grab
	var destination := primary.by.global_transform * primary.transform.affine_inverse()

	# If present, apply secondary-node contributions
	if is_instance_valid(secondary):
		# Calculate lerp coefficients based on drive strengths
		var position_lerp := _vote(primary.drive_position, secondary.drive_position)
		var angle_lerp := _vote(primary.drive_angle, secondary.drive_angle)

		# Calculate the transform from secondary grab
		var x1 := destination
		var x2 := secondary.by.global_transform * secondary.transform.affine_inverse()

		# Independently lerp the angle and position
		destination = Transform3D(
			x1.basis.slerp(x2.basis, angle_lerp),
			x1.origin.lerp(x2.origin, position_lerp))

		# Test if we need to apply aiming
		if secondary.drive_aim > 0.0:
			# Convert destination from global to primary-local
			destination = primary.by.global_transform.affine_inverse() * destination

			# Calculate the from and to vectors in primary-local space
			var secondary_from := destination * secondary.transform.origin
			var secondary_to := primary.by.to_local(secondary.by.global_position)

			# Build shortest arc
			secondary_from = secondary_from.normalized()
			secondary_to = secondary_to.normalized()
			var spherical := Quaternion(secondary_from, secondary_to)

			# Build aim-rotation
			var rotate := Basis.IDENTITY.slerp(Basis(spherical), secondary.drive_aim)
			destination = Transform3D(rotate, Vector3.ZERO) * destination

			# Convert destination from primary-local to global
			destination = primary.by.global_transform * destination

	# Handle update
	match state:
		GrabState.LERP:
			# Progress the lerp
			lerp_time += delta
			if lerp_time < lerp_duration:
				# Interpolate from lerp_start to destination
				destination = lerp_start.interpolate_with(
					destination,
					lerp_time / lerp_duration)
			else:
				# Lerp completed
				state = GrabState.SNAP
				_update_weight()
				if primary: primary.set_arrived()
				if secondary: secondary.set_arrived()

	# LOCAL PATCH (RetroXR): snap-zone preview — blend the held object onto a
	# compatible socket while the HAND's desired pose is within its grab range.
	# The engage test must use `destination` (where the hand wants the object),
	# not the object's actual position: while previewing, the object sits AT
	# the zone, so testing its own position could never disengage.
	if primary != _primary_cached:
		_primary_cached = primary
		_primary_by_zone = primary.by is XRToolsSnapZone
	if state == GrabState.SNAP and is_instance_valid(target) \
			and not _primary_by_zone:
		var r := _get_preview_radius()
		var zone := XRToolsSnapZone.find_preview_zone(target, destination.origin, r)
		# First frame of a grab that took the object out of a socket: it is still
		# standing in that socket's seated pose, so engage the preview already
		# blended in. Starting from zero puts it at the hold pose for a frame and
		# then drags it back over ~0.12 s — a jump out to the hold pose and a jump
		# back into the seat, most visible on desktop, where the hold pose comes
		# from where the player is LOOKING and so barely moves. Seeded, the object
		# simply stays seated until the hold pose leaves the socket's range.
		if _preview_seed_pending:
			_preview_seed_pending = false
			if zone != null and target.global_position.distance_to(
					zone.snap_pose_for(target).origin) < PREVIEW_SEATED_EPSILON:
				_preview_blend = 1.0
				_perch_ease = 0.0
		if zone == null and is_instance_valid(_preview_zone) \
				and _preview_zone.can_preview(target) \
				and _preview_zone.global_position.distance_to(destination.origin) \
					< (_preview_zone.grab_distance + r) * 1.25:
			zone = _preview_zone   # hysteresis: hold the zone a bit past range
		if zone:
			_preview_zone = zone
		# Orange snap-preview outline on the held object while it targets a
		# socket (in range / hysteresis); notify the highlight only on change.
		var previewing := zone != null
		if previewing != _prev_previewing:
			_prev_previewing = previewing
			_notify_snap_preview(previewing)
		_preview_blend = move_toward(
			_preview_blend, 1.0 if zone else 0.0, delta * PREVIEW_BLEND_SPEED)
		_perch_ease = move_toward(_perch_ease, 1.0, delta * PREVIEW_BLEND_SPEED)
		# Suppress object<->socket-owner collisions while engaged so the console
		# isn't shoved by the previewed object (which would jitter the socket).
		_set_preview_collisions(zone != null)
		if _preview_blend > 0.001 and is_instance_valid(_preview_zone):
			# The zone's own preview pose: grab-point-corrected (without it the
			# ghost shows the raw zone orientation, e.g. a plug backwards) and
			# offset by whatever stand-off the zone presents its media at.
			var zt := _preview_zone.preview_pose_for(target, _perch_ease)
			var w := smoothstep(0.0, 1.0, _preview_blend)
			var scale := destination.basis.get_scale()
			var q := destination.basis.get_rotation_quaternion().slerp(
				zt.basis.get_rotation_quaternion(), w)
			destination = Transform3D(
				Basis(q).scaled(scale),
				destination.origin.lerp(zt.origin, w))
		elif _preview_blend <= 0.001:
			_set_preview_collisions(false)
			_preview_zone = null

	# LOCAL PATCH (RetroXR): the stack this driver sits in can change under it --
	# a loaded 32X is bolted into a console long after its cartridge went in, and
	# that is the moment the cartridge's driver has to start running later than
	# the 32X's. Rechecked only when the holder graph has actually changed, so
	# the common case is one integer compare.
	if primary and _primary_by_zone:
		var epoch := XRToolsSnapZone.holder_epoch()
		if epoch != _priority_epoch:
			_priority_epoch = epoch
			var want := _priority_for(primary)
			if want != process_physics_priority:
				process_physics_priority = want

	# LOCAL PATCH (RetroXR): always push once, however the driver was built.
	#
	# create_snap and create_lerp set the driver's transform to the destination
	# BEFORE remote_path is assigned, so a RemoteTransform3D built that way has
	# nothing to report: its transform never changes, this early-out matches on
	# the first tick, and the target is never moved. A hand-held object escapes
	# it because the hand keeps moving; an object handed to a zone
	# programmatically -- a save restore seating a cartridge, a console lowered
	# onto an expansion -- does not, and simply stays where it was left.
	if _pushed_once and global_transform.is_equal_approx(destination):
		return
	_pushed_once = true

	# Apply the destination transform
	global_transform = destination
	force_update_transform()
	if is_instance_valid(target):
		target.force_update_transform()


## Set the secondary grab point
func add_grab(p_grab : Grab) -> void:
	# Set the secondary grab
	if p_grab.hand_point and p_grab.hand_point.mode == XRToolsGrabPointHand.Mode.PRIMARY:
		print_verbose("%s> new primary grab %s" % [target.name, p_grab.by.name])
		secondary = primary
		primary = p_grab
	else:
		print_verbose("%s> new secondary grab %s" % [target.name, p_grab.by.name])
		secondary = p_grab

	# If snapped then report arrived at the new grab
	if state == GrabState.SNAP:
		_update_weight()
		p_grab.set_arrived()


## Get the grab information for the grab node
func get_grab(by : Node3D) -> Grab:
	if primary and primary.by == by:
		return primary

	if secondary and secondary.by == by:
		return secondary

	return null


func remove_grab(p_grab : Grab) -> void:
	# Remove the appropriate grab
	if p_grab == primary:
		# Remove primary (secondary promoted)
		print_verbose("%s> %s (primary) released" % [target.name, p_grab.by.name])
		primary = secondary
		secondary = null
	elif p_grab == secondary:
		# Remove secondary
		print_verbose("%s> %s (secondary) released" % [target.name, p_grab.by.name])
		secondary = null

	if state == GrabState.SNAP:
		_update_weight()


# Discard the driver
func discard() -> void:
	# LOCAL PATCH (RetroXR): drop any preview collision exceptions we added.
	# When a socket captures the previewed object this hand-driver is discarded
	# and a new socket-driver takes over, so releasing here returns the object
	# to its normal (pre-preview) collision behaviour.
	_set_preview_collisions(false)
	_notify_snap_preview(false)
	remote_path = NodePath()
	queue_free()


# LOCAL PATCH (RetroXR): bounding radius of the target, cached. Used so the snap
# preview engages when the object's surface — not just its centre — reaches a
# socket's grab sphere, matching where the old ghost appeared.
func _get_preview_radius() -> float:
	if _preview_radius >= 0.0:
		return _preview_radius
	_preview_radius = 0.0
	# Use only the target body's OWN shapes (via the shape-owner API) — not any
	# separate child CollisionObject3D such as a wider pointer/ray proxy.
	var body := target as CollisionObject3D
	if body:
		for owner_id: int in body.get_shape_owners():
			var off: float = body.shape_owner_get_transform(owner_id).origin.length()
			for i: int in body.shape_owner_get_shape_count(owner_id):
				var shape: Shape3D = body.shape_owner_get_shape(owner_id, i)
				if shape:
					_preview_radius = maxf(_preview_radius, off + _shape_extent(shape))
	if _preview_radius <= 0.0:
		_preview_radius = 0.03
	return _preview_radius


static func _shape_extent(shape: Shape3D) -> float:
	if shape is SphereShape3D:
		return shape.radius
	if shape is BoxShape3D:
		return shape.size.length() * 0.5
	if shape is CapsuleShape3D:
		return shape.radius + shape.height * 0.5
	if shape is CylinderShape3D:
		return maxf(shape.radius, shape.height * 0.5)
	return 0.03


# LOCAL PATCH (RetroXR): add/remove mutual collision exceptions between the
# previewed object and the socket's owner body. Idempotent — only acts on a
# change of state, and removes exactly the RIDs it added.
func _set_preview_collisions(on: bool) -> void:
	if on == _preview_collisions_on:
		return
	if on:
		if not is_instance_valid(_preview_zone) or not is_instance_valid(target):
			return
		var owner_body := _owner_body(_preview_zone)
		if owner_body == null:
			return
		_preview_exc_target = _body_rids(target)
		_preview_exc_owner = _body_rids(owner_body)
		for a in _preview_exc_target:
			for b in _preview_exc_owner:
				PhysicsServer3D.body_add_collision_exception(a, b)
				PhysicsServer3D.body_add_collision_exception(b, a)
		_preview_collisions_on = true
	else:
		for a in _preview_exc_target:
			for b in _preview_exc_owner:
				PhysicsServer3D.body_remove_collision_exception(a, b)
				PhysicsServer3D.body_remove_collision_exception(b, a)
		_preview_exc_target.clear()
		_preview_exc_owner.clear()
		_preview_collisions_on = false


# First PhysicsBody3D ancestor of the socket (the body its Area3D rides on).
static func _owner_body(zone: Node) -> PhysicsBody3D:
	var n := zone.get_parent()
	while n:
		if n is PhysicsBody3D:
			return n
		n = n.get_parent()
	return null


# Collect the RIDs of `root` and its descendant physics bodies (skipping Area3D
# subtrees so we don't grab neighbouring snapped objects).
static func _body_rids(root: Node) -> Array[RID]:
	var out: Array[RID] = []
	if root is PhysicsBody3D:
		out.push_back(root.get_rid())
	for c: Node in root.get_children():
		if c is Area3D:
			continue
		out.append_array(_body_rids(c))
	return out


# Create the driver to lerp the target from its current location to the
# primary grab-point.
static func create_lerp(
	p_target : Node3D,
	p_grab : Grab,
	p_lerp_speed : float) -> XRToolsGrabDriver:

	print_verbose("%s> lerping %s" % [p_target.name, p_grab.by.name])

	# Construct the driver lerping from the current position
	var driver := XRToolsGrabDriver.new()
	driver.name = p_target.name + "_driver"
	driver.top_level = true
	driver.process_physics_priority = _priority_for(p_grab)
	driver.state = GrabState.LERP
	driver.target = p_target
	driver.primary = p_grab
	driver.global_transform = p_target.global_transform

	# Calculate the start and duration
	var end := p_grab.by.global_transform * p_grab.transform
	var delta := end.origin - p_target.global_position
	driver.lerp_start = p_target.global_transform
	driver.lerp_duration = delta.length() / p_lerp_speed

	# Add the driver as a neighbor of the target as RemoteTransform3D nodes
	# cannot be descendands of the targets they drive.
	p_target.get_parent().add_child(driver)
	driver.remote_path = driver.get_path_to(p_target)

	# Return the driver
	return driver


# Create the driver to instantly snap to the primary grab-point.
static func create_snap(
	p_target : Node3D,
	p_grab : Grab) -> XRToolsGrabDriver:

	print_verbose("%s> snapping to %s" % [p_target.name, p_grab.by.name])

	# Construct the driver snapped to the held position
	var driver := XRToolsGrabDriver.new()
	driver.name = p_target.name + "_driver"
	driver.top_level = true
	driver.process_physics_priority = _priority_for(p_grab)
	driver.state = GrabState.SNAP
	driver.target = p_target
	driver.primary = p_grab
	driver.global_transform = p_grab.by.global_transform * p_grab.transform.affine_inverse()

	# Snapped to grab-point so report arrived
	p_grab.set_arrived()

	# Add the driver as a neighbor of the target as RemoteTransform3D nodes
	# cannot be descendands of the targets they drive.
	p_target.get_parent().add_child(driver)
	driver.remote_path = driver.get_path_to(p_target)

	driver._update_weight()

	# Return the driver
	return driver


# LOCAL PATCH (RetroXR): physics priority for a new grab driver.
#
# Drivers all ran at -80, so a driver following a snap zone *inside* another
# held pickable (e.g. a cartridge snapped into a carried system) could run
# before that carrier's own driver in the same physics tick (same priority →
# tree order decides). It then read the snap zone's previous-tick transform,
# leaving the snapped object visibly trailing one physics tick behind while
# the carrier moves. Snap-zone-held drivers now run at -70 — after all
# hand-held drivers (-80) — so they always see this tick's carrier transform.
## LOCAL PATCH (RetroXR): a hand runs first, then each rank of sockets in turn.
##
## Hands at -80, sockets from -70 DOWN the stack: a socket mounted on a machine
## that is itself snapped into something must be placed after that something, or
## it reads a pose one physics frame old. All snap-zone drivers used to share
## -70, so the order among them was tree order -- and a tower assembled leaf
## first (cartridge into the 32X, then the 32X into the console) had them in
## exactly the wrong one. See XRToolsSnapZone.stack_depth for the measurements.
static func _priority_for(p_grab : Grab) -> int:
	if not p_grab.by is XRToolsSnapZone:
		return -80
	return -70 + XRToolsSnapZone.stack_depth(p_grab.by as XRToolsSnapZone)


# Calculate the lerp voting from a to b
static func _vote(a : float, b : float) -> float:
	if a == 0.0 and b == 0.0:
		return 0.0

	return b / (a + b)


# Update the weight on collision hands
func _update_weight() -> void:
	if primary:
		var weight : float = target.mass
		if secondary:
			# Each hand carries half the weight
			weight = weight / 2.0
			if secondary.collision_hand:
				secondary.collision_hand.set_held_weight(weight)

		if primary.collision_hand:
			primary.collision_hand.set_held_weight(weight)


# LOCAL PATCH (RetroXR): toggle the held object's orange snap-preview outline
# via its PickableHighlight (a direct child exposing set_snap_preview).
func _notify_snap_preview(on : bool) -> void:
	if not is_instance_valid(target):
		return
	for child: Node in target.get_children():
		if child.has_method("set_snap_preview"):
			child.set_snap_preview(on)
			return

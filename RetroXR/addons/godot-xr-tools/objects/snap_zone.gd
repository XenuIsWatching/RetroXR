@tool
class_name XRToolsSnapZone
extends Area3D


## Signal emitted when the snap-zone picks something up
signal has_picked_up(what)

## Signal emitted when the snap-zone drops something
signal has_dropped

# Signal emitted when the highlight state changes
signal highlight_updated(pickable, enable)

# Signal emitted when the highlight state changes
signal close_highlight_updated(pickable, enable)


## Enumeration of snap mode
enum SnapMode {
	DROPPED,	## Snap only when the object is dropped
	RANGE,		## Snap whenever an object is in range
}


## Enable or disable snap-zone
@export var enabled : bool = true: set = _set_enabled

## Optional audio stream to play when a object snaps to the zone
@export var stash_sound : AudioStream

## Grab distance
@export var grab_distance : float = 0.3: set = _set_grab_distance

## Snap mode
@export var snap_mode : SnapMode = SnapMode.DROPPED: set = _set_snap_mode

## Require snap items to be in specified group
@export var snap_require : String = ""

## Deny snapping items in the specified group
@export var snap_exclude : String = ""

## Require grab-by to be in the specified group
@export var grab_require : String = ""

## LOCAL PATCH (RetroXR): optional extra acceptance test `func(obj) -> bool`
## set by the zone's owner — e.g. a console slot only taking media whose
## systemid matches. Applies to hover/snap and the held preview; programmatic
## pick_up_object() (save/netplay restore) bypasses it on purpose.
var snap_filter: Callable = Callable()

## Deny grab-by
@export var grab_exclude : String= ""

## Initial object in snap zone
@export var initial_object : NodePath


# Public fields
var closest_object : Node3D = null
var picked_up_object : Node3D = null
var picked_up_ranged : bool = true


# Private fields
var _object_in_grab_area = Array()


# LOCAL PATCH (RetroXR): registry of live snap zones so held objects can find
# a nearby compatible socket for the snap PREVIEW (see grab_driver.gd).
static var _live_zones: Array[XRToolsSnapZone] = []

## LOCAL PATCH (RetroXR): how deep in a stack of sockets each zone sits, and a
## counter that changes whenever the answer might have.
##
## Every snap-zone grab driver used to be created at ONE process_physics_priority,
## so which of them ran first each physics frame was decided by nothing but the
## order they were added to the tree. That is fine for a single socket and wrong
## the moment sockets are stacked: a driver that runs BEFORE the one holding its
## own host reads its host's pose one frame late, and the error is cumulative.
##
## Measured on the Tower of Power (Mega-CD, Mega Drive, 32X, cartridge), built
## the way a player builds it -- cartridge into the 32X, loaded 32X into the
## console, console onto the base -- the 32X trailed by 25 mm and the cartridge
## by 51 mm, exactly double, one frame per hop. Built root-first the same stack
## measured zero, which is why this only ever showed up on some assemblies.
##
## `_holder_epoch` is bumped rather than recomputing eagerly: the graph changes
## only when something is snapped or released, and a driver can then refresh its
## own priority the next time it runs.
static var _holder_of: Dictionary = {}
static var _holder_epoch: int = 0


## The zone currently holding `obj`, or null.
static func holder_of(obj: Node3D) -> XRToolsSnapZone:
	var z: XRToolsSnapZone = _holder_of.get(obj)
	return z if is_instance_valid(z) else null


## Bumped whenever the holder graph changes; a driver compares it to decide
## whether its cached priority is still right.
static func holder_epoch() -> int:
	return _holder_epoch


## How many sockets stand between this zone and something nothing else is
## holding. Zero for a socket on a machine sitting on the floor, one for a
## socket on a machine that is itself snapped into another, and so on.
##
## Walks the chain by asking, for the body this zone belongs to, which zone is
## holding THAT -- the tree cannot answer it, because a snapped object is never
## reparented under the zone holding it; it stays where it was and is driven.
static func stack_depth(zone: XRToolsSnapZone) -> int:
	var depth := 0
	var z := zone
	# Bounded so a cycle -- which should be impossible, but would otherwise hang
	# the physics frame -- costs a wrong priority rather than the room.
	while depth < 8:
		var body := _owning_body(z)
		if body == null:
			break
		var up := holder_of(body)
		if up == null:
			break
		depth += 1
		z = up
	return depth


## The machine a zone is mounted on: its nearest PhysicsBody3D ancestor.
static func _owning_body(zone: Node3D) -> Node3D:
	var n := zone.get_parent()
	while n != null:
		if n is PhysicsBody3D:
			return n as Node3D
		n = n.get_parent()
	return null


static func _note_held(obj: Node3D, zone: XRToolsSnapZone) -> void:
	if obj == null:
		return
	if zone == null:
		_holder_of.erase(obj)
	else:
		_holder_of[obj] = zone
	_holder_epoch += 1


## LOCAL PATCH (RetroXR): the zone the preview ghost last lit, so releasing an
## object puts it where the player was shown it would go. Distance alone cannot be
## trusted to agree: the ghost is ranked from the HAND's desired position while the
## drop is ranked from where the object actually IS when it lands, and a plug
## released among sockets 18 mm apart moves far enough between those two moments to
## change the winner.
static var _preview_zone: XRToolsSnapZone = null


# Add support for is_xr_class on XRTools classes
func is_xr_class(xr_name:  String) -> bool:
	return xr_name == "XRToolsSnapZone"


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		_live_zones.append(self)


func _exit_tree() -> void:
	_live_zones.erase(self)
	# LOCAL PATCH (RetroXR): release whatever we are holding on the way out.
	# A zone goes away with the object it belongs to — a machine deleted with a
	# controller plugged into it takes its ports with it — but the plug lives at
	# the scene root and survives, still recording this zone as its grabber. The
	# next drop() on that plug then calls drop_object() on a freed instance.
	# XRToolsPickable._exit_tree already does the mirror of this.
	if is_instance_valid(picked_up_object):
		drop_object()


## LOCAL PATCH (RetroXR): every zone currently in the tree. A dropped object that
## seated nowhere uses this to say which sockets were in reach and why each one
## declined it, because a zone that refuses an object otherwise does nothing at
## all and the silence is indistinguishable from a socket being full, switched
## off, or simply not quite reached.
static func live_zones() -> Array[XRToolsSnapZone]:
	return _live_zones


## LOCAL PATCH (RetroXR): whether this zone would accept `obj` if dropped here
## right now (used by the held-object snap preview). Only zones with an explicit
## snap_require participate — generic catch-all zones don't preview.
func can_preview(obj: Node3D) -> bool:
	if not enabled or is_instance_valid(picked_up_object):
		return false
	if snap_require.is_empty() or not obj.is_in_group(snap_require):
		return false
	if not snap_exclude.is_empty() and obj.is_in_group(snap_exclude):
		return false
	if snap_filter.is_valid() and not snap_filter.call(obj):
		return false
	return true


## LOCAL PATCH (RetroXR): the pose `obj` would occupy if snapped here — this
## zone offset by the object's snap grab point, the same correction
## pickable.pick_up -> create_snap applies and grab_driver's preview ghost draws.
## Zones are compared by this pose, not by their own origin: a plug's grab point
## carries a 180-degree flip and an offset, so zone origins alone rank wrongly.
func snap_pose_for(obj: Node3D) -> Transform3D:
	var t := global_transform
	# LOCAL PATCH (RetroXR): typed, not has_method + a dynamic call - this runs
	# for every zone within reach on every physics tick a hand holds something.
	var pickable := obj as XRToolsPickable
	if pickable != null and is_instance_valid(pickable):
		var gp: XRToolsGrabPoint = pickable._get_grab_point(self, null)
		if gp:
			t = t * gp.transform.affine_inverse()
	elif is_instance_valid(obj) and obj.has_method("_get_grab_point"):
		var gp: XRToolsGrabPoint = obj._get_grab_point(self, null)
		if gp:
			t = t * gp.transform.affine_inverse()
	return t


## LOCAL PATCH (RetroXR): how far a snapped pose can sit from its zone's origin
## - a grab point's own offset, a few centimetres on a plug, a hand's width on
## a cartridge. find_preview_zone rejects a zone by its origin at this slack
## before asking anything of it, so a room's forty zones cost forty distance
## checks per tick and not forty group tests and grab-point calls.
const PREVIEW_ORIGIN_SLACK := 0.3


## LOCAL PATCH (RetroXR): where a held object is SHOWN before release, as an
## offset from the seated pose in this zone's own local metres. Zero for every
## zone but a bay whose media is presented before it goes in — the NES cart sits
## proud of the mouth and slides the last centimetre on release, and a controller
## plug stands off its socket. Local to the zone on purpose: the NES bay's zone
## rides a cradle that hinges, so the offset follows the tray's angle without
## anything here knowing the tray can move.
var preview_offset: Vector3 = Vector3.ZERO


## LOCAL PATCH (RetroXR): the orientation the ghost draws in, relative to this
## zone. Identity for every zone that seats its object as-authored.
##
## A bay driven by MediaSlot or MediaTray does NOT seat its media by the grab
## point the way an ordinary snap zone does -- it reparents the media and writes
## a slot-local pose built from `media_local_basis`. The ghost knew nothing about
## that basis, so a 64DD disk was offered standing on end and then lay flat the
## instant it was let go: the preview and the seat disagreed about rotation while
## agreeing about position, which is exactly what it looked like.
##
## Kept out of `snap_pose_for` for the same reason `preview_offset` is: that one
## also RANKS which of several sockets wins a release, and turning the ranking
## pose would change which socket catches an object dropped between two.
var preview_basis: Basis = Basis.IDENTITY


## LOCAL PATCH (RetroXR): the pose the ghost draws — `snap_pose_for` offset by
## `preview_offset`. Kept apart from snap_pose_for because that one also RANKS
## which of several sockets wins a release; moving the ranking pose would change
## which socket catches a plug dropped between two.
## [param amount] scales the stand-off, so a caller can ease between the seat (0)
## and the offer (1) rather than jumping the object the whole way.
func preview_pose_for(obj: Node3D, amount: float = 1.0) -> Transform3D:
	var t := snap_pose_for(obj)
	# In the ZONE's frame, not the object's: the seat is written as a slot-local
	# pose, so the ghost has to be turned the same way about the same origin.
	if preview_basis != Basis.IDENTITY:
		t.basis = t.basis * preview_basis
	if preview_offset != Vector3.ZERO and amount > 0.0:
		t.origin += global_transform.basis * (preview_offset * amount)
	return t


## LOCAL PATCH (RetroXR): nearest zone that could capture `obj` if released at
## `at` (the HAND's desired object position — not the object's actual one,
## which sits at the zone while previewing). `radius` is the object's bounding
## radius so the preview engages when the object's SURFACE reaches the grab
## sphere — i.e. at the same range the old blue ghost lit (which triggered on
## the Area3D body overlap, not the object centre). Null when none in range.
static func find_preview_zone(obj: Node3D, at: Vector3, radius: float = 0.0) -> XRToolsSnapZone:
	var best: XRToolsSnapZone = null
	var best_d := INF
	for z: XRToolsSnapZone in _live_zones:
		if not is_instance_valid(z):
			continue
		var reach: float = z.grab_distance + radius + PREVIEW_ORIGIN_SLACK
		if z.global_position.distance_squared_to(at) > reach * reach:
			continue
		if not z.can_preview(obj):
			continue
		# Ranked by the pose the object would OCCUPY, the same measure
		# _on_target_dropped uses. Ranking by zone origin here and by snapped pose
		# there let the two disagree, which is the ghost lighting on one socket
		# and the plug landing in its neighbour.
		var d := z.snap_pose_for(obj).origin.distance_to(at)
		if d < z.grab_distance + radius and d < best_d:
			best_d = d
			best = z
	# Remembered so the release can honour it — see _on_target_dropped.
	_preview_zone = best
	return best


func _ready():
	# Set collision shape radius
	if has_node("CollisionShape3D") and "radius" in $CollisionShape3D.shape:
		$CollisionShape3D.shape.radius = grab_distance

	# Add important connections
	if not body_entered.is_connected(_on_snap_zone_body_entered):
		body_entered.connect(_on_snap_zone_body_entered)
	if not body_exited.is_connected(_on_snap_zone_body_exited):
		body_exited.connect(_on_snap_zone_body_exited)

	# Perform updates
	_update_snap_mode()

	# Perform the initial object check when next idle
	if not Engine.is_editor_hint():
		_initial_object_check.call_deferred()


# Called on each frame to update the pickup
func _process(_delta):
	# Skip if in editor or not enabled
	if Engine.is_editor_hint() or not enabled:
		return

	# Skip if we aren't doing range-checking
	if snap_mode != SnapMode.RANGE:
		return

	# Skip if already holding a valid object
	if is_instance_valid(picked_up_object):
		return

	# Check for any object in range that can be grabbed
	for o in _object_in_grab_area:
		# skip objects that can not be picked up
		if not o.can_pick_up(self):
			continue

		# pick up our target
		pick_up_object(o)
		return


# Pickable Method: snap-zone can be grabbed if holding object
func can_pick_up(by: Node3D) -> bool:
	# Refuse if not enabled
	if not enabled:
		return false

	# Refuse if no object is held
	if not is_instance_valid(picked_up_object):
		return false

	# Refuse if the grab-by is not in the required group
	if not grab_require.is_empty() and not by.is_in_group(grab_require):
		return false

	# Refuse if the grab-by is in the excluded group
	if not grab_exclude.is_empty() and by.is_in_group(grab_exclude):
		return false

	# Grab is permitted
	return true


# Pickable Method: Snap points can't be picked up
func is_picked_up() -> bool:
	return false


# Pickable Method: Gripper-actions can't occur on snap zones
func action():
	pass


# Ignore highlighting requests from XRToolsFunctionPickup
func request_highlight(from : Node, on : bool = true) -> void:
	if is_instance_valid(picked_up_object):
		picked_up_object.request_highlight(from, on)


# Pickable Method: Object being grabbed from this snap zone
func pick_up(_by: Node3D) -> void:
	pass


# Pickable Method: Player never graps snap-zone
func let_go(_by: Node3D, _p_linear_velocity: Vector3, _p_angular_velocity: Vector3) -> void:
	pass


# Pickup Method: Drop the currently picked up object
func drop_object() -> void:
	if not is_instance_valid(picked_up_object):
		return

	# let go of this object
	_note_held(picked_up_object, null)
	picked_up_object.let_go(self, Vector3.ZERO, Vector3.ZERO)
	picked_up_object = null
	# LOCAL PATCH (RetroXR): see pick_up_object. Bodies still inside re-enter
	# on the next physics step.
	monitoring = true
	has_dropped.emit()
	highlight_updated.emit(self, enabled)
	# LOCAL PATCH (RetroXR): the ghost may come back now that the zone is free
	_update_close_highlight()


# Check for an initial object pickup
func _initial_object_check() -> void:
	# Check for an initial object
	if initial_object:
		# Force pick-up the initial object
		pick_up_object(get_node(initial_object))
	else:
		# Show highlight when empty and enabled
		highlight_updated.emit(self, enabled)

	# Stop any audio from initial pickup
	var audio := get_node("AudioStreamPlayer3D") if has_node("AudioStreamPlayer3D") else null

	# Only stop if the user doesn't intend to auto-play
	if audio is AudioStreamPlayer3D and !audio.autoplay:
		audio.stop()


# Called when a body enters the snap zone
func _on_snap_zone_body_entered(target: Node3D) -> void:
	# Ignore objects already known about
	if _object_in_grab_area.find(target) >= 0:
		return

	# Reject objects which don't support picking up
	if not target.has_method('pick_up'):
		return

	# Reject objects not in the required snap group
	if not snap_require.is_empty() and not target.is_in_group(snap_require):
		return

	# Reject objects in the excluded snap group
	if not snap_exclude.is_empty() and target.is_in_group(snap_exclude):
		return

	# LOCAL PATCH (RetroXR): owner-supplied acceptance test (media matching)
	if snap_filter.is_valid() and not snap_filter.call(target):
		return

	# Reject climbable objects
	if target is XRToolsClimbable:
		return

	# Add to the list of objects in grab area
	_object_in_grab_area.push_back(target)

	# If this snap zone is configured to snap objects that are dropped, then
	# start listening for the objects dropped signal
	if snap_mode == SnapMode.DROPPED and target.has_signal("dropped"):
		target.connect("dropped", _on_target_dropped, CONNECT_DEFERRED)

	# LOCAL PATCH (RetroXR): re-evaluate the highlight when this object's
	# held-state changes — an object snapped into a NEIGHBORING zone stays
	# inside our grab sphere forever (no body_exited), which used to leave
	# the ghost lit permanently.
	if target.has_signal("picked_up") and not target.is_connected("picked_up", _on_area_object_state_changed):
		target.connect("picked_up", _on_area_object_state_changed, CONNECT_DEFERRED)
	if target.has_signal("dropped") and not target.is_connected("dropped", _on_area_object_state_changed):
		target.connect("dropped", _on_area_object_state_changed, CONNECT_DEFERRED)

	# Show highlight when something could be snapped
	_update_close_highlight()


# Called when a body leaves the snap zone
func _on_snap_zone_body_exited(target: Node3D) -> void:
	forget_object(target)


## Forget an overlap immediately when external state teleports an object away.
## Physics will normally call this through body_exited, but network restores
## must close neighbouring sockets, release, and move a plug in one operation;
## retaining the old overlap until the next tick lets a deferred dropped signal
## re-seat it in an adjacent zone first.
func forget_object(target: Node3D) -> void:
	_object_in_grab_area.erase(target)
	if target.has_signal("dropped") and target.is_connected("dropped", _on_target_dropped):
		target.disconnect("dropped", _on_target_dropped)
	if target.has_signal("picked_up") and target.is_connected("picked_up", _on_area_object_state_changed):
		target.disconnect("picked_up", _on_area_object_state_changed)
	if target.has_signal("dropped") and target.is_connected("dropped", _on_area_object_state_changed):
		target.disconnect("dropped", _on_area_object_state_changed)
	_update_close_highlight()


# LOCAL PATCH (RetroXR): true when the object could still be snapped here —
# objects currently snapped INTO a snap zone (this one or a neighbor) don't
# count. Hand-held and free-lying objects do.
func _is_candidate_available(o: Node3D) -> bool:
	if not o.has_method("is_picked_up") or not o.is_picked_up():
		return true
	var driver: Variant = o.get("_grab_driver")
	if driver and driver.primary and driver.primary.by is XRToolsSnapZone:
		return false
	return true


# LOCAL PATCH (RetroXR): recompute and emit the close-highlight state.
func _update_close_highlight() -> void:
	if not enabled or is_instance_valid(picked_up_object):
		close_highlight_updated.emit(self, false)
		return
	for o in _object_in_grab_area:
		if is_instance_valid(o) and _is_candidate_available(o):
			close_highlight_updated.emit(self, true)
			return
	close_highlight_updated.emit(self, false)


# LOCAL PATCH (RetroXR): an object in our grab area was picked up or dropped
# somewhere (by a hand, another zone, or us) — refresh the ghost.
func _on_area_object_state_changed(_target: Node3D) -> void:
	_update_close_highlight()


# Test if this snap zone has a picked up object
func has_snapped_object() -> bool:
	return is_instance_valid(picked_up_object)


# Pick up the specified object
func pick_up_object(target: Node3D) -> void:
	# check if already holding an object
	if is_instance_valid(picked_up_object):
		# skip if holding the target object
		if picked_up_object == target:
			return
		# holding something else? drop it
		drop_object()

	# skip if target null or freed
	if not is_instance_valid(target):
		return

	# Pick up our target. Note, target may do instant drop_and_free
	picked_up_object = target
	# LOCAL PATCH (RetroXR): remember who holds what, so a driver can work out
	# how deep it sits and run after the one above it. See stack_depth.
	_note_held(target, self)
	if has_node("AudioStreamPlayer3D"):
		var player = get_node("AudioStreamPlayer3D")
		if is_instance_valid(player):
			if player.playing:
				player.stop()
			player.stream = stash_sound
			player.play()

	target.pick_up(self)

	# If object picked up then emit signal
	if is_instance_valid(picked_up_object):
		has_picked_up.emit(picked_up_object)
		highlight_updated.emit(self, false)
		# LOCAL PATCH (RetroXR): a full zone ignores every enter and drop until
		# it lets go, so its Area3D need not monitor for the hold - a room's
		# thirty-odd sockets and bays were a measurable slice of the physics
		# step in overlap bookkeeping alone. The overlap list is flushed here
		# and rebuilt by the entered callbacks when monitoring returns in
		# drop_object.
		for o in _object_in_grab_area.duplicate():
			forget_object(o)
		monitoring = false


# Called when the enabled property has been modified
func _set_enabled(p_enabled: bool) -> void:
	enabled = p_enabled
	if is_inside_tree:
		highlight_updated.emit(
			self,
			enabled and not is_instance_valid(picked_up_object))
	# LOCAL PATCH (RetroXR): the close ghost follows the enabled state too
	_update_close_highlight()


# Called when the grab distance has been modified
func _set_grab_distance(new_value: float) -> void:
	grab_distance = new_value
	if is_inside_tree() and $CollisionShape3D:
		$CollisionShape3D.shape.radius = grab_distance


# Called when the snap mode property has been modified
func _set_snap_mode(new_value: SnapMode) -> void:
	snap_mode = new_value
	if is_inside_tree():
		_update_snap_mode()


# Handle changes to the snap mode
func _update_snap_mode() -> void:
	match snap_mode:
		SnapMode.DROPPED:
			# Disable _process as we aren't using RANGE pickups
			set_process(false)

			# Start monitoring all objects in range for drop
			for o in _object_in_grab_area:
				o.connect("dropped", _on_target_dropped, CONNECT_DEFERRED)

		SnapMode.RANGE:
			# Enable _process to scan for RANGE pickups
			set_process(true)

			# Clear any dropped signal hooks
			for o in _object_in_grab_area:
				o.disconnect("dropped", _on_target_dropped)


# Called when a target in our grab area is dropped
func _on_target_dropped(target: Node3D) -> void:
	# Skip if not enabled
	if not enabled:
		return

	# Skip if already holding a valid object
	if is_instance_valid(picked_up_object):
		return

	# Skip if the target is not valid
	if not is_instance_valid(target):
		return

	# LOCAL PATCH (RetroXR): zones close enough to overlap — the NES's two
	# controller ports sit 18 mm apart inside 30 mm grab spheres, and its A/V
	# sockets the same — hold the object in several grab areas at once, and this
	# handler fires on every one of them. Without a tiebreak the winner is whichever
	# area the object entered FIRST, decided by approach direction rather than aim.
	#
	# The preview ghost decides, and decides ALONE. It is what the player was shown,
	# so it is the only answer that cannot surprise them. Every other zone stands
	# down; the ghost skips the distance test entirely.
	#
	# It has to be the sole decider, not merely preferred: an earlier version had
	# the others yield to the ghost while the ghost still ran the distance test
	# below, so whenever the ghost was not ALSO the nearest by snapped pose it
	# yielded to a zone that had already yielded to it, and the object fell through
	# every zone onto the floor. That is the "sometimes it just drops" case.
	#
	# Membership of `_object_in_grab_area` carries every acceptance test in
	# _on_snap_zone_body_entered, and is set in the same breath as the `dropped`
	# connection, so a zone that has it will really receive this callback.
	var ghost: XRToolsSnapZone = _preview_zone
	var ghost_can_take: bool = is_instance_valid(ghost) and ghost.enabled 		and not is_instance_valid(ghost.picked_up_object) 		and ghost._object_in_grab_area.has(target)
	if ghost_can_take:
		if ghost != self:
			return
	else:
		# Nothing previewed — an object let go without a ghost ever lighting. Fall
		# back to the nearest snapped pose. Strict, so the nearest never yields and
		# a tie falls back to entry order.
		var mine := snap_pose_for(target).origin.distance_squared_to(target.global_position)
		for z: XRToolsSnapZone in _live_zones:
			if z == self or not is_instance_valid(z):
				continue
			if not z.enabled or is_instance_valid(z.picked_up_object):
				continue
			if not z._object_in_grab_area.has(target):
				continue
			if z.snap_pose_for(target).origin.distance_squared_to(target.global_position) < mine:
				return

	# Pick up the target if we can
	if target.can_pick_up(self):
		pick_up_object(target)

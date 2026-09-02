@tool
@icon("res://addons/godot-xr-tools/editor/icons/function.svg")
class_name XRToolsFunctionPickup
extends XRToolsHandPalmOffset


## XR Tools Function Pickup Script
##
## This script implements picking up of objects. Most pickable
## objects are instances of the [XRToolsPickable] class.
##
## Additionally this script can work in conjunction with the
## [XRToolsMovementProvider] class support climbing. Most climbable objects are
## instances of the [XRToolsClimbable] class.


## Signal emitted when the pickup picks something up
signal has_picked_up(what)

## Signal emitted when the pickup drops something
signal has_dropped

## Signal emitted when a held object moves between the hand and the ray without
## ever being let go. Neither has_dropped nor has_picked_up fires for a transfer:
## the hand stays occupied throughout, so listeners that fade controller art or
## track held state must not see a drop/pickup pair. [param to_ray] is true when
## the object left the hand for the beam, false when it was caught back.
signal has_transferred(what, to_ray)


# Default pickup collision mask of 3:pickable and 19:handle
const DEFAULT_GRAB_MASK := 0b0000_0000_0000_0100_0000_0000_0000_0100

# Default pickup collision mask of 3:pickable
const DEFAULT_RANGE_MASK := 0b0000_0000_0000_0000_0000_0000_0000_0100

# Constant for worst-case grab distance
const MAX_GRAB_DISTANCE2: float = 1000000.0

# Class for storing copied collision data
class CopiedCollision extends RefCounted:
	var collision_shape : CollisionShape3D
	var org_transform : Transform3D

## Pickup enabled property
@export var enabled : bool = true

## Grip controller axis
@export var pickup_axis_action : String = "grip"

## Action controller button
@export var action_button_action : String = "trigger_click"

## Grab distance
@export var grab_distance : float = 0.125: set = _set_grab_distance

## Grab collision mask
@export_flags_3d_physics \
		var grab_collision_mask : int = DEFAULT_GRAB_MASK: set = _set_grab_collision_mask

## If true, ranged-grabbing is enabled
@export var ranged_enable : bool = true

## Ranged-grab distance
@export var ranged_distance : float = 5.0: set = _set_ranged_distance

## Ranged-grab angle
@export_range(0.0, 45.0) var ranged_angle : float = 5.0: set = _set_ranged_angle

## Ranged-grab collision mask
@export_flags_3d_physics \
		var ranged_collision_mask : int = DEFAULT_RANGE_MASK: set = _set_ranged_collision_mask

## Throw impulse factor
@export var impulse_factor : float = 1.0

## Throw velocity averaging
@export var velocity_samples: int = 5


# Public fields
var closest_object : Node3D = null
var picked_up_object : Node3D = null
var picked_up_ranged : bool = false
var grip_pressed : bool = false

# Private fields
var _object_in_grab_area := Array()
var _object_in_ranged_area := Array()
var _velocity_averager := XRToolsVelocityAverager.new(velocity_samples)
var _grab_area : Area3D
var _grab_collision : CollisionShape3D
var _ranged_area : Area3D
var _ranged_collision : CollisionShape3D
var _active_copied_collisions : Array[CopiedCollision]

# Ray-pointer grab constants
const RAY_GRAB_DISTANCE_MIN := 0.3
const RAY_GRAB_DISTANCE_MAX := 10.0
const RAY_GRAB_SPEED := 3.0  # metres per second at full stick deflection
const RAY_GRAB_ROTATE_SPEED := 2.5  # radians per second at full stick deflection

# Hand <-> ray handoff constants
#
# The reel already stops at RAY_GRAB_DISTANCE_MIN, so that stop doubles as the
# gate: an object parked there is at arm's length and goes no further on its own.
# Catching it costs a deliberate hold, which is what keeps a casual reel from
# dumping the object into your hand.
const HANDOFF_TRIGGER_THRESHOLD := 0.6  # trigger held this hard arms the push-out
const HANDOFF_PUSH_STICK := 0.7         # ...then the stick past this launches
const HANDOFF_PUSH_REARM := 0.4         # stick must fall below this to launch again
const HANDOFF_BLEND_TIME := 0.15        # seconds to ease onto/off the ray axis
const CATCH_HOLD_TIME := 1.0            # seconds of pull-back needed to catch
const CATCH_STICK := 0.85               # pull must reach the stick's edge to charge
const CATCH_RELEASE := 0.70             # ...and fall below this to reset
const CATCH_CHARGE_HZ := 20.0           # rumble magnitude update rate while charging
const CATCH_CHARGE_MAG_MIN := 0.10
const CATCH_CHARGE_MAG_MAX := 0.55

# Slack left when a tethered object (a cable plug) is held at full stretch, so
# the host's own position clamp never has to fire and fight this one.
const TETHER_MARGIN := 0.02

# Socket preview while ray-holding. Matches XRToolsGrabDriver's hand-held
# preview so a plug flown in on the beam behaves like one carried by hand.
const RAY_PREVIEW_BLEND_SPEED := 8.0   # blend/sec (~0.12 s each way)
const RAY_PREVIEW_HYSTERESIS := 1.25   # hold an engaged zone this far past range

# Ray-pointer grab state
var _ray_pointer : XRToolsFunctionPointer = null   # sibling FunctionPointer
var _pointer_highlighted : XRToolsPickable = null  # object highlighted by the laser
var _ray_grab_object : XRToolsPickable = null      # object currently held via the ray
var _ray_grab_distance : float = 0.0              # hold distance along the ray
var _ray_grab_other_controller : XRController3D = null
var _locomotion_manager: LocomotionManager = null
var _ray_grab_block_owner: StringName = &"ray_grab"
# Accumulated rotation tracked independently of the physics body — prevents
# _direct_state_changed from corrupting our rotation between physics ticks.
var _ray_grab_basis : Basis = Basis.IDENTITY
# LOCAL PATCH (RetroXR): scale of the ray-held object, carried alongside the
# rotation tracker above rather than inside it. _compute_ray_grab_rotation
# orthonormalizes, which is right for an accumulator that must not drift — and
# which silently threw a resized object's scale away the first time it was spun,
# snapping a 2.5x television back to 1x mid-hold.
var _ray_grab_scale : Vector3 = Vector3.ONE

# Hand <-> ray handoff state
var _reel_charge : float = 0.0             # seconds of pull-back accumulated at the gate
var _reel_gated : bool = false             # was the object parked at the gate last frame
var _reel_charge_tick : float = 0.0        # throttles the charge rumble update
var _push_armed : bool = true              # stick returned to neutral since the last launch
var _handoff_blend : float = 0.0           # counts down while easing onto the ray axis
var _handoff_blend_from : Transform3D = Transform3D.IDENTITY
var _handoff_block_owner : StringName = &"ray_handoff"
var _handoff_loco_blocked : bool = false
var _pointer_muted : bool = false          # we disabled the sibling pointer's button dispatch

# Socket preview while ray-holding
var _ray_preview_zone : XRToolsSnapZone = null
var _ray_preview_blend : float = 0.0
var _ray_preview_radius : float = -1.0     # bounding radius of the held object
var _ray_previewing : bool = false         # last state pushed to the outline

## Collision hand (if applicable)
@onready var _collision_hand : XRToolsCollisionHand

## Grip threshold (from configuration)
@onready var _grip_threshold : float = XRTools.get_grip_threshold()


# Add support for is_xr_class on XRTools classes
func is_xr_class(xr_name:  String) -> bool:
	return xr_name == "XRToolsFunctionPickup"


# Called when the node enters the scene tree for the first time.
func _ready():
	# Skip creating grab-helpers if in the editor
	if Engine.is_editor_hint():
		return

	# Create the grab collision shape
	_grab_collision = CollisionShape3D.new()
	_grab_collision.set_name("GrabCollisionShape")
	_grab_collision.shape = SphereShape3D.new()
	_grab_collision.shape.radius = grab_distance

	# Create the grab area
	_grab_area = Area3D.new()
	_grab_area.set_name("GrabArea")
	_grab_area.collision_layer = 0
	_grab_area.collision_mask = grab_collision_mask
	_grab_area.add_child(_grab_collision)
	_grab_area.area_entered.connect(_on_grab_entered)
	_grab_area.body_entered.connect(_on_grab_entered)
	_grab_area.area_exited.connect(_on_grab_exited)
	_grab_area.body_exited.connect(_on_grab_exited)
	add_child(_grab_area)

	# Create the ranged collision shape
	_ranged_collision = CollisionShape3D.new()
	_ranged_collision.set_name("RangedCollisionShape")
	_ranged_collision.shape = CylinderShape3D.new()
	_ranged_collision.transform.basis = Basis(Vector3.RIGHT, PI/2)

	# Create the ranged area
	_ranged_area = Area3D.new()
	_ranged_area.set_name("RangedArea")
	_ranged_area.collision_layer = 0
	_ranged_area.collision_mask = ranged_collision_mask
	_ranged_area.add_child(_ranged_collision)
	_ranged_area.area_entered.connect(_on_ranged_entered)
	_ranged_area.body_entered.connect(_on_ranged_entered)
	_ranged_area.area_exited.connect(_on_ranged_exited)
	_ranged_area.body_exited.connect(_on_ranged_exited)
	add_child(_ranged_area)

	# Update the colliders
	_update_colliders()

	# Find the sibling FunctionPointer (deferred so all scene nodes are ready)
	call_deferred("_find_ray_pointer")


# Called when we're added to the tree
func _enter_tree():
	super._enter_tree()
	add_to_group(PICKUP_GROUP)

	_collision_hand = XRToolsCollisionHand.find_ancestor(self)

	# Monitor Grab Button
	if _controller:
		_controller.button_pressed.connect(_on_button_pressed)
		_controller.button_released.connect(_on_button_released)

# Called when we exit the tree
func _exit_tree():
	if _controller:
		_controller.button_pressed.disconnect(_on_button_pressed)
		_controller.button_released.disconnect(_on_button_released)

	_reset_charge()
	_clear_socket_preview()

	if _locomotion_manager:
		_locomotion_manager.set_block(_ray_grab_block_owner, LocomotionManager.CHANNEL_ALL, false)
		_set_handoff_loco_block(false)

	if _collision_hand:
		_remove_copied_collisions()
		_collision_hand = null

	super._exit_tree()


# Drive the ray-grabbed body from _physics_process so the transform is written
# AFTER _direct_state_changed (which runs earlier in the same physics tick) and
# is never overwritten by the physics engine before the render.
func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if is_instance_valid(_ray_grab_object):
		_process_ray_grab(delta)


# Called on each frame to update the pickup
func _process(delta):
	super._process(delta)

	# Do not process if in the editor
	if Engine.is_editor_hint():
		return

	# Skip if disabled, or the controller isn't active
	if !enabled or !_controller.get_is_active():
		return

	# Handle our grip
	var grip_value = _controller.get_float(pickup_axis_action)
	if (grip_pressed and grip_value < (_grip_threshold - 0.1)):
		grip_pressed = false
		_on_grip_release()
	elif (!grip_pressed and grip_value > (_grip_threshold + 0.1)):
		grip_pressed = true
		_on_grip_pressed()

	# Calculate average velocity (also tracks ray-grabbed objects for throw)
	if is_instance_valid(picked_up_object) and picked_up_object.is_picked_up():
		_velocity_averager.add_transform(delta, picked_up_object.global_transform)
	elif is_instance_valid(_ray_grab_object):
		_velocity_averager.add_transform(delta, _ray_grab_object.global_transform)
	else:
		_velocity_averager.add_transform(delta, global_transform)

	_update_copied_collisions()

	# Ray-grab position/rotation is handled in _physics_process, which runs
	# after _direct_state_changed — so the physics body is never overwritten by
	# the physics tick between our write and the render.
	if is_instance_valid(_ray_grab_object):
		return

	# Trigger + stick forward pushes a held object out onto the ray.
	if is_instance_valid(picked_up_object):
		_process_push_to_ray()
		# The push may have just handed the object to the ray.
		if is_instance_valid(_ray_grab_object):
			return
	else:
		_set_pointer_muted(false)
		_set_handoff_loco_block(false)

	# Always update closest proximity object first — it takes priority over the laser.
	_update_closest_object()
	# Only show pointer highlight when nothing is close enough to grab by hand.
	if not is_instance_valid(closest_object):
		_process_pointer_highlight()
	else:
		_set_pointer_highlight(null)


## Find an [XRToolsFunctionPickup] node.
##
## This function searches from the specified node for an [XRToolsFunctionPickup]
## assuming the node is a sibling of the pickup under an [XRController3D].
static func find_instance(node : Node) -> XRToolsFunctionPickup:
	return XRTools.find_xr_child(
		XRHelpers.get_xr_controller(node),
		"*",
		"XRToolsFunctionPickup") as XRToolsFunctionPickup


## Find the left [XRToolsFunctionPickup] node.
##
## This function searches from the specified node for the left controller
## [XRToolsFunctionPickup] assuming the node is a sibling of the [XOrigin3D].
static func find_left(node : Node) -> XRToolsFunctionPickup:
	return XRTools.find_xr_child(
		XRHelpers.get_left_controller(node),
		"*",
		"XRToolsFunctionPickup") as XRToolsFunctionPickup


## Find the right [XRToolsFunctionPickup] node.
##
## This function searches from the specified node for the right controller
## [XRToolsFunctionPickup] assuming the node is a sibling of the [XROrigin3D].
static func find_right(node : Node) -> XRToolsFunctionPickup:
	return XRTools.find_xr_child(
		XRHelpers.get_right_controller(node),
		"*",
		"XRToolsFunctionPickup") as XRToolsFunctionPickup


## Get the [XRController3D] driving this pickup.
func get_controller() -> XRController3D:
	return _controller


# Called when the grab distance has been modified
func _set_grab_distance(new_value: float) -> void:
	grab_distance = new_value
	if is_inside_tree():
		_update_colliders()


# Called when the grab collision mask has been modified
func _set_grab_collision_mask(new_value: int) -> void:
	grab_collision_mask = new_value
	if is_inside_tree() and _grab_area:
		_grab_area.collision_mask = new_value


# Called when the ranged-grab distance has been modified
func _set_ranged_distance(new_value: float) -> void:
	ranged_distance = new_value
	if is_inside_tree():
		_update_colliders()


# Called when the ranged-grab angle has been modified
func _set_ranged_angle(new_value: float) -> void:
	ranged_angle = new_value
	if is_inside_tree():
		_update_colliders()


# Called when the ranged-grab collision mask has been modified
func _set_ranged_collision_mask(new_value: int) -> void:
	ranged_collision_mask = new_value
	if is_inside_tree() and _ranged_area:
		_ranged_area.collision_mask = new_value


# Update the colliders geometry
func _update_colliders() -> void:
	# Update the grab sphere
	if _grab_collision:
		_grab_collision.shape.radius = grab_distance

	# Update the ranged-grab cylinder
	if _ranged_collision:
		_ranged_collision.shape.radius = tan(deg_to_rad(ranged_angle)) * ranged_distance
		_ranged_collision.shape.height = ranged_distance
		_ranged_collision.transform.origin.z = -ranged_distance * 0.5


# Called when an object enters the grab sphere
func _on_grab_entered(target: Node3D) -> void:
	# reject objects which don't support picking up
	if not target.has_method('pick_up'):
		return

	# ignore objects already known
	if _object_in_grab_area.find(target) >= 0:
		return

	# Add to the list of objects in grab area
	_object_in_grab_area.push_back(target)


# Called when an object enters the ranged-grab cylinder
func _on_ranged_entered(target: Node3D) -> void:
	# reject objects which don't support picking up rangedly
	if not 'can_ranged_grab' in target or not target.can_ranged_grab:
		return

	# ignore objects already known
	if _object_in_ranged_area.find(target) >= 0:
		return

	# Add to the list of objects in grab area
	_object_in_ranged_area.push_back(target)


# Called when an object exits the grab sphere
func _on_grab_exited(target: Node3D) -> void:
	_object_in_grab_area.erase(target)


# Called when an object exits the ranged-grab cylinder
func _on_ranged_exited(target: Node3D) -> void:
	_object_in_ranged_area.erase(target)


# Update the closest object field with the best choice of grab
func _update_closest_object() -> void:
	# Find the closest object we can pickup
	var new_closest_obj: Node3D = null
	if not picked_up_object:
		# Find the closest in grab area
		new_closest_obj = _get_closest_grab()
		if not new_closest_obj and ranged_enable:
			# Find closest in ranged area
			new_closest_obj = _get_closest_ranged()

	# Skip if no change
	if closest_object == new_closest_obj:
		return

	# remove highlight on old object
	if is_instance_valid(closest_object):
		closest_object.request_highlight(self, false)

	# add highlight to new object
	closest_object = new_closest_obj
	if is_instance_valid(closest_object):
		closest_object.request_highlight(self, true)


# Find the pickable object closest to our hand's grab location
#
# LOCAL PATCH (RetroXR): snap zones only compete when the hand is INSIDE the
# zone's own grab sphere (a deliberate reach at the socket), and then they WIN
# over pickables. Plain origin-distance ranking let a zone buried inside a
# small pickable — a handheld's cartridge slot — steal grabs aimed at the
# body (the slot origin is nearer than the body's centre from behind), while
# any bias in the other direction made short bodies (DS) steal deliberate
# pinches at the protruding cart stub.
func _get_closest_grab() -> Node3D:
	var new_closest_obj: Node3D = null
	var new_closest_distance := MAX_GRAB_DISTANCE2
	var best_zone: Node3D = null
	var best_zone_distance := MAX_GRAB_DISTANCE2
	for o in _object_in_grab_area:
		# skip objects that can not be picked up
		if not o.can_pick_up(self):
			continue

		var distance_squared := global_transform.origin.distance_squared_to(
				o.global_transform.origin)
		if o is XRToolsSnapZone:
			var zone_r: float = o.grab_distance
			if distance_squared <= zone_r * zone_r \
					and distance_squared < best_zone_distance:
				best_zone = o
				best_zone_distance = distance_squared
			continue

		# Save if this object is closer than the current best
		if distance_squared < new_closest_distance:
			new_closest_obj = o
			new_closest_distance = distance_squared

	# A directly-touched socket beats nearby pickables
	if best_zone != null:
		return best_zone

	# Return best object
	return new_closest_obj


# Find the rangedly-pickable object closest to our hand's pointing direction
func _get_closest_ranged() -> Node3D:
	var new_closest_obj: Node3D = null
	var new_closest_angle_dp := cos(deg_to_rad(ranged_angle))
	var hand_forwards := -global_transform.basis.z
	for o in _object_in_ranged_area:
		# skip objects that can not be picked up
		if not o.can_pick_up(self):
			continue

		# Save if this object is closer than the current best
		var object_direction: Vector3 = o.global_transform.origin - global_transform.origin
		object_direction = object_direction.normalized()
		var angle_dp := hand_forwards.dot(object_direction)
		if angle_dp > new_closest_angle_dp:
			new_closest_obj = o
			new_closest_angle_dp = angle_dp

	# Return best object
	return new_closest_obj


## Drop the currently held object
func drop_object() -> void:
	if not is_instance_valid(picked_up_object):
		return

	# The push-out modifier can't outlive the object it applied to.
	_set_pointer_muted(false)
	_set_handoff_loco_block(false)
	_push_armed = true

	# Remove any copied collision objects
	_remove_copied_collisions()

	# let go of this object
	picked_up_object.let_go(
		self,
		_velocity_averager.linear_velocity() * impulse_factor,
		_velocity_averager.angular_velocity())
	picked_up_object = null

	if _collision_hand:
		# Reset the held weight
		_collision_hand.set_held_weight(0.0)

	emit_signal("has_dropped")


func _pick_up_object(target: Node3D) -> void:
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

	# Handle snap-zone
	var snap := target as XRToolsSnapZone
	if snap:
		target = snap.picked_up_object
		if not is_instance_valid(target):
			return
		# LOCAL PATCH (RetroXR): asked BEFORE the zone lets go, and only about what
		# does not depend on the zone holding it — can_pick_up() answers "already
		# held" while it does. A clamped cart refused after the drop would be
		# released by the socket and picked up by nobody.
		if target.has_method("is_clamped") and target.is_clamped():
			return
		snap.drop_object()

	# Re-check can_pick_up here: state may have changed since closest_object was last updated
	# (e.g. another controller grabbed the same object on the same frame).
	if target.has_method("can_pick_up") and not target.can_pick_up(self):
		return

	# Pick up our target. Note, target may do instant drop_and_free
	picked_up_ranged = not _object_in_grab_area.has(target)
	picked_up_object = target
	target.pick_up(self)

	# If object picked up then emit signal
	if is_instance_valid(picked_up_object):
		_copy_collisions()

		picked_up_object.request_highlight(self, false)
		emit_signal("has_picked_up", picked_up_object)


# Copy collision shapes on the held object to our collision hand (if applicable).
# If we're two handing an object, both collision hands will get copies.
func _copy_collisions():
	if not is_instance_valid(_collision_hand):
		return

	if not is_instance_valid(picked_up_object) or not picked_up_object is RigidBody3D:
		return

	for child in picked_up_object.get_children():
		if child is CollisionShape3D and not child.disabled:

			var copied_collision : CopiedCollision = CopiedCollision.new()
			copied_collision.collision_shape = CollisionShape3D.new()
			copied_collision.collision_shape.shape = child.shape
			copied_collision.org_transform = child.transform

			_collision_hand.add_child(copied_collision.collision_shape, false, Node.INTERNAL_MODE_BACK)
			copied_collision.collision_shape.global_transform = picked_up_object.global_transform * \
				copied_collision.org_transform

			_active_copied_collisions.push_back(copied_collision)


# Adjust positions of our collisions to match actual location of object
func _update_copied_collisions():
	if is_instance_valid(_collision_hand) and is_instance_valid(picked_up_object):
		for copied_collision : CopiedCollision in _active_copied_collisions:
			if is_instance_valid(copied_collision.collision_shape):
				copied_collision.collision_shape.global_transform = picked_up_object.global_transform * \
					copied_collision.org_transform


# Remove copied collision shapes
func _remove_copied_collisions():
	if is_instance_valid(_collision_hand):
		for copied_collision : CopiedCollision in _active_copied_collisions:
			if is_instance_valid(copied_collision.collision_shape):
				_collision_hand.remove_child(copied_collision.collision_shape)
				copied_collision.collision_shape.queue_free()

	_active_copied_collisions.clear()


func _on_button_pressed(p_button) -> void:
	if p_button == action_button_action and is_instance_valid(picked_up_object):
		if picked_up_object.has_method("action"):
			picked_up_object.action()

		if picked_up_object.has_method("controller_action"):
			picked_up_object.controller_action(_controller)


func _on_button_released(p_button) -> void:
	if p_button == action_button_action and is_instance_valid(picked_up_object):
		if picked_up_object.has_method("action_release"):
			picked_up_object.action_release()

		if picked_up_object.has_method("controller_action_release"):
			picked_up_object.controller_action_release(_controller)


func _on_grip_pressed() -> void:
	if is_instance_valid(picked_up_object) and !picked_up_object.press_to_hold:
		# LOCAL PATCH (RetroXR): let a pickable manage its own drop so a redundant grip
		# press on an already-held object is a no-op (no drop->re-grab pose pop). Objects
		# that drop only via their own gesture (e.g. RetroController's combo) return false.
		if picked_up_object.has_method("wants_grip_toggle_drop") \
				and not picked_up_object.wants_grip_toggle_drop():
			return
		drop_object()
	elif is_instance_valid(closest_object):
		# Proximity grab takes priority over the laser
		_pick_up_object(closest_object)
	elif is_instance_valid(_pointer_highlighted) and not is_instance_valid(picked_up_object):
		# Nothing close — grab along the ray
		_start_ray_grab(_pointer_highlighted)


func _on_grip_release() -> void:
	if is_instance_valid(_ray_grab_object):
		_end_ray_grab()
	elif is_instance_valid(picked_up_object) and picked_up_object.press_to_hold:
		drop_object()


# ----------  Ray-pointer grab helpers  ----------

# Locate the sibling FunctionPointer; deferred so all controller children are ready.
# Also cache locomotion nodes globally by name — identical to SpawnMenuController.
func _find_ray_pointer() -> void:
	if Engine.is_editor_hint() or not _controller:
		return
	for child in _controller.get_children():
		if child is XRToolsFunctionPointer:
			_ray_pointer = child
			break
	_locomotion_manager = get_tree().root.find_child("LocomotionManager", true, false) as LocomotionManager
	if _controller.tracker == &"left_hand":
		_ray_grab_other_controller = XRHelpers.get_right_controller(self)
		_ray_grab_block_owner = &"ray_grab_left"
		_handoff_block_owner = &"ray_handoff_left"
	else:
		_ray_grab_other_controller = XRHelpers.get_left_controller(self)
		_ray_grab_block_owner = &"ray_grab_right"
		_handoff_block_owner = &"ray_handoff_right"


# Resolve a raycast collider to the owning XRToolsPickable.
# The collider may be the pickable RigidBody itself, or a PointerArea (StaticBody3D)
# that is a direct child of the pickable (see PointerArea pattern in system.tscn).
func _resolve_pickable(collider: Node3D) -> XRToolsPickable:
	if not collider:
		return null
	var direct := collider as XRToolsPickable
	if direct:
		return direct
	return collider.get_parent() as XRToolsPickable


# Each frame: highlight whichever pickable the laser is currently pointing at.
func _process_pointer_highlight() -> void:
	var new_target: XRToolsPickable = null
	if enabled and _ray_pointer:
		var ray_cast := _ray_pointer.get_node_or_null("RayCast") as RayCast3D
		if ray_cast and ray_cast.is_colliding():
			var body := _resolve_pickable(ray_cast.get_collider())
			if body and body.can_pick_up(self) and not _is_target_ray_grabbed_elsewhere(body):
				new_target = body
	_set_pointer_highlight(new_target)


# Manage the pointer-driven highlight, clearing the old one and setting the new one.
func _set_pointer_highlight(new_target: XRToolsPickable) -> void:
	if new_target == _pointer_highlighted:
		return
	if is_instance_valid(_pointer_highlighted):
		_pointer_highlighted.request_highlight(self, false)
	_pointer_highlighted = new_target
	if is_instance_valid(_pointer_highlighted):
		_pointer_highlighted.request_highlight(self, true)


# Begin holding the target at the distance the ray currently hits it.
func _start_ray_grab(target: XRToolsPickable) -> void:
	if not is_instance_valid(target) or _is_target_ray_grabbed_elsewhere(target):
		return
	# Only one ray-grab allowed at a time — prevents the free hand from grabbing
	# a second object while the other controller is already ray-holding something.
	if _is_any_other_pickup_ray_grabbing():
		return
	# Refuse anything already held — most importantly an object seated in a snap
	# zone, which would otherwise be flown out of its socket while the zone went
	# on believing it still had it. _process_pointer_highlight applies the same
	# test before offering a target, so this only bites a direct caller.
	if not target.can_pick_up(self):
		return

	_start_ray_grab_at(target, global_transform.origin.distance_to(
			target.global_transform.origin))


# Begin holding the target at an explicit distance. Split out of _start_ray_grab
# so the handoff can seed the distance from where the object already is.
#
# [param transferred] suppresses has_picked_up: a handoff from the hand never
# let the object go, so listeners must not see a fresh pickup.
func _start_ray_grab_at(target: XRToolsPickable, distance: float,
		transferred: bool = false) -> void:
	_clear_socket_preview()   # never inherit the previous object's socket state
	_ray_grab_distance = clampf(
			distance, RAY_GRAB_DISTANCE_MIN, RAY_GRAB_DISTANCE_MAX)
	_ray_grab_object = target
	_reel_gated = false
	# Seed our independent rotation tracker. LOCAL PATCH (RetroXR): orthonormal,
	# with the scale split off into _ray_grab_scale — see that declaration.
	_ray_grab_basis = target.global_basis.orthonormalized()
	_ray_grab_scale = target.global_basis.get_scale()
	_set_pointer_highlight(null)  # object transitions from "highlighted" to "held"
	# Freeze physics and move to the held layer (mirrors XRToolsPickable.pick_up)
	target.restore_freeze = target.freeze
	target.freeze = true
	target.collision_layer = target.picked_up_layer
	target.collision_mask = 0
	if _locomotion_manager:
		_locomotion_manager.set_block(_ray_grab_block_owner, LocomotionManager.CHANNEL_ALL, true)
	if not transferred:
		emit_signal("has_picked_up", target)


# Each frame: reposition the ray-held object and adjust distance via thumbstick.
func _process_ray_grab(delta: float) -> void:
	if not is_instance_valid(_ray_grab_object):
		if _locomotion_manager:
			_locomotion_manager.set_block(_ray_grab_block_owner, LocomotionManager.CHANNEL_ALL, false)
		_ray_grab_object = null
		_reset_charge()
		return
	# Thumbstick Y — up moves away, down moves toward; 10 % dead-zone
	if _controller:
		var stick_y := _controller.get_vector2("primary").y
		if absf(stick_y) > 0.1:
			_ray_grab_distance += stick_y * RAY_GRAB_SPEED * delta
			_ray_grab_distance = clampf(
					_ray_grab_distance, RAY_GRAB_DISTANCE_MIN, RAY_GRAB_DISTANCE_MAX)
		# The clamp above parks the object at arm's length; charge the catch there.
		_process_catch_charge(delta, stick_y)
		if not is_instance_valid(_ray_grab_object):
			return  # the charge completed and handed the object to the hand
	# Compute rotation and position together, then write in ONE transform assignment.
	# Writing global_basis and global_position separately causes the physics server to
	# receive two distinct body_set_state calls with an intermediate (new_basis, old_pos)
	# state. At high frame rates this intermediate state gets rendered, producing a ghost
	# at the original rotation that grows apart as total rotation accumulates.
	var new_basis := _compute_ray_grab_rotation(delta)
	# LOCAL PATCH (RetroXR): re-read the object's scale every frame rather than
	# trusting the value cached at grab time, so a resize made WHILE it is held —
	# the TV's size slider is pointer-driven and works mid-hold — is carried
	# instead of being overwritten by a stale one. A degenerate read is ignored.
	if is_instance_valid(_ray_grab_object):
		var live_scale: Vector3 = _ray_grab_object.global_basis.get_scale()
		if live_scale.x > 0.0001 and live_scale.y > 0.0001 and live_scale.z > 0.0001:
			_ray_grab_scale = live_scale
	if _ray_pointer:
		var ray_cast := _ray_pointer.get_node_or_null("RayCast") as RayCast3D
		if ray_cast:
			var ray_dir := -ray_cast.global_transform.basis.z
			# Written back, not just applied locally: otherwise the stick would
			# keep winding the distance up behind a taut cable and the plug would
			# spring outward the instant it was unplugged.
			_ray_grab_distance = _clamp_distance_to_tether(
					ray_cast.global_transform.origin, ray_dir, _ray_grab_distance)
			var new_pos := ray_cast.global_transform.origin + ray_dir * _ray_grab_distance
			var new_transform := _apply_socket_preview(
					Transform3D(new_basis, new_pos), delta)
			new_transform = _apply_handoff_blend(new_transform, delta)
			# LOCAL PATCH (RetroXR): scale goes on LAST. Both blends above
			# interpolate toward poses authored at 1x, and lerping a scaled basis
			# against an unscaled one skews the object as it converges.
			new_transform.basis = new_transform.basis.orthonormalized() \
					.scaled_local(_ray_grab_scale)
			_ray_grab_object.global_transform = new_transform
			# Explicitly sync to the physics server — frozen bodies can silently drop the
			# node→physics update, causing _direct_state_changed to restore the stale
			# pickup-time transform on the next physics tick.
			PhysicsServer3D.body_set_state(
					_ray_grab_object.get_rid(),
					PhysicsServer3D.BODY_STATE_TRANSFORM,
					new_transform)
			return
	_ray_grab_object.global_basis = new_basis.scaled_local(_ray_grab_scale)


func _compute_ray_grab_rotation(delta: float) -> Basis:
	# Read _ray_grab_basis (our own tracker), NOT _ray_grab_object.global_basis.
	# The physics body's basis can be reset by _direct_state_changed mid-sequence;
	# using our own variable keeps the accumulated rotation stable across physics ticks.
	var basis := _ray_grab_basis

	if _ray_grab_other_controller and _ray_grab_other_controller.get_is_active():
		var stick := _ray_grab_other_controller.get_vector2("primary")
		if stick.length_squared() > 0.01:
			# Aircraft semantics (nose = far side of the object, pointing away):
			# stick right → nose yaws right, stick up → nose pitches up.
			var yaw := -stick.x * RAY_GRAB_ROTATE_SPEED * delta
			var pitch := stick.y * RAY_GRAB_ROTATE_SPEED * delta

			# Rotate from the player's viewpoint using the HOLDING controller as the
			# reference (not the headset): left/right yaws around world up (a stable
			# turntable spin); up/down pitches around the holding controller's leveled
			# right axis, so the tilt follows where the ray is pointing. Both axes stay
			# level, so wrist roll never turns the stick directions diagonal.
			var pitch_axis := _controller.global_transform.basis.x.normalized()
			var roll_axis := (-_controller.global_transform.basis.z).normalized()
			var flat_fwd := -_controller.global_transform.basis.z
			flat_fwd.y = 0.0
			if flat_fwd.length_squared() > 0.0001:
				roll_axis = flat_fwd.normalized()
				pitch_axis = roll_axis.cross(Vector3.UP).normalized()

			# Roll mode: squeeze grip on the rotating hand — stick X then rolls the
			# object around the ray axis (right = roll right, i.e. clockwise from
			# the player's view since the nose points away) instead of yawing it.
			var roll_mode := \
					_ray_grab_other_controller.get_float(pickup_axis_action) > _grip_threshold

			if roll_mode:
				var roll := stick.x * RAY_GRAB_ROTATE_SPEED * delta
				if absf(roll) > 0.001:
					basis = Basis(roll_axis, roll) * basis
			elif absf(yaw) > 0.001:
				basis = Basis(Vector3.UP, yaw) * basis

			if absf(pitch) > 0.001:
				basis = Basis(pitch_axis, pitch) * basis

			basis = basis.orthonormalized()

	_ray_grab_basis = basis
	return basis


# Release the ray-held object and restore its physics.
func _end_ray_grab() -> void:
	_reset_charge()
	_reel_gated = false
	if not is_instance_valid(_ray_grab_object):
		_clear_socket_preview()
		_ray_grab_object = null
		return

	# Released while a socket was engaged: hand it over instead of dropping it.
	# The zone's own capture path can't fire here — it waits on the object's
	# `dropped` signal, which comes from let_go(), which a ray grab never calls.
	var socket := _ray_preview_zone if _ray_previewing else null

	_ray_grab_object.freeze = _ray_grab_object.restore_freeze
	_ray_grab_object.collision_mask = _ray_grab_object.original_collision_mask
	_ray_grab_object.collision_layer = _ray_grab_object.original_collision_layer

	var released := _ray_grab_object
	_clear_socket_preview()
	_ray_grab_object = null

	if is_instance_valid(socket) and socket.can_preview(released) \
			and released.can_pick_up(socket):
		socket.pick_up_object(released)
	else:
		# Apply throw velocity so the object can be tossed
		released.linear_velocity = _velocity_averager.linear_velocity() * impulse_factor
		released.angular_velocity = _velocity_averager.angular_velocity()
		# LOCAL PATCH (RetroXR): let the object say why it landed nowhere. A ray
		# grab never emits `dropped`, so anything listening for that hears nothing
		# on this path, and a socket that declines an object is silent by design.
		# Between the two, a plug that will not go in looks exactly like a plug
		# that was never quite aimed.
		if released.has_method("report_missed_socket"):
			released.report_missed_socket()

	if _locomotion_manager:
		_locomotion_manager.set_block(_ray_grab_block_owner, LocomotionManager.CHANNEL_ALL, false)
	emit_signal("has_dropped")


## Returns true while an object is held via the ray-pointer grab.
## Used externally (e.g. spawn_menu_controller) to avoid conflicting grabs.
func is_ray_grabbing() -> bool:
	return is_instance_valid(_ray_grab_object)


func is_ray_grabbing_target(target: XRToolsPickable) -> bool:
	return is_instance_valid(target) and _ray_grab_object == target


## Every pickup function in the tree. The two checks below run every frame per
## hand whenever the laser rests on a pickable, and walking the whole room with
## find_children for them cost 11% of the main thread in an eight-machine arcade.
const PICKUP_GROUP := &"xrt_function_pickup"


func _is_any_other_pickup_ray_grabbing() -> bool:
	for pickup in get_tree().get_nodes_in_group(PICKUP_GROUP):
		if pickup == self:
			continue
		if pickup is XRToolsFunctionPickup and pickup.is_ray_grabbing():
			return true
	return false


func _is_target_ray_grabbed_elsewhere(target: XRToolsPickable) -> bool:
	if not is_instance_valid(target):
		return false

	for pickup in get_tree().get_nodes_in_group(PICKUP_GROUP):
		if pickup == self:
			continue
		if pickup is XRToolsFunctionPickup and pickup.is_ray_grabbing_target(target):
			return true

	return false


# ----------  LOCAL PATCH (RetroXR): hand <-> ray handoff  ----------
#
# Moves a held object between the hand and the end of the laser without ever
# letting go of it.
#
#   hand -> ray   hold the trigger, push the stick forward. The trigger is the
#                 modifier because the stick alone is locomotion (and, on the
#                 right hand, teleport-aim at 0.6 — below our launch threshold),
#                 so the gesture blocks that hand's locomotion while armed.
#   ray -> hand   pull the stick back. The object reels in and stops at
#                 RAY_GRAB_DISTANCE_MIN; holding the stick near its edge for
#                 CATCH_HOLD_TIME there completes the catch, with rising rumble.
#                 Easing off resets the charge.
#
# Objects that claim the trigger or the stick for themselves (emulator pads,
# handhelds, the light gun, the TV remote, the mouse, books) opt out of the
# push-out via wants_ray_handoff(). They can still be caught into the hand.


## True when [param obj] can be pushed from the hand out onto the ray. Objects
## answer for themselves; anything that doesn't implement the method is eligible.
func _handoff_eligible(obj: Node3D) -> bool:
	if not is_instance_valid(obj):
		return false
	if obj.has_method("wants_ray_handoff"):
		return obj.wants_ray_handoff()
	return true


# Drive the push-out gesture. Called from _process while an object is in hand.
func _process_push_to_ray() -> void:
	var eligible := _handoff_eligible(picked_up_object)
	var trigger_held := eligible \
			and _controller.get_float("trigger") > HANDOFF_TRIGGER_THRESHOLD

	# The sibling pointer fires UI presses on the same trigger. Mute its button
	# dispatch while the modifier is live so aiming at a panel doesn't click it.
	# _process_pointer_highlight and _process_ray_grab read $RayCast directly, so
	# the ray itself keeps working — the same trick retro_controller uses.
	_set_pointer_muted(trigger_held)
	_set_handoff_loco_block(trigger_held)

	if not trigger_held:
		_push_armed = true
		return

	var stick_y := _controller.get_vector2("primary").y
	if stick_y < HANDOFF_PUSH_REARM:
		_push_armed = true
	if not _push_armed or stick_y < HANDOFF_PUSH_STICK:
		return

	_push_armed = false
	_push_to_ray()


# Hand -> ray. Refuses (silently, no denial rumble) if the other hand already
# owns the single allowed ray grab.
func _push_to_ray() -> void:
	var target := picked_up_object as XRToolsPickable
	if not is_instance_valid(target):
		return
	# Check BEFORE releasing: otherwise the object is dropped with nowhere to go.
	if _is_any_other_pickup_ray_grabbing() or _is_target_ray_grabbed_elsewhere(target):
		return

	var from := target.global_transform
	var seed_distance := _ray_origin().distance_to(from.origin)

	if not _release_hand_for_transfer():
		return

	_start_ray_grab_at(target, maxf(seed_distance, RAY_GRAB_DISTANCE_MIN), true)
	_begin_handoff_blend(from)
	Haptics.pulse(_controller, 0.45, 60, &"ray_handoff")
	has_transferred.emit(target, true)


# Ray -> hand. Runs once the charge completes.
func _catch_from_ray() -> void:
	var target := _ray_grab_object
	if not is_instance_valid(target):
		_reset_charge()
		return

	var from := target.global_transform
	_reset_charge()
	_release_ray_for_transfer()

	# picked_up_ranged routes XRToolsPickable.pick_up through create_lerp, so the
	# object flies into the palm instead of snapping there.
	picked_up_ranged = true
	picked_up_object = target
	target.pick_up(self)

	if not is_instance_valid(picked_up_object):
		return

	_copy_collisions()
	picked_up_object.request_highlight(self, false)
	_begin_handoff_blend(from)
	Haptics.pulse(_controller, 0.60, 80, &"ray_handoff")
	has_transferred.emit(target, false)


# The dwell gate. Called from _process_ray_grab after the distance clamp.
func _process_catch_charge(delta: float, stick_y: float) -> void:
	var at_gate := _ray_grab_distance <= RAY_GRAB_DISTANCE_MIN + 0.001

	# Arrival tick — without it, an object that stops dead looks like a bug.
	if at_gate and not _reel_gated:
		Haptics.pulse(_controller, 0.30, 30, &"ray_handoff")
	_reel_gated = at_gate

	# Hysteresis: pull past CATCH_STICK to start charging, ease past CATCH_RELEASE
	# to abandon it. A gentle reel (over the 0.1 deadzone but short of the edge)
	# moves the object without ever charging.
	var charging := false
	if _reel_charge > 0.0:
		charging = stick_y < -CATCH_RELEASE
	else:
		charging = stick_y < -CATCH_STICK

	if not at_gate or not charging:
		_reset_charge()
		return

	_reel_charge += delta
	if _reel_charge >= CATCH_HOLD_TIME:
		_catch_from_ray()
		return

	_reel_charge_tick += delta
	if _reel_charge_tick >= 1.0 / CATCH_CHARGE_HZ:
		_reel_charge_tick = 0.0
		var t := clampf(_reel_charge / CATCH_HOLD_TIME, 0.0, 1.0)
		# Quiet early, swelling at the end, so the catch is anticipated.
		var mag := lerpf(CATCH_CHARGE_MAG_MIN, CATCH_CHARGE_MAG_MAX, pow(t, 1.5))
		Haptics.hold(_controller, mag, &"reel_charge")


# Abandon any in-progress charge and silence its rumble. Must be reachable from
# every path that can end the gesture — an indefinite rumble event that is never
# cleared keeps the controller buzzing forever.
func _reset_charge() -> void:
	if _reel_charge > 0.0:
		Haptics.stop(_controller, &"reel_charge")
	_reel_charge = 0.0
	_reel_charge_tick = 0.0


# Release from the hand without the throw impulse or the has_dropped signal.
# Returns false if the object went away mid-release.
func _release_hand_for_transfer() -> bool:
	if not is_instance_valid(picked_up_object):
		return false

	_remove_copied_collisions()
	picked_up_object.let_go(self, Vector3.ZERO, Vector3.ZERO)
	picked_up_object = null

	if _collision_hand:
		_collision_hand.set_held_weight(0.0)

	# Hand-carry motion must not leak into a later throw off the ray.
	_velocity_averager.clear()
	return true


# Release from the ray without the throw impulse or the has_dropped signal. The
# locomotion block stays put — the caller is about to hold the object anyway.
func _release_ray_for_transfer() -> void:
	# Catching it into the hand abandons whatever socket it was lining up with.
	_clear_socket_preview()
	if not is_instance_valid(_ray_grab_object):
		_ray_grab_object = null
		return
	_ray_grab_object.freeze = _ray_grab_object.restore_freeze
	_ray_grab_object.collision_mask = _ray_grab_object.original_collision_mask
	_ray_grab_object.collision_layer = _ray_grab_object.original_collision_layer
	_ray_grab_object = null
	_reel_gated = false
	if _locomotion_manager:
		_locomotion_manager.set_block(_ray_grab_block_owner, LocomotionManager.CHANNEL_ALL, false)
	_velocity_averager.clear()


# A transferred object is off the ray axis at the moment of handoff (the pointer
# RayCast sits a few cm from the palm). Ease onto the computed pose instead of
# snapping to it.
func _begin_handoff_blend(from: Transform3D) -> void:
	_handoff_blend = HANDOFF_BLEND_TIME
	_handoff_blend_from = from


func _apply_handoff_blend(target_xform: Transform3D, delta: float) -> Transform3D:
	if _handoff_blend <= 0.0:
		return target_xform
	_handoff_blend = maxf(_handoff_blend - delta, 0.0)
	var t := 1.0 - (_handoff_blend / HANDOFF_BLEND_TIME)
	return _handoff_blend_from.interpolate_with(target_xform, smoothstep(0.0, 1.0, t))


# ----------  Socket preview for a ray-held object  ----------
#
# Mirrors the hand-held preview in XRToolsGrabDriver (see its LOCAL PATCH block):
# while the object the beam is carrying comes within a compatible socket's grab
# range, it blends onto the pose it would seat at, wearing the orange preview
# outline. Releasing there hands it to the zone instead of dropping it.
#
# A ray grab creates no GrabDriver, so none of that machinery runs for it — and
# the zone's own capture path is no help either: it listens for the object's
# `dropped` signal, which only fires from let_go(), which a ray grab never calls.
# Hence an explicit hand-off in _end_ray_grab.
#
# Unlike the hand version this needs no collision exceptions: a ray-held object
# already has collision_mask = 0, so it cannot shove the console it is aiming at.


## Blend `want` (where the beam wants the object) toward the socket it is close
## enough to seat in, and return the pose to actually use.
func _apply_socket_preview(want: Transform3D, delta: float) -> Transform3D:
	if not is_instance_valid(_ray_grab_object):
		return want

	# Test against where the BEAM wants the object, not where it currently is:
	# while previewing it sits AT the zone, so its own position could never fall
	# out of range and the preview would never disengage.
	var radius := _get_ray_preview_radius()
	var zone := XRToolsSnapZone.find_preview_zone(_ray_grab_object, want.origin, radius)
	if zone == null and is_instance_valid(_ray_preview_zone) \
			and _ray_preview_zone.can_preview(_ray_grab_object) \
			and _ray_preview_zone.global_position.distance_to(want.origin) \
				< (_ray_preview_zone.grab_distance + radius) * RAY_PREVIEW_HYSTERESIS:
		zone = _ray_preview_zone
	if zone:
		_ray_preview_zone = zone

	if (zone != null) != _ray_previewing:
		_ray_previewing = zone != null
		_notify_ray_snap_preview(_ray_previewing)

	_ray_preview_blend = move_toward(
		_ray_preview_blend, 1.0 if zone else 0.0, delta * RAY_PREVIEW_BLEND_SPEED)

	if _ray_preview_blend <= 0.001 or not is_instance_valid(_ray_preview_zone):
		if _ray_preview_blend <= 0.001:
			_ray_preview_zone = null
		return want

	var w := smoothstep(0.0, 1.0, _ray_preview_blend)
	var seated := _seated_transform(_ray_preview_zone)
	return Transform3D(
		Basis(want.basis.get_rotation_quaternion().slerp(
			seated.basis.get_rotation_quaternion(), w)).scaled(want.basis.get_scale()),
		want.origin.lerp(seated.origin, w))


## Where the object will actually sit once `zone` captures it: grab-point-
## corrected (without it a plug would appear to go in backwards) and offset by
## whatever stand-off the zone presents its media at, so the beam's ghost and
## the hand-held ghost agree.
func _seated_transform(zone: XRToolsSnapZone) -> Transform3D:
	return zone.preview_pose_for(_ray_grab_object)


func _get_ray_preview_radius() -> float:
	if _ray_preview_radius >= 0.0:
		return _ray_preview_radius
	_ray_preview_radius = 0.0
	# The body's OWN shapes only. A plug carries a wider PointerArea proxy so the
	# beam can hit it, and measuring that would engage sockets far too early.
	var body := _ray_grab_object as CollisionObject3D
	if body:
		for owner_id in body.get_shape_owners():
			var off: float = body.shape_owner_get_transform(owner_id).origin.length()
			for i in body.shape_owner_get_shape_count(owner_id):
				var shape: Shape3D = body.shape_owner_get_shape(owner_id, i)
				if shape:
					_ray_preview_radius = maxf(_ray_preview_radius,
						off + XRToolsGrabDriver._shape_extent(shape))
	if _ray_preview_radius <= 0.0:
		_ray_preview_radius = 0.03
	return _ray_preview_radius


func _notify_ray_snap_preview(on: bool) -> void:
	if not is_instance_valid(_ray_grab_object):
		return
	for child in _ray_grab_object.get_children():
		if child.has_method("set_snap_preview"):
			child.set_snap_preview(on)
			return


## Forget any engaged socket. Safe to call when none is.
func _clear_socket_preview() -> void:
	if _ray_previewing:
		_notify_ray_snap_preview(false)
	_ray_previewing = false
	_ray_preview_zone = null
	_ray_preview_blend = 0.0
	_ray_preview_radius = -1.0


# Keep a tethered object — a cable plug — inside the reach of its own cord.
#
# The object has to stay ON the ray, so this solves for the furthest point along
# the beam still inside the tether sphere instead of yanking it off-axis. The
# host's per-frame clamp (retro_controller._physics_process and its five
# siblings) skips only while is_picked_up(), which a ray grab never sets, so
# without this the two would write the same transform in an order the scene tree
# decides and the plug would jitter.
func _clamp_distance_to_tether(origin: Vector3, dir: Vector3, distance: float) -> float:
	if not is_instance_valid(_ray_grab_object) \
			or not _ray_grab_object.has_method("get_tether"):
		return distance
	var tether: Dictionary = _ray_grab_object.get_tether()
	if tether.is_empty():
		return distance
	var length: float = tether.get("length", 0.0) - TETHER_MARGIN
	if length <= 0.0:
		return distance

	var m: Vector3 = origin - (tether.get("anchor", Vector3.ZERO) as Vector3)
	var c := m.length_squared() - length * length
	if c > 0.0:
		# The hand is already further from the anchor than the cord is long. No
		# point on the beam is reachable; leave it to the host's clamp, which
		# pulls the plug taut toward the anchor — which is what a stretched cable
		# should look like.
		return distance
	# Origin inside the sphere: exactly one intersection ahead of us.
	var b := m.dot(dir)
	return minf(distance, -b + sqrt(b * b - c))


# Origin of the aiming ray, falling back to the pickup itself when the sibling
# pointer hasn't resolved yet.
func _ray_origin() -> Vector3:
	if _ray_pointer:
		var ray_cast := _ray_pointer.get_node_or_null("RayCast") as RayCast3D
		if ray_cast:
			return ray_cast.global_transform.origin
	return global_transform.origin


# Suppress the sibling pointer's button dispatch without disabling its RayCast.
func _set_pointer_muted(muted: bool) -> void:
	if muted == _pointer_muted or not _ray_pointer:
		return
	_pointer_muted = muted
	_ray_pointer.enabled = not muted


func _set_handoff_loco_block(blocked: bool) -> void:
	if blocked == _handoff_loco_blocked or not _locomotion_manager:
		return
	_handoff_loco_blocked = blocked
	var channel := LocomotionManager.CHANNEL_LEFT \
			if _controller.tracker == &"left_hand" \
			else LocomotionManager.CHANNEL_RIGHT
	_locomotion_manager.set_block(_handoff_block_owner, channel, blocked)

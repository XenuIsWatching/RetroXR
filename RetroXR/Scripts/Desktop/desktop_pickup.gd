## DesktopPickup — mouse-driven object pickup for desktop (non-VR) mode.
##
## Attach to XRCamera3D.  When XR is not active:
##   Left-click             — pick up the XRToolsPickable under the cursor.
##   Shift + Left-click     — drop the currently held object.
##   Scroll up/down    — push/pull the held object along the camera ray.
##                       (Disabled for FPS-snap objects.)
##   Middle-mouse drag — rotate the held object in place (aircraft controls:
##                       mouse right yaws the far side right, mouse up pitches
##                       the far side up). Shift + horizontal drag rolls it
##                       (right = clockwise). (Disabled for FPS-snap objects.)
##
## FPS-snap mode:
##   Objects with a truthy "desktop_fps_snap" property (e.g. the LightGun) are
##   locked to a fixed lower-right offset from the camera instead of floating
##   freely on the ray.  This gives an FPS-style weapon view.  The hand pivot's
##   orientation matches the camera so the weapon always aims where you look.
##
##   An FPS-snap object may also name a COMPANION — a second object it arrives
##   with, which gets the mirrored lower-LEFT slot, i.e. the player's other hand.
##   The Wiimote's Nunchuk is the case this exists for: it is a separate pickable
##   on a cord, so without a slot of its own it hung off the remote and dragged
##   along the floor.  Declared by a desktop_companion() method returning the
##   pickable or null, and re-read every frame — plug the cord in mid-hold and it
##   comes to hand, pull it out and it drops.
##
## Objects must have collision on layer 3 ("Pickable") to be grabbable.
##
## The "fake hand" (_hand_pivot, group "desktop_hand") is an invisible Node3D
## child that acts as the grabber.  XRToolsGrabDriver follows its
## global_transform, so moving/rotating the pivot moves/rotates the held object.
extends Node3D

const InteractionTargetType := preload("res://Scripts/Interaction/interaction_target.gd")
const InteractionResolver := preload("res://Scripts/Interaction/interaction_resolver.gd")

## Scroll step in metres
const SCROLL_STEP := 0.075
const MIN_DIST    := 0.15
const MAX_DIST    := 5.0

## Mouse sensitivity for rotation (radians per pixel)
const ROT_SENSITIVITY := 0.008

## Pointer travel (pixels) that turns a click into a drag.
const CLICK_DRAG_PX := 6.0

## FPS-snap local offset from camera: right, down, forward.
## Applied as a Transform3D in camera-local space so the weapon is always
## in the same screen-space corner regardless of where the player looks.
const FPS_SNAP_LOCAL := Transform3D(Basis.IDENTITY, Vector3(0.20, -0.22, -0.45))

## The companion's slot: the same offset mirrored across the view, so the pair
## reads as one in each hand. Same depth and drop as the weapon slot on purpose —
## anything else and the two sit at visibly different distances.
const FPS_SNAP_COMPANION_LOCAL := Transform3D(Basis.IDENTITY, Vector3(-0.20, -0.22, -0.45))

var _held_object : XRToolsPickable = null
var _grab_dist   : float = 1.5

var _hand_pivot  : Node3D    = null
var _desktop_pointer : XRToolsDesktopFunctionPointer = null

var _companion_object : XRToolsPickable = null
var _companion_pivot  : Node3D = null

var _middle_held : bool = false
var _hovered_target : Node3D = null

## Left button down over something that answers to a click (a cart lying in a push
## tray). Held until the button comes back up — a release without travel is the
## click, travel first is a pull — so the grab has to wait for one or the other.
var _pending_click : Node3D = null
var _pending_grab  : Node3D = null
var _click_drag    : float = 0.0


func _ready() -> void:
	# Invisible pivot that the grabbed object follows.
	# Uses DesktopHandPivot script to satisfy XRToolsPickable's grabber interface
	# (picked_up_ranged property + drop_object() callback).
	# Placed in the "desktop_hand" group so light_gun.gd / retro_controller.gd
	# can detect desktop-grab in their _on_grabbed_signal handlers.
	var pivot_script := load("res://Scripts/Desktop/desktop_hand_pivot.gd")
	_hand_pivot = Node3D.new()
	_hand_pivot.set_script(pivot_script)
	_hand_pivot.name = "DesktopHand"
	_hand_pivot.add_to_group("desktop_hand")
	_hand_pivot._owner_pickup = weakref(self)
	add_child(_hand_pivot)

	# The other hand. Same shim and the same group — HeldHint reads "desktop_hand"
	# to decide which platform's hints an object shows, and a companion held by
	# something outside the group would advertise the VR drop combo.
	_companion_pivot = Node3D.new()
	_companion_pivot.set_script(pivot_script)
	_companion_pivot.name = "DesktopCompanionHand"
	_companion_pivot.add_to_group("desktop_hand")
	_companion_pivot._owner_pickup = weakref(self)
	_companion_pivot._drop_method = &"_on_companion_drop_object"
	add_child(_companion_pivot)

	_desktop_pointer = get_node_or_null("FunctionDesktopPointer") as XRToolsDesktopFunctionPointer


func _unhandled_input(event: InputEvent) -> void:
	# Only active in desktop mode
	if get_viewport().use_xr:
		return

	if event is InputEventMouseButton:
		var mbe := event as InputEventMouseButton
		match mbe.button_index:
			MOUSE_BUTTON_LEFT:
				if mbe.pressed:
					if _held_object:
						# Shift+click drops any held object.
						# Plain click also drops non-FPS-snap objects (books, controllers, etc.)
						# so the user doesn't need Shift for those.
						# FPS-snap objects (light gun) require Shift+click to drop because
						# plain left-click is the shoot/trigger action while the gun is held.
						# Objects with desktop_shift_drop (mouse) do too — plain click is
						# their own LEFT button while held.
						if mbe.shift_pressed or not (_is_fps_snap() or _needs_shift_drop()):
							_drop()
							get_viewport().set_input_as_handled()
					else:
						_try_grab()
				elif _pending_click != null:
					# Came back up without travelling: it was a click.
					var clicked := _pending_click
					_pending_click = null
					_pending_grab = null
					if is_instance_valid(clicked):
						clicked.desktop_click_action()
					get_viewport().set_input_as_handled()

			MOUSE_BUTTON_MIDDLE:
				_middle_held = mbe.pressed

			MOUSE_BUTTON_WHEEL_UP:
				if _held_object and not _is_fps_snap():
					_grab_dist = clampf(_grab_dist - SCROLL_STEP, MIN_DIST, MAX_DIST)
					get_viewport().set_input_as_handled()

			MOUSE_BUTTON_WHEEL_DOWN:
				if _held_object and not _is_fps_snap():
					_grab_dist = clampf(_grab_dist + SCROLL_STEP, MIN_DIST, MAX_DIST)
					get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion and _pending_click != null:
		# Travelled while held: the player is pulling it out, not pressing it.
		_click_drag += (event as InputEventMouseMotion).relative.length()
		if _click_drag >= CLICK_DRAG_PX:
			var target := _pending_grab
			_pending_click = null
			_pending_grab = null
			if is_instance_valid(target):
				_grab_target(target)

	elif event is InputEventMouseMotion and _middle_held:
		if _held_object and not _is_fps_snap():
			var delta := (event as InputEventMouseMotion).relative
			# Aircraft semantics (nose = far side, pointing away from the camera):
			# mouse right → nose yaws right, mouse up → nose pitches up.
			# Shift+drag horizontal → roll (right = roll right / clockwise).
			# Axes are built in world space and premultiplied onto the pivot's
			# global basis — Node3D.rotate() expects parent-space axes, so feeding
			# it world-space camera axes skewed the rotation whenever the camera
			# was turned.
			var pitch_axis := global_transform.basis.x.normalized()
			var roll_axis := (-global_transform.basis.z).normalized()
			var flat_fwd := -global_transform.basis.z
			flat_fwd.y = 0.0
			if flat_fwd.length_squared() > 0.0001:
				roll_axis = flat_fwd.normalized()
				pitch_axis = roll_axis.cross(Vector3.UP).normalized()
			var pivot_basis := _hand_pivot.global_basis
			if (event as InputEventMouseMotion).shift_pressed:
				pivot_basis = Basis(roll_axis, delta.x * ROT_SENSITIVITY) * pivot_basis
			else:
				pivot_basis = Basis(Vector3.UP, -delta.x * ROT_SENSITIVITY) * pivot_basis
			pivot_basis = Basis(pitch_axis, -delta.y * ROT_SENSITIVITY) * pivot_basis
			_hand_pivot.global_basis = pivot_basis.orthonormalized()
		# Always consume mouse motion while MMB is held so MovementDesktopTurn
		# doesn't also rotate the player.
		get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	_update_reticle_highlight()

	if not _held_object:
		return
	if get_viewport().use_xr:
		_drop()
		return

	if _is_fps_snap():
		# Lock weapon to camera-local FPS slot — orientation tracks camera exactly
		# so the barrel always points straight ahead.
		_hand_pivot.global_transform = global_transform * FPS_SNAP_LOCAL
		_sync_companion()
	else:
		# Standard ray-hold: slide along camera forward at the stored distance
		var fwd := -global_transform.basis.z.normalized()
		_hand_pivot.global_position = global_position + fwd * _grab_dist
		_release_companion()


## True while the desktop hand is holding something (spawn-into-hand gate).
func is_holding() -> bool:
	return _held_object != null


## Grab a freshly spawned pickable into the desktop hand (spawn-into-hand).
func grab_spawned(pickable: XRToolsPickable) -> void:
	if _held_object or not is_instance_valid(pickable):
		return
	_grab_target(pickable)


## Cast ray and grab the first XRToolsPickable hit.
func _try_grab() -> void:
	if _held_object:
		_drop()
		return

	var interaction := _resolve_interaction_target(true)
	if not interaction.can_grab or not is_instance_valid(interaction.action_node):
		return
	# The resolver now runs down the POINTER's ray, which reaches twice as far as
	# the pickup ray it replaced. Out of arm's reach is out of reach.
	if interaction.distance > MAX_DIST:
		return

	# Something that answers to a click takes the press instead of the grab, and
	# only gives it up if the pointer then travels.
	var clickable := _click_action_node(interaction.action_node)
	if clickable != null:
		_pending_click = clickable
		_pending_grab = interaction.action_node
		_click_drag = 0.0
		return

	_grab_target(interaction.action_node)


## The object under the pointer that wants the click for itself, or null. A snap
## zone is asked about what it is HOLDING: the resolver hands back the socket, but
## it is the cart in the tray that knows a click means "push me home".
##
## The object is asked whether the click is claimable RIGHT NOW, not whether it owns
## the method at all — a cartridge carries one wherever it is, and a class-level
## test made every loose cart in the room wait for a drag before it could be picked
## up, with a plain click doing nothing.
func _click_action_node(target: Node3D) -> Node3D:
	var zone := target as XRToolsSnapZone
	var obj: Node3D = InteractionResolver.held_pickable(zone) if zone != null else target
	if obj != null and obj.has_method("desktop_click_available") \
			and obj.desktop_click_available() and obj.has_method("desktop_click_action"):
		return obj
	return null


## Park the companion slot and reconcile who is standing in it.
##
## The pivot is moved FIRST so a companion picked up on this frame lands in the
## corner immediately rather than snapping there next frame from wherever the
## cord had swung it.
func _sync_companion() -> void:
	_companion_pivot.global_transform = global_transform * FPS_SNAP_COMPANION_LOCAL

	var want := _companion_wanted()
	if want == _companion_object:
		return
	_release_companion()
	if not is_instance_valid(want) or not want.can_pick_up(_companion_pivot):
		return
	want.pick_up(_companion_pivot)
	_companion_object = want

	# A companion was not grabbed, it arrived, so its hint panel is answering a
	# question nobody asked — and answering it wrongly: the rotate rows
	# HeldObjectPhysics adds to every desktop grab are dead in an FPS slot, and
	# there is no gesture that puts this one down by itself. Both grab handlers
	# have already run and built the panel by the time pick_up returns, so this
	# takes it back down rather than preventing it. Looked up rather than
	# for_node()'d: a companion with no hint should not be given one.
	var hint := want.get_node_or_null("HeldHint") as HeldHint
	if hint != null:
		hint.hide_now()


## What the held object says should ride the companion slot, if anything.
func _companion_wanted() -> XRToolsPickable:
	if _held_object == null or not _held_object.has_method("desktop_companion"):
		return null
	return _held_object.call("desktop_companion") as XRToolsPickable


func _release_companion() -> void:
	if _companion_object == null:
		return
	var obj := _companion_object
	_companion_object = null
	if is_instance_valid(obj) and obj.is_picked_up() \
			and obj.get_picked_up_by() == _companion_pivot:
		obj.let_go(_companion_pivot, Vector3.ZERO, Vector3.ZERO)
		obj.sleeping = false


## Called by DesktopCompanionHand.drop_object() when the companion is released
## from the far end — a snap zone taking it, or its own script calling drop().
func _on_companion_drop_object() -> void:
	_release_companion()


## Drop the currently held object.
func _drop() -> void:
	_release_companion()
	if _held_object:
		# Only when the modifier was actually required — a plain-click drop taught
		# the player nothing.
		if _is_fps_snap() or _needs_shift_drop():
			HeldHint.note_on(_held_object, &"drop_desktop")
		var obj := _held_object
		_held_object = null
		if obj.is_picked_up() and obj.get_picked_up_by() == _hand_pivot:
			obj.let_go(_hand_pivot, Vector3.ZERO, Vector3.ZERO)
			obj.sleeping = false
	_middle_held = false


## Called by DesktopHandPivot.drop_object() when pickable.gd notifies the
## grabber of a drop (e.g. from a snap zone or external pickable.drop() call).
func _on_pivot_drop_object() -> void:
	_release_companion()
	if _held_object and _held_object.is_picked_up() and _held_object.get_picked_up_by() == _hand_pivot:
		var obj := _held_object
		_held_object = null
		obj.let_go(_hand_pivot, Vector3.ZERO, Vector3.ZERO)
		obj.sleeping = false
		_middle_held = false
		return
	_held_object = null
	_middle_held = false


## Returns true when the held object wants FPS-snap positioning.
func _is_fps_snap() -> bool:
	return _held_object != null and _held_object.get("desktop_fps_snap")


## True when the held object claims plain left-click as its own input
## (RetroMouse) — dropping then needs Shift+click, like the light gun.
func _needs_shift_drop() -> bool:
	return _held_object != null and _held_object.get("desktop_shift_drop") == true


func _update_reticle_highlight() -> void:
	if get_viewport().use_xr or _held_object:
		_set_hovered_target(null)
		return

	var interaction := _resolve_interaction_target(false)
	if not interaction.can_grab or not is_instance_valid(interaction.highlight_node):
		_set_hovered_target(null)
		return

	_set_hovered_target(interaction.highlight_node)


func _set_hovered_target(target: Node3D) -> void:
	if target == _hovered_target:
		return

	if _hovered_target and _hovered_target.has_method("request_highlight"):
		_hovered_target.request_highlight(self, false)

	_hovered_target = target

	if _hovered_target and _hovered_target.has_method("request_highlight"):
		_hovered_target.request_highlight(self, true)


func _grab_target(target: Node3D) -> void:
	var pickable: XRToolsPickable = null
	var snap_zone := target as XRToolsSnapZone
	if snap_zone:
		pickable = InteractionResolver.held_pickable(snap_zone)
	else:
		pickable = target as XRToolsPickable

	if not pickable:
		return
	# Asked BEFORE the zone lets go, and only about the rules that do not depend on
	# the zone holding it — can_pick_up() answers "already held" while it does. A
	# refusal taken after the drop leaves the object released by the socket and
	# picked up by nobody, which is how a clamped cart falls out of a console.
	if not pickable.enabled \
			or (pickable.has_method("is_clamped") and pickable.is_clamped()):
		return
	if snap_zone:
		snap_zone.drop_object()
	if not pickable.can_pick_up(_hand_pivot):
		return

	# Position the pivot at the object's origin so the grab offset is ~zero,
	# giving clean behaviour for both ray-hold and FPS-snap modes.
	_grab_dist = clampf(
		global_position.distance_to(pickable.global_position),
		MIN_DIST, MAX_DIST)
	_hand_pivot.global_transform = pickable.global_transform

	_set_hovered_target(null)
	pickable.pick_up(_hand_pivot)
	_held_object = pickable


func _resolve_interaction_target(refresh: bool) -> InteractionTarget:
	if not is_instance_valid(_desktop_pointer):
		return InteractionTargetType.none()

	if refresh:
		return _desktop_pointer.resolve_interaction_target()
	return _desktop_pointer.get_resolved_target()

## VrPointerBlock — hide a hand's ray pointer while an object owns that hand.
##
## Anything held in a fist that also aims — a pad, a light gun, a Wii Remote, a
## TV remote, a handheld console — has to suppress the laser pointer on the hand
## holding it, or the player's grab gesture fires the pointer at whatever is
## behind the thing they are already holding.
##
## Five scripts had each grown their own copy of this, identical apart from
## local variable names. Sharing it is not only about the twenty lines: the
## pointer is refcounted through a `block_count` meta BECAUSE two objects can
## legitimately block the same hand at once, and a divergent copy is how that
## count gets left standing. A hand whose count never returns to zero has a dead
## pointer for the rest of the session, with nothing on screen to say why.
##
## Held by composition rather than inherited: every one of these scripts already
## extends XRToolsPickable, which is vendored.
class_name VrPointerBlock
extends RefCounted

## Whether each hand is currently blocked BY THIS OWNER. The pointer's own
## `block_count` is the shared total; this pair is one object's contribution to
## it, and is what makes release idempotent.
var _blocking_left: bool = false
var _blocking_right: bool = false


## Whether this owner is currently blocking `ctrl`'s pointer.
func is_blocking(ctrl: XRController3D) -> bool:
	if not is_instance_valid(ctrl):
		return false
	return _blocking_left if _is_left(ctrl) else _blocking_right


## Take or release this owner's block on `ctrl`. A repeated call in the same
## direction is a no-op, so the shared count cannot be double-counted.
func set_block(ctrl: XRController3D, should_block: bool) -> void:
	if not is_instance_valid(ctrl):
		return
	var is_left := _is_left(ctrl)
	if should_block == (_blocking_left if is_left else _blocking_right):
		return
	if is_left:
		_blocking_left = should_block
	else:
		_blocking_right = should_block

	var pointer: Node3D = ctrl.get_node_or_null("FunctionPointer")
	if pointer == null:
		return
	var count: int = maxi(0, int(pointer.get_meta("block_count", 0))
		+ (1 if should_block else -1))
	pointer.set_meta("block_count", count)
	pointer.visible = count == 0
	# FunctionPickup._process_pointer_highlight queries the RayCast directly,
	# bypassing pointer.visible, so ray-grab survives hiding the pointer alone.
	var ray: RayCast3D = pointer.get_node_or_null("RayCast") as RayCast3D
	if ray != null:
		ray.enabled = count == 0


## Give both hands back. Call from _exit_tree: an object that leaves the tree
## still holding a block leaves the pointer's count above zero for good.
func release(left_ctrl: XRController3D, right_ctrl: XRController3D) -> void:
	if _blocking_left:
		set_block(left_ctrl, false)
	if _blocking_right:
		set_block(right_ctrl, false)
	# A controller that has already gone invalid can never be un-blocked through
	# its pointer, so drop the claim regardless — otherwise a later release()
	# would try again and a re-grab would think the hand was still held.
	_blocking_left = false
	_blocking_right = false


func _is_left(ctrl: XRController3D) -> bool:
	return ctrl.tracker == &"left_hand"

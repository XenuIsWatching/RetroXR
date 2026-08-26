## ObjectLock — pins a pickable where it stands, so no hand, ray or snap zone
## can move it again until it is unlocked.
##
## The gate is XRToolsPickable.can_pick_up(), which every route into a grab
## already asks: the near grab, the ray grab, the desktop hand and a snap zone
## all call it, and all four refuse when `enabled` is false. So the lock is one
## flag rather than a check bolted onto each of them.
##
## `freeze` goes with it, because "cannot be picked up" is not the same as
## "stays put": an unfrozen body still slides when something is dropped on it,
## and one locked in mid-air would simply fall. What each body had before is
## remembered per node, not assumed — several objects here ship with
## can_ranged_grab off or start frozen, and handing them back a blanket `true`
## would quietly grant a grab the object never allowed.
class_name ObjectLock

const META_LOCKED := &"locked_in_place"
const META_PREV := &"locked_prev_state"


## Anything that can be picked up can be locked; nothing else has a grab to take
## away.
static func can_lock(node: Object) -> bool:
	return node is XRToolsPickable


static func is_locked(node: Object) -> bool:
	if node is Node and is_instance_valid(node):
		return bool((node as Node).get_meta(META_LOCKED, false))
	return false


static func set_locked(node: Node, locked: bool) -> void:
	if not can_lock(node) or not is_instance_valid(node):
		return
	var body := node as XRToolsPickable
	if locked == is_locked(body):
		return
	if locked:
		# Locking something out of a hand is a legitimate gesture — put it down
		# first, or the grab driver keeps driving a body that refuses to be let
		# go of by any later release.
		if body.is_picked_up():
			body.drop()
		body.set_meta(META_PREV, {
			"enabled": body.enabled,
			"ranged": body.can_ranged_grab,
			"freeze": body.freeze,
		})
		body.set_meta(META_LOCKED, true)
		body.enabled = false
		body.can_ranged_grab = false
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.freeze = true
	else:
		var prev: Dictionary = body.get_meta(META_PREV, {})
		body.set_meta(META_LOCKED, false)
		body.enabled = bool(prev.get("enabled", true))
		body.can_ranged_grab = bool(prev.get("ranged", true))
		body.freeze = bool(prev.get("freeze", false))


static func toggle(node: Node) -> bool:
	set_locked(node, not is_locked(node))
	return is_locked(node)

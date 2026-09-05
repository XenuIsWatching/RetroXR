## DesktopHandPivot — minimal XRToolsFunctionPickup shim for desktop pickup.
##
## XRToolsPickable.pick_up(by) and .drop() access these members on the grabber:
##   picked_up_ranged  — read to decide snap vs lerp grab driver
##   drop_object()     — called when the pickable reports it has been dropped
##
## This script satisfies that interface for the plain Node3D pivot used by
## desktop_pickup.gd, without any VR controller machinery.
extends Node3D

## Always false: desktop grabs are always immediate (snap), never ranged-lerp.
var picked_up_ranged: bool = false

## Weak reference back to the DesktopPickup that owns this pivot.
## Set by desktop_pickup.gd immediately after creating the pivot.
var _owner_pickup: WeakRef = null

## Which of the owner's release handlers this pivot reports to. DesktopPickup runs
## two pivots — the hand and the companion slot — and they must clear different
## state: routing the companion's release through the hand's handler would let go
## of the object the player is actually holding.
var _drop_method: StringName = &"_on_pivot_drop_object"


## The DesktopPickup this pivot belongs to, or null once it has gone. Weak on
## purpose — the pivot must not keep its owner alive.
func owner_pickup() -> Node:
	return _owner_pickup.get_ref() if _owner_pickup != null else null


## Called by XRToolsPickable.drop() to notify the grabber it was released.
## Forward to DesktopPickup so it clears its held object even if drop came from
## outside (e.g. a snap zone or another script calling pickable.drop()).
func drop_object() -> void:
	if _owner_pickup == null:
		return
	var pickup = _owner_pickup.get_ref()
	if pickup and pickup.has_method(_drop_method):
		pickup.call(_drop_method)

## VrHold — the small conventions every held peripheral has to agree on.
##
## A pad, a light gun, a Wii Remote, a Nunchuk, a TV remote and a handheld
## console all do the same three things while held: hide the controller's own
## model so the object is in the hand instead of overlapping it, and claim the
## VR and desktop locomotion channels under a key of their own.
##
## The owner keys are the reason this is shared rather than copied. LocomotionManager
## erases a block BY KEY, so two objects that pick the same key erase each other's
## claim and the player is left either unable to move or moving while holding
## something that should have stopped them. Deriving the key from the instance id
## here means a new peripheral cannot get the prefix wrong.
class_name VrHold
extends RefCounted


## Who is holding a pickable, as XRToolsPickable's own grab driver.
##
## The single place this project reaches into the vendored addon's private
## _grab_driver. XRToolsPickable exposes no accessor for its holder, and adding
## one would mean patching godot-xr-tools — which the next update drops. Kept to
## one function so that coupling is one line to find and one line to change.
##
## Returns null when nothing holds it. `primary` is the hand that picked it up,
## `secondary` the second hand on a two-handed grab; each has `.controller`,
## `.by` and `.pickup`.
static func grab_driver(pickable: Object) -> Variant:
	if not is_instance_valid(pickable):
		return null
	return pickable.get("_grab_driver")


## Show or hide a controller's own hand/controller model.
##
## Duck-typed on purpose: which node answers `set_model_visible` differs between
## the XR controller scenes, and a peripheral may be held by one that does not.
static func set_model_visible(ctrl: XRController3D, shown: bool) -> void:
	if is_instance_valid(ctrl) and ctrl.has_method("set_model_visible"):
		ctrl.call("set_model_visible", shown)


## Per-instance owner key for the VR locomotion channels.
static func vr_block_owner(holder: Object) -> StringName:
	return StringName("retro_hold_%d" % holder.get_instance_id())


## Per-instance owner key for the desktop locomotion channel, kept separate from
## the VR one so releasing a desktop hold cannot clear a VR block still wanted.
static func desktop_block_owner(holder: Object) -> StringName:
	return StringName("desktop_hold_%d" % holder.get_instance_id())

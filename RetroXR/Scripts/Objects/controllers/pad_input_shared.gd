## PadInputShared — the parts a held controller and a handheld console share.
##
## `handheld_input.gd` was written as an acknowledged adapted copy of
## `retro_controller.gd`, and several of its functions still carry the "adapted
## from retro_controller.gd" comment. That is honest but it is still a fork:
## twenty-six functions share a name across the two files and eight of them were
## byte-identical, so a fix to the drop combo or the rumble routing had to be
## made twice and was not.
##
## What lives here is the half that has nothing to do with either host — finding
## the rig, reading a stick as a d-pad, the drop combo, and the haptics. What
## stays in each script is its own wiring: a controller has a cable and a port,
## a handheld has a shell and a screen, and neither belongs to the other.
##
## Held by composition, like VrPointerBlock: both scripts already extend
## XRToolsPickable, which is vendored.
class_name PadInputShared
extends RefCounted

## How far a stick must travel before it reads as a d-pad press.
const DPAD_THRESHOLD := 0.35


## The stick-as-d-pad bits, in RetroPad order (up, down, left, right).
static func threshold_to_dpad(stick: Vector2) -> int:
	var bits := 0
	if stick.y > DPAD_THRESHOLD: bits |= (1 << 4)
	if stick.y < -DPAD_THRESHOLD: bits |= (1 << 5)
	if stick.x < -DPAD_THRESHOLD: bits |= (1 << 6)
	if stick.x > DPAD_THRESHOLD: bits |= (1 << 7)
	return bits


## The player's rig, as {locomotion, spawn_menu, left, right}.
##
## Callers run this deferred, because a spawn-menu spawn is handed to the
## grabbing hand BEFORE the lookup gets to run — so whoever calls it must
## re-apply its locomotion block afterwards rather than assume the grab it
## missed will come round again.
static func find_rig(tree: SceneTree) -> Dictionary:
	var rig := {
		"locomotion": tree.root.find_child("LocomotionManager", true, false) as LocomotionManager,
		"spawn_menu": tree.root.find_child("SpawnMenuController", true, false),
		"left": null,
		"right": null,
	}
	for node: Node in tree.root.find_children("*", "XRController3D", true, false):
		var ctrl := node as XRController3D
		if ctrl == null:
			continue
		if ctrl.tracker == &"left_hand":
			rig["left"] = ctrl
		elif ctrl.tracker == &"right_hand":
			rig["right"] = ctrl
	return rig


## Whether the drop combo is down on `ctrl`, telling `hint` it was used.
static func combo_pressed(ctrl: XRController3D, hint: HeldHint) -> bool:
	if not HeldHint.is_combo_pressed(ctrl):
		return false
	if hint:
		hint.note_used(&"drop_vr")
	return true


## Diagnostic for the "drop combo doesn't fire" report: logs the three combo
## inputs whenever their combined state changes, so a logcat or console trace
## shows whether detection (primary_click never reading pressed, say) or the
## drop handling is at fault. State-change gated, so it is silent while idle.
class ComboDebug:
	extends RefCounted

	var _state := -1

	func log_change(ctrl: XRController3D, who: String) -> void:
		if not is_instance_valid(ctrl):
			return
		var state := (1 if ctrl.get_float("grip") > 0.5 else 0) \
			| (2 if ctrl.get_float("trigger") > 0.5 else 0) \
			| (4 if ctrl.get_float("primary_click") > 0.5 else 0)
		if state == _state:
			return
		_state = state
		print("[drop-combo] %s grip=%d trigger=%d stick_click=%d" % [who,
			state & 1, (state >> 1) & 1, (state >> 2) & 1])


## Haptics for a held pad: the XR rumble on whichever hands hold it, and the
## physical pads that are merged into its port.
class Rumble:
	extends RefCounted

	var weak: float = 0.0
	var strong: float = 0.0

	## Keyed on the owner rather than on a tracker, so transferring hands
	## mid-rumble clears the old hand instead of leaving it buzzing.
	var _owner: Node
	var _event: XRToolsRumbleEvent = null
	var _pad_active: bool = false

	func _init(owner: Node) -> void:
		_owner = owner

	func set_levels(new_weak: float, new_strong: float, holders: Array,
			desktop_held: bool) -> void:
		weak = new_weak
		strong = new_strong
		apply(holders, desktop_held)

	## `holders` is every controller physically holding the object — the
	## primary hand and, on a two-hand grab, the secondary. Invalid entries are
	## ignored, so a caller can pass a hand that has already gone.
	func apply(holders: Array, desktop_held: bool) -> void:
		var combined: float = XRToolsRumbleManager.combine_magnitudes(weak, strong)
		XRToolsRumbleManager.clear(_owner)

		var hands: Array = []
		for h: Variant in holders:
			if is_instance_valid(h):
				hands.append(h)
		var is_held: bool = not hands.is_empty() or desktop_held

		# No physical holder → stop desktop vibration if active, nothing else.
		if not is_held or combined <= 0.0:
			stop_pads()
			return

		# XR path: an indefinite event on whichever trackers are holding.
		# XRToolsRumbleManager re-pulses each tick until it is cleared.
		if not hands.is_empty():
			if _event == null:
				_event = XRToolsRumbleEvent.new()
				_event.indefinite = true
			_event.magnitude = combined
			var trackers: Array = []
			for hand: XRController3D in hands:
				trackers.append(hand.tracker)
			XRToolsRumbleManager.add(_owner, _event, trackers)

		# Physical-pad path: every connected pad merges into the one held
		# controller's port, so rumbling all of them is the faithful mirror.
		# Runs alongside the XR haptics, so a hand and a pad can buzz together.
		for device: int in GamepadBindings.usable_pads():
			Input.start_joy_vibration(device, weak, strong, 0.0)
		_pad_active = true

	## Silence the physical pads. Safe to call when they are already quiet, and
	## called from _exit_tree so a pad cannot keep buzzing after its object goes.
	func stop_pads() -> void:
		if not _pad_active:
			return
		for device: int in GamepadBindings.usable_pads():
			Input.stop_joy_vibration(device)
		_pad_active = false

## VmuInput — the hand holding a VMU works its buttons while it runs a minigame.
##
## A VMU out of a controller is a handheld, and HandheldInput is the thing that
## drives a handheld — but that class hangs off a RetroSystem, with its port
## table, pad selection, rumble and netplay route, and a VMU is a card first.
## This is the one-hand half of that file, on a fixed map, because a VMU has
## exactly four buttons and a d-pad and no Controls panel to remap them in:
##
##     A            the holding hand's A / X
##     B            the holding hand's B / Y
##     MODE         the holding hand's stick click
##     SLEEP        the holding hand's trigger
##     d-pad        the holding hand's stick
##
## Both hands' buttons count when both are on the card. On desktop, the
## keyboard's RETRO_JOYPAD_* actions drive it under the same Scroll Lock
## capture a handheld uses, so WASD keeps moving the player until asked.
##
## Active only while the card is running standalone AND held. A card being
## carried to a controller is a card, and nothing here touches the hand; the
## pointer and locomotion blocks go on when a game starts and come off when it
## stops or the card is put down.
class_name VmuInput
extends Node

const INPUT_THRESHOLDS: Dictionary = {
	"ax_button":     0.5,
	"by_button":     0.5,
	"primary_click": 0.5,
	"trigger":       0.3,
}

const DESKTOP_BUTTON_MAP: Dictionary = {
	"RETRO_JOYPAD_A":      ControllerBindings.JOYPAD_A,
	"RETRO_JOYPAD_B":      ControllerBindings.JOYPAD_B,
	"RETRO_JOYPAD_START":  ControllerBindings.JOYPAD_START,
	"RETRO_JOYPAD_SELECT": ControllerBindings.JOYPAD_SELECT,
	"RETRO_JOYPAD_UP":     ControllerBindings.JOYPAD_UP,
	"RETRO_JOYPAD_DOWN":   ControllerBindings.JOYPAD_DOWN,
	"RETRO_JOYPAD_LEFT":   ControllerBindings.JOYPAD_LEFT,
	"RETRO_JOYPAD_RIGHT":  ControllerBindings.JOYPAD_RIGHT,
}

## Nerd Font: gamepad — floats off the card while capture is on.
const ICON_CAPTURE := 0xEC17
const ICON_SIZE := 0.020

var _card: Node3D = null
## Every controller with a hand on the card, in the order they took it.
var _holders: Array[XRController3D] = []
var _desktop_held := false
var _capture: ScrollLockCapture = null
var _pointer_block := VrPointerBlock.new()
var _locomotion: LocomotionManager = null
var _left_ctrl: XRController3D = null
var _right_ctrl: XRController3D = null
var _latch := InputLatch.new()
## Whether the hand blocks are on. Flipped only when the answer changes.
var _active := false
var _last_mask := 0


static func attach(card: Node3D) -> VmuInput:
	var n := VmuInput.new()
	n.name = "VmuInput"
	n._card = card
	card.add_child(n)
	return n


func _ready() -> void:
	if _card == null:
		return
	_card.grabbed.connect(_on_grabbed)
	_card.released.connect(_on_released)
	_card.dropped.connect(_on_dropped)
	_capture = ScrollLockCapture.attach(_card, _can_capture, ICON_CAPTURE, ICON_SIZE)
	call_deferred("_find_rig")


func _find_rig() -> void:
	var rig := PadInputShared.find_rig(get_tree())
	_locomotion = rig["locomotion"]
	_left_ctrl = rig["left"]
	_right_ctrl = rig["right"]


func _exit_tree() -> void:
	_pointer_block.release(_left_ctrl, _right_ctrl)
	if _locomotion != null:
		_locomotion.clear_owner(VrHold.vr_block_owner(self))
	if _capture:
		_capture.release()


# --- Who is holding it --------------------------------------------------------

func _on_grabbed(_pickable: Node3D, by: Node3D) -> void:
	var pickup := by as XRToolsFunctionPickup
	var ctrl: XRController3D = pickup.get_controller() if pickup else null
	if ctrl == null:
		if by.is_in_group("desktop_hand"):
			_desktop_held = true
		return
	if not _holders.has(ctrl):
		_holders.append(ctrl)


func _on_released(_pickable: Node3D, by: Node3D) -> void:
	var pickup := by as XRToolsFunctionPickup
	var ctrl: XRController3D = pickup.get_controller() if is_instance_valid(pickup) else null
	if ctrl != null:
		_holders.erase(ctrl)
		_pointer_block.set_block(ctrl, false)


func _on_dropped(_pickable: Node3D) -> void:
	for ctrl in _holders:
		if is_instance_valid(ctrl):
			_pointer_block.set_block(ctrl, false)
	_holders.clear()
	_desktop_held = false
	_latch.clear()


## Hands on the card, for the probes and the tests.
func holders() -> Array[XRController3D]:
	return _holders


# --- The mask -----------------------------------------------------------------

## The RetroPad bits for one hand's state. Pure, so the mapping can be checked
## without a controller in the room.
static func mask_from(a: bool, b: bool, mode: bool, sleep: bool, stick: Vector2) -> int:
	var m := 0
	if a:
		m |= 1 << ControllerBindings.JOYPAD_A
	if b:
		m |= 1 << ControllerBindings.JOYPAD_B
	if mode:
		m |= 1 << ControllerBindings.JOYPAD_START
	if sleep:
		m |= 1 << ControllerBindings.JOYPAD_SELECT
	m |= PadInputShared.threshold_to_dpad(stick)
	return m


## The bits one controller is pressing, with the same hysteresis a handheld
## applies so a single squeeze does not reach the core as two presses.
func mask_for(ctrl: XRController3D) -> int:
	if not is_instance_valid(ctrl):
		return 0
	var id := ctrl.get_instance_id()
	var a := _latch.pressed("%d:ax_button" % id, ctrl.get_float("ax_button"),
		INPUT_THRESHOLDS["ax_button"])
	var b := _latch.pressed("%d:by_button" % id, ctrl.get_float("by_button"),
		INPUT_THRESHOLDS["by_button"])
	var mode := _latch.pressed("%d:primary_click" % id, ctrl.get_float("primary_click"),
		INPUT_THRESHOLDS["primary_click"])
	var sleep := _latch.pressed("%d:trigger" % id, ctrl.get_float("trigger"),
		INPUT_THRESHOLDS["trigger"])
	return mask_from(a, b, mode, sleep, ctrl.get_vector2("primary"))


func _desktop_mask() -> int:
	if _capture == null or not _capture.is_active():
		return 0
	var m := 0
	for action: String in DESKTOP_BUTTON_MAP:
		if Input.is_action_pressed(action):
			m |= 1 << int(DESKTOP_BUTTON_MAP[action])
	return m


func _running() -> bool:
	return _card != null and _card.has_method("is_running_standalone") \
		and bool(_card.call("is_running_standalone"))


func _held() -> bool:
	return _desktop_held or not _holders.is_empty()


## Capture is only meaningful on desktop, and only while there is a game to
## take the keys.
func _can_capture() -> bool:
	return _desktop_held and _running()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or key.is_echo() or _capture == null:
		return
	if _capture.handle_key(key):
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if _card == null:
		return
	var active := _running() and _held()
	if active != _active:
		_set_active(active)
	if not active:
		if _last_mask != 0:
			_last_mask = 0
			_card.call("set_input", 0)
		return
	var mask := 0
	if _desktop_held:
		mask = _desktop_mask()
	for ctrl in _holders:
		mask |= mask_for(ctrl)
	if mask != _last_mask:
		_last_mask = mask
		_card.call("set_input", mask)


## The stick is the d-pad and the trigger is SLEEP, so while a game is running
## neither may also walk the player or fire the ray at whatever is behind the
## card. Per-instance owner key, never a shared literal: the manager erases a
## block by key, and a room can hold eight of these.
func _set_active(on: bool) -> void:
	_active = on
	_latch.clear()
	for ctrl in _holders:
		if is_instance_valid(ctrl):
			_pointer_block.set_block(ctrl, on)
	if _locomotion != null:
		var owner_key := VrHold.vr_block_owner(self)
		var left := false
		var right := false
		if on:
			for ctrl in _holders:
				if not is_instance_valid(ctrl):
					continue
				if ctrl.tracker == &"left_hand":
					left = true
				elif ctrl.tracker == &"right_hand":
					right = true
		_locomotion.set_block(owner_key, LocomotionManager.CHANNEL_LEFT, left)
		_locomotion.set_block(owner_key, LocomotionManager.CHANNEL_RIGHT, right)
	if _capture:
		_capture.refresh()

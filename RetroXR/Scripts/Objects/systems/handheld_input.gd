## HandheldInput — drives port 0 of a handheld RetroSystem while it is held.
##
## The held device IS the controller: VR controller buttons/sticks map to the
## game via the per-system ControllerBindings, the ONE physical gamepad this
## machine's Controllers panel selects merges in, and desktop mode uses the
## keyboard actions — the same pipeline as
## retro_controller.gd (adapted copy; the controller stays untouched because
## it is battle-tested). Also provides toggle-hold comfort (grip toggles the
## grab instead of holding it), pointer/locomotion blocking while held, the
## grip+trigger+stick-click drop combo, and rumble to the holding hands.
##
## Added as a child of the RetroSystem by system.gd when the model
## is_handheld(); registers itself as the port-0 "controller" so the system's
## existing rumble routing reaches it.
class_name HandheldInput
extends Node

const DPAD_THRESHOLD := 0.35
const ANALOG_SCALE := 0x7fff

const INPUT_THRESHOLDS: Dictionary = {
	"ax_button":     0.5,
	"by_button":     0.5,
	"primary_click": 0.5,
	"grip":          0.3,
	"trigger":       0.3,
}

const DESKTOP_BUTTON_MAP: Dictionary = {
	"RETRO_JOYPAD_B":      ControllerBindings.JOYPAD_B,
	"RETRO_JOYPAD_Y":      ControllerBindings.JOYPAD_Y,
	"RETRO_JOYPAD_SELECT": ControllerBindings.JOYPAD_SELECT,
	"RETRO_JOYPAD_START":  ControllerBindings.JOYPAD_START,
	"RETRO_JOYPAD_UP":     ControllerBindings.JOYPAD_UP,
	"RETRO_JOYPAD_DOWN":   ControllerBindings.JOYPAD_DOWN,
	"RETRO_JOYPAD_LEFT":   ControllerBindings.JOYPAD_LEFT,
	"RETRO_JOYPAD_RIGHT":  ControllerBindings.JOYPAD_RIGHT,
	"RETRO_JOYPAD_A":      ControllerBindings.JOYPAD_A,
	"RETRO_JOYPAD_X":      ControllerBindings.JOYPAD_X,
	"RETRO_JOYPAD_L":      ControllerBindings.JOYPAD_L,
	"RETRO_JOYPAD_R":      ControllerBindings.JOYPAD_R,
	"RETRO_JOYPAD_L2":     ControllerBindings.JOYPAD_L2,
	"RETRO_JOYPAD_R2":     ControllerBindings.JOYPAD_R2,
	"RETRO_JOYPAD_L3":     ControllerBindings.JOYPAD_L3,
	"RETRO_JOYPAD_R3":     ControllerBindings.JOYPAD_R3,
}

var _host: Node3D = null   # the RetroSystem (XRToolsPickable)

var _button_map: Dictionary = ControllerBindings.DEFAULT_BUTTON_MAP.duplicate()
var _stick_map:  Dictionary = ControllerBindings.DEFAULT_STICK_MAP.duplicate()
var _pad_button_map: Dictionary = GamepadBindings.DEFAULT_BUTTON_MAP.duplicate()
var _pad_stick_map:  Dictionary = GamepadBindings.DEFAULT_STICK_MAP.duplicate()

# Toggle-hold state (mirrors retro_controller.gd).
var _allow_drop := false
var _saved_by: Node3D = null
var _holding_ctrl: XRController3D = null
var _desktop_held := false
## Scroll Lock capture: while on, keyboard-bound RETRO_JOYPAD_* actions drive this
## handheld instead of the player. The selected physical pad is never gated by it.
var _capture: ScrollLockCapture = null
var _hint: HeldHint = null
## Nerd Font: gamepad — floats off the near edge of the handheld while capture is on.
const ICON_CAPTURE := 0xEC17
const ICON_SIZE := 0.030
## Height of the hint popup above the handheld, in metres.
const HINT_HEIGHT := 0.20
## Hides the ray pointer on whichever hand is holding this, so a grab
## gesture cannot also fire the pointer at whatever is behind it.
var _pointer_block := VrPointerBlock.new()

## Haptics, shared with retro_controller.gd — see PadInputShared.
var _rumble := PadInputShared.Rumble.new(self)

var _locomotion_manager: LocomotionManager = null
var _spawn_menu_ctrl: Node = null
var _left_vr_ctrl: XRController3D = null
var _right_vr_ctrl: XRController3D = null


func setup(host: Node3D) -> void:
	_host = host
	_load_bindings()
	host.press_to_hold = false
	host.grabbed.connect(_on_grabbed_signal)
	host.dropped.connect(_on_dropped_signal)
	host.released.connect(_on_released_signal)
	_capture = ScrollLockCapture.attach(host, _can_capture,
		ICON_CAPTURE, ICON_SIZE)
	_hint = HeldHint.attach(host, true, HINT_HEIGHT)
	_hint.add_row(&"capture", HeldHint.PLATFORM_DESKTOP,
		["keyboard_scroll_lock_outline"], "or F3 — send keys here")


func _ready() -> void:
	add_to_group(ControllerBindings.CONSUMER_GROUP)
	call_deferred("_find_vr_nodes")


## Reload bindings from disk (called after the user saves new bindings).
func reload_bindings() -> void:
	_load_bindings()


func _find_vr_nodes() -> void:
	var rig := PadInputShared.find_rig(get_tree())
	_locomotion_manager = rig["locomotion"]
	_spawn_menu_ctrl = rig["spawn_menu"]
	_left_vr_ctrl = rig["left"]
	_right_vr_ctrl = rig["right"]
	# A spawn-menu spawn is handed to the grabbing hand before this deferred lookup
	# runs, so that grab found no manager and never blocked locomotion. Re-apply.
	_update_locomotion_block()


func _load_bindings() -> void:
	var systemid := str(_host.get("systemid")) if _host else ""
	var bindings := ControllerBindings.get_for_system(systemid)
	_button_map = bindings["buttons"]
	_stick_map = bindings["sticks"]
	var pad := GamepadBindings.get_for_system(systemid)
	_pad_button_map = pad["buttons"]
	_pad_stick_map = pad["sticks"]


func _get_secondary_ctrl() -> XRController3D:
	var driver: Variant = VrHold.grab_driver(_host)
	if driver and driver.secondary:
		return driver.secondary.controller
	return null


# ── Toggle-hold (adapted from retro_controller.gd) ────────────────────────────

func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	if _hint:
		_hint.on_grabbed(by)
	var pickup := by as XRToolsFunctionPickup
	var ctrl := pickup.get_controller() if pickup else null as XRController3D
	if ctrl == null:
		if by.is_in_group("desktop_hand"):
			_desktop_held = true
		return
	if not is_instance_valid(_holding_ctrl):
		_saved_by = by
		_holding_ctrl = ctrl
	_update_pointer_block(ctrl, true)
	_update_locomotion_block()
	_apply_rumble()
	_refresh_grip()


## Anchor each holding hand onto its own grip: one hand takes the device by that
## side, two hands centre it between them. The anchors come from the handheld
## model's body (RetroSystem.grip_anchor). See GripAnchor.
func _refresh_grip() -> void:
	GripAnchor.refresh(_host as XRToolsPickable, _host)


func _on_released_signal(_pickable: Node3D, by: Node3D) -> void:
	var pickup := by as XRToolsFunctionPickup
	if not is_instance_valid(pickup):
		return
	var ctrl: XRController3D = pickup.get_controller()
	if ctrl == null:
		return
	if _allow_drop:
		_update_pointer_block(ctrl, false)
		if ctrl == _holding_ctrl:
			var driver: Variant = VrHold.grab_driver(_host)
			if driver and driver.primary:
				_holding_ctrl = driver.primary.controller
				_saved_by = driver.primary.by
			else:
				_holding_ctrl = null
				_saved_by = null
		_update_locomotion_block()
		_apply_rumble()
		# Back to one hand → the survivor takes the device by its own grip.
		_refresh_grip()
		return
	# Toggle grip — rehold the released hand.
	if ctrl == _holding_ctrl:
		var driver: Variant = VrHold.grab_driver(_host)
		if driver and driver.primary:
			_holding_ctrl = driver.primary.controller
			_saved_by = driver.primary.by
			PokeTip.begin_rehold(ctrl)
			call_deferred("_rehold_hand", by)
	else:
		PokeTip.begin_rehold(ctrl)
		call_deferred("_rehold_hand", by)
	_refresh_grip()


func _on_dropped_signal(_pickable: Node3D) -> void:
	if not _allow_drop and is_instance_valid(_saved_by):
		PokeTip.begin_rehold(_holding_ctrl)
		call_deferred("_rehold")
	else:
		if _hint:
			_hint.on_dropped()
		_allow_drop = false
		_update_pointer_block(_holding_ctrl, false)
		_saved_by = null
		_holding_ctrl = null
		_desktop_held = false
		_update_locomotion_block()
		_apply_rumble()
		_zero_port()


func _rehold() -> void:
	if _allow_drop:
		_allow_drop = false
		return
	if not is_instance_valid(_saved_by):
		_update_pointer_block(_holding_ctrl, false)
		_saved_by = null
		_holding_ctrl = null
		_update_locomotion_block()
		return
	_saved_by.call("_pick_up_object", _host)


func _rehold_hand(by: Node3D) -> void:
	if _allow_drop or not is_instance_valid(by):
		return
	by.call("_pick_up_object", _host)


## The combo test itself lives on HeldHint so the check and the row advertising
## it cannot disagree. Counting the use here rather than at each drop branch is
## deliberate: every one of them drops, and a predicate they all pass through
## cannot be missed when another is added. HeldHint counts once per hold, so
## testing every frame does not inflate it.
func _is_combo_pressed(ctrl: XRController3D) -> bool:
	return PadInputShared.combo_pressed(ctrl, _hint)


var _combo_dbg := PadInputShared.ComboDebug.new()

func _combo_debug(ctrl: XRController3D) -> void:
	_combo_dbg.log_change(ctrl, name)


func _drop_all() -> void:
	_update_pointer_block(_holding_ctrl, false)
	var secondary := _get_secondary_ctrl()
	if is_instance_valid(secondary):
		_update_pointer_block(secondary, false)
	_allow_drop = true
	_holding_ctrl = null
	_update_locomotion_block()
	_host.call("drop")


func _exit_tree() -> void:
	_pointer_block.release(_left_vr_ctrl, _right_vr_ctrl)
	XRToolsRumbleManager.clear(self)
	_rumble.stop_pads()
	if _locomotion_manager != null:
		_locomotion_manager.clear_owner(VrHold.vr_block_owner(self))
	if _capture:
		_capture.release()


func _update_locomotion_block() -> void:
	var secondary := _get_secondary_ctrl()
	var left_held := (is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"left_hand") \
				  or (is_instance_valid(secondary) and secondary.tracker == &"left_hand")
	var right_held := (is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"right_hand") \
				   or (is_instance_valid(secondary) and secondary.tracker == &"right_hand")
	if _locomotion_manager != null:
		# Per-instance, never a shared literal. LocomotionManager erases a block
		# BY KEY, so two handhelds sharing one key erase each other's claim --
		# and a room can hold several, which is the whole premise of a link
		# cable. One put down would have freed the hand still holding the other.
		var owner_key := VrHold.vr_block_owner(self)
		_locomotion_manager.set_block(owner_key, LocomotionManager.CHANNEL_LEFT, left_held)
		_locomotion_manager.set_block(owner_key, LocomotionManager.CHANNEL_RIGHT, right_held)
	# The desktop side is ScrollLockCapture's: it blocks WASD only while captured,
	# and losing the grip here makes it ineligible, which drops both.
	if _capture:
		_capture.refresh()
	if is_instance_valid(_spawn_menu_ctrl) and "disabled" in _spawn_menu_ctrl:
		_spawn_menu_ctrl.set("disabled", left_held)


## Delegates to VrPointerBlock, which owns the shared refcount.
func _update_pointer_block(ctrl: XRController3D, should_block: bool) -> void:
	_pointer_block.set_block(ctrl, should_block)


# ── Input forwarding (adapted from retro_controller.gd) ───────────────────────

func _process(_delta: float) -> void:
	if _host == null:
		return

	# Drop combo: evaluated even while the system is powered OFF — the gate
	# below is for game-input forwarding only. (A powered-off handheld used to
	# be undroppable because this whole function bailed before the combo check.)
	var secondary := _get_secondary_ctrl()
	_combo_debug(_holding_ctrl)
	# Drop combo: each hand only releases itself.
	if _is_combo_pressed(secondary):
		_allow_drop = true
		_update_pointer_block(secondary, false)
		var driver: Variant = VrHold.grab_driver(_host)
		if driver and driver.secondary:
			driver.secondary.pickup.drop_object()
		_allow_drop = false
		_update_locomotion_block()
	elif _is_combo_pressed(_holding_ctrl):
		if is_instance_valid(secondary):
			_allow_drop = true
			_update_pointer_block(_holding_ctrl, false)
			if is_instance_valid(_saved_by):
				_saved_by.call("drop_object")
			_allow_drop = false
			_update_locomotion_block()
		else:
			_drop_all()
			return

	if not bool(_host.get("is_powered_on")):
		return

	if _desktop_held:
		_process_desktop_joypad()
		return
	if not is_instance_valid(_holding_ctrl):
		_send_joypad(0, 0, 0, 0, 0)
		return

	var ctrl := _holding_ctrl
	var left_hand := ctrl.tracker == &"left_hand"
	var btn: int = _apply_buttons_for_ctrl(ctrl, left_hand)
	if is_instance_valid(secondary):
		btn |= _apply_buttons_for_ctrl(secondary, secondary.tracker == &"left_hand")

	var left_ctrl := ctrl if left_hand else secondary
	var right_ctrl := ctrl if not left_hand else secondary
	var lstick: Vector2 = left_ctrl.get_vector2("primary") if is_instance_valid(left_ctrl) else Vector2.ZERO
	var rstick: Vector2 = right_ctrl.get_vector2("primary") if is_instance_valid(right_ctrl) else Vector2.ZERO

	var alx := 0; var aly := 0
	var arx := 0; var ary := 0
	var lt: String = _stick_map.get("stick_left",  "left+dpad")
	var rt: String = _stick_map.get("stick_right", "right")
	if "left"  in lt: alx = int(lstick.x * ANALOG_SCALE); aly = int(-lstick.y * ANALOG_SCALE)
	elif "right" in lt: arx = int(lstick.x * ANALOG_SCALE); ary = int(-lstick.y * ANALOG_SCALE)
	if "dpad" in lt: btn |= _threshold_to_dpad(lstick)
	if "right" in rt: arx = int(rstick.x * ANALOG_SCALE); ary = int(-rstick.y * ANALOG_SCALE)
	elif "left" in rt: alx = int(rstick.x * ANALOG_SCALE); aly = int(-rstick.y * ANALOG_SCALE)
	if "dpad" in rt: btn |= _threshold_to_dpad(rstick)

	var m := _merge_pad_state(btn, alx, aly, arx, ary)
	_send_joypad(m["btn"], m["alx"], m["aly"], m["arx"], m["ary"])


## Hysteresis for the analog sources — see InputLatch. Without it a single
## squeeze reaches the core as two presses.
var _latch := InputLatch.new()


func _apply_buttons_for_ctrl(ctrl: XRController3D, left_hand: bool) -> int:
	var bits: int = 0
	for full_source: String in _button_map:
		var bit: int = _button_map[full_source]
		if bit < 0:
			continue
		var vr_input: String
		if full_source.begins_with("right_"):
			if left_hand:
				continue
			vr_input = full_source.substr(6)
		elif full_source.begins_with("left_"):
			if not left_hand:
				continue
			vr_input = full_source.substr(5)
		else:
			vr_input = full_source
		var threshold: float = INPUT_THRESHOLDS.get(vr_input, 0.5)
		var key := "%d:%s" % [ctrl.get_instance_id(), vr_input]
		if _latch.pressed(key, ctrl.get_float(vr_input), threshold):
			bits |= (1 << bit)
	return bits


## Capture is only meaningful on desktop: in VR the handheld reads the hand
## controllers, never the keyboard-bound actions.
func _can_capture() -> bool:
	return _desktop_held and _host != null and bool(_host.get("is_powered_on"))


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or key.is_echo() or _capture == null:
		return
	if _capture.handle_key(key):
		get_viewport().set_input_as_handled()


func _process_desktop_joypad() -> void:
	var btn: int = 0
	# Keyboard-bound buttons only while captured — otherwise WASD and friends
	# still belong to the player. The selected pad is merged in regardless.
	if _capture == null or not _capture.is_active():
		var idle := _merge_pad_state(0, 0, 0, 0, 0)
		_send_joypad(idle["btn"], idle["alx"], idle["aly"], idle["arx"], idle["ary"])
		return
	for action: String in DESKTOP_BUTTON_MAP:
		if Input.is_action_pressed(action):
			btn |= (1 << int(DESKTOP_BUTTON_MAP[action]))
	var lx := Input.get_axis("RETRO_ANALOG_LEFT_X_NEGATIVE",  "RETRO_ANALOG_LEFT_X_POSITIVE")
	var ly := Input.get_axis("RETRO_ANALOG_LEFT_Y_NEGATIVE",  "RETRO_ANALOG_LEFT_Y_POSITIVE")
	var rx := Input.get_axis("RETRO_ANALOG_RIGHT_X_NEGATIVE", "RETRO_ANALOG_RIGHT_X_POSITIVE")
	var ry := Input.get_axis("RETRO_ANALOG_RIGHT_Y_NEGATIVE", "RETRO_ANALOG_RIGHT_Y_POSITIVE")
	var m := _merge_pad_state(btn,
		int(lx * ANALOG_SCALE), int(-ly * ANALOG_SCALE),
		int(rx * ANALOG_SCALE), int(-ry * ANALOG_SCALE))
	_send_joypad(m["btn"], m["alx"], m["aly"], m["arx"], m["ary"])


## Merge the SELECTED physical pad into the current (VR or keyboard) state.
##
## A handheld has no controller port — system.gd gives it port_count = 0 — so
## there is nowhere to plug a PadReceiver in, and the pad is chosen from this
## machine's own Controllers panel instead. That choice is the whole of the
## routing: an unset or disconnected selection merges nothing.
##
## Buttons OR together; each analog stick takes whichever source has the larger
## magnitude, so the real pad and the VR thumbstick don't fight.
func _merge_pad_state(btn: int, alx: int, aly: int, arx: int, ary: int) -> Dictionary:
	var device := GamepadBindings.resolve_device(_host.pad_guid, _host.pad_ordinal)
	var pad := GamepadBindings.poll(_pad_button_map, _pad_stick_map, device)
	btn |= int(pad["btn"])
	var plx: int = pad["alx"]
	var ply: int = pad["aly"]
	var prx: int = pad["arx"]
	var pry: int = pad["ary"]
	if plx * plx + ply * ply > alx * alx + aly * aly:
		alx = plx; aly = ply
	if prx * prx + pry * pry > arx * arx + ary * ary:
		arx = prx; ary = pry
	return {"btn": btn, "alx": alx, "aly": aly, "arx": arx, "ary": ary}


func _send_joypad(btn: int, alx: int, aly: int, arx: int, ary: int) -> void:
	# Drive the model's own physical controls (a handheld animating its buttons /
	# slide-pad from the same state it feeds the core). No-ops on models without it.
	var model: Object = _host.get_model() if _host.has_method("get_model") else null
	# Every source — VR controllers, a physical pad, the captured keyboard — lands
	# on the same bits, so the buttons the hardware never had are dropped here
	# rather than unbound in three separate maps.
	var sys_model := model as RetroSystemModel
	if sys_model != null:
		btn &= ~sys_model.get_unsupported_button_mask()
	if model != null and model.has_method("animate_controls"):
		model.animate_controls(btn,
			Vector2(float(alx) / ANALOG_SCALE, float(aly) / ANALOG_SCALE),
			Vector2(float(arx) / ANALOG_SCALE, float(ary) / ANALOG_SCALE))
	if NetworkManager.netplay_route(_host, 0, {"btn": btn, "alx": alx, "aly": aly, "arx": arx, "ary": ary}):
		return
	_host.get_libretro_node().SetJoypadState(0, btn, alx, aly, arx, ary)


func _zero_port() -> void:
	if _host and bool(_host.get("is_powered_on")):
		_send_joypad(0, 0, 0, 0, 0)


static func _threshold_to_dpad(stick: Vector2) -> int:
	return PadInputShared.threshold_to_dpad(stick)


# ── Rumble (adapted from retro_controller.gd; registered as the port-0
#    "controller" so system.gd's rumble routing reaches us) ────────────────────

func set_rumble(weak: float, strong: float) -> void:
	_rumble.set_levels(weak, strong, _holders(), _desktop_held)


func _apply_rumble() -> void:
	_rumble.apply(_holders(), _desktop_held)


## Every controller physically holding this handheld: the grabbing hand, plus
## the second one on a two-hand grab.
func _holders() -> Array:
	return [_holding_ctrl, _get_secondary_ctrl()]

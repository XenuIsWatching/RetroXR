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
var _blocking_left := false
var _blocking_right := false

# Rumble state (mirrors retro_controller.gd).
var _rumble_weak := 0.0
var _rumble_strong := 0.0
var _rumble_event: XRToolsRumbleEvent = null
var _pad_rumble_active := false

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
	_locomotion_manager = get_tree().root.find_child("LocomotionManager", true, false) as LocomotionManager
	_spawn_menu_ctrl = get_tree().root.find_child("SpawnMenuController", true, false)
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		var ctrl := node as XRController3D
		if ctrl == null:
			continue
		if ctrl.tracker == &"left_hand":
			_left_vr_ctrl = ctrl
		elif ctrl.tracker == &"right_hand":
			_right_vr_ctrl = ctrl
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
	var driver: Variant = _host.get("_grab_driver")
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
			var driver: Variant = _host.get("_grab_driver")
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
		var driver: Variant = _host.get("_grab_driver")
		if driver and driver.primary:
			_holding_ctrl = driver.primary.controller
			_saved_by = driver.primary.by
			call_deferred("_rehold_hand", by)
	else:
		call_deferred("_rehold_hand", by)
	_refresh_grip()


func _on_dropped_signal(_pickable: Node3D) -> void:
	if not _allow_drop and is_instance_valid(_saved_by):
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
	if not HeldHint.is_combo_pressed(ctrl):
		return false
	if _hint:
		_hint.note_used(&"drop_vr")
	return true


# Diagnostic for the "drop combo doesn't fire" report: log the three combo
# inputs whenever their combined state changes, so a logcat/console trace shows
# whether detection (e.g. primary_click never reading pressed) or the drop
# handling is at fault. State-change gated — silent while idle.
var _combo_dbg_state := -1

func _combo_debug(ctrl: XRController3D) -> void:
	if not is_instance_valid(ctrl):
		return
	var state := (1 if ctrl.get_float("grip") > 0.5 else 0) \
		| (2 if ctrl.get_float("trigger") > 0.5 else 0) \
		| (4 if ctrl.get_float("primary_click") > 0.5 else 0)
	if state != _combo_dbg_state:
		_combo_dbg_state = state
		print("[drop-combo] %s grip=%d trigger=%d stick_click=%d" % [name,
			state & 1, (state >> 1) & 1, (state >> 2) & 1])


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
	if _blocking_left and is_instance_valid(_left_vr_ctrl):
		_update_pointer_block(_left_vr_ctrl, false)
	if _blocking_right and is_instance_valid(_right_vr_ctrl):
		_update_pointer_block(_right_vr_ctrl, false)
	XRToolsRumbleManager.clear(self)
	if _pad_rumble_active:
		for device in GamepadBindings.usable_pads():
			Input.stop_joy_vibration(device)
		_pad_rumble_active = false
	if _locomotion_manager != null:
		_locomotion_manager.set_block(&"handheld_hold", LocomotionManager.CHANNEL_LEFT, false)
		_locomotion_manager.set_block(&"handheld_hold", LocomotionManager.CHANNEL_RIGHT, false)
	if _capture:
		_capture.release()


func _update_locomotion_block() -> void:
	var secondary := _get_secondary_ctrl()
	var left_held := (is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"left_hand") \
				  or (is_instance_valid(secondary) and secondary.tracker == &"left_hand")
	var right_held := (is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"right_hand") \
				   or (is_instance_valid(secondary) and secondary.tracker == &"right_hand")
	if _locomotion_manager != null:
		_locomotion_manager.set_block(&"handheld_hold", LocomotionManager.CHANNEL_LEFT, left_held)
		_locomotion_manager.set_block(&"handheld_hold", LocomotionManager.CHANNEL_RIGHT, right_held)
	# The desktop side is ScrollLockCapture's: it blocks WASD only while captured,
	# and losing the grip here makes it ineligible, which drops both.
	if _capture:
		_capture.refresh()
	if is_instance_valid(_spawn_menu_ctrl) and "disabled" in _spawn_menu_ctrl:
		_spawn_menu_ctrl.set("disabled", left_held)


## Reference-counted pointer blocking (same contract as retro_controller.gd).
func _update_pointer_block(ctrl: XRController3D, should_block: bool) -> void:
	if not is_instance_valid(ctrl):
		return
	var is_left := ctrl.tracker == &"left_hand"
	var currently: bool = _blocking_left if is_left else _blocking_right
	if should_block == currently:
		return
	if is_left:
		_blocking_left = should_block
	else:
		_blocking_right = should_block
	var pointer: Node3D = ctrl.get_node_or_null("FunctionPointer")
	if not pointer:
		return
	var delta := 1 if should_block else -1
	var count: int = maxi(0, pointer.get_meta("block_count", 0) + delta)
	pointer.set_meta("block_count", count)
	pointer.visible = count == 0
	var ray: RayCast3D = pointer.get_node_or_null("RayCast") as RayCast3D
	if ray:
		ray.enabled = count == 0


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
		var driver: Variant = _host.get("_grab_driver")
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
	var bits := 0
	if stick.y >  DPAD_THRESHOLD: bits |= (1 << 4)
	if stick.y < -DPAD_THRESHOLD: bits |= (1 << 5)
	if stick.x < -DPAD_THRESHOLD: bits |= (1 << 6)
	if stick.x >  DPAD_THRESHOLD: bits |= (1 << 7)
	return bits


# ── Rumble (adapted from retro_controller.gd; registered as the port-0
#    "controller" so system.gd's rumble routing reaches us) ────────────────────

func set_rumble(weak: float, strong: float) -> void:
	_rumble_weak = weak
	_rumble_strong = strong
	_apply_rumble()


func _apply_rumble() -> void:
	var combined: float = XRToolsRumbleManager.combine_magnitudes(_rumble_weak, _rumble_strong)
	XRToolsRumbleManager.clear(self)
	var secondary := _get_secondary_ctrl()
	var is_held: bool = is_instance_valid(_holding_ctrl) or is_instance_valid(secondary) or _desktop_held
	if not is_held or combined <= 0.0:
		if _pad_rumble_active:
			for device in GamepadBindings.usable_pads():
				Input.stop_joy_vibration(device)
			_pad_rumble_active = false
		return
	if is_instance_valid(_holding_ctrl) or is_instance_valid(secondary):
		if _rumble_event == null:
			_rumble_event = XRToolsRumbleEvent.new()
			_rumble_event.indefinite = true
		_rumble_event.magnitude = combined
		var trackers: Array = []
		if is_instance_valid(_holding_ctrl):
			trackers.append(_holding_ctrl.tracker)
		if is_instance_valid(secondary):
			trackers.append(secondary.tracker)
		if not trackers.is_empty():
			XRToolsRumbleManager.add(self, _rumble_event, trackers)
	if is_held:
		for device in GamepadBindings.usable_pads():
			Input.start_joy_vibration(device, _rumble_weak, _rumble_strong, 0.0)
		_pad_rumble_active = true

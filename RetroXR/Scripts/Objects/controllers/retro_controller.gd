## RetroController — pickable joypad that plugs into a RetroSystem controller port.
## Grip once to toggle-hold; grip+trigger+thumbstick-click to drop.
## While held and plugged in, VR controller input routes to the assigned port.
## Button and analog mappings are data-driven via ControllerBindings.
class_name RetroController
extends XRToolsPickable


const CONTROLLER_CABLE_SCENE := preload("res://Scenes/Objects/cables/controller_cable.tscn")
const RETRO_DEVICE_JOYPAD := 1

const DPAD_THRESHOLD      := 0.35
const ANALOG_SCALE        := 0x7fff

## Input thresholds per XRController float input name.
const INPUT_THRESHOLDS: Dictionary = {
	"ax_button":     0.5,
	"by_button":     0.5,
	"primary_click": 0.5,
	"grip":          0.3,
	"trigger":       0.3,
}

## libretro device type reported to the system when plugged in.
var device_type: int = RETRO_DEVICE_JOYPAD

## Preferred per-port "pad type" core-option value. When this controller is
## plugged into a system whose core exposes a per-port pad-type option (e.g.
## PCSX-ReARMed's `pcsx_rearmed_padNtype`), RetroSystem auto-selects this value.
## Digital pads leave it at "standard"; the analog DualShock scenes set
## "dualshock". No-ops on cores without such an option.
@export var pad_type_pref: String = "standard"

## Mesh resource for this controller's cable connector, or "" for the generic
## cylinder plug. Console pads point this at their real connector — see
## Tools/gen/extract_nes_plug.gd. The mesh must be authored in ControllerPlug's frame
## (origin at the seated position, connector on +Z, cable trailing -Z), which is
## what lets set_plug_mesh derive cable_anchor from it. A missing resource falls
## back to the generic plug, so an export-excluded model never breaks a build.
@export var plug_mesh_path: String = ""

## The systemid this controller physically belongs to, e.g. "super_nes". A port
## only accepts a plug whose controller matches (see RetroSystem._accepts_plug),
## the same way the cartridge slot only accepts media for its own system.
##
## Empty means UNIVERSAL and fits anything — that is deliberate for RetroXR's own
## props (the generic pad, keyboard, mouse, multitap, light gun), which stand in for
## hardware we have no model of and must keep working on every system.
@export var systemid: String = ""

## Cord length in metres, or 0 to keep whatever controller_cable.tscn ships
## (50 x 36 mm = 1.80 m). Real hardware varies a lot — a CX40's lead is far
## shorter than an SNES pad's — and the cable scene is shared by every
## controller, so the length belongs on the controller rather than in it.
##
## Applied by resizing the segment COUNT, not the segment length: the rope's
## boot taper and minimum bend radius were tuned against a ~36 mm segment, and
## stretching segments instead would quietly change how the whole cord hangs.
## The segment length is then trimmed by under a percent to hit the asked-for
## length exactly rather than landing on the nearest whole segment.
@export var cable_length: float = 0.0

# Port connection state
var _connected_system: RetroSystem = null
var _port_index: int = -1


## The console this peripheral is plugged into, or null. Part of the port-
## peripheral contract ScenePersistence and NetObjectSync ask for by method
## rather than by field name.
func get_connected_system() -> RetroSystem:
	return _connected_system if is_instance_valid(_connected_system) else null


## Which port of that console it occupies, or -1 when unplugged.
func get_port_index() -> int:
	return _port_index

# Active bindings (loaded from ControllerBindings on plug-in)
var _button_map: Dictionary = ControllerBindings.DEFAULT_BUTTON_MAP.duplicate()
var _stick_map:  Dictionary = ControllerBindings.DEFAULT_STICK_MAP.duplicate()

# Cable
var _cable_instance: Node3D = null


## The captive cable spawned for this pad, or null. Parented to the scene root
## rather than to the pad, so anything that disposes of the pad — the storage
## box, a despawn — has to dispose of this too or leave an orphaned rope.
func cable_instance() -> Node3D:
	return _cable_instance
var _cable_plug: ControllerPlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0

# Pending port restore (set before cable is ready)
var _pending_port_restore: Dictionary = {}

# Toggle-hold state
var _allow_drop := false
var _saved_by: Node3D = null
var _holding_ctrl: XRController3D = null    # primary holder
var _desktop_held: bool = false
## Scroll Lock capture: while on, keyboard-bound RETRO_JOYPAD_* actions drive this
## pad instead of the player. A physical USB/Bluetooth pad is never gated by it.
var _capture: ScrollLockCapture = null
var _hint: HeldHint = null
## Nerd Font: gamepad — floats off the near edge of the pad while capture is on.
const ICON_CAPTURE := 0xEC17
const ICON_SIZE := 0.030
## Height of the hint popup above the pad, in metres.
const HINT_HEIGHT := 0.20

## Hides the ray pointer on whichever hand is holding this, so a grab
## gesture cannot also fire the pointer at whatever is behind it.
var _pointer_block := VrPointerBlock.new()

## Keyboard action → RETRO_JOYPAD bit index for desktop mode.
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

var _locomotion_manager: LocomotionManager = null
var _spawn_menu_ctrl: Node = null
var _left_vr_ctrl: XRController3D = null
var _right_vr_ctrl: XRController3D = null

## Haptics, shared with handheld_input.gd — see PadInputShared. Levels are
## pushed in from RetroSystem._on_rumble_state_changed, normalized 0.0..1.0.
var _rumble := PadInputShared.Rumble.new(self)

@onready var _cable_attach_point: Node3D = $CableAttachPoint


func _ready() -> void:
	super._ready()
	press_to_hold = false
	second_hand_grab = SecondHandGrab.SECOND
	add_to_group("spawned")
	add_to_group(ControllerBindings.CONSUMER_GROUP)
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	released.connect(_on_released_signal)
	_spawn_cable()
	_capture = ScrollLockCapture.attach(self, _can_capture,
		ICON_CAPTURE, ICON_SIZE)
	_hint = HeldHint.attach(self, true, HINT_HEIGHT)
	_hint.add_row(&"capture", HeldHint.PLATFORM_DESKTOP,
		["keyboard_scroll_lock_outline"], "or F3 — send keys here")
	call_deferred("_find_vr_nodes")


func _find_vr_nodes() -> void:
	var rig := PadInputShared.find_rig(get_tree())
	_locomotion_manager = rig["locomotion"]
	_spawn_menu_ctrl = rig["spawn_menu"]
	_left_vr_ctrl = rig["left"]
	_right_vr_ctrl = rig["right"]
	# A spawn-menu spawn is handed to the grabbing hand before this deferred lookup
	# runs, so that grab found no manager and never blocked locomotion. Re-apply.
	_update_locomotion_block()


## Returns the XRController3D of the secondary (two-hand) grab, or null.
func _get_secondary_ctrl() -> XRController3D:
	if _grab_driver and _grab_driver.secondary:
		return _grab_driver.secondary.controller
	return null


## RetroController drops only via the grip+trigger+stick combo, so a plain grip
## press on a hand already holding it must be ignored — otherwise XRToolsFunctionPickup
## would toggle-drop and the custom re-grab would pop the pose. Queried by the
## LOCAL PATCH in function_pickup._on_grip_pressed.
func wants_grip_toggle_drop() -> bool:
	return false


## Both the trigger and the thumbstick are game inputs while this is held (L2/R2
## and the analog stick + d-pad), so the push-out gesture has nothing to bind to.
## Catching one back off the laser still works. Queried by
## function_pickup._handoff_eligible.
func wants_ray_handoff() -> bool:
	return false


## Anchor each holding hand onto its own grip: one hand takes the controller by
## that side, two hands centre it between them. See GripAnchor.
func _refresh_grip() -> void:
	GripAnchor.refresh(self, self)


## Where a hand grips this controller, in controller-local space. The authored
## HandLeft/HandRight nodes are the source — the same transform that places the
## wrap-around hand mesh (controller_model.gd), so the drawn hand sits on the
## real one. Null when the scene carries no such node.
func grip_anchor(is_left: bool) -> Variant:
	var hand := get_node_or_null(^"HandLeft" if is_left else ^"HandRight") as Node3D
	if hand == null:
		return null
	return hand.transform


# ── Cable ─────────────────────────────────────────────────────────────────────

func _spawn_cable() -> void:
	_cable_instance = CONTROLLER_CABLE_SCENE.instantiate()
	call_deferred("_add_cable_to_scene")


## Resize the cord to `cable_length`, before _init_points lays the particles out.
##
## Segment COUNT carries the length; the segment length is then nudged by well
## under a percent so the total is exact instead of rounding to a whole segment.
## Doing it the other way — same count, longer segments — would move the boot
## taper and the minimum bend radius, which are tuned in millimetres.
func _resize_cable() -> void:
	if _cable_rope == null or cable_length <= 0.0:
		return
	var seg: float = _cable_rope.segment_length
	if seg <= 0.0:
		return
	var count: int = maxi(2, int(round(cable_length / seg)))
	_cable_rope.segment_count = count
	_cable_rope.segment_length = cable_length / float(count)


func _add_cable_to_scene() -> void:
	get_tree().current_scene.add_child(_cable_instance)
	_cable_instance.add_to_group("spawned")
	_cable_plug = _cable_instance.get_node("ControllerPlug") as ControllerPlug
	_cable_rope = _cable_instance.get_node("VerletRope") as VerletRope
	_cable_plug.set_plug_mesh(plug_mesh_path)
	_cable_plug.set_controller(self)
	_cable_plug.add_collision_exception_with(self)
	_cable_plug.global_position = _cable_attach_point.global_position + Vector3(0, 0, -0.12)
	_cable_rope.start_node = _cable_attach_point
	_cable_rope.end_node = _cable_plug
	# End the cable AT the connector's cable boss. A bespoke plug model's origin
	# is its seating reference, which sits inside the shell, so without this the
	# rope terminates in the middle of the plug and the tube runs through it.
	_cable_rope.end_anchor_offset = _cable_plug.cable_anchor
	_resize_cable()
	_cable_rope._init_points()
	_max_rope_length = _cable_rope.segment_count * _cable_rope.segment_length

	if not _pending_port_restore.is_empty():
		var sys: RetroSystem = _pending_port_restore.get("system")
		var idx: int = _pending_port_restore.get("port_index", -1)
		_pending_port_restore = {}
		if is_instance_valid(sys) and idx >= 0:
			sys.restore_controller_plug(idx, _cable_plug)


func _physics_process(_delta: float) -> void:
	if _cable_plug == null or _cable_attach_point == null or _max_rope_length <= 0.0:
		return
	if _cable_plug.is_picked_up() or _connected_system != null:
		return

	var attach_pos := _cable_attach_point.global_position
	var diff := _cable_plug.global_position - attach_pos
	var dist := diff.length()

	if dist > _max_rope_length:
		var dir := diff / dist
		_cable_plug.global_position = attach_pos + dir * _max_rope_length
		var outward_vel := dir.dot(_cable_plug.linear_velocity)
		if outward_vel > 0.0:
			_cable_plug.linear_velocity -= dir * outward_vel


# ── Toggle-hold ───────────────────────────────────────────────────────────────

func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	if _hint:
		_hint.on_grabbed(by)
	var pickup := by as XRToolsFunctionPickup
	var ctrl := pickup.get_controller() if pickup else null as XRController3D
	if ctrl == null:
		if by.is_in_group("desktop_hand"):
			_desktop_held = true
		return

	# Only set _holding_ctrl for the first (primary) grab.
	if not is_instance_valid(_holding_ctrl):
		_saved_by = by
		_holding_ctrl = ctrl

	VrHold.set_model_visible(ctrl, false)
	_update_pointer_block(ctrl, true)
	_update_locomotion_block()
	_apply_rumble()
	_refresh_grip()


## Fires for any individual grab release (primary or secondary).
func _on_released_signal(_pickable: Node3D, by: Node3D) -> void:
	var pickup := by as XRToolsFunctionPickup
	if not is_instance_valid(pickup):
		return
	var ctrl: XRController3D = pickup.get_controller()
	if ctrl == null:
		return

	if _allow_drop:
		# Intentional drop — clean up this hand.
		VrHold.set_model_visible(ctrl, true)
		_update_pointer_block(ctrl, false)
		if ctrl == _holding_ctrl:
			if _grab_driver and _grab_driver.primary:
				_holding_ctrl = _grab_driver.primary.controller
				_saved_by = _grab_driver.primary.by
			else:
				_holding_ctrl = null
				_saved_by = null
		_update_locomotion_block()
		_apply_rumble()
		# Back to one hand after an intentional/combo drop → the survivor takes the
		# controller by its own grip.
		_refresh_grip()
		return

	# Toggle grip — rehold the released hand.
	if ctrl == _holding_ctrl:
		if _grab_driver and _grab_driver.primary:
			# Secondary was promoted to primary. Update our tracking.
			_holding_ctrl = _grab_driver.primary.controller
			_saved_by = _grab_driver.primary.by
			PokeTip.begin_rehold(ctrl)
			call_deferred("_rehold_hand", by)
		# else: no secondary, full drop follows — _on_dropped_signal handles rehold.
	else:
		# Secondary hand toggle — rehold it.
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
		VrHold.set_model_visible(_holding_ctrl, true)
		_update_pointer_block(_holding_ctrl, false)
		_saved_by = null
		_holding_ctrl = null
		_desktop_held = false
		_latch.clear()
		_update_locomotion_block()
		_apply_rumble()


func _rehold() -> void:
	if _allow_drop:
		_allow_drop = false
		return
	if not is_instance_valid(_saved_by):
		VrHold.set_model_visible(_holding_ctrl, true)
		_update_pointer_block(_holding_ctrl, false)
		_saved_by = null
		_holding_ctrl = null
		_update_locomotion_block()
		return
	_saved_by.call("_pick_up_object", self)


## Re-grab a hand that was released by toggle (not combo).
func _rehold_hand(by: Node3D) -> void:
	if _allow_drop or not is_instance_valid(by):
		return
	by.call("_pick_up_object", self)


func _update_locomotion_block() -> void:
	var secondary_ctrl := _get_secondary_ctrl()
	var left_held := (is_instance_valid(_holding_ctrl)   and _holding_ctrl.tracker   == &"left_hand") \
				  or (is_instance_valid(secondary_ctrl)  and secondary_ctrl.tracker  == &"left_hand")
	var right_held := (is_instance_valid(_holding_ctrl)   and _holding_ctrl.tracker   == &"right_hand") \
				   or (is_instance_valid(secondary_ctrl)  and secondary_ctrl.tracker  == &"right_hand")
	if _locomotion_manager != null:
		_locomotion_manager.set_block(VrHold.vr_block_owner(self), LocomotionManager.CHANNEL_LEFT,  left_held)
		_locomotion_manager.set_block(VrHold.vr_block_owner(self), LocomotionManager.CHANNEL_RIGHT, right_held)
	# The desktop side is ScrollLockCapture's: it blocks WASD only while captured,
	# and losing the grip here makes it ineligible, which drops both.
	if _capture:
		_capture.refresh()
	if is_instance_valid(_spawn_menu_ctrl) and "disabled" in _spawn_menu_ctrl:
		_spawn_menu_ctrl.set("disabled", left_held)


## Delegates to VrPointerBlock, which owns the shared refcount.
func _update_pointer_block(ctrl: XRController3D, should_block: bool) -> void:
	_pointer_block.set_block(ctrl, should_block)


## The combo test itself lives on HeldHint so the check and the row advertising
## it cannot disagree. Counting the use here rather than in the three branches
## below is deliberate: every one of them drops, and a predicate they all pass
## through cannot be missed when a fourth is added. HeldHint counts once per
## hold, so testing every frame does not inflate it.
func _is_combo_pressed(ctrl: XRController3D) -> bool:
	return PadInputShared.combo_pressed(ctrl, _hint)


var _combo_dbg := PadInputShared.ComboDebug.new()

func _combo_debug(ctrl: XRController3D) -> void:
	_combo_dbg.log_change(ctrl, name)


func _drop_all() -> void:
	VrHold.set_model_visible(_holding_ctrl, true)
	_update_pointer_block(_holding_ctrl, false)
	var secondary_ctrl := _get_secondary_ctrl()
	if is_instance_valid(secondary_ctrl):
		VrHold.set_model_visible(secondary_ctrl, true)
		_update_pointer_block(secondary_ctrl, false)
	_allow_drop = true
	_holding_ctrl = null
	_update_locomotion_block()
	drop()


func _exit_tree() -> void:
	# The captive cable is parented to current_scene so its rope can collide with
	# the room; it is not a child and would otherwise survive a controller
	# despawn (including a network despawn) as an orphaned plug and rope.
	if is_instance_valid(_cable_instance):
		_cable_instance.queue_free()
	# Release any active pointer blocks so other objects aren't stuck.
	_pointer_block.release(_left_vr_ctrl, _right_vr_ctrl)
	XRToolsRumbleManager.clear(self)
	_rumble.stop_pads()
	if _locomotion_manager != null:
		_locomotion_manager.clear_owner(VrHold.vr_block_owner(self))
	if _capture:
		_capture.release()
		# _process will not run again, so the global map has to go back now.
		_sync_desktop_scope()
	_allow_drop = true
	super._exit_tree()


# ── Port events ───────────────────────────────────────────────────────────────

func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	_connected_system = system
	_port_index = port_index
	_load_bindings()
	print("[RetroController] plugged into system port %d" % port_index)


func on_unplugged() -> void:
	print("[RetroController] unplugged from port %d" % _port_index)
	_connected_system = null
	_port_index = -1
	# Back to the global map. Keeping the last console's profile would mean a pad
	# pulled out of a NES still played a NES layout in your hand.
	_load_bindings()
	# Stop any lingering rumble when the cable is yanked. Usually already
	# cleared by RetroSystem._on_port_released, but idempotent and safer.
	set_rumble(0.0, 0.0)


# ── Rumble ────────────────────────────────────────────────────────────────────

## Push a new rumble state from the system (ultimately from the libretro core).
## weak / strong are normalized 0.0..1.0.
func set_rumble(weak: float, strong: float) -> void:
	_rumble.set_levels(weak, strong, _holders(), _desktop_held)


## Translate the current rumble state into real haptics. Called whenever the
## physical holder changes (grab/drop) so the new hand picks up ongoing rumble.
func _apply_rumble() -> void:
	_rumble.apply(_holders(), _desktop_held)


## Every controller physically holding this pad: the grabbing hand, plus the
## second one on a two-hand grab.
func _holders() -> Array:
	return [_holding_ctrl, _get_secondary_ctrl()]


func restore_port_connection(system: RetroSystem, port_index: int) -> void:
	if _cable_plug != null:
		system.restore_controller_plug(port_index, _cable_plug)
	else:
		_pending_port_restore = {"system": system, "port_index": port_index}


# ── Bindings ──────────────────────────────────────────────────────────────────

## Reload bindings from disk for the currently-connected system (or global if unplugged).
func reload_bindings() -> void:
	_load_bindings()


func _load_bindings() -> void:
	var sysid := ""
	if is_instance_valid(_connected_system):
		sysid = _connected_system.systemid
	var bindings := ControllerBindings.get_for_system(sysid)
	_button_map = bindings["buttons"]
	_stick_map  = bindings["sticks"]


## Hysteresis for the analog sources above — see InputLatch. Without it a single
## squeeze reaches the core as two presses.
var _latch := InputLatch.new()


# Returns the joypad button bitmask contributed by one controller.
# Only processes sources prefixed for the given hand.
func _apply_buttons_for_ctrl(ctrl: XRController3D, left_hand: bool) -> int:
	var bits: int = 0
	_sync_button_lists()
	for entry: Array in (_left_buttons if left_hand else _right_buttons):
		var vr_input: String = entry[0]
		var key := "%d:%s" % [ctrl.get_instance_id(), vr_input]
		if _latch.pressed(key, ctrl.get_float(vr_input), entry[1]):
			bits |= (1 << int(entry[2]))
	return bits


## _button_map flattened per hand into [vr_input, threshold, bit] entries, so the
## per-frame read does no prefix parsing. Rebuilt whenever the map object changes
## (_load_bindings, or a test assigning it directly).
var _left_buttons: Array = []
var _right_buttons: Array = []
var _button_lists_src: Dictionary = {}


func _sync_button_lists() -> void:
	if is_same(_button_lists_src, _button_map):
		return
	_button_lists_src = _button_map
	_left_buttons = []
	_right_buttons = []
	for full_source: String in _button_map:
		var bit: int = _button_map[full_source]
		if bit < 0:
			continue
		var vr_input: String
		var left := true
		var right := true
		if full_source.begins_with("right_"):
			vr_input = full_source.substr(6)
			left = false
		elif full_source.begins_with("left_"):
			vr_input = full_source.substr(5)
			right = false
		else:
			vr_input = full_source
		var entry: Array = [vr_input, float(INPUT_THRESHOLDS.get(vr_input, 0.5)), bit]
		if left:
			_left_buttons.append(entry)
		if right:
			_right_buttons.append(entry)


## The _stick_map targets resolved to flags once per map, not per frame.
var _stick_flags_src: Dictionary = {}
var _lt_left := false
var _lt_right := false
var _lt_dpad := false
var _rt_left := false
var _rt_right := false
var _rt_dpad := false


func _sync_stick_flags() -> void:
	if is_same(_stick_flags_src, _stick_map):
		return
	_stick_flags_src = _stick_map
	# Target strings: "left", "right", "dpad", "left+dpad", "right+dpad"
	# Substring checks handle combined targets ("dpad" in "left+dpad" → true).
	var lt: String = _stick_map.get("stick_left",  "left+dpad")
	var rt: String = _stick_map.get("stick_right", "right")
	_lt_left = "left" in lt
	_lt_right = "right" in lt
	_lt_dpad = "dpad" in lt
	_rt_left = "left" in rt
	_rt_right = "right" in rt
	_rt_dpad = "dpad" in rt


# ── Input forwarding ──────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	# Ahead of every early return below. The keyboard scope follows the CAPTURE,
	# which can be taken or dropped while this pad is neither held nor plugged —
	# behind the _desktop_held gate it simply never ran.
	_sync_desktop_scope()

	# A pad lying on the table, plugged into nothing, has no hand to read and no
	# machine to feed. A plugged one still has to send its idle state below.
	if _connected_system == null and not _desktop_held \
			and not is_instance_valid(_holding_ctrl):
		return

	var secondary_ctrl := _get_secondary_ctrl()
	_combo_debug(_holding_ctrl)

	# Drop combo: each hand only releases itself.
	if _is_combo_pressed(secondary_ctrl):
		_allow_drop = true
		VrHold.set_model_visible(secondary_ctrl, true)
		_update_pointer_block(secondary_ctrl, false)
		if _grab_driver and _grab_driver.secondary:
			_grab_driver.secondary.pickup.drop_object()
		_allow_drop = false
		_update_locomotion_block()
		_apply_rumble()
	elif _is_combo_pressed(_holding_ctrl):
		if is_instance_valid(secondary_ctrl):
			# Drop primary only; XRTools promotes secondary to primary.
			_allow_drop = true
			VrHold.set_model_visible(_holding_ctrl, true)
			_update_pointer_block(_holding_ctrl, false)
			if is_instance_valid(_saved_by):
				_saved_by.call("drop_object")
			# _on_released_signal already updated _holding_ctrl to promoted hand.
			_allow_drop = false
			_update_locomotion_block()
			_apply_rumble()
		else:
			_drop_all()
			return

	if _connected_system == null or _port_index < 0:
		return

	if _desktop_held:
		_process_desktop_joypad()
		return

	if not is_instance_valid(_holding_ctrl):
		_send_joypad(0, 0, 0, 0, 0)
		return

	var ctrl := _holding_ctrl
	var left_hand := ctrl.tracker == &"left_hand"

	var btn: int = 0

	# Face / grip / trigger buttons via button_map.
	btn |= _apply_buttons_for_ctrl(ctrl, left_hand)
	if is_instance_valid(secondary_ctrl):
		btn |= _apply_buttons_for_ctrl(secondary_ctrl, secondary_ctrl.tracker == &"left_hand")

	# lstick = left hand's primary stick; rstick = right hand's primary stick.
	var left_ctrl  := ctrl if left_hand else secondary_ctrl
	var right_ctrl := ctrl if not left_hand else secondary_ctrl
	var lstick: Vector2 = left_ctrl.get_vector2("primary") if is_instance_valid(left_ctrl) else Vector2.ZERO
	var rstick: Vector2 = right_ctrl.get_vector2("primary") if is_instance_valid(right_ctrl) else Vector2.ZERO

	var alx := 0; var aly := 0
	var arx := 0; var ary := 0

	_sync_stick_flags()

	if _lt_left: alx = int(lstick.x * ANALOG_SCALE); aly = int(-lstick.y * ANALOG_SCALE)
	elif _lt_right: arx = int(lstick.x * ANALOG_SCALE); ary = int(-lstick.y * ANALOG_SCALE)
	if _lt_dpad: btn |= _threshold_to_dpad(lstick)

	if _rt_right: arx = int(rstick.x * ANALOG_SCALE); ary = int(-rstick.y * ANALOG_SCALE)
	elif _rt_left: alx = int(rstick.x * ANALOG_SCALE); aly = int(-rstick.y * ANALOG_SCALE)
	if _rt_dpad: btn |= _threshold_to_dpad(rstick)

	_send_joypad(btn, alx, aly, arx, ary)


## Capture is only meaningful on desktop: in VR the pad reads the hand
## controllers, never the keyboard-bound actions.
func _can_capture() -> bool:
	return _desktop_held and _connected_system != null and _port_index >= 0


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or key.is_echo() or _capture == null:
		return
	if _capture.handle_key(key):
		get_viewport().set_input_as_handled()


## Which desktop key map is loaded into the InputMap, and whether WE put it
## there. The map is global to the process, so only the controller holding the
## Scroll Lock capture may drive it — otherwise every other pad in the room would
## keep stamping the global map back over the captured one's.
var _desktop_scope := ""
var _owns_desktop_scope := false


## Point the InputMap at this machine's key map while this pad holds the
## keyboard, and put the global map back when it lets go. Cheap enough to call
## every frame: it only touches the InputMap when the answer changes.
func _sync_desktop_scope() -> void:
	var active := _capture != null and _capture.is_active()
	if active:
		var sysid := ""
		if is_instance_valid(_connected_system):
			sysid = _connected_system.systemid
		if not _owns_desktop_scope or _desktop_scope != sysid:
			_owns_desktop_scope = true
			_desktop_scope = sysid
			DesktopBindings.apply_for_system(sysid)
	elif _owns_desktop_scope:
		_owns_desktop_scope = false
		_desktop_scope = ""
		DesktopBindings.apply_for_system("")


func _process_desktop_joypad() -> void:

	var btn: int = 0
	var alx := 0
	var aly := 0
	var arx := 0
	var ary := 0

	# Keyboard-bound buttons and sticks only while captured — otherwise WASD and
	# friends still belong to the player. A physical gamepad does NOT reach this
	# pad: it drives the port its own PadReceiver is plugged into, and nothing
	# else. Holding a controller is not a claim on every pad in the house.
	if _capture != null and _capture.is_active():
		for act: String in DESKTOP_BUTTON_MAP:
			var bit: int = DESKTOP_BUTTON_MAP[act]
			if Input.is_action_pressed(act):
				btn |= (1 << bit)

		# Left stick from RETRO_ANALOG_LEFT_* actions; Y negated to match VR.
		var lx := Input.get_axis("RETRO_ANALOG_LEFT_X_NEGATIVE",  "RETRO_ANALOG_LEFT_X_POSITIVE")
		var ly := Input.get_axis("RETRO_ANALOG_LEFT_Y_NEGATIVE",  "RETRO_ANALOG_LEFT_Y_POSITIVE")
		var rx := Input.get_axis("RETRO_ANALOG_RIGHT_X_NEGATIVE", "RETRO_ANALOG_RIGHT_X_POSITIVE")
		var ry := Input.get_axis("RETRO_ANALOG_RIGHT_Y_NEGATIVE", "RETRO_ANALOG_RIGHT_Y_POSITIVE")
		alx = int(lx * ANALOG_SCALE)
		aly = int(-ly * ANALOG_SCALE)
		arx = int(rx * ANALOG_SCALE)
		ary = int(-ry * ANALOG_SCALE)

	_send_joypad(btn, alx, aly, arx, ary)


## Route input to the connected system's core, via netplay when a lockstep game
## is running (the gate applies the agreed frame on every peer), else directly.
func _send_joypad(btn: int, alx: int, aly: int, arx: int, ary: int) -> void:
	if NetworkManager.netplay_route(_connected_system, _port_index,
			{"btn": btn, "alx": alx, "aly": aly, "arx": arx, "ary": ary}):
		return
	_connected_system.get_libretro_node().SetJoypadState(_port_index, btn, alx, aly, arx, ary)


static func _threshold_to_dpad(stick: Vector2) -> int:
	return PadInputShared.threshold_to_dpad(stick)

## Nunchuk — the Wii Remote's extension, as a separate object on its own cord.
##
## It never talks to libretro. The remote owns the slot and makes every core call
## for the pair, so this only has to say what its stick and buttons are doing and
## let the remote fold that into the one joypad word it sends. Seating the plug in
## the remote's expansion port is what flips that remote from WIIMOTE to
## WIIMOTE_NC; pulling it out flips it back.
##
## Motion is the one thing it does report on its own account, and even that goes
## out through the remote. libretro addresses one accelerometer per port, so the
## pair's second one rides a sub-device index (see libretro-godot's
## SensorIndex.hpp); the remote reads accel_in_nunchuk_frame() and sends it.
class_name Nunchuk
extends XRToolsPickable


const NUNCHUK_CABLE_SCENE := preload("res://Scenes/Objects/controllers/wii/nunchuk_cable.tscn")

## What the plug reports so it fits the remote's expansion port and nothing else.
## RetroSystem._accepts_plug rejects any plug whose systemid is not the console's,
## which keeps this cord out of every cabinet socket in the room.
const PLUG_SYSTEMID := "wii_nunchuk"

const INPUT_THRESHOLDS: Dictionary = {
	"trigger":   0.3,
	"grip":      0.3,
	"ax_button": 0.5,
	"by_button": 0.5,
}

## Height of the drop hint above the nunchuk, in metres.
const HINT_HEIGHT := 0.10

const BUTTON_PRESS := 0.0015
const ANIM_WEIGHT := 0.4

## How far the stick leans at full throw, in degrees.
##
## Modest on purpose. The stick's own mesh carries the boot that plugs the shell's
## bore, so leaning it leans that too, and the boot's skirt is only buried about
## 6 mm: at 25 mm across, much past this and its edge climbs out through the shell
## on the low side.
const STICK_TILT_DEG := 15.0

## How far BELOW the stick's own origin it pivots, in metres.
##
## A real stick hinges on a gimbal down inside the shell, not at the point where
## it leaves it. Pivoting at the origin swings the buried boot as much as the cap;
## dropping the pivot 8 mm swings the cap more and the boot less, which is both
## what the hardware does and what keeps the skirt inside the bore.
const STICK_PIVOT_DROP := 0.008

## Gravity used to convert measured acceleration into g, matching the remote's.
## The core multiplies by the same constant on the way back in.
const G := 9.80665
## Low-pass weight on the derived acceleration. Same reason as the remote's: VR
## linear_velocity is noisy enough that raw differentiation reads as a permanent
## shake.
const ACCEL_SMOOTHING := 0.25

# Cable
var _cable_instance: Node3D = null
var _cable_plug: ControllerPlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0

# Toggle-hold state (mirrors TVRemote and the Wiimote)
var _holding_ctrl: XRController3D = null
var _hint: HeldHint = null
var _allow_drop := false
var _saved_by: Node3D = null
var _desktop_held := false

var _locomotion_manager: LocomotionManager = null

## Which controller's pointer this is currently blocking, or null.
##
## Held as the controller itself rather than as the left/right pair Wiimote and
## LightGun keep, because a Nunchuk is only ever in one hand. That also makes the
## shared count impossible to unbalance: blocking a second time is a no-op, and
## releasing when nothing is held does nothing at all.
var _blocking_ctrl: XRController3D = null

# Motion
var _prev_velocity := Vector3.ZERO
var _accel_smoothed := Vector3.UP * G

# Active bindings
var _nunchuk_map: Dictionary = ControllerBindings.DEFAULT_NUNCHUK_MAP.duplicate()

@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _c_button: MeshInstance3D = $CButton
@onready var _z_button: MeshInstance3D = $ZButton
@onready var _stick: MeshInstance3D = $Stick

var _c_rest := Transform3D()
var _z_rest := Transform3D()
var _stick_rest := Transform3D()


func _ready() -> void:
	super._ready()
	# Toggle-hold, not grip-to-hold: this is a controller you pick up and keep,
	# and its own stick and buttons are read off the hand holding it. A grip you
	# have to keep squeezed is a grip you cannot use to play.
	press_to_hold = false
	add_to_group("spawned")
	add_to_group(ControllerBindings.CONSUMER_GROUP)
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	_hint = HeldHint.attach(self, true, HINT_HEIGHT)
	_c_rest = _c_button.transform
	_z_rest = _z_button.transform
	_stick_rest = _stick.transform
	_load_bindings()
	_spawn_cable()
	call_deferred("_find_locomotion")


func _find_locomotion() -> void:
	_locomotion_manager = get_tree().root.find_child(
		"LocomotionManager", true, false) as LocomotionManager
	# A Nunchuk spawned into a hand is grabbed before this resolves, so re-apply
	# rather than waiting for the next grab to notice.
	_update_locomotion_block()


## Stop the holding hand's stick from also walking the player.
##
## The Nunchuk reads its stick straight off that controller's "primary" vector --
## the same stick locomotion moves on -- so without this, using it drives the game
## AND drags you across the room. The Wiimote has the same guard, but it blocks
## the hand holding the REMOTE; the Nunchuk is in the other hand, which is very
## often the movement one.
##
## Only the hand actually holding it is blocked, and only in VR: get_state()
## returns a zero stick when there is no XR controller, so a desktop hold
## contributes no input to conflict over and takes no channel away.
## Per-instance owner for the VR channels. Shared owner keys let one object
## erase another's block -- see LocomotionManager.set_block for what that cost.
func _vr_block_owner() -> StringName:
	return StringName("retro_hold_%d" % get_instance_id())


func _update_locomotion_block() -> void:
	if _locomotion_manager == null:
		return
	var ctrl_valid := is_instance_valid(_holding_ctrl)
	_locomotion_manager.set_block(_vr_block_owner(), LocomotionManager.CHANNEL_LEFT,
		ctrl_valid and _holding_ctrl.tracker == &"left_hand")
	_locomotion_manager.set_block(_vr_block_owner(), LocomotionManager.CHANNEL_RIGHT,
		ctrl_valid and _holding_ctrl.tracker == &"right_hand")


## Stop the holding hand's laser pointing while this is in it.
##
## Without this the Nunchuk was the one thing in the room you could hold and still
## have a ray coming out of your fist: RetroController, Wiimote, LightGun,
## TVRemote and HandheldInput all block it, and this hid the controller model and
## took the locomotion channel but left the pointer alone.
##
## Reference-counted through a `block_count` meta on the controller's
## FunctionPointer, the same as those five, so several pickables can block one
## pointer independently and it returns only when the last of them lets go. A
## Nunchuk and the Wiimote it plugs into are very often one in each hand, which is
## exactly the case a plain visible = false would get wrong.
func _update_pointer_block(ctrl: XRController3D, should_block: bool) -> void:
	var target: XRController3D = ctrl if should_block else null
	if target == _blocking_ctrl:
		return
	_add_pointer_block(_blocking_ctrl, -1)
	_add_pointer_block(target, 1)
	_blocking_ctrl = target


func _add_pointer_block(ctrl: XRController3D, delta_count: int) -> void:
	if not is_instance_valid(ctrl):
		return
	var pointer: Node3D = ctrl.get_node_or_null("FunctionPointer")
	if pointer == null:
		return
	var count: int = maxi(0, pointer.get_meta("block_count", 0) + delta_count)
	pointer.set_meta("block_count", count)
	pointer.visible = count == 0
	# FunctionPickup._process_pointer_highlight reads the RayCast directly and
	# never looks at visibility, so hiding the laser alone leaves it able to grab.
	var ray: RayCast3D = pointer.get_node_or_null("RayCast") as RayCast3D
	if ray:
		ray.enabled = count == 0


func reload_bindings() -> void:
	_load_bindings()


func _load_bindings() -> void:
	_nunchuk_map = ControllerBindings.get_for_system("wii")["nunchuk"]


# ── Cable (mirrors RetroMultitap) ─────────────────────────────────────────────

func _spawn_cable() -> void:
	_cable_instance = NUNCHUK_CABLE_SCENE.instantiate()
	call_deferred("_add_cable_to_scene")


func _add_cable_to_scene() -> void:
	get_tree().current_scene.add_child(_cable_instance)
	_cable_instance.add_to_group("spawned")
	_cable_plug = _cable_instance.get_node("ControllerPlug") as ControllerPlug
	_cable_rope = _cable_instance.get_node("VerletRope") as VerletRope
	_cable_plug.set_controller(self)
	_cable_plug.add_collision_exception_with(self)
	# set_controller copies device_type and systemid off this node; the sentinel
	# below is what the remote's expansion port filters on.
	_cable_plug.systemid = PLUG_SYSTEMID
	# Laid out along the BOOT's axis rather than straight down the world, so the
	# first thing the cord does is continue the direction the moulding points. A
	# world-down guess put a kink at the join on any nunchuk not stood upright.
	_cable_plug.global_position = _cable_attach_point.global_position \
		- _cable_attach_point.global_transform.basis.y * 0.1
	_cable_rope.start_node = _cable_attach_point
	_cable_rope.end_node = _cable_plug
	_cable_rope._init_points()
	_max_rope_length = _cable_rope.segment_count * _cable_rope.segment_length


func get_plug() -> ControllerPlug:
	return _cable_plug


func _physics_process(delta: float) -> void:
	_update_accel(delta)
	if _cable_plug == null or _cable_attach_point == null or _max_rope_length <= 0.0:
		return
	if _cable_plug.is_picked_up():
		return
	var attach_pos := _cable_attach_point.global_position
	var diff := _cable_plug.global_position - attach_pos
	var dist := diff.length()
	if dist > _max_rope_length:
		var dir := diff / dist
		_cable_plug.global_position = attach_pos + dir * _max_rope_length
		var outward := dir.dot(_cable_plug.linear_velocity)
		if outward > 0.0:
			_cable_plug.linear_velocity -= dir * outward


# ── Toggle-hold (mirrors TVRemote) ────────────────────────────────────────────
#
# HeldHint.attach(self, true, ...) in _ready already ADVERTISES a combo drop, and
# for a long time that was all it did: the row promised a gesture nothing
# implemented, so the only way to put the Nunchuk down was to let go of the grip
# it was never meant to need. The three pieces below are what the hint was
# describing.

func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	if _hint:
		_hint.on_grabbed(by)
	var pickup := by as XRToolsFunctionPickup
	var ctrl := pickup.get_controller() if pickup else null as XRController3D
	if ctrl == null:
		# Desktop has no controller to hide and no combo to press; its own driver
		# handles the drop. Deliberately NOT recorded in _saved_by, or the gate
		# below would re-hold it and desktop could never let go.
		if by.is_in_group("desktop_hand"):
			_desktop_held = true
		return
	_saved_by = by
	_holding_ctrl = ctrl
	_set_model_visible(ctrl, false)
	_update_pointer_block(ctrl, true)
	_update_locomotion_block()


func _on_dropped_signal(_pickable: Node3D) -> void:
	# The gate. Every ordinary drop — an opened hand, a grip released, the pickup
	# losing tracking — arrives here and is undone by re-holding on the next
	# frame. Only _drop_all, which the combo reaches, sets _allow_drop first.
	if not _allow_drop and is_instance_valid(_saved_by):
		PokeTip.begin_rehold(_holding_ctrl)
		call_deferred("_rehold")
		return
	if _hint:
		_hint.on_dropped()
	_set_model_visible(_holding_ctrl, true)
	_update_pointer_block(_holding_ctrl, false)
	_allow_drop = false
	_saved_by = null
	_holding_ctrl = null
	_desktop_held = false
	_update_locomotion_block()


func _rehold() -> void:
	if _allow_drop:
		_allow_drop = false
		return
	if not is_instance_valid(_saved_by):
		# The hand went away rather than letting go — a teleport, a scene change.
		# Give its model back before forgetting it, or the player is left with an
		# invisible controller.
		_set_model_visible(_holding_ctrl, true)
		_update_pointer_block(_holding_ctrl, false)
		_saved_by = null
		_holding_ctrl = null
		_update_locomotion_block()
		return
	_saved_by.call("_pick_up_object", self)


## Hide the VR controller's own mesh while this is in that hand, so the player
## sees the Nunchuk and the wrap-around hand rather than a Touch controller
## floating inside it.
func _set_model_visible(ctrl: XRController3D, shown: bool) -> void:
	if is_instance_valid(ctrl) and ctrl.has_method("set_model_visible"):
		ctrl.call("set_model_visible", shown)


## The combo test itself lives on HeldHint so the check and the row advertising
## it cannot disagree.
func _is_combo_pressed(ctrl: XRController3D) -> bool:
	if not HeldHint.is_combo_pressed(ctrl):
		return false
	if _hint:
		_hint.note_used(&"drop_vr")
	return true


func _drop_all() -> void:
	_set_model_visible(_holding_ctrl, true)
	_update_pointer_block(_holding_ctrl, false)
	_allow_drop = true
	_holding_ctrl = null
	_update_locomotion_block()
	drop()


func _exit_tree() -> void:
	# Teardown is not a drop the player asked for, and the gate must not fight it.
	_allow_drop = true
	# clear_owner and not two set_block(false) calls: a Nunchuk freed mid-hold
	# never reaches _on_dropped_signal, and a block left behind is a hand that
	# can never walk again. The pointer has exactly the same hazard, and releasing
	# it takes no argument because _blocking_ctrl already knows whose it is.
	_update_pointer_block(null, false)
	if _locomotion_manager != null:
		_locomotion_manager.clear_owner(_vr_block_owner())
	super._exit_tree()


# ── State the Wiimote polls ───────────────────────────────────────────────────

## Stick, C and Z. Read once a frame by the remote holding the port; nothing here
## reaches the core directly. Motion is NOT in here — it goes out as a sensor,
## through accel_in_nunchuk_frame, and no longer doubles as a button.
func get_state() -> Dictionary:
	var vr := is_instance_valid(_holding_ctrl)
	return {
		"stick": _holding_ctrl.get_vector2("primary") if vr else Vector2.ZERO,
		"c":     _held(_nunchuk_map.get("c", "ax_button")),
		"z":     _held(_nunchuk_map.get("z", "trigger")),
	}


## Hysteresis for the analog VR sources — see InputLatch. Without it a single
## squeeze reaches the core as two presses.
var _latch := InputLatch.new()


func _held(source: Variant) -> bool:
	if not is_instance_valid(_holding_ctrl):
		return false
	var name_str := str(source)
	if name_str.is_empty() or name_str == "none":
		return false
	var key := "%d:%s" % [_holding_ctrl.get_instance_id(), name_str]
	return _latch.pressed(key, _holding_ctrl.get_float(name_str), float(INPUT_THRESHOLDS.get(name_str, 0.5)))


func _process(_delta: float) -> void:
	# The VR drop. Desktop drops through its own driver's click, which reaches
	# _on_dropped_signal with _saved_by unset and so passes the gate.
	if _is_combo_pressed(_holding_ctrl):
		_drop_all()
		return

	var state := get_state()
	_animate(_c_button, _c_rest, state.get("c", false))
	_animate(_z_button, _z_rest, state.get("z", false))
	_animate_stick(state.get("stick", Vector2.ZERO))


## Derive what this Nunchuk's accelerometer would read, the same way the remote
## derives its own: proper acceleration is motion MINUS gravity, so one at rest
## reads +1g upward rather than nothing, and simply holding it still while the
## room moves cannot register as a jerk.
##
## Driven from _physics_process, and only from there. linear_velocity is the
## physics server's, and a held Nunchuk is a frozen kinematic body the grab
## driver moves on its own physics tick, so this value changes on that clock and
## no other. Differentiated by a render delta it reads a step function off-phase
## and by the wrong divisor — measured at 88 m/s^2 for a brisk 30 cm wave whose
## true peak is 23.7, which swamps the one g of gravity the pose is read from.
func _update_accel(delta: float) -> void:
	if delta <= 0.0:
		return
	var velocity := linear_velocity
	var a_world := (velocity - _prev_velocity) / delta + Vector3.UP * G
	_prev_velocity = velocity
	_accel_smoothed = _accel_smoothed.lerp(a_world, ACCEL_SMOOTHING)


## The reading in the Nunchuk's own axes, in g, ready for the core.
##
## Dolphin's IMUAccelerometer is +X LEFT, +Y BACK, +Z UP — see the group's own
## constructor, which subtracts Right from Left, Forward from Backward and Down
## from Up — and its resting default is (0, 0, +1g). So a device lying flat and
## right side up must read (0, 0, 1), and every axis below is fixed by that.
##
## The swap is NOT the remote's. It cannot be, and the reason is the one thing
## worth carrying away from here: the two shells are authored in DIFFERENT
## attitudes. The remote lies down — nose at -Z, buttons at +Y — so its own up
## and forward already are Godot's, and (-x, z, y) is right for it. This shell
## STANDS UP: gen_nunchuk.gd runs the spine along Y with the nose at +0.056 and
## the cord's tail at -0.057, and sets the stick into the +Z face with C and Z
## in the -Z brow.
##
## So the Nunchuk's up is its +Z, not its +Y. Its rest pose is the model turned
## Rx(-90) — stick up, buttons down, spine level — which is the pose
## Tools/models/nunchuk_views.gd calls "the pose every reference photograph of this
## thing is taken in", and in it this returns (0, 0, 1).
##
## It read (0, 1, 0) there until 2026-08-24, because it borrowed the remote's
## swap on the stated grounds that both shells were authored the same way up.
## They are not. The reading was a quarter turn out about X for as long as the
## Nunchuk has had an accelerometer: at rest the core was told gravity pointed
## out of the device's BACK, so a Nunchuk lying on a table looked to a game like
## one held nose-up that never came level.
##
## The check that finds this class of bug, and the one that missed it: put the
## remote and the Nunchuk in the SAME attitude and compare. Nose straight up,
## both must answer (0, -1, 0). Reading either device's mapping on its own
## cannot tell you anything, because either is self-consistent.
func accel_in_nunchuk_frame() -> Vector3:
	var a := MotionFilter.deadband_motion(_accel_smoothed, G)
	var local := global_transform.basis.orthonormalized().inverse() * (a / G)
	return Vector3(-local.x, -local.y, local.z)


## Lean the stick the way the thumb is pushing it.
##
## The vector is the holding controller's own thumbstick, which is what get_state
## already hands the remote, so the mesh and the value going to the core cannot
## disagree about where the stick is.
##
## Built in the stick's OWN frame and then composed onto its rest transform, which
## is the only way that survives the seat: the stick sits at 34.5 degrees off the
## body, so "push forward" is not any one of the controller's axes and a rotation
## applied in the parent frame leans it in a direction that has nothing to do with
## the gate. +Y is up the stalk, so a push along the pad's Y tips the cap toward
## the nose (local -Z) and a push along X tips it toward local +X.
func _animate_stick(v: Vector2) -> void:
	var tilt := deg_to_rad(STICK_TILT_DEG)
	var lean := Vector2(v.x, v.y).limit_length(1.0)
	var rot := Basis(Vector3.RIGHT, -lean.y * tilt) * Basis(Vector3.BACK, -lean.x * tilt)
	var pivot := Vector3(0.0, -STICK_PIVOT_DROP, 0.0)
	var about := Transform3D(Basis.IDENTITY, pivot) * Transform3D(rot, Vector3.ZERO) 		* Transform3D(Basis.IDENTITY, -pivot)
	var tgt := _stick_rest * about
	_stick.transform = _stick.transform.interpolate_with(tgt, ANIM_WEIGHT)


func _animate(node: MeshInstance3D, rest: Transform3D, down: bool) -> void:
	var depth := BUTTON_PRESS if down else 0.0
	# The buttons face -Z on the shell's back, so they press away from the player.
	var tgt := Transform3D(rest.basis, rest.origin + Vector3(0, 0, depth))
	node.transform = node.transform.interpolate_with(tgt, ANIM_WEIGHT)

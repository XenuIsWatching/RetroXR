## Wiimote — a wireless Wii Remote that pairs with a RetroSystem instead of
## plugging into one, and drives Dolphin's emulated remote on the slot it claims.
##
## Three channels go to the core every frame, and each is a different mechanism:
##   • IR:       every lit sensor bar LED in the room is projected into the
##     camera in the nose of this remote, and the resulting pixel coordinates
##     handed to the core on pointer indices 0-3. That is the whole of the aim: no
##     cursor, no screen, no raycast. Dolphin feeds them to its emulated camera
##     verbatim under `dolphin_ir_passthrough`, which is why that option is forced.
##   • JOYPAD:   buttons, plus the Nunchuk's stick when one is seated.
##   • SENSOR:   a real accelerometer derived from the barrel's motion, in g,
##     which is what makes tilt and shake games work, plus a gyroscope in rad/s
##     derived from how fast the barrel is turning, which is what MotionPlus
##     reports. See _send_accel and _send_gyro.
##
## The IR channel replaced a raycast at the television, which could not be made
## right. That path sends a CURSOR — a point on the glass — and the core turns it
## back into a camera view by rotating a notional remote parked two metres from
## the bar, by a scale no geometry produces. Where the game then drew its hand
## depended on a constant fitted per game, and it compressed vertically and
## drifted. Projecting the real lights costs the same arithmetic and carries roll
## and distance too, neither of which a point on a plane can express.
##
## Pairing mirrors the hardware: press SYNC on the console, then SYNC on the
## remote (under the battery cover). The four blue LEDs show the slot. Pressing
## the remote's SYNC while already paired drops it, so unpairing needs no walk.
class_name Wiimote
extends XRToolsPickable


const NUNCHUK_PLUG_SYSTEMID := "wii_nunchuk"
const MOTION_PLUS_PLUG_SYSTEMID := "wii_motion_plus"

# Dolphin libretro device ids (DolphinLibretro/Input.cpp). WIIMOTE is #defined to
# RETRO_DEVICE_JOYPAD, so a bare remote and a plain pad share the value 1. See
# RetroSystem._cabinet_device_id for why that matters.
#
# The _MP pair is the same two remotes with the MotionPlus dongle fitted. They
# double rather than adding one because the dongle passes the port through, so
# every extension can still be plugged in behind it. What the id buys is the
# emulated dongle: the core attaches MotionPlus for a _MP id and detaches it
# otherwise, which is what makes the accessory in the room mean something.
#
# The _SW pair is the same remote held SIDEWAYS, in two hands like a plain pad.
# It is a device id and not a setting because the core has to know: it swaps the
# d-pad's bitmasks, renames four buttons and turns the emulated remote's
# orientation, none of which a frontend can do on the core's behalf.
#
# There is deliberately no sideways-with-Nunchuk id, because there is no such
# way to hold one -- the Nunchuk needs the hand that would be on the other end
# of the remote. _refresh_device_type resolves the clash in favour of the
# Nunchuk, which is the half a player physically plugged in.
const RETRO_DEVICE_WIIMOTE := 1
const RETRO_DEVICE_WIIMOTE_SW := 513
const RETRO_DEVICE_WIIMOTE_NC := 769
const RETRO_DEVICE_WIIMOTE_MP := 1793
const RETRO_DEVICE_WIIMOTE_MP_SW := 2049
const RETRO_DEVICE_WIIMOTE_MP_NC := 2305

## Analog range libretro expects on a stick axis.
const ANALOG_SCALE := 32767.0
## Full-scale value on a libretro pointer axis. The IR path uses the positive half
## only: the core's IRPassthrough controls read 0..1, so 0 is one edge of the
## sensor and 32767 the other.
const POINTER_SCALE := 32767.0

# ── Emulated IR camera ────────────────────────────────────────────────────────
#
# Dolphin's numbers, from CameraLogic in Core/HW/WiimoteEmu/Camera.h, and they are
# a description of the real hardware rather than a choice. They have to match: the
# frontend now IS the camera, and a game reading the dots was calibrated against a
# real one. Widen the field and every cursor in the machine travels too far.

## IR objects the camera can report. Four exist; a sensor bar only ever lights two
## of them, and Dolphin's own note says filling all four can cause stuttering.
const IR_OBJECTS := 4
const CAMERA_RES_X := 1024.0
const CAMERA_RES_Y := 768.0
const CAMERA_FOV_X_DEG := 42.0
const CAMERA_AR := 4.0 / 3.0

## Input thresholds per XRController float input name (shared with LightGun).
const INPUT_THRESHOLDS: Dictionary = {
	"trigger":       0.3,
	"grip":          0.3,
	"ax_button":     0.5,
	"by_button":     0.5,
	"primary_click": 0.5,
}

## Height of the drop hint above the remote, in metres.
const HINT_HEIGHT := 0.10

## Scroll Lock capture glyph, matching RetroController's.
const ICON_CAPTURE := 0xEC17
const ICON_SIZE := 0.030

## Desktop keyboard map: Godot action -> the remote's own control name. The same
## RETRO_JOYPAD_* actions every other device reads, so one set of keys drives
## whatever is in hand. Only live while Scroll Lock capture is on — otherwise
## these keys still belong to the player.
const DESKTOP_BUTTON_MAP: Dictionary = {
	"RETRO_JOYPAD_B":      "b",
	"RETRO_JOYPAD_A":      "a",
	"RETRO_JOYPAD_X":      "one",
	"RETRO_JOYPAD_Y":      "two",
	"RETRO_JOYPAD_START":  "plus",
	"RETRO_JOYPAD_SELECT": "minus",
	"RETRO_JOYPAD_R3":     "home",
	"RETRO_JOYPAD_R2":     "shake",
}

## Desktop d-pad, read straight off the same actions.
const DESKTOP_DPAD: Dictionary = {
	"RETRO_JOYPAD_UP":    ControllerBindings.JOYPAD_UP,
	"RETRO_JOYPAD_DOWN":  ControllerBindings.JOYPAD_DOWN,
	"RETRO_JOYPAD_LEFT":  ControllerBindings.JOYPAD_LEFT,
	"RETRO_JOYPAD_RIGHT": ControllerBindings.JOYPAD_RIGHT,
}

## How far the battery cover must swing before SYNC is reachable, in degrees.
const COVER_OPEN_DEG := 45.0

## The trigger's swing. Negative about +X so the blade sweeps back toward the
## palm, same sign and reasoning as the light gun's. (The face caps set their own
## travel in the scene — they are VRButtons and move themselves.)
const TRIGGER_PULL_DEG := -16.0
const ANIM_WEIGHT := 0.4

## Two-handed grip points, measured along the remote's long (+/-Z) axis. The
## D-pad sits at -Z, so the left hand always takes the negative end and the
## buttons stay by the right hand. Their basis turns the remote's +Z axis into
## the hands' +X axis: seen by the player, the remote lies sideways like a pad.
const SIDEWAYS_GRIP_OFFSET := 0.055
const SIDEWAYS_GRIP_ROTATION := -PI * 0.5

## Player-LED colours. "Off" is the unlit lens, not black — an unlit LED still
## catches room light.
const LED_OFF := Color(0.06, 0.07, 0.12)
const LED_ON := Color(0.25, 0.6, 1.0)
## Seconds per blink phase while unpaired or pairing.
const LED_BLINK_PERIOD := 0.5

## Gravity used to convert measured acceleration into g. The core multiplies by
## the same constant on the way back in (DolphinLibretro/Input.cpp).
const G := 9.80665
## Low-pass weight on the derived acceleration. VR linear_velocity is noisy
## enough that raw differentiation reads as a permanent shake.
const ACCEL_SMOOTHING := 0.25
## Same idea for angular velocity. Looser than the accelerometer's because the
## gyro is differentiated only once (orientation -> rate, not twice as with
## position -> acceleration), so it starts out far less noisy, and MotionPlus
## games are read as a direct measure of the wrist, so over-smoothing them feels
## like lag rather than steadiness.
const GYRO_SMOOTHING := 0.45
## Which sub-device of this port the Nunchuk's accelerometer is. libretro
## addresses one accelerometer per port and a Wii Remote with a Nunchuk is one
## player with two, so the pair's second one rides a sub-device index; 0 is the
## remote itself. See libretro-godot's SensorIndex.hpp.
const NUNCHUK_SENSOR_INDEX := 1

## Rotations smaller than this over one frame are treated as no rotation at all.
## Quaternion.get_axis() has no meaningful answer at zero angle (it returns a
## fixed axis), so without a floor a motionless remote reports a steady spin
## about whatever that happens to be.
const GYRO_MIN_ANGLE := 0.00001

## libretro device type reported to the system. Flips to _NC while a Nunchuk is
## seated in the expansion port.
var device_type: int = RETRO_DEVICE_WIIMOTE

## Whether to show the aim dot on the screen.
var show_laser_dot: bool = true

## Desktop: park the remote in the lower-right of the view instead of floating it
## on the grab ray, and aim from the camera centre — the same FPS-weapon handling
## the light gun uses (desktop_pickup._is_fps_snap reads this).
##
## Without it the remote hangs in the middle of the screen on the ray, directly in
## front of the very thing it is pointing at. The aim was already working; the
## hand cursor was simply behind the remote.
var desktop_fps_snap: bool = true

# Active bindings (loaded from ControllerBindings on pair)
var _wiimote_map: Dictionary = ControllerBindings.DEFAULT_WIIMOTE_MAP.duplicate()
var _wiimote_sideways_map: Dictionary = \
	ControllerBindings.DEFAULT_WIIMOTE_SIDEWAYS_MAP.duplicate()

# Pairing state
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
var _pending_port_restore: Dictionary = {}

# What is on the end of this remote. The Nunchuk may be seated directly in the
# expansion port or one step further out, in the dongle's own pass-through, and
# _nunchuk holds it either way so nothing downstream has to care which.
var _nunchuk: Nunchuk = null
var _motion_plus: MotionPlus = null

# Cached screen geometry (set on pair, cleared on unpair)
var _screen_mesh: MeshInstance3D = null
var _screen_w: float = 0.0
var _screen_h: float = 0.0

# Toggle-hold state (VR)
var _allow_drop := false
var _saved_by: Node3D = null
var _holding_ctrl: XRController3D = null
var _desktop_held: bool = false
var _upright_left_grip := Transform3D.IDENTITY
var _upright_right_grip := Transform3D.IDENTITY

var _hint: HeldHint = null
var _capture: ScrollLockCapture = null
var _locomotion_manager: LocomotionManager = null
var _spawn_menu_ctrl: Node = null
var _left_vr_ctrl: XRController3D = null
var _right_vr_ctrl: XRController3D = null

## Hides the ray pointer on whichever hand is holding this, so a grab
## gesture cannot also fire the pointer at whatever is behind it.
var _pointer_block := VrPointerBlock.new()

# Accelerometer derivation
var _prev_velocity := Vector3.ZERO
## Starts at the at-rest reading rather than at zero, which is freefall: a remote
## that has only just appeared has not been dropped, and the same value is what
## on_unplugged puts back.
var _accel_smoothed := Vector3.UP * G

# Gyroscope derivation. The previous orientation of the barrel, and whether one
# has been recorded yet. The first frame after pairing has nothing to difference
# against, and a stale basis from before would read as one enormous flick.
var _prev_tip_basis := Basis()
var _has_prev_tip_basis := false
var _gyro_smoothed := Vector3.ZERO

# LED animation
var _led_materials: Array[StandardMaterial3D] = []
var _led_lit: PackedInt32Array = PackedInt32Array()
var _blink_clock := 0.0
## Last aim state printed, so the log speaks only on change. See _log_aim.
var _last_aim_log: String = ""
var _last_aim_counts := Vector2i(-1, -1)
var _last_aim_value_ms: int = 0

## The two slot orderings _update_aim sorts by, built once rather than as a
## lambda per frame.
var _sort_nearest_first: Callable = Callable(self, &"_nearer")
var _sort_sensor_x_desc: Callable = Callable(self, &"_higher_x")


static func _nearer(a: Vector3, b: Vector3) -> bool:
	return a.z < b.z


static func _higher_x(a: Vector3, b: Vector3) -> bool:
	return a.x > b.x

## Half-field tangents of the emulated camera, filled in _ready. Dolphin passes
## the ratio of the FOV ANGLES as the projection's aspect, so the horizontal
## tangent is the vertical one scaled by 4:3 rather than tan(fov_x / 2) — a
## difference of most of a degree, and this is not the place to be almost right.
var _tan_half_fov := Vector2.ONE

## Print where the remote is aiming, twice a second.
##
## ON while the pointer's alignment is being chased. Exported so it can be ticked
## per-remote later, but defaulted true because a remote is SPAWNED — there is no
## authored node in the editor to tick, so a false default is a switch with
## nothing to flip it. Turn this off (or delete it with the two _log_aim helpers)
## once the aim is trusted.
@export var aim_debug: bool = true

## The face buttons, by the control name each one is. These are VRButtons: they
## can be POKED with the free hand as well as driven from the held hand, which is
## the only way the remote's full set is reachable — five usable inputs on one
## hand against seven buttons and a d-pad. VRButton also owns their depress
## animation, so nothing here moves a cap by hand.
const FACE_BUTTONS: Dictionary = {
	"a":     "AButton",
	"one":   "OneButton",
	"two":   "TwoButton",
	"plus":  "PlusButton",
	"minus": "MinusButton",
	"home":  "HomeButton",
}
var _face_buttons: Dictionary = {}   # control name -> VRButton
var _face_latched: Dictionary = {}   # control name -> the latch last handed to it

## Seconds a finger must stay on POWER before the paired console shuts down.
##
## There is no hardware figure to copy. Nintendo's own manual says only "Press to
## turn the console ON or OFF", and on a real remote a tap does both — the one
## documented hold in the Wii family is the CONSOLE's own key, about four seconds
## from standby to a full shutdown, which is far too long to stand there with a
## fingertip on a 6 mm cap. A second is what the remote is commonly reported to
## want, and it is long enough that no brush of the shell can reach it.
const POWER_HOLD_SEC := 1.0

## Rumble queue slot for that hold. Its own key rather than VRButton's HAPTIC_KEY,
## which the cap's own press tick already owns — sharing it would mean the press
## tick cancelling the hold a frame after starting it.
const POWER_HAPTIC_KEY := &"wiimote_power"
## How hard it buzzes. Low on purpose: this runs for a whole second, and the
## magnitude a button click uses (0.5) is a power tool at that length. It says
## "something is counting", not "something fired".
const POWER_HAPTIC_MAGNITUDE := 0.15

var _power_held_for := 0.0
## The hand being rumbled through the hold, so it can be stopped on the same hand
## that started — a touch press may be relayed between hands mid-hold.
var _power_haptic_ctrl: XRController3D = null
## Latched for the whole of one contact, so a hold that has already acted cannot
## act again without letting go first — which is what stops the power-off rolling
## straight into a power-on under a finger that never moved.
var _power_fired := false
var _trigger_rest := Transform3D()
var _dpad_rest := Transform3D()

## How far the d-pad rocker tilts toward the direction being pushed, in degrees.
const DPAD_TILT_DEG := 6.0
## Stick deflection that counts as a d-pad press.
const DPAD_THRESHOLD := 0.35

@onready var _barrel_tip: Node3D = $BarrelTip
@onready var _laser_dot: MeshInstance3D = $LaserDot
@onready var _expansion_port: XRToolsSnapZone = $ExpansionPort
@onready var _sync_button: VRButton = $SyncButton
## The red key at the top left of the face. Deliberately absent from FACE_BUTTONS,
## from DESKTOP_BUTTON_MAP and from ControllerBindings: no core sees it and no
## controller input maps to it, so the only way to work it is a finger on the cap
## (or the pointer, on desktop). That is what makes the hold below meaningful.
@onready var _power_button: VRButton = $PowerButton
## Under CoverPivot, not beside it: the hinge's grab box has to ride the cover it
## swings, or it stays over the shut position while the lid moves out from under it.
@onready var _battery_cover: VRHinge = $CoverPivot/BatteryCover
@onready var _trigger_pivot: Node3D = $TriggerPivot
@onready var _dpad: Node3D = $DPad
@onready var _leds: Node3D = $PlayerLEDs


## The remote is aimed and fired from the hand holding it, so the push-out
## gesture has nothing to bind to. Same call the light gun makes.
func wants_ray_handoff() -> bool:
	return false


func _ready() -> void:
	super._ready()
	press_to_hold = false
	second_hand_grab = SecondHandGrab.SECOND
	_upright_left_grip = ($HandLeft as Node3D).transform
	_upright_right_grip = ($HandRight as Node3D).transform
	add_to_group("spawned")
	add_to_group(ControllerBindings.CONSUMER_GROUP)
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	released.connect(_on_released_signal)
	_hint = HeldHint.attach(self, true, HINT_HEIGHT)
	_capture = ScrollLockCapture.attach(self, _can_capture,
		ICON_CAPTURE, ICON_SIZE)
	_hint.add_row(&"capture", HeldHint.PLATFORM_DESKTOP,
		["keyboard_scroll_lock_outline"], "or F3 — send keys here")
	# One VR hand carries five usable inputs against this remote's seven buttons
	# and a d-pad, so the hand binding alone can never reach all of them. The
	# answer is the one the hardware itself suggests — hold it in one hand, poke
	# the awkward ones with the other — but nothing on screen says so, and a
	# player who does not think of it simply cannot press 1, 2 or minus.
	#
	# VR only. On desktop the same buttons are keys under Scroll Lock capture,
	# which the row above already explains.
	_hint.add_row(&"poke_buttons", HeldHint.PLATFORM_VR,
		["generic_button_finger"], "Press its buttons with your other hand",
		HeldHint.WHEN_HELD)
	_laser_dot.visible = false
	var tan_y := tan(deg_to_rad(CAMERA_FOV_X_DEG / CAMERA_AR) * 0.5)
	_tan_half_fov = Vector2(CAMERA_AR * tan_y, tan_y)
	_cache_controls()
	_setup_leds()
	# snap_require alone would also take a console pad's plug — every ControllerPlug
	# joins that group. The systemid sentinel is what makes this socket the
	# Nunchuk's and nothing else's, the mirror of RetroSystem._accepts_plug.
	_expansion_port.snap_filter = _accepts_extension
	_expansion_port.has_picked_up.connect(_on_extension_seated)
	_expansion_port.has_dropped.connect(_on_extension_removed)
	_sync_button.button_pressed.connect(_on_sync_pressed)
	_sync_button.set_active(false)
	_battery_cover.rotation_changed.connect(_on_cover_moved)
	call_deferred("_find_vr_nodes")


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
	_update_locomotion_block()
	# A restore that arrived before this node was in the tree.
	if not _pending_port_restore.is_empty():
		var sys: RetroSystem = _pending_port_restore.get("system")
		var idx: int = _pending_port_restore.get("port_index", -1)
		_pending_port_restore = {}
		if is_instance_valid(sys) and idx >= 0:
			sys.attach_expanded_controller(idx, self)


# ── Pairing ───────────────────────────────────────────────────────────────────

## SYNC on the remote. Paired → drop the slot (no console trip). Unpaired → find
## a console with an open pairing window and claim its lowest free slot.
func _on_sync_pressed() -> void:
	if _connected_system != null:
		print("[Wiimote] SYNC while paired — releasing slot %d" % _port_index)
		var link := _connected_system.get_wii_link()
		if link != null:
			link.unpair(self)
		return
	var host := _nearest_listening_link()
	if host == null:
		print("[Wiimote] SYNC with no console listening — press SYNC on the console first")
		return
	if host.pair(self) < 0:
		print("[Wiimote] pairing refused — that console is full")


## Nearest console currently listening. Nearest rather than first so two Wiis in
## one room can be paired to independently: walk to the one you mean.
func _nearest_listening_link() -> WiiLink:
	var best: WiiLink = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group(WiiLink.PAIRING_GROUP):
		var link := node as WiiLink
		if link == null or not is_instance_valid(link.host):
			continue
		var d := global_position.distance_to(link.host.global_position)
		if d < best_d:
			best_d = d
			best = link
	return best


## Called by RetroSystem when a slot is claimed — by pairing, by a rehome after a
## wired pad took this remote's slot, or by a save restore.
func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	_connected_system = system
	_port_index = port_index
	_load_bindings()
	_cache_screen_geometry()
	_laser_dot.visible = show_laser_dot
	# The core leaves IR on the right analog stick unless this is set, in which
	# case the raycast below reaches nothing. It is consumed mid-run.
	var libretro := system.get_libretro_node()
	if is_instance_valid(libretro):
		libretro.SetCoreOption("dolphin_ir_mode", "2")
	print("[Wiimote] paired to slot %d (device %d)" % [port_index, device_type])


func on_unplugged() -> void:
	print("[Wiimote] released slot %d" % _port_index)
	_connected_system = null
	_port_index = -1
	# Drop the motion history with the slot. However far the remote is carried
	# while unpaired, the next pairing must not read that as one frame's rotation
	# or as one frame's acceleration.
	_has_prev_tip_basis = false
	_gyro_smoothed = Vector3.ZERO
	_prev_velocity = Vector3.ZERO
	_accel_smoothed = Vector3.UP * G
	_screen_mesh = null
	_screen_w = 0.0
	_screen_h = 0.0
	_laser_dot.visible = false


## Marker method. RetroSystem._evict_remote_from looks for this to tell a wireless
## remote (which it may move) from a wired pad (which it may not).
func on_wireless_rehomed() -> void:
	pass


func restore_port_connection(system: RetroSystem, port_index: int) -> void:
	if is_inside_tree():
		system.attach_expanded_controller(port_index, self)
	else:
		_pending_port_restore = {"system": system, "port_index": port_index}


## The Nunchuk on the end of this remote, or null. Read when saving. It may be
## seated in this remote's own port or in the dongle's pass-through; the save
## records only that this remote has it, because reloading puts it back on
## whichever of the two is there.
func get_nunchuk() -> Nunchuk:
	return _nunchuk


## The MotionPlus dongle seated in the expansion port, or null. Read when saving.
func get_motion_plus() -> MotionPlus:
	return _motion_plus


## The object that rides the desktop's second FPS slot while this remote is held.
##
## A Nunchuk is a pickable in its own right on a metre of cord, so on the desktop
## — where the remote is pinned to the corner of the view rather than carried by a
## hand — it had nothing holding it and simply trailed along the floor behind the
## player. This hands it the other hand. desktop_pickup polls it every frame, so
## seating or pulling the cord mid-hold is all it takes.
func desktop_companion() -> XRToolsPickable:
	return _nunchuk


## Re-seat a Nunchuk after a load. Deferred because the nunchuk spawns its cord
## on its own deferred call — its plug does not exist on the frame the scene is
## rebuilt, and there is nothing to snap until it does.
func restore_nunchuk(nc: Nunchuk) -> void:
	if not is_instance_valid(nc):
		return
	_reseat_nunchuk.call_deferred(nc, RESEAT_RETRIES)


## Retries are bounded, not "until it works": a nunchuk that was freed mid-load
## would otherwise reschedule this every idle frame for the life of the session.
const RESEAT_RETRIES := 8

func _reseat_nunchuk(nc: Nunchuk, tries_left: int) -> void:
	if not is_instance_valid(nc):
		return
	# Into the DONGLE when one is fitted, because that is the port it came out
	# of. Safe to decide here rather than at save time: restore_motion_plus runs
	# first and seats synchronously, so _motion_plus is already right by now.
	if _motion_plus != null:
		_motion_plus.restore_nunchuk(nc)
		return
	var plug := nc.get_plug()
	if plug != null:
		_expansion_port.pick_up_object(plug)
		return
	if tries_left <= 0:
		push_warning("[Wiimote] nunchuk cord never appeared; left unseated")
		return
	_reseat_nunchuk.call_deferred(nc, tries_left - 1)


## Re-seat a MotionPlus after a load. No deferral, unlike the Nunchuk: the dongle
## is a plain pickable with no cord to wait on, and seating it straight away is
## what lets _reseat_nunchuk find it on the deferred pass that follows.
func restore_motion_plus(mp: MotionPlus) -> void:
	if not is_instance_valid(mp):
		return
	_expansion_port.pick_up_object(mp)


func reload_bindings() -> void:
	_load_bindings()


func _load_bindings() -> void:
	var systemid := ""
	if is_instance_valid(_connected_system):
		systemid = _connected_system.systemid
	var bindings := ControllerBindings.get_for_system(systemid)
	_wiimote_map = bindings["wiimote"]
	_wiimote_sideways_map = bindings["wiimote_sideways"]


## Find the glass to aim at. Re-runnable, and re-run whenever it has nothing —
## see _update_aim.
##
## This used to fire once, when the remote claimed its slot, and give up quietly
## if the set was not cabled to the console at that instant. A remote pairs by
## handshake, so that instant has nothing to do with when the A/V lead went in;
## restore a saved room and the order is whatever the file happens to list. Miss
## it and the pointer never worked again for that pairing, while every button
## carried on working — they do not need the screen — which reads as "the
## pointer is broken" rather than "it never found the television".
func _cache_screen_geometry() -> void:
	if _connected_system == null or _connected_system.connected_tv == null:
		return
	var mesh := _connected_system.connected_tv.get_screen_mesh()
	if mesh == null:
		return
	var aabb := mesh.get_aabb()
	_screen_mesh = mesh
	_screen_w = aabb.size.x
	_screen_h = aabb.size.y


# ── Battery cover / SYNC access ───────────────────────────────────────────────

## SYNC only exists once the cover is off it. Hiding the cap is not enough —
## VRButton.set_active is what takes it off the pointable layer and stops it
## polling fingertips, so a closed cover really does cover it.
func _on_cover_moved(degrees: float) -> void:
	_sync_button.set_active(degrees >= COVER_OPEN_DEG)


# ── Nunchuk ───────────────────────────────────────────────────────────────────

## Two things fit this port: a Nunchuk's plug, or a MotionPlus dongle. The dongle
## is not on a cord, so it presents ITSELF rather than a plug, which is why it
## joins the controller_plug group the snap zone requires.
func _accepts_extension(obj: Node3D) -> bool:
	if not "systemid" in obj:
		return false
	var mid := str(obj.get("systemid"))
	return mid == NUNCHUK_PLUG_SYSTEMID or mid == MOTION_PLUS_PLUG_SYSTEMID


func _on_extension_seated(obj: Node3D) -> void:
	var node: Node3D = obj.get_controller() if obj.has_method("get_controller") else obj
	var mp := node as MotionPlus
	if mp != null:
		_motion_plus = mp
		# The Nunchuk now belongs to the dongle's port, not this one, so the
		# remote can no longer see it being seated or pulled. Follow the dongle's
		# signal instead, and adopt whatever is already in it.
		mp.nunchuk_changed.connect(_on_chained_nunchuk_changed)
		_nunchuk = mp.get_nunchuk()
	else:
		_nunchuk = node as Nunchuk
	_refresh_device_type()


## XRToolsSnapZone.has_dropped carries no argument: it does not say what left,
## only that the zone is empty. Which is enough, because the zone holds one thing
## and this remote already knows what that was.
func _on_extension_removed() -> void:
	if _motion_plus != null:
		if _motion_plus.nunchuk_changed.is_connected(_on_chained_nunchuk_changed):
			_motion_plus.nunchuk_changed.disconnect(_on_chained_nunchuk_changed)
		_motion_plus = null
	_nunchuk = null
	_refresh_device_type()


## A Nunchuk was seated in or pulled out of the seated dongle's pass-through.
func _on_chained_nunchuk_changed(nc: Nunchuk) -> void:
	_nunchuk = nc
	_refresh_device_type()


## Whether the announced id is one of the Nunchuk ones. Asked rather than compared
## against a single id because there are two of them now, with and without the
## dongle, and the button layout is the same for both.
func _has_nunchuk() -> bool:
	return device_type == RETRO_DEVICE_WIIMOTE_NC or device_type == RETRO_DEVICE_WIIMOTE_MP_NC


## Announce whatever is currently hanging off this remote, as one of the four ids
## the core understands. Called from every path that can change the chain, so the
## mapping from hardware to id lives in exactly one place.
## A Nunchuk BEATS a two-handed grab, and the order below is the whole rule.
##
## Both hands on the remote is how a player asks for sideways, but a Nunchuk in
## one of them means that hand is not free — you cannot hold a Nunchuk and the
## far end of the remote at once. The core has no id for the combination either.
## So a seated Nunchuk wins and the second hand is just a second hand.
func _refresh_device_type() -> void:
	var dev := RETRO_DEVICE_WIIMOTE
	if _motion_plus != null:
		if _nunchuk != null:
			dev = RETRO_DEVICE_WIIMOTE_MP_NC
		elif _is_held_in_two_hands():
			dev = RETRO_DEVICE_WIIMOTE_MP_SW
		else:
			dev = RETRO_DEVICE_WIIMOTE_MP
	elif _nunchuk != null:
		dev = RETRO_DEVICE_WIIMOTE_NC
	elif _is_held_in_two_hands():
		dev = RETRO_DEVICE_WIIMOTE_SW
	_set_device_type(dev)


## True when both hands have hold of the remote.
##
## Asked of the grab driver rather than tracked with a counter of our own: the
## driver already owns the answer, and a counter kept alongside it goes wrong the
## first time a hand is taken away by something other than a release — a teleport,
## a scene change, the object being freed under the hand.
func _is_held_in_two_hands() -> bool:
	if _grab_driver == null:
		return false
	return _grab_driver.secondary != null


func _is_sideways() -> bool:
	return device_type == RETRO_DEVICE_WIIMOTE_SW \
		or device_type == RETRO_DEVICE_WIIMOTE_MP_SW


## Returns the XR controller carrying the secondary grab, if there is one.
func _get_secondary_ctrl() -> XRController3D:
	if _grab_driver and _grab_driver.secondary:
		return _grab_driver.secondary.controller
	return null


## A plain grip press on a hand already holding the remote is not a drop. The
## remote uses the same explicit drop combo as the other game controllers, which
## also lets either hand leave a two-handed hold without a drop/re-grab flicker.
func wants_grip_toggle_drop() -> bool:
	return false


## Re-anchor both live grabs and blend to the resulting one- or two-hand pose.
func _refresh_grip() -> void:
	_update_hand_pose_anchors()
	GripAnchor.refresh(self, self)


## Local-space grip for one hand. Upright uses the authored centre pose; with two
## hands the remote spans them, D-pad end on the left, irrespective of which hand
## picked it up first.
func grip_anchor(is_left: bool) -> Transform3D:
	if not _is_held_in_two_hands():
		return _upright_left_grip if is_left else _upright_right_grip
	return Transform3D(
		Basis(Vector3.UP, SIDEWAYS_GRIP_ROTATION),
		Vector3(0.0, 0.0, -SIDEWAYS_GRIP_OFFSET if is_left else SIDEWAYS_GRIP_OFFSET))


## The drawn hands use these same nodes, so keep their meshes on the physical
## grips as the remote changes pose.
func _update_hand_pose_anchors() -> void:
	var left := get_node_or_null(^"HandLeft") as Node3D
	var right := get_node_or_null(^"HandRight") as Node3D
	if left:
		left.transform = grip_anchor(true)
	if right:
		right.transform = grip_anchor(false)


## Re-announce the slot when the extension changes. The core rebuilds the whole
## Wiimote mapping on this call — including which buttons mean what, which is why
## _pressed_now reads a different table per device type.
func _set_device_type(dev: int) -> void:
	if dev == device_type:
		return
	device_type = dev
	if _connected_system == null or _port_index < 0:
		return
	_connected_system.set_controller_port_device(_port_index, device_type)
	if _has_nunchuk():
		return
	# Nothing on the expansion port any more. Put the sub-device back to a device
	# lying still, so the pulled Nunchuk's last pose cannot be read as the next
	# one's first frame.
	var libretro := _connected_system.get_libretro_node()
	if is_instance_valid(libretro):
		if not NetworkManager.netplay_set_aux_sensor(_connected_system, _port_index,
				NUNCHUK_SENSOR_INDEX, 0, 0, 1000):
			libretro.SetSensorAccel(_port_index, 0.0, 0.0, 1.0, NUNCHUK_SENSOR_INDEX)
		print("[Wiimote] extension changed — slot %d re-announced as %d"
			% [_port_index, device_type])


# ── Toggle-hold (mirrors LightGun) ────────────────────────────────────────────

## Also fires for the SECOND hand — xr-tools emits grabbed for both — which is
## what turns the remote sideways.
func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	_refresh_device_type()
	if _hint:
		_hint.on_grabbed(by)
	_set_face_buttons_active(true)
	var pickup := by as XRToolsFunctionPickup
	var ctrl := pickup.get_controller() if pickup else null as XRController3D
	if ctrl == null:
		if by.is_in_group("desktop_hand"):
			_desktop_held = true
			_laser_dot.visible = _connected_system != null and show_laser_dot
			if _capture:
				_capture.refresh()
		return
	# The first grab remains the input-bearing primary. A second hand only adds
	# its controls and its grip anchor; it must not steal the saved rehold target.
	if not is_instance_valid(_holding_ctrl):
		_saved_by = by
		_holding_ctrl = ctrl
	VrHold.set_model_visible(ctrl, false)
	_update_pointer_block(ctrl, true)
	_update_locomotion_block()
	_refresh_grip()


## Fires for each individual hand. XR Tools has already removed that grab (and
## promoted the survivor when the primary left) before emitting this signal.
func _on_released_signal(_pickable: Node3D, by: Node3D) -> void:
	_refresh_device_type()
	var pickup := by as XRToolsFunctionPickup
	if not is_instance_valid(pickup):
		_refresh_grip()
		return
	var ctrl: XRController3D = pickup.get_controller()
	if ctrl == null:
		_refresh_grip()
		return

	if _allow_drop:
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
		_refresh_grip()
		return

	# A non-drop release is the toggle-hold machinery trying to let go. Reattach
	# that hand; if it was primary, XR Tools has already promoted the survivor.
	if ctrl == _holding_ctrl:
		if _grab_driver and _grab_driver.primary:
			_holding_ctrl = _grab_driver.primary.controller
			_saved_by = _grab_driver.primary.by
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
		return
	if _hint:
		_hint.on_dropped()
	_set_face_buttons_active(false)
	VrHold.set_model_visible(_holding_ctrl, true)
	_update_pointer_block(_holding_ctrl, false)
	_allow_drop = false
	_saved_by = null
	_holding_ctrl = null
	_desktop_held = false
	_laser_dot.visible = false
	# Capture is always a subset of "held", so letting go has to drop it or the
	# player is left with their keyboard pointed at a remote on the floor.
	if _capture:
		_capture.release()
	_update_locomotion_block()


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


func _rehold_hand(by: Node3D) -> void:
	if _allow_drop or not is_instance_valid(by):
		return
	by.call("_pick_up_object", self)


func _is_combo_pressed(ctrl: XRController3D) -> bool:
	if not HeldHint.is_combo_pressed(ctrl):
		return false
	if _hint:
		_hint.note_used(&"drop_vr")
	return true


func _drop_all() -> void:
	VrHold.set_model_visible(_holding_ctrl, true)
	_update_pointer_block(_holding_ctrl, false)
	var secondary_ctrl := _get_secondary_ctrl()
	if is_instance_valid(secondary_ctrl):
		VrHold.set_model_visible(secondary_ctrl, true)
		_update_pointer_block(secondary_ctrl, false)
	_allow_drop = true
	_holding_ctrl = null
	_laser_dot.visible = false
	_update_locomotion_block()
	drop()


func _exit_tree() -> void:
	_stop_power_haptic()
	_pointer_block.release(_left_vr_ctrl, _right_vr_ctrl)
	if _locomotion_manager != null:
		_locomotion_manager.clear_owner(VrHold.vr_block_owner(self))
		_locomotion_manager.set_block(VrHold.desktop_block_owner(self),
			LocomotionManager.CHANNEL_DESKTOP_MOVE, false)
	_allow_drop = true
	super._exit_tree()


func _update_locomotion_block() -> void:
	var secondary_ctrl := _get_secondary_ctrl()
	var left_held := (is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"left_hand") \
		or (is_instance_valid(secondary_ctrl) and secondary_ctrl.tracker == &"left_hand")
	var right_held := (is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"right_hand") \
		or (is_instance_valid(secondary_ctrl) and secondary_ctrl.tracker == &"right_hand")
	var desktop_claim := _desktop_held and _connected_system != null and _port_index >= 0
	if _locomotion_manager != null:
		_locomotion_manager.set_block(VrHold.vr_block_owner(self), LocomotionManager.CHANNEL_LEFT,  left_held)
		_locomotion_manager.set_block(VrHold.vr_block_owner(self), LocomotionManager.CHANNEL_RIGHT, right_held)
		_locomotion_manager.set_block(VrHold.desktop_block_owner(self),
			LocomotionManager.CHANNEL_DESKTOP_MOVE, desktop_claim)
	if is_instance_valid(_spawn_menu_ctrl) and "disabled" in _spawn_menu_ctrl:
		_spawn_menu_ctrl.set("disabled", left_held)


func _update_pointer_block(ctrl: XRController3D, should_block: bool) -> void:
	_pointer_block.set_block(ctrl, should_block)


# ── Desktop keyboard (Scroll Lock capture) ────────────────────────────────────

## May this remote take the keyboard right now? Same rule as RetroController's:
## held on the desktop and actually driving a port, so capture can never outlive
## the grip and strand the player with WASD blocked.
func _can_capture() -> bool:
	return _desktop_held and _connected_system != null and _port_index >= 0


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or key.is_echo() or _capture == null:
		return
	if _capture.handle_key(key):
		get_viewport().set_input_as_handled()


## The remote's controls as the keyboard sees them. Empty unless capture is on —
## otherwise the RETRO_JOYPAD_* keys still belong to the player, which is the
## whole point of the Scroll Lock gate.
func _desktop_pressed() -> Dictionary:
	var out: Dictionary = {}
	if _capture == null or not _capture.is_active():
		return out
	for action_name: String in DESKTOP_BUTTON_MAP:
		if Input.is_action_pressed(action_name):
			out[String(DESKTOP_BUTTON_MAP[action_name])] = true
	return out


## Desktop d-pad bits, read off the same actions.
func _desktop_dpad_mask() -> int:
	if _capture == null or not _capture.is_active():
		return 0
	var mask := 0
	for action_name: String in DESKTOP_DPAD:
		if Input.is_action_pressed(action_name):
			mask |= 1 << int(DESKTOP_DPAD[action_name])
	return mask


# ── POWER ─────────────────────────────────────────────────────────────────────

## The two halves of POWER are not symmetric, and that asymmetry is the design.
##
## OFF, a press acts at once: that is what the manual describes and what anyone
## picking up a remote expects. ON, a press does nothing at all and only a HOLD
## of POWER_HOLD_SEC stops the machine, because a tap is exactly what putting the
## remote down on a table looks like, and losing a running game to that is not a
## thing the room should permit.
##
## toggle_power rather than power_on/power_off: it is the same entry the cabinet's
## own key uses, and it carries the netplay rules (a lockstep session stops on
## every peer, a client sends the intent instead of acting) that a direct call
## would quietly skip.
func _update_power_hold(delta: float) -> void:
	if not _power_button.is_held():
		_stop_power_haptic()
		_power_held_for = 0.0
		_power_fired = false
		return

	if _power_fired:
		return

	if not is_instance_valid(_connected_system):
		# Said once per press, not once per frame. A remote that is not paired has
		# no console to switch, and from the room that looks the same as a dead
		# button.
		_power_fired = true
		print("[Wiimote] POWER with no console paired — press SYNC on both first")
		return

	if not _connected_system.is_powered_on:
		_power_fired = true
		print("[Wiimote] POWER — switching the console on")
		_connected_system.toggle_power()
		return

	# The rumble IS the timer, and it is the only thing that is: there is no dial
	# and no sound, so without it a player holding a red cap has nothing telling
	# them the hold is being counted rather than ignored. It starts on the first
	# frame of the count and is cut the instant the machine acts, which is what
	# makes the stop read as "done" rather than as a dropped press.
	_set_power_haptic(_power_button.held_by())

	_power_held_for += delta
	if _power_held_for < POWER_HOLD_SEC:
		return
	_stop_power_haptic()
	_power_fired = true
	print("[Wiimote] POWER held %.1fs — switching the console off" % POWER_HOLD_SEC)
	_connected_system.toggle_power()


## Rumble [param ctrl] for the length of the hold, moving the buzz if the press is
## relayed to the other hand. A null hand (the pointer, or the desktop reticle)
## simply stops it: there is nothing there to feel it.
func _set_power_haptic(ctrl: XRController3D) -> void:
	if ctrl == _power_haptic_ctrl:
		return
	_stop_power_haptic()
	if is_instance_valid(ctrl):
		_power_haptic_ctrl = ctrl
		Haptics.hold(ctrl, POWER_HAPTIC_MAGNITUDE, POWER_HAPTIC_KEY)


## Every path that can end the hold calls this — firing, letting go, dropping the
## remote, leaving the tree. Haptics.hold is indefinite, so one missed stop is a
## controller that buzzes until the room is torn down.
func _stop_power_haptic() -> void:
	if is_instance_valid(_power_haptic_ctrl):
		Haptics.stop(_power_haptic_ctrl, POWER_HAPTIC_KEY)
	_power_haptic_ctrl = null


# ── Shell animation ───────────────────────────────────────────────────────────

func _cache_controls() -> void:
	for key: String in FACE_BUTTONS:
		var b := get_node_or_null(String(FACE_BUTTONS[key])) as VRButton
		if b != null:
			_face_buttons[key] = b
			# Only a POKE retires the poke hint, which is why this listens to the
			# VRButton rather than to _pressed_now(): that merges the poked state
			# with the held hand's bindings, so pressing A from the controller
			# would count as having learned to use the other hand.
			b.button_pressed.connect(_note_poked)
	# POWER is not a face button — it drives no core — but pressing it IS the
	# other-hand poke the hint teaches, so it retires the row like the rest.
	_power_button.button_pressed.connect(_note_poked)
	if _trigger_pivot != null:
		_trigger_rest = _trigger_pivot.transform
	if _dpad != null:
		_dpad_rest = _dpad.transform
	# Live only while the remote is in a hand. VRButton puts itself on the
	# pointable layer, and a remote lying across the room whose caps answer the
	# laser is a remote you cannot pick up by pointing at it — the beam presses 1
	# instead. It also stops every unheld remote in the room polling fingertips.
	_set_face_buttons_active(false)


## Give each LED its own material so they can light independently. The scene
## shares one sub-resource across the four lenses, which would otherwise mean
## tinting one tints all of them.
func _setup_leds() -> void:
	for child in _leds.get_children():
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		var mat := StandardMaterial3D.new()
		mat.albedo_color = LED_OFF
		mat.emission_enabled = true
		mat.emission = LED_ON
		mat.emission_energy_multiplier = 0.0
		mi.set_surface_override_material(0, mat)
		_led_materials.append(mat)


## Three states, and the middle one is the point:
##   * unpaired          — all four blinking together, as in discovery
##   * paired, set OFF   — dark. A remote is not talking to a console that is not
##                         running, and lighting a player number there claimed a
##                         connection the game could not possibly see.
##   * paired, set ON    — LED N solid for slot N
func _update_leds(delta: float) -> void:
	if _led_materials.is_empty():
		return
	_blink_clock += delta
	var blink_on := fmod(_blink_clock, LED_BLINK_PERIOD * 2.0) < LED_BLINK_PERIOD
	var live := _port_index >= 0 and is_instance_valid(_connected_system) \
		and _connected_system.is_powered_on
	if _led_lit.size() != _led_materials.size():
		_led_lit.resize(_led_materials.size())
		_led_lit.fill(-1)
	for i in range(_led_materials.size()):
		var lit := false
		if _port_index < 0:
			lit = blink_on
		elif live:
			lit = i == _port_index
		# A material write is a render-server call; four of them a frame for
		# LEDs that change twice a second is the wrong ratio.
		if _led_lit[i] == int(lit):
			continue
		_led_lit[i] = int(lit)
		var mat := _led_materials[i]
		mat.albedo_color = LED_ON if lit else LED_OFF
		mat.emission_energy_multiplier = 1.6 if lit else 0.0


## Move the shell to match what is being pressed.
##
## The face caps are NOT moved here — they are VRButtons and animate themselves.
## What they cannot see is the other route in, a bound hand input pressing a
## button nobody is touching, so that is handed to them as a latch and they draw
## it with the same travel a poke gets. One depress animation, two causes.
func _animate_controls(pressed: Dictionary) -> void:
	for key: String in _face_buttons:
		var down: bool = pressed.get(key, false)
		var was: Variant = _face_latched.get(key)
		if was is bool and bool(was) == down:
			continue
		_face_latched[key] = down
		(_face_buttons[key] as VRButton).set_latched_pressed(down)

	if _trigger_pivot != null:
		var pull := 1.0 if pressed.get("b", false) else 0.0
		var tgt_x := Transform3D(
			_trigger_rest.basis * Basis(Vector3.RIGHT, deg_to_rad(TRIGGER_PULL_DEG * pull)),
			_trigger_rest.origin)
		_trigger_pivot.transform = _trigger_pivot.transform.interpolate_with(tgt_x, ANIM_WEIGHT)

	# The d-pad is one rocker, not four keys, so it TILTS toward the push rather
	# than sinking. Driven off the raw stick rather than the thresholded d-pad
	# bits, so it leans with the thumb instead of snapping between five poses.
	if _dpad != null:
		var s := _dpad_animation_stick()
		# Both axes are NEGATED, and it is the same reason twice: a rocker dips on
		# the side you press. UP is the arm toward the front of the remote (-Z), so
		# pushing up has to carry -Z downward — a positive turn about +X lifts it
		# instead, which read as the pad answering the opposite direction. Likewise
		# RIGHT (+X) must dip, not rise.
		var tgt := Transform3D(
			_dpad_rest.basis
				* Basis(Vector3.RIGHT, deg_to_rad(-DPAD_TILT_DEG * s.y))
				* Basis(Vector3.BACK, deg_to_rad(-DPAD_TILT_DEG * s.x)),
			_dpad_rest.origin)
		_dpad.transform = _dpad.transform.interpolate_with(tgt, ANIM_WEIGHT)


## set_interactive, not set_active: the caps are moulded into the shell and stay
## on show whether or not they can be pressed. set_active would hide them and
## leave a blank white slab whenever the remote is put down.
func _set_face_buttons_active(active: bool) -> void:
	for key: String in _face_buttons:
		(_face_buttons[key] as VRButton).set_interactive(active)
	# POWER goes with them. It is on the pointable layer too, and a remote across
	# the room whose red key answers the laser is a remote you cannot pick up by
	# pointing at it without switching a console off.
	_power_button.set_interactive(active)
	if not active:
		_stop_power_haptic()
		_power_held_for = 0.0
		_power_fired = false


## Count the poke hint as learned the first time a face button is actually
## pressed in a hold. Without this the row would reappear on every pickup for
## ever — note_used is what retires it after HeldHint.LEARNED_AFTER holds, and it
## is already idempotent within one hold.
func _note_poked() -> void:
	if _hint:
		_hint.note_used(&"poke_buttons")


## What the aim is doing, printed only when the answer CHANGES.
##
## The pointer has three distinct ways of showing nothing — no screen found, a ray
## pointing away from the glass, and a hit that lands outside it — and from the
## room all three look identical: no hand. This says which, once, per transition,
## so a single run tells you where to look instead of a guess.
func _log_aim(state: String) -> void:
	if state == _last_aim_log:
		return
	_last_aim_log = state
	_last_aim_counts = Vector2i(-1, -1)
	print("[Wiimote] aim: %s" % state)


## The in-view count, formatted only when it moves; _log_aim would drop the
## repeat anyway, and this saves building the string it would drop.
func _log_aim_counts(in_view: int, lit: int) -> void:
	var counts := Vector2i(in_view, lit)
	if counts == _last_aim_counts:
		return
	_log_aim("%d of %d lit LEDs in view" % [in_view, lit])
	_last_aim_counts = counts


## Twice a second, where the sensor bar's lights landed on the emulated sensor.
##
## The state log above only speaks on transitions, which is right for "why is
## there no pointer" and useless for "the pointer is in the wrong place". This is
## the calibration read, in the units the hardware works in: pixels on a
## 1024 x 768 sensor, with the centre at 512,384 when the remote is aimed square
## at the middle of the bar. Their SEPARATION is the distance to the bar, and it
## should shrink as you back away — that is the reading no cursor could carry.
func _log_aim_points(points: Array[Vector3]) -> void:
	if not aim_debug:
		return
	var now := Time.get_ticks_msec()
	if now - _last_aim_value_ms < 500:
		return
	_last_aim_value_ms = now
	var parts: Array[String] = []
	for p: Vector3 in points:
		parts.append("(%.0f,%.0f)" % [p.x, p.y])
	var gap := 0.0
	if points.size() >= 2:
		gap = Vector2(points[0].x, points[0].y).distance_to(Vector2(points[1].x, points[1].y))
	print("[Wiimote] IR %s  separation=%.0f px" % [" ".join(parts), gap])


## The holding hand's thumbstick, or zero when nothing is holding the remote.
func _dpad_stick() -> Vector2:
	var active_map := _wiimote_sideways_map if _is_sideways() else _wiimote_map
	if active_map.get("stick", "dpad") != "dpad" or not is_instance_valid(_holding_ctrl):
		return Vector2.ZERO
	var secondary_ctrl := _get_secondary_ctrl()
	if is_instance_valid(secondary_ctrl):
		if _holding_ctrl.tracker == &"left_hand":
			return _holding_ctrl.get_vector2("primary")
		if secondary_ctrl.tracker == &"left_hand":
			return secondary_ctrl.get_vector2("primary")
	return _holding_ctrl.get_vector2("primary")


## The core wants the player's logical direction and rotates it internally for
## a sideways remote. The visible rocker wants the opposite view: which arm on
## the rotated physical cross moved. With the D-pad end on the left, logical
## LEFT is the arm labelled UP, then the other three follow around the cross.
func _dpad_animation_stick() -> Vector2:
	var logical := _dpad_stick()
	return Vector2(logical.y, -logical.x) if _is_sideways() else logical


# ── Input forwarding ──────────────────────────────────────────────────────────

## Hysteresis for the analog VR sources — see InputLatch. Without it a single
## squeeze reaches the core as two presses.
var _latch := InputLatch.new()

## The frame's read, reused: _pressed_now is consumed within the frame it ran.
var _pressed_out: Dictionary = {}
var _press_ctrls: Array[XRController3D] = []

## A binding layer flattened for the per-frame read: one [input, control,
## threshold, hand] per bound source, so no frame walks the map's prefixes.
## Rebuilt when the layer object is swapped (see _load_bindings).
const PRESS_HAND_ANY := 0
const PRESS_HAND_LEFT := 1
const PRESS_HAND_RIGHT := 2
var _press_entries_upright: Array = []
var _press_entries_upright_src: Dictionary = {}
var _press_entries_sideways: Array = []
var _press_entries_sideways_src: Dictionary = {}


static func _build_press_entries(map: Dictionary) -> Array:
	var entries: Array = []
	for source: String in map:
		if source == "stick":
			continue
		var control := str(map[source])
		if control.is_empty() or control == "none":
			continue
		var input := source
		var hand := PRESS_HAND_ANY
		if source.begins_with("left_"):
			input = source.substr(5)
			hand = PRESS_HAND_LEFT
		elif source.begins_with("right_"):
			input = source.substr(6)
			hand = PRESS_HAND_RIGHT
		entries.append([input, control, float(INPUT_THRESHOLDS.get(input, 0.5)), hand])
	return entries


func _press_entries() -> Array:
	if _is_sideways():
		if not is_same(_press_entries_sideways_src, _wiimote_sideways_map):
			_press_entries_sideways_src = _wiimote_sideways_map
			_press_entries_sideways = _build_press_entries(_wiimote_sideways_map)
		return _press_entries_sideways
	if not is_same(_press_entries_upright_src, _wiimote_map):
		_press_entries_upright_src = _wiimote_map
		_press_entries_upright = _build_press_entries(_wiimote_map)
	return _press_entries_upright


## Which PHYSICAL remote controls are down this frame, from the active upright
## or sideways binding layer plus a hand poking the shell. One read is shared by
## the core and animation, so the visible button and emulated button agree.
##
## Every face button appears in the result whether or not anything is mapped to
## it, so a control with no binding still reports false rather than nothing —
## _button_mask and the animation both read it either way.
func _pressed_now() -> Dictionary:
	var out := _pressed_out
	out.clear()
	for key: String in FACE_BUTTONS:
		out[key] = false
	var controllers := _press_ctrls
	controllers.clear()
	if is_instance_valid(_holding_ctrl):
		controllers.append(_holding_ctrl)
	if _is_sideways():
		var secondary_ctrl := _get_secondary_ctrl()
		if is_instance_valid(secondary_ctrl):
			controllers.append(secondary_ctrl)
	for entry: Array in _press_entries():
		var input: String = entry[0]
		var hand: int = entry[3]
		for ctrl: XRController3D in controllers:
			if hand == PRESS_HAND_LEFT and ctrl.tracker != &"left_hand":
				continue
			if hand == PRESS_HAND_RIGHT and ctrl.tracker != &"right_hand":
				continue
			var key := "%d:%s" % [ctrl.get_instance_id(), input]
			if _latch.pressed(key, ctrl.get_float(input), entry[2]):
				out[entry[1]] = true
				break
	# A poke is an OR, not an override: pressing 1 on the shell while the bound
	# hand input is also down must not cancel it. The keyboard joins on the same
	# terms, so a desktop player and a poking hand cannot cancel each other either.
	for key: String in _face_buttons:
		if (_face_buttons[key] as VRButton).is_held():
			out[key] = true
	for key: String in _desktop_pressed():
		out[key] = true
	return out


## Pack the named controls into a libretro joypad mask.
##
## These tables are deliberately separate. A Nunchuk moves 1/2 off X/Y onto
## START/SELECT; sideways maps physical 1/2/A/B and the rotated cross onto the
## bits in descWiimoteSideways. Reading the wrong one silently swaps controls.
func _button_mask(pressed: Dictionary) -> int:
	var nc := _has_nunchuk()
	var bits: Dictionary = {
		"b":     ControllerBindings.JOYPAD_B,
		"a":     ControllerBindings.JOYPAD_A,
		"one":   ControllerBindings.JOYPAD_START if nc else ControllerBindings.JOYPAD_X,
		"two":   ControllerBindings.JOYPAD_SELECT if nc else ControllerBindings.JOYPAD_Y,
		"minus": ControllerBindings.JOYPAD_L if nc else ControllerBindings.JOYPAD_SELECT,
		"plus":  ControllerBindings.JOYPAD_R if nc else ControllerBindings.JOYPAD_START,
		"home":  ControllerBindings.JOYPAD_R3,
		"shake": ControllerBindings.JOYPAD_R2,
		# The cross, so a hand input bound to a direction really works it. The
		# Controls page has always promised this -- "the D-pad is driven by the
		# thumbstick unless you bind a button to it" -- and for a Wii Remote it
		# was not true: the remote resolves its own layer, and this table, which
		# is where that layer turns into libretro bits, had no directions in it.
		# A player who bound grip to Up got nothing and no error.
		#
		# These are ORed with the stick below rather than replacing it, so binding
		# one direction does not cost you the other three.
		"up":    ControllerBindings.JOYPAD_UP,
		"down":  ControllerBindings.JOYPAD_DOWN,
		"left":  ControllerBindings.JOYPAD_LEFT,
		"right": ControllerBindings.JOYPAD_RIGHT,
	}
	if _is_sideways():
		# Values in the sideways binding layer are PHYSICAL shell labels. Dolphin's
		# sideways device describes those labels on different RetroPad bits.
		bits = {
			"one":   ControllerBindings.JOYPAD_B,
			"two":   ControllerBindings.JOYPAD_A,
			"a":     ControllerBindings.JOYPAD_X,
			"b":     ControllerBindings.JOYPAD_Y,
			"minus": ControllerBindings.JOYPAD_SELECT,
			"plus":  ControllerBindings.JOYPAD_START,
			"home":  ControllerBindings.JOYPAD_R3,
			"shake": ControllerBindings.JOYPAD_R2,
			"up":    ControllerBindings.JOYPAD_LEFT,
			"down":  ControllerBindings.JOYPAD_RIGHT,
			"left":  ControllerBindings.JOYPAD_DOWN,
			"right": ControllerBindings.JOYPAD_UP,
		}
	var mask := 0
	for key: String in bits:
		if pressed.get(key, false):
			mask |= 1 << int(bits[key])
	# The d-pad rides the holding hand's thumbstick — same read the rocker leans
	# on, so what the game sees and what the shell shows cannot drift apart.
	var stick := _dpad_stick()
	if stick.y >  DPAD_THRESHOLD: mask |= 1 << ControllerBindings.JOYPAD_UP
	if stick.y < -DPAD_THRESHOLD: mask |= 1 << ControllerBindings.JOYPAD_DOWN
	if stick.x < -DPAD_THRESHOLD: mask |= 1 << ControllerBindings.JOYPAD_LEFT
	if stick.x >  DPAD_THRESHOLD: mask |= 1 << ControllerBindings.JOYPAD_RIGHT
	mask |= _desktop_dpad_mask()
	# Nunchuk: C and Z land on X/Y, freed by 1/2 moving. L2 — the core's "Shake
	# Nunchuk" — is deliberately never set from here. A Nunchuk reports a real
	# accelerometer now, and Dolphin composes shake ON TOP of it, so a gesture
	# would put a second, larger, canned punch behind every real one.
	if nc and _nunchuk != null:
		var nstate := _nunchuk.get_state()
		if nstate.get("c", false):
			mask |= 1 << ControllerBindings.JOYPAD_X
		if nstate.get("z", false):
			mask |= 1 << ControllerBindings.JOYPAD_Y
	return mask


func _process(delta: float) -> void:
	_update_leds(delta)
	_update_power_hold(delta)

	var secondary_ctrl := _get_secondary_ctrl()
	if _is_combo_pressed(secondary_ctrl):
		_allow_drop = true
		VrHold.set_model_visible(secondary_ctrl, true)
		_update_pointer_block(secondary_ctrl, false)
		if _grab_driver and _grab_driver.secondary:
			_grab_driver.secondary.pickup.drop_object()
		_allow_drop = false
		_update_locomotion_block()
	elif _is_combo_pressed(_holding_ctrl):
		if is_instance_valid(secondary_ctrl):
			_allow_drop = true
			VrHold.set_model_visible(_holding_ctrl, true)
			_update_pointer_block(_holding_ctrl, false)
			if is_instance_valid(_saved_by):
				_saved_by.call("drop_object")
			_allow_drop = false
			_update_locomotion_block()
		else:
			_drop_all()
			return

	# The shell moves whether or not it is paired — an unpaired remote still has
	# buttons you can press.
	var pressed := _pressed_now()
	_animate_controls(pressed)

	if _connected_system == null or _port_index < 0:
		return

	var libretro := _connected_system.get_libretro_node()
	if not is_instance_valid(libretro):
		return

	var nstick := Vector2.ZERO
	if _has_nunchuk() and _nunchuk != null:
		nstick = _nunchuk.get_state().get("stick", Vector2.ZERO) as Vector2

	# Right stick stays at zero on purpose: with a Nunchuk attached in pointer IR
	# mode the core binds the Tilt group to it, which would fight the real
	# accelerometer below.
	var joy := {"btn": _button_mask(pressed), "alx": int(nstick.x * ANALOG_SCALE),
		"aly": int(-nstick.y * ANALOG_SCALE), "arx": 0, "ary": 0}
	if not NetworkManager.netplay_route(_connected_system, _port_index, joy):
		libretro.SetJoypadState(_port_index, joy.btn, joy.alx, joy.aly, 0, 0)

	_update_aim(libretro)


## Both sensors ride the PHYSICS clock, not the render one, and that is not a
## detail: they are differentiated from linear_velocity and from the barrel's
## pose, and a held remote is a frozen kinematic body moved by the grab driver's
## own _physics_process. Those two only change on a physics tick, so dividing
## their change by a render delta divides by the wrong number and samples a step
## function off-phase. Measured on the Nunchuk, whose derivation is the same: a
## brisk 30 cm wave reported 88 m/s^2 against a true 23.7, and the one g of
## gravity that carries the pose — which is the whole of what Dolphin's
## IMUAccelerometer positions a hand from — was swamped by up to 84 degrees.
func _physics_process(delta: float) -> void:
	if _connected_system == null or _port_index < 0:
		return
	var libretro := _connected_system.get_libretro_node()
	if not is_instance_valid(libretro):
		return
	_send_accel(libretro, delta)
	_send_gyro(libretro, delta)


# ── Pointer (IR) ──────────────────────────────────────────────────────────────

## Where the remote's camera is and which way it is looking, as a transform with
## -Z forward.
##
## The barrel, whether or not anyone is holding it. A remote put down on the sofa
## still has a lens, and if it happens to be facing the set it really does still
## drive the cursor — that is a thing that happens in living rooms, and there is
## nothing to gain by pretending otherwise. Pointed anywhere else it sees no
## lights, which blanks the pointer on its own.
##
## The desktop is the exception: there the remote is snapped in front of the
## camera rather than held, so its own barrel says nothing about where the player
## is looking. The view aims instead — the same substitution the light gun makes.
func _camera_pose() -> Transform3D:
	if _desktop_held:
		var cam := get_viewport().get_camera_3d()
		if is_instance_valid(cam):
			return cam.global_transform
	return _barrel_tip.global_transform


## Project a world point into the emulated IR camera. Returns (px, py, distance),
## with px/py in pixels on a 1024 x 768 sensor. A distance of zero means the
## camera cannot see it — behind the lens, or past the edge of the sensor.
##
## This is Dolphin's CameraLogic::GetCameraPoints, rewritten in Godot's frame. It
## has to be, exactly: the passthrough path takes sensor coordinates, and the game
## on the other side was calibrated against real hardware, so anything but the
## real optics puts the cursor in the wrong place by a fixed factor.
##
## Dolphin projects with Perspective(fov_y, fov_x/fov_y) — note the aspect is the
## ratio of the ANGLES, not of their tangents — and then maps clip space to pixels
## as (1 - ndc) * RES / 2 on both axes. Its pre-projection camera frame has +X
## LEFT and +Y DOWN, so composing that flip with the (1 - ndc) flip cancels both:
## in Godot's frame it comes out as (1 + ndc) * RES / 2 with ndc taken straight
## off +X right and +Y up. The upshot is the convention a real Wii camera has —
## an object to the RIGHT of the aim axis reads high in x, and one ABOVE it reads
## high in y, because the lens inverts the image and the hardware never undoes it.
func _project_to_camera(cam_inv: Transform3D, world_point: Vector3) -> Vector3:
	var v := cam_inv * world_point
	# Godot looks down -Z, so the forward distance is -z. Dolphin's own check is
	# the same one: a point behind the camera is no point at all.
	var w := -v.z
	if w <= 0.0:
		return Vector3.ZERO
	var px := (1.0 + (v.x / w) / _tan_half_fov.x) * 0.5 * CAMERA_RES_X
	var py := (1.0 + (v.y / w) / _tan_half_fov.y) * 0.5 * CAMERA_RES_Y
	if px < 0.0 or py < 0.0 or px >= CAMERA_RES_X or py >= CAMERA_RES_Y:
		return Vector3.ZERO
	return Vector3(px, py, w)


## Every lit LED in the room, in world space.
##
## Deliberately NOT scoped to the console this remote is paired with. A camera
## cannot tell whose lights it is looking at — it sees infrared, and the sensor
## bar is a dumb lamp with no identity to read. Two Wiis set up in one room really
## do confuse each other on real hardware, and this is where that comes from.
## Pairing decides which console HEARS the report, not what the camera can see.
##
## Only lit bars are here: an unplugged one, or one on a console nobody switched
## on, has no power and emits nothing. See SensorBar.is_lit.
func _visible_leds() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for node: Node in get_tree().get_nodes_in_group(SensorBar.BAR_GROUP):
		var bar := node as SensorBar
		if bar != null:
			out.append_array(bar.led_positions())
	return out


func _send_pointer(libretro: Libretro, index: int, x: int, y: int, pressed: bool) -> void:
	if not NetworkManager.netplay_set_aux_pointer(_connected_system, _port_index,
			index, x, y, pressed):
		libretro.SetPointerIndexState(_port_index, index, x, y, pressed)


## Report every IR object as unseen. Dolphin skips any object whose size is zero,
## so an all-blank frame is a camera looking at nothing — which is what the Wii's
## own software reads as "the remote is pointed away", and is how the cursor gets
## hidden rather than clamped at the edge. The cursor path could never do that:
## it binds no Hide control, so pointing at the ceiling left the hand stuck to the
## border.
func _blank_ir(libretro: Libretro) -> void:
	for i in range(IR_OBJECTS):
		_send_pointer(libretro, i, 0, 0, false)
	_laser_dot.visible = false


func _update_aim(libretro: Libretro) -> void:
	var pose := _camera_pose()
	var leds := _visible_leds()
	if leds.is_empty():
		# Both real reasons look the same from the room — no bar in a socket, or a
		# console nobody switched on — so say so plainly.
		_log_aim("no sensor bar lit anywhere — plug one into a Wii and power up")
		_blank_ir(libretro)
		return

	var cam_inv := pose.affine_inverse()
	var points: Array[Vector3] = []
	for led: Vector3 in leds:
		var p := _project_to_camera(cam_inv, led)
		if p.z > 0.0:
			points.append(p)

	# More lights than slots is possible — two bars is four dots, and the camera
	# has four. Keep the NEAREST, because that is how the real sensor picks: it
	# tracks blobs by size, and a closer light is a bigger one.
	points.sort_custom(_sort_nearest_first)
	points.resize(mini(points.size(), IR_OBJECTS))
	# Then into slot order: descending x, which is what Dolphin's own camera
	# produces (its LED array starts at world -X, the end that lands HIGH in
	# sensor x). Sorted rather than taken from the scene, because the bar is a
	# pickable and a player can turn it round.
	points.sort_custom(_sort_sensor_x_desc)

	for i in range(IR_OBJECTS):
		var p: Vector3 = points[i] if i < points.size() else Vector3.ZERO
		# Normalised over the sensor, because the core's IRPassthrough group scales
		# a 0..1 control back up by (RES - 1). It reads the POSITIVE half of the
		# pointer range only, so 0 is the left/top edge and 32767 the right/bottom.
		_send_pointer(libretro, i,
			int(p.x / (CAMERA_RES_X - 1.0) * POINTER_SCALE),
			int(p.y / (CAMERA_RES_Y - 1.0) * POINTER_SCALE),
			p.z > 0.0)

	_log_aim_counts(points.size(), leds.size())
	if not points.is_empty():
		_log_aim_points(points)
	_update_laser_dot(pose)


## The dot on the glass. Purely a courtesy now — the aim above never touches the
## screen — but it is the only feedback saying where the barrel is pointed, and on
## the desktop it is the only way to see the aim at all.
func _update_laser_dot(pose: Transform3D) -> void:
	if not show_laser_dot:
		_laser_dot.visible = false
		return
	# Look again if we have no glass, or the set we had went away (unplugged,
	# swapped, deleted). Cheap: two null checks on the frames it succeeds.
	if not is_instance_valid(_screen_mesh):
		_screen_mesh = null
		_cache_screen_geometry()
	if _screen_mesh == null or _screen_w == 0.0:
		_laser_dot.visible = false
		return

	var screen_transform := _screen_mesh.global_transform
	var screen_normal := screen_transform.basis.z.normalized()
	var plane := Plane(screen_normal, screen_transform.origin)
	var hit: Variant = plane.intersects_ray(pose.origin, -pose.basis.z)
	if hit == null:
		_laser_dot.visible = false
		return

	var local: Vector3 = screen_transform.affine_inverse() * (hit as Vector3)
	var u := (local.x / _screen_w) + 0.5
	var v := (-local.y / _screen_h) + 0.5
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		_laser_dot.visible = false
		return
	_laser_dot.visible = true
	_laser_dot.global_position = (hit as Vector3) + screen_normal * 0.002


# ── Accelerometer ─────────────────────────────────────────────────────────────

## Derive what the remote's accelerometer would read and hand it to the core in g.
func _send_accel(libretro: Libretro, delta: float) -> void:
	if delta <= 0.0:
		return

	# Proper acceleration is what an accelerometer measures: motion MINUS gravity,
	# so a remote at rest reads +1g upward rather than nothing.
	var velocity := linear_velocity
	var a_world := (velocity - _prev_velocity) / delta + Vector3.UP * G
	_prev_velocity = velocity
	_accel_smoothed = _accel_smoothed.lerp(a_world, ACCEL_SMOOTHING)

	var g_vec := accel_in_wiimote_frame()
	if not NetworkManager.netplay_set_aux_sensor(_connected_system, _port_index, 0,
			int(g_vec.x * 1000.0), int(g_vec.y * 1000.0), int(g_vec.z * 1000.0)):
		libretro.SetSensorAccel(_port_index, g_vec.x, g_vec.y, g_vec.z)

	# And the Nunchuk's, on the same port. The remote owns the slot and makes
	# every core call for the pair, so a Nunchuk seated directly and one seated
	# behind a dongle are the same thing from here: _nunchuk is the one answer.
	if _has_nunchuk() and _nunchuk != null:
		var n_vec: Vector3 = _nunchuk.accel_in_nunchuk_frame()
		if not NetworkManager.netplay_set_aux_sensor(_connected_system, _port_index,
				NUNCHUK_SENSOR_INDEX, int(n_vec.x * 1000.0), int(n_vec.y * 1000.0),
				int(n_vec.z * 1000.0)):
			libretro.SetSensorAccel(_port_index, n_vec.x, n_vec.y, n_vec.z,
				NUNCHUK_SENSOR_INDEX)


## The smoothed world acceleration expressed on the emulated remote's own axes,
## in g. Split out from _send_accel because this is where the whole thing can go
## quietly wrong: it is two coordinate changes in a row and nothing downstream
## complains about a wrong one, the game just tilts the wrong way.
##
## Godot has -Z forward, +Y up, +X right. Dolphin's remote has +X LEFT, +Y BACK,
## +Z UP (IMUAccelerometer::GetState, which reads x as Left-Right, y as
## Backward-Forward, z as Up-Down). Level and pointing forward at rest that gives
## (0, 0, 1) — the same at-rest reading the GDExtension returns when nothing is
## driving the sensor at all.
func accel_in_wiimote_frame() -> Vector3:
	var a := MotionFilter.deadband_motion(_accel_smoothed, G)
	var local := _barrel_tip.global_transform.basis.inverse() * (a / G)
	return Vector3(-local.x, local.z, local.y)


# ── Gyroscope ─────────────────────────────────────────────────────────────────

## Derive the remote's angular velocity and hand it to the core in radians/second.
##
## This is what MotionPlus reports, and without it Wii Sports Resort and Skyward
## Sword have nothing to read. It is measured from how the BarrelTip's orientation
## changed since last frame rather than from the RigidBody's angular_velocity,
## because a held pickable is frozen (pickable.gd sets freeze = true on pickup) and
## a frozen body's velocities are the physics server's business, not ours. The
## barrel's own basis is true whatever the body is doing, and it is the frame the
## answer is wanted in anyway.
##
## Note the core low-passes nothing and calibrates instead: IMUGyroscope averages a
## few seconds of stable input and subtracts it, so a small constant bias from VR
## tracking jitter is removed for free. What it cannot remove is a spike, which is
## why GYRO_MIN_ANGLE and the smoothing below are here.
func _send_gyro(libretro: Libretro, delta: float) -> void:
	if delta <= 0.0:
		return

	var basis_now := _barrel_tip.global_transform.basis.orthonormalized()
	if not _has_prev_tip_basis:
		_prev_tip_basis = basis_now
		_has_prev_tip_basis = true
		return

	var q_prev := _prev_tip_basis.get_rotation_quaternion()
	var q_now := basis_now.get_rotation_quaternion()
	_prev_tip_basis = basis_now

	# q and -q name the same orientation, so the difference between two of them
	# can describe either the short way round or the long way. Flip one to force
	# the short arc, because otherwise a sign change reads as a near-360° flick.
	if q_prev.dot(q_now) < 0.0:
		q_prev = -q_prev

	# The rotation that took the barrel from where it was to where it is, in world
	# space. Its axis is the axis of rotation and its angle over dt is the rate.
	var dq := (q_now * q_prev.inverse()).normalized()
	var angle := dq.get_angle()
	var w_world := Vector3.ZERO
	if angle > GYRO_MIN_ANGLE:
		w_world = dq.get_axis() * (angle / delta)

	_gyro_smoothed = _gyro_smoothed.lerp(w_world, GYRO_SMOOTHING)

	var rad := gyro_in_wiimote_frame()
	if not NetworkManager.netplay_set_aux_sensor(_connected_system, _port_index, 0,
			int(rad.x * 100.0), int(rad.y * 100.0), int(rad.z * 100.0), true):
		libretro.SetSensorGyro(_port_index, rad.x, rad.y, rad.z)


## The smoothed angular velocity on the emulated remote's own axes, in rad/s.
##
## The same change of basis the accelerometer uses, and for the same reason:
## Godot has -Z forward/+Y up/+X right, Dolphin's remote has +X LEFT, +Y BACK,
## +Z UP. That swap is a proper rotation (its determinant is +1), which is what
## makes it legal to apply to an angular velocity at all: a mirrored basis would
## need the sign flipped back, because rotation is a pseudovector and does not
## survive a reflection the way a position does.
##
## Dolphin reads these right-handed about those axes, so +X is pitching the nose
## DOWN, +Y is rolling the top to the LEFT, and +Z is swinging the nose LEFT
## (Input.cpp binds each to the matching half of a GyroX/Y/Z± pair).
func gyro_in_wiimote_frame() -> Vector3:
	var local := _barrel_tip.global_transform.basis.orthonormalized().inverse() * _gyro_smoothed
	return Vector3(-local.x, local.z, local.y)

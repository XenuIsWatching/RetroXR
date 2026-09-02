## LightGun — pickable light gun that plugs into a RetroSystem controller port.
## While held and plugged in: casts a ray from the barrel to the TV screen each
## frame and reports the hit position as libretro lightgun coordinates.
## Button mappings are data-driven via ControllerBindings.
##
## Desktop mode (grabbed by DesktopHand group):
##   desktop_fps_snap = true  → desktop_pickup.gd locks the gun to the camera
##   lower-right (FPS weapon view).  Aiming uses the camera centre ray so the
##   crosshair reticle always matches where the gun is pointing.
##   Trigger  = left mouse button  (trigger_left action)
##   Aux/dpad = RETRO_JOYPAD_* keyboard actions
class_name LightGun
extends XRToolsPickable


const CONTROLLER_CABLE_SCENE := preload("res://Scenes/Objects/cables/controller_cable.tscn")
const RETRO_DEVICE_LIGHTGUN := 7
const DPAD_THRESHOLD := 0.35

## Input thresholds per XRController float input name.
const INPUT_THRESHOLDS: Dictionary = {
	"trigger":       0.3,
	"grip":          0.3,
	"ax_button":     0.5,
	"by_button":     0.5,
	"primary_click": 0.5,
}

## Desktop lightgun button map: Godot action name → LIGHTGUN_* id.
const DESKTOP_LIGHTGUN_BUTTONS: Dictionary = {
	"trigger_left":        ControllerBindings.LIGHTGUN_TRIGGER,
	"RETRO_JOYPAD_A":      ControllerBindings.LIGHTGUN_AUX_A,
	"RETRO_JOYPAD_B":      ControllerBindings.LIGHTGUN_AUX_B,
	"RETRO_JOYPAD_START":  ControllerBindings.LIGHTGUN_START,
	"RETRO_JOYPAD_SELECT": ControllerBindings.LIGHTGUN_SELECT,
}

## Set true so desktop_pickup.gd uses FPS-snap positioning instead of ray-hold.
var desktop_fps_snap: bool = true

## Height of the drop hint above the gun, in metres.
const HINT_HEIGHT := 0.16
var _hint: HeldHint = null

## libretro device type reported to the system when plugged in.
var device_type: int = RETRO_DEVICE_LIGHTGUN

## Whether to show the laser-dot aim indicator on the screen.
var show_laser_dot: bool = true

# Active bindings (loaded from ControllerBindings on plug-in)
var _lightgun_map: Dictionary = ControllerBindings.DEFAULT_LIGHTGUN_MAP.duplicate()

# Port connection state
var _connected_system: RetroSystem = null
var _port_index: int = -1

# Cable
var _cable_instance: Node3D = null
var _cable_plug: ControllerPlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0

# Pending port restore (set before cable is ready)
var _pending_port_restore: Dictionary = {}

# Cached screen geometry (set on plug-in, cleared on unplug)
var _screen_mesh: MeshInstance3D = null
var _screen_w: float = 0.0
var _screen_h: float = 0.0

# Toggle-hold state (VR)
var _allow_drop := false
var _saved_by: Node3D = null
var _holding_ctrl: XRController3D = null

# Desktop-hold state
var _desktop_held: bool = false

var _locomotion_manager: LocomotionManager = null
var _spawn_menu_ctrl: Node = null
var _left_vr_ctrl: XRController3D = null
var _right_vr_ctrl: XRController3D = null

# Reference-counted pointer blocking — prevents multi-instance conflicts.
var _blocking_left: bool = false
var _blocking_right: bool = false

@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _barrel_tip: Node3D = $BarrelTip
@onready var _laser_dot: MeshInstance3D = $LaserDot

# ── Physical control animation ────────────────────────────────────────────────
# The shell's trigger and buttons are display-only: the gun is aimed and fired
# from the VR controller (or the keyboard on desktop), so these show what the
# hand is doing. Driven from _pressed_now(), the same read that goes to the core,
# so the shell can never disagree with what the game is being told.

## Buttons that press into the barrel's top face, by the lightgun id they show.
const ANIM_BUTTONS: Dictionary = {
	ControllerBindings.LIGHTGUN_AUX_A: "AuxAButton",
	ControllerBindings.LIGHTGUN_AUX_B: "AuxBButton",
	ControllerBindings.LIGHTGUN_START: "StartButton",
}
## Kept well under how far the caps stand proud of the barrel (3 mm) — press
## them further and they read as vanishing into it rather than being pushed.
const BUTTON_PRESS := 0.001
## Trigger swing. Negative about +X so the blade's tip sweeps BACK toward the
## grip — a positive angle would push it forward, out of the hand.
const TRIGGER_PULL_DEG := -14.0
const ANIM_WEIGHT := 0.4

var _anim_btns: Array[Dictionary] = []   # {node, rest, lid}
var _trigger_pivot: Node3D = null
var _trigger_rest := Transform3D()


## The trigger fires the gun and the thumbstick is the lightgun d-pad, so the
## push-out gesture has nothing to bind to. Catching one back off the laser
## still works. Queried by function_pickup._handoff_eligible.
func wants_ray_handoff() -> bool:
	return false


func _ready() -> void:
	super._ready()
	press_to_hold = false
	add_to_group("spawned")
	add_to_group(ControllerBindings.CONSUMER_GROUP)
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	_hint = HeldHint.attach(self, true, HINT_HEIGHT)
	_laser_dot.visible = false
	_cache_controls()
	_spawn_cable()
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
	# A spawn-menu spawn is handed to the grabbing hand before this deferred lookup
	# runs, so that grab found no manager and never blocked locomotion. Re-apply.
	_update_locomotion_block()


# ── Toggle-hold ───────────────────────────────────────────────────────────────

func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	if _hint:
		_hint.on_grabbed(by)
	var pickup := by as XRToolsFunctionPickup
	var ctrl := pickup.get_controller() if pickup else null as XRController3D
	if ctrl == null:
		# Desktop pickup: just flag desktop-held mode, don't set up VR toggle-hold
		if by.is_in_group("desktop_hand"):
			_desktop_held = true
			_laser_dot.visible = _connected_system != null and show_laser_dot
		return
	_saved_by = by
	_holding_ctrl = ctrl
	_set_model_visible(ctrl, false)
	_update_pointer_block(ctrl, true)
	_update_locomotion_block()


func _on_dropped_signal(_pickable: Node3D) -> void:
	if not _allow_drop and is_instance_valid(_saved_by):
		PokeTip.begin_rehold(_holding_ctrl)
		call_deferred("_rehold")
	else:
		if _hint:
			_hint.on_dropped()
		_set_model_visible(_holding_ctrl, true)
		_update_pointer_block(_holding_ctrl, false)
		_allow_drop = false
		_saved_by = null
		_holding_ctrl = null
		_desktop_held = false
		_laser_dot.visible = false
		_update_locomotion_block()


func _rehold() -> void:
	if _allow_drop:
		_allow_drop = false
		return
	if not is_instance_valid(_saved_by):
		_set_model_visible(_holding_ctrl, true)
		_update_pointer_block(_holding_ctrl, false)
		_saved_by = null
		_holding_ctrl = null
		_update_locomotion_block()
		return
	_saved_by.call("_pick_up_object", self)


func _set_model_visible(ctrl: XRController3D, shown: bool) -> void:
	if is_instance_valid(ctrl) and ctrl.has_method("set_model_visible"):
		ctrl.call("set_model_visible", shown)


## The combo test itself lives on HeldHint so the check and the row advertising
## it cannot disagree. Counting the use here rather than at the drop branch is
## deliberate: a predicate every drop passes through cannot be missed when
## another is added. HeldHint counts once per hold, so testing every frame does
## not inflate it.
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
	_laser_dot.visible = false
	_update_locomotion_block()
	drop()


func _exit_tree() -> void:
	if _blocking_left and is_instance_valid(_left_vr_ctrl):
		_update_pointer_block(_left_vr_ctrl, false)
	if _blocking_right and is_instance_valid(_right_vr_ctrl):
		_update_pointer_block(_right_vr_ctrl, false)
	if _locomotion_manager != null:
		_locomotion_manager.clear_owner(_vr_block_owner())
		_locomotion_manager.set_block(_desktop_block_owner(),
			LocomotionManager.CHANNEL_DESKTOP_MOVE, false)
	_allow_drop = true
	super._exit_tree()


## Per-instance owner for the VR channels. Shared owner keys let one object
## erase another's block -- see LocomotionManager.set_block for what that cost.
func _vr_block_owner() -> StringName:
	return StringName("retro_hold_%d" % get_instance_id())


func _update_locomotion_block() -> void:
	var left_held  := is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"left_hand"
	var right_held := is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"right_hand"
	var desktop_claim := _desktop_held and _connected_system != null and _port_index >= 0
	if _locomotion_manager != null:
		_locomotion_manager.set_block(_vr_block_owner(), LocomotionManager.CHANNEL_LEFT,  left_held)
		_locomotion_manager.set_block(_vr_block_owner(), LocomotionManager.CHANNEL_RIGHT, right_held)
	# Desktop has no hands, so the tracker tests above never fire there. The
	# desktop providers poll the InputMap, so blocking them is the only way to
	# stop WASD reaching the player while this device is claiming it.
		_locomotion_manager.set_block(_desktop_block_owner(),
			LocomotionManager.CHANNEL_DESKTOP_MOVE, desktop_claim)
	if is_instance_valid(_spawn_menu_ctrl) and "disabled" in _spawn_menu_ctrl:
		_spawn_menu_ctrl.set("disabled", left_held)


## Reference-counted pointer blocking (same mechanism as RetroController).
func _update_pointer_block(ctrl: XRController3D, should_block: bool) -> void:
	if not is_instance_valid(ctrl):
		return
	var is_left := ctrl.tracker == &"left_hand"
	var currently_blocking: bool = _blocking_left if is_left else _blocking_right
	if should_block == currently_blocking:
		return
	if is_left:
		_blocking_left = should_block
	else:
		_blocking_right = should_block
	var pointer: Node3D = ctrl.get_node_or_null("FunctionPointer")
	if not pointer:
		return
	var delta_count := 1 if should_block else -1
	var count: int = maxi(0, pointer.get_meta("block_count", 0) + delta_count)
	pointer.set_meta("block_count", count)
	pointer.visible = count == 0
	var ray: RayCast3D = pointer.get_node_or_null("RayCast") as RayCast3D
	if ray:
		ray.enabled = count == 0


# ── Cable ─────────────────────────────────────────────────────────────────────

func _spawn_cable() -> void:
	_cable_instance = CONTROLLER_CABLE_SCENE.instantiate()
	call_deferred("_add_cable_to_scene")


func _add_cable_to_scene() -> void:
	get_tree().current_scene.add_child(_cable_instance)
	_cable_instance.add_to_group("spawned")
	_cable_plug = _cable_instance.get_node("ControllerPlug") as ControllerPlug
	_cable_rope = _cable_instance.get_node("VerletRope") as VerletRope
	_cable_plug.set_controller(self)
	_cable_plug.add_collision_exception_with(self)
	_cable_plug.global_position = _cable_attach_point.global_position + Vector3(0, 0, -0.12)
	_cable_rope.start_node = _cable_attach_point
	_cable_rope.end_node = _cable_plug
	_cable_rope._init_points()
	_max_rope_length = _cable_rope.segment_count * _cable_rope.segment_length

	if not _pending_port_restore.is_empty():
		var sys: RetroSystem = _pending_port_restore.get("system")
		var idx: int = _pending_port_restore.get("port_index", -1)
		_pending_port_restore = {}
		if is_instance_valid(sys) and idx >= 0:
			sys.restore_controller_plug(idx, _cable_plug)


## Cache the control meshes. Absent on an older scene, in which case the gun just
## has nothing to animate.
func _cache_controls() -> void:
	for lid: int in ANIM_BUTTONS:
		var m := get_node_or_null(String(ANIM_BUTTONS[lid])) as MeshInstance3D
		if m != null:
			_anim_btns.append({"node": m, "rest": m.transform, "lid": lid})
	_trigger_pivot = get_node_or_null("TriggerPivot") as Node3D
	if _trigger_pivot != null:
		_trigger_rest = _trigger_pivot.transform


## Hysteresis for the analog VR sources — see InputLatch. Without it a single
## squeeze reaches the core as two presses.
var _latch := InputLatch.new()


## Which lightgun buttons are down this frame, keyed by LIGHTGUN_* id. One read
## of the input, shared by the core and the shell animation. Every mapped id is
## present, so an unheld gun reports them all false rather than reporting nothing.
func _pressed_now() -> Dictionary:
	var out: Dictionary = {}
	if _desktop_held:
		for action_name: String in DESKTOP_LIGHTGUN_BUTTONS:
			var lid: int = DESKTOP_LIGHTGUN_BUTTONS[action_name]
			if lid >= 0:
				out[lid] = Input.is_action_pressed(action_name)
		return out
	var vr: bool = is_instance_valid(_holding_ctrl)
	for vr_source: String in _lightgun_map:
		if vr_source == "stick":
			continue
		var lid: int = _lightgun_map[vr_source]
		if lid < 0:
			continue
		var key := "%d:%s" % [_holding_ctrl.get_instance_id() if vr else 0, vr_source]
		var value: float = _holding_ctrl.get_float(vr_source) if vr else 0.0
		out[lid] = _latch.pressed(key, value, float(INPUT_THRESHOLDS.get(vr_source, 0.5)))
	return out


func _animate_controls(pressed: Dictionary) -> void:
	for e: Dictionary in _anim_btns:
		var node: MeshInstance3D = e["node"]
		var rest: Transform3D = e["rest"]
		var down := 1.0 if pressed.get(int(e["lid"]), false) else 0.0
		var tgt := Transform3D(rest.basis, rest.origin + Vector3.DOWN * (BUTTON_PRESS * down))
		node.transform = node.transform.interpolate_with(tgt, ANIM_WEIGHT)
	if _trigger_pivot == null:
		return
	var pull := 1.0 if pressed.get(ControllerBindings.LIGHTGUN_TRIGGER, false) else 0.0
	var tgt_x := Transform3D(
		_trigger_rest.basis * Basis(Vector3.RIGHT, deg_to_rad(TRIGGER_PULL_DEG * pull)),
		_trigger_rest.origin)
	_trigger_pivot.transform = _trigger_pivot.transform.interpolate_with(tgt_x, ANIM_WEIGHT)


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


# ── Port events ───────────────────────────────────────────────────────────────

func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	_connected_system = system
	_port_index = port_index
	_laser_dot.visible = true
	_load_bindings()
	print("[LightGun] plugged into system port %d" % port_index)
	_cache_screen_geometry()


## Reload bindings from disk (called externally after the user saves new bindings).
func reload_bindings() -> void:
	_load_bindings()


func _load_bindings() -> void:
	var systemid := ""
	if is_instance_valid(_connected_system):
		systemid = _connected_system.systemid
	var bindings := ControllerBindings.get_for_system(systemid)
	_lightgun_map = bindings["lightgun"]


func on_unplugged() -> void:
	print("[LightGun] unplugged from port %d" % _port_index)
	_laser_dot.visible = false
	_connected_system = null
	_port_index = -1
	_screen_mesh = null
	_screen_w = 0.0
	_screen_h = 0.0


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


func restore_port_connection(system: RetroSystem, port_index: int) -> void:
	if _cable_plug != null:
		system.restore_controller_plug(port_index, _cable_plug)
	else:
		_pending_port_restore = {"system": system, "port_index": port_index}


# ── Input forwarding ──────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	# VR drop combo (desktop drop is handled by desktop_pickup via left click)
	if _is_combo_pressed(_holding_ctrl):
		_drop_all()
		return

	# The shell moves whether or not it is plugged into anything — an unplugged
	# gun still has a trigger you can squeeze.
	var pressed := _pressed_now()
	_animate_controls(pressed)

	if _connected_system == null or _port_index < 0:
		return

	var libretro := _connected_system.get_libretro_node()

	# Desktop mode: aim from camera centre, read keyboard/mouse for buttons
	if _desktop_held:
		_process_desktop_lightgun(libretro, pressed)
		return

	# VR mode: no controller held → report offscreen and clear buttons
	if not is_instance_valid(_holding_ctrl):
		_set_aim(libretro, 0, 0, true)
		for lid: int in pressed:
			_set_button(libretro, lid, false)
		if _lightgun_map.get("stick", "none") == "dpad":
			_set_button(libretro, 8, false)
			_set_button(libretro, 9, false)
			_set_button(libretro, 10, false)
			_set_button(libretro, 11, false)
		_laser_dot.visible = false
		return

	var ctrl := _holding_ctrl

	# Buttons come from the map via _pressed_now(); "stick" is handled separately.
	for lid: int in pressed:
		_set_button(libretro, lid, pressed[lid])

	# Thumbstick → lightgun d-pad (thresholded).
	if _lightgun_map.get("stick", "none") == "dpad":
		var stick: Vector2 = ctrl.get_vector2("primary")
		_set_button(libretro, 8, stick.y > DPAD_THRESHOLD)
		_set_button(libretro, 9, stick.y < -DPAD_THRESHOLD)
		_set_button(libretro, 10, stick.x < -DPAD_THRESHOLD)
		_set_button(libretro, 11, stick.x > DPAD_THRESHOLD)

	_update_aim(libretro)


## Desktop: read keyboard+mouse, aim from camera centre ray.
func _process_desktop_lightgun(libretro: Libretro, pressed: Dictionary) -> void:
	for lid: int in pressed:
		_set_button(libretro, lid, pressed[lid])

	# D-pad from WASD/retro joypad actions
	_set_button(libretro, ControllerBindings.LIGHTGUN_DPAD_UP,
		Input.is_action_pressed("RETRO_JOYPAD_UP"))
	_set_button(libretro, ControllerBindings.LIGHTGUN_DPAD_DOWN,
		Input.is_action_pressed("RETRO_JOYPAD_DOWN"))
	_set_button(libretro, ControllerBindings.LIGHTGUN_DPAD_LEFT,
		Input.is_action_pressed("RETRO_JOYPAD_LEFT"))
	_set_button(libretro, ControllerBindings.LIGHTGUN_DPAD_RIGHT,
		Input.is_action_pressed("RETRO_JOYPAD_RIGHT"))

	_update_aim_desktop(libretro)


## VR aim: ray from barrel tip along barrel -Z.
func _update_aim(libretro: Libretro) -> void:
	if _screen_mesh == null or _screen_w == 0.0:
		_set_aim(libretro, 0, 0, true)
		_laser_dot.visible = false
		return

	var screen_transform := _screen_mesh.global_transform
	var screen_normal := screen_transform.basis.z
	var plane := Plane(screen_normal, screen_transform.origin)
	var ray_origin := _barrel_tip.global_position
	var ray_dir := -_barrel_tip.global_transform.basis.z

	_apply_aim_hit(libretro, plane, screen_transform, screen_normal, ray_origin, ray_dir)


## Desktop aim: ray from camera centre along camera -Z (matches the crosshair).
func _update_aim_desktop(libretro: Libretro) -> void:
	if _screen_mesh == null or _screen_w == 0.0:
		_set_aim(libretro, 0, 0, true)
		_laser_dot.visible = false
		return

	var cam := get_viewport().get_camera_3d()
	if not is_instance_valid(cam):
		_set_aim(libretro, 0, 0, true)
		_laser_dot.visible = false
		return

	var screen_transform := _screen_mesh.global_transform
	var screen_normal := screen_transform.basis.z
	var plane := Plane(screen_normal, screen_transform.origin)
	var ray_origin := cam.global_position
	var ray_dir := -cam.global_transform.basis.z

	_apply_aim_hit(libretro, plane, screen_transform, screen_normal, ray_origin, ray_dir)


## Shared hit-test and coordinate conversion for both VR and desktop aim.
func _apply_aim_hit(
		libretro: Libretro,
		plane: Plane,
		screen_transform: Transform3D,
		screen_normal: Vector3,
		ray_origin: Vector3,
		ray_dir: Vector3) -> void:

	var hit: Variant = plane.intersects_ray(ray_origin, ray_dir)

	if hit == null:
		_set_aim(libretro, 0, 0, true)
		_laser_dot.visible = false
		return

	var local: Vector3 = screen_transform.affine_inverse() * (hit as Vector3)

	var u := (local.x / _screen_w) + 0.5
	var v := (-local.y / _screen_h) + 0.5

	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		_set_aim(libretro, 0, 0, true)
		_laser_dot.visible = false
		return

	var lx := int((u * 2.0 - 1.0) * 32767)
	var ly := int((v * 2.0 - 1.0) * 32767)
	_set_aim(libretro, lx, ly, false)

	_laser_dot.visible = show_laser_dot
	_laser_dot.global_position = (hit as Vector3) + screen_normal * 0.002


func _set_button(libretro: Libretro, button: int, pressed: bool) -> void:
	if not NetworkManager.netplay_set_lightgun_button(_connected_system, _port_index,
			button, pressed):
		libretro.SetLightgunButton(_port_index, button, pressed)


func _set_aim(libretro: Libretro, x: int, y: int, offscreen: bool) -> void:
	if not NetworkManager.netplay_set_lightgun_aim(_connected_system, _port_index,
			x, y, offscreen):
		libretro.SetLightgunPosition(_port_index, x, y)
		libretro.SetLightgunIsOffscreen(_port_index, offscreen)


## Per-instance owner for the desktop channel. Several objects share the
## "retro_hold" key on the VR channels, so whichever updated last would otherwise
## clear a block another object still wants.
func _desktop_block_owner() -> StringName:
	return StringName("desktop_hold_%d" % get_instance_id())

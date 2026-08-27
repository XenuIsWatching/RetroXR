## RetroMouse — pickable mouse that plugs into a RetroSystem controller port
## (same cable/plug as a controller). While held ON a surface and plugged in,
## lateral motion is reported as libretro RETRO_DEVICE_MOUSE relative deltas
## (Mario Paint, ScummVM, DOS…). Trigger = left button, A = right, B = middle.
##
## Surface stickiness: when the mouse comes near a surface it GLUES to the
## surface plane — the visible mouse is the hand's position projected onto the
## plane, so micro lifts and wobbles neither show nor move the cursor. Only
## when the hand pulls farther than the break threshold does the visual snap back to
## the hand's true position (and motion reporting stops until it re-lands).
class_name RetroMouse
extends XRToolsPickable


const CONTROLLER_CABLE_SCENE := preload("res://Scenes/Objects/cables/controller_cable.tscn")
const OPTIONS_PANEL_SCENE := preload("res://Scenes/UI/mouse_options_panel.tscn")
const RETRO_DEVICE_MOUSE := 2

# libretro RETRO_DEVICE_ID_MOUSE_* button bits (C++ tests buttons & (1 << id)).
const MOUSE_BTN_LEFT := 1 << 2
const MOUSE_BTN_RIGHT := 1 << 3
const MOUSE_BTN_MIDDLE := 1 << 6

## Cursor units reported per metre of surface travel.
@export var sensitivity: float = 2400.0

## Mesh resource for this mouse's cable connector. The default is the PC99 green
## PS/2 plug — the mouse half of the colour code, and the only thing that tells
## this lead from the keyboard's once both are plugged in. A console mouse points
## it at its own connector instead. Authored in ControllerPlug's frame (origin at
## the seated position, connector on +Z, cable trailing -Z), which is what lets
## set_plug_mesh derive cable_anchor from it.
const PLUG_MESH := "res://Scenes/Objects/cables/ps2_plug_mouse.res"
@export var plug_mesh_path: String = PLUG_MESH

## The systemid this mouse physically belongs to, e.g. "super_nes". A port only
## accepts a plug whose systemid matches — the same filter RetroController uses.
##
## Empty means UNIVERSAL and fits anything, which is what the generic mouse wants:
## it stands in for hardware we have no model of on every system that reads a
## RETRO_DEVICE_MOUSE, from ScummVM to DOS.
@export var systemid: String = ""

## Bounds for stick_distance (metres), shared with MouseOptions2D's slider.
const STICK_MIN := 0.01
const STICK_MAX := 0.10
## How much farther than stick_distance the hand must pull before the stick
## breaks. Held as a RATIO rather than a second setting so a player who raises
## the engage distance does not get a mouse that lands and lets go at once.
const STICK_BREAK_RATIO := 2.0
## Slack on the raycast beyond stick_distance — the ray has to reach past the
## engage threshold or the distance test never gets a hit to measure.
const STICK_RAY_SLACK := 0.02

## Base-to-surface distance that engages the stick (metres). A player setting,
## because how high a hand hovers over a desk is a personal thing and the
## surfaces vary: set it low and the mouse only lands when pressed down, high
## and it grabs the table from a hover.
@export var stick_distance: float = 0.035:
	set(value):
		stick_distance = clampf(value, STICK_MIN, STICK_MAX)
		_apply_ray_length()

## libretro device type reported to the system when plugged in.
var device_type: int = RETRO_DEVICE_MOUSE

## Desktop: plain left-click is the mouse's own LEFT button while held, so
## dropping requires Shift+click (same rule as the light gun's trigger).
var desktop_shift_drop := true

## Height of the drop hint above the mouse, in metres.
const HINT_HEIGHT := 0.14
var _hint: HeldHint = null

var _options_panel: MouseOptionsPanel = null

# Port connection state
var _connected_system: RetroSystem = null
var _port_index: int = -1

# Cable (same pattern as RetroController)
var _cable_instance: Node3D = null
var _cable_plug: ControllerPlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0
var _pending_port_restore: Dictionary = {}

# Hold state
var _holding_ctrl: XRController3D = null
var _desktop_held := false

# Sticky-surface state
var _stuck := false
var _plane := Plane()
var _accum := Vector2.ZERO    # metres of surface travel, pending report
var _carry := Vector2.ZERO    # fractional cursor units carried between frames
var _last_buttons := 0

@onready var _visual: Node3D = $MouseVisual
@onready var _ray: RayCast3D = $SurfaceRay
## Child of the VISUAL, not of the body: while the mouse is stuck the visual is
## top_level on the surface plane and the body stays with the hand, so a cord
## anchored to the body would trail up into the air.
@onready var _cable_attach_point: Node3D = $MouseVisual/CableAttachPoint

# ── Button animation ──────────────────────────────────────────────────────────
# The shell already models both buttons and the wheel; they just never moved.
# Driven from _poll_buttons(), the same read that goes to the core, so the shell
# cannot disagree with what the game is being told. Wheel-click depresses the
# wheel, which is what the hardware does — there is no scroll axis to roll it.

## Mesh under MouseVisual for each button bit.
const ANIM_BUTTONS: Dictionary = {
	MOUSE_BTN_LEFT:   "LeftButton",
	MOUSE_BTN_RIGHT:  "RightButton",
	MOUSE_BTN_MIDDLE: "WheelMesh",
}
const BUTTON_PRESS := 0.0012
const ANIM_WEIGHT := 0.45
## Rumble queue slot for a click on this mouse's own buttons.
const HAPTIC_KEY := &"mouse_btn"

var _anim_btns: Array[Dictionary] = []   # {node, rest, bit}
# Button bits the haptics have already ticked for.
var _haptic_buttons := 0


## The trigger is this mouse's left button, so it can't double as the push-out
## modifier. Catching one back off the laser still works. Queried by
## function_pickup._handoff_eligible.
func wants_ray_handoff() -> bool:
	return false


func _ready() -> void:
	super._ready()
	press_to_hold = false
	add_to_group("spawned")
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	# No VR drop row: in VR the mouse lets go on a plain grip release. The
	# desktop Shift rule is read off desktop_shift_drop by HeldHint itself.
	_hint = HeldHint.attach(self, false, HINT_HEIGHT)
	_apply_ray_length()
	_cache_buttons()
	_spawn_cable()


# ── Cable (mirrors RetroController) ──────────────────────────────────────────

func _spawn_cable() -> void:
	_cable_instance = CONTROLLER_CABLE_SCENE.instantiate()
	call_deferred("_add_cable_to_scene")


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
	# End the cord AT the connector's cable boss. The plug's origin is its
	# SEATING reference, buried up at the collar, so a zero offset runs the tube
	# out through the barrel.
	_cable_rope.end_anchor_offset = _cable_plug.cable_anchor
	_cable_rope._init_points()
	_max_rope_length = _cable_rope.segment_count * _cable_rope.segment_length

	if not _pending_port_restore.is_empty():
		var sys: RetroSystem = _pending_port_restore.get("system")
		var idx: int = _pending_port_restore.get("port_index", -1)
		_pending_port_restore = {}
		if is_instance_valid(sys) and idx >= 0:
			sys.restore_controller_plug(idx, _cable_plug)


# ── Port events (duck-typed contract used by RetroSystem) ────────────────────

func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	_connected_system = system
	_port_index = port_index
	print("[RetroMouse] plugged into system port %d" % port_index)


func on_unplugged() -> void:
	print("[RetroMouse] unplugged from port %d" % _port_index)
	_connected_system = null
	_port_index = -1


func restore_port_connection(system: RetroSystem, port_index: int) -> void:
	if _cable_plug != null:
		system.restore_controller_plug(port_index, _cable_plug)
	else:
		_pending_port_restore = {"system": system, "port_index": port_index}


## Toggle the floating settings panel (sensitivity, stick distance). Called by
## SpawnMenuController when the menu button is pressed while pointing here.
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel == null:
		_options_panel = OPTIONS_PANEL_SCENE.instantiate()
		add_child(_options_panel)
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)


# ── Hold tracking ─────────────────────────────────────────────────────────────

func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	if _hint:
		_hint.on_grabbed(by)
	var pickup := by as XRToolsFunctionPickup
	var ctrl := pickup.get_controller() if pickup else null as XRController3D
	if ctrl:
		_holding_ctrl = ctrl
	elif by.is_in_group("desktop_hand"):
		_desktop_held = true


func _on_dropped_signal(_pickable: Node3D) -> void:
	if _hint:
		_hint.on_dropped()
	_holding_ctrl = null
	_desktop_held = false
	_unstick()


# ── Sticky surface ────────────────────────────────────────────────────────────

func _physics_process(_delta: float) -> void:
	# Cable rope clamp (same as RetroController).
	if _cable_plug != null and _cable_attach_point != null and _max_rope_length > 0.0 \
			and not _cable_plug.is_picked_up() and _connected_system == null:
		var attach_pos := _cable_attach_point.global_position
		var diff := _cable_plug.global_position - attach_pos
		var dist := diff.length()
		if dist > _max_rope_length:
			var dir := diff / dist
			_cable_plug.global_position = attach_pos + dir * _max_rope_length
			var outward := dir.dot(_cable_plug.linear_velocity)
			if outward > 0.0:
				_cable_plug.linear_velocity -= dir * outward

	_update_sticky()


## The setter runs before @onready resolves _ray (and on a restored value set
## before the node enters the tree), so this is a no-op until _ready calls it.
func _apply_ray_length() -> void:
	if _ray != null:
		_ray.target_position = Vector3(0, -(stick_distance + STICK_RAY_SLACK), 0)


func _update_sticky() -> void:
	var held := is_picked_up() and (is_instance_valid(_holding_ctrl) or _desktop_held)
	if not held:
		if _stuck:
			_unstick()
		return

	if not _stuck:
		_ray.force_raycast_update()
		if _ray.is_colliding() \
				and global_position.distance_to(_ray.get_collision_point()) <= stick_distance:
			_stick(_ray.get_collision_point(), _ray.get_collision_normal())

	if _stuck:
		# Break only when the HAND (the body follows it) pulls past the
		# threshold — micro lifts stay glued and invisible.
		if absf(_plane.distance_to(global_position)) > stick_distance * STICK_BREAK_RATIO:
			_unstick()
			return
		var before := _visual.global_position
		_apply_stick_visual()
		var delta3 := _visual.global_position - before
		# Express plane travel in the mouse's own frame: +x right, +y toward
		# the user (libretro mouse +y = cursor down = pulling the mouse back).
		var right := _visual.global_transform.basis.x
		var fwd := -_visual.global_transform.basis.z
		_accum += Vector2(delta3.dot(right), -delta3.dot(fwd))


func _stick(point: Vector3, normal: Vector3) -> void:
	_stuck = true
	_plane = Plane(normal.normalized(), point)
	_visual.top_level = true
	_apply_stick_visual()
	_accum = Vector2.ZERO


func _unstick() -> void:
	if not _stuck:
		return
	_stuck = false
	# Snap the visual back to the hand's true position.
	_visual.top_level = false
	_visual.transform = Transform3D.IDENTITY
	_accum = Vector2.ZERO


## Place the visual at the hand's position projected onto the surface plane,
## flattened so the mouse sits on the surface with the hand's yaw.
func _apply_stick_visual() -> void:
	var n := _plane.normal
	var pos := _plane.project(global_position)
	var fwd := -global_transform.basis.z
	fwd = fwd - n * fwd.dot(n)
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD - n * Vector3.FORWARD.dot(n)
	fwd = fwd.normalized()
	_visual.global_transform = Transform3D(
		Basis(fwd.cross(n), n, -fwd).orthonormalized(), pos + n * 0.001)


# ── Input reporting ───────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	# The shell moves whether or not it is plugged into anything — an unplugged
	# mouse still has buttons you can click.
	var buttons := _poll_buttons()
	_click_haptics(buttons)
	_animate_buttons(buttons)

	if _connected_system == null or _port_index < 0:
		return

	var move := _accum * sensitivity + _carry
	_accum = Vector2.ZERO
	var dx := int(move.x)
	var dy := int(move.y)
	_carry = move - Vector2(dx, dy)

	# Netplay: mouse deltas ride the deterministic schedule through the same
	# seam as joypads — dx/dy packed into the analog-left slots. "drain": the
	# session zeroes the deltas after the first scheduled frame consumes them
	# (deltas are per-frame quantities, unlike held joypad state). The emu
	# thread routes them to the mouse device because the port's device type is
	# RETRO_DEVICE_MOUSE.
	if NetworkManager.netplay_route(_connected_system, _port_index,
			{"btn": buttons, "alx": dx, "aly": dy, "arx": 0, "ary": 0, "drain": true}):
		_last_buttons = buttons
		return

	if dx != 0 or dy != 0 or buttons != _last_buttons:
		_connected_system.get_libretro_node().SetMouseState(_port_index, dx, dy, buttons)
		_last_buttons = buttons


## A tick on the hand holding the mouse for each button edge — the click a real
## microswitch would give back through the shell.
##
## Tracked apart from _last_buttons, which only advances once a PLUGGED-IN mouse
## reports; the buttons click whether or not anything is listening.
func _click_haptics(buttons: int) -> void:
	if buttons == _haptic_buttons:
		return
	var changed := buttons ^ _haptic_buttons
	_haptic_buttons = buttons
	# Down wins a frame that both presses and releases: it is the louder event.
	Haptics.click(_holding_ctrl, (buttons & changed) != 0, HAPTIC_KEY)


## Cache the button meshes. A mesh a scene doesn't carry is simply one this mouse
## cannot animate — the SNES mouse has no middle button, and an older scene has
## none of the three.
func _cache_buttons() -> void:
	for bit: int in ANIM_BUTTONS:
		var m := _find_button(String(ANIM_BUTTONS[bit]))
		if m != null:
			_anim_btns.append({"node": m, "rest": m.transform, "bit": bit})


## Find a button mesh anywhere under the visual, not just as a direct child: an
## imported shell nests its meshes inside the .glb's own root. Matched on a
## normalised name because Godot's glTF import rewrites punctuation.
func _find_button(base: String) -> MeshInstance3D:
	var target := _norm(base)
	for n: Node in _visual.find_children("*", "MeshInstance3D", true, false):
		if _norm(n.name) == target:
			return n as MeshInstance3D
	return null


static func _norm(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out


func _animate_buttons(buttons: int) -> void:
	for e: Dictionary in _anim_btns:
		var node: MeshInstance3D = e["node"]
		var down := 1.0 if (buttons & int(e["bit"])) != 0 else 0.0
		node.transform = node.transform.interpolate_with(_button_pose(e, down), ANIM_WEIGHT)


## Where a button sits at `down` (0 = rest, 1 = fully pressed). A moulded cap on
## a primitive shell just sinks straight in; a shell whose buttons are its whole
## front panel has to hinge instead, or the panel would part company with the
## body along the hinge line. Overridden per model.
func _button_pose(e: Dictionary, down: float) -> Transform3D:
	var rest: Transform3D = e["rest"]
	return Transform3D(rest.basis, rest.origin + Vector3.DOWN * (BUTTON_PRESS * down))


func _poll_buttons() -> int:
	var b := 0
	if is_instance_valid(_holding_ctrl):
		if _holding_ctrl.get_float("trigger") > 0.5:
			b |= MOUSE_BTN_LEFT
		if _holding_ctrl.get_float("ax_button") > 0.5:
			b |= MOUSE_BTN_RIGHT
		if _holding_ctrl.get_float("by_button") > 0.5:
			b |= MOUSE_BTN_MIDDLE
	elif _desktop_held:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			b |= MOUSE_BTN_LEFT
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			b |= MOUSE_BTN_RIGHT
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			b |= MOUSE_BTN_MIDDLE
	return b

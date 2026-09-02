## VRButton — Area3D that emits button_pressed when a VR controller interacts with it.
## Attach to any Area3D that has a child MeshInstance3D named "ButtonMesh".
## Uses direct XRController3D proximity checks each frame instead of physics
## bodies, so it reliably fires exactly where the controller/hand visually is.
## Also supports desktop reticle pointer hover/press.
##
## Two interaction modes:
##   • TOUCH (default) — the fingertip crossing trigger_radius fires the button
##     immediately. No confirmation, so a drifting hand presses things by accident.
##   • TRIGGER (require_trigger = true) — the fingertip entering the interaction
##     box only ARMS the button, outlining it green; pulling the controller's
##     TRIGGER then fires it and the outline turns amber. Same shape as VRHinge's
##     proximity-then-button latch, and the same amber for "engaged".
class_name VRButton
extends Area3D


signal button_pressed

const POINTABLE_LAYER := 1 << 20

## Rumble queue slot for a press. Shared across buttons: one hand can only be
## pressing one of them, and a retrigger under the same key restarts the tick.
const HAPTIC_KEY := &"vr_button"

## Analog trigger action, read as a float like the rest of the project
## (grip_click/trigger_click bools are only read by godot-xr-tools itself).
const TRIGGER_ACTION := "trigger"
## Float that arms→engages, and the lower value that releases (hysteresis).
## Mirrors VRHinge.GRIP_ON / GRIP_OFF.
const TRIGGER_ON := 0.6
const TRIGGER_OFF := 0.4


## How close (metres) the controller tip must be to trigger the button.
## The button face is at the top of the mesh, so ~half the mesh height is a
## good starting threshold.  TOUCH mode only — TRIGGER mode uses interact_margin.
@export var trigger_radius: float = 0.01

## Require a TRIGGER pull while the fingertip is inside the interaction box,
## instead of firing on touch alone. Off by default so authored buttons keep
## their existing behaviour until switched over scene by scene.
@export var require_trigger: bool = false

## How far (metres) the interaction box extends past the button mesh's own AABB,
## on every side. TRIGGER mode only.
@export var interact_margin: float = 0.02
## How far past the cap the visible fingertip starts snapping to its face
## (metres). Purely visual: it does not change when the button fires. Tighter
## than interact_margin so hovering between two adjacent console buttons
## (~20-25 mm pitch) does not ping-pong; PokeTip breaks any remaining tie by
## nearest.
@export var contact_margin: float = 0.015

## How much the mesh travels when pressed (metres)
@export var depress_depth: float = 0.008

## Direction the mesh moves when pressed, in the mesh PARENT's local space.
## Default (0,-1,0) pushes down on Y.  For front-face buttons derive it from
## the model's Finger Button empty's -Z axis via set_depress_axis_from_node().
@export var depress_axis: Vector3 = Vector3(0, -1, 0)

## Optional veto, called with a fingertip's WORLD position; false rejects the poke.
## Left empty by every button that has no side to it. See _gate_allows.
var press_gate: Callable = Callable()

# Cached original local position of the active mesh (in its parent's space)
var _mesh_local_origin: Vector3
# Parent node of the active mesh — used for direction-space conversion
var _mesh_depress_parent: Node3D = null

## Release distance as a multiple of trigger_radius. Matches the factor VRSlider
## already uses, so a button and a slider let go at the same relative slack.
const RELEASE_SCALE := 1.8
## Seconds a fingertip may be outside the release radius before the press drops.
## Sized to ride out a dropped tracking frame — it is a tail on how long every
## press lasts, so it stays short. See PokeTip.CONTACT_GRACE.
const CONTACT_GRACE := 0.05

# Visual state
var _touch_ctrl: XRController3D = null         # hand holding this button down
var _touch_lost: float = 0.0                   # seconds outside the release radius
var _touch_pressed: bool = false
var _pointer_pressed: bool = false
var _pointer_hovered: bool = false
var _latched_pressed: bool = false

# TRIGGER mode state
var _armed: bool = false                       # a fingertip is inside the box
var _trigger_pressed: bool = false             # trigger held after arming
var _engaged_ctrl: XRController3D = null       # controller holding the trigger
# Controller instance ids whose trigger has dropped below TRIGGER_OFF since they
# last fired this button — see _process_trigger_mode.
var _rearmed: Dictionary = {}
var _last_activate_frame: int = -1

@onready var _mesh: MeshInstance3D = $ButtonMesh

# Controller nodes — resolved once in _ready
var _controllers: Array[XRController3D] = []
var _outline: WidgetOutline = null
var _outline_amber: bool = false
# Pointable layer this button carries while active, captured before anything
# switches it off so set_active(true) restores what the scene authored.
var _active_layer: int = POINTABLE_LAYER


func _ready() -> void:
	collision_layer |= POINTABLE_LAYER
	_active_layer = collision_layer
	# Attached BEFORE the mesh is looked at, because set_button_mesh only sets an
	# outline source when there is already an outline to set it on.
	_outline = WidgetOutline.attach(self)
	# A button whose cap is measured off a shell carries no ButtonMesh in its own
	# scene and is handed one later by set_button_mesh, which records all of this
	# itself. Reading it here took the whole of _ready down with it: no outline,
	# and past the await below no _controllers either — and _process does nothing
	# with an empty controller list, so the button was dead to a hand rather than
	# merely unpainted. The DualShock's ANALOG switch ships exactly that way.
	if _mesh != null:
		_mesh_local_origin = _mesh.position
		_mesh_depress_parent = _mesh.get_parent() as Node3D
		_outline.set_source(_mesh)
	# Controllers aren't added until the first frame, so wait one frame
	await get_tree().process_frame
	# Find all XRController3D nodes in the scene by type
	var all := get_tree().root.find_children("*", "XRController3D", true, false)
	for node in all:
		_controllers.append(node as XRController3D)


func _process(delta: float) -> void:
	# A hand nowhere near the cap is asked nothing: a press in flight keeps
	# polling wherever the hand roams, an idle button only wakes for a tip
	# within reach.
	if not _controllers.is_empty():
		if _touch_ctrl != null or _trigger_pressed \
				or PokeTip.any_tip_within(_controllers, global_position, PokeTip.WIDGET_NEAR):
			if require_trigger:
				_process_trigger_mode()
			else:
				_process_touch_mode(delta)
			_claim_contact()
		else:
			_armed = false
	_sync_outline()


## TOUCH mode — crossing trigger_radius fires immediately, and then HOLDS.
##
## This used to test every controller against one radius with no hysteresis at
## all: the same distance engaged and released, so a millimetre of tremor at the
## boundary dropped the press. Bind the hand that made contact and give it an
## asymmetric release (the factor VRSlider already uses) plus a short grace.
##
## The two kinds of loss are deliberately NOT treated alike. A DEFINITE loss —
## the controller went invalid, inactive, or grabbed something — releases at once,
## because gracing it would leave a stuck press on a hand that has walked off with
## a console. Only a DISTANCE loss is graced.
func _process_touch_mode(delta: float) -> void:
	if _touch_ctrl != null:
		if not _qualified(_touch_ctrl):
			_release_touch()
		elif global_position.distance_to(PokeTip.tip_of(_touch_ctrl)) 				<= trigger_radius * RELEASE_SCALE:
			_touch_lost = 0.0
			return
		else:
			_touch_lost += delta
			if _touch_lost < CONTACT_GRACE:
				return
			# Either hand keeps this button pressed, so hand over to the other one
			# rather than releasing if it is already on the cap.
			var relay := _nearest_touching()
			if relay != null:
				_touch_ctrl = relay
				_touch_lost = 0.0
				return
			_release_touch()

	var ctrl := _nearest_touching()
	if ctrl != null:
		_touch_ctrl = ctrl
		_touch_lost = 0.0
		_touch_pressed = true
		_update_visual_state()
		Haptics.click(ctrl, true, HAPTIC_KEY)
		_activate()


## Nearest qualifying hand inside trigger_radius, or null.
func _nearest_touching() -> XRController3D:
	var best: XRController3D = null
	var best_d := INF
	for controller in _controllers:
		# Skip a hand that's holding something — otherwise the poke tip of the
		# hand gripping a handheld fires this button by drifting near it.
		if not _qualified(controller):
			continue
		var dist: float = global_position.distance_to(PokeTip.tip_of(controller))
		if dist <= trigger_radius and dist < best_d:
			best_d = dist
			best = controller
	return best


func _qualified(ctrl: XRController3D) -> bool:
	if not (is_instance_valid(ctrl) and ctrl.get_is_active() and PokeTip.is_poking(ctrl)):
		return false
	return _gate_allows(PokeTip.tip_of(ctrl))


## Ask the owner whether a fingertip at this world position may work this button.
##
## A toggle bat is the case that needs it: which half of the lever the finger is on
## decides whether the press is legal, and that answer changes every time the button
## fires. Gating in `_qualified` rather than at `_activate` is what makes it hold
## as well as fire — a held press whose gate has just flipped is released on the
## next frame, so a finger left resting on the bat cannot toggle it back.
##
## The pointer paths are deliberately not gated: a laser has no side.
func _gate_allows(tip: Vector3) -> bool:
	if not press_gate.is_valid():
		return true
	return bool(press_gate.call(tip))


func _release_touch() -> void:
	var was := _touch_ctrl
	_touch_ctrl = null
	_touch_lost = 0.0
	if _touch_pressed:
		_touch_pressed = false
		Haptics.click(was, false, HAPTIC_KEY)
		_update_visual_state()


## Hand the fingertip contact disc to this button's cap so it lands ON the face
## you press rather than floating over it or sinking through. Purely visual — the gate is
## contact_margin, not trigger_radius, and it fires nothing.
##
## Gated on the tip being inside the contact box, which matters in TRIGGER mode:
## that latch deliberately survives the hand roaming away, and without the gate
## the disc would slide after it.
func _claim_contact() -> void:
	if not is_instance_valid(_mesh) or _mesh.mesh == null:
		return
	# depress_axis lives in the MESH PARENT's frame (it can carry inverse parent
	# scale), so it has to go through that basis, not the mesh's own.
	var out: Vector3 = -depress_axis.normalized()
	if _mesh_depress_parent != null:
		out = -(_mesh_depress_parent.global_transform.basis * depress_axis).normalized()
	var box: AABB = _mesh.mesh.get_aabb().grow(contact_margin)
	var inv: Transform3D = _mesh.global_transform.affine_inverse()
	for ctrl in _controllers:
		if not _qualified(ctrl):
			continue
		var tip: Vector3 = PokeTip.tip_of(ctrl)
		if not box.has_point(inv * tip):
			continue
		var held: bool = (_touch_pressed and ctrl == _touch_ctrl) 			or (_trigger_pressed and ctrl == _engaged_ctrl)
		PokeTip.claim_box_face(ctrl, _mesh, tip, out,
			PokeTip.CONTACT_ENGAGED if held else PokeTip.CONTACT_HOVER)


## TRIGGER mode — arm on proximity, fire on the trigger's rising edge.
func _process_trigger_mode() -> void:
	# Re-arm bookkeeping. A controller may only fire this button once per trigger
	# pull: without it, sweeping a HELD trigger across a row of buttons (a DVD
	# player's transport strip) fires every one of them in turn.
	for ctrl in _controllers:
		if ctrl != null and ctrl.get_float(TRIGGER_ACTION) < TRIGGER_OFF:
			_rearmed[ctrl.get_instance_id()] = true

	if _trigger_pressed:
		# Held. The hand is free to roam off the button — only releasing the
		# trigger lets go.
		if not is_instance_valid(_engaged_ctrl) or not _engaged_ctrl.get_is_active() \
				or _engaged_ctrl.get_float(TRIGGER_ACTION) < TRIGGER_OFF:
			Haptics.click(_engaged_ctrl, false, HAPTIC_KEY)
			_engaged_ctrl = null
			_trigger_pressed = false
			_update_visual_state()
		_armed = _hovering_ctrl() != null
		return

	var ctrl := _hovering_ctrl()
	_armed = ctrl != null
	if ctrl == null or ctrl.get_float(TRIGGER_ACTION) <= TRIGGER_ON:
		return
	if not _rearmed.get(ctrl.get_instance_id(), false):
		return
	_rearmed[ctrl.get_instance_id()] = false
	_engaged_ctrl = ctrl
	_trigger_pressed = true
	_update_visual_state()
	Haptics.click(ctrl, true, HAPTIC_KEY)
	_activate()


## First active, non-holding controller whose poke tip is inside the box.
func _hovering_ctrl() -> XRController3D:
	if not is_instance_valid(_mesh) or _mesh.mesh == null:
		return null
	for ctrl in _controllers:
		# Skip a hand that's holding something, same as TOUCH mode.
		if ctrl == null or not ctrl.get_is_active() or not PokeTip.is_poking(ctrl):
			continue
		var tip: Vector3 = PokeTip.tip_of(ctrl)
		if _tip_in_box(tip) and _gate_allows(tip):
			return ctrl
	return null


## Interaction volume: the button mesh's own AABB grown by interact_margin on
## every side, tested in the mesh's local space. Beats a sphere centred on the
## Area3D origin for the wide, rectangular caps most console buttons have.
func _tip_in_box(tip: Vector3) -> bool:
	var box := _mesh.mesh.get_aabb().grow(interact_margin)
	return box.has_point(_mesh.global_transform.affine_inverse() * tip)


## Single funnel for every activation path, deduped to one emit per frame.
##
## XRToolsFunctionPointer.active_button_action is "trigger_click" — the same
## physical pull the near-field path watches. Without this, a hand inside the box
## while the laser is also on the button emits button_pressed TWICE in one frame.
## Same idiom as VRDropdown._accept_activation.
func _activate() -> void:
	var frame := Engine.get_process_frames()
	if frame == _last_activate_frame:
		return
	_last_activate_frame = frame
	button_pressed.emit()


## The outline is updated HERE and not left to the next _process. The pointer
## reports EXITED on the button it left and ENTERED on the one it reached inside a
## single call, so deferring both to _process makes the handover depend on the
## order the three nodes happen to sit in: with the pointer between them, the
## button being left has already drawn this frame and stays lit alongside the new
## one — two outlines, a room apart, for a frame. PickableHighlight has always
## repainted on the signal edge; this is the same rule.
func pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_pointer_hovered = true
			_update_visual_state()
		XRToolsPointerEvent.Type.EXITED:
			_pointer_hovered = false
			_pointer_pressed = false
			_update_visual_state()
		XRToolsPointerEvent.Type.PRESSED:
			_pointer_hovered = true
			_pointer_pressed = true
			_update_visual_state()
			# Null for the desktop reticle, which has no hand to rumble.
			Haptics.click(Haptics.controller_of(event.pointer), true, HAPTIC_KEY)
			_activate()
		XRToolsPointerEvent.Type.RELEASED:
			_pointer_pressed = false
			Haptics.click(Haptics.controller_of(event.pointer), false, HAPTIC_KEY)
			_update_visual_state()
	_sync_outline()


## Swap the mesh used for the depress animation and hide the original ButtonMesh child.
## Call this from a system model after the GLB has loaded to drive the real geometry.
## True until a real GLB button mesh is adopted. The power button's green/red
## START/STOP tint (RetroSystem._update_power_button_visual) is only meant for the
## generic placeholder cap — painting it onto a modelled button (the 3DS's real
## power key) turns that button pure green while the console is off. Cleared by
## set_button_mesh so state colouring skips real meshes.
var state_tint := true


func set_button_mesh(mesh: MeshInstance3D) -> void:
	var old := get_node_or_null("ButtonMesh") as MeshInstance3D
	if old:
		old.hide()
	state_tint = false
	_mesh = mesh
	_mesh_local_origin = mesh.position
	_mesh_depress_parent = mesh.get_parent() as Node3D
	# The outline traces the real geometry, and so does the TRIGGER-mode AABB.
	if _outline:
		_outline.set_source(_mesh)
	_update_visual_state()


## Derive the depress axis from a GLB "Finger Button" empty node.
## GLTF finger-button empties are oriented so their local -Z points in the direction
## of travel.  This converts that to the button mesh's local space.
func set_depress_axis_from_node(finger_node: Node3D) -> void:
	# Global -Z of the finger empty = travel direction in world space.
	# Convert to mesh parent's local space so that _mesh.position offsets work correctly.
	var world_dir := -finger_node.global_transform.basis.z.normalized()
	var parent := _mesh_depress_parent if _mesh_depress_parent else _mesh.get_parent() as Node3D
	if parent:
		depress_axis = parent.global_transform.basis.inverse() * world_dir
	else:
		depress_axis = world_dir


## Set the depress travel direction from a WORLD-space direction (converted to the
## button mesh's parent local space). Use when a GLB's finger-button empties don't
## encode the travel axis reliably — e.g. after the model itself has been rotated.
func set_depress_axis_world(world_dir: Vector3) -> void:
	var parent := _mesh_depress_parent if _mesh_depress_parent else _mesh.get_parent() as Node3D
	if parent:
		depress_axis = parent.global_transform.basis.inverse() * world_dir.normalized()
	else:
		depress_axis = world_dir.normalized()


## Keep drawing the hover outline even though the source mesh is hidden — for a
## control the shell PAINTS into its texture rather than modelling, so there is
## no geometry to adopt and the source is a hidden box the size of the print.
## Same escape hatch VRSlider uses for its hidden KnobMesh placeholder; see
## WidgetOutline.outline_hidden_source for why it is off by default.
func set_outline_hidden_source(hidden_ok: bool) -> void:
	if _outline:
		_outline.outline_hidden_source = hidden_ok


## Set the button's visual color by changing its material albedo
func set_color(color: Color) -> void:
	if not _mesh:
		return
	_apply_mesh_color(color)


## Put this button in or out of play. Hiding it is NOT enough: `visible` stops the
## drawing and nothing else, so a hidden cap keeps polling fingertips in _process
## — it fires, and PokeTip.claim_box_face places the visible disc on its contact
## box. A console whose model replaced these with its own controls (the Atari
## 2600's slide switches) grew a pair of invisible buttons on its front face,
## where the generic cabinet had put START and RESET.
##
## Being off the pointable layer matters as much: `monitoring` only governs what
## an Area3D DETECTS, never what a ray finds, so the laser went on clicking them.
func set_active(active: bool) -> void:
	visible = active
	set_interactive(active)


## Take the button in and out of play WITHOUT hiding it.
##
## set_active also drops `visible`, which is right for a cap a model has replaced
## with its own geometry — it should leave nothing behind. It is wrong for a
## control moulded into a device that is always on show: a Wii Remote's 1 and 2
## are part of the shell whether or not anyone can currently press them, and
## hiding them leaves a blank white slab.
func set_interactive(active: bool) -> void:
	set_process(active)
	set_deferred("monitoring", active)
	collision_layer = _active_layer if active else 0
	if not active:
		_release_touch()
		_armed = false
		_trigger_pressed = false
		_engaged_ctrl = null
		_pointer_pressed = false
		_pointer_hovered = false
		_sync_outline()


func set_latched_pressed(pressed: bool) -> void:
	_latched_pressed = pressed
	_update_visual_state()


## True while a hand or the pointer is actually holding this button down.
##
## button_pressed is an edge — it fires once per press, which is right for a
## console's START or a transport key. A button wired to a GAME needs the LEVEL:
## holding 1 on a Wii Remote has to keep reading as held for as long as the
## finger is on it. Deliberately excludes _latched_pressed, which is the caller
## telling this button it is already down by some other route; counting it would
## feed that straight back out again.
func is_held() -> bool:
	return _touch_pressed or _pointer_pressed or _trigger_pressed


## The HAND holding this button down, or null.
##
## is_held answers whether; this answers which, which a caller needs the moment a
## press drives something continuous rather than an edge — a rumble that runs for
## as long as the finger stays on the cap has to know whose finger it is, and
## touch mode can hand a held button from one hand to the other mid-press.
##
## Null for a pointer press. The desktop reticle has no hand to rumble at all,
## and a laser is not touching anything.
func held_by() -> XRController3D:
	if _touch_pressed:
		return _touch_ctrl
	if _trigger_pressed:
		return _engaged_ctrl
	return null


func _update_visual_state() -> void:
	if not _mesh:
		return

	if _touch_pressed or _pointer_pressed or _latched_pressed or _trigger_pressed:
		# depress_axis may already encode inverse parent scale from
		# set_depress_axis_from_node(), so do not renormalize it here.
		_mesh.position = _mesh_local_origin + depress_axis * depress_depth
	else:
		_mesh.position = _mesh_local_origin

func _apply_mesh_color(color: Color) -> void:
	# Get or create a per-instance material override.
	# Scene sub-resources are shared across instances, so duplicate on first use.
	var mat := _mesh.get_surface_override_material(0)
	if not mat or not mat is StandardMaterial3D:
		mat = StandardMaterial3D.new()
		_mesh.set_surface_override_material(0, mat)
	elif not mat.resource_local_to_scene:
		mat = mat.duplicate() as StandardMaterial3D
		_mesh.set_surface_override_material(0, mat)
	(mat as StandardMaterial3D).albedo_color = color


## Green while armed (the trigger will act here), amber while the trigger is down.
## The pointer-hover outline is unchanged by require_trigger — the laser has always
## highlighted what it is over.
func _sync_outline() -> void:
	if _outline == null:
		return
	if _trigger_pressed != _outline_amber:
		_outline_amber = _trigger_pressed
		_outline.set_color(WidgetOutline.ACTIVE_COLOR if _outline_amber else WidgetOutline.HOVER_COLOR)
	_outline.sync(_armed or _trigger_pressed or _pointer_hovered)

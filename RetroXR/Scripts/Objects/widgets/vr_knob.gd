## VRKnob — a physical, trigger-latched rotary control: a cap the player grabs and
## twists about its own axle, reporting a normalised 0..1 value.
##
## The two halves of this already existed separately. VRHinge is grab-and-twist and
## owns the angle maths — the rest-frame measurement and the unwrap, both of which
## are load-bearing and are lifted here verbatim in spirit. VRSlider owns the 0..1
## `value_changed` contract that every volume control in the project speaks, so a
## knob emitting anything else would need a translator at each end. This is the two
## joined: a hinge's grip, a slider's signal.
##
## Interaction (VR + desktop), the same model as VRHinge and VRSlider:
##   • HOVER — a controller tip within engage_radius, or the desktop reticle over
##     the grab box, shows a floating OPEN-HAND icon ("grab here").
##   • HELD  — pull the TRIGGER (VR) / press the reticle (desktop) to LATCH; the
##     icon becomes a FIST and the cap turns with the hand. Once latched the hand
##     need NOT stay in the grab box. On desktop the mouse WHEEL then steps the
##     value, which is finer than dragging a ray around a 20 mm cap.
##
## TRIGGER ONLY, and there is deliberately no `grip_engages` here. Grip is how
## XRToolsFunctionPickup takes hold, and a speaker cabinet IS a pickable — so a
## grip-latched knob would mean one squeeze both turned the volume up and lifted the
## whole box off the desk. VRHinge offers the grip as an opt-in for hardware nobody
## ever picks up; nothing this knob goes on qualifies.
##
## The axle is the target's local **Z**, and that is forced rather than chosen.
## Node3D Euler order is YXZ, so the rotation composes as Ry * Rx * Rz: only the Z
## term is INNERMOST, i.e. only Z turns the node about its own axis. Driving
## rotation.y on a cap that had been laid over to face out of a panel would have
## spun it about the panel's up axis instead — the cap would have swung like a door
## rather than turned like a knob.
##
## So the target is a pivot whose local Z already points out of the panel, and the
## cap mesh is its CHILD, carrying whatever rotation a CylinderMesh needs (Y-aligned,
## so a 90° turn about X) to lie along that axle. The pivot itself stays at identity
## on a front-facing panel.
##
## Attach to an Area3D with a child CollisionShape3D covering the cap (the desktop
## reticle ray hits this; VR engages on tip proximity to the Area origin).
class_name VRKnob
extends Area3D

signal value_changed(value: float)

const POINTABLE_LAYER := 1 << 20
## Analog trigger action, read as a float — same contract as VRButton/VRSlider/VRHinge.
const TRIGGER_ACTION := "trigger"
const TRIGGER_ON := 0.6   # trigger float that latches the knob
const TRIGGER_OFF := 0.4  # trigger float that releases it (hysteresis)
const ICON_HOVER := 0xF256   # Nerd Font: open palm — "grab here"
const ICON_HELD := 0xF255    # Nerd Font: closed fist — "holding"
const SYMBOL_FONT_PATH := "res://fonts/SymbolsNerdFont-Regular.ttf"
## Child adopted as the pivot when `target` is unset — see the note there.
const PIVOT_NAME := "KnobPivot"

## The pivot this knob turns, about its own local Z. Give it the cap mesh as a child
## rather than pointing this at the mesh itself — see the axle note above.
##
## Leave it unset and a child named `PIVOT_NAME` is used. That is the normal case,
## because an exported node reference pointing DOWN at a child does not survive
## scene instantiation: it arrives null, silently, and the knob then reads correct
## values while the cap never moves. Every other exported target in this project
## points at "..", which already exists by the time it is resolved.
@export var target: Node3D
## The cap angle about its local Z at value 0 and at value 1, in degrees. The pair
## are named by their VALUE rather than as min/max because which way round they go is
## the whole point: a positive rotation about +Z is counter-clockwise seen from the
## front, so a knob authored low-to-high would turn the wrong way — you would wind a
## volume pot anti-clockwise to make it louder. The defaults are the 270° sweep of a
## real pot, running clockwise.
@export var deg_at_zero: float = 135.0
@export var deg_at_one: float = -135.0
## Controller tip distance (m) that engages the cap. Smaller than a hinge's: a knob
## is a 20 mm part and a generous sphere would swallow the whole front panel.
@export var engage_radius: float = 0.03
## Desktop: fraction of full travel the mouse wheel steps per notch while held.
@export var wheel_step: float = 0.05
## Icon glyph height, roughly, in metres.
@export var icon_size: float = 0.024
## Starting position, 0..1. Applied without emitting in _ready — assigning this at
## runtime moves nothing and tells nobody; use set_value / set_value_no_signal.
@export var value: float = 0.75

var _trigger_ctrl: XRController3D = null   # latched controller (trigger held)
# Drag bookkeeping: how far the cap sat from the angle the hand implied when it took
# hold, and the last raw hand angle (the unwrap reference).
var _grab_offset_deg: float = 0.0
var _grab_raw_prev: float = 0.0
# Controller instance ids whose trigger has dropped since they last latched.
var _rearmed: Dictionary = {}
var _pointer_held := false               # desktop pointer latched
var _pointer_hover := false              # desktop reticle over the grab box
var _controllers: Array[XRController3D] = []
var _icon: Label3D = null


func _ready() -> void:
	collision_layer |= POINTABLE_LAYER
	if target == null:
		target = get_node_or_null(PIVOT_NAME) as Node3D
	if target == null:
		push_warning("VRKnob %s has no pivot: the value will move but the cap will not"
			% get_path())
	_build_icon()
	set_value_no_signal(value)
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node as XRController3D)


## Turn the cap and tell everyone — for an owner driving the knob from something
## other than a hand on it.
func set_value(v: float) -> void:
	_apply_value(v, true)


## Turn the cap and stay quiet — restore and populate use this.
func set_value_no_signal(v: float) -> void:
	_apply_value(v, false)


func get_value() -> float:
	return value


func _process(_delta: float) -> void:
	# A hand nowhere near the cap is asked nothing; a latched hand keeps driving
	# the knob wherever it roams.
	if _trigger_ctrl == null \
			and not PokeTip.any_tip_within(_controllers, global_position, PokeTip.WIDGET_NEAR):
		_update_icon()
		return
	# A trigger already down cannot grab control after control as the hand sweeps
	# across a panel — it has to fall below TRIGGER_OFF first. Same re-arm guard
	# VRSlider and VRHinge use.
	for ctrl in _controllers:
		if ctrl == null:
			continue
		if ctrl.get_float(TRIGGER_ACTION) < TRIGGER_OFF:
			_rearmed[ctrl.get_instance_id()] = true
	# VR: a latched controller drives the knob until it lets the trigger go, however
	# far the hand roams from the cap.
	if _trigger_ctrl != null:
		if not is_instance_valid(_trigger_ctrl) or not _trigger_ctrl.get_is_active() \
				or _trigger_ctrl.get_float(TRIGGER_ACTION) < TRIGGER_OFF:
			_trigger_ctrl = null
		else:
			_track_world_point(PokeTip.tip_of(_trigger_ctrl))
	elif not _pointer_held:
		# Latch a hovering hand that pulls the trigger. A hand already holding
		# something is skipped, so firing a held object's action never turns a knob
		# as a side effect.
		for ctrl in _controllers:
			if ctrl == null or not ctrl.get_is_active() or not PokeTip.is_poking(ctrl):
				continue
			var id := ctrl.get_instance_id()
			var tip: Vector3 = PokeTip.tip_of(ctrl)
			if _rearmed.get(id, false) \
					and global_position.distance_to(tip) <= engage_radius \
					and ctrl.get_float(TRIGGER_ACTION) > TRIGGER_ON:
				_rearmed[id] = false
				_trigger_ctrl = ctrl
				_begin_track(tip)
				break
	_update_icon()


## Desktop reticle / VR laser support (same contract as VRButton/VRSlider/VRHinge).
## Press latches; the latch holds through MOVED even if the ray leaves the cap, and
## only RELEASED lets go — EXITED just clears the hover highlight, never the drag.
func pointer_event(event: XRToolsPointerEvent) -> void:
	var vr := get_viewport().use_xr
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_pointer_hover = true
		XRToolsPointerEvent.Type.PRESSED:
			_pointer_held = true
			if vr:
				_begin_track(event.position)
		XRToolsPointerEvent.Type.MOVED:
			if _pointer_held and vr:
				_track_world_point(event.position)
		XRToolsPointerEvent.Type.RELEASED:
			_pointer_held = false
		XRToolsPointerEvent.Type.EXITED:
			_pointer_hover = false
			# NB: keep _pointer_held — a drag is allowed to leave the cap.
	_update_icon()


## Desktop: while the cap is held, the mouse wheel steps the value. Gated on
## _pointer_held so other wheel consumers only see the event when no knob is grabbed.
func _unhandled_input(event: InputEvent) -> void:
	if not _pointer_held or target == null:
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		set_value(value + wheel_step)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		set_value(value - wheel_step)
	else:
		return
	get_viewport().set_input_as_handled()


## Angle about the axle implied by a world point, or NAN where it is undefined.
##
## Measured in the CAP'S OWN rest frame rather than the parent's, for the reason
## VRHinge records: a cap authored with a yaw of its own would otherwise report an
## angle of the opposite sign to its rotation and track the hand backwards. Rest
## frame = the pivot's basis with the knob rotation taken out; Node3D Euler order is
## YXZ, so dropping the Z term leaves Ry * Rx.
##
## Rotation about +Z carries +X toward +Y, hence atan2(y, x).
##
## atan2 wraps at ±180°, so near a limit a tiny cross-axis jitter can flip the sign
## and snap the knob to the opposite end. `near_deg` unwraps onto the branch nearest
## a reference angle, keeping the twist continuous end to end.
func _angle_at(world_pos: Vector3, near_deg: float) -> float:
	if target == null:
		return NAN
	var parent := target.get_parent() as Node3D
	if parent == null:
		return NAN
	var rest := Basis.from_euler(Vector3(target.rotation.x, target.rotation.y, 0.0))
	var rel: Vector3 = rest.inverse() * (parent.to_local(world_pos) - target.position)
	if Vector2(rel.x, rel.y).length() < 0.001:
		return NAN   # hand on the axle — angle undefined
	var deg := rad_to_deg(atan2(rel.y, rel.x))
	while deg - near_deg > 180.0:
		deg -= 360.0
	while deg - near_deg < -180.0:
		deg += 360.0
	return deg


## Take hold WITHOUT moving the cap. The grab box sits on the knob, so the angle a
## hand implies at the moment it grabs is wherever it happens to be around the axle
## and has nothing to do with where the cap is. Driving the cap straight to it would
## jump the volume on contact — a trigger tap near the knob would slam it to one end.
## Remember the difference instead and carry it through the twist.
func _begin_track(world_pos: Vector3) -> void:
	if target == null:
		return
	var cur := rad_to_deg(target.rotation.z)
	var raw := _angle_at(world_pos, cur)
	_grab_offset_deg = 0.0 if is_nan(raw) else cur - raw
	_grab_raw_prev = cur if is_nan(raw) else raw


func _track_world_point(world_pos: Vector3) -> void:
	# Unwrap against the PREVIOUS raw angle, not the cap's: once an offset is in play
	# the two are no longer near each other, and unwrapping against the cap would fold
	# a large offset into a 360° jump.
	var raw := _angle_at(world_pos, _grab_raw_prev)
	if is_nan(raw):
		return
	_grab_raw_prev = raw
	_apply_deg(raw + _grab_offset_deg, true)


func _apply_value(v: float, emit: bool) -> void:
	_apply_deg(lerpf(deg_at_zero, deg_at_one, clampf(v, 0.0, 1.0)), emit)


func _apply_deg(deg: float, emit: bool) -> void:
	# Clamped against the ORDERED pair, since deg_at_zero is the larger of the two on
	# a clockwise knob and clampf with its arguments the wrong way round returns the
	# high bound for everything.
	deg = clampf(deg, minf(deg_at_zero, deg_at_one), maxf(deg_at_zero, deg_at_one))
	var span: float = deg_at_one - deg_at_zero
	value = 0.0 if is_zero_approx(span) else clampf((deg - deg_at_zero) / span, 0.0, 1.0)
	if target != null:
		target.rotation.z = deg_to_rad(deg)
	if emit:
		value_changed.emit(value)


# --- floating hint icon --------------------------------------------------------

## Build the open-hand / fist hint, the same recipe VRHinge uses — the Symbols Nerd
## Font chained as a fallback so the PUA glyphs resolve. WHERE it sits is the
## scene's business: an authored "KnobHint" child keeps the position it was given.
func _build_icon() -> void:
	var existing := get_node_or_null("KnobHint") as Label3D
	if existing != null:
		_icon = existing
	else:
		_icon = Label3D.new()
		_icon.name = "KnobHint"
		add_child(_icon)
	var fv := FontVariation.new()
	fv.base_font = ThemeDB.fallback_font
	var symbols: Font = load(SYMBOL_FONT_PATH)
	if symbols:
		fv.fallbacks = [symbols]
	_icon.font = fv
	_icon.font_size = 96
	_icon.pixel_size = icon_size / 96.0
	_icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_icon.no_depth_test = true
	_icon.render_priority = 2
	_icon.outline_size = 18
	_icon.outline_modulate = Color(0.0, 0.0, 0.0, 0.7)
	_icon.visible = false


func _update_icon() -> void:
	if _icon == null:
		return
	if _trigger_ctrl != null or _pointer_held:
		_icon.text = String.chr(ICON_HELD)
		_icon.modulate = Color(1.0, 0.82, 0.28)   # fist — amber "holding"
		_icon.visible = true
		return
	if _pointer_hover or _vr_hovering():
		_icon.text = String.chr(ICON_HOVER)
		_icon.modulate = Color(0.92, 0.96, 1.0)    # open hand — cool white
		_icon.visible = true
		return
	_icon.visible = false


## Position the hint, for rigs assembled in code rather than authored in a scene.
func place_hint(local_pos: Vector3) -> void:
	if _icon != null:
		_icon.position = local_pos


func _vr_hovering() -> bool:
	for ctrl in _controllers:
		if ctrl and ctrl.get_is_active() \
				and global_position.distance_to(PokeTip.tip_of(ctrl)) <= engage_radius:
			return true
	return false

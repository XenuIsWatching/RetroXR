## VRSlider — a physical slider/switch: a knob that travels along a local axis.
##
## Interaction mirrors VRButton: direct XRController3D tip proximity engages the
## knob (no physics bodies), plus desktop reticle pointer press-drag (works live
## thanks to the desktop pointer press/drag patch). With `steps >= 2` the knob
## snaps to detents and only emits on detent change — that IS a slide switch
## (steps = 2 → power switch). With `steps = 0` it's continuous (volume).
##
## Two interaction modes, same as VRButton:
##   • TOUCH (default) — the fingertip crossing engage_radius grabs the knob at
##     once, and a 1.8x radius hysteresis decides when it lets go.
##   • TRIGGER (require_trigger = true) — the fingertip entering the interaction
##     box only ARMS the knob, outlining it green; pulling the controller's
##     TRIGGER latches it (amber) and the knob tracks the hand until the trigger
##     is released. Because it latches rather than tracking proximity, the hand
##     is free to roam past the knob mid-drag — strictly better than the radius
##     hysteresis it replaces. Same model as VRHinge.
##
## Attach to an Area3D with a child MeshInstance3D named "KnobMesh", or hand it one
## from anywhere with set_knob_mesh().
class_name VRSlider
extends Area3D

signal value_changed(value: float)

const POINTABLE_LAYER := 1 << 20

## Analog trigger action, read as a float — see VRButton.
const TRIGGER_ACTION := "trigger"
const TRIGGER_ON := 0.6
const TRIGGER_OFF := 0.4

## Travel axis in this node's local space.
@export var axis_local: Vector3 = Vector3(1, 0, 0)
## Degrees the knob TURNS across the full travel, for a cap that rides a curved
## edge rather than a straight slot. A long cap on a shallow arc cannot stay on
## the surface by translating alone — its middle sinks in while its tips break
## out — so it has to turn as it goes. Zero (the default) is a plain straight
## slide, which is what a flat slot wants.
@export var knob_turn_deg: float = 0.0
## Axis the knob turns about, in THIS node's local space. The default suits an
## edge that curves in the horizontal plane, i.e. a switch on a device's side.
@export var knob_turn_axis: Vector3 = Vector3.UP

## Total knob travel in metres (value 0 → -travel/2, value 1 → +travel/2).
@export var travel: float = 0.03
## 0 = continuous; >= 2 = snap to this many detent positions.
@export var steps: int = 0
## Controller tip distance (m) that engages the knob. TOUCH mode only —
## TRIGGER mode uses interact_margin.
@export var engage_radius: float = 0.035
## Require a TRIGGER pull while the fingertip is inside the interaction box,
## instead of grabbing on proximity alone. Off by default so authored sliders
## keep their existing behaviour until switched over scene by scene.
@export var require_trigger: bool = false
## How far (metres) the interaction box extends past the knob mesh's own AABB,
## on every side. TRIGGER mode only.
@export var interact_margin: float = 0.02
## How far past the knob the visible fingertip starts snapping to its face
## (metres). Purely visual; it does not change when the knob engages.
@export var contact_margin: float = 0.015
## Current value 0..1.
@export var value: float = 0.0

## Release distance as a multiple of engage_radius, and how long the binding
## survives outside engage_radius. The knob stops tracking at engage_radius
## either way — these only decide how long it waits to be re-touched.
const RELEASE_SCALE := 1.8
const CONTACT_GRACE := 0.05
## How far the fingertip may back OFF the groove, measured from the DEEPEST it
## has pressed, and still be driving the knob.
##
## Lift-off has to be judged perpendicular to the travel axis, because that is
## the only direction that means "I have stopped touching it". Judging it on the
## distance from the slider ORIGIN cannot work: sliding along the groove inflates
## that same number, so engage_radius has to exceed half the throw just to let you
## slide, and a radius that generous then lets a withdrawing hand drag the knob
## most of its range on the way out. Measured on the 3DS depth slider (12.8 mm
## throw, 20 mm radius): pulling away moved it 0.500 -> 0.893 before freezing.
##
## Relative to the deepest press rather than to the grab, which is what makes
## PUSHING free and PULLING immediate: pressing further in always tracks and
## tightens the reference, so backing out is judged against how hard you were
## actually holding it, not against however tentatively you first touched it.
## 3 mm is above hand tremor and below a deliberate withdrawal.
const TRACK_SLACK := 0.003

var _engaged_ctrl: XRController3D = null
var _lost: float = 0.0
## value minus the value the tip projected to at the moment of contact. Keeps
## taking hold from jumping the knob to the fingertip. Fingertip path only.
var _grab_offset: float = 0.0
## Least perpendicular distance from the travel axis seen during this drag, i.e.
## how deep the fingertip has pressed. Only ever falls while engaged.
var _min_perp: float = 0.0
var _pointer_engaged := false
var _pointer_hovered := false
var _controllers: Array[XRController3D] = []
var _suppress_signal := false

# TRIGGER mode state
var _armed: bool = false
# Controller instance ids whose trigger has dropped below TRIGGER_OFF since they
# last latched this knob — stops one held trigger grabbing knob after knob.
var _rearmed: Dictionary = {}

# Travel direction in the KNOB'S PARENT space, and the pose everything is
# measured from: the knob's transform at _knob_anchor_value, which is the value
# the geometry is actually MODELLED at. Anchoring on that rather than on
# mid-travel means value == anchor reproduces the modelled pose exactly, by
# construction — which matters once the knob turns as well as slides.
var _knob_axis: Vector3 = Vector3.RIGHT
var _knob_turn_axis: Vector3 = Vector3.UP
var _knob_anchor: Transform3D = Transform3D()
var _knob_anchor_value: float = 0.5
# Cap centre in the knob's own MESH space — the point it turns about. An adopted
# GLB cap often has an identity node transform with its offset baked into the
# vertex data, so its centre is tens of mm from its origin and turning about the
# origin would fling it across the shell.
var _knob_centre: Vector3 = Vector3.ZERO
# Optional touch shape that rides the knob — see set_knob_collision.
var _knob_collision: CollisionShape3D = null
var _knob_collision_rest: Transform3D = Transform3D()
var _knob_collision_value: float = 0.0

var _outline: WidgetOutline = null
var _outline_amber: bool = false

## Optional. A slider whose cap is modelled elsewhere — the 3DS stand-in keeps its
## two on the lid beside the sliders, and every GLB shell has its own — is handed
## that mesh by set_knob_mesh() instead, so requiring a child here only produced
## "Node not found" on the ones doing it the intended way. Everything downstream
## already null-checks _knob; only this lookup was strict.
@onready var _knob: MeshInstance3D = get_node_or_null("KnobMesh") as MeshInstance3D


func _ready() -> void:
	collision_layer |= POINTABLE_LAYER
	_knob_axis = axis_local.normalized()
	_knob_turn_axis = knob_turn_axis.normalized()
	# The authored placeholder is driven from the Area origin at mid-travel, which
	# is what this class did before knobs could be adopted or turn.
	_anchor_knob(Transform3D(_knob.basis, Vector3.ZERO) if _knob != null else Transform3D(), 0.5)
	_adopt_knob_collision()
	_update_knob()
	_outline = WidgetOutline.attach(self)
	# The knob is a hidden placeholder on every baked handheld — outline it anyway
	# (see WidgetOutline.outline_hidden_source).
	_outline.outline_hidden_source = true
	_outline.set_source(_knob)
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node as XRController3D)


## Set the value AND report it, for an owner driving the slider from something
## other than a hand on the knob — the PSP's volume +/- buttons step it this way.
## The plain `value` export has no setter, so assigning it moves nothing and tells
## nobody; set_value_no_signal moves the knob but stays silent.
func set_value(v: float) -> void:
	_set_from_raw(v)


## Set the value without emitting (panel/populate use).
func set_value_no_signal(v: float) -> void:
	_suppress_signal = true
	_set_from_raw(v)
	_suppress_signal = false


## Drive the real GLB knob instead of the placeholder KnobMesh, hiding the
## placeholder. Mirrors VRButton.set_button_mesh — without it a handheld whose
## GLB has loaded would size its interaction box to a hidden primitive and show
## no highlight at all (see handheld_model.gd).
func set_knob_mesh(mesh: MeshInstance3D) -> void:
	if mesh == null:
		return
	var old := get_node_or_null("KnobMesh") as MeshInstance3D
	if old and old != mesh:
		old.hide()
	_knob = mesh
	# Convert the travel axis from THIS node's local space into the adopted
	# knob's parent space so _update_knob still slides it the right way.
	var world_axis := (global_transform.basis * axis_local.normalized()).normalized()
	var parent := mesh.get_parent() as Node3D
	if parent:
		_knob_axis = parent.global_transform.basis.inverse() * world_axis
	else:
		_knob_axis = world_axis
	if parent:
		_knob_turn_axis = (parent.global_transform.basis.inverse()
			* (global_transform.basis * knob_turn_axis.normalized())).normalized()
	# Anchor on where the GLB actually models the cap, at whatever value is current
	# — adopting must not visibly jerk it. GLBs model switches in the off position,
	# which is value 0, so this lines up.
	_anchor_knob(mesh.transform, value)
	if _outline:
		_outline.set_source(_knob)
	_update_knob()


func _process(delta: float) -> void:
	if _pointer_engaged:
		_sync_outline()
		return   # pointer drag owns the knob (handled in pointer_event)
	# A hand nowhere near the knob is asked nothing; an engaged hand keeps
	# tracking wherever it roams.
	if not _controllers.is_empty():
		if _engaged_ctrl != null \
				or PokeTip.any_tip_within(_controllers, global_position, PokeTip.WIDGET_NEAR):
			if require_trigger:
				_process_trigger_mode()
			else:
				_process_touch_mode(delta)
			_claim_contact()
		else:
			_armed = false
	_sync_outline()


## TOUCH mode — proximity engages, and the value FREEZES the moment
## contact is lost rather than following the hand out.
##
## The freeze band is the point of this. The value reads only the component of the
## tip along the travel axis, so pulling straight off a knob already changed
## nothing — but real withdrawals are not perpendicular, and tracking all the
## way out to the release radius let the last frames drag the value along with the
## departing hand. So grace holds the BINDING (riding out a dropped tracking
## frame) and never the TRACKING: past engage_radius the knob stops following.
## Dip back in and it resumes from where it stopped.
##
## A DEFINITE loss — invalid, inactive, or the hand grabbed something — drops
## at once; only a distance loss is graced.
func _process_touch_mode(delta: float) -> void:
	if _engaged_ctrl != null:
		if not _qualified(_engaged_ctrl):
			_engaged_ctrl = null
		else:
			var tip: Vector3 = PokeTip.tip_of(_engaged_ctrl)
			var d: float = global_position.distance_to(tip)
			# Track only while the fingertip is still pressing ON the groove.
			# Sliding along is free and pressing in is free; backing away from
			# the deepest press freezes the value where it stood.
			var perp: float = _perp_of(tip)
			if d <= engage_radius and perp <= _min_perp + TRACK_SLACK:
				_min_perp = minf(_min_perp, perp)
				_lost = 0.0
				_track_world_point(tip)
				return
			if d <= engage_radius:
				return   # off the groove but still in reach: bound, frozen
			_lost += delta
			if _lost < CONTACT_GRACE and d <= engage_radius * RELEASE_SCALE:
				return   # still bound, deliberately NOT tracking
			_engaged_ctrl = null
	for ctrl in _controllers:
		# Skip a hand that's holding something so it can't grab the knob by bumping it.
		if _qualified(ctrl) \
				and global_position.distance_to(PokeTip.tip_of(ctrl)) <= engage_radius:
			_engaged_ctrl = ctrl
			_lost = 0.0
			_begin_track(PokeTip.tip_of(ctrl))
			return


## How far a world point sits OFF the travel axis. Sliding along the groove does
## not change this; lifting away from it does, which is exactly the distinction
## the freeze band needs.
func _perp_of(world_pos: Vector3) -> float:
	var rel: Vector3 = world_pos - global_position
	var ax: Vector3 = (global_transform.basis * axis_local.normalized()).normalized()
	return (rel - ax * rel.dot(ax)).length()


func _qualified(ctrl: XRController3D) -> bool:
	return is_instance_valid(ctrl) and ctrl.get_is_active() and PokeTip.is_poking(ctrl)


## Take hold WITHOUT moving the knob: remember how far the value sits from the one
## the fingertip projects to, and carry that through the drag. Touching a knob
## off-centre used to snap it to your finger before you had moved at all. Same
## thing VRHinge._begin_track does for lids, for the same reason.
func _begin_track(world_pos: Vector3) -> void:
	_grab_offset = value - _raw_value_at(world_pos)
	_min_perp = _perp_of(world_pos)


## Hand the fingertip contact disc to the real knob so it lands ON the cap rather
## than floating over it. Visual only. Vector3.ZERO picks whichever face the tip is
## nearest — a knob is grabbable from any side, unlike a button's press face.
func _claim_contact() -> void:
	if not is_instance_valid(_knob) or _knob.mesh == null:
		return
	var box: AABB = _knob.mesh.get_aabb().grow(contact_margin)
	var inv: Transform3D = _knob.global_transform.affine_inverse()
	for ctrl in _controllers:
		if not _qualified(ctrl):
			continue
		var tip: Vector3 = PokeTip.tip_of(ctrl)
		if not box.has_point(inv * tip):
			continue
		PokeTip.claim_box_face(ctrl, _knob, tip, Vector3.ZERO,
			PokeTip.CONTACT_ENGAGED if ctrl == _engaged_ctrl else PokeTip.CONTACT_HOVER)


## TRIGGER mode — arm on proximity, latch on the trigger's rising edge, and hold
## the latch until the trigger is released regardless of where the hand goes.
func _process_trigger_mode() -> void:
	for ctrl in _controllers:
		if ctrl != null and ctrl.get_float(TRIGGER_ACTION) < TRIGGER_OFF:
			_rearmed[ctrl.get_instance_id()] = true

	if _engaged_ctrl != null:
		if not is_instance_valid(_engaged_ctrl) or not _engaged_ctrl.get_is_active() \
				or _engaged_ctrl.get_float(TRIGGER_ACTION) < TRIGGER_OFF:
			_engaged_ctrl = null
		else:
			_track_world_point(PokeTip.tip_of(_engaged_ctrl))
			_armed = true
			return

	var ctrl := _hovering_ctrl()
	_armed = ctrl != null
	if ctrl == null or ctrl.get_float(TRIGGER_ACTION) <= TRIGGER_ON:
		return
	if not _rearmed.get(ctrl.get_instance_id(), false):
		return
	_rearmed[ctrl.get_instance_id()] = false
	_engaged_ctrl = ctrl
	_track_world_point(PokeTip.tip_of(ctrl))


## First active, non-holding controller whose poke tip is inside the knob's box.
func _hovering_ctrl() -> XRController3D:
	for ctrl in _controllers:
		if ctrl == null or not ctrl.get_is_active() or not PokeTip.is_poking(ctrl):
			continue
		if _tip_in_box(PokeTip.tip_of(ctrl)):
			return ctrl
	return null


## Interaction volume: the knob mesh's own AABB grown by interact_margin on every
## side, tested in the knob's local space. It rides the knob as the value changes,
## which is what you want — you grab the cap, not the track.
func _tip_in_box(tip: Vector3) -> bool:
	if not is_instance_valid(_knob) or _knob.mesh == null:
		return false
	var box := _knob.mesh.get_aabb().grow(interact_margin)
	return box.has_point(_knob.global_transform.affine_inverse() * tip)


## Desktop reticle / VR laser support (same contract as VRButton), including
## repainting the outline on the event rather than on the next _process — see
## VRButton.pointer_event for why the handover cannot wait a frame.
func pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_pointer_hovered = true
		XRToolsPointerEvent.Type.PRESSED:
			_pointer_hovered = true
			_pointer_engaged = true
			_track_pointer_point(event.position)
		XRToolsPointerEvent.Type.MOVED:
			if _pointer_engaged:
				_track_pointer_point(event.position)
		XRToolsPointerEvent.Type.RELEASED:
			_pointer_engaged = false
		XRToolsPointerEvent.Type.EXITED:
			_pointer_engaged = false
			_pointer_hovered = false
	_sync_outline()


## Value the travel axis projects a world point to, unclamped and unsnapped.
func _raw_value_at(world_pos: Vector3) -> float:
	if travel <= 0.0:
		return value
	return to_local(world_pos).dot(axis_local.normalized()) / travel + 0.5


## Fingertip drag: RELATIVE to where contact was made (see _begin_track).
func _track_world_point(world_pos: Vector3) -> void:
	if travel <= 0.0:
		return
	_set_from_raw(_raw_value_at(world_pos) + _grab_offset)


## Pointer / desktop drag: absolute, unchanged. The reticle has no contact point
## to be relative to, and press-drag there has always jumped straight to the ray.
func _track_pointer_point(world_pos: Vector3) -> void:
	if travel <= 0.0:
		return
	_set_from_raw(_raw_value_at(world_pos))


func _set_from_raw(raw: float) -> void:
	var v := clampf(raw, 0.0, 1.0)
	if steps >= 2:
		v = roundf(v * (steps - 1)) / float(steps - 1)
	if is_equal_approx(v, value):
		return
	value = v
	_update_knob()
	if not _suppress_signal:
		value_changed.emit(value)


## Knob pose at mid-travel, plus the point it turns about: the cap's own CENTRE
## in the knob's parent frame. An adopted GLB cap frequently has an identity node
## transform with its offset baked into the vertex data, so `position` is nowhere
## near the cap and turning about it would fling the cap across the shell.
## Record the pose the knob is modelled in, and the value that pose represents.
func _anchor_knob(pose: Transform3D, at_value: float) -> void:
	_knob_anchor = pose
	_knob_anchor_value = at_value
	_knob_centre = Vector3.ZERO
	if _knob != null and _knob.mesh != null:
		_knob_centre = _knob.mesh.get_aabb().get_center()


## Re-record the touch shape's pose as belonging to the CURRENT value.
##
## _ready adopts the shape automatically, so this is only for a model that
## re-poses it afterwards — the 2600 turns its levers' boxes into the plane of
## the control panel long after the slider is in the tree, and without this the
## next value change would slide them from the pose they no longer have.
func set_knob_collision(shape: CollisionShape3D) -> void:
	_knob_collision = shape
	_knob_collision_rest = shape.transform if shape != null else Transform3D()
	_knob_collision_value = value


## The slider's own touch shape, so it can be carried along with the knob.
func _adopt_knob_collision() -> void:
	for child in get_children():
		var shape := child as CollisionShape3D
		if shape != null:
			set_knob_collision(shape)
			return


func _update_knob() -> void:
	# Before the knob's own early-out: a slider can carry a shape without ever
	# having been given a mesh to drive.
	#
	# The shape travels with the knob rather than covering the slot, so what the
	# player aims at is the switch itself wherever it currently sits. Every box in
	# the room is already longer than its slider's throw — 5.7 mm spare on the
	# 2600's levers, 24 mm on a Game Boy's power switch — so they stay generous
	# targets rather than turning into slot-length strips.
	#
	# Slide only. No slider in the project sets knob_turn_deg; a shape for one that
	# did would need turning about the knob's own centre as well.
	if is_instance_valid(_knob_collision):
		var cd: float = value - _knob_collision_value
		_knob_collision.transform = Transform3D(
			_knob_collision_rest.basis,
			_knob_collision_rest.origin + axis_local.normalized() * cd * travel)
	if _knob == null:
		return
	# Everything is measured from the anchor, so at value == anchor this is exactly
	# the modelled pose: zero slide, zero turn, no drift to correct for.
	var d: float = value - _knob_anchor_value
	var slide: Vector3 = _knob_axis * d * travel
	if is_zero_approx(knob_turn_deg):
		_knob.position = _knob_anchor.origin + slide
		return
	# Turn about the cap's own centre where it currently sits, then slide.
	var r := Basis(_knob_turn_axis.normalized(), deg_to_rad(knob_turn_deg) * d)
	var pivot: Vector3 = _knob_anchor * _knob_centre
	_knob.transform = Transform3D(Basis.IDENTITY, slide) \
		* Transform3D(r, pivot - r * pivot) * _knob_anchor


## Green while armed, amber while the trigger holds the knob.
##
## Only the ARMED/ENGAGED states are gated on require_trigger — they describe the
## trigger mode and mean nothing without it. Pointer hover is not: the laser and
## the desktop reticle highlight whatever they are over, which is what VRButton
## has always done. Gating the whole method left every slider in the room silent
## under the pointer while every button lit up.
func _sync_outline() -> void:
	if _outline == null:
		return
	if not require_trigger:
		_outline.sync(_pointer_hovered)
		return
	var engaged := _engaged_ctrl != null or _pointer_engaged
	if engaged != _outline_amber:
		_outline_amber = engaged
		_outline.set_color(WidgetOutline.ACTIVE_COLOR if engaged else WidgetOutline.HOVER_COLOR)
	_outline.sync(_armed or engaged or _pointer_hovered)

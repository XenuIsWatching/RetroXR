## PokeTip — the canonical near-interaction ("poke") position: touch screens, console
## buttons, keyboard keys, sliders, book corners all test against this tip
## instead of the controller's tracked origin. Capsense display modes query the
## runtime index-tip joint directly; Controllers mode keeps the established
## point 6 cm ahead of the controller.
##
## Add as a child named "PokeTip" of each XRController3D (player_rig.tscn).
## Consumers call the static PokeTip.tip_of(ctrl); when the node is missing
## (e.g. desktop hands) it falls back to a computed forward offset, so callers
## never need to care.
##
## CONTACT SNAPPING. A widget under the tip may CLAIM it for the frame
## (set_contact / claim_box_face). Two things show it: a small disc on the
## touched surface, always, and — in Controllers mode only — a cone nib on the
## front of the controller that bends onto the same point. The Capsense modes
## draw a real fingertip there instead, so the nib would sit inside the hand.
class_name PokeTip
extends Node3D

## How far ahead of the controller origin the tip sits (metres, along -Z aim).
const TIP_FORWARD := 0.06

# ── Contact claims ───────────────────────────────────────────────────────────

## Claim priorities. A widget merely under the tip claims HOVER; the one actually
## driving it claims ENGAGED, which wins — so poking a console's touch screen
## doesn't hand the contact disc to an overlapping power button.
const CONTACT_HOVER := 0
const CONTACT_ENGAGED := 10

## Follow rate for the disc, via the house clampf(K * delta, 0, 1) idiom. The
## contact is smoothed in WORLD space, so this only shapes how quickly the disc
## reaches a surface and lets go. It never leaks hand motion into a planted disc.
const CONTACT_LERP := 18.0
## Seconds a claim survives unrenewed. Sized to ride out a DROPPED TRACKING FRAME
## (~4 at 90 Hz) and nothing more: the widgets' own grace is a tail on how long a
## press lasts, so a generous value here would be felt as sticky buttons.
const CONTACT_GRACE := 0.05
## Lift off the claimed surface, applied once here so every widget gets the same
## clearance and nothing z-fights with the face it is sitting on.
const CONTACT_LIFT := 0.001
## Keeps the disc ON a face rather than balanced on its silhouette edge. Under the
## smallest cap that claims (the DS power key, 10 mm).
const FACE_INSET := 0.0015
## Contact shadow on the surface. Under the cone's own base radius so it reads as
## a fingertip's footprint, not a second object.
const DISC_RADIUS := 0.005

## The Controllers-mode nib. Its APEX sits exactly on this node's origin, so what
## you see is the point every widget tests against, and its base runs back toward
## the controller body.
const CONE_HEIGHT := 0.022
const CONE_RADIUS := 0.007
## Longest the nib may stretch onto a claimed surface. Past this it reads as
## snapped off the hand rather than reaching; larger than any engage radius.
const CONTACT_MAX_REACH := 0.045

var _pickup: Node = null   # sibling XRToolsFunctionPickup (hide contact while holding)
var _disc: MeshInstance3D = null
var _disc_mat: StandardMaterial3D = null
var _cone: MeshInstance3D = null
var _cone_local := Vector3.ZERO    # resolved apex, in THIS node's frame

# Winning claim for the current frame, plus the smoothed state it drives.
var _claim_point := Vector3.ZERO
var _claim_normal := Vector3.UP
var _claim_priority := -1
var _claim_dist := INF
var _claim_frame := -1
var _hold := 0.0
var _claim_smooth := Vector3.ZERO  # smoothed contact, in WORLD space
var _blend := 0.0                 # 0 free … 1 landed; drives the disc's alpha


# ── Per-frame cache ──────────────────────────────────────────────────────────

## tip_of and is_poking are asked by every widget in the room, several times
## per controller per frame, and each ask is a method lookup, a node lookup and
## a dynamic get. A tracked pose changes once per frame, so the answers are
## kept per process frame, keyed by controller. With eight machines' worth of
## buttons, lids and knobs those lookups were a measurable slice of the main
## thread on a Quest 3.
static var _cache_frame := -1
static var _tip_cache: Dictionary = {}
static var _poking_cache: Dictionary = {}

## How far a fingertip may be from a widget before the widget stops polling
## the controllers at all. Larger than any widget's reach, including a lid's
## grab box measured from its hinge.
const WIDGET_NEAR := 0.6


static func _cache_for_frame() -> void:
	var frame := Engine.get_process_frames()
	if frame != _cache_frame:
		_cache_frame = frame
		_tip_cache.clear()
		_poking_cache.clear()


## Whether any controller's tip is within `radius` of `pos` - the cheap first
## question a widget asks before polling triggers, grips and poke faces.
static func any_tip_within(controllers: Array, pos: Vector3, radius: float) -> bool:
	var r2 := radius * radius
	for ctrl in controllers:
		if ctrl == null or not is_instance_valid(ctrl):
			continue
		if tip_of(ctrl).distance_squared_to(pos) <= r2:
			return true
	return false


## The poke position for a controller. Hands/BOTH use the current runtime index
## joint whenever it is valid; Controllers mode and unavailable tracking use the
## controller-forward point. The joint is queried once per frame per controller.
static func tip_of(ctrl: Node3D) -> Vector3:
	_cache_for_frame()
	var id := ctrl.get_instance_id()
	if _tip_cache.has(id):
		return _tip_cache[id]
	var tip := _tip_of_now(ctrl)
	_tip_cache[id] = tip
	return tip


static func _tip_of_now(ctrl: Node3D) -> Vector3:
	if ctrl.has_method("capsense_index_tip"):
		var tracked: Variant = ctrl.call("capsense_index_tip")
		if tracked is Vector3:
			return tracked
	var tip := ctrl.get_node_or_null("PokeTip") as Node3D
	if tip:
		return tip.global_position
	return ctrl.global_position - ctrl.global_transform.basis.z * TIP_FORWARD


## True when this controller's poke tip is "live" — the hand is NOT currently
## holding an object (grabbed or ray-grabbed). VRButton/VRSlider skip controllers
## for which this is false, so a hand busy holding a handheld can't trigger a
## nearby widget by bumping it. Desktop hands (no FunctionPickup) always poke.
static func is_poking(ctrl: Node3D) -> bool:
	_cache_for_frame()
	var id := ctrl.get_instance_id()
	if _poking_cache.has(id):
		return _poking_cache[id]
	var poking := _is_poking_now(ctrl)
	_poking_cache[id] = poking
	return poking


static func _is_poking_now(ctrl: Node3D) -> bool:
	var pk := ctrl.get_node_or_null("FunctionPickup")
	if pk == null:
		return true
	if is_instance_valid(pk.get("picked_up_object")):
		return false
	if pk.has_method("is_ray_grabbing") and pk.is_ray_grabbing():
		return false
	return true


## Claim this frame's contact point for `ctrl`. Claims are frame-scoped and expire
## on their own, so a widget never has to release one — it simply stops claiming.
## A controller with no PokeTip node (desktop hands) is a silent no-op.
static func set_contact(ctrl: Node3D, world_point: Vector3, world_normal: Vector3,
		priority: int = CONTACT_HOVER) -> void:
	if ctrl == null or not is_poking(ctrl):
		return
	var tip := ctrl.get_node_or_null("PokeTip") as PokeTip
	if tip != null:
		tip._claim(world_point, world_normal, priority)


## Project `tip_pos` onto a face of `mi`'s mesh-local AABB and claim it.
##
## `prefer_world_normal` picks the face — a button passes its cap's outward
## normal, so the disc always lands on the face you press. Vector3.ZERO means
## "whichever face the tip is nearest", which is what a knob grabbable from any
## side wants; that test uses NORMALISED penetration so a long thin knob picks its
## long face rather than the nearer but larger-halved one.
static func claim_box_face(ctrl: Node3D, mi: MeshInstance3D, tip_pos: Vector3,
		prefer_world_normal: Vector3, priority: int) -> void:
	if ctrl == null or mi == null or mi.mesh == null:
		return
	var xf: Transform3D = mi.global_transform
	var inv: Transform3D = xf.affine_inverse()
	var box: AABB = mi.mesh.get_aabb()
	var c: Vector3 = box.get_center()
	var half: Vector3 = box.size * 0.5
	var p: Vector3 = inv * tip_pos
	var ax := 0
	var sgn := 1.0
	if prefer_world_normal.length_squared() > 1e-12:
		var n: Vector3 = (inv.basis * prefer_world_normal).normalized()
		ax = _dominant(Vector3(absf(n.x), absf(n.y), absf(n.z)))
		sgn = signf(n[ax])
	else:
		var d: Vector3 = p - c
		ax = _dominant(Vector3(absf(d.x) / maxf(half.x, 1e-6),
			absf(d.y) / maxf(half.y, 1e-6), absf(d.z) / maxf(half.z, 1e-6)))
		sgn = signf(d[ax])
	if is_zero_approx(sgn):
		sgn = 1.0
	p[ax] = c[ax] + sgn * half[ax]
	for i in 3:
		if i == ax:
			continue
		# maxf guards a cap thinner than the inset, which would invert the clamp.
		var lim: float = maxf(half[i] - FACE_INSET, 0.0)
		p[i] = clampf(p[i], c[i] - lim, c[i] + lim)
	var face := Vector3.ZERO
	face[ax] = sgn
	set_contact(ctrl, xf * p, (xf.basis * face).normalized(), priority)


## Index of the largest component.
static func _dominant(v: Vector3) -> int:
	if v.x >= v.y and v.x >= v.z:
		return 0
	return 1 if v.y >= v.z else 2


func _ready() -> void:
	position = Vector3(0, 0, -TIP_FORWARD)
	_pickup = get_parent().get_node_or_null("FunctionPickup")
	# Consume same-frame claims: run after the widgets that make them. The
	# one-frame tolerance in _process covers any ordering this misses.
	process_priority = 100

	# Visible cone: apex exactly at this node's origin, base back toward the
	# controller body — reads as a stylus nib. Shown only in Controllers mode;
	# _process owns that, so it starts hidden and never flashes on first frame.
	_cone = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = CONE_RADIUS
	cone.height = CONE_HEIGHT
	_cone.mesh = cone
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.8, 0.9)
	mat.emission_enabled = true
	mat.emission = Color(0.25, 0.3, 0.4)
	mat.emission_energy_multiplier = 0.4
	_cone.set_surface_override_material(0, mat)
	_cone.visible = false
	add_child(_cone)
	_apply_cone()   # with no claim this IS the rest pose; see _apply_cone

	# Contact shadow. This sits at the smoothed, reported point — what you see is
	# what the core is told. top_level so it stays flat on the surface rather than
	# inheriting the hand's roll.
	_disc = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = DISC_RADIUS
	disc.bottom_radius = DISC_RADIUS
	disc.height = 0.0004
	disc.radial_segments = 16
	disc.rings = 1
	_disc.mesh = disc
	_disc_mat = StandardMaterial3D.new()
	_disc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_disc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_disc_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_disc_mat.albedo_color = Color(0.6, 0.9, 1.0, 0.0)
	_disc.set_surface_override_material(0, _disc_mat)
	_disc.top_level = true
	_disc.visible = false
	_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_disc)


## Record a claim, resolving against any other made this frame: higher priority
## wins, then nearest to the TRUE tip. The smoothed disc never feeds back into
## this distance, so widget ordering cannot change the winner.
func _claim(world_point: Vector3, world_normal: Vector3, priority: int) -> void:
	var frame := Engine.get_process_frames()
	if frame != _claim_frame:
		_claim_frame = frame
		_claim_priority = -1
		_claim_dist = INF
	if priority < _claim_priority:
		return
	var d := tip_of(get_parent()).distance_to(world_point)
	if priority == _claim_priority and d >= _claim_dist:
		return
	_claim_priority = priority
	_claim_dist = d
	_claim_normal = world_normal.normalized() if world_normal.length_squared() > 1e-12 \
		else Vector3.UP
	_claim_point = world_point + _claim_normal * CONTACT_LIFT


func _process(delta: float) -> void:
	# Hide contact feedback while this hand holds something. Same signal every
	# widget gates on, so visual feedback and activation stay in sync.
	if _pickup:
		visible = is_poking(get_parent())
	if not visible:
		# Drop any claim rather than letting a stale one reappear on un-hide.
		_claim_priority = -1
		_claim_frame = -1
		_claim_smooth = Vector3.ZERO
		_blend = 0.0
		_disc.visible = false
		_cone.visible = false
		return

	var live: bool = _claim_priority >= 0 and _claim_frame >= Engine.get_process_frames() - 1
	_hold = 0.0 if live else _hold + delta
	var on: bool = live or _hold < CONTACT_GRACE
	var k: float = clampf(CONTACT_LERP * delta, 0.0, 1.0)
	# Smooth the contact in WORLD space, then blend the disc from the live tip.
	#
	# Smoothing in THIS node's frame (the first cut) was wrong: the claim is
	# world-fixed, so the hand's own motion moved the local target every frame and
	# the lerp chased it. Tremor leaked straight back into the disc that was meant
	# to be planted — measured at 2.2 mm of apex wander against a 3.0 mm hand
	# wobble, i.e. about three quarters of the jitter passing through.
	if on:
		_claim_smooth = _claim_point if _blend < 0.001 else _claim_smooth.lerp(_claim_point, k)
	_blend = lerpf(_blend, 1.0 if on else 0.0, k)
	var apex: Vector3 = tip_of(get_parent()).lerp(_claim_smooth, _blend)
	_apply_disc(apex)

	# The nib is the Controllers-mode stand-in for a fingertip. In the Capsense
	# modes a real finger is drawn at this point, so showing both would put the
	# cone inside the hand.
	_cone.visible = AppPrefs.xr_display_mode == AppPrefs.XRDisplayMode.CONTROLLERS
	if _cone.visible:
		_cone_local = to_local(apex)
		_apply_cone()


## Smoothed surface point for visual fingertip IK. This is deliberately NOT the
## point tip_of() reports to widgets: interaction remains on the raw tracked
## joint, while the rendered finger may curl the last few millimetres onto the
## surface. Returning the un-lifted point puts skin on the face; the disc keeps
## its tiny CONTACT_LIFT to avoid z-fighting.
func visual_contact_target() -> Variant:
	var contact := visual_contact()
	return contact.get("point") if not contact.is_empty() else null


## Point and outward normal for consumers that must account for their own
## thickness. The contact disc wants the point alone; fingertip IK also needs the
## normal so the joint centre can remain one fingertip radius above the face.
func visual_contact() -> Dictionary:
	if not visible or _blend <= 0.02 or _claim_smooth == Vector3.ZERO:
		return {}
	return {
		"point": _claim_smooth - _claim_normal * CONTACT_LIFT,
		"normal": _claim_normal,
	}


## Stretch the cone from its fixed base to the smoothed apex, so the nib bends
## onto the claimed surface instead of floating at whatever depth the hand is.
## Only the length axis scales — the nib keeps its radius — and the base stays
## put, so the cone always reads as attached to the controller.
##
## This moves the CONE only. It must never move this node: tip_of() IS this
## node's origin and every widget projects against it, so moving it would make a
## widget project onto a face, the tip follow, the widget re-project, and the
## geometry chase itself.
func _apply_cone() -> void:
	if _cone == null:
		return
	var base := Vector3(0.0, 0.0, CONE_HEIGHT)
	var d: Vector3 = _cone_local - base
	var dist: float = d.length()
	if dist < 1e-6:
		d = Vector3(0.0, 0.0, -CONE_HEIGHT)
		dist = CONE_HEIGHT
	var reach: float = clampf(dist, CONE_HEIGHT * 0.4, CONTACT_MAX_REACH)
	var dir: Vector3 = d / dist
	var ref: Vector3 = Vector3.RIGHT if absf(dir.x) < 0.9 else Vector3.FORWARD
	var bx: Vector3 = ref.cross(dir).normalized()
	var bz: Vector3 = bx.cross(dir)
	_cone.transform = Transform3D(Basis(bx, dir * (reach / CONE_HEIGHT), bz),
		base + dir * (reach * 0.5))


func _apply_disc(apex: Vector3) -> void:
	if _disc == null:
		return
	_disc.visible = _blend > 0.02
	if not _disc.visible:
		return
	_disc_mat.albedo_color = Color(0.6, 0.9, 1.0, _blend * 0.55)
	var n: Vector3 = _claim_normal
	var ref: Vector3 = Vector3.RIGHT if absf(n.y) > 0.9 else Vector3.UP
	var dx: Vector3 = ref.cross(n).normalized()
	_disc.global_transform = Transform3D(Basis(dx, n, n.cross(dx)), apex)

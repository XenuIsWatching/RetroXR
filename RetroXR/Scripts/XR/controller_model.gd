class_name ControllerModel
extends XRController3D

## Global toggle for the wrap-around hand shown on held peripherals (mouse, retro
## controller, light gun…). When false the device hand is never drawn; the
## controller art fades out on a grab either way. Default off; flipped by the
## OPTIONS menu via SpawnMenuController. Static so the two rig controllers and
## the menu all share one value.
static var draw_hands: bool = false

## The art itself comes from the XR runtime — see [ControllerArt], which owns the
## tier choice and the geometry. This node owns what the room does to it: the
## fade on a grab, and the hand drawn over a held device.
var _art: ControllerArt
## The runtime hand paired with this controller. Kept untyped so the controller
## still parses on platforms where the vendor hand-mesh class is unavailable.
var _capsense_hand: Node = null

# --- Wrap-around hand indicator on held peripherals ---
## A pickable must be in this group to get a wrap-around hand while held. Each
## such device carries its own "HandLeft"/"HandRight" child (an XRToolsHand,
## positioned + posed by hand in the editor); this controller simply shows the
## one matching its tracker while the device is held.
const HAND_HELD_GROUP := "hand_held_device"

# This controller's godot-xr-tools pickup function (source of grab/drop events).
var _pickup: XRToolsFunctionPickup
# The device-mounted hand this controller is currently showing (null if none).
var _shown_hand: Node3D

func _ready():
	# React to this controller's grabs/drops to show/hide the held device's hand.
	_pickup = get_node_or_null("FunctionPickup") as XRToolsFunctionPickup
	if _pickup:
		_pickup.has_picked_up.connect(_on_held_grabbed)
		_pickup.has_dropped.connect(_on_held_dropped)

	_art = ControllerArt.new()
	_art.name = "ModelArt"
	add_child(_art)
	_art.setup(self)
	# Geometry can be replaced at any point — a model that arrives during a grab
	# would otherwise be drawn opaque inside whatever is being held.
	_art.art_changed.connect(_apply_fade)
	_art.art_changed.connect(_resolve_rig)
	_setup_input()

	# A runtime hands its models over when the session begins, and the hardware
	# behind a hand can change mid-session (controllers waking, a swap to hand
	# tracking). Both are signals; neither is worth a per-frame poll.
	profile_changed.connect(_on_profile_changed)
	var xri := XRServer.find_interface("OpenXR")
	if xri != null and xri.has_signal("session_begun"):
		xri.connect("session_begun", _art.refresh)
	_art.refresh.call_deferred()

func _process(delta):
	_drive_fade(delta)
	_check_hold_state()

func _on_profile_changed(_role: String) -> void:
	_art.refresh()


# ── Driving the model's own rig ──────────────────────────────────────────
#
# The runtime hands the controller over with an AnimationPlayer describing how
# each of its inputs moves it. Nothing here chooses an axis or a travel distance:
# for every input we find the stretch of that clip in which its bone moves, and
# sample it. A rig from another vendor, with different geometry and different
# bone axes, animates for the same reason.

## Which bone each action actuates. Face buttons are named for the letters
## printed on them, so they differ per hand.
const ACTION_BONES := {
	"trigger": "b_trigger_front",
	"grip": "b_trigger_grip",
	"primary": "b_thumbstick",
	"menu_button": "b_button_oculus",
}
const AX_BONES := {"left_hand": "b_button_x", "right_hand": "b_button_a"}
const BY_BONES := {"left_hand": "b_button_y", "right_hand": "b_button_b"}

var _skeleton: Skeleton3D
## Bone name -> { bone, rot_rest, rot_far, pos_rest, pos_far }: where the rig
## rests each bone and how far it takes it.
var _driven := {}
## The thumbstick's measured geometry: which way its shaft points and how far the
## rig leans it.
var _stick := {}


## Re-read the rig whenever the art changes. A model can be replaced mid-session,
## and a stale bone index would drive a freed skeleton.
func _resolve_rig() -> void:
	_invalidate_rig()
	_skeleton = _art.skeleton()
	var anim := _art.animation_player()
	if _skeleton == null or anim == null:
		return
	var clips := anim.get_animation_list()
	if clips.is_empty():
		return
	# The clip describes the motion; it must not play it. Left running it would
	# actuate every input in turn on its own, over the top of the real ones.
	anim.stop()
	var clip: Animation = anim.get_animation(clips[0])

	for track in clip.get_track_count():
		var kind := clip.track_get_type(track)
		if kind != Animation.TYPE_ROTATION_3D and kind != Animation.TYPE_POSITION_3D:
			continue
		var bone_name := String(clip.track_get_path(track).get_concatenated_subnames())
		var bone := _skeleton.find_bone(bone_name)
		if bone < 0:
			continue
		var d: Dictionary = _driven.get(bone_name, {"bone": bone})
		_read_extremes(clip, track, kind, d)
		_driven[bone_name] = d
	_read_stick(clip)


## A runtime render model owns this skeleton and may replace it between input
## events (most visibly when a sleeping second controller wakes for a two-hand
## grab). A freed Object is not null in GDScript, so null checks alone leave a
## short window where the old rig looks present but every method call on it
## throws "previously freed instance".
func _rig_is_valid() -> bool:
	if is_instance_valid(_skeleton):
		return true
	_invalidate_rig()
	return false


func _invalidate_rig() -> void:
	_skeleton = null
	_driven.clear()
	_stick.clear()


## The clip runs every input in turn across five seconds, and a button's stretch
## of it presses twice. So the timeline is no use as a dial — what is wanted from
## each track is only where the bone rests and how far it travels, and a press
## interpolates between the two.
func _read_extremes(clip: Animation, track: int, kind: int, d: Dictionary) -> void:
	var count := clip.track_get_key_count(track)
	if count == 0:
		return
	var rest: Variant = clip.track_get_key_value(track, 0)
	var far: Variant = rest
	var furthest := 0.0
	for k in count:
		var v: Variant = clip.track_get_key_value(track, k)
		var dist: float = _deviation(rest, v)
		if dist > furthest:
			furthest = dist
			far = v
	if kind == Animation.TYPE_ROTATION_3D:
		d["rot_rest"] = rest
		d["rot_far"] = far
	else:
		d["pos_rest"] = rest
		d["pos_far"] = far


func _deviation(rest: Variant, v: Variant) -> float:
	if rest is Quaternion:
		return (rest as Quaternion).angle_to(v as Quaternion)
	if rest is Vector3:
		return (rest as Vector3).distance_to(v as Vector3)
	return 0.0


## Put a bone `amount` of the way from where the rig rests it to as far as the
## rig ever takes it.
func _actuate(bone_name: String, amount: float) -> void:
	var d: Variant = _driven.get(bone_name)
	if d == null or not _rig_is_valid():
		return
	var t := clampf(amount, 0.0, 1.0)
	if d.has("rot_rest"):
		_skeleton.set_bone_pose_rotation(d["bone"], (d["rot_rest"] as Quaternion).slerp(d["rot_far"], t))
	if d.has("pos_rest"):
		_skeleton.set_bone_pose_position(d["bone"], (d["pos_rest"] as Vector3).lerp(d["pos_far"], t))


## A stick has two axes where the clip has one timeline, so the rig sweeps it
## round a circle. Rather than replay that sweep, measure it once: the axes a
## stick turns about all lie in one plane whose normal is the shaft, and the
## furthest key says how far it leans. Any push can then be built directly.
func _read_stick(clip: Animation) -> void:
	_stick.clear()
	var d: Variant = _driven.get(ACTION_BONES["primary"])
	if d == null or not d.has("rot_rest"):
		return
	var track := _track_of(clip, ACTION_BONES["primary"], Animation.TYPE_ROTATION_3D)
	if track < 0:
		return

	var rest: Quaternion = d["rot_rest"]
	var axes: Array[Vector3] = []
	for k in clip.track_get_key_count(track):
		var delta := rest.inverse() * (clip.track_get_key_value(track, k) as Quaternion)
		var axis := Vector3(delta.x, delta.y, delta.z)
		if axis.length() > 0.005:
			axes.append(axis.normalized())
	var shaft := _plane_normal(axes)
	if shaft == Vector3.ZERO:
		return

	_stick = {
		"bone": d["bone"],
		"rest": rest,
		"shaft": shaft,
		"lean": _swing_of(clip, track, rest, shaft),
	}


## How far the rig leans the stick, which is not how far it turns it. A key can
## carry a twist about the shaft as well - spin, which moves the tip nowhere -
## and counting that as lean throws the stick further than the rig ever does.
## Taken as the widest swing over the sweep, with the twist divided out.
func _swing_of(clip: Animation, track: int, rest: Quaternion, shaft: Vector3) -> float:
	var widest := 0.0
	for k in clip.track_get_key_count(track):
		var delta := rest.inverse() * (clip.track_get_key_value(track, k) as Quaternion)
		var along := Vector3(delta.x, delta.y, delta.z).dot(shaft)
		var twist := Quaternion(shaft.x * along, shaft.y * along, shaft.z * along, delta.w).normalized()
		var swing := delta * twist.inverse()
		widest = maxf(widest, 2.0 * acos(clampf(absf(swing.w), -1.0, 1.0)))
	return widest


func _track_of(clip: Animation, bone_name: String, kind: int) -> int:
	for t in clip.get_track_count():
		if clip.track_get_type(t) == kind 				and String(clip.track_get_path(t).get_concatenated_subnames()) == bone_name:
			return t
	return -1


## The normal shared by a set of rotation axes, i.e. the direction none of them
## turn about. Taken over every pair rather than one chosen pair, so a stray key
## - a touch of twist along the shaft, a barely-deflected frame - cannot decide
## the whole plane. Zero if they do not span one, which is a rig whose stick only
## ever leans one way. The sign does not matter: a lean is built from two crosses
## with the shaft, and flipping it cancels.
func _plane_normal(axes: Array[Vector3]) -> Vector3:
	var normal := Vector3.ZERO
	for i in axes.size():
		for j in range(i + 1, axes.size()):
			var pair := axes[i].cross(axes[j])
			if pair.length() < 0.1:
				continue
			pair = pair.normalized()
			normal += pair if normal == Vector3.ZERO or normal.dot(pair) >= 0.0 else -pair
	if normal.length() < 0.001:
		return Vector3.ZERO
	return normal.normalized()


## The frame the clip's stick rotations are written in, as the player sees it -
## measured now rather than when the model loaded. A model arrives while the
## controllers are still asleep, so at that point there is no pose to read and
## the art still hangs off a grip anchor sitting at identity; a mapping baked
## then sends the stick anywhere but where it was pushed.
func _stick_frame() -> Basis:
	if not _rig_is_valid():
		return Basis.IDENTITY
	var bone: int = _stick["bone"]
	var parent := _skeleton.get_bone_parent(bone)
	var below := _skeleton.get_bone_global_pose(parent) if parent >= 0 else Transform3D.IDENTITY
	var in_hand := (global_transform.affine_inverse() * _skeleton.global_transform
		* below).basis * Basis(_stick["rest"] as Quaternion)
	return in_hand.inverse()


## Lean the stick the way it is pushed, as far as it is pushed.
##
## A stick leans in the plane of its own face, which is not the plane the push
## arrives in: the face is tilted out of the controller by however the hardware
## sits in the hand. So "away from me" means the hand's forward direction laid
## down onto that face, and "right" is the face's own right, taken so it agrees
## with the hand's. Turning about `shaft x lean` then moves the tip along `lean`.
func _actuate_stick(value: Vector2) -> void:
	if not _rig_is_valid():
		return
	if _stick.is_empty():
		_actuate(ACTION_BONES["primary"], minf(1.0, value.length()))
		return
	var amount := minf(1.0, value.length())
	var rest: Quaternion = _stick["rest"]
	if amount < 0.001:
		_skeleton.set_bone_pose_rotation(_stick["bone"], rest)
		return

	var shaft: Vector3 = _stick["shaft"]
	var frame := _stick_frame()
	var forward := _on_face(frame * Vector3.FORWARD, shaft)
	if forward == Vector3.ZERO:
		# Looking straight down the shaft there is no "away"; the hand's own up
		# still crosses the face.
		forward = _on_face(frame * Vector3.UP, shaft)
		if forward == Vector3.ZERO:
			return
	var side := shaft.cross(forward).normalized()
	if side.dot(frame * Vector3.RIGHT) < 0.0:
		side = -side

	var lean := (side * value.x + forward * value.y).normalized()
	_skeleton.set_bone_pose_rotation(_stick["bone"],
		rest * Quaternion(shaft.cross(lean).normalized(), _stick["lean"] * amount))


## A direction laid down onto the stick's face, i.e. with the part pointing along
## the shaft taken out of it. Zero if there is nothing left to lay down.
func _on_face(dir: Vector3, shaft: Vector3) -> Vector3:
	var flat := dir - shaft * dir.dot(shaft)
	return flat.normalized() if flat.length() > 0.05 else Vector3.ZERO


func _setup_input() -> void:
	input_float_changed.connect(_on_float_changed)
	input_vector2_changed.connect(_on_vec2_changed)
	button_pressed.connect(_on_button_pressed)
	button_released.connect(_on_button_released)


func _on_float_changed(action: String, value: float) -> void:
	if ACTION_BONES.has(action):
		_actuate(ACTION_BONES[action], value)


func _on_vec2_changed(action: String, value: Vector2) -> void:
	if action == "primary":
		_actuate_stick(value)


func _on_button_pressed(button: String) -> void:
	_actuate(_button_bone(button), 1.0)


func _on_button_released(button: String) -> void:
	_actuate(_button_bone(button), 0.0)


func _button_bone(button: String) -> String:
	match button:
		"ax_button":   return AX_BONES.get(tracker, "")
		"by_button":   return BY_BONES.get(tracker, "")
		"menu_button": return ACTION_BONES["menu_button"]
	return ""


# ── Fading the controller art ────────────────────────────────────────────
#
# Grabbing something used to snap the controller out of existence, and only for
# devices that author a hand pose; everything else kept a controller drawn inside
# the object you were holding. It now fades, on every grab.

## Seconds for a full fade. Short enough to read as "the controller got out of
## the way" rather than as an animation.
const FADE_TIME := 0.08

var _fade := 1.0
var _fade_target := 1.0
## Visibility has three independent owners. A peripheral may suppress the model,
## the XR display mode may suppress it, and a near grab always suppresses it.
## Recombining them in one place is what stops a drop's `true` from resurrecting
## controller art while Hands mode remains selected.
var _content_visible := true
var _display_visible := true
var _grab_suppressed := false


## Show or hide the loaded controller model (called by VRInputMapper). Kept as a
## bool for its callers; it sets a fade target rather than toggling.
func set_model_visible(v: bool) -> void:
	_content_visible = v
	_refresh_fade_target()


func set_display_visible(v: bool) -> void:
	_display_visible = v
	_refresh_fade_target()


func register_capsense_hand(hand: Node) -> void:
	_capsense_hand = hand


## Variant is intentional: null means use the controller-forward fallback.
func capsense_index_tip() -> Variant:
	if not is_instance_valid(_capsense_hand) \
			or not _capsense_hand.has_method("index_tip_position"):
		return null
	return _capsense_hand.call("index_tip_position")


func refresh_xr_display_mode() -> void:
	if is_instance_valid(_capsense_hand) \
			and _capsense_hand.has_method("apply_display_mode"):
		_capsense_hand.call("apply_display_mode")
	else:
		# No hand node means the fallback is controller art in every mode.
		set_display_visible(true)


## The fade is independent of `draw_hands`: the art gets out of the way because
## it would otherwise be drawn inside whatever is in your hand, which is true
## whether or not a hand is drawn over the device.
func _fade_to(target: float) -> void:
	_fade_target = target


func _refresh_fade_target() -> void:
	_fade_to(1.0 if _content_visible and _display_visible and not _grab_suppressed else 0.0)


func _drive_fade(delta: float) -> void:
	if is_equal_approx(_fade, _fade_target):
		return
	_fade = move_toward(_fade, _fade_target, delta / FADE_TIME)
	_apply_fade()


## Push the current fade level onto the art. The materials belong to ControllerArt
## because they are duplicates of whatever the runtime supplied; a surface it
## could not give us a BaseMaterial3D for cannot take an alpha at all, so it is
## hidden for the whole of a partial fade rather than left standing opaque.
func _apply_fade() -> void:
	if _art == null:
		return
	# Skip drawing entirely once invisible, and go back to opaque rendering at
	# full alpha so the model keeps its normal depth behaviour when in use.
	_art.visible = _fade > 0.001
	for m in _art.fade_materials:
		m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED if _fade >= 0.999 \
			else BaseMaterial3D.TRANSPARENCY_ALPHA
		var c: Color = m.albedo_color
		m.albedo_color = Color(c.r, c.g, c.b, _fade)
	for g in _art.opaque_only:
		g.visible = _fade >= 0.999


## XRToolsFunctionPickup.drop_object() returns before emitting has_dropped when
## the held object was freed under it, which strands the art faded out with
## nothing in hand. Restore whenever this hand is hidden but holding nothing.
func _check_hold_state() -> void:
	if _pickup == null or not _grab_suppressed:
		return
	if is_instance_valid(_pickup.picked_up_object) or _pickup.is_ray_grabbing():
		return
	_on_held_dropped()


## This controller grabbed something — fade the controller art out, and when the
## object is a device peripheral show its own hand for this tracker (authored in
## the device scene).
func _on_held_grabbed(what: Node) -> void:
	# A ray-pointer (telekinesis) grab holds the object at a distance, not in the
	# hand — its has_picked_up still fires, but the controller has nothing to get
	# out of the way of and no hand belongs on the object.
	if _pickup and _pickup.is_ray_grabbing_target(what as XRToolsPickable):
		return
	# Fade on ANY grab, not just the device peripherals that author their own
	# hand pose. A cartridge or a TV left the controller art sitting inside
	# whatever you were holding.
	_grab_suppressed = true
	_refresh_fade_target()
	_show_device_hand(what)


## This controller released whatever it held — hide the hand, restore the art.
func _on_held_dropped() -> void:
	_hide_device_hand()
	_grab_suppressed = false
	_refresh_fade_target()


## Draw the device's own hand for this tracker, if it authors one and the option
## is on. Only the hand answers to `draw_hands` — the fade above does not.
func _show_device_hand(what: Node) -> void:
	if not draw_hands:
		return
	if what == null or not what.is_in_group(HAND_HELD_GROUP):
		return
	var hand_name := "HandLeft" if tracker == "left_hand" else "HandRight"
	var hand := what.get_node_or_null(NodePath(hand_name)) as Node3D
	if hand == null:
		return
	hand.visible = true
	_shown_hand = hand


func _hide_device_hand() -> void:
	if is_instance_valid(_shown_hand):
		_shown_hand.visible = false
	_shown_hand = null


## Re-evaluate the device hand after the OPTIONS switch flipped mid-hold, so
## turning hands off drops the hand off whatever is already held and turning
## them on puts one there without waiting for a re-grab.
func refresh_device_hand() -> void:
	_hide_device_hand()
	if _pickup == null or _pickup.is_ray_grabbing():
		return
	# Variant, not Node3D: the hand can still be pointing at an object that was
	# freed while held, and binding that to a typed local throws.
	var held: Variant = _pickup.picked_up_object
	if is_instance_valid(held):
		_show_device_hand(held)

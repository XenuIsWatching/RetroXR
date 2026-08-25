class_name ControllerArt
extends Node3D

## The controller's own artwork, supplied by the XR runtime rather than shipped
## with the app. Created at runtime by [ControllerModel] as a child named
## "ModelArt", so it stays a descendant of the XRController3D and
## XRToolsDesktopControllerHider keeps hiding it on desktop for free.
##
## Two sources, in preference order:
##   CORE      — XR_EXT_render_model through Godot's OpenXRRenderModelManager.
##               Vendor-neutral and animates its own buttons. SteamVR, PICO.
##   VENDOR_FB — XR_FB_render_model through godot-openxr-vendors'
##               OpenXRFbRenderModel. The only one Meta's runtime serves; hands
##               back a plain glTF, so nothing on it moves.
## Neither class can be named statically: the vendor node exists only where the
## plugin binary loads, and the core singleton only answers once a session is
## running. Everything here goes through ClassDB.

enum Source {
	NONE,
	CORE,
	VENDOR_FB,
}

## Geometry was replaced — whoever drives the fade must re-apply it.
signal art_changed

const CORE_EXTENSION := "OpenXRRenderModelExtension"
const CORE_MANAGER := "OpenXRRenderModelManager"
const FB_MODEL := "OpenXRFbRenderModel"
## The vendor node refuses to load without this, with a message that only reaches
## the log. Checked here so the refusal is reported as a tier decision instead.
const FB_SETTING := "xr/openxr/extensions/meta/render_model"

## The vendor node asks the runtime for its buffer once, when the session begins,
## and gives up silently on an empty answer — which is what a controller that is
## asleep, flat or not yet paired returns. Re-entering the tree asks again.
const FB_RETRY_SECONDS: Array[float] = [1.0, 2.0, 4.0, 8.0, 16.0]

## Frames to keep re-walking the tree after a change. The core manager builds its
## children over several frames, so one walk on the frame of the signal finds an
## empty node.
const SETTLE_FRAMES := 3

var source: Source = Source.NONE
## Materials the loaded art draws with, duplicated so writing alpha on them
## cannot bleed into anything else the runtime handed out.
var fade_materials: Array[BaseMaterial3D] = []
## Surfaces whose material is not a BaseMaterial3D and so cannot be faded; these
## are hidden outright instead.
var opaque_only: Array[GeometryInstance3D] = []

var _ctrl: XRController3D
var _grip_anchor: Node3D
var _fb: Node3D
var _retry := 0
var _settle := 0
## Instance ids of the duplicates above, so a repeat walk adopts them instead of
## duplicating a duplicate.
var _owned := {}
var _reported := ""


func _init() -> void:
	set_process(false)


## Called by ControllerModel right after this node is added.
func setup(ctrl: XRController3D) -> void:
	_ctrl = ctrl


## Idempotent tier resolution. Safe to call on any signal, any number of times:
## once a source is live it short-circuits.
func refresh() -> void:
	if source != Source.NONE:
		return
	if _ctrl == null or not _xr_running():
		return
	if _try_core():
		return
	_try_fb()


## Nothing can be asked of either API before the session exists, and on desktop
## the vendor class is present with no runtime behind it.
func _xr_running() -> bool:
	var xri := XRServer.find_interface("OpenXR")
	return xri != null and xri.is_initialized()


func has_art() -> bool:
	return source != Source.NONE


## The loaded model's skeleton, if it brought one. Meta's runtime rig carries the
## same articulated bones its downloadable art pack does, so the buttons and
## triggers can still be driven; the core tier animates itself and returns one
## nobody should touch.
func skeleton() -> Skeleton3D:
	if source != Source.VENDOR_FB:
		return null
	for node in _walk(self):
		var skel := node as Skeleton3D
		if skel != null:
			return skel
	return null


## The rig's own description of how each input moves it. Meta ships one with the
## model; it is the only thing that knows the axes and the travel.
func animation_player() -> AnimationPlayer:
	if source != Source.VENDOR_FB:
		return null
	for node in _walk(self):
		var anim := node as AnimationPlayer
		if anim != null:
			return anim
	return null


func _walk(node: Node, out: Array[Node] = []) -> Array[Node]:
	for child in node.get_children():
		out.append(child)
		_walk(child, out)
	return out


# ── Core tier: XR_EXT_render_model ───────────────────────────────────────

func _try_core() -> bool:
	if not Engine.has_singleton(CORE_EXTENSION) or not ClassDB.can_instantiate(CORE_MANAGER):
		return false
	# An engine singleton, not a static get_singleton() on the class — ClassDB
	# cannot reach it.
	var ext: Object = Engine.get_singleton(CORE_EXTENSION)
	if ext == null or not ext.call("is_active"):
		return false

	var mgr: Node = ClassDB.instantiate(CORE_MANAGER)
	if mgr == null:
		return false
	mgr.name = "RenderModels"
	mgr.set("tracker", _core_tracker_filter())
	# The manager places its children relative to XROrigin3D and cancels that out
	# against the pose named here. Naming the pose this node's controller follows
	# — not the "grip" the docs suggest — is what makes it land correctly as a
	# descendant of that controller, offsets and all.
	mgr.set("make_local_to_pose", String(_ctrl.pose))
	add_child(mgr)
	mgr.child_entered_tree.connect(_on_subtree_changed)
	mgr.child_exiting_tree.connect(_on_subtree_changed)

	source = Source.CORE
	_mark_dirty()
	_report("core (XR_EXT_render_model)")
	return true


func _core_tracker_filter() -> int:
	var name := "RENDER_MODEL_TRACKER_LEFT_HAND" if _is_left() else "RENDER_MODEL_TRACKER_RIGHT_HAND"
	return ClassDB.class_get_integer_constant(CORE_MANAGER, name)


# ── Vendor tier: XR_FB_render_model ──────────────────────────────────────

func _try_fb() -> bool:
	if not ClassDB.can_instantiate(FB_MODEL):
		_report("none (no render model API)")
		return false
	# The plugin binary ships on the desktop editor too, so the class existing
	# says nothing about the runtime behind it.
	if not bool(ProjectSettings.get_setting(FB_SETTING, false)):
		_report("none (%s is off)" % FB_SETTING)
		return false

	if _fb == null:
		_ensure_grip_anchor()
		_fb = ClassDB.instantiate(FB_MODEL)
		if _fb == null:
			return false
		_fb.name = "FbRenderModel"
		_fb.set("render_model_type", 0 if _is_left() else 1)
		_fb.connect("openxr_fb_render_model_loaded", _on_fb_loaded)
		_grip_anchor.add_child(_fb)

	if bool(_fb.call("has_render_model_node")):
		_adopt_fb()
		return true
	_schedule_fb_retry()
	return false


func _on_fb_loaded() -> void:
	if source == Source.NONE:
		_adopt_fb()
	else:
		# The vendor node may replace its Skeleton3D when a controller wakes or
		# changes profile. Re-walk the new model so ControllerModel drops the old
		# bone indices and resolves the replacement rig.
		_mark_dirty()


func _adopt_fb() -> void:
	source = Source.VENDOR_FB
	set_process(true)
	_update_grip_anchor()
	_mark_dirty()
	_report("vendor (XR_FB_render_model)")


func _schedule_fb_retry() -> void:
	if _retry >= FB_RETRY_SECONDS.size():
		_report("none (no model from XR_FB_render_model)")
		return
	var wait := FB_RETRY_SECONDS[_retry]
	_retry += 1
	get_tree().create_timer(wait).timeout.connect(_retry_fb)


func _retry_fb() -> void:
	if source != Source.NONE or _fb == null or not is_instance_valid(_fb):
		return
	if bool(_fb.call("has_render_model_node")):
		_adopt_fb()
		return
	# Loading is driven off the node entering the tree, so bounce it.
	var parent := _fb.get_parent()
	parent.remove_child(_fb)
	parent.add_child(_fb)
	if bool(_fb.call("has_render_model_node")):
		_adopt_fb()
	else:
		_schedule_fb_retry()


## The runtime's models are authored in the OpenXR grip space, while this
## controller follows the pose named by its `pose` property — which the project's
## action map binds to /input/aim/pose. This node carries the difference so the
## art sits in the hand and every interaction offset on the controller keeps its
## aim frame.
func _ensure_grip_anchor() -> void:
	if _grip_anchor != null:
		return
	_grip_anchor = Node3D.new()
	_grip_anchor.name = "GripAnchor"
	add_child(_grip_anchor)


func _update_grip_anchor() -> void:
	if _grip_anchor == null or _ctrl == null:
		return
	var tracker := XRServer.get_tracker(_ctrl.tracker) as XRPositionalTracker
	if tracker == null:
		return
	var base_pose: XRPose = tracker.get_pose(_ctrl.pose)
	var grip_pose: XRPose = tracker.get_pose(&"grip")
	if base_pose == null or grip_pose == null:
		return
	if not base_pose.has_tracking_data or not grip_pose.has_tracking_data:
		return
	# get_adjusted_transform, not get_transform: it carries the world scale that
	# XRNode3D already applied to the parent.
	_grip_anchor.transform = base_pose.get_adjusted_transform().affine_inverse() \
		* grip_pose.get_adjusted_transform()


# ── Materials ────────────────────────────────────────────────────────────

func _on_subtree_changed(_node: Node) -> void:
	_mark_dirty()


func _mark_dirty() -> void:
	_settle = SETTLE_FRAMES
	set_process(true)


func _process(_delta: float) -> void:
	if source == Source.VENDOR_FB:
		_update_grip_anchor()
	if _settle > 0:
		_settle -= 1
		_collect_fade_materials()
	elif source != Source.VENDOR_FB:
		set_process(false)


## Give every surface a material of our own, so the fade can write alpha on it.
## Deduplicated by source material: the runtime shares one material across a
## whole controller, and so should we.
func _collect_fade_materials() -> void:
	var seen := {}
	fade_materials.clear()
	opaque_only.clear()
	for mesh: MeshInstance3D in _mesh_instances(self):
		for i in mesh.get_surface_override_material_count():
			var active: Material = mesh.get_active_material(i)
			var base := active as BaseMaterial3D
			if base == null:
				if not opaque_only.has(mesh):
					opaque_only.append(mesh)
				continue
			if _owned.has(base.get_instance_id()):
				if not fade_materials.has(base):
					fade_materials.append(base)
				continue
			var key := base.get_instance_id()
			var dup: BaseMaterial3D = seen.get(key)
			if dup == null:
				dup = base.duplicate() as BaseMaterial3D
				seen[key] = dup
				_owned[dup.get_instance_id()] = true
			mesh.set_surface_override_material(i, dup)
			if not fade_materials.has(dup):
				fade_materials.append(dup)
	art_changed.emit()


func _mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	_gather_meshes(root, out)
	return out


func _gather_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	var mesh := node as MeshInstance3D
	if mesh != null:
		out.append(mesh)
	for child in node.get_children():
		_gather_meshes(child, out)


# ── Reporting ────────────────────────────────────────────────────────────

func _is_left() -> bool:
	return _ctrl.tracker == &"left_hand"


## One line per controller, unconditional: on a headset the log is the only way
## to know which tier is live.
func _report(what: String) -> void:
	if _reported == what:
		return
	_reported = what
	print("ControllerArt %s: %s" % [_ctrl.tracker, what])

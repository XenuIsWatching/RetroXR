## spatial_probe.gd — Phase 0 of plans/wish-list/spatial-data-quest3.md.
##
## Answers on real hardware: does the runtime back the vendor-neutral core path
## (XR_EXT_spatial_entity), and do real Room Setup planes arrive as trackers?
## Everything is discovered reflectively, so it reports even when a class or
## method is absent.
##
## Run it as the main scene on device (QuestSpatialProbe preset) and read the
## [spatial] lines from logcat. The Meta Fb path is exercised LAST: without the
## USE_SCENE runtime permission it can take the process down, which would
## otherwise swallow the core results.
extends Node3D


const CLASSES: PackedStringArray = [
	"OpenXRSpatialEntityExtension",
	"OpenXRSpatialPlaneTrackingCapability",
	"OpenXRSpatialAnchorCapability",
	"OpenXRFbSpatialEntityExtension",
	"OpenXRFbSceneCaptureExtension",
	"OpenXRMetaSpatialEntityMeshExtension",
	"OpenXRFbSceneManager",
	"OpenXRPlaneTracker",
	"OpenXRAnchorTracker",
]
const SCENE_PERMS: PackedStringArray = [
	"com.oculus.permission.USE_SCENE",
	"horizonos.permission.USE_SCENE",
]

var _frames: int = 0
var _elapsed: float = 0.0


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void: get_tree().quit(0))

	var xri: XRInterface = XRServer.find_interface("OpenXR")
	var initialized: bool = xri != null and xri.is_initialized()
	print("[spatial] OpenXR interface=%s initialized=%s" % [xri != null, initialized])
	if initialized:
		xri.set_play_area_mode(XRInterface.XR_PLAY_AREA_ROOMSCALE)
		get_viewport().use_xr = true
		print("[spatial] blend modes=%s" % str(xri.get_supported_environment_blend_modes()))

	_report_permissions()
	_report_classes()
	_report_core_capabilities()
	_report_trackers("t=0")

	# Discovery is asynchronous — planes show up some frames after the session
	# starts, so sample repeatedly rather than once.
	for t: int in [3, 8, 15, 25]:
		await get_tree().create_timer(float(t) - _elapsed).timeout
		_report_trackers("t=%ds" % t)

	# Meta path last, on purpose (see the class docs above).
	print("[spatial] ===== core probe complete; trying Meta Fb path =====")
	_report_fb()

	await get_tree().create_timer(3.0).timeout
	print("[spatial] ===== probe complete =====")
	get_tree().quit(0)


## Heartbeat: distinguishes "process died" from "process alive but not ticking".
func _process(delta: float) -> void:
	_frames += 1
	_elapsed += delta
	if _frames % 90 == 0:
		print("[spatial] alive t=%.1fs frames=%d" % [_elapsed, _frames])


func _report_permissions() -> void:
	var granted: PackedStringArray = OS.get_granted_permissions()
	for p in SCENE_PERMS:
		print("[spatial] permission %s granted=%s" % [p, p in granted])
	# Ask for it if the shell did not grant it at install time.
	for p in SCENE_PERMS:
		if not (p in granted):
			print("[spatial] requesting %s -> %s" % [p, OS.request_permission(p)])


func _report_classes() -> void:
	for c in CLASSES:
		if not ClassDB.class_exists(c):
			print("[spatial] class %s: ABSENT" % c)
			continue
		print("[spatial] class %s: present singleton=%s parent=%s" % [
			c, Engine.has_singleton(c), ClassDB.get_parent_class(c)])


## The core / cross-vendor answer.
func _report_core_capabilities() -> void:
	if not Engine.has_singleton("OpenXRSpatialEntityExtension"):
		print("[spatial] core: OpenXRSpatialEntityExtension singleton ABSENT")
		return
	var ext: Object = Engine.get_singleton("OpenXRSpatialEntityExtension")
	for e in ClassDB.class_get_enum_list("OpenXRSpatialEntityExtension", true):
		for k in ClassDB.class_get_enum_constants("OpenXRSpatialEntityExtension", e, true):
			if not k.contains("CAPABILITY"):
				continue
			var v: int = ClassDB.class_get_integer_constant("OpenXRSpatialEntityExtension", k)
			print("[spatial] core supports_capability(%s) = %s" % [
				k, str(ext.call("supports_capability", v))])
	for c in ["OpenXRSpatialPlaneTrackingCapability", "OpenXRSpatialAnchorCapability"]:
		if Engine.has_singleton(c):
			_call_support_queries(c, Engine.get_singleton(c))


## Reflectively call every zero-arg is_*/supports_* query on an object.
func _call_support_queries(label: String, obj: Object) -> void:
	if obj == null:
		return
	for m: Dictionary in ClassDB.class_get_method_list(obj.get_class(), true):
		var name: String = str(m["name"])
		if (m["args"] as Array).is_empty() \
				and (name.begins_with("is_") or name.begins_with("supports_")):
			print("[spatial] %s.%s() = %s" % [label, name, str(obj.call(name))])


## What built-in plane/anchor detection actually published, with geometry.
func _report_trackers(when: String) -> void:
	var trackers: Dictionary = XRServer.get_trackers(XRServer.TRACKER_ANY)
	var planes: int = 0
	var lines: PackedStringArray = []
	for key: Variant in trackers:
		var t: Variant = trackers[key]
		if not (t is Object):
			continue
		var o: Object = t as Object
		if o.has_method("get_plane_label"):
			planes += 1
			lines.append("%s label=%s alignment=%s bounds=%s" % [
				str(key), str(o.call("get_plane_label")),
				str(o.call("get_plane_alignment")), str(o.call("get_bounds_size"))])
		elif o.has_method("get_uuid"):
			lines.append("%s ANCHOR uuid=%s" % [str(key), str(o.call("get_uuid"))])
	print("[spatial] %s trackers=%d planes=%d" % [when, trackers.size(), planes])
	for l in lines:
		print("[spatial]   %s" % l)


func _report_fb() -> void:
	for c in ["OpenXRFbSpatialEntityExtension", "OpenXRFbSceneCaptureExtension"]:
		if Engine.has_singleton(c):
			_call_support_queries(c, Engine.get_singleton(c))
	if not ClassDB.class_exists("OpenXRFbSceneManager"):
		return
	var n: Object = ClassDB.instantiate("OpenXRFbSceneManager")
	if not (n is Node):
		return
	var mgr: Node = n as Node
	if mgr.has_signal("openxr_fb_scene_data_missing"):
		mgr.connect("openxr_fb_scene_data_missing",
			func() -> void: print("[spatial] fb SIGNAL scene_data_missing (no Room Setup)"))
	if mgr.has_signal("openxr_fb_scene_anchor_created"):
		mgr.connect("openxr_fb_scene_anchor_created",
			func(node: Variant, entity: Variant) -> void:
				print("[spatial] fb SIGNAL anchor_created %s %s" % [str(node), str(entity)]))
	add_child(mgr)
	print("[spatial] fb: OpenXRFbSceneManager added to tree (survived)")
	if mgr.has_method("get_anchor_uuids"):
		print("[spatial] fb room-setup anchors = %s" % str(mgr.call("get_anchor_uuids")))

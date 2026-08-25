extends Node3D

## Scene id this room registers as in SceneManager.SCENE_PATHS. Every room sets
## its own; an empty one claims nothing and leaves whatever SceneManager already
## reads standing, so a room that does not set it is only ever correct by luck.
@export var scene_id: String = ""


## Claim the scene id before any _ready() runs. SpawnMenuController auto-loads the
## last arcade save on startup whenever SceneManager still reads "arcade", and that
## load begins by freeing every node in the "spawned" group — cables included.
## Arriving through SceneManager.change_scene() sets the id already; running a
## scene directly (F6, or a headless probe) does not.
func _enter_tree() -> void:
	if scene_id.is_empty():
		return
	var sm := get_node_or_null("/root/SceneManager")
	if sm != null:
		sm.current_scene_id = scene_id


func _ready():
	DesktopBindings.load_and_apply()
	var xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		# Use roomscale tracking so Y=0 is the physical floor
		xr_interface.set_play_area_mode(XRInterface.XR_PLAY_AREA_ROOMSCALE)
		# The saved refresh rate, or the platform default where none is saved — the
		# system setting alone does not pick one. QualityManager owns the value.
		QualityManager.apply_display_rate()
		# The saved eye-buffer size, applied before the first XR frame so the
		# swapchain is allocated once at it. QualityManager owns the value and the
		# reasoning; it goes on the interface PROPERTY because there is no
		# `xr/openxr/render_target_size_multiplier` project setting (the whole xr/*
		# list was dumped to check).
		QualityManager.apply_eye_buffer_scale()
		# Both are live settings; applied here so a launch starts where the saved
		# ones say rather than at the runtime's own defaults.
		QualityManager.apply_perf_levels()
		QualityManager.apply_foveation()
		# Enable XR rendering — this also signals desktop support nodes to disable
		# themselves (xr_start_shim.gd returns get_viewport().use_xr).
		get_viewport().use_xr = true
		_log_eye_buffer_quality(xr_interface)
		print("=====================================")
		print("  RetroXR: running in XR / VR mode")
		print("=====================================")
	else:
		print("=====================================")
		print("  RetroXR: running in DESKTOP mode")
		print("  WASD = move   Mouse = look")
		print("  Left-click = grab/shoot")
		print("  Shift+Left-click = drop (held gun)")
		print("  Tab = spawn menu")
		print("=====================================")
		# Ensure the window starts with a sensible resolution for desktop play
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


## Report what the session actually came up with, so a bad eye-buffer size is
## visible in logcat instead of only in the headset. `foveation` should read 0 —
## anything else means foveation crept back in and the view will be a flat colour
## (21351c5); on a Quest 3 at the default eye-buffer scale, expect
## "eye buffer (2064.72, 2163.04) per eye, window (4128, 2208), foveation 0".
##
## Sampled once, at startup. The GRAPHICS tab's Eye Buffer row moves it later, and
## xr/openxr/extensions/meta/dynamic_resolution (a vendors-plugin default) lets the
## runtime LOWER it under GPU load; the perf HUD's eye row reads the live size
## every slow tick, which this cannot.
func _log_eye_buffer_quality(xri: XRInterface) -> void:
	print("XRInit: eye buffer %s per eye, window %s, foveation %s" % [
		xri.get_render_target_size(), get_viewport().size, xri.get("foveation_level")])

## LoadingPanel — the loading screen itself, with nothing around it.
##
## Split out of LoadingRig so the same panel can cover a room that is ALREADY in
## the tree. The rig owns a WorldEnvironment and a fallback camera and therefore
## has to leave before the incoming scene enters; this has neither, so it can hang
## in front of a live room while that room's objects are still being built. That
## gap — the room visible, its contents still arriving — is the whole reason this
## exists.
##
## Two things move independently and the split is deliberate. `Screen` is
## yaw-smoothed so a deliberate turn brings the panel round without copying every
## twitch. `Curtain` is parented straight to the camera and so is FULLY
## head-locked: a yaw-smoothed curtain lags a head turn and shows a sliver of the
## room it is supposed to be hiding.
class_name LoadingPanel
extends Node3D


## Fast enough to follow a deliberate turn, slow enough to ignore small movements.
const FOLLOW_RATE := 6.0

## Resolved by _ensure() rather than @onready, because a caller can reach this
## panel before its _ready has run. A node added to a parent that is not itself
## ready yet has its own _ready DEFERRED, and the boot curtain goes up from
## SceneManager._ready while the LoadingOverlay autoload is still being set up —
## so every @onready here was still null on the first set_progress.
var _screen: Node3D = null
var _curtain: MeshInstance3D = null
var _title_label: Label3D = null
var _status_label: Label3D = null
var _percent_label: Label3D = null
var _detail_label: Label3D = null
var _progress_material: ShaderMaterial = null
var _resolved := false

var _player_camera: XRCamera3D = null
var _player_origin: Node3D = null
var _progress: float = 0.0
var _animation_time: float = 0.0
var _status_text: String = "PREPARING ROOM"
## Set by set_status(). While it is non-empty the band derived from progress is
## suppressed — a caller that knows it is on object 14 of 31 has more to say than
## "LOADING ROOM DATA".
var _status_override: String = ""
var _last_percent: int = -1
var _last_status_rendered: String = ""
var _load_failed: bool = false
var _following: bool = false


func _ensure() -> void:
	if _resolved:
		return
	_screen = get_node_or_null("Screen") as Node3D
	if _screen == null:
		return
	_curtain = get_node_or_null("Curtain") as MeshInstance3D
	_title_label = _screen.get_node_or_null("TitleLabel") as Label3D
	_status_label = _screen.get_node_or_null("StatusLabel") as Label3D
	_percent_label = _screen.get_node_or_null("PercentLabel") as Label3D
	_detail_label = _screen.get_node_or_null("DetailLabel") as Label3D
	var bar := _screen.get_node_or_null("ProgressBar") as MeshInstance3D
	if bar != null:
		_progress_material = bar.get_surface_override_material(0) as ShaderMaterial
	_resolved = true


func _ready() -> void:
	_ensure()
	if _following:
		_follow_player(0.0, true)
	_apply_progress()


func _process(delta: float) -> void:
	_animation_time += delta
	if _following:
		_follow_player(delta)
	_update_status_label()


## Track the player's head without touching the scene tree. This is what
## LoadingRig uses: there the panel stands in an empty world behind the rig's own
## dark WorldEnvironment, so nothing can show past the curtain and the yaw
## smoothing is free to lag.
func follow(camera: XRCamera3D, origin: Node3D) -> void:
	if camera == null or not is_instance_valid(camera):
		return
	_player_camera = camera
	_player_origin = origin
	_following = true
	if is_inside_tree():
		_follow_player(0.0, true)


## Same, plus the curtain is reparented onto the camera so it is FULLY
## head-locked — the PerfHud pattern, where plain parenting costs nothing per
## frame and cannot lag. Only LoadingOverlay uses this, and only because it
## covers a room that is really there: a yaw-smoothed curtain lags a head turn
## and shows a sliver of the room it is meant to be hiding.
##
## detach() must be called before this node dies, or the curtain is left behind
## on a camera that outlives it. _exit_tree does that.
func attach_to(camera: XRCamera3D, origin: Node3D) -> void:
	follow(camera, origin)
	if not _following:
		return
	if is_instance_valid(_curtain) and _curtain.get_parent() != camera:
		_curtain.get_parent().remove_child(_curtain)
		camera.add_child(_curtain)
		_curtain.transform = Transform3D(Basis(), Vector3(0.0, 0.0, -10.5))


## The curtain may be parented to a camera we do not own, so leaving the tree has
## to reclaim it. Without this, a panel freed while attached leaves a 44x30 quad
## welded to the player's face for the rest of the session.
func _exit_tree() -> void:
	detach()


## Put the curtain back under this node and stop following. Safe to call when
## never attached, and safe while the camera is already being freed — the curtain
## is ours, so it is reclaimed rather than left behind on a dying node.
func detach() -> void:
	if is_instance_valid(_curtain):
		var parent := _curtain.get_parent()
		if parent != null and parent != self:
			parent.remove_child(_curtain)
			add_child(_curtain)
			_curtain.transform = Transform3D(Basis(), Vector3(0.0, 1.65, -10.5))
	_player_camera = null
	_player_origin = null
	_following = false


func _follow_player(delta: float, snap: bool = false) -> void:
	_ensure()
	if not is_instance_valid(_player_camera) or _screen == null:
		return
	var here := _player_camera.global_position
	here.y = _player_origin.global_position.y if is_instance_valid(_player_origin) else 0.0
	global_position = here
	var target_yaw := _player_camera.global_rotation.y
	if snap:
		_screen.global_rotation.y = target_yaw
	else:
		# lerp_angle cannot overshoot the way a fixed angular step can.
		var weight := 1.0 - exp(-FOLLOW_RATE * delta)
		_screen.global_rotation.y = lerp_angle(_screen.global_rotation.y, target_yaw, weight)


## What is being loaded, shown above the bar.
func set_title(title: String) -> void:
	_ensure()
	if _title_label != null:
		_title_label.text = title


## Say what is happening in words, instead of the band derived from progress.
## An empty string hands the band back.
func set_status(text: String) -> void:
	_ensure()
	_status_override = text
	if _status_override.is_empty():
		_apply_progress_status()
	else:
		_status_text = _status_override
	_update_status_label()


## Extra rows under the bar — a netplay transfer's phase and byte counts. Empty
## clears them.
func set_detail(rows: PackedStringArray) -> void:
	_ensure()
	if not is_instance_valid(_detail_label):
		return
	_detail_label.text = "\n".join(rows)


func set_progress(value: float) -> void:
	if _load_failed:
		return
	# Threaded-loader progress should be monotonic, but individual dependency
	# reports can briefly move backwards. A loading bar must never do the same.
	_progress = maxf(_progress, clampf(value, 0.0, 1.0))
	_apply_progress()


func _apply_progress() -> void:
	_ensure()
	if _progress_material == null:
		return
	_progress_material.set_shader_parameter("progress", _progress)
	var percent := roundi(_progress * 100.0)
	if percent != _last_percent:
		_last_percent = percent
		_percent_label.text = "%d%%" % percent
	if _status_override.is_empty():
		_apply_progress_status()
	_update_status_label()


func _apply_progress_status() -> void:
	if _progress >= 1.0:
		_status_text = "READY"
	elif _progress >= 0.9:
		_status_text = "FINISHING SETUP"
	elif _progress >= 0.05:
		_status_text = "LOADING ROOM DATA"
	else:
		_status_text = "PREPARING ROOM"


## Make the failure unmistakable without taking the player's view away. The
## caller decides how long it stays.
func show_load_error(message: String = "RETRY OR CHOOSE ANOTHER ROOM") -> void:
	_ensure()
	_load_failed = true
	if _title_label != null:
		_title_label.text = "LOAD FAILED"
	_status_override = message
	_status_text = message
	_percent_label.text = "!"
	_progress_material.set_shader_parameter("failed", true)
	_progress_material.set_shader_parameter("progress", 1.0)
	_update_status_label()


## Back to a fresh screen, so one panel instance can serve a second show without
## inheriting the first one's bar position or error state.
func reset() -> void:
	_ensure()
	_load_failed = false
	_progress = 0.0
	_status_override = ""
	_last_percent = -1
	_progress_material.set_shader_parameter("failed", false)
	set_detail(PackedStringArray())
	_apply_progress()


func _update_status_label() -> void:
	if _status_label == null:
		return
	var rendered := _status_text
	if _load_failed or _progress >= 1.0:
		rendered += "   "
	else:
		var dot_count := int(_animation_time / 0.35) % 4
		rendered += ".".repeat(dot_count) + " ".repeat(3 - dot_count)
	if rendered != _last_status_rendered:
		_last_status_rendered = rendered
		_status_label.text = rendered

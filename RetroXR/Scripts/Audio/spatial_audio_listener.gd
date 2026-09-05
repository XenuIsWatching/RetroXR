extends Node

## Feeds the head pose to the Meta XR Audio SDK once per frame.
##
## Autoloaded rather than parented to the XRCamera3D so it survives scene
## changes and needs no edit to player_rig.tscn. It reads the viewport's current
## 3D camera, which is the XRCamera3D in VR and the desktop fallback camera
## otherwise, so it follows whichever is active without special-casing.
##
## Orientation is the point: Godot's built-in 3D audio only ever used listener
## position, and head rotation is what HRTF needs to place a source in front of
## or behind you.

var _active := false
var _mx: Object = null
var _listener_pos := Vector3.ZERO


## Where the head is this frame. Emitters need it because the SDK applies no
## distance law of its own, so the falloff has to be computed against this.
func get_listener_position() -> Vector3:
	return _listener_pos


## Switch the whole application between Meta XR Audio and Godot's own panning.
##
## Everything already in the room rebuilds at once. A RUNNING EMULATOR does not:
## its voices belong to the libretro audio handler, which chooses a backend when
## the core boots, so a system already switched on keeps what it started with and
## picks up the change the next time it is powered on. Nothing else has that
## constraint.
func set_sdk_enabled(enabled: bool) -> void:
	if _mx == null:
		return
	_mx.set_enabled(enabled)
	_active = _mx.is_available()
	set_process(_active)
	for e in get_tree().get_nodes_in_group(SpatialAudioEmitter.GROUP):
		e.rebuild_backend()
	print("[MetaXRAudio] spatialisation %s" % ("on" if _active else "off — Godot panning"))


func _ready() -> void:
	if not Engine.has_singleton("MetaXRAudio"):
		set_process(false)
		return
	_mx = Engine.get_singleton("MetaXRAudio")
	if _mx == null:
		set_process(false)
		return
	# The player's choice is applied HERE rather than pushed from AppPrefs at its
	# own _ready. This autoload is declared after AppPrefs, so AppPrefs is always
	# there to be asked, while the reverse is never true — AppPrefs' boot-time
	# push looked for /root/SpatialAudioListener before it existed and always
	# fell through to its singleton branch. A later autoload pulling from an
	# earlier one is the direction that survives the block being reordered.
	#
	# Before is_available(), because that is what enabling the SDK decides.
	# Android is excluded the same way AppPrefs excludes it: the option is not
	# offered there, so a stored value could only be stale.
	if OS.get_name() != "Android":
		_mx.set_enabled(AppPrefs.spatial_audio_sdk)
	_active = _mx.is_available()
	set_process(_active)
	if _active:
		print("[MetaXRAudio] listener tracking active — SDK ", _mx.get_version())
	else:
		print("[MetaXRAudio] not available (", _mx.get_last_error(),
			  "); emitters will use Godot panning")


func _process(_delta: float) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var vp := tree.root.get_viewport()
	if vp == null:
		return
	var cam := vp.get_camera_3d()
	if cam == null:
		return
	_listener_pos = cam.global_position
	_mx.set_listener_transform(cam.global_transform)


## True when the SDK is driving spatialisation. Probes and the settings UI read
## this rather than poking the singleton directly.
func is_spatialised() -> bool:
	return _active

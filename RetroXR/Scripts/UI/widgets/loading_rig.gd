## LoadingRig — the only thing in the tree while one scene is torn down and the
## next is loaded.
##
## SceneManager carries the player's own rig across that gap, so normally this
## just adds a LoadingPanel and a dark environment in front of wherever the player
## is standing — see prepare_for_player(). Without a player rig to borrow (a probe
## scene, a room that never had one) it falls back to its own origin and camera,
## so the headset still has a tracked view and something to look at.
##
## The panel itself lives in loading_panel.tscn, which is also used on its own to
## cover a room that is already in the tree — see LoadingOverlay. What stays here
## is the part that CANNOT coexist with a live room: the WorldEnvironment and the
## fallback camera, which is why this rig has to leave the tree before the
## incoming scene enters it.
class_name LoadingRig
extends Node3D


@onready var _own_origin := get_node_or_null("XROrigin3D") as XROrigin3D
@onready var _own_camera := get_node_or_null("XROrigin3D/XRCamera3D") as XRCamera3D
@onready var _panel: LoadingPanel = $LoadingPanel

var _player_camera: XRCamera3D = null
var _player_origin: Node3D = null


## Hand over the player's rig, which the caller is keeping alive across the
## transition. Call this BEFORE adding this node to the tree: it drops our own
## origin and camera, which must never reach the tree while the player's are live
## — two XROrigin3Ds cannot both be current, and a second camera would be
## competing for a viewport that already has one.
func prepare_for_player(player: PlayerRig) -> void:
	if player == null:
		return
	_player_camera = player.camera
	_player_origin = player.origin
	var own := get_node_or_null("XROrigin3D")
	if own != null:
		remove_child(own)
		own.free()


func _ready() -> void:
	if _player_camera != null:
		# Snap on the first frame so the panel cannot briefly appear at the old
		# room's origin. Subsequent motion is player-relative and yaw is smoothed
		# by the panel itself.
		_panel.follow(_player_camera, _player_origin)
	else:
		_own_origin.current = true
		_own_camera.current = true
	_panel.set_progress(0.0)


## Name of the room being loaded, shown above the bar.
func set_title(title: String) -> void:
	_panel.set_title(title)


func set_progress(value: float) -> void:
	_panel.set_progress(value)


## Leave the player's tracked view and menu alive while making the failure
## unmistakable. SceneManager keeps this rig in the tree until the player retries
## or chooses another room.
func show_load_error() -> void:
	_panel.show_load_error()

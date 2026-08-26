## CDPlayer — a pickable CD deck that plays an inserted audio CD (AudioDisc). Adds
## Prev/Next track skipping on top of the shared RetroAudioPlayer transport; the
## TV remote shows the full set (prev / play / pause / stop / ff / rew / next).
##
## Top-loads through a hinged lid like a PlayStation: press OPEN to raise the lid,
## drop the disc in the well (or lift it out), close the lid, and the disc spins
## while it plays — all handled by the shared MediaTray.
class_name CDPlayer
extends RetroAudioPlayer

# Disc spin (purely visual): ramps up while the lid is shut over a playing disc.
const DISC_SPIN_MAX := 25.0    # rad/s (~240 RPM)
const DISC_SPIN_UP := 18.0     # rad/s² ramp-up
const DISC_SPIN_DOWN := 10.0   # rad/s² ramp-down

var _tray: MediaTray = null
var _disc_spin := 0.0


func _ready() -> void:
	_media_group = "audio_disc"
	super._ready()
	add_to_group("cd_player")
	# OPEN lifts the lid, which is what eject means on a top loader.
	TransportGlyphs.label_buttons(self, {
		"OpenButton": "eject", "PrevButton": "prev", "RewindButton": "rew",
		"PlayButton": "play", "PauseButton": "pause", "StopButton": "stop",
		"FastForwardButton": "ff", "NextButton": "next",
	}, TransportGlyphs.DECK_SIZE)


## Top-loading lid tray via the shared MediaTray (replaces the base plain-snap).
func _setup_loader() -> void:
	_tray = MediaTray.new()
	_tray.host = self
	_tray.slot = _media_slot
	_tray.lid_pivot = get_node_or_null("TrayLidPivot")
	add_child(_tray)
	_tray.loaded.connect(_media_loaded)
	_tray.unloaded.connect(_media_unloaded)
	_tray.opened.connect(_on_lid_opened)
	var open_btn := get_node_or_null("OpenButton") as VRButton
	if open_btn:
		open_btn.button_pressed.connect(func() -> void:
			if _tray:
				_tray.toggle_open())
		open_btn.set_color(Color(0.8, 0.8, 0.85))


## The CD never auto-plays — the user presses PLAY once the lid is shut over a disc.
func _autoplay_on_load() -> bool:
	return false


## Opening the lid mid-play stops it (you can't read a spinning disc with the lid up).
func _on_lid_opened() -> void:
	if is_playing:
		stop()


func restore_media(media: Node3D) -> void:
	if _tray:
		_tray.restore(media)


## Lift the lid and take the disc out — a top loader has no eject that hands it back.
func remove_media() -> void:
	if _tray:
		_tray.set_open(true)
		_tray.release()


func deck_save_type() -> String:
	return "cd_player"


func _process(delta: float) -> void:
	super._process(delta)
	_update_disc_spin(delta)


## Spin the seated disc while the lid is shut and it's playing; ramp down otherwise.
func _update_disc_spin(delta: float) -> void:
	var disc := _tray.get_media() if _tray else null
	if disc == null or not is_instance_valid(disc):
		_disc_spin = 0.0
		return
	var target := DISC_SPIN_MAX if (is_playing and _tray.can_spin()) else 0.0
	var rate := DISC_SPIN_UP if target > _disc_spin else DISC_SPIN_DOWN
	_disc_spin = move_toward(_disc_spin, target, rate * delta)
	if _disc_spin > 0.0 and disc is RigidBody3D and (disc as RigidBody3D).freeze:
		disc.rotate_object_local(Vector3.UP, _disc_spin * delta)

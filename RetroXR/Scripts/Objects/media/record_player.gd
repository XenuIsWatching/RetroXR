## RecordPlayer — a pickable turntable that plays an LP (VinylRecord) dropped onto
## its platter. The third audio deck beside the CD and the cassette, and the first
## one whose interaction is not a button row: you cue it by hand.
##
## There is no FF/REW on a turntable, because there is no such control on one — you
## move the needle. So the deck reports has_scan() false, the base leaves those two
## buttons unbuilt, and the TV remote greys their cells. START and STOP drive the
## platter; PAUSE is kept because it costs nothing and a listener wants it.
##
## The TONEARM is the gate. MediaTray already expresses exactly a turntable's rule —
## while "open" the media is liftable and the well receptive, while "closed" it is
## locked — so the arm maps onto it: parked = open, cued over the record = closed.
## The tray keeps its own lid_pivot null and never animates anything; the arm is a
## real VRLever the player drags, and this deck relays its position to the tray.
##
## A VRLever rather than a bare VRHinge for one load-bearing reason: restoring a room
## calls VRLever.set_value(), which EMITS value_changed. A deck that started playing
## on value_changed would treat every save-load as someone dropping the needle — and
## broadcast it to the room. released() is emitted only by a real hand letting go, so
## the semantic "play this track" hangs off that, and value_changed drives only the
## cheap continuous side (the tray gate).
class_name RecordPlayer
extends RetroAudioPlayer

## Platter speeds, rad/s. 33 1/3 rpm and 45 rpm.
const SPEED_33 := 3.4907
const SPEED_45 := 4.7124
## Ramp rates, rad/s². A real platter takes a moment to come up and coasts down.
const PLATTER_SPIN_UP := 6.0
const PLATTER_SPIN_DOWN := 3.0

## Arm positions, as VRLever values. Below `arm_park` the arm is off the record
## entirely (the rest post); `arm_lead_in`..`arm_lead_out` is the playable band,
## mapped across the album's tracks.
##
## Exported rather than const because they are not opinions, they are where this
## deck's arm physically reaches: they follow from the pivot position, the arm
## length and the platter radius authored in the scene, and a deck with a different
## plinth has different ones. Calibrated with a throwaway probe — see the scene.
@export var arm_park: float = 0.35
@export var arm_lead_in: float = 0.557
@export var arm_lead_out: float = 1.0
## Radius of the platter, for deciding whether a fingertip is on the record.
@export var platter_radius: float = 0.152

## A hand on the record has to be moving this fast (rad/s) to count as scrubbing
## rather than braking it still.
const SCRUB_MIN_OMEGA := 0.35
## Fingertip must be within this of the platter plane, and inside its radius, to be
## touching the record at all.
const TOUCH_HEIGHT := 0.035
## The hand's angular rate is smoothed before it is believed — a tracked fingertip
## is noisy, and the raw per-frame delta reads as a stutter of direction changes.
const OMEGA_LERP := 14.0

var _tray: MediaTray = null
var _arm: VRLever = null
var _speed_switch: VRSlider = null
var _platter: Node3D = null
var _poke_area: Area3D = null

## Platter state. `_motor` is what START/STOP drives; `_platter_omega` is what the
## platter is actually doing this frame, which is not the same thing while it is
## spinning up, coasting down, or being held by a hand.
var _motor := false
var _platter_omega := 0.0
var _speed_45 := false

# Hand contact
var _controllers: Array[XRController3D] = []
var _touch_ctrl: XRController3D = null
var _touch_angle := 0.0
var _hand_omega := 0.0
var _was_playing_before_touch := false


func _ready() -> void:
	super._ready()
	add_to_group("record_player")
	TransportGlyphs.label_buttons(self, {
		"PlayButton": "play", "PauseButton": "pause", "StopButton": "stop",
	}, TransportGlyphs.DECK_SIZE)
	_platter = get_node_or_null("Platter")
	_arm = get_node_or_null("ArmMount/ArmPivot/TonearmLever") as VRLever
	if _arm:
		_arm.value_changed.connect(_on_arm_moved)
		_arm.released.connect(_on_arm_released)
	_speed_switch = get_node_or_null("SpeedSwitch") as VRSlider
	if _speed_switch:
		_speed_switch.value_changed.connect(_on_speed_changed)
		_speed_45 = _speed_switch.value > 0.5
	_poke_area = get_node_or_null("PlatterPoke") as Area3D
	_cache_controllers()


func deck_save_type() -> String:
	return "record_player"


## No scan hardware. Also stops a TV remote, or a stale peer's "ff", from scanning
## a deck that physically cannot.
func has_scan() -> bool:
	return false


## The needle CAN be moved from track to track, so the remote keeps prev/next even
## though there are no such buttons on the plinth. The base's handlers do not touch
## the button nodes, so they work; the arm is moved to match in _goto_track.
func has_track_skip() -> bool:
	return true


## Platter well via the shared MediaTray, with no lid of its own — the tonearm is
## the gate. MediaTray starts CLOSED, which for a turntable is backwards: it would
## leave a freshly spawned deck with a locked, unreceptive platter that no record
## could be put on. So it is opened here, unanimated, as its rest state.
func _setup_loader() -> void:
	_tray = MediaTray.new()
	_tray.host = self
	_tray.slot = _media_slot
	add_child(_tray)
	_tray.loaded.connect(_media_loaded)
	_tray.unloaded.connect(_media_unloaded)
	_tray.opened.connect(_on_arm_lifted)
	_tray.set_open(true, false)


## Dropping a record on the platter does not start it — you press START and lower
## the arm, in whichever order.
func _autoplay_on_load() -> bool:
	return false


## Lifting the needle mid-play stops the sound. The platter keeps turning, because
## the motor is a separate control and that is what a real deck does.
func _on_arm_lifted() -> void:
	if is_playing:
		stop()


func restore_media(media: Node3D) -> void:
	if _tray:
		_tray.restore(media)


func remove_media() -> void:
	if _tray:
		_tray.set_open(true)
		_tray.release()


# --- Tonearm ------------------------------------------------------------------

func _arm_value() -> float:
	return _arm.get_value() if _arm else 0.0


func _arm_parked() -> bool:
	return _arm_value() <= arm_park


## Continuous side of the arm: the access gate only. Deliberately does NOT start
## playback — see the class comment; this fires on restore as well as on a hand.
func _on_arm_moved(value: float) -> void:
	if _tray:
		_tray.set_open(value <= arm_park, false)


## The hand let go. THIS is the needle drop, and it is emitted only by a real
## release — never by a restore.
func _on_arm_released(value: float) -> void:
	if value <= arm_park:
		if is_playing:
			if not _net_forward_cmd("stop"):
				stop()
		return
	var idx := _track_at(value)
	if _net_forward_cmd_at("track", idx):
		return
	remote_goto_track(idx)


## Which track the needle is sitting over. The playable band is mapped across the
## album, so the outer edge is track 1 and the run-out is the last — which is where
## the tracks are on the record.
func _track_at(value: float) -> int:
	if _tracks.is_empty():
		return 0
	var t := clampf((value - arm_lead_in) / (arm_lead_out - arm_lead_in), 0.0, 1.0)
	return clampi(int(t * float(_tracks.size())), 0, _tracks.size() - 1)


## Where the needle should sit for a given track (the start of its band).
func _arm_value_for(idx: int) -> float:
	if _tracks.size() <= 0:
		return arm_lead_in
	var t := float(idx) / float(_tracks.size())
	return lerpf(arm_lead_in, arm_lead_out, t)


## Track changed by any route — the remote, a net command, auto-advance at the end
## of a track. Move the arm to match, WITHOUT emitting, or the needle would sit over
## track 2 while track 5 plays and the deck would be lying about itself.
func _goto_track(idx: int) -> void:
	super._goto_track(idx)
	if _arm and not _arm_parked():
		_arm.set_value_no_signal(_arm_value_for(_track_idx))


# --- Motor --------------------------------------------------------------------

## START. Spins the platter up; the sound only follows if the needle is down.
func _on_play_pressed() -> void:
	if _net_forward_cmd("play"):
		return
	_motor = true
	super._on_play_pressed()


## STOP. Kills the motor as well as the sound.
func _on_stop_pressed() -> void:
	if _net_forward_cmd("stop"):
		return
	_motor = false
	super._on_stop_pressed()


## A turntable cannot make a sound with the needle up. Refusing here rather than in
## the button handler covers every route into playback — the remote, auto-advance,
## a net state the peer is following. The base retries on its next heartbeat, so a
## client whose arm has not replicated yet recovers on its own rather than sticking.
func play() -> void:
	if _arm_parked():
		return
	_motor = true
	super.play()


func _process(delta: float) -> void:
	super._process(delta)
	_update_touch(delta)
	_update_platter(delta)


func _target_omega() -> float:
	return SPEED_45 if _speed_45 else SPEED_33


func _on_speed_changed(value: float) -> void:
	_speed_45 = value > 0.5
	_update_status()


## Spin the platter, and the seated record with it, from one angular velocity. The
## record is turned alongside rather than parented to the platter because the base
## and the net layer both resolve the well as $MediaSlot on the deck itself — moving
## that node under the platter to get free parenting left the tray with a null slot
## and no gate at all. Same approach as CDPlayer's spinning disc, which is proven.
##
## A hand on the record OVERRIDES the motor: that is the whole point of being able
## to touch it. Otherwise the platter eases toward the motor's speed.
func _update_platter(delta: float) -> void:
	if _platter == null:
		return
	if _touch_ctrl != null:
		_platter_omega = _hand_omega
	else:
		var target := _target_omega() if _motor else 0.0
		var rate := PLATTER_SPIN_UP if target > _platter_omega else PLATTER_SPIN_DOWN
		_platter_omega = move_toward(_platter_omega, target, rate * delta)
	if is_zero_approx(_platter_omega):
		return
	var step := -_platter_omega * delta
	_platter.rotate_object_local(Vector3.UP, step)
	var lp := _tray.get_media() if _tray else null
	if lp != null and is_instance_valid(lp) and lp is Node3D:
		(lp as Node3D).rotate_object_local(Vector3.UP, step)


# --- Touching the record ------------------------------------------------------
#
# Palm it to brake, drag it to scrub. Both go through machinery the base already
# has: a scrub is exactly the muted, throttled position-jumping that FF/REW does
# (_update_scan), with its rate and direction coming from the finger instead of a
# button, so the sign of the hand's rotation is _scan_dir and its speed relative to
# the platter's nominal speed is scan_speed.
#
# What this deliberately does NOT do is pitch-bend or reverse the audio. That needs
# per-sample resampling, and SpatialAudioEmitter records the measurement that a
# per-sample GDScript loop over this buffer cannot keep the ring fed. A real scratch
# is C++ work in vlc-godot. What is here reads as slowing, stopping and nudging a
# physical object, which is the honest version of it.

func _cache_controllers() -> void:
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node as XRController3D)


## The fingertip's angle about the spindle, in the platter's own frame, or NAN when
## the tip is not on the record at all.
func _touch_angle_of(ctrl: XRController3D) -> float:
	if _poke_area == null:
		return NAN
	var local: Vector3 = _poke_area.global_transform.affine_inverse() \
		* PokeTip.tip_of(ctrl)
	if absf(local.y) > TOUCH_HEIGHT:
		return NAN
	var radial := Vector2(local.x, local.z)
	# The spindle itself is a singularity, and a finger there is not scrubbing.
	if radial.length() > platter_radius or radial.length() < 0.02:
		return NAN
	return radial.angle()


func _update_touch(delta: float) -> void:
	if _poke_area == null or delta <= 0.0:
		return
	var ctrl := _touch_ctrl
	var angle := _touch_angle_of(ctrl) if is_instance_valid(ctrl) else NAN
	if is_nan(angle):
		ctrl = null
		for candidate in _controllers:
			if not is_instance_valid(candidate) or not candidate.get_is_active():
				continue
			if not PokeTip.is_poking(candidate):
				continue
			angle = _touch_angle_of(candidate)
			if not is_nan(angle):
				ctrl = candidate
				break
	if ctrl == null:
		if _touch_ctrl != null:
			_end_touch()
		return
	if _touch_ctrl == null:
		_begin_touch(ctrl, angle)
		return
	# Shortest-arc delta, so crossing the ±PI seam is not read as a full turn back.
	var d := angle_difference(_touch_angle, angle)
	_touch_angle = angle
	var raw := d / delta
	_hand_omega = lerpf(_hand_omega, raw, clampf(OMEGA_LERP * delta, 0.0, 1.0))
	_apply_scrub()


func _begin_touch(ctrl: XRController3D, angle: float) -> void:
	_touch_ctrl = ctrl
	_touch_angle = angle
	_hand_omega = 0.0
	_was_playing_before_touch = is_playing and not _paused
	# A hand landing on a playing record silences it at once, before any scrub rate
	# has been measured — that is what happens when you touch one.
	if is_playing and not _net_forward_cmd("pause"):
		_scan_dir = 0
		if _vlc:
			_vlc.set_paused(true)
		_paused = true
		_apply_volume()
		_update_status()


## Rate and direction of the scrub, handed to the base's scan loop. Local only on a
## client: transport is the host's, and a per-frame position stream is not something
## to put on the wire. A client still brakes the platter it can see, and its pause /
## resume intent is forwarded, so the room stays together.
func _apply_scrub() -> void:
	if NetworkManager.is_client() or not is_playing:
		return
	var nominal := _target_omega()
	if absf(_hand_omega) < SCRUB_MIN_OMEGA or is_zero_approx(nominal):
		# Held still: braked, and silent.
		_scan_dir = 0
		_apply_volume()
		return
	# One turn of the record is one turn's worth of audio, so the seek rate is just
	# how much faster or slower than the motor the hand is going.
	scan_speed = absf(_hand_omega) / nominal
	_scan_dir = 1 if _hand_omega > 0.0 else -1
	if _vlc:
		_vlc.set_paused(false)
	_paused = false
	_scan_accum = 0.0
	_apply_volume()


func _end_touch() -> void:
	_touch_ctrl = null
	_hand_omega = 0.0
	_scan_dir = 0
	if not _was_playing_before_touch:
		_apply_volume()
		_update_status()
		return
	# Let go of a record that was playing and it picks up from where you left it.
	if _net_forward_cmd("play"):
		return
	if _vlc:
		_vlc.set_paused(false)
	_paused = false
	_apply_volume()
	_update_status()
	_net_push_state()


# --- Net ----------------------------------------------------------------------

## Forward an intent that carries an index (the needle landing on a track). The
## base's _net_forward_cmd has no room for one.
func _net_forward_cmd_at(cmd: String, index: int) -> bool:
	if NetworkManager.is_client() and not NetworkManager.is_event_applying():
		NetworkManager.report_event(NetObjectSync.EV_AUDIO_CMD,
			{"player": self, "cmd": cmd, "index": index})
		return true
	return false

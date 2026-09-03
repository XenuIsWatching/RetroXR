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
## What a 45 does to a record cut at 33 1/3: 45 / (100/3). The mesh IS a 12" LP, so
## every record here is a 33 and the switch is the thing that can be wrong — play
## one at 45 and it comes out a third faster and a fifth higher, which is the whole
## joke of the control. VlcPlayer runs with --no-audio-time-stretch so the rate
## bends pitch instead of preserving it; measured 1.338 against this 1.35.
const RATE_45 := 1.35
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

## Below this rate the record is turning too slowly to be a note rather than a
## rumble, and libVLC refuses a rate of 0 outright. The sound stops here and picks
## up again when the platter does — which is what a record coasting to a halt does.
const RATE_MIN := 0.25
## A hand can spin a record absurdly fast. Past this the pitch is noise and there is
## no point asking libVLC for it.
const RATE_MAX := 2.5
## The rate is pushed at 20 Hz rather than every frame, and only on a real change.
## Each push strands whatever run-ahead libVLC has already decoded at the old rate
## (see _update_rate), so pushing per-frame in VR would be 90 corrections a second.
const RATE_PUSH_INTERVAL := 0.05
const RATE_PUSH_EPSILON := 0.01
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
var _rate_pushed := 1.0
var _rate_accum := 0.0
## Paused because the PLATTER stopped, as opposed to because someone pressed pause.
## Only a stall resumes on its own.
var _stalled := false


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
	_apply_rate()


func _process(delta: float) -> void:
	super._process(delta)
	_update_touch(delta)
	_update_platter(delta)
	_update_rate(delta)


func _target_omega() -> float:
	return SPEED_45 if _speed_45 else SPEED_33


## Deliberately NOT a net command. A speed is a control POSITION, not transport
## state, and the switch already replicates through the articulated-control path
## like every other knob and lever in the room — so each peer derives its own rate
## from its own slider and they cannot disagree. Routing it through EV_AUDIO_CMD
## as well would have two mechanisms driving one value.
func _on_speed_changed(value: float) -> void:
	_speed_45 = value > 0.5
	_apply_rate()
	_update_status()


## The rate the deck settles at for the selected speed — the platter's target
## expressed as audio. Falls out of the two platter speeds rather than being a
## second, independent number: SPEED_45 / SPEED_33 IS 1.35.
func playback_rate() -> float:
	return _target_omega() / SPEED_33


## The rate the record is turning at RIGHT NOW, which is not the same thing while
## the platter is spinning up, coasting down, or being held by a hand.
func current_rate() -> float:
	return _platter_omega / SPEED_33


## Pushed after every play() because open() builds a fresh media player that starts
## back at 1.0; _update_rate keeps it there afterwards.
func _apply_rate() -> void:
	if _vlc:
		_rate_pushed = clampf(current_rate(), RATE_MIN, RATE_MAX)
		_vlc.set_rate(_rate_pushed)


## THE PITCH FOLLOWS THE PLATTER. Not the switch — the platter, which is already
## ramping toward the switch's speed, already coasting down after STOP, and already
## being dragged by a hand on the record. One rule then covers all four: a deck
## starting glides up to pitch, a stopped one sags away instead of cutting, the
## 33/45 switch bends between speeds the way a real one does, and palming the record
## drops the note as it slows.
##
## Gliding is also what keeps the switch from clicking. A rate change strands every
## sample libVLC has already decoded at the old rate — around 1.15 s of run-ahead —
## and read_audio's lead corrector then discards the difference in one go, measured
## at 316 ms of audio for a straight 1.00 -> 1.35 jump. Ramped, each step strands a
## few ms and the corrector trims that instead.
##
## Local on every peer, deliberately. The platter's spin has always been local, so
## the pitch derived from it is too: a client palming its own record bends its own
## note while the host keeps owning POSITION, and the base's drift correction reels
## the position back afterwards.
func _update_rate(delta: float) -> void:
	if _vlc == null or not is_playing:
		return
	_rate_accum += delta
	var want := current_rate()

	# Turning too slowly to be a note. Stop the sound rather than ask libVLC for a
	# rate it will refuse, and remember that it was the PLATTER that stopped it.
	if want < RATE_MIN:
		if not _paused:
			_stalled = true
			_vlc.set_paused(true)
			_paused = true
			_apply_volume()
			_update_status()
		return
	if _stalled:
		_stalled = false
		_vlc.set_paused(false)
		_paused = false
		_apply_volume()
		_update_status()
	if _paused:
		return   # someone pressed pause; leave it alone

	if _rate_accum < RATE_PUSH_INTERVAL:
		return
	want = clampf(want, RATE_MIN, RATE_MAX)
	if absf(want - _rate_pushed) < RATE_PUSH_EPSILON:
		return
	_rate_accum = 0.0
	_rate_pushed = want
	_vlc.set_rate(want)


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
# A hand on the record drags the PLATTER, and nothing here touches the audio at all:
# _update_rate derives the pitch from the platter afterwards, so palming it bends the
# note down and letting go lets it climb back. That replaced a muted, seek-based
# scrub that ran the base's FF/REW machinery from the fingertip — two mechanisms
# reacting to one gesture, and the quieter of the two.
#
# BACKWARDS IS SILENT, and that is a real limitation rather than a choice. libVLC
# has no negative rate, so a record dragged the wrong way falls under RATE_MIN and
# stops rather than playing in reverse. Reverse, and a true scratch with it, needs
# per-sample resampling — which SpatialAudioEmitter records as unaffordable in
# GDScript, so it is C++ work in vlc-godot whenever it happens.

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


## Taking hold of the record only starts MEASURING it. The hand's rotation becomes
## the platter's in _update_platter, and the pitch follows from there — so there is
## nothing to silence here, and no transport intent to forward.
func _begin_touch(ctrl: XRController3D, angle: float) -> void:
	_touch_ctrl = ctrl
	_touch_angle = angle
	_hand_omega = 0.0


## Letting go hands the platter back to the motor, which spins it back up — and the
## pitch climbs with it, because the pitch is DERIVED from the platter rather than
## saved and restored around the gesture. Nothing to resume, nothing to forward.
func _end_touch() -> void:
	_touch_ctrl = null
	_hand_omega = 0.0


# --- Net ----------------------------------------------------------------------

## Forward an intent that carries an index (the needle landing on a track). The
## base's _net_forward_cmd has no room for one.
func _net_forward_cmd_at(cmd: String, index: int) -> bool:
	if NetworkManager.is_client() and not NetworkManager.is_event_applying():
		NetworkManager.report_event(NetObjectSync.EV_AUDIO_CMD,
			{"player": self, "cmd": cmd, "index": index})
		return true
	return false

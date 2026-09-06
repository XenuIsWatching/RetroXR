class_name SpatialAudioEmitter
extends Node3D

## One spatialised sound source, with two interchangeable backends.
##
## SDK backend: HRTF voices from the Meta XR Audio SDK, mixed by the
## metaxr-audio GDExtension. Fallback backend: the AudioStreamPlayer3D +
## AudioStreamGenerator pair this project used everywhere before, with the same
## unit_size / max_distance values so nothing regresses when the SDK is absent.
##
## The backend is chosen once at _ready and never changes. Callers push stereo
## PCM and set a volume; they do not know or care which one is running.

## Half the distance between the left and right speakers, in metres. A TV or a
## hi-fi radiates from two points; a handheld is a single speaker, so leave this
## at 0.0 and one voice is used.
@export var speaker_separation: float = 0.0

## Godot's ATTENUATION_INVERSE_DISTANCE parameters, used by both backends so the
## two sound alike at a distance.
@export var unit_size: float = 3.0
@export var max_distance: float = 15.0

const _MUTE_DB := -80.0

var _use_sdk := false
var _volume := 1.0

# Engine.register_singleton from a GDExtension does not create a GDScript global
# identifier the way an autoload does, so the singleton has to be fetched and
# cached rather than referenced by bare name.
var _mx: Object = null

# SDK backend
var _voice_l := -1
var _voice_r := -1

# Fallback backend
var _player: AudioStreamPlayer3D = null
var _playback: AudioStreamGeneratorPlayback = null

# Where the sound should appear to come from. Defaults to this node, but a
# device can redirect it (the emulator's audio moves to whichever TV is showing
# the picture).
var _emit_origin := Vector3.ZERO
var _emit_override := false

# Explicit left/right points, when the source can name them outright rather than
# leaving them to be spread around _emit_origin. See set_speaker_positions.
var _speaker_l_pos := Vector3.ZERO
var _speaker_r_pos := Vector3.ZERO
var _speaker_override := false

# Head position, for the distance law applied in _apply_distance_gain, and the
# last gain handed over so an unchanged one costs nothing.
var _listener: Node = null
var _sent_gain_l := -1.0
var _sent_gain_r := -1.0

# Per-channel trim, so one channel can be silenced without touching the other.
# See set_channel_gains.
var _ch_gain_l := 1.0
var _ch_gain_r := 1.0

## Which source channel feeds each speaker. See set_channel_mode.
enum ChannelMode { STEREO = 0, MONO_LEFT = 1, MONO_RIGHT = 2 }
var _channel_mode: ChannelMode = ChannelMode.STEREO
# Last distance term measured, so a volume change can be applied against it
# without waiting for the next frame.
var _dist_factor := 1.0

## How directional this source is, 0 (omnidirectional) to 1. Only consulted once
## a direction has been given; see set_emit_direction.
@export var directivity: float = 0.0

## Directivity that suits a speaker firing out of a box -- a television, a deck.
## A few dB down when turned away rather than gone. The measured curve is on
## RetroSystem.audio_directivity.
const SPEAKER_DIRECTIVITY := 0.45

# Which way the sound radiates. ZERO leaves it omnidirectional, which is what a
# source with no meaningful facing wants.
var _emit_forward := Vector3.ZERO
var _emit_up := Vector3.UP
var _sent_directivity := -1.0


## Every live emitter, so the desktop switch between the two backends can reach
## the ones already in the room rather than only the next one built.
const GROUP := "spatial_audio_emitter"


func _ready() -> void:
	add_to_group(GROUP)
	_choose_backend()
	set_process(true)


func _choose_backend() -> void:
	_use_sdk = _sdk_available()
	if _use_sdk:
		_voice_l = _mx.create_voice()
		if speaker_separation > 0.0:
			_voice_r = _mx.create_voice()
		# Out of voices: fall back rather than run silent.
		if _voice_l < 0:
			_use_sdk = false
		else:
			_listener = get_node_or_null("/root/SpatialAudioListener")
	if not _use_sdk:
		_setup_fallback()


## Drop the current backend and choose again. The backend is normally settled at
## _ready and never revisited; this exists for the desktop switch between Meta XR
## Audio and Godot's own panning, which has to take effect on sources that are
## already playing. Whatever was queued is lost -- the two backends do not share
## a buffer -- so expect a click, once, at the switch.
func rebuild_backend() -> void:
	var volume := _volume
	if _use_sdk:
		if _voice_l >= 0:
			_mx.destroy_voice(_voice_l)
		if _voice_r >= 0:
			_mx.destroy_voice(_voice_r)
		_voice_l = -1
		_voice_r = -1
	elif is_instance_valid(_player):
		_player.stop()
		_player.queue_free()
		_player = null
		_playback = null
	_sent_gain_l = -1.0
	_sent_gain_r = -1.0
	_sent_directivity = -1.0
	_dist_factor = 1.0
	_choose_backend()
	set_volume(volume)


func _exit_tree() -> void:
	if _use_sdk:
		if _voice_l >= 0:
			_mx.destroy_voice(_voice_l)
		if _voice_r >= 0:
			_mx.destroy_voice(_voice_r)
		_voice_l = -1
		_voice_r = -1


func _sdk_available() -> bool:
	if not Engine.has_singleton("MetaXRAudio"):
		return false
	_mx = Engine.get_singleton("MetaXRAudio")
	return _mx != null and _mx.is_available()


func _setup_fallback() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = float(AudioServer.get_mix_rate())
	gen.buffer_length = 0.25
	_player = AudioStreamPlayer3D.new()
	_player.name = "AudioStreamPlayer3D"
	_player.stream = gen
	_player.unit_size = unit_size
	_player.max_distance = max_distance
	_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(_player)
	_player.play()
	_playback = _player.get_stream_playback()


func _process(_delta: float) -> void:
	var origin: Vector3
	var l_pos: Vector3
	var r_pos: Vector3
	if _speaker_override:
		# Two points given outright, so nothing is derived: the source that owns
		# the speakers knows where they are far better than a spread along this
		# node's X does.
		l_pos = _speaker_l_pos
		r_pos = _speaker_r_pos
		# Everything that wants one point -- the distance law, the fallback
		# backend -- takes the middle of the pair.
		origin = (l_pos + r_pos) * 0.5
	else:
		origin = _emit_origin if _emit_override else global_position
		l_pos = origin + _speaker_offset(-1.0)
		r_pos = origin + _speaker_offset(1.0)
	if _use_sdk:
		# The mixer skips the underlying SDK call when the position has not
		# changed, so writing this every frame is safe -- it saves a lock, and
		# most emitters here rewrite a position that never moved.
		if _voice_r < 0:
			l_pos = origin      # one voice: the middle, not the left speaker
		if is_instance_valid(_listener):
			var lp: Vector3 = _listener.get_listener_position()
			l_pos = hold_off_head(l_pos, lp)
			r_pos = hold_off_head(r_pos, lp)
		_apply_directivity()
		if _emit_forward == Vector3.ZERO:
			_mx.set_voice_position(_voice_l, l_pos)
			if _voice_r >= 0:
				_mx.set_voice_position(_voice_r, r_pos)
		else:
			_mx.set_voice_pose(_voice_l, l_pos, _emit_forward, _emit_up)
			if _voice_r >= 0:
				_mx.set_voice_pose(_voice_r, r_pos, _emit_forward, _emit_up)
		# Gain from the TRUE origin, not the held-off one: the hold-off exists to
		# keep the HRTF usable, and should not also make a source quieter.
		_apply_distance_gain(origin)
	elif is_instance_valid(_player):
		_player.global_position = origin


## Distance attenuation, which the SDK will not do for us.
##
## A freshly created context applies no distance law at all: a source four
## metres away measures the same level as one a metre away. Of the modes
## mxra_source_set_attenuation accepts, only one attenuates and it falls off far
## steeper than inverse-distance, so the law is applied here instead, through the
## gain, from the same unit_size / max_distance the fallback hands to
## AudioStreamPlayer3D. The two backends then behave alike, which is what this
## class promises. Without it every emitter plays at full level everywhere and
## max_distance means nothing at all.
##
## Clamped to 1.0 inside unit_size, where Godot's own curve keeps climbing. A
## handheld ends up centimetres from the head and the unclamped law runs away
## there.
func _apply_distance_gain(origin: Vector3) -> void:
	if is_instance_valid(_listener):
		_dist_factor = distance_gain(origin, _listener.get_listener_position(),
			unit_size, max_distance)
	_send_gain(_volume * _dist_factor)


func _send_gain(g: float) -> void:
	var gl: float = g * _ch_gain_l
	var gr: float = g * _ch_gain_r
	if is_equal_approx(gl, _sent_gain_l) and is_equal_approx(gr, _sent_gain_r):
		return
	_sent_gain_l = gl
	_sent_gain_r = gr
	_mx.set_voice_gain(_voice_l, gl)
	if _voice_r >= 0:
		_mx.set_voice_gain(_voice_r, gr)


## Per-channel trim on top of the volume, 0.0 .. 1.0 each.
##
## For a source whose two channels can be routed independently — a deck whose left
## cord is plugged in and whose right is not. The channels are separate VOICES
## carrying separate sample streams, so silencing one is a gain of zero on it and
## costs nothing; doing it by editing the samples would mean per-sample GDScript at
## 48 kHz, which cannot keep a ring fed.
##
## Godot's fallback backend has a single player fed interleaved stereo and cannot
## split them. There, anything above zero on either channel plays both — a
## half-connected lead is heard in full rather than not at all, which is the less
## confusing failure.
## Which source channel each speaker is fed from: STEREO leaves the pair alone,
## MONO_LEFT sends the left channel to both, MONO_RIGHT the right.
##
## A duplication, not a downmix — both speakers still radiate, so the sound keeps
## its place in the room instead of collapsing into one cabinet. Applied where the
## interleaved buffer is split into the two voices (in C++), because rewriting a
## frame buffer per push in GDScript cannot keep a 48 kHz ring fed.
##
## Godot's fallback backend has one player fed interleaved stereo and no separate
## speaker voices to route between, so it keeps playing the pair as authored —
## the same way set_channel_gains degrades there.
func set_channel_mode(mode: ChannelMode) -> void:
	_channel_mode = clampi(mode, ChannelMode.STEREO, ChannelMode.MONO_RIGHT)


func get_channel_mode() -> ChannelMode:
	return _channel_mode


func set_channel_gains(l: float, r: float) -> void:
	_ch_gain_l = clampf(l, 0.0, 1.0)
	_ch_gain_r = clampf(r, 0.0, 1.0)
	if _use_sdk:
		_send_gain(_volume * _dist_factor)
	elif is_instance_valid(_player):
		var live: float = maxf(_ch_gain_l, _ch_gain_r)
		_player.volume_db = _MUTE_DB if _volume * live <= 0.0 \
			else linear_to_db(_volume * live)


## Closest a source is allowed to sit to the head, in metres.
##
## Measured against the shipped SDK: inside about 0.2 m it loses treble and
## level together. At 5 cm the 4-16 kHz band sits 3.3 dB down on 100-1000 Hz and
## the whole source is 5.9 dB quieter than the same source at 2 m -- audibly
## muffled, and getting fainter the closer it comes, which is backwards. HRTF
## sets are measured at a metre or more, so this is the model running out rather
## than anything being done wrong; a handheld raised to the face lands well
## inside it.
const MIN_LISTENER_DISTANCE := 0.25


## Push a source out to MIN_LISTENER_DISTANCE if it is nearer than that, along
## the line it already sits on so the direction is untouched.
static func hold_off_head(pos: Vector3, listener: Vector3) -> Vector3:
	var v := pos - listener
	var d := v.length()
	if d >= MIN_LISTENER_DISTANCE:
		return pos
	if d < 0.0001:
		return listener + Vector3(0.0, 0.0, -MIN_LISTENER_DISTANCE)   # dead ahead
	return listener + v * (MIN_LISTENER_DISTANCE / d)


## Godot's ATTENUATION_INVERSE_DISTANCE as a plain number, 0.0 .. 1.0. Static
## because RetroSystem drives its libretro voices through the singleton rather
## than through an emitter, and both have to fall off identically.
static func distance_gain(origin: Vector3, listener: Vector3,
		p_unit_size: float, p_max_distance: float) -> float:
	var d := origin.distance_to(listener)
	if p_max_distance > 0.0 and d >= p_max_distance:
		return 0.0
	if d <= p_unit_size:
		return 1.0
	return p_unit_size / d


func _speaker_offset(sign_x: float) -> Vector3:
	if _voice_r < 0 or speaker_separation <= 0.0:
		return Vector3.ZERO
	return global_transform.basis.x.normalized() * (sign_x * speaker_separation)


## Emit from somewhere other than this node's own position -- used when a
## console's sound should come from the TV it is plugged into.
func set_emit_position(pos: Vector3) -> void:
	_emit_origin = pos
	_emit_override = true


## Go back to emitting from this node.
func clear_emit_position() -> void:
	_emit_override = false


## Radiate from two given points instead of a centre plus `speaker_separation`.
##
## For a deck playing through a TV: the set carries authored speaker markers, so
## it can say where its two channels leave the cabinet, which beats spreading
## them along the DECK's local X -- an axis that has nothing to do with the set
## and swings whenever the deck is turned. Takes precedence over
## set_emit_position, since the pair already says where the sound is.
##
## World space, and expected every frame: the caller reads them off a set that
## can be picked up and carried.
func set_speaker_positions(l: Vector3, r: Vector3) -> void:
	_speaker_l_pos = l
	_speaker_r_pos = r
	_speaker_override = true


## Go back to a centre plus the authored separation.
func clear_speaker_positions() -> void:
	_speaker_override = false


## Point the sound somewhere -- the screen normal of the set it is playing
## through, say. Until this is called the source stays omnidirectional however
## `directivity` is set, since there is nothing to be directional about.
func set_emit_direction(forward: Vector3, up: Vector3 = Vector3.UP) -> void:
	_emit_forward = forward
	_emit_up = up


func clear_emit_direction() -> void:
	_emit_forward = Vector3.ZERO


func _apply_directivity() -> void:
	var k: float = directivity if _emit_forward != Vector3.ZERO else 0.0
	if is_equal_approx(k, _sent_directivity):
		return
	_sent_directivity = k
	_mx.set_voice_directivity(_voice_l, k)
	if _voice_r >= 0:
		_mx.set_voice_directivity(_voice_r, k)


## How many frames the producer should hand over right now. Deliberately not
## "all the free space": queue depth is latency, and filling a large buffer to
## the brim is what makes the existing generator path carry ~250 ms.
##
## What this bounds is the queue on THIS side, which for a libretro core is the
## whole of the latency: Wrapper stalls instead of calling retro_run() while this
## is saturated, so the core cannot run ahead, and audio and video stay locked
## because that one call produces both.
##
## It says nothing about libVLC, which has no such brake. That decoder runs
## seconds ahead of the play dates it stamps and hands the run-ahead over in
## bursts, so asking it for less does not reduce anything -- it only leaves
## future audio sitting in VlcPlayer's ring. Sync on that path comes from
## serving each sample at its play date; see VlcPlayer::read_audio.
func frames_wanted() -> int:
	if _use_sdk:
		return _mx.voice_frames_wanted(_voice_l)
	if _playback == null:
		return 0
	return _playback.get_frames_available()


## Push interleaved stereo. Deinterleaved into two voices when this emitter has
## separated speakers, summed to the single voice otherwise.
func push_stereo(frames: PackedVector2Array) -> void:
	if frames.is_empty():
		return
	if _use_sdk:
		# Passing -1 for the right voice downmixes in C++. Doing it here with a
		# per-sample GDScript loop cannot keep a 48 kHz ring fed and starves the
		# voice outright — which is why the channel mode is passed down too
		# rather than the buffer being rewritten here.
		_mx.push_stereo_frames(_voice_l, _voice_r, frames, _channel_mode)
	elif _playback != null:
		_playback.push_buffer(frames)


## Drop anything still queued, so a device that stops and later restarts does
## not replay a stale tail.
func flush() -> void:
	if _use_sdk:
		_mx.flush_voice(_voice_l)
		if _voice_r >= 0:
			_mx.flush_voice(_voice_r)
	elif is_instance_valid(_player):
		# The generator has no flush; restarting the stream is the equivalent.
		_player.stop()
		_player.play()
		_playback = _player.get_stream_playback()


## 0.0 .. 1.0. Keeps the -80 dB mute floor the device scripts already assume.
func set_volume(volume: float) -> void:
	_volume = clampf(volume, 0.0, 1.0)
	if _use_sdk:
		# Applied here and now against the distance factor already measured, not
		# left for the next _process. A mute has to be immediate and must not
		# depend on this node being processed -- silencing something is the one
		# volume change nobody can afford to have arrive a frame late, or not at
		# all. _process keeps the distance term up to date from here on.
		_send_gain(_volume * _dist_factor)
	elif _player != null:
		_player.volume_db = _MUTE_DB if _volume <= 0.0 else linear_to_db(_volume)


func get_volume() -> float:
	return _volume


## True when this emitter is running on the Meta XR Audio SDK rather than
## Godot's built-in panning. Probes assert on this.
func is_spatialised() -> bool:
	return _use_sdk

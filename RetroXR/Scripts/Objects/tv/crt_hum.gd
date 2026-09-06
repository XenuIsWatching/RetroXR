## The noise a CRT television makes while it is switched on.
##
## Attach as a child of a RetroTV and call set_powered(). It plays a degauss
## transient, settles into the flyback whine, and plays a switch-off transient —
## all through SpatialAudioEmitter, so it is spatialised by Meta XR Audio when the
## SDK is present and by AudioStreamPlayer3D when it is not.
##
## Two things drive the design, both from the emitter:
##
##  * It is PCM-PUSH ONLY. There is no "play this AudioStream" path, so the clips
##    are decoded to frames once by PcmClip and pushed a slice at a time in
##    _process. That is also why the loop can be seamless without a crossfade: the
##    idle clip is exactly periodic by construction, so the read index simply
##    wraps.
##  * GDScript cannot do per-sample work at the mix rate — the emitter's own
##    comments record a per-sample loop starving the voice outright — so nothing
##    here touches a sample. It slices pre-built buffers.
##
## The transients hand off to the loop with no level jump because the generator
## built them from the same recipe: the tail of the power-on matches the loop's
## RMS to within 0.2%. There is still a phase discontinuity at the splice, since
## the loop's whine starts at phase 0 and the transient ends wherever it ends, so
## a short crossfade covers the join.
class_name CrtHum
extends Node3D


const IDLE := "res://Audio/crt/crt_idle.wav"
const POWER_ON := "res://Audio/crt/crt_power_on.wav"
const POWER_OFF := "res://Audio/crt/crt_power_off.wav"

## Crossfade over the splice between a transient and the loop. The whine is
## 15734 Hz and the two sides meet at an arbitrary phase; without this the join
## ticks. 20 ms is ~300 cycles, far longer than needed to hide it and far shorter
## than anything the ear reads as a fade.
const SPLICE_FADE := 0.02

## Distance at which the hum plays at full gain. Small on purpose: this is a
## faint mechanical noise, not room-filling audio like the console feed
## (unit_size 3.0). page_sfx.gd is the precedent for a close-range sound.
@export var unit_size: float = 0.3
## Beyond this the hum is silent. Close enough that the set has to be within
## reach to be heard at all, which is how a real one behaves — the flyback is
## quiet enough to vanish under room noise a couple of steps away.
##
## Keep this around 4-5x unit_size. Inverse-distance attenuation still has gain
## unit_size/max_distance left when the hard cut lands, so a narrower ratio makes
## the cut audible as a click when you walk away.
@export var max_distance: float = 1.5
## Level. Expect to retune on device: the whine sits at 15.7 kHz where the Quest's
## off-ear speakers are weakest, so the headset may want MORE than the desktop.
@export var volume: float = 0.1

var _emitter: SpatialAudioEmitter = null
var _idle_clip: PackedVector2Array = []
var _power_on_clip: PackedVector2Array = []
var _power_off_clip: PackedVector2Array = []

var _powered := false
var _transient: PackedVector2Array = []   # empty once the transient has finished
var _t_read := 0
var _loop_read := 0
var _fade_frames := 0


func _ready() -> void:
	_idle_clip = PcmClip.load_frames(IDLE)
	_power_on_clip = PcmClip.load_frames(POWER_ON)
	_power_off_clip = PcmClip.load_frames(POWER_OFF)
	_fade_frames = int(SPLICE_FADE * AudioServer.get_mix_rate())

	_emitter = SpatialAudioEmitter.new()
	_emitter.name = "HumEmitter"
	_emitter.unit_size = unit_size
	_emitter.max_distance = max_distance
	# speaker_separation stays 0: the whine radiates from the flyback transformer,
	# a single point inside the cabinet, not from the speaker grille.
	add_child(_emitter)
	_emitter.set_volume(0.0)
	set_process(true)


## Power state. NOT the volume knob and NOT mute: the flyback whine is mechanical,
## radiated by the transformer rather than the speaker, so turning a real set down
## does not quiet it. Only switching off does.
##
## `transient` false skips the degauss / switch-off clip and jumps straight to the
## steady state. Used at load: a scene whose TVs are authored ON must not thunk at
## the player as they walk in, because nobody switched anything on.
func set_powered(on: bool, transient: bool = true) -> void:
	if on == _powered:
		return
	_powered = on
	_transient = (_power_on_clip if on else _power_off_clip) if transient else PackedVector2Array()
	_t_read = 0
	_loop_read = 0
	if on:
		_emitter.set_volume(volume)


func _process(_delta: float) -> void:
	if _emitter == null:
		return
	var want := _emitter.frames_wanted()
	if want <= 0:
		return
	if not _powered and _transient.is_empty():
		return                                  # off and the tail has played out

	var out: PackedVector2Array = []
	out.resize(want)
	for i in want:
		out[i] = _next_frame()
	_emitter.push_stereo(out)

	if not _powered and _transient.is_empty():
		_emitter.set_volume(0.0)


func _next_frame() -> Vector2:
	# Still inside a power-on / power-off transient.
	if not _transient.is_empty():
		var s: Vector2 = _transient[_t_read]
		_t_read += 1
		# Crossfade the last SPLICE_FADE of a power-ON into the loop, so the
		# 15.7 kHz phase jump at the join does not tick.
		if _powered:
			var left := _transient.size() - _t_read
			if left < _fade_frames and not _idle_clip.is_empty():
				var f := 1.0 - float(left) / float(_fade_frames)
				s = s.lerp(_idle_clip[_loop_read % _idle_clip.size()], f)
				_loop_read += 1
		if _t_read >= _transient.size():
			_transient = PackedVector2Array()
		return s

	if not _powered or _idle_clip.is_empty():
		return Vector2.ZERO

	# The loop is exactly periodic by construction, so wrapping the read index is
	# seamless — no crossfade needed here, unlike the splice above.
	var v: Vector2 = _idle_clip[_loop_read % _idle_clip.size()]
	_loop_read += 1
	return v

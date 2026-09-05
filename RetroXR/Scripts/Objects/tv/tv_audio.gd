## TvAudio — the set's volume, mute and speaker switch, and pushing the result to
## whatever is making the sound.
##
## A child of the RetroTV it serves, created unconditionally in _init, in the same
## shape as TvResize, TvFit and TvOsd.
##
## The set owns no emitter of its own except the tuner's, so nothing here mixes
## anything: it decides a level and a channel routing and hands both to the
## connected host, which owns the samples.
##
## _volume, _muted and audio_mode stay on RetroTV. get_control_state and
## restore_control_state read them by name, object_sync replicates them, and
## object_sync_tests writes all three directly — the same reason scale_factor stays
## there rather than moving into TvResize.
class_name TvAudio
extends Node

## The set this listens for. Every level below is pushed to its connected hosts.
var _tv: RetroTV = null



## Loudness and mute live here rather than on RetroTV, because this helper is
## the only thing that changes them: the set reads them back for its OSD and its
## save file. Mute is sticky and deliberately does NOT alter the volume, so
## un-muting returns to whatever the player had set.
var _volume: float = 1.0        # 0.0-1.0, default 100%
var _muted: bool = false


func volume() -> float:
	return _volume


func is_muted() -> bool:
	return _muted


## Put back a saved level. The set applies it through apply_volume() afterwards,
## the same as any other change.
func restore(level: float, muted: bool) -> void:
	_volume = clampf(level, 0.0, 1.0)
	_muted = muted

func setup(tv: RetroTV) -> void:
	_tv = tv


## Cycle the speaker switch: stereo -> the left channel from both speakers -> the
## right from both. Called by the front-panel key and by the remote.
func set_mode(mode: int) -> void:
	_tv.audio_mode = clampi(mode, 0, 2)
	apply_channel_mode()
	update_mode_button()
	_tv.show_osd_timed(RetroTV.AUDIO_MODE_NAMES[_tv.audio_mode], 2.0)
	NetworkManager.report_event(NetEvents.EV_TV_AUDIO_MODE,
		{"tv": _tv, "mode": _tv.audio_mode})


func on_mode_toggle() -> void:
	set_mode((_tv.audio_mode + 1) % 3)


## The routing itself belongs to whoever owns the samples, so it is handed to the
## connected deck rather than done here — the set has no emitter of its own.
func apply_channel_mode() -> void:
	# Every connected host, not just the one showing: the speaker switch is a
	# property of the SET, so an input switched to later has to already be routed
	# the way the switch says rather than reverting to stereo for one press.
	for system in _tv.panel()._connected_systems:
		if is_instance_valid(system) \
				and system.has_method("set_audio_channel_mode"):
			system.set_audio_channel_mode(_tv.audio_mode)
	# The tuner is the one source the set does own an emitter for, so it takes the
	# same routing directly rather than being asked to do it.
	if _tv.tuner():
		_tv.tuner().set_channel_mode(_tv.audio_mode)


## Stereo gets the two-speaker symbol; a mono mode gets a single speaker leaning
## to the channel it is carrying, matching how the 3D key shows its eye.
func update_mode_button() -> void:
	match _tv.audio_mode:
		0:
			TransportGlyphs.set_glyph(_tv, "AudioModeButton", "audio_stereo",
				TransportGlyphs.TV_SIZE)
		1:
			TransportGlyphs.set_glyph(_tv, "AudioModeButton", "audio_mono",
				TransportGlyphs.TV_SIZE, -1.0)
		2:
			TransportGlyphs.set_glyph(_tv, "AudioModeButton", "audio_mono",
				TransportGlyphs.TV_SIZE, 1.0)
	if _tv.audio_mode_btn():
		_tv.audio_mode_btn().set_color(Color(0.35, 0.55, 0.9) if _tv.audio_mode == 0
			else Color(0.9, 0.65, 0.25))


## What the set's own amplifier is passing: silence while off or muted.
func _effective_volume() -> float:
	return 0.0 if (not _tv.is_on() or _muted) else _volume


## …and what reaches one input, which is nothing at all unless that input is the
## one SOURCE has selected.
##
## The set has five sound sources and only ever plays one. Deselecting an input
## used to silence only its PICTURE (set_screen_enabled) and leave its sound
## running, so switching a console to the tuner played the channel over the top
## of the game you had just been playing.
func volume_for(source: int) -> float:
	return _effective_volume() if _tv.current_source == source else 0.0


## Push the current volume to every connected device and to the built-in tuner, so
## one knob governs whichever input is showing and the other four are quiet.
func apply_volume() -> void:
	# Every slot, not just the composite ones: a console reached through an RF switch
	# is on Source.RF and has to be silenced with the rest when it is not showing.
	for i in _tv.panel()._connected_systems.size():
		var system: Node3D = _tv.panel()._connected_systems[i]
		if is_instance_valid(system):
			system.set_audio_volume(volume_for(i))
	if _tv.tuner():
		_tv.tuner().set_volume(volume_for(RetroTV.Source.TV))


## A volume key clears mute (like a real set) so the change is audible.
func _clear_mute_silently() -> void:
	if _muted:
		_muted = false
		_tv.hide_osd()


func on_volume_down() -> void:
	_clear_mute_silently()
	_volume = maxf(0.0, _volume - 0.1)
	if _tv.is_on():
		_tv.osd().show_volume()
	if _tv.is_on():
		apply_volume()
	NetworkManager.report_event(NetEvents.EV_TV_VOL_DOWN, {"tv": _tv})


func on_volume_up() -> void:
	_clear_mute_silently()
	_volume = minf(1.0, _volume + 0.1)
	if _tv.is_on():
		_tv.osd().show_volume()
	if _tv.is_on():
		apply_volume()
	NetworkManager.report_event(NetEvents.EV_TV_VOL_UP, {"tv": _tv})


## Toggle mute: silence (or restore) the connected device and show/clear a sticky
## "MUTE" OSD in the same corner "POWER" uses. No-op audibility change while off.
## Red while muted, matching the remote's own mute tint. Driven from here rather
## than the button so the remote's mute lands on the same cap.
func update_mute_button() -> void:
	if _tv.mute_btn():
		_tv.mute_btn().set_color(Color(1.0, 0.35, 0.35) if _muted else Color(0.35, 0.35, 0.35))


func on_mute_toggle() -> void:
	_muted = not _muted
	update_mute_button()
	update_mode_button()
	apply_volume()
	if _muted:
		_tv.show_osd("MUTE")
	else:
		_tv.hide_osd()
	NetworkManager.report_event(NetEvents.EV_TV_MUTE, {"tv": _tv})

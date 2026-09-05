## VCRPlayer — pickable VCR that plays a video from an inserted VCRTape and
## renders it onto a connected TV, reusing the same cable/plug/TV wiring as
## RetroSystem. Playback is driven by the libVLC-backed VlcPlayer GDExtension
## (the same engine as DVDPlayer): video is decoded to a texture and audio to a
## PCM ring buffer drained into a spatialised AudioStreamPlayer3D at the TV.
## Using libVLC gives broad codec support (incl. HEVC/x265) with one shared
## video backend.
class_name VCRPlayer
extends MediaTransport


## Fast-forward / rewind scan rate: seconds of video traversed per real second
## while scanning (e.g. 8.0 ≈ 8× speed).
@export var scan_speed: float = 8.0

## Human-readable label shown above the unit.
@export var vcr_label: String = "VCR"

## When true, the video is rendered through the VHS/VCR effect shader.
@export var vcr_effect_enabled: bool = true

const VCR_SHADER := preload("res://Shaders/vcr_effect.gdshader")

# Tunable VHS/VCR shader uniforms (vcr_effect.gdshader). Adjustable from the VCR
# options panel's "VHS Effect" tab; applied to the screen ShaderMaterial. Defaults
# mirror the shader's own defaults. (CRT display-stage uniforms are owned by the
# connected TV and tuned from the TV panel, so they're not duplicated here.)
var _vcr_params := {
	"effect_amount": 1.0,
	"aberration": 0.0025,
	"scanline_strength": 0.22,
	"noise_strength": 0.10,
	"wobble_strength": 0.0016,
	"tracking_strength": 0.02,
	"desaturation": 0.15,
	"brightness": 1.12,
	"roll_amount": 0.008,
	"roll_speed": 0.5,
	"banded_noise_opacity": 0.15,
	"noise_speed": 8.0,
	"vhs_contrast": 1.12,
	"pixelate": true,
}


# Runtime state
var video_path: String = ""
var is_playing: bool = false
# Scan direction: 0 = normal, +1 = fast-forward scan, -1 = rewind scan.
# While scanning the player keeps PLAYING (so it presents frames) but we jump
# the position ahead/back in throttled steps so the picture visibly races, with
# audio muted (real-VCR feel).
var _scan_dir: int = 0
var _scan_accum: float = 0.0            # time since the last scan seek
# How often (seconds) to seek while scanning. Seeking every frame overloads the
# decoder; ~12 seeks/sec still reads as a smooth fast-scan.
const SCAN_SEEK_INTERVAL := 0.08


# Front-loading tape bay (insert ride, eject, grab hand-off, collision) — all owned
# by the shared MediaSlot; see media_slot.gd. The tape rides in 10 cm and lies flat
# (the mesh is authored standing, so it's rotated -90° about the slot's X axis).
const SLOT_INSET := 0.10        # how far inside the VCR a loaded tape rides
var _slot: MediaSlot = null

@onready var _tape_slot: XRToolsSnapZone = $TapeSlot
@onready var _play_button: VRButton = $PlayButton
@onready var _pause_button: VRButton = $PauseButton
@onready var _stop_button: VRButton = $StopButton
@onready var _rewind_button: VRButton = $RewindButton
@onready var _ff_button: VRButton = $FastForwardButton
@onready var _eject_button: VRButton = $EjectButton
@onready var _name_label: Label3D = $NameLabel
@onready var _options_panel: VCROptionsPanel = $VCROptionsPanel
@onready var _clock: VCRClock = $VCRClock

# Last known total duration (seconds), remembered so the readout keeps showing
# the tape length when paused/stopped. -1 = unknown.
var _last_total: float = -1.0


func _ready() -> void:
	super._ready()
	add_to_group("vcr_player")
	# Silkscreen round the A/V row. A deck is a source, so this one reads AV OUT.
	AvLegend.attach(self, [$VideoOut, $AudioLOut, $AudioROut])
	_float_lock = FloatLock.attach(self, ignore_gravity)
	TransportGlyphs.label_buttons(self, {
		"PlayButton": "play", "PauseButton": "pause", "StopButton": "stop",
		"RewindButton": "rew", "FastForwardButton": "ff", "EjectButton": "eject",
	}, TransportGlyphs.DECK_SIZE)
	_slot = MediaSlot.new()
	_slot.host = self
	_slot.slot = _tape_slot
	_slot.insert_depth = SLOT_INSET
	_slot.media_local_basis = Basis(Vector3(1, 0, 0), -PI / 2.0)   # lay the tape flat
	add_child(_slot)
	_slot.inserted.connect(_on_media_inserted)
	_slot.removed.connect(_on_media_removed)
	_play_button.button_pressed.connect(_on_play_pressed)
	_pause_button.button_pressed.connect(_on_pause_pressed)
	_stop_button.button_pressed.connect(_on_stop_pressed)
	_rewind_button.button_pressed.connect(_on_rewind_pressed)
	_ff_button.button_pressed.connect(_on_ff_pressed)
	_eject_button.button_pressed.connect(_on_eject_pressed)
	_play_button.set_color(Color(0.0, 0.9, 0.0))     # green
	_pause_button.set_color(Color(0.9, 0.8, 0.0))     # amber
	_stop_button.set_color(Color(0.9, 0.1, 0.1))      # red
	_rewind_button.set_color(Color(0.1, 0.4, 0.9))    # blue
	_ff_button.set_color(Color(0.1, 0.4, 0.9))        # blue
	_eject_button.set_color(Color(0.8, 0.8, 0.85))    # light grey

	if ClassDB.class_exists("VlcPlayer"):
		_vlc = ClassDB.instantiate("VlcPlayer")
		_vlc.finished.connect(_on_video_finished)
	else:
		push_error("VCRPlayer: VlcPlayer extension not loaded — video playback unavailable")

	_setup_audio()
	_update_name_label()


func _update_name_label() -> void:
	if _name_label:
		_name_label.text = vcr_label.to_upper()


func _process(delta: float) -> void:
	if _vlc:
		# Pump the latest decoded frame + PCM every frame.
		_vlc.update_frame()
		_pump_audio()
		# Emanate the sound from the connected TV so it's spatialised there, aimed
		# the way its picture points -- a set heard from behind should be muted by
		# its own cabinet.
		if _emitter and is_instance_valid(connected_tv):
			_emit_through(connected_tv)
		elif _emitter:
			_emitter.clear_speaker_positions()
			_emitter.clear_emit_position()
			_emitter.clear_emit_direction()
	_update_scan(delta)
	if _clock == null:
		return
	if is_playing:
		_last_total = _vlc_length_sec()
		_clock.set_times(_vlc_time_sec(), _last_total)
	elif not video_path.is_empty():
		# Tape inserted but stopped/paused-at-start — show 0 against the last
		# known length (unknown until first played).
		_clock.set_times(0.0, _last_total)
	else:
		_last_total = -1.0
		_clock.set_blank()


## Drain decoded PCM from VlcPlayer into the generator (fills only what's free).
##
## Stops dead while paused. Pausing the source does not stop the sound on its
## own: libVLC has handed over a second or more of PCM by then, and it keeps
## playing out of the ring until the drain stops as well.
func _pump_audio() -> void:
	if _emitter == null or _paused:
		return
	# frames_wanted, not "all free space": queue depth is latency.
	var want := _emitter.frames_wanted()
	if want <= 0:
		return
	var frames: PackedVector2Array = _vlc.read_audio(want)
	if frames.size() > 0:
		_emitter.push_stereo(frames)


# --- Position helpers (VlcPlayer reports ms / 0..1; the VCR works in seconds) ---

func _vlc_time_sec() -> float:
	return (float(_vlc.get_time()) / 1000.0) if _vlc else 0.0


func _vlc_length_sec() -> float:
	if _vlc == null:
		return -1.0
	var ms: int = _vlc.get_length()
	return (float(ms) / 1000.0) if ms > 0 else -1.0


## Seek to an absolute time in seconds (needs a known length — libVLC seeks by
## fraction). No-op when the length isn't known yet.
func _vlc_seek_sec(sec: float) -> void:
	if _vlc == null:
		return
	var length := _vlc_length_sec()
	if length > 0.0:
		_vlc.set_position(clampf(sec / length, 0.0, 1.0))


## While scanning, jump the (still-playing) player's position forward/back in
## throttled steps so frames visibly race by at scan_speed. Hitting either end
## stops the scan and holds there.
func _update_scan(delta: float) -> void:
	if _scan_dir == 0 or not is_playing:
		return
	_scan_accum += delta
	if _scan_accum < SCAN_SEEK_INTERVAL:
		return
	var length := _vlc_length_sec()
	var pos := _vlc_time_sec() + _scan_accum * scan_speed * float(_scan_dir)
	_scan_accum = 0.0
	if pos <= 0.0:
		_vlc_seek_sec(0.0)
		_end_scan_hold()   # reached the start; hold here
	elif length > 0.0 and pos >= length:
		_vlc_seek_sec(length)
		_end_scan_hold()   # reached the end; hold here
	else:
		_vlc_seek_sec(pos)


## Stop an in-progress scan and freeze on the current frame (used at either end).
func _end_scan_hold() -> void:
	_scan_dir = 0
	if _vlc:
		_vlc.set_paused(true)
	_paused = true
	_apply_volume()
	_osd("PAUSE", true)


## Toggle the floating VCR settings panel (mirrors RetroSystem.toggle_options_ui).
## Called by SpawnMenuController when the menu button is pressed while pointing
## at this VCR.
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel == null:
		return
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)


# --- Tape slot callbacks ---

## MediaSlot accepted a tape (the insert ride has begun). Cache its path and report
## the insert; playback is user/host-started, never auto-played on insert.
func _on_media_inserted(tape: Node3D) -> void:
	if tape.has_method("get_video_path"):
		video_path = tape.get_video_path()
	NetworkManager.report_event(NetEvents.EV_TAPE_INSERT,
		{"vcr": self, "tape": tape})


## MediaSlot reports the tape left (ejected, or pulled straight out). Stop playback
## and clear state.
func _on_media_removed() -> void:
	stop()
	video_path = ""
	NetworkManager.report_event(NetEvents.EV_TAPE_REMOVE, {"vcr": self})


func _on_eject_pressed() -> void:
	_slot.eject()


## Client-in-session: transport intents route to the host (authoritative
## transport). The host executes and its state broadcast drives every peer's
## LOCAL playback (M5) — video files arrive via NetFileTransfer.
## Returns true when the command was forwarded instead of handled locally.
func _net_forward_cmd(cmd: String) -> bool:
	if NetworkManager.is_client() and not NetworkManager.is_event_applying():
		NetworkManager.report_event(NetEvents.EV_VCR_CMD, {"vcr": self, "cmd": cmd})
		return true
	return false


# ── Multiplayer playback sync (M5) ────────────────────────────────────────────
# Host is transport authority; every peer plays its own local copy of the video.
# Sync is drift-corrected, not lockstep: the host broadcasts
# (playing, paused, position) on transport changes plus a heartbeat, and a peer
# seeks whenever its position drifts past NET_DRIFT_TOLERANCE.

const NET_DRIFT_TOLERANCE := 0.75   # seconds off host before a corrective seek

## Host: push the current transport state to peers (no-op offline/client).
func _net_push_state() -> void:
	if NetworkManager.is_host() and not NetworkManager.is_event_applying():
		NetworkManager.report_media_state(self)


## Current transport state for the sync layer.
func net_get_state() -> Dictionary:
	return {
		"playing": is_playing,
		"paused": is_playing and _paused,
		"pos": _vlc_time_sec() if is_playing else 0.0,
	}


## Client: mirror the host's transport state on the LOCAL player.
func net_apply_state(state: Dictionary) -> void:
	var playing := bool(state.get("playing", false))
	var paused := bool(state.get("paused", false))
	var pos := float(state.get("pos", 0.0))
	if not playing:
		if is_playing:
			stop()
		return
	# Ensure we have a local file — the tape's path is remapped/downloaded by
	# object_sync; refresh in case the transfer landed after insertion.
	var tape := _slot.get_media()
	if video_path.is_empty() and tape and tape.has_method("get_video_path"):
		video_path = tape.get_video_path()
	if not is_playing:
		if video_path.is_empty() or connected_tv == null:
			_osd("WAITING FOR TAPE…", true)
			return
		play()
		if is_playing and pos > NET_DRIFT_TOLERANCE:
			_vlc_seek_sec(pos)
	if not is_playing:
		return
	if _vlc:
		_vlc.set_paused(paused)
	_paused = paused
	if not paused and absf(_vlc_time_sec() - pos) > NET_DRIFT_TOLERANCE:
		_vlc_seek_sec(pos)


# --- Playback controls ---

# Remote-control entry points (TVRemote): identical to pressing the unit's
# front-panel buttons, including FF/REW scan toggling and OSD messages.

func remote_play() -> void:
	_on_play_pressed()


func remote_pause() -> void:
	_on_pause_pressed()


func remote_stop() -> void:
	_on_stop_pressed()


func remote_ff() -> void:
	_on_ff_pressed()


func remote_rewind() -> void:
	_on_rewind_pressed()


func remote_eject() -> void:
	_slot.eject()


## True when a tape is loaded (the remote greys its Eject cell otherwise).
func has_media() -> bool:
	return _slot.has_media()


func _on_play_pressed() -> void:
	if _net_forward_cmd("play"):
		return
	if is_playing and (_scan_dir != 0 or _paused):
		# Leaving a scan or resuming from pause both mean "back to normal play".
		_set_scan(0)
		if _vlc:
			_vlc.set_paused(false)
		_paused = false
		_osd("PLAY", false)
		_net_push_state()
		return
	play()


func _on_pause_pressed() -> void:
	if _net_forward_cmd("pause"):
		return
	if is_playing:
		_scan_dir = 0
		if _vlc:
			_vlc.set_paused(true)
		_paused = true
		_apply_volume()   # undo any scan mute
		_osd("PAUSE", true)
		_net_push_state()


func _on_stop_pressed() -> void:
	if _net_forward_cmd("stop"):
		return
	stop()


## Rewind button: toggle reverse scan (press again, or Play/Pause, to exit).
func _on_rewind_pressed() -> void:
	if _net_forward_cmd("rew"):
		return
	if not is_playing:
		return
	if _scan_dir == -1:
		_set_scan(0)
		_osd("PLAY", false)
	else:
		_set_scan(-1)
		_osd("<< REW", true)


## Fast-forward button: toggle forward scan (press again, or Play/Pause, to exit).
func _on_ff_pressed() -> void:
	if _net_forward_cmd("ff"):
		return
	if not is_playing:
		return
	if _scan_dir == 1:
		_set_scan(0)
		_osd("PLAY", false)
	else:
		_set_scan(1)
		_osd("FF >>", true)


## Show an on-screen message on the connected TV (sticky, or auto-hiding after 3s).
func _osd(text: String, sticky: bool) -> void:
	if connected_tv == null:
		return
	if sticky:
		connected_tv.show_osd(text)
	else:
		connected_tv.show_osd_timed(text, 3.0)


## Enter (dir = ±1) or leave (dir = 0) a fast-forward/rewind scan.
## The player keeps playing during a scan (so frames present) but is muted;
## leaving restores normal-speed playback and the prior volume.
func _set_scan(dir: int) -> void:
	_scan_dir = dir
	_scan_accum = 0.0
	if _vlc:
		_vlc.set_paused(false)
	_paused = false
	if _emitter:
		_emitter.set_volume(0.0 if dir != 0 else _volume_linear)
	_net_push_state()


func _apply_volume() -> void:
	if _emitter:
		_emitter.set_volume(_volume_linear)


func play() -> void:
	if connected_tv == null:
		push_error("VCRPlayer: Cannot play - no TV connected")
		return
	if video_path.is_empty():
		push_error("VCRPlayer: Cannot play - no tape inserted")
		return
	if _vlc == null:
		push_error("VCRPlayer: VlcPlayer unavailable (extension not loaded)")
		return
	if not _vlc.open(video_path, false):
		push_error("VCRPlayer: VlcPlayer.open failed for ", video_path)
		return
	_vlc.play()
	# Full internal gain — level is controlled by the Godot 3D player (TV knob).
	_vlc.set_volume(100)
	is_playing = true
	_paused = false
	_scan_dir = 0
	if _emitter:
		_emitter.flush()
		_apply_volume()
	_osd("PLAY", false)
	_net_push_state()


func stop() -> void:
	if not is_playing:
		return
	_scan_dir = 0
	if _vlc:
		_vlc.stop()
	is_playing = false
	_paused = false
	if _emitter:
		_emitter.flush()
	if connected_tv:
		connected_tv.hide_osd()
	_net_push_state()


# --- TV connection contract ---
#
# on_tv_connected/on_tv_disconnected are gone: they were the captive lead's, called
# by the set when a CablePlug carrying a back-reference to its host arrived. A
# composite cable's plugs belong to no device, so the deck works out its own
# connection instead — see on_av_topology_changed. A console still uses the old
# path, which is why the set still has it.


## Set the audio volume (0.0 = silent, 1.0 = 100%). Called by the TV volume buttons.
func set_audio_volume(volume: float) -> void:
	_volume_linear = clampf(volume, 0.0, 1.0)
	# Don't fight an active scan mute; it restores on scan exit.
	if _scan_dir == 0:
		_apply_volume()


## Part of the TV contract: the set's mono switch, applied to the tape's own
## sound. See SpatialAudioEmitter.set_channel_mode.
func set_audio_channel_mode(mode: int) -> void:
	if _emitter:
		_emitter.set_channel_mode(mode)


# --- What the set reads ---
#
# The deck no longer paints anything. It answers two questions — is there a
# picture, and what should it be put through — and RetroTV builds the material.
# set_screen_enabled, _screen_allowed, _may_paint, _bind_screen_to_tv,
# _blank_screen, _make_screen_material and _material_matches_effect all existed to
# keep this deck's painting in step with a set that was painting too. There is one
# painter now.


## The tape's live frame, or null when there is nothing to show: stopped, or the
## picture cord is not in the set's video socket. A different object after a
## resolution change, so the set re-reads it per frame.
func get_video_texture() -> Texture2D:
	if _vlc == null or not is_playing or not _feed_video:
		return null
	return _vlc.get_texture()


## The shader the set should put this deck's picture through, and the parameters
## for it. Empty means "no stage of my own" — the set uses its plain path, which is
## what the VHS effect being switched off asks for.
##
## The set owns the material; this only says what to run in it. That is the whole
## of what the deck used to build, install and keep in step by hand.
func get_video_stage(_tv: Node) -> Dictionary:
	if not vcr_effect_enabled:
		return {}
	return {"shader": VCR_SHADER, "params": _vcr_params}


## Toggle the VHS effect at runtime. The set notices the stage changed and rebuilds.
func set_vcr_effect_enabled(on: bool) -> void:
	vcr_effect_enabled = on


## Set one VHS uniform, remembering it. Called by VCROptionsPanel; the set pushes
## the stored values onto the material it owns.
func set_vcr_param(pname: String, value: Variant) -> void:
	if _vcr_params.has(pname):
		_vcr_params[pname] = value


## Current VHS uniform values, for the options panel to populate its controls.
func get_vcr_params() -> Dictionary:
	return _vcr_params.duplicate()


func _on_video_finished() -> void:
	# Leave the last frame; mark as not playing so Play restarts from the top.
	is_playing = false
	_paused = false
	if _emitter:
		_emitter.flush()


# --- A/V out ---
#
# The deck has three sockets and no lead of its own. A composite cable is spawned
# and plugged in, and what plays depends entirely on which sockets its cords reach:
# picture only when a cord joins this VideoOut to the set's video in, the left
# channel only when one joins AudioLOut to an audio in — and if that one lands in
# the set's RIGHT socket, the left channel comes out of the right-hand speaker.
# CompositeCable works out the pairs; this only reads them.


# --- Save/load restore (mirrors RetroSystem) ---

func get_snapped_tape() -> Node3D:
	return _slot.get_media()


## Seat a tape programmatically (event/save restore) — no ride, bypasses the filter.
func restore_tape(tape: Node3D) -> void:
	_slot.restore(tape)


## The counterpart to restore_tape, for a remote peer taking the tape out.
##
## Releases the snap zone rather than running the local eject ride: the tape is
## already gone on the peer that moved it, and object_sync positions it here.
## Which child holds the tape stays this deck's business.
func net_release_tape() -> void:
	_tape_slot.drop_object()

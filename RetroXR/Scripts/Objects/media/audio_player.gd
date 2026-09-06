## RetroAudioPlayer — shared base for the pickable CD and cassette players. Plays
## an inserted audio album (a folder of tracks, or a single audio file) through
## the libVLC-backed VlcPlayer GDExtension — the same engine as the VCR/DVD, but
## audio-only and self-contained: the sound emanates from the unit's own
## spatialised AudioStreamPlayer3D, so no TV or cable is needed.
##
## Subclasses (CDPlayer / CassettePlayer) provide the scene + button set. The CD
## has Prev/Next track buttons (and the remote shows them); the cassette is a
## linear tape (play/pause/stop/ff/rew only, tracks auto-advance, no skip).
##
## Transport is host-authoritative in a netplay session (mirrors VCR/DVD): a
## client's button/remote intent is forwarded to the host, which executes it and
## broadcasts the transport state; every peer plays its own local copy of the
## album (verify-by-name — albums are never transferred; see NetObjectSync).
class_name RetroAudioPlayer
extends XRToolsPickable

## Human-readable label shown above the unit.
@export var player_label: String = "AUDIO"

## Fast-forward / rewind scan rate: seconds of audio traversed per real second.
@export var scan_speed: float = 8.0

# The snap-zone group the media item must belong to (set by subclass _ready).
@warning_ignore("unused_private_class_variable")
var _media_group: String = ""

# Runtime state
var album_path: String = ""
var is_playing: bool = false
var _paused: bool = false
var _tracks: PackedStringArray = PackedStringArray()
var _track_idx: int = 0

# FF/REW scan: 0 = normal, +1 = forward, -1 = reverse. The player keeps playing
# (so it presents audio position) but we jump the position in throttled steps and
# mute, exactly like the VCR's video scan.
var _scan_dir: int = 0
var _scan_accum: float = 0.0
const SCAN_SEEK_INTERVAL := 0.08
## If Prev is pressed past this point in a track, it restarts the track instead
## of skipping to the previous one (standard CD behaviour).
const PREV_RESTART_SEC := 3.0

var _vlc: Object = null                 # VlcPlayer (GDExtension)
var _emitter: SpatialAudioEmitter = null
var _volume_linear: float = 1.0

var _snapped_media: Node3D = null

@warning_ignore("unused_private_class_variable")
@onready var _media_slot: XRToolsSnapZone = $MediaSlot
@onready var _name_label: Label3D = $NameLabel
@onready var _play_button: VRButton = $PlayButton
@onready var _pause_button: VRButton = $PauseButton
@onready var _stop_button: VRButton = $StopButton
@onready var _rewind_button: VRButton = get_node_or_null("RewindButton")
@onready var _ff_button: VRButton = get_node_or_null("FastForwardButton")
@onready var _prev_button: VRButton = get_node_or_null("PrevButton")
@onready var _next_button: VRButton = get_node_or_null("NextButton")


func _ready() -> void:
	super._ready()
	add_to_group("audio_player")
	_float_lock = FloatLock.attach(self, ignore_gravity)
	# Physical media handling (how the disc/tape loads, ejects, rides, and collides)
	# is provided by the subclass: the cassette front-loads through a MediaSlot like
	# the VCR; the CD drops into a MediaTray (flip-up lid) like a PlayStation. Both
	# call _media_loaded/_media_unloaded for the transport-side state.
	_setup_loader()
	_play_button.button_pressed.connect(_on_play_pressed)
	_pause_button.button_pressed.connect(_on_pause_pressed)
	_stop_button.button_pressed.connect(_on_stop_pressed)
	_play_button.set_color(Color(0.0, 0.9, 0.0))     # green
	_pause_button.set_color(Color(0.9, 0.8, 0.0))     # amber
	_stop_button.set_color(Color(0.9, 0.1, 0.1))      # red
	# Scan is optional hardware: a turntable has no FF/REW at all — you move the
	# needle instead. Same shape as prev/next below.
	if _rewind_button:
		_rewind_button.button_pressed.connect(_on_rewind_pressed)
		_rewind_button.set_color(Color(0.1, 0.4, 0.9))    # blue
	if _ff_button:
		_ff_button.button_pressed.connect(_on_ff_pressed)
		_ff_button.set_color(Color(0.1, 0.4, 0.9))        # blue
	if _prev_button:
		_prev_button.button_pressed.connect(_on_prev_pressed)
		_prev_button.set_color(Color(0.5, 0.5, 0.55))
	if _next_button:
		_next_button.button_pressed.connect(_on_next_pressed)
		_next_button.set_color(Color(0.5, 0.5, 0.55))

	if ClassDB.class_exists("VlcPlayer"):
		_vlc = ClassDB.instantiate("VlcPlayer")
		_vlc.finished.connect(_on_track_finished)
	else:
		push_error("RetroAudioPlayer: VlcPlayer extension not loaded — audio playback unavailable")

	_setup_audio()
	_update_status()


## Whether this player offers manual track skipping (CD yes, cassette no). Read by
## the TV remote to pick its row set and by the net layer to gate skip commands.
func has_track_skip() -> bool:
	return _prev_button != null


## Whether this deck can scan (FF/REW). A tape and a CD can; a turntable cannot —
## there is no such control on one, you move the needle. Read by the TV remote to
## grey those two cells, and enforced in the handlers so a remote or a stale peer's
## command cannot scan a deck that has no scan.
func has_scan() -> bool:
	return _ff_button != null


## True while playback is paused (used by the TV remote's play/pause cell).
func is_paused() -> bool:
	return _paused


## Build the spatialised audio player fed by VlcPlayer's PCM ring buffer. As a
## child of the (pickable) unit it follows the device around automatically.
func _setup_audio() -> void:
	_emitter = SpatialAudioEmitter.new()
	_emitter.name = "SpatialAudioEmitter"
	_emitter.unit_size = 2.0
	_emitter.max_distance = 12.0
	# A hi-fi has two speakers a little way apart; hearing them separately is
	# most of what makes it feel like an object in the room.
	_emitter.speaker_separation = 0.18
	add_child(_emitter)


func _process(delta: float) -> void:
	if _vlc:
		_vlc.update_frame()
		_pump_audio()
	_update_scan(delta)


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


# --- Position helpers (VlcPlayer reports ms / 0..1) ---

func _vlc_time_sec() -> float:
	return (float(_vlc.get_time()) / 1000.0) if _vlc else 0.0


func _vlc_length_sec() -> float:
	if _vlc == null:
		return -1.0
	var ms: int = _vlc.get_length()
	return (float(ms) / 1000.0) if ms > 0 else -1.0


func _vlc_seek_sec(sec: float) -> void:
	if _vlc == null:
		return
	var length := _vlc_length_sec()
	if length > 0.0:
		_vlc.set_position(clampf(sec / length, 0.0, 1.0))


## While scanning, jump the position forward/back in throttled steps. Hitting
## either end of the current track stops the scan and holds there.
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
		_end_scan_hold()
	elif length > 0.0 and pos >= length:
		_vlc_seek_sec(length)
		_end_scan_hold()
	else:
		_vlc_seek_sec(pos)


func _end_scan_hold() -> void:
	_scan_dir = 0
	if _vlc:
		_vlc.set_paused(true)
	_paused = true
	_apply_volume()
	_update_status()


# --- Media load/unload (called by the subclass's loader) ---

## Install the physical media loader — MediaSlot for the cassette, MediaTray for
## the CD. Every deck supplies its own; there is no default.
func _setup_loader() -> void:
	pass


## Media accepted into the deck (loader owns the physical ride + collision). Reads
## the album, resets tracks, reports the insert. Offline, auto-starts; in a session
## playback is host-authoritative (transport commands / state broadcast) like DVD/VCR.
func _media_loaded(media: Node3D) -> void:
	_snapped_media = media
	if media.has_method("get_album_path"):
		album_path = media.get_album_path()
	_track_idx = 0
	_rebuild_tracks()
	NetworkManager.report_event(NetEvents.Event.EV_AUDIO_INSERT, {"player": self, "media": media})
	if _autoplay_on_load() and not NetworkManager.is_active():
		play()
	_update_status()


## Whether inserting media auto-starts playback offline. The cassette does (it
## front-loads and plays); the CD waits for the lid to close over the disc.
func _autoplay_on_load() -> bool:
	return true


## Media left the deck (ejected / lid opened and taken). Stops and clears state.
func _media_unloaded() -> void:
	_snapped_media = null
	stop()
	album_path = ""
	_tracks = PackedStringArray()
	NetworkManager.report_event(NetEvents.Event.EV_AUDIO_REMOVE, {"player": self})
	_update_status()


func _rebuild_tracks() -> void:
	_tracks = RomLibrary.music_tracks(album_path)
	_track_idx = clampi(_track_idx, 0, maxi(0, _tracks.size() - 1))


func get_snapped_media() -> Node3D:
	return _snapped_media


## Seat a media item programmatically (event / save restore). Each deck seats it
## through its own loader (MediaSlot / MediaTray).
func restore_media(_media: Node3D) -> void:
	pass


## Unseat whatever is loaded, through this deck's own loader. The net layer used to
## do this by reaching for get_node("MediaSlot").drop_object(), which is a no-op for
## any TRAY deck: MediaTray.accept already dropped the zone and reparented the media
## to its own holder, so the zone holds nothing to drop. Each deck answers for
## itself instead.
func remove_media() -> void:
	pass


## The type string this deck saves under. A virtual rather than a chain of `is`
## tests at the call site, so a new deck that forgets to override is a missing
## method rather than something silently serialised as another deck.
func deck_save_type() -> String:
	return ""


# --- Transport (front-panel buttons + remote entry points) ---

func remote_play() -> void: _on_play_pressed()
func remote_pause() -> void: _on_pause_pressed()
func remote_stop() -> void: _on_stop_pressed()
func remote_ff() -> void: _on_ff_pressed()
func remote_rewind() -> void: _on_rewind_pressed()
func remote_next() -> void: _on_next_pressed()
func remote_prev() -> void: _on_prev_pressed()


## Play a specific track. The public entry point for the net layer, which must not
## reach into the private _goto_track (that one does no command forwarding, and is
## also the tail of _on_next_pressed). A caller that could be a client forwards the
## intent itself before calling this.
func remote_goto_track(idx: int) -> void:
	_goto_track(idx)


func _on_play_pressed() -> void:
	if _net_forward_cmd("play"):
		return
	if is_playing and (_scan_dir != 0 or _paused):
		_scan_dir = 0
		if _vlc:
			_vlc.set_paused(false)
		_paused = false
		_apply_volume()
		_update_status()
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
		_apply_volume()
		_update_status()
		_net_push_state()


func _on_stop_pressed() -> void:
	if _net_forward_cmd("stop"):
		return
	stop()


func _on_rewind_pressed() -> void:
	if not has_scan():
		return
	if _net_forward_cmd("rew"):
		return
	if not is_playing:
		return
	_scan_dir = 0 if _scan_dir == -1 else -1
	_apply_scan_mute()
	_update_status()
	_net_push_state()


func _on_ff_pressed() -> void:
	if not has_scan():
		return
	if _net_forward_cmd("ff"):
		return
	if not is_playing:
		return
	_scan_dir = 0 if _scan_dir == 1 else 1
	_apply_scan_mute()
	_update_status()
	_net_push_state()


func _on_next_pressed() -> void:
	if not has_track_skip():
		return
	if _net_forward_cmd("next"):
		return
	_goto_track(_track_idx + 1)


func _on_prev_pressed() -> void:
	if not has_track_skip():
		return
	if _net_forward_cmd("prev"):
		return
	# Past the restart threshold, "previous" restarts the current track.
	if is_playing and _vlc_time_sec() > PREV_RESTART_SEC:
		_vlc_seek_sec(0.0)
		_net_push_state()
		return
	_goto_track(_track_idx - 1)


## Load and play a specific track index (clamped). No-op past the ends.
func _goto_track(idx: int) -> void:
	if _tracks.is_empty():
		return
	if idx < 0 or idx >= _tracks.size():
		return
	_track_idx = idx
	_scan_dir = 0
	play()


func play() -> void:
	if _vlc == null:
		return
	if _tracks.is_empty():
		_rebuild_tracks()
	if _tracks.is_empty():
		push_error("RetroAudioPlayer: cannot play — no album inserted")
		return
	_track_idx = clampi(_track_idx, 0, _tracks.size() - 1)
	if not _vlc.open(_tracks[_track_idx], false):
		push_error("RetroAudioPlayer: VlcPlayer.open failed for ", _tracks[_track_idx])
		return
	_vlc.play()
	_vlc.set_volume(100)
	is_playing = true
	_paused = false
	_scan_dir = 0
	if _emitter:
		_emitter.flush()
		_apply_volume()
	_update_status()
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
	_update_status()
	_net_push_state()


## A track reached its end. Auto-advance to the next one (both CD and cassette
## play through an album); stop at the end of the last track.
func _on_track_finished() -> void:
	if NetworkManager.is_client():
		return   # the host drives advancement; clients follow its state
	if _track_idx + 1 < _tracks.size():
		_track_idx += 1
		play()
	else:
		is_playing = false
		_paused = false
		if _emitter:
			_emitter.flush()
		_update_status()
		_net_push_state()


# --- Volume / status ---

func _apply_volume() -> void:
	if _emitter:
		_emitter.set_volume(0.0 if _scan_dir != 0 else _volume_linear)


func _apply_scan_mute() -> void:
	if _vlc:
		_vlc.set_paused(false)
	_paused = false
	_scan_accum = 0.0
	_apply_volume()


func set_audio_volume(volume: float) -> void:
	_volume_linear = clampf(volume, 0.0, 1.0)
	if _scan_dir == 0:
		_apply_volume()


## A NAMEPLATE, not a readout. This used to append the track number and a transport
## caret, which made a piece of hi-fi wear a caption describing itself — and none of
## it was information the deck was not already giving: the tape rides in or out, the
## disc spins or it does not, a record's needle is down or parked. The label is still
## driven from here rather than left to the scene so that a deck renamed at runtime,
## and the download status below, both still land somewhere.
func _update_status() -> void:
	if _name_label:
		_name_label.text = player_label.to_upper()


# ── Multiplayer sync ──────────────────────────────────────────────────────────
# Host is transport authority; every peer plays its own local copy of the album.
# Drift-corrected, not lockstep: the host broadcasts (playing, paused, track,
# pos) on transport changes plus a heartbeat, and a peer switches track / seeks
# when it diverges.

const NET_DRIFT_TOLERANCE := 0.75   # seconds off host before a corrective seek


## Client-in-session: route a transport intent to the host instead of acting
## locally. Returns true when forwarded (caller must then return).
func _net_forward_cmd(cmd: String) -> bool:
	if NetworkManager.is_client() and not NetworkManager.is_event_applying():
		NetworkManager.report_event(NetEvents.Event.EV_AUDIO_CMD, {"player": self, "cmd": cmd})
		return true
	return false


## Host: broadcast the current transport state for peer drift sync.
func _net_push_state() -> void:
	if NetworkManager.is_host() and not NetworkManager.is_event_applying():
		NetworkManager.report_media_state(self)


## Current transport state for the sync layer. The "track" key is the state-shape
## discriminator the heartbeat uses to route audio states (vs VCR/DVD).
func net_get_state() -> Dictionary:
	return {
		"playing": is_playing,
		"paused": is_playing and _paused,
		"track": _track_idx,
		"pos": _vlc_time_sec() if is_playing else 0.0,
	}


## Client: mirror the host's transport state on the LOCAL player.
func net_apply_state(state: Dictionary) -> void:
	var playing := bool(state.get("playing", false))
	var paused := bool(state.get("paused", false))
	var track := int(state.get("track", 0))
	var pos := float(state.get("pos", 0.0))
	if not playing:
		if is_playing:
			stop()
		return
	# The album path is resolved by object_sync after insertion (verify-by-name);
	# refresh in case it landed after the insert event.
	if _tracks.is_empty():
		if album_path.is_empty() and _snapped_media and _snapped_media.has_method("get_album_path"):
			album_path = _snapped_media.get_album_path()
		_rebuild_tracks()
	if _tracks.is_empty():
		_update_status()
		return
	track = clampi(track, 0, _tracks.size() - 1)
	if not is_playing or _track_idx != track:
		_track_idx = track
		play()
	if not is_playing or _vlc == null:
		return
	if not paused and absf(_vlc_time_sec() - pos) > NET_DRIFT_TOLERANCE:
		_vlc_seek_sec(pos)
	if _vlc:
		_vlc.set_paused(paused)
	_paused = paused
	_apply_volume()
	_update_status()


## Optional download-status hook (albums are verify-by-name, so this is only used
## to surface an "album not found on this peer" state).
func net_set_download_status(status: String) -> void:
	if _name_label:
		if status.is_empty():
			_update_status()
		else:
			_name_label.text = "%s  %s" % [player_label.to_upper(), status]


## Ignore-gravity: the device floats where it is put instead of falling. Restored
## from a save through this flag, which FloatLock reads once at _ready.
var ignore_gravity: bool = false
var _float_lock: FloatLock = null

const OPTIONS_PANEL_SCENE := preload("res://Scenes/UI/audio_options_panel.tscn")
var _options_panel: AudioOptionsPanel = null


## Toggle the floating settings panel. Called by SpawnMenuController when the
## menu button is pressed while pointing at this unit (mirrors RetroMouse).
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel == null:
		_options_panel = OPTIONS_PANEL_SCENE.instantiate()
		add_child(_options_panel)
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)


func get_ignore_gravity() -> bool:
	return _float_lock != null and _float_lock.enabled


func set_ignore_gravity(on: bool) -> void:
	ignore_gravity = on
	if _float_lock != null:
		_float_lock.set_enabled(on)

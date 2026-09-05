## DVDPlayer — a pickable DVD deck that plays a real DVD image (VIDEO_TS/.iso/.img)
## onto a connected TV, with working disc menus + chapter navigation driven by the
## TV remote. Playback is handled by the libVLC-backed VlcPlayer GDExtension, which
## renders the disc's own menus into the picture; the remote forwards D-pad/OK and
## chapter presses into libVLC navigation.
##
## Reuses the same cable/plug/TV wiring as VCRPlayer / RetroSystem.
class_name DVDPlayer
extends MediaTransport

## Human-readable label shown above the unit.
@export var dvd_label: String = "DVD"

## Fast-forward / rewind scan rate: seconds of video traversed per real second.
@export var scan_speed: float = 8.0

# Runtime state
var dvd_path: String = ""
var is_playing: bool = false

# FF/REW scan (only meaningful during title playback, not in a disc menu):
# 0 = normal, +1 = forward, -1 = reverse. Mirrors the VCR's scan.
var _scan_dir: int = 0
var _scan_accum: float = 0.0
const SCAN_SEEK_INTERVAL := 0.08


# Front-loading disc bay (insert ride, eject, grab hand-off, collision) — all owned
# by the shared MediaSlot; see media_slot.gd. Disc rides in 10 cm, lies flat.
const SLOT_INSET := 0.10       # how far inside the player a loaded disc rides
var _slot: MediaSlot = null


# Cached track counts for the remote's audio/subtitle greying (-1 = not yet
# known; libVLC populates the lists a beat after play()). Refreshed on a low-rate
# throttle in _process and after each cycle.
var _n_audio: int = -1
var _n_sub: int = -1
var _track_refresh_accum: float = 0.0

# Multiplayer (Phase 5): the host is the transport + menu authority; every peer
# plays its own local copy of the disc (verify-only by MD5, never transferred —
# same legal stance as ROMs). Sync is drift-corrected on title/chapter/time, not
# lockstep; the disc's menu-VM highlight state is not replicated (both peers boot
# the same root menu, and content transitions resync via title/chapter). See the
# NetObjectSync header.
const NET_DRIFT_TOLERANCE := 1.0   # seconds of content drift before a seek


@onready var _disc_slot: XRToolsSnapZone = $DiscSlot
@onready var _play_button: VRButton = $PlayButton
@onready var _pause_button: VRButton = $PauseButton
@onready var _stop_button: VRButton = $StopButton
@onready var _menu_button: VRButton = $MenuButton
@onready var _prev_button: VRButton = $PrevChapterButton
@onready var _next_button: VRButton = $NextChapterButton
@onready var _rewind_button: VRButton = $RewindButton
@onready var _ff_button: VRButton = $FastForwardButton
@onready var _eject_button: VRButton = $EjectButton
@onready var _name_label: Label3D = $NameLabel
@onready var _options_panel: DVDOptionsPanel = $DVDOptionsPanel

# The box's copy of the remote's menu cluster + track cycling: same ids, same
# enable rules, same actions. Lit colour per id; greyed to COLOR_BTN_OFF whenever
# the remote would grey the matching cell.
const BOX_BTN_COLOR := {
	"up": Color(0.35, 0.45, 0.62), "down": Color(0.35, 0.45, 0.62),
	"left": Color(0.35, 0.45, 0.62), "right": Color(0.35, 0.45, 0.62),
	"ok": Color(0.2, 0.7, 0.95),
	"audio": Color(0.6, 0.35, 0.8), "subtitle": Color(0.85, 0.55, 0.15),
}
const COLOR_BTN_OFF := Color(0.22, 0.22, 0.24)
var _box_buttons: Dictionary = {}      # id -> VRButton
var _box_button_lit: Dictionary = {}   # id -> bool, last colour applied


func _ready() -> void:
	super._ready()
	add_to_group("dvd_player")
	# Silkscreen round the A/V row. A deck is a source, so this one reads AV OUT.
	AvLegend.attach(self, [$VideoOut, $AudioLOut, $AudioROut])
	_float_lock = FloatLock.attach(self, ignore_gravity)
	TransportGlyphs.label_buttons(self, {
		"PlayButton": "play", "PauseButton": "pause", "StopButton": "stop",
		"MenuButton": "menu", "PrevChapterButton": "prev", "NextChapterButton": "next",
		"EjectButton": "eject", "RewindButton": "rew", "FastForwardButton": "ff",
		"LanguageButton": "audio", "SubtitleButton": "subtitle",
		"UpButton": "up", "DownButton": "down", "LeftButton": "left",
		"RightButton": "right", "SelectButton": "ok",
	}, TransportGlyphs.DECK_SIZE)
	_slot = MediaSlot.new()
	_slot.host = self
	_slot.slot = _disc_slot
	_slot.insert_depth = SLOT_INSET
	add_child(_slot)
	_slot.inserted.connect(_on_media_inserted)
	_slot.removed.connect(_on_media_removed)
	_play_button.button_pressed.connect(_on_play_pressed)
	_pause_button.button_pressed.connect(_on_pause_pressed)
	_stop_button.button_pressed.connect(_on_stop_pressed)
	_menu_button.button_pressed.connect(_on_menu_pressed)
	_prev_button.button_pressed.connect(dvd_prev_chapter)
	_next_button.button_pressed.connect(dvd_next_chapter)
	_rewind_button.button_pressed.connect(_on_rewind_pressed)
	_ff_button.button_pressed.connect(_on_ff_pressed)
	_eject_button.button_pressed.connect(_on_eject_pressed)
	_play_button.set_color(Color(0.0, 0.9, 0.0))    # green
	_pause_button.set_color(Color(0.9, 0.8, 0.0))    # amber
	_stop_button.set_color(Color(0.9, 0.1, 0.1))     # red
	_menu_button.set_color(Color(0.2, 0.5, 0.95))    # blue
	_prev_button.set_color(Color(0.5, 0.5, 0.55))
	_next_button.set_color(Color(0.5, 0.5, 0.55))
	_rewind_button.set_color(Color(0.1, 0.4, 0.9))   # blue
	_ff_button.set_color(Color(0.1, 0.4, 0.9))       # blue
	_eject_button.set_color(Color(0.8, 0.8, 0.85))
	_setup_box_buttons()

	if ClassDB.class_exists("VlcPlayer"):
		_vlc = ClassDB.instantiate("VlcPlayer")
		_vlc.finished.connect(_on_disc_finished)
	else:
		push_error("DVDPlayer: VlcPlayer extension not loaded — DVD playback unavailable")

	_setup_audio()
	_update_name_label()


## Wire the D-pad / select / language / subtitle caps on the box. They exist so the
## deck is usable without hunting for the remote; every one of them lands on the
## same method the remote's matching cell calls.
func _setup_box_buttons() -> void:
	_box_buttons = {
		"up": $UpButton, "down": $DownButton,
		"left": $LeftButton, "right": $RightButton,
		"ok": $SelectButton,
		"audio": $LanguageButton, "subtitle": $SubtitleButton,
	}
	for id: String in _box_buttons:
		var button := _box_buttons[id] as VRButton
		button.button_pressed.connect(_on_box_button.bind(id))
	_refresh_box_buttons()


func _on_box_button(id: String) -> void:
	if not _box_button_enabled(id, is_in_menu()):
		return
	match id:
		"up": dvd_menu_up()
		"down": dvd_menu_down()
		"left": dvd_menu_left()
		"right": dvd_menu_right()
		"ok": dvd_ok()
		"audio": dvd_cycle_audio()
		"subtitle": dvd_cycle_subtitle()


## Same rules the remote applies to its equivalent cells: the nav cluster only
## does anything inside a disc menu, the two track buttons only outside one.
func _box_button_enabled(id: String, in_menu: bool) -> bool:
	match id:
		"audio":
			return not in_menu and has_audio_options()
		"subtitle":
			return not in_menu and has_subtitle_options()
	return in_menu


func _refresh_box_buttons() -> void:
	var in_menu := is_in_menu()
	for id: String in _box_buttons:
		var lit := _box_button_enabled(id, in_menu)
		if _box_button_lit.get(id) == lit:
			continue
		_box_button_lit[id] = lit
		var col: Color = BOX_BTN_COLOR[id] if lit else COLOR_BTN_OFF
		(_box_buttons[id] as VRButton).set_color(col)


func _update_name_label() -> void:
	if _name_label:
		_name_label.text = dvd_label.to_upper()


func _process(delta: float) -> void:
	_refresh_box_buttons()
	if _vlc == null:
		return
	# Pump the latest decoded frame into the VLC texture every frame.
	_vlc.update_frame()
	_pump_audio()
	_update_scan(delta)
	# Low-rate refresh of the cached audio/subtitle track counts (the remote reads
	# these to grey its Audio/Subtitle cells).
	if is_playing:
		_track_refresh_accum += delta
		if _track_refresh_accum >= 0.5:
			_track_refresh_accum = 0.0
			_refresh_track_counts()
	# Emanate the sound from the connected TV so it's spatialised there, aimed the
	# way its picture points -- a set heard from behind should be muted by its own
	# cabinet.
	if _emitter and connected_tv != null and is_instance_valid(connected_tv):
		_emit_through(connected_tv)
	elif _emitter:
		_emitter.clear_speaker_positions()
		_emitter.clear_emit_position()
		_emitter.clear_emit_direction()


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


## Toggle the disc menu-control routing is done via the remote; the front Menu
## button just returns to the disc's root menu.
func _on_menu_pressed() -> void:
	dvd_root_menu()


# --- Disc slot callbacks ---

## MediaSlot accepted a disc (the insert ride has begun). Cache its path and report
## the insert; playback is user-started (remote / Play button) or host-driven in a
## session — insert never auto-plays.
func _on_media_inserted(disc: Node3D) -> void:
	if disc.has_method("get_dvd_path"):
		dvd_path = disc.get_dvd_path()
	NetworkManager.report_event(NetEvents.EV_DVD_INSERT, {"dvd": self, "disc": disc})


## MediaSlot reports the disc left (ejected, or pulled straight out). Stop playback
## and clear state.
func _on_media_removed() -> void:
	stop()
	dvd_path = ""
	NetworkManager.report_event(NetEvents.EV_DVD_REMOVE, {"dvd": self})


func _on_eject_pressed() -> void:
	_slot.toggle_eject()


# --- Playback controls ---

func remote_play() -> void: _on_play_pressed()
func remote_pause() -> void: _on_pause_pressed()
func remote_stop() -> void: _on_stop_pressed()
func remote_ff() -> void: _on_ff_pressed()
func remote_rewind() -> void: _on_rewind_pressed()
func remote_eject() -> void: _slot.toggle_eject()
## True when a disc is loaded (the remote greys its Eject cell otherwise).
func has_media() -> bool: return _slot.has_media()


func _on_play_pressed() -> void:
	if _net_forward_cmd("play"):
		return
	if not is_playing:
		play()
	else:
		# Leaving a scan or resuming from pause both mean "back to normal play".
		_set_scan(0)
		_vlc.set_paused(false)
		_paused = false
		_osd("PLAY")
		_net_push_state()


func _on_pause_pressed() -> void:
	if _net_forward_cmd("pause"):
		return
	if is_playing and _vlc:
		_set_scan(0)
		_vlc.set_paused(true)
		_paused = true
		_osd("PAUSE")
		_net_push_state()


## Fast-forward button: toggle forward scan (press again, or Play/Pause, to exit).
## No-op while showing a disc menu (there's nothing to scan through there).
func _on_ff_pressed() -> void:
	if _net_forward_cmd("ff"):
		return
	if not is_playing or is_in_menu():
		return
	if _scan_dir == 1:
		_set_scan(0)
		_osd("PLAY")
	else:
		_set_scan(1)
		_osd("FF >>")


## Rewind button: toggle reverse scan (press again, or Play/Pause, to exit).
func _on_rewind_pressed() -> void:
	if _net_forward_cmd("rew"):
		return
	if not is_playing or is_in_menu():
		return
	if _scan_dir == -1:
		_set_scan(0)
		_osd("PLAY")
	else:
		_set_scan(-1)
		_osd("<< REW")


## Enter (dir = ±1) or leave (dir = 0) a scan. The player keeps playing (frames
## present) but is muted while scanning; leaving restores the prior volume.
func _set_scan(dir: int) -> void:
	_scan_dir = dir
	_scan_accum = 0.0
	if _vlc:
		_vlc.set_paused(false)
	_paused = false
	if _emitter:
		_emitter.set_volume(0.0 if dir != 0 else _volume_linear)


## While scanning, jump the (still-playing) position forward/back in throttled
## steps so frames visibly race by; hold at either end of the title.
func _update_scan(delta: float) -> void:
	if _scan_dir == 0 or not is_playing or _vlc == null:
		return
	if is_in_menu():
		_set_scan(0)
		return
	_scan_accum += delta
	if _scan_accum < SCAN_SEEK_INTERVAL:
		return
	var length := float(_vlc.get_length())
	var pos := float(_vlc.get_time()) + _scan_accum * scan_speed * 1000.0 * float(_scan_dir)
	_scan_accum = 0.0
	if length <= 0.0:
		return
	if pos <= 0.0:
		_vlc.set_position(0.0)
		_end_scan_hold()
	elif pos >= length:
		_vlc.set_position(1.0)
		_end_scan_hold()
	else:
		_vlc.set_position(clampf(pos / length, 0.0, 1.0))


func _end_scan_hold() -> void:
	_set_scan(0)
	if _vlc:
		_vlc.set_paused(true)
	_paused = true
	_osd("PAUSE")
	_net_push_state()


func _on_stop_pressed() -> void:
	if _net_forward_cmd("stop"):
		return
	stop()


func play() -> void:
	if _vlc == null:
		return
	if connected_tv == null:
		push_error("DVDPlayer: cannot play - no TV connected")
		return
	if dvd_path.is_empty():
		push_error("DVDPlayer: cannot play - no disc inserted")
		return
	if not _vlc.open(dvd_path, true):
		push_error("DVDPlayer: VlcPlayer.open failed for ", dvd_path)
		return
	_vlc.play()
	# Full internal gain — level is controlled by the Godot 3D player (TV knob).
	_vlc.set_volume(100)
	is_playing = true
	_paused = false
	_scan_dir = 0
	_n_audio = -1        # unknown until libVLC parses the new disc
	_n_sub = -1
	if _emitter:
		_emitter.flush()
		_emitter.set_volume(_volume_linear)
	_osd("DVD")
	_net_push_state()


func stop() -> void:
	if not is_playing:
		return
	_scan_dir = 0
	if _vlc:
		_vlc.stop()
	is_playing = false
	_paused = false
	_n_audio = -1
	_n_sub = -1
	if _emitter:
		_emitter.flush()
	if connected_tv:
		connected_tv.hide_osd()
	_net_push_state()


func _on_disc_finished() -> void:
	is_playing = false


# --- DVD menu / chapter control (called by the remote) ---

func dvd_menu_up() -> void:
	if _net_forward_cmd("menu_up"): return
	if _vlc: _vlc.menu_up()
	_net_push_state()


func dvd_menu_down() -> void:
	if _net_forward_cmd("menu_down"): return
	if _vlc: _vlc.menu_down()
	_net_push_state()


func dvd_menu_left() -> void:
	if _net_forward_cmd("menu_left"): return
	if _vlc: _vlc.menu_left()
	_net_push_state()


func dvd_menu_right() -> void:
	if _net_forward_cmd("menu_right"): return
	if _vlc: _vlc.menu_right()
	_net_push_state()


func dvd_ok() -> void:
	if _net_forward_cmd("ok"): return
	if _vlc: _vlc.menu_activate()
	_net_push_state()


func dvd_root_menu() -> void:
	if _net_forward_cmd("root"): return
	if _vlc:
		# Real "Menu" button: return to the disc's root menu from anywhere (a
		# popup navigate does nothing mid-title on most discs).
		_vlc.go_to_menu()
		_osd("MENU")
	_net_push_state()


func dvd_next_chapter() -> void:
	if _net_forward_cmd("next_ch"): return
	if _vlc:
		_vlc.next_chapter()
		_osd("NEXT")
	_net_push_state()


func dvd_prev_chapter() -> void:
	if _net_forward_cmd("prev_ch"): return
	if _vlc:
		_vlc.prev_chapter()
		_osd("PREV")
	_net_push_state()


## Whether the disc is currently showing a menu (drives the remote's button set).
func is_in_menu() -> bool:
	return _vlc != null and _vlc.is_in_menu()


# --- Audio-track / subtitle cycling (called by the remote) ---

func dvd_cycle_audio() -> void:
	if _net_forward_cmd("audio"): return
	_cycle_audio_local()
	_net_push_state()


func dvd_cycle_subtitle() -> void:
	if _net_forward_cmd("subtitle"): return
	_cycle_subtitle_local()
	_net_push_state()


## Advance to the next audio track (wraps), OSD the new track name.
func _cycle_audio_local() -> void:
	if _vlc == null:
		return
	var tracks: Array = _vlc.get_audio_tracks()
	if tracks.size() <= 1:
		_osd("AUDIO: —")
		return
	var id := _next_track_id(tracks, _vlc.get_audio_track())
	_vlc.set_audio_track(id)
	_osd("AUDIO: " + _track_name(tracks, id))
	_refresh_track_counts()


## Advance to the next subtitle track (wraps; libVLC's list includes a -1 "Disable"
## entry, so cycling naturally passes through subtitles-off).
func _cycle_subtitle_local() -> void:
	if _vlc == null:
		return
	var tracks: Array = _vlc.get_subtitle_tracks()
	if tracks.is_empty():
		_osd("SUB: —")
		return
	var id := _next_track_id(tracks, _vlc.get_subtitle())
	_vlc.set_subtitle(id)
	_osd("SUB: " + _track_name(tracks, id))
	_refresh_track_counts()


## Next id after `cur` in a [{id,name}] track list, wrapping around.
func _next_track_id(tracks: Array, cur: int) -> int:
	var ids: Array = []
	for t: Dictionary in tracks:
		ids.append(int(t["id"]))
	if ids.is_empty():
		return cur
	var idx := ids.find(cur)
	return int(ids[(idx + 1) % ids.size()])


## Human label for a track id (falls back to "Off" for -1, else the raw id).
func _track_name(tracks: Array, id: int) -> String:
	for t: Dictionary in tracks:
		if int(t["id"]) == id:
			var n := str(t["name"])
			if not n.is_empty():
				return n
			return "Off" if id == -1 else str(id)
	return "—"


## Refresh the cached audio/subtitle track counts used for remote greying.
func _refresh_track_counts() -> void:
	if _vlc == null or not is_playing:
		_n_audio = -1
		_n_sub = -1
		return
	_n_audio = (_vlc.get_audio_tracks() as Array).size()
	_n_sub = (_vlc.get_subtitle_tracks() as Array).size()


## Whether the disc offers more than one audio track (read by the TV remote to
## grey the Audio cell). Optimistic while the count is still unknown (-1).
func has_audio_options() -> bool:
	return _n_audio < 0 or _n_audio > 1


## Whether the disc offers a real subtitle beyond libVLC's "Disable" entry.
func has_subtitle_options() -> bool:
	return _n_sub < 0 or _n_sub > 1


# ── Multiplayer sync (Phase 5) ────────────────────────────────────────────────
# Host is transport + menu authority. A client's transport/menu intent is
# forwarded to the host, which executes it and broadcasts DVD state; every peer
# plays its own local disc copy and drift-corrects to the host's title/chapter/
# time. Disc images are verify-only (MD5), never sent (see file_transfer.gd).

## Client-in-session: route a transport/menu intent to the host instead of
## acting locally. Returns true when forwarded (caller must then return).
func _net_forward_cmd(cmd: String) -> bool:
	if NetworkManager.is_client() and not NetworkManager.is_event_applying():
		NetworkManager.report_event(NetEvents.EV_DVD_CMD, {"dvd": self, "cmd": cmd})
		return true
	return false


## Host: broadcast the current transport state for peer drift sync (no-op
## offline / on clients / while applying a remote event).
func _net_push_state() -> void:
	if NetworkManager.is_host() and not NetworkManager.is_event_applying():
		NetworkManager.report_media_state(self)


## Current transport state for the sync layer.
func net_get_state() -> Dictionary:
	if not is_playing or _vlc == null:
		return {"playing": false, "paused": false, "title": 0, "chapter": 0,
			"time": 0, "length": 0, "menu": false, "audio": -1, "sub": -1}
	return {
		"playing": true,
		"paused": _paused,
		"title": _vlc.get_title(),
		"chapter": _vlc.get_chapter(),
		"time": _vlc.get_time(),
		"length": _vlc.get_length(),
		"menu": _vlc.is_in_menu(),
		"audio": _vlc.get_audio_track(),
		"sub": _vlc.get_subtitle(),
	}


## Client: mirror the host's transport state on the LOCAL player.
func net_apply_state(state: Dictionary) -> void:
	var playing := bool(state.get("playing", false))
	var paused := bool(state.get("paused", false))
	var title := int(state.get("title", 0))
	var chapter := int(state.get("chapter", 0))
	var time_ms := int(state.get("time", 0))
	var length_ms := int(state.get("length", 0))
	var menu := bool(state.get("menu", false))
	var audio_id := int(state.get("audio", -1))
	var sub_id := int(state.get("sub", -1))
	if not playing:
		if is_playing:
			stop()
		return
	# The disc path is resolved by object_sync after insertion (verify-only);
	# refresh in case it landed after the insert event.
	var disc := _slot.get_media()
	if dvd_path.is_empty() and disc and disc.has_method("get_dvd_path"):
		dvd_path = disc.get_dvd_path()
	if not is_playing:
		if dvd_path.is_empty() or connected_tv == null:
			_osd("WAITING FOR DISC…")
			return
		play()
	if not is_playing or _vlc == null:
		return
	# Follow the host's title so menu↔playback transitions (incl. the "Menu"
	# button returning to a menu title) track on every peer. Chapter/time drift
	# is only corrected during actual playback; the menu-highlight VM state is
	# not replicated (host is the menu authority).
	if _vlc.get_title() != title:
		_vlc.set_title(title)
	if not menu:
		if _vlc.get_chapter() != chapter:
			_vlc.set_chapter(chapter)
		if length_ms > 0 and absf(float(_vlc.get_time() - time_ms)) > NET_DRIFT_TOLERANCE * 1000.0:
			_vlc.set_position(clampf(float(time_ms) / float(length_ms), 0.0, 1.0))
	_vlc.set_paused(paused)
	_paused = paused
	# Follow the host's audio/subtitle selection (shared TV screen).
	if audio_id >= 0 and _vlc.get_audio_track() != audio_id:
		_vlc.set_audio_track(audio_id)
	if _vlc.get_subtitle() != sub_id:
		_vlc.set_subtitle(sub_id)


# ── Save/load + net restore ───────────────────────────────────────────────────

func get_snapped_disc() -> Node3D:
	return _slot.get_media()


## Seat a disc programmatically (event/save restore) — no ride, bypasses the filter.
func restore_disc(disc: Node3D) -> void:
	_slot.restore(disc)


## The counterpart to restore_disc, for a remote peer taking the disc out.
##
## Releases the snap zone rather than running the local eject ride: the disc is
## already gone on the peer that moved it, and object_sync positions it here.
## Which child holds the disc stays this deck's business.
func net_release_disc() -> void:
	_disc_slot.drop_object()


## Reconnect the cable to a TV programmatically (EV_TV_PLUG + save restore). If
## the cable hasn't finished spawning yet, defer until it has.
## Kept for scene_persistence, which still records which set a deck was playing
## through. There is nothing to restore now that the lead is a separate object:
## the connection lives in a spawned cable's six plugs, not in this deck.
func restore_cable_connection(_tv: RetroTV) -> void:
	pass


# --- Options panel (audio track / subtitles) ---

## Toggle the floating DVD settings panel. Called by SpawnMenuController when the
## menu button is pressed while pointing at this player.
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel == null:
		return
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)


func get_audio_tracks() -> Array:
	return _vlc.get_audio_tracks() if _vlc else []


func get_audio_track() -> int:
	return _vlc.get_audio_track() if _vlc else -1


func set_audio_track(id: int) -> void:
	if _vlc:
		_vlc.set_audio_track(id)


func get_subtitle_tracks() -> Array:
	return _vlc.get_subtitle_tracks() if _vlc else []


func get_subtitle() -> int:
	return _vlc.get_subtitle() if _vlc else -1


func set_subtitle(id: int) -> void:
	if _vlc:
		_vlc.set_subtitle(id)


func _osd(text: String) -> void:
	if connected_tv:
		connected_tv.show_osd_timed(text, 2.0)


# --- TV connection contract ---
#
# on_tv_connected/on_tv_disconnected are gone: they were the captive lead's, called
# by the set when a CablePlug carrying a back-reference to its host arrived. A
# composite cable's plugs belong to no device, so the deck works out its own
# connection instead — see on_av_topology_changed. A console still uses the old
# path, which is why the set still has it.


func set_audio_volume(volume: float) -> void:
	_volume_linear = clampf(volume, 0.0, 1.0)
	# Don't fight an active scan mute; it restores on scan exit.
	if _emitter and _scan_dir == 0:
		_emitter.set_volume(_volume_linear)


## Part of the TV contract: the set's mono switch, applied to the disc's own
## sound. See SpatialAudioEmitter.set_channel_mode.
func set_audio_channel_mode(mode: int) -> void:
	if _emitter:
		_emitter.set_channel_mode(mode)


# --- What the set reads ---
#
# The deck no longer paints anything. It answers one question — is there a picture
# — and RetroTV builds the material. set_screen_enabled, _screen_allowed,
# _may_paint, _bind_screen_to_tv and _blank_screen all existed to keep this deck's
# painting in step with a set that was painting too. There is one painter now.


## The disc's live frame, or null when there is nothing to show: stopped, or the
## picture cord is not in the set's video socket. A different object after a
## resolution change, so the set re-reads it per frame.
func get_video_texture() -> Texture2D:
	if _vlc == null or not is_playing or not _feed_video:
		return null
	return _vlc.get_texture()


# --- A/V out ---
#
# The deck has three sockets and no lead of its own. A composite cable is spawned
# and plugged in, and what plays depends entirely on which sockets its cords reach:
# picture only when a cord joins this VideoOut to the set's video in, the left
# channel only when one joins AudioLOut to an audio in — and if that one lands in
# the set's RIGHT socket, the left channel comes out of the right-hand speaker.
# CompositeCable works out the pairs; this only reads them.



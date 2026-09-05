## TVRemote — pickable remote control. While held, it raycasts forward from its
## tip; when pointed at a RetroTV / VCRPlayer / DVDPlayer / CD / Cassette player the
## target is outlined maroon (PickableHighlight.set_remote_target) and a small
## button GRID pops up above the remote, billboarded to the camera. Each device has
## a stable, real-remote-style layout (icons from a Symbols Nerd Font); buttons that
## don't apply right now (e.g. a DVD's menu arrows during playback) are greyed and
## skipped rather than removed.
##
## VR: the thumbstick moves the highlight around the grid (up/down/left/right → the
## nearest enabled cell), primary button (A/X) or thumbstick click activates.
## Desktop: aim follows the camera reticle, arrow keys move the highlight, Enter
## activates. There is ONE navigation model everywhere — a DVD's on-screen menu is
## driven by highlighting and pressing its ▲/◀/●/▶/▼ cells like any other button.
class_name TVRemote
extends XRToolsPickable


## Half-angle (degrees) of the acquisition cone: point roughly toward a device and
## the one nearest the cone centre is targeted. Tunable in the inspector.
@export var target_cone_angle_deg: float = 20.0
## Max targeting range in metres (cone radius; also the desktop crosshair reach).
@export var target_max_distance: float = 8.0
## Seconds the ray may leave the target before the menu hides (hand jitter).
const TARGET_GRACE := 0.4

# Grid geometry (metres)
const CELL_W       := 0.05
const CELL_H       := 0.036
const GAP          := 0.006
const GRID_COLS    := 3
const PANEL_PAD    := 0.012
const FLOAT_HEIGHT := 0.16

## Cell glyph sizing. The label is authored at CELL_FONT_MAX and then shrunk per
## cell to fit — see _fit_font_size. A fixed size cannot work here: these icons
## come from three different Nerd Font families and their ink boxes differ by 2x
## at the same point size, so one size that suits the arrows spills the speaker
## pair and the power ring off the tile.
const LABEL_PIXEL_SIZE := 0.0011
const CELL_FONT_MAX := 40
const CELL_FONT_MIN := 8
## Every glyph is normalised to this much of the tile's HEIGHT, which is what
## makes a grid of icons read at one weight rather than at whatever weight each
## font family happened to draw.
const CELL_INK_FRACTION := 0.75
## …and nothing may be wider than this much of its own cell.
const CELL_WIDTH_FRACTION := 0.85
## Outline thickness as a fraction of the font size, so a shrunk glyph doesn't
## keep a halo sized for the big one. 0.15 x CELL_FONT_MAX reproduces the 6 px
## outline these labels were authored with.
const OUTLINE_RATIO := 0.15
## VR only: the grid is authored at desktop size, where it sits in a corner of a
## ~70° screen. Filling that much of a headset's view is overbearing, so shrink it
## for the floating panel.
const VR_MENU_SCALE := 0.6
## Desktop: camera-local menu anchor (right, up, forward) — just above the
## FPS-snapped remote, fixed in screen space so looking around doesn't move it.
const DESKTOP_MENU_OFFSET := Vector3(0.22, -0.03, -0.55)

# Thumbstick step/latch thresholds
const STICK_STEP  := 0.6
const STICK_REARM := 0.3

const COLOR_MAROON          := Color(0.5, 0.0, 0.13, 0.9)
const COLOR_CELL_BG         := Color(0.12, 0.12, 0.16, 0.92)
const COLOR_PANEL_BG        := Color(0.05, 0.05, 0.1, 0.85)
const COLOR_GLYPH           := Color(0.88, 0.90, 0.98)
const COLOR_GLYPH_SELECTED  := Color(1.0, 1.0, 1.0)
const COLOR_GLYPH_DISABLED  := Color(0.42, 0.42, 0.48, 0.55)
const COLOR_GLYPH_ON        := Color(0.30, 1.0, 0.42)   # TV power = on
const COLOR_GLYPH_MUTE      := Color(1.0, 0.35, 0.35)   # TV mute = active
const COLOR_HILITE          := Color(0.62, 0.10, 0.22, 0.7)

## Symbol codepoints live in TransportGlyphs, shared with the front panels of the
## decks this drives. Built into the _glyphs string map in _ready so layouts can
## name glyphs by key.

## Desktop mode: lock to the camera lower-right pointing straight ahead
## (FPS-style, same as the LightGun — read by desktop_pickup.gd). Drop with
## Shift+click while snapped.
var desktop_fps_snap: bool = true

## Height of the drop hint above the remote, in metres. Clear of the button
## grid, which floats at FLOAT_HEIGHT.
const HINT_HEIGHT := 0.26
var _hint: HeldHint = null

# Toggle-hold state (mirrors LightGun)
var _allow_drop := false
var _saved_by: Node3D = null
var _holding_ctrl: XRController3D = null
var _desktop_held: bool = false

## Hides the ray pointer on whichever hand is holding this, so a grab
## gesture cannot also fire the pointer at whatever is behind it.
var _pointer_block := VrPointerBlock.new()

var _locomotion_manager: LocomotionManager = null
var _spawn_menu_ctrl: Node = null
var _left_vr_ctrl: XRController3D = null
var _right_vr_ctrl: XRController3D = null

# Current aim target and lost-ray grace timer.
var _target: Node3D = null
var _lost_time: float = 0.0

## Whether the aimed set had 3D content at the last grid build, so the 3D key can
## be added or dropped when that changes.
var _tv_had_stereo: bool = false

# Selection state
var _selection: int = -1
var _stick_latched := false
var _prev_confirm := false

# Menu nodes (built in code)
var _menu: Node3D = null
var _menu_bg: MeshInstance3D = null
var _hilite: MeshInstance3D = null
# Per-cell state: each is {id, glyph, col, row, span, cx, enabled, face, label}.
var _cells: Array = []
var _nrows: int = 0
# key -> glyph String (built from GLYPH_CODES in _ready)
var _glyphs: Dictionary = {}
# Combined font: project default + the Symbols Nerd Font as a fallback for icons.
var _font: Font = null

@onready var _tip: Marker3D = $Tip
@onready var _pointer_area: StaticBody3D = $PointerArea


## The thumbstick drives the on-screen grid while the remote is aimed at a
## device, so the push-out gesture would fight it. Catching one back off the
## laser still works. Queried by function_pickup._handoff_eligible.
func wants_ray_handoff() -> bool:
	return false


func _ready() -> void:
	super._ready()
	press_to_hold = false
	add_to_group("spawned")
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	_hint = HeldHint.attach(self, true, HINT_HEIGHT)
	for k: String in TransportGlyphs.CODES:
		_glyphs[k] = TransportGlyphs.glyph(k)
	_font = TransportGlyphs.font()
	_build_menu()
	call_deferred("_find_vr_nodes")


func _find_vr_nodes() -> void:
	_locomotion_manager = get_tree().root.find_child("LocomotionManager", true, false) as LocomotionManager
	_spawn_menu_ctrl = get_tree().root.find_child("SpawnMenuController", true, false)
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		var ctrl := node as XRController3D
		if ctrl == null:
			continue
		if ctrl.tracker == &"left_hand":
			_left_vr_ctrl = ctrl
		elif ctrl.tracker == &"right_hand":
			_right_vr_ctrl = ctrl
	# The spawn menu hands a fresh object straight to the hand that spawned it, so
	# the grab can land BEFORE this deferred lookup runs — with no manager yet, that
	# grab's block was dropped on the floor and the holding hand kept driving
	# locomotion. Re-apply now that the manager is known.
	_update_locomotion_block()


# ── Toggle-hold (mirrors LightGun) ────────────────────────────────────────────

func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	if _hint:
		_hint.on_grabbed(by)
	var pickup := by as XRToolsFunctionPickup
	var ctrl := pickup.get_controller() if pickup else null as XRController3D
	if ctrl == null:
		if by.is_in_group("desktop_hand"):
			_desktop_held = true
		return
	_saved_by = by
	_holding_ctrl = ctrl
	_set_model_visible(ctrl, false)
	_update_pointer_block(ctrl, true)
	_update_locomotion_block()


func _on_dropped_signal(_pickable: Node3D) -> void:
	if not _allow_drop and is_instance_valid(_saved_by):
		PokeTip.begin_rehold(_holding_ctrl)
		call_deferred("_rehold")
	else:
		if _hint:
			_hint.on_dropped()
		_set_model_visible(_holding_ctrl, true)
		_update_pointer_block(_holding_ctrl, false)
		_allow_drop = false
		_saved_by = null
		_holding_ctrl = null
		_desktop_held = false
		_clear_target()
		_update_locomotion_block()


func _rehold() -> void:
	if _allow_drop:
		_allow_drop = false
		return
	if not is_instance_valid(_saved_by):
		_set_model_visible(_holding_ctrl, true)
		_update_pointer_block(_holding_ctrl, false)
		_saved_by = null
		_holding_ctrl = null
		_update_locomotion_block()
		return
	_saved_by.call("_pick_up_object", self)


func _set_model_visible(ctrl: XRController3D, shown: bool) -> void:
	if is_instance_valid(ctrl) and ctrl.has_method("set_model_visible"):
		ctrl.call("set_model_visible", shown)


## The combo test itself lives on HeldHint so the check and the row advertising
## it cannot disagree. Counting the use here rather than at the drop branch is
## deliberate: a predicate every drop passes through cannot be missed when
## another is added. HeldHint counts once per hold, so testing every frame does
## not inflate it.
func _is_combo_pressed(ctrl: XRController3D) -> bool:
	if not HeldHint.is_combo_pressed(ctrl):
		return false
	if _hint:
		_hint.note_used(&"drop_vr")
	return true


func _drop_all() -> void:
	_set_model_visible(_holding_ctrl, true)
	_update_pointer_block(_holding_ctrl, false)
	_allow_drop = true
	_holding_ctrl = null
	_clear_target()
	_update_locomotion_block()
	drop()


func _exit_tree() -> void:
	_clear_target()
	_pointer_block.release(_left_vr_ctrl, _right_vr_ctrl)
	if _locomotion_manager != null:
		_locomotion_manager.clear_owner(_vr_block_owner())
		_locomotion_manager.set_block(_desktop_block_owner(),
			LocomotionManager.CHANNEL_DESKTOP_MOVE, false)
	_allow_drop = true
	super._exit_tree()


## Per-instance owner for the VR channels. Shared owner keys let one object
## erase another's block -- see LocomotionManager.set_block for what that cost.
func _vr_block_owner() -> StringName:
	return StringName("retro_hold_%d" % get_instance_id())


func _update_locomotion_block() -> void:
	var left_held  := is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"left_hand"
	var right_held := is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"right_hand"
	var desktop_claim := _desktop_held
	if _locomotion_manager != null:
		_locomotion_manager.set_block(_vr_block_owner(), LocomotionManager.CHANNEL_LEFT,  left_held)
		_locomotion_manager.set_block(_vr_block_owner(), LocomotionManager.CHANNEL_RIGHT, right_held)
	# Desktop has no hands, so the tracker tests above never fire there. The
	# desktop providers poll the InputMap, so blocking them is the only way to
	# stop WASD reaching the player while this device is claiming it.
		_locomotion_manager.set_block(_desktop_block_owner(),
			LocomotionManager.CHANNEL_DESKTOP_MOVE, desktop_claim)
	if is_instance_valid(_spawn_menu_ctrl) and "disabled" in _spawn_menu_ctrl:
		_spawn_menu_ctrl.set("disabled", left_held)


## Delegates to VrPointerBlock, which owns the shared refcount.
func _update_pointer_block(ctrl: XRController3D, should_block: bool) -> void:
	_pointer_block.set_block(ctrl, should_block)


# ── Aiming / target management ────────────────────────────────────────────────

func _process(delta: float) -> void:
	# VR drop combo (desktop drop is handled by desktop_pickup via left click)
	if _is_combo_pressed(_holding_ctrl):
		_drop_all()
		return

	var held := is_instance_valid(_holding_ctrl) or _desktop_held
	if not held:
		if _target != null:
			_clear_target()
		return

	_update_target(delta)
	_update_menu_transform()

	if _target != null:
		# Greying + dynamic glyphs (play/pause, power/mute tint) follow the target's
		# own state every frame — no special poll needed.
		_refresh_states()
		if is_instance_valid(_holding_ctrl):
			_process_vr_selection()


func _update_target(delta: float) -> void:
	var host := _scan_for_target()
	if host == _target and host != null:
		_lost_time = 0.0
		return
	if host != null:
		# New target — switch highlight and rebuild the grid for it.
		_set_target_highlight(_target, false)
		_target = host
		_lost_time = 0.0
		_set_target_highlight(_target, true)
		_rebuild_grid()
		_menu.visible = true
		return
	# Off-target. VR's cone is already forgiving, so drop it immediately; desktop's
	# thin crosshair keeps the grace period to ride out brief jitter.
	if _target != null:
		if not is_instance_valid(_target):
			_clear_target()
			return
		if not _desktop_held:
			_clear_target()
			return
		_lost_time += delta
		if _lost_time > TARGET_GRACE:
			_clear_target()


## Desktop: a precise crosshair raycast from the camera. VR: a forgiving cone from
## the tip — point in the general direction and the device nearest the cone centre
## (with clear line-of-sight) is targeted.
func _scan_for_target() -> Node3D:
	if _desktop_held:
		var cam := get_viewport().get_camera_3d()
		if not is_instance_valid(cam):
			return null
		return _ray_device(cam.global_position, -cam.global_transform.basis.z)
	return _cone_pick(_tip.global_position, -_tip.global_transform.basis.z)


## Walk a collider up its ancestors to the owning device, or null.
func _walk_to_device(n: Node) -> Node3D:
	while n:
		if n is RetroTV or n is VCRPlayer or n is DVDPlayer or n is RetroAudioPlayer:
			return n as Node3D
		n = n.get_parent()
	return null


## Thin-ray hit on the pointable layer (desktop crosshair), walked to its device.
func _ray_device(from: Vector3, dir: Vector3) -> Node3D:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * target_max_distance)
	q.collision_mask = 1 << 20   # 21: pointable (PointerArea bodies)
	q.exclude = [_pointer_area.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return null
	return _walk_to_device(hit["collider"] as Node)


## Pick the pointable device nearest the cone centre (largest dot with `dir`) that
## is within `target_cone_angle_deg` / `target_max_distance` and not occluded by
## world geometry. Mirrors XRToolsFunctionPickup._get_closest_ranged.
func _cone_pick(from: Vector3, dir: Vector3) -> Node3D:
	var shape := SphereShape3D.new()
	shape.radius = target_max_distance
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.collision_mask = 1 << 20   # 21: pointable (PointerArea bodies)
	q.exclude = [_pointer_area.get_rid()]
	var space := get_world_3d().direct_space_state
	var hits := space.intersect_shape(q, 64)

	# Best dot product (cone centre = 1.0) per device, plus a point to sight-check.
	var min_dp := cos(deg_to_rad(target_cone_angle_deg))
	var best_dp: Dictionary = {}   # device -> dp
	var best_pt: Dictionary = {}   # device -> collider world position
	for h in hits:
		var dev := _walk_to_device(h["collider"] as Node)
		if dev == null:
			continue
		var col := h["collider"] as Node3D
		var to: Vector3 = col.global_position - from
		var dist := to.length()
		if dist > target_max_distance or dist < 0.0001:
			continue
		var dp := dir.dot(to / dist)
		if dp < min_dp:
			continue
		if not best_dp.has(dev) or dp > float(best_dp[dev]):
			best_dp[dev] = dp
			best_pt[dev] = col.global_position

	# Closest-to-centre first; return the first with clear line-of-sight.
	var devices: Array = best_dp.keys()
	devices.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return float(best_dp[a]) > float(best_dp[b]))
	for dev: Node3D in devices:
		if not _occluded(from, best_pt[dev]):
			return dev
	return null


## True when world/room geometry (physics layer 1) blocks the straight line from
## `from` to `to`. Devices live on layer 21, so they never self-block.
func _occluded(from: Vector3, to: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1 << 0   # world/walls
	q.exclude = [_pointer_area.get_rid()]
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _clear_target() -> void:
	_set_target_highlight(_target, false)
	_target = null
	_lost_time = 0.0
	if _menu:
		_menu.visible = false


func _set_target_highlight(target: Node3D, active: bool) -> void:
	if not is_instance_valid(target):
		return
	var hl := target.find_child("PickableHighlight", false, false)
	if hl and hl.has_method("set_remote_target"):
		hl.call("set_remote_target", active)


# ── Layout (per-device cell grid) ─────────────────────────────────────────────

## The static cell specs for the current target: {id, col, row, span} plus a face —
## either `glyph` (a TransportGlyphs key) or `text` (printed literally).
## `enabled` is resolved separately each frame in _refresh_states().
func _layout_for_target() -> Array:
	if _target is RetroTV:
		var tv := _target as RetroTV
		var cells: Array = [
			{"id": "power", "glyph": "power", "col": 0, "row": 0, "span": 3},
			# SOURCE sits directly under power, the way it does on a real handset:
			# it is a whole-set control, not part of the volume cluster.
			{"id": "source", "glyph": "source", "col": 0, "row": 1, "span": 3},
			{"id": "vol_down", "glyph": "vol_down", "col": 0, "row": 2},
			{"id": "mute", "glyph": "mute", "col": 1, "row": 2},
			{"id": "vol_up", "glyph": "vol_up", "col": 2, "row": 2},
		]
		# The channel keys are always on the handset and grey out when the set is not
		# on the tuner (see _cell_enabled). They used to be ADDED only while the tuner
		# was selected, and the grid is rebuilt on a change of TARGET alone — so
		# switching input with the remote still aimed at the same set left the keys
		# missing until you looked away and back.
		var next_row := 3
		cells.append({"id": "ch_down", "glyph": "ch_down", "col": 0, "row": next_row})
		cells.append({"id": "ch_up", "glyph": "ch_up", "col": 2, "row": next_row})
		next_row += 1
		# The speaker switch always; 3D only while there is something 3D to
		# switch, which is how the set's own bezel key behaves. Both take their
		# glyph from the mode they are currently in, so the key reads as a state
		# rather than a label — see _tv_audio_glyph / _tv_stereo_glyph.
		# Picture shape rides with them: also a state key, also always available.
		if tv.has_stereo_source():
			cells.append({"id": "audio_mode", "glyph": _tv_audio_glyph(tv),
				"col": 0, "row": next_row})
			cells.append({"id": "stereo3d", "glyph": _tv_stereo_glyph(tv),
				"col": 1, "row": next_row})
			cells.append({"id": "aspect", "text": _tv_aspect_text(tv),
				"col": 2, "row": next_row})
		else:
			cells.append({"id": "audio_mode", "glyph": _tv_audio_glyph(tv),
				"col": 0, "row": next_row})
			cells.append({"id": "aspect", "text": _tv_aspect_text(tv),
				"col": 2, "row": next_row})
		return cells
	if _target is VCRPlayer:
		# Eject on its own top row, then the transport grid.
		return [
			{"id": "eject", "glyph": "eject", "col": 0, "row": 0, "span": 3},
			{"id": "prev", "glyph": "prev", "col": 0, "row": 1},
			{"id": "playpause", "glyph": "play", "col": 1, "row": 1},
			{"id": "next", "glyph": "next", "col": 2, "row": 1},
			{"id": "rew", "glyph": "rew", "col": 0, "row": 2},
			{"id": "stop", "glyph": "stop", "col": 1, "row": 2},
			{"id": "ff", "glyph": "ff", "col": 2, "row": 2},
		]
	if _target is RetroAudioPlayer:
		# Transport grid: prev/play/next over rew/stop/ff. prev/next greyed unless CD.
		return [
			{"id": "prev", "glyph": "prev", "col": 0, "row": 0},
			{"id": "playpause", "glyph": "play", "col": 1, "row": 0},
			{"id": "next", "glyph": "next", "col": 2, "row": 0},
			{"id": "rew", "glyph": "rew", "col": 0, "row": 1},
			{"id": "stop", "glyph": "stop", "col": 1, "row": 1},
			{"id": "ff", "glyph": "ff", "col": 2, "row": 1},
		]
	if _target is DVDPlayer:
		# Eject on its own top row, then D-pad cluster + chapter/transport + MENU.
		return [
			{"id": "eject", "glyph": "eject", "col": 0, "row": 0, "span": 3},
			{"id": "up", "glyph": "up", "col": 1, "row": 1},
			{"id": "left", "glyph": "left", "col": 0, "row": 2},
			{"id": "ok", "glyph": "ok", "col": 1, "row": 2},
			{"id": "right", "glyph": "right", "col": 2, "row": 2},
			{"id": "down", "glyph": "down", "col": 1, "row": 3},
			{"id": "prev_ch", "glyph": "prev", "col": 0, "row": 4},
			{"id": "playpause", "glyph": "play", "col": 1, "row": 4},
			{"id": "next_ch", "glyph": "next", "col": 2, "row": 4},
			{"id": "rew", "glyph": "rew", "col": 0, "row": 5},
			{"id": "stop", "glyph": "stop", "col": 1, "row": 5},
			{"id": "ff", "glyph": "ff", "col": 2, "row": 5},
			{"id": "menu", "glyph": "menu", "col": 0, "row": 6, "span": 3},
			# Audio-track + subtitle cycle, two half-width cells filling the row.
			{"id": "audio", "glyph": "audio", "col": 0.0, "row": 7, "span": 1.5},
			{"id": "subtitle", "glyph": "subtitle", "col": 1.5, "row": 7, "span": 1.5},
		]
	return []


## Whether a cell id is usable against the current target's state.
## Both of the set's tri-state keys print the mode they are IN rather than a
## label, the same way its bezel caps do.
func _tv_audio_glyph(tv: RetroTV) -> String:
	return "audio_stereo" if tv.audio_mode == 0 else "audio_mono"


func _tv_stereo_glyph(tv: RetroTV) -> String:
	return "stereo" if tv.stereo_mode == 0 else "eye"


## The shape the set is showing NOW, not the one the key would switch to — same
## reading as the audio and 3D keys, where the cell prints the current state.
##
## The words, not the crop glyphs it used to carry: the set's own bezel cap prints
## "16:9" / "4:3" (RetroTV._update_aspect_button) and the handset key for it should
## say what the cap says. Two picture-shape controls with different faces is one
## control too many to learn.
func _tv_aspect_text(tv: RetroTV) -> String:
	return "16:9" if tv.widescreen else "4:3"


## -1 leans left, +1 right, 0 centred — which channel, or which eye.
func _tv_side(mode: int) -> float:
	if mode == 1:
		return -1.0
	return 1.0 if mode == 2 else 0.0


## A cell is 50 mm wide against the set's 25 mm cap, so the lean is bigger here.
const CELL_LEAN := 0.009


func _lean(label: Label3D, side: float) -> void:
	if not label.has_meta("home_x"):
		label.set_meta("home_x", label.position.x)
	label.position.x = float(label.get_meta("home_x")) + side * CELL_LEAN


func _cell_enabled(id: String) -> bool:
	if _target is DVDPlayer:
		var in_menu: bool = (_target as DVDPlayer).is_in_menu()
		match id:
			"eject":
				return (_target as DVDPlayer).has_media()   # only with a disc in
			"up", "down", "left", "right", "ok":
				return in_menu       # nav cluster only in a disc menu
			"menu":
				return true          # always usable (return to root menu)
			"audio":
				return not in_menu and (_target as DVDPlayer).has_audio_options()
			"subtitle":
				return not in_menu and (_target as DVDPlayer).has_subtitle_options()
			_:
				return not in_menu   # transport/chapter only during playback
	if _target is VCRPlayer:
		if id == "eject":
			return (_target as VCRPlayer).has_media()   # only with a tape in
		return id != "prev" and id != "next"
	if _target is RetroAudioPlayer:
		if id == "prev" or id == "next":
			return (_target as RetroAudioPlayer).has_track_skip()
		# A turntable has no scan: you move the needle instead. Greyed for the
		# same reason prev/next are greyed on a cassette — the deck cannot do it.
		if id == "rew" or id == "ff":
			return (_target as RetroAudioPlayer).has_scan()
		return true
	if _target is RetroTV:
		# The channel keys are the one TV cell that can be dead: the set may be on
		# the component input, where there is no channel to change, or the tuner may
		# have no list yet (no channels.json, tuner still being found). Every other
		# key on a set works whatever it is showing.
		if id == "ch_up" or id == "ch_down":
			var tv := _target as RetroTV
			return tv.get_source() == RetroTV.Source.TV and tv.has_channels()
	return true


# ── Grid widget ───────────────────────────────────────────────────────────────

func _build_menu() -> void:
	_menu = Node3D.new()
	_menu.top_level = true
	_menu.visible = false
	# Repositioned every frame; interpolation would render a visible slide on show.
	_menu.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_menu)

	_menu_bg = MeshInstance3D.new()
	_menu_bg.mesh = QuadMesh.new()
	_menu_bg.material_override = _flat_mat(COLOR_PANEL_BG, 10)
	_menu_bg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Keep the menu out of PickableHighlight's outline overlays (a big highlighted
	# quad would draw a huge hull and mask other objects' outlines behind it).
	_menu_bg.add_to_group("outline_exclude")
	_menu.add_child(_menu_bg)

	_hilite = MeshInstance3D.new()
	_hilite.mesh = QuadMesh.new()
	_hilite.material_override = _flat_mat(COLOR_HILITE, 12)
	_hilite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hilite.add_to_group("outline_exclude")
	_hilite.visible = false
	_menu.add_child(_hilite)


## An unshaded, alpha-blended, depth-test-off material at the given render priority.
func _flat_mat(color: Color, priority: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = color
	m.no_depth_test = true
	m.render_priority = priority
	return m


## Width of a cell spanning `span` columns.
func _cell_width(span: float) -> float:
	return span * CELL_W + (span - 1.0) * GAP


## What a layout spec prints: its own literal `text` when it carries one (the
## picture-shape key says "16:9"), otherwise the glyph its `glyph` key names.
func _spec_text(spec: Dictionary) -> String:
	if spec.has("text"):
		return str(spec["text"])
	return _glyph(str(spec.get("glyph", "")))


## The text a state key should be printing right now, or "" for a cell whose face
## never changes. One list, so a key that reads as a state cannot be given a live
## face in the layout and then left stale by the per-frame refresh — which is
## exactly what happened to the picture-shape key.
func _live_text(id: String) -> String:
	if id == "playpause":
		return _glyph("pause" if _target_playing() else "play")
	if _target is RetroTV:
		var tv := _target as RetroTV
		match id:
			"audio_mode": return _glyph(_tv_audio_glyph(tv))
			"stereo3d":   return _glyph(_tv_stereo_glyph(tv))
			"aspect":     return _tv_aspect_text(tv)
	return ""


## Print `text` on a cell and size it to that cell.
func _set_cell_text(cell: Dictionary, text: String) -> void:
	var label := cell["label"] as Label3D
	if not is_instance_valid(label):
		return
	label.text = text
	var w := float(cell["width"])
	var size := CELL_FONT_MAX
	for face: String in _sizing_faces(str(cell["id"]), text):
		size = mini(size, _fit_font_size(face, w))
	label.font_size = size
	label.outline_size = maxi(1, roundi(float(size) * OUTLINE_RATIO))


## Every face a key can wear. A state key is sized for the largest of them, so
## toggling it changes what it says and not how big it says it — "4:3" alone fits
## at 22 and "16:9" at 17, and a key that jumps a type size mid-press reads as a
## different key.
func _sizing_faces(id: String, text: String) -> Array:
	match id:
		"playpause":  return [_glyph("play"), _glyph("pause")]
		"audio_mode": return [_glyph("audio_stereo"), _glyph("audio_mono")]
		"stereo3d":   return [_glyph("stereo"), _glyph("eye")]
		"aspect":     return ["16:9", "4:3"]
	return [text]


func _glyph(key: String) -> String:
	return str(_glyphs.get(key, "?"))


## Font size at which `text` fills CELL_INK_FRACTION of the tile's height without
## exceeding CELL_WIDTH_FRACTION of `cell_w`, capped at CELL_FONT_MAX.
##
## Normalising on the INK box rather than the line box is the whole point. This
## font's em box is 60 mm at CELL_FONT_MAX against a 36 mm tile, so on line
## metrics every glyph "overflows" and a global shrink would be the only answer —
## yet the ink of md-video_3d is barely half the height of md-speaker-multiple at
## the same point size. Measure what is actually drawn and every icon lands at one
## weight, which is what a row of keys is supposed to look like.
##
## Memoised: the answer depends on nothing but the string and the cell, and the
## per-frame refresh asks for it whenever a state key changes face.
static var _fit_cache: Dictionary = {}

func _fit_font_size(text: String, cell_w: float) -> int:
	var key := "%s|%.4f" % [text, cell_w]
	if _fit_cache.has(key):
		return int(_fit_cache[key])
	var ink := _ink_extent(text, CELL_FONT_MAX)
	var k := 1.0
	if ink.y > 0.0:
		k = CELL_H * CELL_INK_FRACTION / ink.y
	if ink.x > 0.0:
		k = minf(k, cell_w * CELL_WIDTH_FRACTION / ink.x)
	var size := clampi(roundi(float(CELL_FONT_MAX) * k), CELL_FONT_MIN, CELL_FONT_MAX)
	_fit_cache[key] = size
	return size


## Drawn extent of `text` at `size`, in METRES, outline included.
##
## Height is the tallest glyph's rasterised box — the only honest measure for an
## icon, whose ink sits wherever its family chose to put it inside the em. Width
## is the advance run (right for a word) or the glyph's own box, whichever is
## wider: a single icon is routinely drawn wider than it advances.
func _ink_extent(text: String, size: int) -> Vector2:
	var ts := TextServerManager.get_primary_interface()
	var ink := Vector2.ZERO
	for i in text.length():
		var c := text.unicode_at(i)
		for rid: RID in _font.get_rids():
			var gi := ts.font_get_glyph_index(rid, size, c, 0)
			if gi == 0:
				continue
			var gs: Vector2 = ts.font_get_glyph_size(rid, Vector2i(size, 0), gi)
			ink.x = maxf(ink.x, gs.x)
			ink.y = maxf(ink.y, gs.y)
			break
	ink.x = maxf(ink.x, _font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, size).x)
	if ink.y <= 0.0:
		ink.y = _font.get_ascent(size)      # a face with no rasterised box yet
	# The halo is part of what spills off the tile, and it scales with the size
	# this is solving for (see OUTLINE_RATIO).
	var outline := float(size) * OUTLINE_RATIO * 2.0
	return (ink + Vector2(outline, outline)) * LABEL_PIXEL_SIZE


## Local position of a cell's centre (row 0 on top). col/span may be fractional
## (e.g. two 1.5-span cells filling a 3-wide row).
func _cell_center(col: float, row: int, span: float) -> Vector3:
	var cx := col + (span - 1.0) * 0.5
	var x := (cx - float(GRID_COLS - 1) * 0.5) * (CELL_W + GAP)
	var y := (float(_nrows - 1) * 0.5 - float(row)) * (CELL_H + GAP)
	return Vector3(x, y, 0.0)


## Rebuild the grid for the current target: free old cells, create new faces +
## labels from the layout, size the panel, and select the first enabled cell.
func _rebuild_grid() -> void:
	for cell: Dictionary in _cells:
		var f: Node = cell.get("face")
		if is_instance_valid(f):
			f.queue_free()
		var l: Node = cell.get("label")
		if is_instance_valid(l):
			l.queue_free()
	_cells.clear()

	var layout := _layout_for_target()
	_nrows = 0
	for spec: Dictionary in layout:
		_nrows = maxi(_nrows, int(spec["row"]) + 1)

	# Size the background panel to the grid bounds.
	var panel_w := float(GRID_COLS) * CELL_W + float(GRID_COLS - 1) * GAP + PANEL_PAD * 2.0
	var panel_h := float(_nrows) * CELL_H + float(_nrows - 1) * GAP + PANEL_PAD * 2.0
	(_menu_bg.mesh as QuadMesh).size = Vector2(panel_w, panel_h)
	_menu_bg.position = Vector3(0, 0, -0.001)

	for spec: Dictionary in layout:
		var span := float(spec.get("span", 1))
		var col := float(spec["col"])
		var row := int(spec["row"])
		var center := _cell_center(col, row, span)
		var w := _cell_width(span)

		var face := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(w, CELL_H)
		face.mesh = qm
		face.material_override = _flat_mat(COLOR_CELL_BG, 11)
		face.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		face.add_to_group("outline_exclude")
		face.position = center + Vector3(0, 0, 0.001)
		_menu.add_child(face)

		var label := Label3D.new()
		label.font = _font
		label.pixel_size = LABEL_PIXEL_SIZE
		label.no_depth_test = true
		label.render_priority = 13
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.position = center + Vector3(0, 0, 0.004)
		_menu.add_child(label)

		var cell := {
			"id": str(spec["id"]),
			"glyph": str(spec.get("glyph", "")),
			"col": col, "row": row, "span": span, "width": w,
			"cx": float(col) + float(span - 1) * 0.5,
			"enabled": true, "face": face, "label": label,
		}
		_set_cell_text(cell, _spec_text(spec))
		_cells.append(cell)

	_selection = -1
	_refresh_states()


## Recompute each cell's enabled state + dynamic glyph/tint, keep the selection on
## an enabled cell, and move the highlight. Cheap — runs each frame while shown.
func _refresh_states() -> void:
	if not is_instance_valid(_target):
		return
	# 3D content can start or stop while the remote stays aimed at the same set,
	# and the grid is otherwise only built on a target change — so the key would
	# never appear. Rebuilding is cheap and only happens on the flip.
	if _target is RetroTV:
		var has_3d: bool = (_target as RetroTV).has_stereo_source()
		if has_3d != _tv_had_stereo:
			_tv_had_stereo = has_3d
			_rebuild_grid()
			return
	for i in _cells.size():
		var cell: Dictionary = _cells[i]
		var id := str(cell["id"])
		var en := _cell_enabled(id)
		cell["enabled"] = en
		var label := cell["label"] as Label3D
		if not is_instance_valid(label):
			continue
		# Keys that print the state they are IN re-read it here; the rest keep what
		# _rebuild_grid gave them. Only written on an actual change, because the fit
		# that follows a write measures the font.
		var live := _live_text(id)
		if not live.is_empty() and live != label.text:
			_set_cell_text(cell, live)
		if _target is RetroTV:
			if id == "audio_mode":
				_lean(label, _tv_side((_target as RetroTV).audio_mode))
			elif id == "stereo3d":
				_lean(label, _tv_side((_target as RetroTV).stereo_mode))
		# Colour: state tints first, then disabled/selected overrides.
		var col := COLOR_GLYPH
		if _target is RetroTV:
			if id == "power" and (_target as RetroTV).is_powered_on():
				col = COLOR_GLYPH_ON
			elif id == "mute" and (_target as RetroTV).is_muted():
				col = COLOR_GLYPH_MUTE
		if not en:
			col = COLOR_GLYPH_DISABLED
		elif i == _selection:
			col = COLOR_GLYPH_SELECTED if col == COLOR_GLYPH else col
		label.modulate = col

	# Keep selection valid (target flipped a group off, or first build).
	if _selection < 0 or _selection >= _cells.size() or not bool(_cells[_selection]["enabled"]):
		_selection = _first_enabled()
	_refresh_highlight()


## True when the target is actively playing (not stopped, not paused).
func _target_playing() -> bool:
	if not is_instance_valid(_target):
		return false
	if not bool(_target.get("is_playing")):
		return false
	if _target.has_method("is_paused"):
		return not bool(_target.call("is_paused"))
	return true


func _first_enabled() -> int:
	for i in _cells.size():
		if bool(_cells[i]["enabled"]):
			return i
	return -1


func _refresh_highlight() -> void:
	if _selection < 0 or _selection >= _cells.size():
		_hilite.visible = false
		return
	var cell: Dictionary = _cells[_selection]
	var span := float(cell["span"])
	(_hilite.mesh as QuadMesh).size = Vector2(_cell_width(span) + 0.005, CELL_H + 0.005)
	_hilite.position = _cell_center(float(cell["col"]), int(cell["row"]), span) + Vector3(0, 0, 0.0016)
	_hilite.visible = true


# ── Selection input ───────────────────────────────────────────────────────────

func _process_vr_selection() -> void:
	var ctrl := _holding_ctrl
	var v := ctrl.get_vector2("primary")
	if _stick_latched:
		if v.length() < STICK_REARM:
			_stick_latched = false
	elif absf(v.y) >= absf(v.x):
		if v.y > STICK_STEP:
			_move_grid(0, -1); _stick_latched = true
		elif v.y < -STICK_STEP:
			_move_grid(0, 1); _stick_latched = true
	else:
		if v.x > STICK_STEP:
			_move_grid(1, 0); _stick_latched = true
		elif v.x < -STICK_STEP:
			_move_grid(-1, 0); _stick_latched = true

	var confirm := ctrl.get_float("ax_button") > 0.5 or ctrl.get_float("primary_click") > 0.5
	if confirm and not _prev_confirm:
		_activate_selected()
	_prev_confirm = confirm


## Move the highlight to the nearest enabled cell in the given grid direction
## (dcol/drow ∈ {-1,0,1}); no-op if there's no enabled cell that way.
func _move_grid(dcol: int, drow: int) -> void:
	if _selection < 0 or _selection >= _cells.size():
		_selection = _first_enabled()
		_refresh_highlight()
		return
	var cur: Dictionary = _cells[_selection]
	var best := -1
	var best_score := INF
	for i in _cells.size():
		if i == _selection or not bool(_cells[i]["enabled"]):
			continue
		var c: Dictionary = _cells[i]
		var ddc := float(c["cx"]) - float(cur["cx"])
		var ddr := float(c["row"]) - float(cur["row"])
		if drow < 0 and ddr >= 0.0: continue
		if drow > 0 and ddr <= 0.0: continue
		if dcol < 0 and ddc >= 0.0: continue
		if dcol > 0 and ddc <= 0.0: continue
		# Left/right never leaves the row. A cell spanning the full width (Menu,
		# Eject) therefore has no horizontal neighbour at all — reach the row below
		# it with down, not by sliding sideways into it.
		if dcol != 0 and not is_zero_approx(ddr):
			continue
		var score := 0.0
		if drow != 0:
			score = absf(ddr) * 10.0 + absf(ddc)   # nearest row, then nearest column
		else:
			score = absf(ddc)
		if score < best_score:
			best_score = score
			best = i
	if best >= 0:
		_selection = best
		_refresh_highlight()


## Desktop: arrow keys move the highlight, Enter activates (left-click is already
## taken by desktop_pickup's drop).
func _unhandled_input(event: InputEvent) -> void:
	if not _desktop_held or _target == null:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.physical_keycode:
		KEY_UP:
			_move_grid(0, -1); get_viewport().set_input_as_handled()
		KEY_DOWN:
			_move_grid(0, 1); get_viewport().set_input_as_handled()
		KEY_LEFT:
			_move_grid(-1, 0); get_viewport().set_input_as_handled()
		KEY_RIGHT:
			_move_grid(1, 0); get_viewport().set_input_as_handled()
		KEY_ENTER, KEY_KP_ENTER:
			_activate_selected(); get_viewport().set_input_as_handled()


func _activate_selected() -> void:
	if _selection < 0 or _selection >= _cells.size() or not is_instance_valid(_target):
		return
	var cell: Dictionary = _cells[_selection]
	if not bool(cell["enabled"]):
		return
	_activate(str(cell["id"]))
	# Power/mute/play-pause state may have changed — refresh glyphs/tints.
	_refresh_states()


## A single Play/Pause cell: pause if actively playing, else (re)start playback.
func _toggle_playpause(p: Node) -> void:
	if _target_playing():
		p.call("remote_pause")
	else:
		p.call("remote_play")


func _activate(id: String) -> void:
	if _target is RetroTV:
		var tv := _target as RetroTV
		match id:
			"power": tv.remote_power_toggle()
			"vol_up": tv.remote_volume_up()
			"vol_down": tv.remote_volume_down()
			"mute": tv.remote_mute_toggle()
			"audio_mode": tv.set_audio_mode((tv.audio_mode + 1) % 3)
			"stereo3d": tv.set_stereo_mode((tv.stereo_mode + 1) % 3)
			"aspect": tv.toggle_aspect()
			"source": tv.remote_source_cycle()
			"ch_up": tv.remote_channel_up()
			"ch_down": tv.remote_channel_down()
	elif _target is VCRPlayer:
		var vcr := _target as VCRPlayer
		match id:
			"eject": vcr.remote_eject()
			"playpause": _toggle_playpause(vcr)
			"stop": vcr.remote_stop()
			"rew": vcr.remote_rewind()
			"ff": vcr.remote_ff()
	elif _target is RetroAudioPlayer:
		var ap := _target as RetroAudioPlayer
		match id:
			"playpause": _toggle_playpause(ap)
			"stop": ap.remote_stop()
			"rew": ap.remote_rewind()
			"ff": ap.remote_ff()
			"prev": ap.remote_prev()
			"next": ap.remote_next()
	elif _target is DVDPlayer:
		var dvd := _target as DVDPlayer
		match id:
			"eject": dvd.remote_eject()
			"up": dvd.dvd_menu_up()
			"down": dvd.dvd_menu_down()
			"left": dvd.dvd_menu_left()
			"right": dvd.dvd_menu_right()
			"ok": dvd.dvd_ok()
			"menu": dvd.dvd_root_menu()
			"prev_ch": dvd.dvd_prev_chapter()
			"next_ch": dvd.dvd_next_chapter()
			"playpause": _toggle_playpause(dvd)
			"rew": dvd.remote_rewind()
			"ff": dvd.remote_ff()
			"stop": dvd.remote_stop()
			"audio": dvd.dvd_cycle_audio()
			"subtitle": dvd.dvd_cycle_subtitle()


# ── Menu transform ────────────────────────────────────────────────────────────

## Position the menu. VR: float above the remote and billboard to the camera.
## Desktop: fixed camera-local anchor (the remote is FPS-snapped to the camera, so
## anchoring to it would make the menu wander as the player looks around).
func _update_menu_transform() -> void:
	if _menu == null or not _menu.visible:
		return
	var cam := get_viewport().get_camera_3d()

	if _desktop_held:
		if is_instance_valid(cam):
			_menu.global_transform = Transform3D(
				cam.global_transform.basis,
				cam.global_transform * DESKTOP_MENU_OFFSET)
		return

	_menu.global_position = global_position + Vector3(0, FLOAT_HEIGHT, 0)
	_menu.scale = Vector3.ONE * VR_MENU_SCALE
	if is_instance_valid(cam):
		var to_cam := cam.global_position - _menu.global_position
		to_cam.y = 0.0
		if to_cam.length_squared() > 0.0001:
			_menu.look_at(cam.global_position, Vector3.UP)
			_menu.rotate_object_local(Vector3.UP, PI)


## Per-instance owner for the desktop channel. Several objects share the
## "retro_hold" key on the VR channels, so whichever updated last would otherwise
## clear a block another object still wants.
func _desktop_block_owner() -> StringName:
	return StringName("desktop_hold_%d" % get_instance_id())

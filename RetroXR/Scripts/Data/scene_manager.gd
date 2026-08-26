## SceneManager — Autoload that tracks the active scene and handles transitions.
##
## Coordinates with ScenePersistence to auto-save arcade state when switching
## scenes (if auto_save_on_switch is enabled).
extends Node


signal scene_changed(scene_id: String)
## A room is built, current, and standing on its own — the point at which things
## that need the finished tree (the arcade's slot auto-load, anything reading
## current_scene) can run. scene_changed fires much earlier, when the id is
## claimed and the old room is still up.
signal scene_ready(scene_id: String)
## The room's saved objects have also finished restoring (or were deliberately
## skipped on a multiplayer client). Systems that snapshot world contents use
## this later boundary rather than scene_ready.
signal scene_content_ready(scene_id: String)
signal active_slot_changed(slot_id: String)

const SCENE_PATHS := {
	"arcade":      "res://Scenes/MainScene.tscn",
	"den":         "res://Scenes/DenScene.tscn",
	"bedroom":     "res://Scenes/BedroomScene.tscn",
	"passthrough": "res://Scenes/PassthroughScene.tscn",
	"test":        "res://Scenes/TestScene.tscn",
}
## Shown on the loading screen while each scene builds.
const SCENE_TITLES := {
	"arcade":      "ARCADE ROOM",
	"den":         "COZY DEN",
	"bedroom":     "90s BEDROOM",
	"passthrough": "PASSTHROUGH",
	"test":        "TEST HALLWAY",
}
## Rooms that keep save slots — the ones you furnish yourself, where everything
## arrived from the spawn menu and a slot is therefore the whole room. The den and
## the test hallway are authored: their contents are in the .tscn, and a slot of
## what was spawned on top would restore a handful of objects into a room that
## already has its own.
##
## The bedroom was in that second group until it was emptied. It ships as bare
## walls now — window, blinds, door, light switch and the day/night lever, and
## nothing standing on the floor — so it is the home room you furnish, and the
## objection above no longer applies to it.
const SLOT_ROOMS := ["arcade", "passthrough", "bedroom"]
const PREFS_FILE := "user://scenes/prefs.json"
const LOADING_RIG_SCENE := preload("res://Scenes/UI/loading_rig.tscn")
## Every room instances res://Scenes/player_rig.tscn under this name.
const PLAYER_RIG_NAME := "PlayerRig"
const ORIGIN_PATH := "Staging/XROrigin3D"

var current_scene_id: String = "bedroom"
var auto_save_on_switch: bool = true

## room id -> the slot that room is currently standing on. Absent means "clean".
## Per room because the slots are: see ScenePersistence.
var active_slots: Dictionary = {}

## The current room's active slot. Kept as a property so that reading or setting
## "the active slot" without naming a room still means the room you are in.
## Assigning writes the entry and nothing else — persisting and announcing is
## set_active_slot's job, so a probe pointing this at a scratch id cannot leave
## the real game's prefs behind it.
var active_slot_id: String:
	get:
		return active_slot(current_scene_id)
	set(value):
		active_slots[current_scene_id] = value

## Set by NetworkManager around host-driven scene switches so the client
## guard in change_scene() doesn't block them.
var net_scene_override: bool = false

## Seconds since the last periodic autosave of the current room. Reset whenever a
## room finishes restoring, so an interval is always measured from a settled room
## rather than from whenever the last one happened to fire.
var _autosave_accum: float = 0.0

var _transitioning: bool = false
## Last valid request received while a transition is running. Only the newest
## destination matters; it starts after the current room is fully installed.
var _pending_scene_id: String = ""
var _content_ready_scene_id: String = ""
## The rig and player survive a failed load so retrying (or choosing another
## room) cannot strand one player on the root and create a second one.
var _parked_player: PlayerRig = null
var _failed_loading_rig: LoadingRig = null
var _last_load_failed: bool = false


func _ready() -> void:
	load_prefs()
	# Cold boot has no LoadingRig — the engine loads the room directly — so the
	# curtain is claimed here, before anything expensive starts. Both owners are
	# registered together so the warm finishing first cannot flash the room at a
	# restore that has not registered yet.
	if has_node("/root/LoadingOverlay"):
		LoadingOverlay.begin(&"boot_warm", "STARTING UP", 1.0)
		if room_has_slots(current_scene_id) and active_slot(current_scene_id) != "clean":
			# Weighted heavier because it is the phase the player actually notices:
			# the warm is invisible, the restore is their room arriving.
			LoadingOverlay.begin(&"boot_restore", "STARTING UP", 2.0)
	_warm_models.call_deferred()
	scene_content_ready.connect(func(_id: String) -> void: _autosave_accum = 0.0)


## Periodic autosave of the room being played. The gates are the same ones
## _begin_transition uses, for the same reasons — in particular a room whose own
## restore has not finished must never be written back, or it saves as the empty
## room it is halfway through becoming.
func _process(delta: float) -> void:
	if not AppPrefs.autosave_periodic:
		return
	var room := current_scene_id
	if not room_has_slots(room) or not is_scene_content_ready(room):
		return
	# The shared world belongs to the host; a client saving it would write the
	# host's room into the client's own slot.
	if has_node("/root/NetworkManager") and NetworkManager.is_client():
		return
	_autosave_accum += delta
	if _autosave_accum < AppPrefs.autosave_interval:
		return
	_autosave_accum = 0.0
	_autosave_now(room)


## Clean Room is readonly, so an autosave with no slot of its own has nowhere to
## go. Rather than doing nothing forever behind an enabled switch, give it one:
## Clean Room is left untouched and the new slot appears in the slot grid like
## any other, so the player can see what has been happening and rename it.
func _autosave_now(room: String) -> void:
	var persistence := ScenePersistence.new(room)
	var slot := active_slot(room)
	if slot == "clean":
		slot = persistence.create_new_slot(get_tree().current_scene, "Autosave")
		set_active_slot(slot, room)
		return
	persistence.autosave_slot(get_tree().current_scene, slot)


## A deferred autosave write lives on a worker thread, and the process exiting
## (or Android freezing the app) out from under one leaves a truncated slot file
## that reads back as an unloadable room. Waiting is the whole fix; it is a few
## milliseconds at worst and usually nothing at all.
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_EXIT_TREE:
			ScenePersistence.flush_pending_writes()


func load_prefs() -> void:
	if not FileAccess.file_exists(PREFS_FILE):
		return
	var f := FileAccess.open(PREFS_FILE, FileAccess.READ)
	if not f:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary:
		return
	var data := parsed as Dictionary
	# last_slot_id is the single-room form this file used to take, and it was
	# always the arcade's. Read so an existing install comes back to its own room
	# rather than to a clean one.
	var legacy: String = data.get("last_slot_id", "")
	if not legacy.is_empty():
		active_slots["arcade"] = legacy
	var slots: Variant = data.get("slots", {})
	if slots is Dictionary:
		for room: Variant in (slots as Dictionary):
			active_slots[str(room)] = str((slots as Dictionary)[room])


func save_prefs() -> void:
	DirAccess.make_dir_recursive_absolute("user://scenes")
	var f := FileAccess.open(PREFS_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"slots": active_slots}))


## The slot `room_id` is standing on, "clean" if it has never been given one.
func active_slot(room_id: String) -> String:
	return str(active_slots.get(room_id, "clean"))


## Whether a room keeps save slots at all.
func room_has_slots(scene_id: String) -> bool:
	return scene_id in SLOT_ROOMS


## True only when `room_id` names a live room that can safely be read or saved.
## current_scene_id names the requested destination immediately, while the old
## room is still present and while the loading rig temporarily leaves no current
## scene at all, so comparing that id alone is not a readiness check.
func is_room_ready(room_id: String) -> bool:
	return not _transitioning and current_scene_id == room_id \
		and get_tree().current_scene != null


func is_scene_content_ready(scene_id: String) -> bool:
	return is_room_ready(scene_id) and _content_ready_scene_id == scene_id


## Called by the carried SpawnMenuController after any slot restore completes.
## Ignore stale completions from a room that was left while its restore yielded.
func notify_scene_content_ready(scene_id: String) -> void:
	if not is_room_ready(scene_id):
		return
	_content_ready_scene_id = scene_id
	# Ended here rather than from a scene_content_ready listener: this boundary
	# has several listeners now, and which of them ran first would otherwise
	# decide whether the curtain was still up when they looked. Only one of these
	# two is ever registered; end() ignores the other.
	if has_node("/root/LoadingOverlay"):
		LoadingOverlay.end(&"boot_restore")
		LoadingOverlay.end(&"transition")
	scene_content_ready.emit(scene_id)


func set_active_slot(slot_id: String, room_id: String = current_scene_id) -> void:
	active_slots[room_id] = slot_id
	save_prefs()
	active_slot_changed.emit(slot_id)


func is_passthrough_supported() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	if xr == null:
		return false
	return XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in xr.get_supported_environment_blend_modes()


func change_scene(scene_id: String) -> void:
	if not SCENE_PATHS.has(scene_id):
		push_error("SceneManager: unknown scene_id '%s'" % scene_id)
		return
	if scene_id == "passthrough" and not is_passthrough_supported():
		push_warning("SceneManager: passthrough not supported on this device")
		return

	# In a session only the host decides scenes; clients follow via the network.
	var net_client: bool = has_node("/root/NetworkManager") and NetworkManager.is_client()
	if net_client and not net_scene_override:
		push_warning("SceneManager: only the host can change scenes during a session")
		return
	# Last intent wins. Asking for the room already in flight also cancels a
	# different destination that may have been queued after it.
	if _same_scene_request_is_noop(scene_id):
		_pending_scene_id = ""
		return
	if _transitioning:
		_pending_scene_id = scene_id
		return

	_begin_transition(scene_id, net_client)


## A failed destination is not the room the player is in: there is no current
## scene at all. Treating it as the normal same-room no-op made Retry inert.
func _same_scene_request_is_noop(scene_id: String) -> bool:
	return scene_id == current_scene_id and not _last_load_failed


## Claim a validated transition synchronously. The worker is deferred so a menu
## button inside the outgoing room can unwind safely, but no second caller gets
## a window in which it can start another worker or rewrite this one's identity.
func _begin_transition(scene_id: String, net_client: bool = false) -> void:
	# Read before the two flags below move, because both feed the answer.
	var leaving := current_scene_id
	var leaving_restored := is_scene_content_ready(leaving)
	_transitioning = true
	_last_load_failed = false
	_content_ready_scene_id = ""

	# Auto-save the room being left, into its own slot (skip if clean — it's
	# readonly; skip on clients — the shared world is the host's, not ours to save).
	#
	# Only a room whose own restore FINISHED may be written back. A queued
	# destination starts the moment scene_ready returns, and the arriving room's
	# restore is still suspended at that point: it has cleared the room and not yet
	# rebuilt it. Saving there put a 24-object arcade back as 1 object — the player
	# double-tapping a room card is all it takes. The manual Save button has been
	# gated on the same question (is_room_ready) since it was added.
	if room_has_slots(leaving) and auto_save_on_switch and active_slot(leaving) != "clean" \
			and not net_client and leaving_restored and get_tree().current_scene != null:
		var persistence := ScenePersistence.new(leaving)
		persistence.save_slot(get_tree().current_scene, active_slot(leaving))

	current_scene_id = scene_id
	_run_transition.call_deferred(scene_id, SCENE_PATHS[scene_id],
		SCENE_TITLES.get(scene_id, ""))
	scene_changed.emit(scene_id)


## Swap scenes with a loading screen, freeing the outgoing scene BEFORE the
## incoming one is built.
##
## SceneTree.change_scene_to_file() instantiates the new scene while the old one
## is still live, so for one frame both worlds' nodes and every resource they
## reference are resident at once. Going from the arcade into a heavy room that
## way peaks at the sum of both, which is what the Quest cannot afford. Tearing
## down first costs a black gap, which is what the loading rig is for.
##
## The player's rig is carried across rather than rebuilt: building one costs
## ~380 ms of blocked main thread, and a blocked main thread in VR is a frozen
## headset. It steps out of the old room, waits on the root, and is spliced into
## the new one before that enters the tree. PlayerRig owns what the crossing does
## to it; this only decides when.
func _run_transition(scene_id: String, path: String, title: String) -> void:
	var tree := get_tree()

	# All of this runs in one deferred call: the room leaves and the loading
	# screen arrives without a frame drawn in between.
	var outgoing := tree.current_scene
	var player := _player_for_transition(outgoing)
	if outgoing != null:
		tree.current_scene = null
		tree.root.remove_child(outgoing)
		outgoing.queue_free()

	_clear_failed_loading_rig()
	var rig: LoadingRig = LOADING_RIG_SCENE.instantiate()
	rig.prepare_for_player(player)
	tree.root.add_child(rig)
	rig.set_title("LOADING  %s" % title if not title.is_empty() else "LOADING")

	# Two frames: one for queue_free to run, one for the freed resources to drop
	# out of the cache before the next scene starts pulling its own in.
	await tree.process_frame
	await tree.process_frame
	rig.set_progress(0.05)

	var request_error := ResourceLoader.load_threaded_request(path)
	if request_error != OK:
		_fail_transition(rig, path, "request error %d" % request_error)
		return
	var progress: Array = []
	while true:
		var status := ResourceLoader.load_threaded_get_status(path, progress)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			break
		if status != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			# Nothing to go back to — the old room is already gone. Leave the
			# player parked on the root: they keep head tracking and the menu
			# (a child of the player rig) still works, so another room can be picked.
			_fail_transition(rig, path, "loader status %d" % status)
			return
		if not progress.is_empty():
			# Resource loading is most of the work, but scene instantiation still
			# happens afterward on the main thread. Reserve the last ten percent so
			# the bar never claims completion before that blocking step.
			rig.set_progress(0.05 + 0.85 * float(progress[0]))
		await tree.process_frame
	rig.set_progress(0.9)
	await tree.process_frame

	var loaded := ResourceLoader.load_threaded_get(path)
	var packed := loaded as PackedScene
	if packed == null:
		_fail_transition(rig, path, "resource is not a PackedScene")
		return
	var incoming: Node = packed.instantiate()
	# Make READY observable rather than setting it and removing the rig in the
	# same frame. The carried player is still on the root and tracking throughout.
	rig.set_progress(1.0)
	await tree.process_frame
	if player != null:
		_seat_player_rig(incoming, player)
		_parked_player = null
	# The rig has to be out of the tree BEFORE the incoming scene enters, not just
	# switched off. Its WorldEnvironment would otherwise be the one the new room
	# has to displace, and in the no-player fallback its camera holds the viewport:
	# a Camera3D claims the viewport on entry only while none is registered at all,
	# so a rig camera still sitting there — even with current = false — leaves the
	# new scene's XRCamera3D unclaimed and the view grey.
	tree.root.remove_child(rig)
	rig.queue_free()
	tree.root.add_child(incoming)
	tree.current_scene = incoming
	if player != null:
		player.enter_world()
	# Hand the curtain from the rig — which had to leave, it owns a
	# WorldEnvironment — to a panel on the player's own rig, in this same frame.
	# Otherwise the room is on screen and empty while its objects are still being
	# spawned, which is the pop-in this whole thing exists to hide.
	#
	# After enter_world(), because the panel is parented to the seated PlayerRig;
	# before scene_ready, because a listener starts the restore synchronously.
	if has_node("/root/LoadingOverlay"):
		LoadingOverlay.resume()
		LoadingOverlay.begin(&"transition", "LOADING  %s" % title, 1.0)
		LoadingOverlay.set_phase(&"transition", "RESTORING OBJECTS", 0.0)
	# Keep the transition claimed while listeners run. If one of them requests
	# another room it is coalesced, rather than re-entering this coroutine while
	# it is still returning from the ready signal.
	scene_ready.emit(scene_id)
	_finish_transition()


## Keep the error panel and the carried player alive. The spawn menu belongs to
## the player, so it remains available for Retry or for choosing a different room.
func _fail_transition(rig: LoadingRig, path: String, reason: String) -> void:
	push_error("SceneManager: failed to load '%s' (%s)" % [path, reason])
	_last_load_failed = true
	_failed_loading_rig = rig
	# The rig stays up showing the error; a second panel behind it would be wrong,
	# and nothing resumed the overlay on this path.
	if has_node("/root/LoadingOverlay"):
		LoadingOverlay.end(&"transition")
	rig.show_load_error()
	_finish_transition()


func _clear_failed_loading_rig() -> void:
	if not is_instance_valid(_failed_loading_rig):
		_failed_loading_rig = null
		return
	var parent := _failed_loading_rig.get_parent()
	if parent != null:
		parent.remove_child(_failed_loading_rig)
	_failed_loading_rig.queue_free()
	_failed_loading_rig = null


func _finish_transition() -> void:
	_transitioning = false
	var next := _pending_scene_id
	_pending_scene_id = ""
	if not next.is_empty() and next != current_scene_id:
		# Authorization and platform support were checked when it was queued. In
		# particular, a client's one-call net_scene_override has already gone away.
		_begin_transition(next, has_node("/root/NetworkManager") and NetworkManager.is_client())


## Take the player out of the outgoing room and park them on the root so they
## survive the teardown. Null if the room has no rig — a probe scene, or one that
## never had one — in which case the loading rig brings its own camera.
func _take_player_rig(outgoing: Node) -> PlayerRig:
	if outgoing == null:
		return null
	var player := outgoing.get_node_or_null(PLAYER_RIG_NAME) as PlayerRig
	if player == null:
		return null
	player.leave_world()
	outgoing.remove_child(player)
	get_tree().root.add_child(player)
	return player


## Recover the player parked by a failed attempt when there is no outgoing room
## left to take it from. This is what prevents duplicate players/origins/cameras
## on the next attempt.
func _player_for_transition(outgoing: Node) -> PlayerRig:
	var player := _take_player_rig(outgoing)
	if player != null:
		_parked_player = player
	elif is_instance_valid(_parked_player):
		player = _parked_player
	else:
		_parked_player = null
	return player


## Splice the carried rig into the incoming room in place of the one the room
## authored, before any of it enters the tree — so the room's own rig never runs
## a single _ready().
func _seat_player_rig(incoming: Node, player: PlayerRig) -> void:
	var index := -1
	var authored := incoming.get_node_or_null(PLAYER_RIG_NAME) as PlayerRig
	if authored != null:
		index = authored.get_index()
		player.place_at(authored.transform, authored.get_node(ORIGIN_PATH).transform)
		incoming.remove_child(authored)
		authored.free()
	player.get_parent().remove_child(player)
	incoming.add_child(player)
	if index >= 0:
		incoming.move_child(player, index)


## Pay every model's first-spawn cost once, at startup, instead of the first
## time a player reaches for one. Measured on a Quest 3: 3.9 s for a single cold
## spawn of the 3DS stand-in, 6.9 s of blocked main thread for the NES shell.
##
## Deferred past the first frames so the room is up and drawing first. The order
## matters: the shell GLBs' threaded requests fire before anything else, because
## they are what a menu spawn or a slot restore has to wait for
## (ModelWarmer.acquire) and starting them costs the main thread nothing. The
## stand-in warm then runs on the main thread while those loads ride the loader
## threads, and warm_shells finds its GLBs mostly arrived.
func _warm_models() -> void:
	for i in 4:
		await get_tree().process_frame
	ModelWarmer.request_shells()
	await ModelWarmer.warm_stand_ins(self)
	# The curtain lifts here, not after warm_shells. The shells cost ~7 s and only
	# make FUTURE spawns cheap — nothing on screen at boot is waiting on them, and
	# holding the room back for it would turn a short boot into a long black one.
	# The stand-ins are what a slot restore actually instantiates.
	if has_node("/root/LoadingOverlay"):
		LoadingOverlay.end(&"boot_warm")
	await ModelWarmer.warm_shells(self)

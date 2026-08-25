## ScenePersistence — saves and restores dynamically-spawned objects for one room.
## Objects must be in the "spawned" group to be tracked.
##
## Save directory: user://scenes/{room}/
## Manifest:       user://scenes/{room}/manifest.json
## Slot files:     user://scenes/{room}/{id}.json
##
## Each room keeps its own slots and its own manifest. They cannot be one set: a
## slot is a list of world poses, and the arcade's are struck against the arcade's
## furniture — restoring them into passthrough would rain a room's contents into
## wherever the player happens to be standing. The room is a constructor argument
## rather than a parameter on every call because one instance is only ever used
## against one room, and SceneManager.room_has_slots decides which rooms keep them.
class_name ScenePersistence
extends RefCounted


const ROOMS_DIR     := "user://scenes"
const DEFAULT_ROOM  := "arcade"
## The arcade's own directory, named because the save/restore probes reach for it.
const ARCADE_DIR    := "user://scenes/arcade"
const VERSION       := 2
## How long the async restore may hold the main thread before yielding a frame.
const FRAME_BUDGET_USEC := 4000

const _STRING_FIELDS := [
	"systemid", "model_id", "tv_model", "rom_path", "game_label", "save_id",
	"cart_systemid", "card_id", "card_label", "pdf_path", "scene", "video_path",
	"video_label", "dvd_path", "dvd_label", "album_path", "album_label", "kind",
	"pad_guid", "pad_name", "image_path",
]
const _NUMBER_FIELDS := [
	"lid_angle", "scale_factor", "stereo_mode", "size_scale", "page_state",
	"page_leaf", "sensitivity", "device_type", "port_index", "volume", "cords",
	"pad_ordinal", "fit_mode", "roll",
]
const _BOOL_FIELDS := ["video_out", "ignore_gravity", "crt_enabled", "half_pages", "stuck"]
const _REFERENCE_FIELDS := [
	"tv", "cartridge", "memcard", "tape", "disc", "media", "system",
	"nunchuk", "motion_plus",
]
const _SPECIALIZED_TYPES := [
	"system", "tv", "cartridge", "disc", "memory_card", "book",
	"retro_controller", "retro_mouse", "snes_mouse", "vcr_tape", "dvd_disc",
	"composite_cable", "audio_disc", "audio_cassette",
	"pad_receiver", "keyboard_receiver", "mouse_receiver", "poster",
]

## Bumped by every async restore as it starts. Because those yield frames, a
## second one can begin — a room change auto-loading a slot on top of a slot the
## player picked from the menu — and the two then build into the same room while
## clear_scene() frees what the other just spawned, leaving live systems holding
## freed cable plugs. The older run checks this after each yield and stands down.
static var _restore_generation := 0

const SYSTEM_SCENE           := preload("res://Scenes/Objects/system.tscn")
const TV_SCENE               := preload("res://Scenes/Objects/tv.tscn")
const CART_SCENE             := preload("res://Scenes/Objects/media/cartridge.tscn")
const DISC_SCENE             := preload("res://Scenes/Objects/media/disc.tscn")
const UMD_DISC_SCENE         := preload("res://Scenes/Objects/media/umd_disc.tscn")
const MEMCARD_SCENE          := preload("res://Scenes/Objects/media/memory_card.tscn")
const GC_MEMCARD_SCENE       := preload("res://Scenes/Objects/media/gc_memory_card.tscn")
const BOOK_SCENE             := preload("res://Scenes/Objects/media/pdf_book.tscn")
const POSTER_SCENE           := preload("res://Scenes/Objects/media/poster.tscn")
const RETRO_CONTROLLER_SCENE := preload("res://Scenes/Objects/controllers/retro_controller.tscn")
const LIGHT_GUN_SCENE        := preload("res://Scenes/Objects/peripherals/light_gun.tscn")
const VCR_SCENE              := preload("res://Scenes/Objects/appliances/vcr_player.tscn")
const TAPE_SCENE             := preload("res://Scenes/Objects/media/vcr_tape.tscn")
const DVD_SCENE              := preload("res://Scenes/Objects/appliances/dvd_player.tscn")
const DVD_DISC_SCENE         := preload("res://Scenes/Objects/media/dvd_disc.tscn")
const CD_PLAYER_SCENE        := preload("res://Scenes/Objects/appliances/cd_player.tscn")
const CASSETTE_PLAYER_SCENE  := preload("res://Scenes/Objects/appliances/cassette_player.tscn")
const AUDIO_DISC_SCENE       := preload("res://Scenes/Objects/media/audio_disc.tscn")
const AUDIO_CASSETTE_SCENE   := preload("res://Scenes/Objects/media/audio_cassette.tscn")
const TV_REMOTE_SCENE        := preload("res://Scenes/Objects/appliances/tv_remote.tscn")
const COMPOSITE_CABLE_SCENE  := preload("res://Scenes/Objects/cables/composite_cable.tscn")
const MONO_CABLE_SCENE       := preload("res://Scenes/Objects/cables/mono_composite_cable.tscn")
const WII_AV_CABLE_SCENE     := preload("res://Scenes/Objects/system_models/wii/wii_av_cable.tscn")
const VGA_CABLE_SCENE        := preload("res://Scenes/Objects/cables/vga_cable.tscn")
const TRS_CABLE_SCENE        := preload("res://Scenes/Objects/cables/trs_cable.tscn")
const LINK_CABLE_SCENE       := preload("res://Scenes/Objects/cables/link_cable.tscn")
const GB_LINK_CABLE_SCENE    := preload("res://Scenes/Objects/cables/gb_link_cable.tscn")
const GC_GBA_CABLE_SCENE     := preload("res://Scenes/Objects/cables/gc_gba_cable.tscn")
const PSX_LINK_CABLE_SCENE   := preload("res://Scenes/Objects/cables/psx_link_cable.tscn")
const SPEAKER_PAIR_SCENE     := preload("res://Scenes/Objects/appliances/speaker_pair.tscn")
const TRASH_CAN_SCENE        := preload("res://Scenes/Objects/appliances/trash_can.tscn")
const TABLE_SCENE            := preload("res://Scenes/Objects/furniture/table.tscn")
const RETRO_MOUSE_SCENE      := preload("res://Scenes/Objects/peripherals/retro_mouse.tscn")
const SNES_MOUSE_SCENE       := preload("res://Scenes/Objects/peripherals/snes_mouse.tscn")
const RETRO_KEYBOARD_SCENE   := preload("res://Scenes/Objects/peripherals/retro_keyboard.tscn")
const WIIMOTE_SCENE          := preload("res://Scenes/Objects/controllers/wii/wiimote.tscn")
const NUNCHUK_SCENE          := preload("res://Scenes/Objects/controllers/wii/nunchuk.tscn")
const MOTION_PLUS_SCENE      := preload("res://Scenes/Objects/controllers/wii/motion_plus.tscn")
const SENSOR_BAR_SCENE       := preload("res://Scenes/Objects/system_models/wii/sensor_bar.tscn")
const RF_SWITCH_SCENE        := preload("res://Scenes/Objects/appliances/rf_switch.tscn")
const PAD_RECEIVER_SCENE     := preload("res://Scenes/Objects/controllers/pad_receiver.tscn")
const KEYBOARD_RECEIVER_SCENE := preload("res://Scenes/Objects/controllers/keyboard_receiver.tscn")
const MOUSE_RECEIVER_SCENE    := preload("res://Scenes/Objects/controllers/mouse_receiver.tscn")

## Types whose entry carries nothing but a pose — instantiate and place, no
## properties to apply. Types that need more are match arms in
## _deserialize_object().
const PLAIN_SCENES := {
	"tv_remote": TV_REMOTE_SCENE,
	"trash_can": TRASH_CAN_SCENE,
	"table": TABLE_SCENE,
	"light_gun": LIGHT_GUN_SCENE,
	# Slots written before the rename say "ray_gun".
	"ray_gun": LIGHT_GUN_SCENE,
	"retro_keyboard": RETRO_KEYBOARD_SCENE,
	"vcr_player": VCR_SCENE,
	"dvd_player": DVD_SCENE,
	"cd_player": CD_PLAYER_SCENE,
	"cassette_player": CASSETTE_PLAYER_SCENE,
	# Both Wii objects instantiate from here; the remote's pairing and its seated
	# Nunchuk are applied afterwards by the peripheral arm of _apply_references,
	# exactly as the light gun's port connection is. The Nunchuk carries no port of
	# its own — it is wired to a remote, and that seating is restored from the
	# REMOTE's entry, not from this one.
	"wiimote": WIIMOTE_SCENE,
	"nunchuk": NUNCHUK_SCENE,
	# Same arrangement for the dongle: a pose here, and the fact that it is seated
	# in a particular remote restored from the REMOTE's entry.
	"motion_plus": MOTION_PLUS_SCENE,
	# The bar's own entry is a pose; which console it is plugged into is applied
	# afterwards by _apply_references, like the remote's pairing.
	"sensor_bar": SENSOR_BAR_SCENE,
	# Instantiate-and-place here, with the volume and the two cabinet poses applied
	# afterwards by _restore_entry — the same split the sensor bar above uses. A
	# serialize branch and a restore branch both existed for the pair, but nothing
	# ever built one back: a saved room dropped its speakers with "unknown object
	# type 'speaker_pair'", which also left any lead plugged into them with nothing
	# to seat into.
	"speaker_pair": SPEAKER_PAIR_SCENE,
}


## Which room's slots this instance reads and writes. Defaults to the arcade so
## that the callers which only serialize — netplay's object sync, the probes —
## need not name a room at all.
var room_id := DEFAULT_ROOM


func _init(room: String = DEFAULT_ROOM) -> void:
	if not room.is_empty():
		room_id = room


# ── Multi-slot public API ──────────────────────────────────────────────────────

## Returns ordered slot list. "clean" is always first and is never stored in the
## manifest — it is prepended here.
func get_slots() -> Array[Dictionary]:
	var m := _load_manifest()
	var result: Array[Dictionary] = [{"id": "clean", "name": "Clean Room", "readonly": true}]
	for s: Variant in m.get("slots", []):
		result.append(s as Dictionary)
	return result


## Save current scene state to the named slot. Returns false on I/O error.
func save_slot(root: Node, slot_id: String) -> bool:
	if slot_id == "clean":
		return false
	DirAccess.make_dir_recursive_absolute(slot_dir())
	return _write_scene_to_file(root, _slot_file(slot_id))


## Save without the frame hitch, for the periodic autosave.
##
## Profiled over a 27-object arcade: the walk is 0.46 ms but encoding and writing
## are 4.6 ms, and the write alone swings to 7 ms — half a frame at 90 Hz, gone.
## Only the walk has to see the live tree, so it stays here and the rest goes to a
## worker. Returns false if nothing was dispatched (unchanged, or a bad slot).
##
## An idle room re-encodes to the identical 17 KB every interval, so an unchanged
## payload is dropped rather than written: the point of the interval is to catch
## changes, not to keep rewriting a room nobody touched.
func autosave_slot(root: Node, slot_id: String) -> bool:
	if slot_id == "clean":
		return false
	var path := _slot_file(slot_id)
	var text := _encode(_snapshot(root))
	var digest := text.sha256_text()
	if _last_digest.get(path, "") == digest and FileAccess.file_exists(path):
		return false
	DirAccess.make_dir_recursive_absolute(slot_dir())
	_last_digest[path] = digest
	_dispatch_write(path, text)
	return true


# ── Deferred writes ───────────────────────────────────────────────────────────
#
# Statics, not instance state: callers build a ScenePersistence, save through it
# and drop it on the same line (see SceneManager._begin_transition), so an
# in-flight task outlives the object that started it.

## slot path -> sha256 of the payload last written there.
static var _last_digest: Dictionary = {}
## slot path -> WorkerThreadPool task id currently writing it.
static var _pending: Dictionary = {}


func _dispatch_write(path: String, text: String) -> void:
	# One writer per path. Waiting on the previous task is near-free in practice
	# (it has a whole interval's head start) and it is what stops two workers
	# interleaving store_string into the same file.
	_await_path(path)
	_pending[path] = WorkerThreadPool.add_task(
		func() -> void: _store_text(path, text), false, "scene autosave")


static func _await_path(path: String) -> void:
	if not _pending.has(path):
		return
	WorkerThreadPool.wait_for_task_completion(_pending[path])
	_pending.erase(path)


## Block until every deferred write has landed. Must be called before the app
## exits and before a slot file is read back, or a restore can race a half-written
## file. Cheap when nothing is outstanding.
static func flush_pending_writes() -> void:
	for path: Variant in _pending.keys():
		WorkerThreadPool.wait_for_task_completion(_pending[path])
	_pending.clear()


## Clear the scene then restore from the slot file, spread over frames — see
## instantiate_objects_async(). Loading "clean" just clears the scene.
##
## A coroutine: callers must await it, or they get a Signal back and the room
## fills in behind them.
func load_slot_async(root: Node, slot_id: String) -> bool:
	if slot_id == "clean":
		clear_scene(root)
		return true
	var path := _slot_file(slot_id)
	if not FileAccess.file_exists(path):
		push_warning("ScenePersistence: slot file not found '%s'" % path)
		return false
	var objects: Variant = _read_objects(path)
	if objects == null:
		return false
	# Do not dismantle the room until the replacement has passed every check we
	# can perform without instantiating it. A truncated or old slot must be a
	# failed load, not an implicit "Clean Room" action.
	clear_scene(root)
	# Before the objects: the room's own furniture is what everything else was
	# arranged around, and a lead restored into a television still standing in its
	# authored place would be laid out to the wrong end of the room.
	_restore_fixtures(root, _read_fixtures(path))
	var spawned: Dictionary = await instantiate_objects_async(root, objects)
	print("[ScenePersistence] loaded %d objects from '%s'" % [spawned.size(), path])
	return true


## Remove a slot from the manifest and delete its file.
func delete_slot(slot_id: String) -> bool:
	if slot_id == "clean":
		return false
	var m := _load_manifest()
	var new_slots: Array = []
	for s: Variant in m.get("slots", []):
		if (s as Dictionary).get("id", "") != slot_id:
			new_slots.append(s)
	m["slots"] = new_slots
	_save_manifest(m)
	var path := _slot_file(slot_id)
	# A worker still holding this path would recreate the file behind the delete.
	_await_path(path)
	_last_digest.erase(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return true


## Rename a slot in the manifest.
func rename_slot(slot_id: String, new_name: String) -> bool:
	if slot_id == "clean":
		return false
	var m := _load_manifest()
	var slots: Array = m.get("slots", [])
	for s: Variant in slots:
		var d := s as Dictionary
		if d.get("id", "") == slot_id:
			d["name"] = new_name
			m["slots"] = slots
			return _save_manifest(m)
	return false


## Save current scene to a brand-new slot and append it to the manifest.
## Returns the new slot id.
func create_new_slot(root: Node, name: String) -> String:
	DirAccess.make_dir_recursive_absolute(slot_dir())
	var slot_id := _generate_id()
	_write_scene_to_file(root, _slot_file(slot_id))
	var m := _load_manifest()
	var slots: Array = m.get("slots", [])
	slots.append({"id": slot_id, "name": name})
	m["slots"] = slots
	_save_manifest(m)
	return slot_id


## Free all dynamically-spawned objects.
func clear_scene(root: Node) -> void:
	var spawned := root.get_tree().get_nodes_in_group("spawned")

	# Pre-pass: drop cable/controller plugs while their snap-zones are still alive.
	# Cable instances are in "spawned".  Their plug child may be snapped into a
	# snap-zone.  Calling drop() clears _grab_driver before queue_free.
	for node: Node in spawned:
		# The captive A/V lead ends in three connectors, not one — the picture cord
		# plus the audio pair beside it — and any of them can be sitting in a socket.
		for plug_name: String in ["CablePlug", "CablePlugL", "CablePlugR", "ControllerPlug"]:
			var plug := node.get_node_or_null(plug_name)
			if plug and plug.has_method("drop"):
				plug.call("drop")

	# Main pass: power off and free everything.
	for node: Node in spawned:
		# Power off systems so the emulation thread shuts down cleanly.
		#
		# power_off(), not toggle_power(): the toggle is the POWER BUTTON's verb and
		# it answers to the session. In netplay it stops the lockstep game, or sends
		# the intent to the host, and returns in both cases WITHOUT stopping the core
		# in front of it — so tearing a room down mid-session made a network call and
		# then freed a machine that was still running. power_off is the local,
		# unconditional stop, which is the only thing a teardown ever means.
		if node is RetroSystem and (node as RetroSystem).is_powered_on:
			(node as RetroSystem).power_off()
		# drop_and_free() clears _grab_driver before queue_free, preventing a
		# use-after-free in XRToolsPickable._exit_tree when a snap-zone that
		# was "holding" this pickable gets freed first.
		if node.has_method("drop_and_free"):
			node.call("drop_and_free")
		else:
			node.queue_free()


# ── Private helpers ────────────────────────────────────────────────────────────

## Where this room's slots live.
func slot_dir() -> String:
	return "%s/%s" % [ROOMS_DIR, room_id]


func _manifest_file() -> String:
	return slot_dir() + "/manifest.json"


func _slot_file(slot_id: String) -> String:
	return slot_dir() + "/" + slot_id + ".json"


func _generate_id() -> String:
	return "%08x" % (randi() ^ Time.get_ticks_msec())


func _empty_manifest() -> Dictionary:
	return {"version": VERSION, "slots": []}


func _load_manifest() -> Dictionary:
	var path := _manifest_file()
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				return parsed as Dictionary
	return _empty_manifest()


func _save_manifest(m: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(slot_dir())
	var f := FileAccess.open(_manifest_file(), FileAccess.WRITE)
	if not f:
		push_error("ScenePersistence: cannot write manifest (err %d)" % FileAccess.get_open_error())
		return false
	f.store_string(JSON.stringify(m, "\t"))
	return true


func _write_scene_to_file(root: Node, path: String) -> bool:
	var snapshot := _snapshot(root)
	var objects: Array = snapshot["objects"]
	var text := _encode(snapshot)
	# An autosave of this same slot may still be in a worker; letting it land after
	# an explicit save would undo it.
	_await_path(path)
	if not _store_text(path, text):
		return false
	_last_digest[path] = text.sha256_text()
	print("[ScenePersistence] saved %d objects to '%s'" % [objects.size(), path])
	return true


## Walk the spawned set and serialize it. Main thread only: every entry reads live
## node state (global transforms, a TV's CRT params, a cable's seating).
func _collect_objects(root: Node) -> Array[Dictionary]:
	var nodes := root.get_tree().get_nodes_in_group("spawned")
	# The whole map has to exist before anything serializes: a reference can point
	# either way through the set.
	var node_to_id: Dictionary = {}
	for i in range(nodes.size()):
		node_to_id[nodes[i]] = i
	var objects: Array[Dictionary] = []
	for i in range(nodes.size()):
		var data := _serialize_node(nodes[i], i, node_to_id)
		if not data.is_empty():
			objects.append(data)
	return objects


## Everything a slot file holds, ready to encode.
func _snapshot(root: Node) -> Dictionary:
	var out := {"version": VERSION, "objects": _collect_objects(root)}
	var fixtures := _collect_fixtures(root)
	# Omitted entirely when the room has none, so a room without fixtures writes
	# the same bytes it always did.
	if not fixtures.is_empty():
		out["fixtures"] = fixtures
	return out


## Authored objects the player can move.
##
## The arcade's television is instanced by the room rather than spawned into it,
## so it is not in the "spawned" group and the object walk never sees it — but it
## is an XRToolsPickable and can be carried anywhere, and its position was simply
## lost. It cannot join "spawned" to fix that: clear_scene frees that whole group,
## and a slot load would delete the room's own television with nothing in the file
## to rebuild it.
##
## So fixtures are recorded separately and by PATH, and restoring one moves the
## node that is already there. Membership comes from the room's .tscn
## (groups=["fixture"]), which is what keeps a spawned television — same scene,
## no group — out of this list.
func _collect_fixtures(root: Node) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if root.get_tree() == null:
		return out
	for node: Node in root.get_tree().get_nodes_in_group("fixture"):
		var n3d := node as Node3D
		if n3d == null or not root.is_ancestor_of(n3d):
			continue
		var pos := n3d.global_position
		var rot := n3d.global_rotation_degrees
		var record := {
			"path": str(root.get_path_to(n3d)),
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
		# The set's selected input. A spawned television carries its whole control
		# state in its object entry; a fixture has no entry to carry one, so the
		# arcade's own set came back on Composite 1 however it was left.
		if n3d is RetroTV:
			record["source"] = (n3d as RetroTV).current_source
		out.append(record)
	return out


## Put the room's own movable furniture back where it was left. Absent from every
## slot written before fixtures existed, in which case the room keeps the pose its
## .tscn authored.
func _restore_fixtures(root: Node, fixtures: Variant) -> void:
	if not fixtures is Array:
		return
	for entry: Variant in fixtures as Array:
		if not entry is Dictionary:
			continue
		var d := entry as Dictionary
		var n3d := root.get_node_or_null(NodePath(str(d.get("path", "")))) as Node3D
		if n3d == null:
			# A room whose furniture was renamed or removed since the save.
			continue
		var pos: Array = d.get("position", [])
		var rot: Array = d.get("rotation", [])
		if pos.size() == 3:
			n3d.global_position = Vector3(pos[0], pos[1], pos[2])
		if rot.size() == 3:
			n3d.global_rotation_degrees = Vector3(rot[0], rot[1], rot[2])
		# Absent from a slot written before a set remembered its input, and from
		# every fixture that is furniture rather than a television. set_source
		# clamps and falls back on its own, so a cabinet that no longer carries
		# the saved input lands on one it does have.
		var source: Variant = d.get("source")
		if n3d is RetroTV and (source is float or source is int):
			(n3d as RetroTV).set_source(int(source))


func _encode(snapshot: Dictionary) -> String:
	return JSON.stringify(snapshot, "\t")


func _store_text(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		push_error("ScenePersistence: cannot write '%s' (err %d)" % [path, FileAccess.get_open_error()])
		return false
	f.store_string(text)
	return true


## The fixture entries of a slot file — an empty array for one written before
## fixtures existed, or for a room that has none.
func _read_fixtures(path: String) -> Variant:
	_await_path(path)
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary:
		return []
	return (parsed as Dictionary).get("fixtures", [])


## The object entries of a slot file, or null if it cannot be read.
func _read_objects(path: String) -> Variant:
	# Never read a file a worker is still writing — a truncated slot parses as an
	# invalid file and restores as an empty room.
	_await_path(path)
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary:
		push_error("ScenePersistence: invalid slot file '%s'" % path)
		return null
	var d := parsed as Dictionary
	# Refused rather than migrated. Every cross-reference changed shape in v2, so
	# a v1 file still restores its objects — into a room where nothing is plugged
	# into anything, which reads as a bug rather than as an old save.
	var file_version := int(d.get("version", 1))
	if file_version != VERSION:
		push_warning("ScenePersistence: slot '%s' is version %d, this build reads %d"
			% [path, file_version, VERSION])
		return null
	var objects: Variant = d.get("objects", [])
	if not objects is Array:
		push_error("ScenePersistence: slot '%s' has no object list" % path)
		return null
	var error := _objects_validation_error(objects as Array)
	if not error.is_empty():
		push_error("ScenePersistence: invalid slot '%s': %s" % [path, error])
		return null
	return objects


static func _objects_validation_error(objects: Array) -> String:
	var ids: Dictionary = {}
	for index in objects.size():
		var value: Variant = objects[index]
		if not value is Dictionary:
			return "object %d is not a dictionary" % index
		var entry := value as Dictionary
		var id_value: Variant = entry.get("id")
		if not _is_integer(id_value) or int(id_value) < 0:
			return "object %d has an invalid id" % index
		var id := int(id_value)
		if ids.has(id):
			return "object %d repeats id %d" % [index, id]
		ids[id] = true

	for index in objects.size():
		var entry := objects[index] as Dictionary
		var error := _entry_validation_error(entry, ids)
		if not error.is_empty():
			return "object %d: %s" % [index, error]
	return ""


static func _entry_validation_error(entry: Dictionary, ids: Dictionary) -> String:
	var obj_type_value: Variant = entry.get("type")
	if not obj_type_value is String:
		return "type is not a string"
	var obj_type := obj_type_value as String
	if not PLAIN_SCENES.has(obj_type) and obj_type not in _SPECIALIZED_TYPES:
		return "unknown type '%s'" % obj_type
	for field: String in ["position", "rotation"]:
		var pose_error := _vec3_validation_error(entry.get(field))
		if not pose_error.is_empty():
			return "%s %s" % [field, pose_error]
	for field: String in _STRING_FIELDS:
		if entry.has(field) and not entry[field] is String:
			return "%s is not a string" % field
	for field: String in _NUMBER_FIELDS:
		if entry.has(field) and not _is_finite_number(entry[field]):
			return "%s is not a finite number" % field
	for field: String in _BOOL_FIELDS:
		if entry.has(field) and not entry[field] is bool:
			return "%s is not a boolean" % field
	for field: String in _REFERENCE_FIELDS:
		if entry.has(field):
			var ref_error := _reference_validation_error(entry[field], ids)
			if not ref_error.is_empty():
				return "%s %s" % [field, ref_error]

	if entry.has("extra_tvs"):
		if not entry["extra_tvs"] is Array:
			return "extra_tvs is not an array"
		for ref: Variant in entry["extra_tvs"]:
			var ref_error := _reference_validation_error(ref, ids)
			if not ref_error.is_empty():
				return "extra_tvs member %s" % ref_error
	if entry.has("tv_inputs"):
		if not entry["tv_inputs"] is Array:
			return "tv_inputs is not an array"
		for input: Variant in entry["tv_inputs"]:
			if not _is_integer(input):
				return "tv_inputs contains a non-integer"
	if entry.has("crt_params"):
		if not entry["crt_params"] is Dictionary:
			return "crt_params is not a dictionary"
		for key: Variant in (entry["crt_params"] as Dictionary):
			if not key is String or not _is_finite_number(entry["crt_params"][key]):
				return "crt_params contains a non-numeric value"
	if entry.has("controls"):
		if not entry["controls"] is Dictionary:
			return "controls is not a dictionary"
		var controls := entry["controls"] as Dictionary
		for field: String in ["enabled", "muted", "widescreen"]:
			if controls.has(field) and not controls[field] is bool:
				return "controls.%s is not a boolean" % field
		if controls.has("volume") and not _is_finite_number(controls["volume"]):
			return "controls.volume is not a finite number"
		for field: String in ["source", "rf_channel", "channel_index", "audio_mode"]:
			if controls.has(field) and not _is_integer(controls[field]):
				return "controls.%s is not an integer" % field
	if entry.has("boxes"):
		var boxes_error := _pose_records_validation_error(entry["boxes"], ids, false)
		if not boxes_error.is_empty():
			return "boxes %s" % boxes_error
	if entry.has("plugs"):
		var plugs_error := _pose_records_validation_error(entry["plugs"], ids, true)
		if not plugs_error.is_empty():
			return "plugs %s" % plugs_error
	if entry.has("body"):
		if not entry["body"] is Dictionary:
			return "body is not a dictionary"
		for field: String in ["position", "rotation"]:
			var pose_error := _vec3_validation_error((entry["body"] as Dictionary).get(field))
			if not pose_error.is_empty():
				return "body %s %s" % [field, pose_error]
	return ""


static func _pose_records_validation_error(value: Variant, ids: Dictionary,
		validate_plug: bool) -> String:
	if not value is Array:
		return "is not an array"
	for index in (value as Array).size():
		var record_value: Variant = (value as Array)[index]
		if not record_value is Dictionary:
			return "member %d is not a dictionary" % index
		var record := record_value as Dictionary
		for field: String in ["position", "rotation"]:
			var pose_error := _vec3_validation_error(record.get(field))
			if not pose_error.is_empty():
				return "member %d %s %s" % [index, field, pose_error]
		if not validate_plug:
			continue
		for field: String in ["end", "cord"]:
			if not _is_integer(record.get(field)):
				return "member %d %s is not an integer" % [index, field]
		if record.has("port") and not record["port"] is String:
			return "member %d port is not a string" % index
		if record.has("device"):
			var ref_error := _reference_validation_error(record["device"], ids)
			if not ref_error.is_empty():
				return "member %d device %s" % [index, ref_error]
	return ""


static func _vec3_validation_error(value: Variant) -> String:
	if not value is Array or (value as Array).size() != 3:
		return "is not a three-component array"
	for component: Variant in value:
		if not _is_finite_number(component):
			return "contains a non-finite number"
	return ""


static func _reference_validation_error(value: Variant, ids: Dictionary) -> String:
	if value == null or value is String:
		return ""
	if not _is_integer(value) or int(value) < 0:
		return "is not a reference"
	return "" if ids.has(int(value)) else "references missing id %d" % int(value)


static func _is_integer(value: Variant) -> bool:
	return _is_finite_number(value) and float(value) == floorf(float(value))


static func _is_finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


# ── Cross-references ───────────────────────────────────────────────────────────
#
# One object pointing at another is the only thing in a slot file that isn't a
# plain value, and it comes in two flavours: a peer inside this save, and a
# fixture standing in the room that the save doesn't own. Both encode to a single
# JSON value — an int id for the peer, a scene path for the fixture, null for
# nothing — so every site that records or resolves a reference uses this pair
# rather than its own _id/_path key couple.

## Encode a reference to target. Returns int, String or null.
func _ref(node_to_id: Dictionary, target: Node) -> Variant:
	if target == null:
		return null
	if node_to_id.has(target):
		return node_to_id[target]
	# Not in the map. A scene-placed fixture has no id and never will, so name it
	# by path. A "spawned" node missing from the map means a partial serialize
	# (ObjectSync ships one object at a time) — its path is a dynamic name that
	# means nothing to the peer receiving it, so drop the reference instead.
	if target.is_in_group("spawned"):
		return null
	return str(target.get_path())


## Resolve what _ref() wrote. Null when the reference was empty or has gone.
func _resolve_ref(root: Node, spawned: Dictionary, ref: Variant) -> Node:
	if ref == null:
		return null
	if ref is String:
		var node := root.get_node_or_null(ref as String)
		if node == null:
			push_warning("[ScenePersistence] no node at '%s'" % ref)
		return node
	# JSON has no integer type, so an id parses back as a float.
	return spawned.get(int(ref)) as Node


## Instantiate serialized object entries under root and restore their
## cross-connections (two passes). Returns {id: Node3D} for the spawned set.
## Shared by slot loading and multiplayer world snapshots (ObjectSync).
func instantiate_objects(root: Node, objects: Array) -> Dictionary:
	var spawned: Dictionary = {}
	var entries: Dictionary = {}
	var held: Dictionary = {}
	for entry: Variant in objects:
		_spawn_entry(root, entry, spawned, entries, held)
	_hold_still_group(root, held)
	_restore_connections(root, spawned, entries)
	_let_go(held)
	return spawned


## Same, but hands a frame back once it has held the main thread for
## FRAME_BUDGET_USEC. A slot restored as part of a room change is built at the
## exact moment the headset has nothing new to draw: a save with a dozen systems
## in it blocks for a second, and a blocked main thread in VR is a frozen image,
## not a slow one. Callers that need every object within the frame — netplay
## snapshots — use instantiate_objects(), which stays a plain function because a
## body containing await would hand them a Signal instead of the spawned set.
func instantiate_objects_async(root: Node, objects: Array) -> Dictionary:
	var spawned: Dictionary = {}
	var entries: Dictionary = {}
	var tree := root.get_tree()
	var held: Dictionary = {}
	_restore_generation += 1
	var generation := _restore_generation
	var deadline := Time.get_ticks_usec() + FRAME_BUDGET_USEC
	for entry: Variant in objects:
		# A saved bespoke console names a GLB that may still be warming at boot.
		# Spawning it now would load() that GLB synchronously inside _ready —
		# measured 6.9 s of frozen frame for the NES on a Quest 3. Await it into
		# the cache instead; once warm this never suspends.
		await _acquire_entry_assets(entry)
		if not _still_ours(root, generation):
			_let_go(held)
			return spawned
		_spawn_entry(root, entry, spawned, entries, held)
		if Time.get_ticks_usec() < deadline:
			continue
		await tree.process_frame
		if not _still_ours(root, generation):
			_let_go(held)
			return spawned
		deadline = Time.get_ticks_usec() + FRAME_BUDGET_USEC
	_hold_still_group(root, held)
	await _restore_connections_async(root, spawned, entries, generation)
	_let_go(held)
	return spawned


## No-op for everything but a system entry whose model carries external assets.
func _acquire_entry_assets(entry: Variant) -> void:
	if not entry is Dictionary:
		return
	var d := entry as Dictionary
	if str(d.get("type", "")) != "system":
		return
	var row := SystemModelRegistry.resolve(str(d.get("model_id", "")), str(d.get("systemid", "")))
	for path: String in row.get("requires", []):
		await ModelWarmer.acquire(path)


func _spawn_entry(root: Node, entry: Variant, spawned: Dictionary, entries: Dictionary,
		held: Dictionary) -> void:
	if not entry is Dictionary:
		return
	var d := entry as Dictionary
	var id: int = d.get("id", -1)
	if id < 0:
		return
	var obj := _deserialize_object(d)
	if obj == null:
		return
	root.add_child(obj)
	obj.add_to_group("spawned")
	_hold_still(obj, held)
	# A lead's connectors are stood up here rather than with the rest of its wiring
	# in pass 2. Where they go needs nothing from the other objects, and the lead
	# lays its cord out around them at the end of THIS frame — so leaving them until
	# pass 2 hangs the cord in mid-air over the desk for as many frames as the
	# restore takes to reach it. Which socket holds which is still pass 2's, because
	# that genuinely does need every device to exist.
	if obj is CompositeCable:
		(obj as CompositeCable).restore_plug_poses(d.get("plugs", []))
	spawned[id] = obj
	entries[id] = d


## Take gravity off every rigid body in a freshly spawned object, remembering what
## it had. _let_go gives it back once the whole room is wired.
##
## Restoring is two passes — pass 1 stands the objects where they were left, pass 2
## hands each one to whatever was holding it — and both are budgeted to a few ms a
## frame so the headset keeps drawing (see instantiate_objects_async). Everything
## restored is an XRToolsPickable, which is a RigidBody3D, live from the moment it
## is added. So a cartridge saved in its slot spawns at the slot's pose with nothing
## under it and falls out; a disc in a tray does the same; anything resting on
## another restored object falls through the gap until that one arrives. Measured
## on a 24-object slot: one to three seconds of that before pass 2 catches up. The
## whole room appeared to rain into place.
##
## Gravity rather than `freeze`, deliberately. Three other things own that flag and
## would fight over it: XRToolsPickable snapshots it at pick-up and hands it back on
## release — so a cartridge seated in pass 2 while frozen would stay frozen in
## mid-air when the player pulled it out (the correction RetroTV._on_tv_grabbed has
## to make for its own park) — plus FloatLock parks with it and RetroSystem keeps its
## own copy of that. gravity_scale is written by no script in the project.
func _hold_still(node: Node, held: Dictionary) -> void:
	if node is RigidBody3D:
		var body := node as RigidBody3D
		var id := body.get_instance_id()
		# Keyed, and never overwritten: _hold_still_group sweeps again a pass later
		# and would otherwise record the zero this already wrote as what the body
		# arrived with, so _let_go would hand back no gravity at all.
		if not held.has(id):
			held[id] = {"body": body, "gravity": body.gravity_scale}
			body.gravity_scale = 0.0
			body.linear_velocity = Vector3.ZERO
			body.angular_velocity = Vector3.ZERO
	for child in node.get_children():
		_hold_still(child, held)


## The same, over everything in the "spawned" group.
##
## A second sweep, run once pass 1 is finished, because the captive leads are not
## children of the object that owns them: a system, a keyboard or a mouse builds its
## cable in _ready and parents it to the current scene a frame later (see
## RetroSystem._add_cables_to_scene), so it does not exist yet when its owner spawns
## and the walk above cannot reach it. Its plug is the most visible faller of the
## lot — it spawns beside the console's jack and drops to the desk before pass 2
## puts it in the socket.
func _hold_still_group(root: Node, held: Dictionary) -> void:
	if root.get_tree() == null:
		return
	for node: Node in root.get_tree().get_nodes_in_group("spawned"):
		_hold_still(node, held)


## Hand the room back to physics. Woken as well as un-weighted: a body that stood
## still for the length of the restore has gone to sleep, and a sleeping body does
## not notice it has weight again.
func _let_go(held: Dictionary) -> void:
	for id: Variant in held:
		var rec: Dictionary = held[id]
		# Untyped on purpose. Assigning a freed instance to a TYPED local throws on
		# the assignment, so `var body: RigidBody3D = ...` made the is_instance_valid
		# below unreachable — and the throw abandoned the loop, leaving every body
		# after the freed one weightless and asleep for good. Overlapping restores
		# produce exactly this: the newer one frees what the older one is holding.
		var body: Variant = rec["body"]
		if not is_instance_valid(body):
			continue
		var rb := body as RigidBody3D
		rb.gravity_scale = rec["gravity"]
		rb.sleeping = false
	held.clear()


## Pass 2: wire the spawned objects to each other. Has to run after every object
## exists, because a connection can point either way through the set.
func _restore_connections(root: Node, spawned: Dictionary, entries: Dictionary) -> void:
	for id: int in spawned:
		_restore_entry(root, id, spawned, entries)
	for id: int in spawned:
		_restore_rope_layouts(spawned[id], entries[id])
	_report_restored(spawned)


## Same, yielding a frame whenever it has held the main thread too long.
func _restore_connections_async(root: Node, spawned: Dictionary, entries: Dictionary,
		generation: int) -> void:
	var tree := root.get_tree()
	var deadline := Time.get_ticks_usec() + FRAME_BUDGET_USEC
	for id: int in spawned:
		_restore_entry(root, id, spawned, entries)
		if Time.get_ticks_usec() < deadline:
			continue
		await tree.process_frame
		if not _still_ours(root, generation):
			return
		deadline = Time.get_ticks_usec() + FRAME_BUDGET_USEC
	for id: int in spawned:
		_restore_rope_layouts(spawned[id], entries[id])
		if Time.get_ticks_usec() < deadline:
			continue
		await tree.process_frame
		if not _still_ours(root, generation):
			return
		deadline = Time.get_ticks_usec() + FRAME_BUDGET_USEC
	_report_restored(spawned)


## Restore after pass 2 has seated every plug. The saved particles preserve the
## actual route round furniture; VerletRope validates topology immediately and
## validates the route against live collision geometry on its next physics tick.
func _restore_rope_layouts(obj: Node, entry: Dictionary) -> void:
	if not is_instance_valid(obj):
		return
	for rec: Dictionary in entry.get("rope_layouts", []):
		var rope := obj.get_node_or_null(NodePath(str(rec.get("path", "")))) as VerletRope
		if rope == null:
			continue
		var points := PackedVector3Array()
		for raw: Variant in rec.get("points", []):
			if not raw is Array or (raw as Array).size() < 3:
				points = PackedVector3Array()
				break
			var xyz := raw as Array
			points.append(Vector3(float(xyz[0]), float(xyz[1]), float(xyz[2])))
		if not rope.restore_points(points):
			push_warning("ScenePersistence: rejected rope layout at %s" % rec.get("path", ""))


## False once the room we are building into has gone, or once a newer restore
## has taken over — either way this run must not touch the scene again.
##
## root is Variant on purpose. Being handed a freed room is the whole reason this
## exists, and binding a freed object to a Node-typed parameter throws before the
## body can run — the same way assigning one to a typed local does.
func _still_ours(root: Variant, generation: int) -> bool:
	if generation != _restore_generation:
		return false
	return is_instance_valid(root) and (root as Node).is_inside_tree()


func _report_restored(spawned: Dictionary) -> void:
	if spawned.size() > 0:
		print("[ScenePersistence] instantiated %d objects" % spawned.size())


## One entry of a saved "tv_inputs" list, or Composite 1 for a save that predates
## the key, a channel it does not reach, or a value from a future set with more
## inputs than this one has.
static func _tv_input(inputs: Array, channel: int) -> int:
	if channel < 0 or channel >= inputs.size():
		return 0
	return clampi(int(inputs[channel]), 0, RetroTV.COMPOSITE_INPUTS - 1)


func _restore_entry(root: Node, id: int, spawned: Dictionary, entries: Dictionary) -> void:
	# The async pass yields frames, so an object spawned earlier in this very run
	# may already have been freed by the time we come to wire it up.
	if not is_instance_valid(spawned[id]):
		return
	var obj: Node = spawned[id]
	var d: Dictionary = entries[id]
	_restore_articulated_controls(obj, d.get("articulated", d.get("hinges", [])))

	if obj is RetroSystem:
		var sys := obj as RetroSystem
		# Which composite input each channel's lead goes back into. Absent on every
		# save written before a set had four, and read through a helper that answers
		# Composite 1 for anything it does not cover.
		var tv_inputs: Array = d.get("tv_inputs", [])
		var tv := _resolve_ref(root, spawned, d.get("tv")) as RetroTV
		if tv:
			sys.restore_cable_connection(tv, 0, _tv_input(tv_inputs, 0))
		# Extra video-out channels (dual-screen handhelds: ch 1 = BOTTOM). A save
		# made against a model with more channels than this one has is truncated —
		# restore_cable_connection would silently fold the overflow onto ch 0.
		var extra: Array = d.get("extra_tvs", [])
		for i in range(mini(extra.size(), sys.get_channel_count() - 1)):
			var ch_tv := _resolve_ref(root, spawned, extra[i]) as RetroTV
			if ch_tv:
				sys.restore_cable_connection(ch_tv, i + 1, _tv_input(tv_inputs, i + 1))
		var cart := _resolve_ref(root, spawned, d.get("cartridge")) as RetroCartridge
		if cart:
			sys.restore_cartridge(cart)
		var memcard := _resolve_ref(root, spawned, d.get("memcard")) as MemoryCard
		if memcard:
			sys.restore_memory_card(memcard, 0)
		# Slot B is its own key rather than the pair becoming an array: an array
		# would not load in any room file saved before there was a second slot.
		var memcard_b := _resolve_ref(root, spawned, d.get("memcard_b")) as MemoryCard
		if memcard_b:
			sys.restore_memory_card(memcard_b, 1)
		# After the media, and deferred: seating a cartridge swings the bay open (the
		# NES flap) and tweens it there, either of which would otherwise win over the
		# pose the system restored when its model loaded.
		var lid_angle := float(d.get("lid_angle", -1.0))
		if lid_angle >= 0.0:
			sys.set_lid_angle_deg.call_deferred(lid_angle)
	elif obj is RetroTV:
		(obj as RetroTV).restore_control_state(d.get("controls", {}))
	elif obj is VCRPlayer:
		var tape := _resolve_ref(root, spawned, d.get("tape")) as VCRTape
		if tape:
			(obj as VCRPlayer).restore_tape(tape)
	elif obj is DVDPlayer:
		var disc := _resolve_ref(root, spawned, d.get("disc")) as DVDDisc
		if disc:
			(obj as DVDPlayer).restore_disc(disc)
	elif obj is RetroAudioPlayer:
		var media := _resolve_ref(root, spawned, d.get("media"))
		if media is AudioDisc or media is AudioCassette:
			(obj as RetroAudioPlayer).restore_media(media as Node3D)
	elif obj is SpeakerPair:
		var pair := obj as SpeakerPair
		pair.set_volume(float(d.get("volume", 0.75)))
		pair.restore_box_poses(d.get("boxes", []))
	elif obj is CompositeCable:
		# Pass 2, so every deck and set the plugs point at already exists. A plug
		# whose socket cannot be found is simply left where it was saved — a loose
		# end on the floor beats one seated in the wrong device.
		var seats: Array = []
		for rec: Dictionary in d.get("plugs", []):
			seats.append({
				"end": int(rec.get("end", 0)),
				"cord": int(rec.get("cord", 0)),
				"position": rec.get("position", []),
				"rotation": rec.get("rotation", []),
				"device": _resolve_ref(root, spawned, rec.get("device")) as Node3D,
				"port": str(rec.get("port", "")),
			})
		if obj.has_method("restore_carried_body"):
			obj.call("restore_carried_body", d.get("body", {}))
		(obj as CompositeCable).restore_seating(seats)
	elif obj is SensorBar:
		(obj as SensorBar).restore_connection(
			_resolve_ref(root, spawned, d.get("system")) as RetroSystem)
	elif obj is InputReceiver:
		var rx_port := int(d.get("port_index", -1))
		if rx_port < 0:
			return
		var rx_sys := _resolve_ref(root, spawned, d.get("system")) as RetroSystem
		if rx_sys == null:
			push_warning("[ScenePersistence] pad receiver id=%d: system not found" % id)
			return
		(obj as InputReceiver).restore_port_connection(rx_sys, rx_port)
	elif obj is RetroController or obj is LightGun or obj is RetroMouse \
			or obj is RetroKeyboard or obj is Wiimote:
		# The remote's Nunchuk is restored whether or not it was paired to a
		# console — an unpaired remote can still have one plugged into it.
		if obj is Wiimote:
			# Dongle FIRST. It seats synchronously, and the Nunchuk goes into its
			# pass-through rather than into the remote whenever one is present, so
			# restoring them the other way round puts the Nunchuk in the wrong port.
			(obj as Wiimote).restore_motion_plus(
				_resolve_ref(root, spawned, d.get("motion_plus")) as MotionPlus)
			(obj as Wiimote).restore_nunchuk(
				_resolve_ref(root, spawned, d.get("nunchuk")) as Nunchuk)
		var port_idx := int(d.get("port_index", -1))
		if port_idx < 0:
			return
		var sys := _resolve_ref(root, spawned, d.get("system")) as RetroSystem
		if sys == null:
			push_warning("[ScenePersistence] controller id=%d: system not found" % id)
			return
		obj.call("restore_port_connection", sys, port_idx)


# ── Serialization ──────────────────────────────────────────────────────────────

## id, type and pose — the four fields every entry carries. Each branch of
## _serialize_node() merges its own fields onto this.
func _base(id: int, type_name: String, n3d: Node3D) -> Dictionary:
	var pos := n3d.global_position
	var rot := n3d.global_rotation_degrees
	var out := {
		"id": id,
		"type": type_name,
		"position": [pos.x, pos.y, pos.z],
		"rotation": [rot.x, rot.y, rot.z],
	}
	# Float-in-place, for the objects that have it (RetroSystem, and every device
	# carrying a FloatLock). Only written when ON, so a room full of ordinary
	# props saves exactly as it did before this field existed.
	var floating := false
	if n3d.has_method("get_ignore_gravity"):
		floating = bool(n3d.call("get_ignore_gravity"))
	elif "ignore_gravity" in n3d:
		floating = bool(n3d.get("ignore_gravity"))
	if floating:
		out["ignore_gravity"] = true
	var articulated := _serialize_articulated_controls(n3d)
	if not articulated.is_empty():
		out["articulated"] = articulated
	var rope_layouts := _serialize_rope_layouts(n3d)
	if not rope_layouts.is_empty():
		out["rope_layouts"] = rope_layouts
	return out


## Articulated child transforms are not represented by the spawned object's
## root pose. Persist every VRHinge by its stable path inside the object so a
## snapshot/reload preserves handheld lids, console flaps and battery covers.
func _serialize_articulated_controls(root: Node3D) -> Array:
	var out: Array = []
	var hinges: Array[Node] = root.find_children("*", "VRHinge", true, false)
	if root is VRHinge:
		hinges.push_front(root)
	for candidate: Node in hinges:
		var hinge := candidate as VRHinge
		if hinge == null or hinge.target == null:
			continue
		var rec := {"path": str(root.get_path_to(hinge))}
		if hinge is VRLever:
			rec["kind"] = "lever"
			rec["value"] = (hinge as VRLever).get_value()
		else:
			rec["kind"] = "hinge"
			rec["value"] = hinge.get_rotation_deg()
			if hinge is VRSpringLatchedHinge:
				rec["latched"] = (hinge as VRSpringLatchedHinge).is_latched_closed()
		out.append(rec)
	for candidate: Node in root.find_children("*", "VRKnob", true, false):
		var knob := candidate as VRKnob
		if knob != null:
			out.append({"path": str(root.get_path_to(knob)),
				"kind": "knob", "value": knob.get_value()})
	for candidate: Node in root.find_children("*", "VRSlider", true, false):
		var slider := candidate as VRSlider
		# A power switch is the one slider whose position is not a pose: it says
		# whether the machine is RUNNING, and nothing restores a running machine.
		# Saved, it brought a handheld back with its switch at ON and a dead
		# console behind it. Its rest position is authored off, and the model puts
		# it back under the machine's control from there (on_power_on/off).
		if slider != null and not slider.is_in_group(RetroSystemModel.POWER_SWITCH_GROUP):
			out.append({"path": str(root.get_path_to(slider)),
				"kind": "slider", "value": slider.value})
	return out


func _restore_articulated_controls(root: Node, records: Array) -> void:
	for raw: Variant in records:
		if not raw is Dictionary:
			continue
		var rec := raw as Dictionary
		var path := str(rec.get("path", ""))
		if path.is_empty() or path.is_absolute_path() or path.length() > 256:
			continue
		var control := root.get_node_or_null(NodePath(path))
		if control == null or (control != root and not root.is_ancestor_of(control)):
			continue
		var kind := str(rec.get("kind", "hinge"))
		var value := float(rec.get("value", rec.get("degrees", NAN)))
		if not is_finite(value):
			continue
		# Model listeners still need the rotation_changed signal to move dependent
		# geometry, but an ObjectSync snapshot must not echo the restore back out.
		control.set_meta("net_restore_in_progress", true)
		match kind:
			"hinge":
				if control is VRSpringLatchedHinge:
					(control as VRSpringLatchedHinge).set_state_remote(value,
						bool(rec.get("latched", false)))
				elif control is VRHinge:
					(control as VRHinge).set_rotation_deg_remote(value)
			"lever":
				if control is VRLever:
					(control as VRLever).set_value(value)
			"knob":
				if control is VRKnob:
					(control as VRKnob).set_value(value)
			"slider":
				# The group check is here as well as in the save walk: every slot
				# written before this one carries the switch, and applying it would
				# also fire value_changed straight into toggle_power.
				if control is VRSlider \
						and not control.is_in_group(RetroSystemModel.POWER_SWITCH_GROUP):
					(control as VRSlider).set_value(value)
		control.remove_meta("net_restore_in_progress")


## Save world-space particles, keyed by a stable path inside the spawned object.
## Endpoints alone cannot reconstruct which side of a table, post or partition a
## player routed a lead around.
func _serialize_rope_layouts(root: Node3D) -> Array:
	var layouts: Array = []
	var ropes: Array[Node] = root.find_children("*", "VerletRope", true, false)
	if root is VerletRope:
		ropes.push_front(root)
	for child: Node in ropes:
		var rope := child as VerletRope
		if rope == null:
			continue
		var encoded: Array = []
		for point: Vector3 in rope.get_points():
			encoded.append([point.x, point.y, point.z])
		if not encoded.is_empty():
			layouts.append({
				"path": str(root.get_path_to(rope)),
				"points": encoded,
			})
	return layouts


## An ordered chain, not a lookup table: `is` matches every ancestor, so a
## subtype has to be tested before the type it extends. The two places that
## matters are marked below.
func _serialize_node(node: Node, id: int, node_to_id: Dictionary) -> Dictionary:
	if not node is Node3D:
		return {}
	var n3d := node as Node3D

	if node is RetroSystem:
		var sys := node as RetroSystem
		var result := _base(id, "system", n3d).merged({
			"systemid": sys.systemid,
			"model_id": sys.model_id,
			"tv": _ref(node_to_id, sys.connected_tv),
			"cartridge": _ref(node_to_id, sys.get_snapped_cartridge()),
			"memcard": _ref(node_to_id, sys.get_snapped_memcard(0)),
			"memcard_b": _ref(node_to_id, sys.get_snapped_memcard(1)),
			"video_out": sys.video_out_enabled,
			"ignore_gravity": sys.ignore_gravity,
		})
		# Which physical gamepad drives it, for handhelds — they have no port to
		# take a PadReceiver, so the choice lives on the machine. Written only
		# when one is set, so nothing changes for the rooms that never touch it.
		if not sys.pad_guid.is_empty():
			result["pad_guid"] = sys.pad_guid
			result["pad_ordinal"] = sys.pad_ordinal
		# Clamshell lid angle (DS/3DS); omitted for systems without a lid.
		var lid_angle := sys.get_lid_angle_deg()
		if lid_angle >= 0.0:
			result["lid_angle"] = lid_angle
		# Extra video-out channels (dual-screen handhelds: ch 1 = BOTTOM).
		var extra: Array = []
		for ch in range(1, sys.get_channel_count()):
			extra.append(_ref(node_to_id, sys.get_channel_tv(ch)))
		if not extra.is_empty():
			result["extra_tvs"] = extra
		# Which composite input each lead is in, one per channel. Omitted while they
		# are all in Composite 1, which is what a save without the key restores to —
		# so the common case adds nothing to the file.
		var tv_inputs: Array = []
		var any_input := false
		for ch in sys.get_channel_count():
			var input := sys.get_channel_tv_input(ch)
			any_input = any_input or input != 0
			tv_inputs.append(input)
		if any_input:
			result["tv_inputs"] = tv_inputs
		return result
	elif node is RetroTV:
		var tv := node as RetroTV
		return _base(id, "tv", n3d).merged({
			# Which cabinet it wears. Without this a spawned monitor comes back as
			# the stock black box, since tv_model only ever survived by being
			# authored into a scene.
			"tv_model": tv.tv_model,
			"crt_enabled": tv.crt_enabled,
			"crt_params": tv.get_crt_params(),
			"scale_factor": tv.scale_factor,
			"stereo_mode": tv.stereo_mode,
			"controls": tv.get_control_state(),
		})
	elif node is SensorBar:
		# Pose, plus which console is powering it. Unlike the Nunchuk this end DOES
		# mean something: the bar is what a remote looks at, and a bar restored
		# unplugged is a room where nothing points at anything.
		return _base(id, "sensor_bar", n3d).merged({
			"system": _ref(node_to_id, (node as SensorBar).get_system()),
		})
	elif node is Nunchuk:
		# Pose only. Which remote it is plugged into is saved on the REMOTE, which
		# is the end of the cord that means something; this side is just where the
		# thing is lying. Being in PLAIN_SCENES is not enough on its own — that map
		# is only read when LOADING, so without a branch here it was never written
		# and there was nothing to load back.
		return _base(id, "nunchuk", n3d)
	elif node is MotionPlus:
		# Pose only, for the reason the Nunchuk above gives: which remote it is
		# seated in is saved on that remote. It needs a branch here all the same,
		# because PLAIN_SCENES is only read when loading.
		return _base(id, "motion_plus", n3d)
	elif node is TVRemote:
		return _base(id, "tv_remote", n3d)
	elif node is TrashCan:
		return _base(id, "trash_can", n3d)
	elif node is Table:
		# Pose only. Being in PLAIN_SCENES is not enough on its own — that map is
		# read when LOADING, so without this branch a table is never written and
		# there is nothing to load back.
		return _base(id, "table", n3d)
	elif node is RetroDisc:
		# MUST precede the RetroCartridge branch — RetroDisc extends it.
		return _base(id, "disc", n3d).merged(_media_fields(node as RetroCartridge))
	elif node is RetroCartridge:
		return _base(id, "cartridge", n3d).merged(_media_fields(node as RetroCartridge))
	elif node is MemoryCard:
		var card := node as MemoryCard
		return _base(id, "memory_card", n3d).merged({
			"family": card.family,
			"card_id": card.card_id,
			"card_label": card.card_label,
		})
	elif node is Poster:
		var poster := node as Poster
		return _base(id, "poster", n3d).merged({
			"image_path": poster.image_path,
			"size_scale": poster.size_scale,
			"fit_mode": int(poster.fit_mode),
			"roll": poster.roll_degrees,
			"stuck": poster.is_stuck(),
		})
	elif node is PDFBook:
		var book := node as PDFBook
		var page := book.net_get_page()
		return _base(id, "book", n3d).merged({
			"pdf_path": book.pdf_path,
			"half_pages": book.half_page_mode,
			"size_scale": book.size_scale,
			"page_state": int(page.get("state", 0)),
			"page_leaf": int(page.get("leaf", 0)),
		})
	elif node is VCRPlayer:
		# The deck's own TV link is not saved: the lead is a separate object now, so
		# the connection lives in a spawned cable's plugs. Same for the DVD player.
		return _base(id, "vcr_player", n3d).merged({
			"tape": _ref(node_to_id, (node as VCRPlayer).get_snapped_tape()),
		})
	elif node is VCRTape:
		var tape := node as VCRTape
		return _base(id, "vcr_tape", n3d).merged({
			"video_path": tape.video_path,
			"video_label": tape.video_label,
		})
	elif node is DVDPlayer:
		return _base(id, "dvd_player", n3d).merged({
			"disc": _ref(node_to_id, (node as DVDPlayer).get_snapped_disc()),
		})
	elif node is DVDDisc:
		var dvd := node as DVDDisc
		return _base(id, "dvd_disc", n3d).merged({
			"dvd_path": dvd.dvd_path,
			"dvd_label": dvd.dvd_label,
		})
	elif node is RetroAudioPlayer:
		var ap := node as RetroAudioPlayer
		return _base(id, "cd_player" if node is CDPlayer else "cassette_player", n3d).merged({
			"media": _ref(node_to_id, ap.get_snapped_media()),
		})
	elif node is AudioDisc:
		var adisc := node as AudioDisc
		return _base(id, "audio_disc", n3d).merged({
			"album_path": adisc.album_path,
			"album_label": adisc.album_label,
		})
	elif node is AudioCassette:
		var acass := node as AudioCassette
		return _base(id, "audio_cassette", n3d).merged({
			"album_path": acass.album_path,
			"album_label": acass.album_label,
		})
	elif node is RetroController or node is LightGun or node is RetroMouse \
			or node is RetroKeyboard or node is Wiimote:
		return _serialize_peripheral(node, id, n3d, node_to_id)
	elif node is SpeakerPair:
		# Deliberately not a PLAIN_SCENES pose-only object. The root never moves —
		# the two cabinets are separate bodies the player carries around one at a
		# time — so the root's transform says nothing about where either of them is.
		var pair := node as SpeakerPair
		return _base(id, "speaker_pair", n3d).merged({
			"boxes": pair.box_poses(),
			"volume": pair.get_volume(),
		})
	elif node is KeyboardReceiver:
		return _receiver_entry(node as InputReceiver, id, "keyboard_receiver", n3d, node_to_id)
	elif node is MouseReceiver:
		return _receiver_entry(node as InputReceiver, id, "mouse_receiver", n3d, node_to_id)
	elif node is PadReceiver:
		# Which PAD it is for as well as which port it is in — a receiver with no
		# pad is a dongle for nothing.
		var pr := node as PadReceiver
		return _receiver_entry(pr, id, "pad_receiver", n3d, node_to_id).merged({
			"pad_guid": pr.pad_guid,
			"pad_name": pr.pad_name,
			"pad_ordinal": pr.pad_ordinal,
		})
	elif node is CompositeCable:
		return _serialize_cable(node as CompositeCable, id, n3d, node_to_id)
	return {}


## Pose plus which port it is seated in — everything a receiver has in common.
## The socket, like every other peripheral's, is the CABINET's rather than the
## libretro port (see _serialize_peripheral).
func _receiver_entry(rx: InputReceiver, id: int, type_name: String, n3d: Node3D,
		node_to_id: Dictionary) -> Dictionary:
	var sys: Node = rx.get_connected_system()
	var port := -1
	if sys != null and sys.has_method("cabinet_port_of"):
		port = int(sys.call("cabinet_port_of", rx))
	return _base(id, type_name, n3d).merged({
		"system": _ref(node_to_id, sys),
		"port_index": port,
	})


func _media_fields(cart: RetroCartridge) -> Dictionary:
	return {
		"rom_path": cart.rom_path,
		"game_label": cart.game_label,
		"save_id": cart.save_id,
		"cart_systemid": cart.systemid,
	}


func _serialize_peripheral(node: Node, id: int, n3d: Node3D, node_to_id: Dictionary) -> Dictionary:
	var obj_type := "retro_controller"
	if node is Wiimote:
		obj_type = "wiimote"
	elif node is LightGun:
		obj_type = "light_gun"
	elif node is SnesMouse:
		# Before the RetroMouse arm, which it also satisfies — reaching that
		# first would save the SNES mouse as the primitive one and hand the
		# player a grey box back.
		obj_type = "snes_mouse"
	elif node is RetroMouse:
		obj_type = "retro_mouse"
	elif node is RetroKeyboard:
		obj_type = "retro_keyboard"
	var connected_sys: Node = node.get("_connected_system")
	# The CABINET socket, which is what restore_controller_plug takes — not the
	# peripheral's own _port_index, which is the libretro port and is pinned to 0
	# for a mouse on a computer system. Falls back to it for anything the cabinet
	# does not claim to be holding.
	var port_index := -1
	if connected_sys != null:
		port_index = int(node.get("_port_index"))
		if connected_sys.has_method("cabinet_port_of"):
			var socket: int = connected_sys.call("cabinet_port_of", node)
			if socket >= 0:
				port_index = socket
	var entry := _base(id, obj_type, n3d).merged({
		"device_type": node.get("device_type") as int,
		"system": _ref(node_to_id, connected_sys),
		"port_index": port_index,
	})
	if node is Wiimote:
		# Which Nunchuk is plugged into this remote, if any. Saved on the REMOTE
		# because that is the end of the cord that means something — the nunchuk
		# itself is just a pose.
		entry["nunchuk"] = _ref(node_to_id, (node as Wiimote).get_nunchuk())
		# And the dongle, if one is fitted. Saved beside the Nunchuk rather than
		# derived from device_type, because the pair of them is what says which
		# port the Nunchuk goes back into.
		entry["motion_plus"] = _ref(node_to_id, (node as Wiimote).get_motion_plus())
	if node is RetroMouse:
		entry["sensitivity"] = (node as RetroMouse).sensitivity
	if node is RetroController:
		# Every real pad — NES, Virtual Boy, CX40 — is a RetroController with a
		# scene of its own, so the type above maps the whole family back onto the
		# generic grey pad. The scene is what tells them apart.
		entry["scene"] = node.scene_file_path
	return entry


## Six independent ends, so the lead is saved as six plugs rather than as one
## object with a position: each carries its own pose and, if it is in a socket,
## the device and the socket's node name. The name is what makes this readable
## and stable — "AudioLIn" survives any renumbering of ports, which an index
## would not.
func _serialize_cable(cable: CompositeCable, id: int, n3d: Node3D,
		node_to_id: Dictionary) -> Dictionary:
	var plugs: Array = []
	for seat: Dictionary in cable.seating():
		var plug := seat["plug"] as Node3D
		var ppos := plug.global_position
		var prot := plug.global_rotation_degrees
		plugs.append({
			"end": seat["end"],
			"cord": seat["cord"],
			"position": [ppos.x, ppos.y, ppos.z],
			"rotation": [prot.x, prot.y, prot.z],
			"port": seat["port"],
			"device": _ref(node_to_id, seat["device"] as Node),
		})
	var extra := {}
	# A plain lead has no body and _base's pose — the ROOT's — is the whole object.
	# The RF switch has a box the player carries while its root stays where it
	# spawned, so without this it restores at the origin and its own tether
	# immediately hauls both plugs out of their sockets to reach it.
	if cable.has_method("carried_body_pose"):
		var body_pose: Dictionary = cable.call("carried_body_pose")
		if not body_pose.is_empty():
			extra["body"] = body_pose
	return _base(id, "composite_cable", n3d).merged(extra).merged({
		# 2 = the mono lead, 3 = the full one. Both are CompositeCable; only
		# the scene differs, so the count is what picks it back up.
		"cords": cable.cord_count(),
		# ...except that a one-cord lead is NOT "the composite lead with a cord
		# missing" — it is a different connector entirely. Named rather than
		# inferred from the count, so the next single-cord lead to be added does not
		# silently restore as a VGA one.
		"kind": cable.scene_file_path.get_file().get_basename(),
		"plugs": plugs,
	})


## The pad scene the entry names, or the generic pad when the save predates the
## field, names a scene this build no longer ships, or names something that is
## not a controller at all. ResourceLoader.exists, not FileAccess: paths are
## remapped into the pck in an exported build.
func _instantiate_controller(data: Dictionary) -> Node3D:
	var path: String = str(data.get("scene", ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		var packed := ResourceLoader.load(path) as PackedScene
		if packed != null:
			var inst := packed.instantiate() as Node3D
			if inst is RetroController:
				return inst
			if inst != null:
				push_warning("ScenePersistence: '%s' is not a controller" % path)
				inst.queue_free()
	return RETRO_CONTROLLER_SCENE.instantiate() as Node3D


func _deserialize_object(data: Dictionary) -> Node3D:
	var obj_type: String = data.get("type", "")
	var obj: Node3D = null

	if PLAIN_SCENES.has(obj_type):
		obj = (PLAIN_SCENES[obj_type] as PackedScene).instantiate() as Node3D
	else:
		match obj_type:
			"system":
				var sys := SYSTEM_SCENE.instantiate() as RetroSystem
				sys.systemid = data.get("systemid", "")
				sys.model_id = str(data.get("model_id", ""))
				if data.has("video_out"):
					sys._video_out_from_save = 1 if bool(data["video_out"]) else 0
				sys.pad_guid = str(data.get("pad_guid", ""))
				sys.pad_ordinal = int(data.get("pad_ordinal", 0))
				sys._lid_angle_from_save = float(data.get("lid_angle", -1.0))
				sys.ignore_gravity = bool(data.get("ignore_gravity", false))
				obj = sys
			"tv":
				var tv := TV_SCENE.instantiate() as RetroTV
				# Before the caller adds it to the tree: _load_shell runs from
				# _ready. "" is _load_shell's own "stock body, strict no-op"
				# value, so every set already in a save file restores unchanged.
				tv.tv_model = data.get("tv_model", "")
				tv.crt_enabled = data.get("crt_enabled", true)
				var crt_params: Dictionary = data.get("crt_params", {})
				if not crt_params.is_empty():
					tv.set_crt_params(crt_params)
				tv.scale_factor = data.get("scale_factor", 1.0)
				tv.stereo_mode = int(data.get("stereo_mode", 0))
				obj = tv
			"cartridge":
				var cart := CART_SCENE.instantiate() as RetroCartridge
				_apply_media_fields(cart, data)
				obj = cart
			"disc":
				var disc_systemid: String = data.get("cart_systemid", "")
				var disc_scene := UMD_DISC_SCENE if disc_systemid == "playstation_portable" else DISC_SCENE
				var disc := disc_scene.instantiate() as RetroDisc
				_apply_media_fields(disc, data)
				obj = disc
			"memory_card":
				# A room saved before there were two families holds no family at
				# all, and every card in one is a PlayStation card.
				var family := str(data.get("family", "playstation"))
				var scene := GC_MEMCARD_SCENE if family == "gamecube" 					else MEMCARD_SCENE
				var card := scene.instantiate() as MemoryCard
				card.family = family
				card.card_id = data.get("card_id", "")
				card.card_label = data.get("card_label", "MEMORY CARD")
				obj = card
			"poster":
				var poster := POSTER_SCENE.instantiate() as Poster
				# Size and mode BEFORE the path: the image setter derives the
				# sheet's dimensions and has to see the final scale.
				poster.size_scale = float(data.get("size_scale", 1.0))
				poster.fit_mode = int(data.get("fit_mode", 0)) as Poster.FitMode
				poster.roll_degrees = float(data.get("roll", 0.0))
				poster.image_path = str(data.get("image_path", ""))
				poster.stuck_from_save = bool(data.get("stuck", false))
				obj = poster
			"book":
				var book := BOOK_SCENE.instantiate() as PDFBook
				book.half_page_mode = data.get("half_pages", false)
				book.size_scale = data.get("size_scale", 1.0)
				book.pdf_path = data.get("pdf_path", "")
				# Applied after the PDF loads (stashed while _page_count == 0).
				book.set_page(int(data.get("page_state", 0)), int(data.get("page_leaf", 0)))
				obj = book
			"retro_controller":
				obj = _instantiate_controller(data)
			"retro_mouse":
				var mouse := RETRO_MOUSE_SCENE.instantiate() as RetroMouse
				mouse.sensitivity = data.get("sensitivity", 2400.0)
				obj = mouse
			"snes_mouse":
				var snes := SNES_MOUSE_SCENE.instantiate() as SnesMouse
				snes.sensitivity = data.get("sensitivity", 2400.0)
				obj = snes
			"pad_receiver":
				# The saved pad may well not be connected — switched off, flat, or
				# swapped for another since. That is not a failure: the receiver
				# comes back red and binds to whatever turns up
				# (PadReceiver._resolve_or_adopt), so nothing here warns about it.
				var rx := PAD_RECEIVER_SCENE.instantiate() as PadReceiver
				rx.pad_guid = data.get("pad_guid", "")
				rx.pad_name = data.get("pad_name", "")
				rx.pad_ordinal = int(data.get("pad_ordinal", 0))
				obj = rx
			"keyboard_receiver":
				obj = KEYBOARD_RECEIVER_SCENE.instantiate() as Node3D
			"mouse_receiver":
				obj = MOUSE_RECEIVER_SCENE.instantiate() as Node3D
			"vcr_tape":
				var tape := TAPE_SCENE.instantiate() as VCRTape
				tape.video_path = data.get("video_path", "")
				tape.video_label = data.get("video_label", "")
				obj = tape
			"dvd_disc":
				var disc := DVD_DISC_SCENE.instantiate() as DVDDisc
				disc.dvd_path = data.get("dvd_path", "")
				disc.dvd_label = data.get("dvd_label", "")
				obj = disc
			"composite_cable":
				# Every lead in the room is a CompositeCable; only the scene it was
				# spawned from differs. "kind" names it outright — the cord count is
				# the fallback for saves written before that field existed, and it
				# cannot tell a VGA lead from any other one-cord lead.
				var kind: String = str(data.get("kind", ""))
				var lead: PackedScene = COMPOSITE_CABLE_SCENE
				# The Wii lead has to be named: it is three cords like the plain
				# composite one, so the cord-count fallback cannot tell them apart and
				# an old save has no reason to hold one anyway.
				if kind == "wii_av_cable":
					lead = WII_AV_CABLE_SCENE
				elif kind == "vga_cable":
					lead = VGA_CABLE_SCENE
				elif kind == "trs_cable":
					lead = TRS_CABLE_SCENE
				elif kind == "link_cable":
					lead = LINK_CABLE_SCENE
				elif kind == "gb_link_cable":
					lead = GB_LINK_CABLE_SCENE
				elif kind == "gc_gba_cable":
					lead = GC_GBA_CABLE_SCENE
				elif kind == "psx_link_cable":
					lead = PSX_LINK_CABLE_SCENE
				elif kind == "rf_switch":
					lead = RF_SWITCH_SCENE
				elif kind == "mono_composite_cable" or int(data.get("cords", 3)) == 2:
					lead = MONO_CABLE_SCENE
				obj = lead.instantiate() as Node3D
			"audio_disc":
				var adisc := AUDIO_DISC_SCENE.instantiate() as AudioDisc
				adisc.album_path = data.get("album_path", "")
				adisc.album_label = data.get("album_label", "")
				obj = adisc
			"audio_cassette":
				var acass := AUDIO_CASSETTE_SCENE.instantiate() as AudioCassette
				acass.album_path = data.get("album_path", "")
				acass.album_label = data.get("album_label", "")
				obj = acass
			_:
				push_warning("ScenePersistence: unknown object type '%s'" % obj_type)
				return null

	if not obj:
		return null

	var pos: Array = data.get("position", [0.0, 0.0, 0.0])
	var rot: Array = data.get("rotation", [0.0, 0.0, 0.0])
	obj.position = Vector3(pos[0], pos[1], pos[2])
	obj.rotation_degrees = Vector3(rot[0], rot[1], rot[2])
	# Float-in-place is a property of the OBJECT rather than of any one kind of
	# it, so it is applied once here instead of in a branch per device. Written
	# before the caller adds the child, which is what FloatLock needs: it reads
	# this flag in _ready and parks the body at the pose restored just above.
	if "ignore_gravity" in obj:
		obj.set("ignore_gravity", bool(data.get("ignore_gravity", false)))
	return obj


func _apply_media_fields(cart: RetroCartridge, data: Dictionary) -> void:
	cart.rom_path = data.get("rom_path", "")
	cart.game_label = data.get("game_label", "")
	cart.save_id = data.get("save_id", "")
	cart.systemid = data.get("cart_systemid", "")

## RoomCatalog — every room RetroXR can be standing in, in one table.
##
## This replaced four parallel tables that each held a slice of the same fact:
## SceneManager.SCENE_PATHS (id -> .tscn), SCENE_TITLES (the upper-case name the
## loading screen shows), SLOT_ROOMS (which rooms keep save slots), and
## SpawnMenuSceneView.ROOM_TITLES (the menu's own casing). Four places to edit
## for one room, in two files, with nothing checking they agreed — and the two
## title tables in particular were free to drift, since nothing reads both.
##
## Row fields:
##   path        the room's .tscn
##   title       loading-screen copy; upper-case, because that screen shouts
##   menu_title  the SCENE tab's card and its slot header
##   has_slots   rooms you furnish yourself, where a slot IS the room
##
## has_slots is the one that is not cosmetic. A room whose contents are authored
## in its own .tscn (the den, the test hallway) must not keep slots: a slot of
## what was spawned on top would restore a handful of objects into a room that
## already has its own.
class_name RoomCatalog
extends RefCounted

const _ROOMS: Dictionary = {
	"arcade": {
		"path": "res://Scenes/MainScene.tscn",
		"title": "ARCADE ROOM", "menu_title": "Arcade Room", "has_slots": true,
	},
	"den": {
		"path": "res://Scenes/DenScene.tscn",
		"title": "COZY DEN", "menu_title": "Cozy Den", "has_slots": false,
	},
	"bedroom": {
		"path": "res://Scenes/BedroomScene.tscn",
		"title": "90s BEDROOM", "menu_title": "90s Bedroom", "has_slots": true,
	},
	"passthrough": {
		"path": "res://Scenes/PassthroughScene.tscn",
		"title": "PASSTHROUGH", "menu_title": "Passthrough AR", "has_slots": true,
	},
	"test": {
		"path": "res://Scenes/TestScene.tscn",
		"title": "TEST HALLWAY", "menu_title": "Test Hallway", "has_slots": false,
	},
}

## Rooms contributed by mods, merged after the shipped ones.
static var _overlay := ModOverlayTable.new(_ROOMS)


static func _table() -> Dictionary:
	return _overlay.table()


static func has(room_id: String) -> bool:
	return _table().has(room_id)


static func ids() -> Array:
	return _table().keys()


## The row for a room, or {} — never null, so a caller can .get() through it.
static func row(room_id: String) -> Dictionary:
	return _table().get(room_id, {}) as Dictionary


static func path_of(room_id: String) -> String:
	return str(row(room_id).get("path", ""))


## Loading-screen copy. Falls back to the id rather than to empty, so a room with
## a missing title still says something while it builds.
static func title_of(room_id: String) -> String:
	return str(row(room_id).get("title", room_id.to_upper()))


static func menu_title_of(room_id: String) -> String:
	var r := row(room_id)
	return str(r.get("menu_title", r.get("title", room_id)))


static func has_slots(room_id: String) -> bool:
	return bool(row(room_id).get("has_slots", false))


## Every room that keeps save slots, in table order. Was SceneManager.SLOT_ROOMS.
static func slot_rooms() -> Array:
	var out: Array = []
	for room_id: String in _table():
		if has_slots(room_id):
			out.append(room_id)
	return out


## True for a room a mod brought. The SCENE tab uses it to mark them, and a save
## slot belonging to one is left alone rather than pruned when the mod is absent.
static func is_mod_room(room_id: String) -> bool:
	return _overlay.is_mod(room_id)


static func owner_of(room_id: String) -> String:
	return _overlay.owner_of(room_id)


## Register a mod room. Returns "" on success.
static func register_mod_room(room_id: String, d: Dictionary, owner_id: String) -> String:
	if _ROOMS.has(room_id):
		return "'%s' is a shipped room" % room_id
	if _overlay.is_mod(room_id):
		return "'%s' is already registered by mod '%s'" % [room_id, owner_of(room_id)]
	var path := str(d.get("path", ""))
	if path.is_empty():
		return "no path"
	# ResourceLoader, not FileAccess: a res:// path inside a mounted pack is
	# remapped, and FileAccess.file_exists reports false for every one of them.
	if not ResourceLoader.exists(path):
		return "scene does not exist: %s" % path
	var menu_title := str(d.get("menu_title", d.get("title", room_id)))
	_overlay.add(room_id, {
		"path": path,
		"title": str(d.get("title", menu_title.to_upper())),
		"menu_title": menu_title,
		"has_slots": bool(d.get("has_slots", true)),
	}, owner_id)
	return ""


static func drop_mod(owner_id: String) -> void:
	_overlay.drop_owner(owner_id)

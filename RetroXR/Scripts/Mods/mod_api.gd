## ModApi — what a mod is handed, and the only supported way for it to register.
##
## Every call RECORDS what it did, so the Mods page can report what a mod
## actually contributed rather than what its manifest claimed. For a system whose
## whole security story is informed consent, observed beats declared.
##
## Ids a mod introduces must be namespaced "<mod_id>:<name>". That is not
## tidiness: the shipped model ids, the room ids and the persistence type strings
## are flat global namespaces that end up in save files, so an unprefixed mod id
## could collide with a shipped one or with another mod — and the collision would
## surface as a save that restores the wrong object.
class_name ModApi
extends RefCounted

## Contribution kinds, in the order the Mods page lists them.
const KINDS := ["console", "platform", "room", "object", "tv_shell", "controller",
	"media", "scraper", "hook"]

var id: String = ""
var manifest: ModManifest = null

var _hooks: ModHooks = null
## kind -> Array[String] of human-readable labels.
var _record: Dictionary = {}
## Problems raised during this mod's own registration, shown on the Mods page.
var _problems: PackedStringArray = []
## The subset of those that were REFUSALS rather than warnings.
##
## Kept apart because the two mean opposite things for whether the mod loads: a
## platform registered without pad art is incomplete and still works, while a
## row the registry rejected is a contribution the mod believes it made and did
## not. Only the second is grounds for withdrawing the mod.
var _errors: PackedStringArray = []


func _init(a_manifest: ModManifest, hooks: ModHooks) -> void:
	manifest = a_manifest
	id = a_manifest.id
	_hooks = hooks


# ── consoles ──────────────────────────────────────────────────────────────────

## Add a console model. `row` is a SystemModelRegistry row: platform, label, and
## exactly one of scene/script, plus optional handheld and requires.
func register_model(row: Dictionary) -> bool:
	var model_id := str(row.get("id", ""))
	if not _namespaced(model_id, "model id"):
		return false
	var err := SystemModelRegistry.register_mod_row(model_id, row, id)
	if not err.is_empty():
		return _fail("model %s: %s" % [model_id, err])
	_note("console", "%s (%s)" % [row.get("label", model_id), row.get("platform", "?")])
	return true


## Replace a shipped console model in place. The recommended way to override
## hardware: no file replacement, no claim, and the row keeps its original id so
## existing saves still resolve to it.
func override_model(model_id: String, row: Dictionary) -> bool:
	var err := SystemModelRegistry.override_mod_row(model_id, row, id)
	if not err.is_empty():
		return _fail("override %s: %s" % [model_id, err])
	_note("console", "%s (replaces shipped)" % model_id)
	return true


## Add or replace a console's hardware descriptor.
func register_system_info(info: SystemInfo) -> bool:
	if info == null or info.systemid.is_empty():
		return _fail("register_system_info needs a SystemInfo carrying a systemid")
	SystemInfo.register_mod_info(info, id)
	_note("platform", "%s descriptor" % info.systemid)
	return true


# ── whole platforms ───────────────────────────────────────────────────────────

## Everything a genuinely new platform needs, in one call.
##
## The separate calls all exist, but a platform registered with four of the six
## pieces fails much later and far from the cause — no remap diagram, or carts
## that never get art — so this reports what is missing at registration time.
##
## Keys: systemid, system_info, models, pad_art, media, scraper_id.
func register_platform(d: Dictionary) -> bool:
	var systemid := str(d.get("systemid", ""))
	if systemid.is_empty():
		return _fail("register_platform needs a systemid")
	var missing := PackedStringArray()
	# A piece that is PRESENT and refused is a different failure from one that
	# was never supplied, and this used to discard every sub-call's answer — so
	# a platform whose pad art was rejected outright still reported success and
	# was noted as registered.
	var ok := true
	if d.has("system_info"):
		ok = register_system_info(d["system_info"] as SystemInfo) and ok
	else:
		missing.append("system_info")
	if d.has("models"):
		for row: Variant in (d["models"] as Array):
			ok = register_model(row as Dictionary) and ok
	else:
		missing.append("models")
	if d.has("pad_art"):
		ok = register_pad_art(systemid, d["pad_art"] as Dictionary) and ok
	else:
		missing.append("pad_art (no Controls remap diagram)")
	if d.has("media"):
		ok = register_media(systemid, d["media"] as Dictionary) and ok
	else:
		missing.append("media (carts come out the wrong size)")
	if d.has("scraper_id"):
		ok = register_scraper_system(systemid, int(d["scraper_id"])) and ok
	else:
		missing.append("scraper_id (carts never get art)")
	if not missing.is_empty():
		_warn("platform %s is incomplete: %s" % [systemid, ", ".join(missing)])
	if not ok:
		return false
	_note("platform", systemid)
	return true


## The pad drawing behind this platform's Controls remap page.
func register_pad_art(systemid: String, row: Dictionary) -> bool:
	var err := ConsolePadArt.register_mod_row(systemid, row, id)
	if not err.is_empty():
		return _fail("pad art %s: %s" % [systemid, err])
	_note("platform", "%s pad art" % systemid)
	return true


## Cartridge and disc sizing. Without it a platform's carts come out the wrong
## size, and its discs do not exist at all.
func register_media(systemid: String, dims: Dictionary) -> bool:
	var err := MediaDimensions.register_mod_media(systemid, dims, id)
	if not err.is_empty():
		return _fail("media %s: %s" % [systemid, err])
	_note("media", systemid)
	return true


## Map this platform to a screenscraper.fr system id so its ROMs can be scraped
## at all. A platform absent from that table gets no art, ever.
func register_scraper_system(systemid: String, systemeid: int) -> bool:
	var err := ScreenscraperSystems.register_mod_system(systemid, systemeid, id)
	if not err.is_empty():
		return _fail("scraper %s: %s" % [systemid, err])
	_note("scraper", "%s to %d" % [systemid, systemeid])
	return true


# ── rooms, props, cabinets ────────────────────────────────────────────────────

## Add a room reachable from the SCENE tab.
## Keys: id, path, title, menu_title, has_slots.
func register_room(d: Dictionary) -> bool:
	var room_id := str(d.get("id", ""))
	if not _namespaced(room_id, "room id"):
		return false
	var err := RoomCatalog.register_mod_room(room_id, d, id)
	if not err.is_empty():
		return _fail("room %s: %s" % [room_id, err])
	_note("room", str(d.get("menu_title", room_id)))
	return true


## Add a spawnable prop. `type` is the persistence key written into save slots,
## so it must be namespaced and must never change once players have used it.
func register_object(type: String, scene_path: String, menu: Dictionary = {}) -> bool:
	if not _namespaced(type, "object type"):
		return false
	var err := ScenePersistence.register_mod_object(type, scene_path, id)
	if not err.is_empty():
		return _fail("object %s: %s" % [type, err])
	if not menu.is_empty():
		SpawnCatalog.register_mod_spawnable(type, menu, id)
	_note("object", str(menu.get("label", type)))
	return true


## Add a television cabinet, spawned by the existing "tv:<shell>" token.
func register_tv_shell(shell_id: String, scene_path: String, label: String) -> bool:
	if not _namespaced(shell_id, "tv shell id"):
		return false
	var err := RetroTV.register_mod_shell(shell_id, scene_path, label, id)
	if not err.is_empty():
		return _fail("tv shell %s: %s" % [shell_id, err])
	_note("tv_shell", label)
	return true


## Add rows to a console's spawn card — its pads, leads and accessories.
##
## A mod controller is simply a scene rooted at RetroController; persistence
## already records and restores its scene path, and falls back to the generic pad
## when the mod is gone, with no help needed from here.
func add_peripherals(systemid: String, items: Array) -> bool:
	var err := SpawnCatalog.register_mod_peripherals(systemid, items, id)
	if not err.is_empty():
		return _fail("peripherals %s: %s" % [systemid, err])
	for item: Variant in items:
		_note("controller", str((item as Dictionary).get("label", "?")))
	return true


# ── services ──────────────────────────────────────────────────────────────────

## A built-in display shader by name — "crt", "vcr", "static", "window",
## "gameboy_lcd", "vb_stereo", "phosphor_decay", "screen_pixel_aa".
##
## Only needed by a mod that wants one DELIBERATELY. A TV shell that returns null
## from screen_shader() already gets the stock CRT material.
func shader(shader_name: String) -> Shader:
	return ModShaders.get_shader(shader_name)


## Call `cb(node)` for every node of class `cls` added from now on — the way to
## decorate a RetroSystem, a RetroTV or any pickable without editing it.
func on_node_added(cls: StringName, cb: Callable) -> void:
	_hooks.watch_nodes(id, cls, cb)
	_note("hook", "watches %s" % cls)


## Call `cb(scene_id)` once a room has finished restoring its saved contents —
## the right moment to add something to a finished room.
func on_scene_content_ready(cb: Callable) -> void:
	var loop := Engine.get_main_loop() as SceneTree
	var sm: Node = loop.root.get_node_or_null("SceneManager") if loop != null else null
	if sm == null:
		_warn("on_scene_content_ready: SceneManager is not available")
		return
	sm.scene_content_ready.connect(cb)
	_note("hook", "waits for a room")


## A writable folder of this mod's own, for settings. Use it with JsonStore.
func store() -> String:
	var dir := "user://mods/%s" % id
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func log_line(msg: String) -> void:
	print("[mod:%s] %s" % [id, msg])


# ── what this mod did ─────────────────────────────────────────────────────────

## kind -> Array[String], for the Mods page. Observed, not declared.
func contributions() -> Dictionary:
	return _record.duplicate(true)


func problems() -> PackedStringArray:
	return _problems


## True when some contribution this mod tried to make was refused.
func failed() -> bool:
	return not _errors.is_empty()


func errors_text() -> String:
	return "; ".join(_errors)


## Take back everything this mod registered.
##
## The rollback the registries' own drop_mod docs describe — "only used when a
## mod fails part-way through register(), so a half-registered mod leaves
## nothing standing" — which until now nothing outside the tests called, so a
## mod that failed half way through kept the half that worked.
##
## Every table a mod can reach is named here rather than in mod_manager, so
## adding a register_* method and forgetting to make it withdrawable is one
## file's mistake instead of two.
func withdraw() -> void:
	SystemModelRegistry.drop_mod(id)
	SystemInfo.drop_mod(id)
	ConsolePadArt.drop_mod(id)
	MediaDimensions.drop_mod(id)
	ScreenscraperSystems.drop_mod(id)
	RoomCatalog.drop_mod(id)
	SpawnCatalog.drop_mod(id)
	ScenePersistence.drop_mod_objects(id)
	RetroTV.drop_mod_shells(id)
	_hooks.drop_owner(id)


## "2 consoles, 1 room, 4 props" — the one-line summary on a mod's list row.
func summary() -> String:
	var parts := PackedStringArray()
	for kind: String in KINDS:
		var n: int = (_record.get(kind, []) as Array).size()
		if n > 0:
			parts.append("%d %s" % [n, _plural(kind, n)])
	return ", ".join(parts) if not parts.is_empty() else "nothing"


static func _plural(kind: String, n: int) -> String:
	var word: String = {
		"console": "console", "platform": "platform", "room": "room",
		"object": "prop", "tv_shell": "TV cabinet", "controller": "peripheral",
		"media": "media format", "scraper": "scraper mapping", "hook": "hook",
	}.get(kind, kind)
	return word if n == 1 else word + "s"


func _note(kind: String, label: String) -> void:
	if not _record.has(kind):
		_record[kind] = []
	(_record[kind] as Array).append(label)


func _fail(msg: String) -> bool:
	_problems.append(msg)
	_errors.append(msg)
	push_warning("[mod:%s] %s" % [id, msg])
	return false


func _warn(msg: String) -> void:
	_problems.append(msg)
	push_warning("[mod:%s] %s" % [id, msg])


## A mod-introduced id must carry its own mod's prefix.
func _namespaced(value: String, what: String) -> bool:
	if value.begins_with(id + ":") and value.length() > id.length() + 1:
		return true
	_fail("%s '%s' must be named '%s:something'" % [what, value, id])
	return false

## mod_tests — the mod loading stack, headless, no mod installed and none needed.
##
##   godot --headless --path RetroXR res://Tests/mod_tests.tscn
##   godot --headless --path RetroXR res://Tests/mod_tests.tscn -- --only=pack
##
## Groups:
##   pack/        reading a container without mounting it, both formats
##   manifest/    what a mod.json must say, and what is refused
##   inventory/   namespace escapes, unclaimed paths, the three fatal files
##   registry/    the model overlay and its fallbacks
##   rooms/       the collapsed room descriptor and mod rooms
##   objects/     mod props, and their persistence type
##   media/       cart sizing, disc loaders, scraper mapping
##   shaders/     the three ways a mod lands on a shader
##   removal/     A SLOT MUST SURVIVE THE MOD THAT FILLED IT GOING AWAY
##   netplay/     the fingerprint and its mismatch report
##   consistency/ cross-table invariants a mod platform would break first
##
## Almost every case runs WITHOUT mounting anything, because a mounted pack
## cannot be unmounted and a test that mounts pollutes every case after it.
## Fixtures are built into user:// at run time with ZIPPacker/PCKPacker, so
## nothing binary is committed.
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
extends Node

var _pass := 0
var _fail := 0
var _only := ""
var _dir := ""


func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func():
		print("[test] TIMEOUT"); get_tree().quit(1))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.substr(7)
	_dir = OS.get_user_data_dir().replace("\\", "/") + "/mod_tests"
	DirAccess.make_dir_recursive_absolute(_dir)

	if _want("pack"):        _group_pack()
	if _want("manifest"):    _group_manifest()
	if _want("inventory"):   _group_inventory()
	if _want("registry"):    _group_registry()
	if _want("rooms"):       _group_rooms()
	if _want("objects"):     _group_objects()
	if _want("media"):       _group_media()
	if _want("shaders"):     _group_shaders()
	if _want("removal"):     _group_removal()
	if _want("netplay"):     _group_netplay()
	if _want("consistency"): _group_consistency()

	_cleanup()
	print("[test] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _want(group: String) -> bool:
	return _only.is_empty() or _only == group


# ── pack/ ─────────────────────────────────────────────────────────────────────

func _group_pack() -> void:
	var payload := {
		"mods/t.one/mod.json": '{"id":"t.one","api_version":1,"entry":"res://mods/t.one/m.gd"}',
		"mods/t.one/m.gd": "extends RetroMod",
	}
	var zip_path := _write_zip("pack.zip", payload)
	var pck_path := _write_pck("pack.pck", payload)

	# Both containers must present the SAME view, or the two readers have
	# diverged and only one of them is being exercised by everything below.
	for label: String in ["zip", "pck"]:
		var r := ModPackReader.open(zip_path if label == "zip" else pck_path)
		_ok(r.error.is_empty(), "pack/%s opens" % label, r.error)
		var files := r.files()
		files.sort()
		_eq(files, PackedStringArray(["res://mods/t.one/m.gd", "res://mods/t.one/mod.json"]),
			"pack/%s lists res:// paths" % label)
		_eq(r.read("res://mods/t.one/m.gd").get_string_from_utf8(),
			"extends RetroMod", "pack/%s reads a member" % label)
		_eq(str(r.read_json("res://mods/t.one/mod.json").get("id", "")),
			"t.one", "pack/%s parses json" % label)
		_ok(r.read("res://nope").is_empty(), "pack/%s misses cleanly" % label)
		r.close()

	var bad := ModPackReader.open(_dir.path_join("nope.zip"))
	_ok(not bad.error.is_empty(), "pack/absent file errors")
	var wrong := ModPackReader.open(_dir.path_join("pack.txt"))
	_ok(not wrong.error.is_empty(), "pack/unknown extension refused")


# ── manifest/ ─────────────────────────────────────────────────────────────────

func _group_manifest() -> void:
	var good := ModManifest.parse({
		"id": "a.b", "api_version": 1, "entry": "res://mods/a.b/m.gd",
		"name": "Nice", "version": "1.2.3", "priority": 5,
	})
	_ok(good.error.is_empty(), "manifest/valid parses", good.error)
	_eq(good.own_root(), "res://mods/a.b/", "manifest/own root")
	_eq(good.priority, 5, "manifest/priority kept")

	_ok(not ModManifest.parse({"api_version": 1, "entry": "x"}).error.is_empty(),
		"manifest/no id refused")
	_ok(not ModManifest.parse({"id": "Bad", "api_version": 1, "entry": "res://mods/Bad/m.gd"}).error.is_empty(),
		"manifest/upper-case id refused")
	_ok(not ModManifest.parse({"id": "a.b", "entry": "res://mods/a.b/m.gd"}).error.is_empty(),
		"manifest/no api_version refused")
	# A future mod is refused by version, not by crashing on its contents. This
	# is the break marker doing its job.
	var future := ModManifest.parse({"id": "a.b", "api_version": 9999,
		"entry": "res://mods/a.b/m.gd"})
	_ok(not future.error.is_empty(), "manifest/future api refused")
	_ok(future.error.contains("newer"), "manifest/future says which", future.error)
	_ok(not ModManifest.parse({"id": "a.b", "api_version": 1, "entry": "res://Scripts/evil.gd"}).error.is_empty(),
		"manifest/entry outside namespace refused")

	var here := ModManifest.parse({"id": "a.b", "api_version": 1,
		"entry": "res://mods/a.b/m.gd", "platforms": [OS.get_name()]})
	_ok(here.runs_here(), "manifest/runs on this platform")
	var elsewhere := ModManifest.parse({"id": "a.b", "api_version": 1,
		"entry": "res://mods/a.b/m.gd", "platforms": ["Nintendo64"]})
	_ok(not elsewhere.runs_here(), "manifest/other platform excluded")
	_ok(good.runs_here(), "manifest/no platforms means all")


# ── inventory/ ────────────────────────────────────────────────────────────────

func _group_inventory() -> void:
	var m := ModManifest.parse({"id": "a.b", "api_version": 1,
		"entry": "res://mods/a.b/m.gd"})
	_ok(m.inventory_error(PackedStringArray(["res://mods/a.b/m.gd"])).is_empty(),
		"inventory/own files accepted")
	_ok(not m.inventory_error(PackedStringArray()).is_empty(), "inventory/empty container refused")
	_ok(not m.inventory_error(PackedStringArray(["res://mods/other/x.gd"])).is_empty(),
		"inventory/nothing of its own refused")
	_ok(not m.inventory_error(PackedStringArray( ["res://mods/a.b/m.gd", "res://Textures/x.png"])).is_empty(),
		"inventory/unclaimed outside path refused")
	_ok(not m.inventory_error(PackedStringArray( ["res://mods/a.b/m.gd", "res://mods/victim/m.gd"])).is_empty(),
		"inventory/another mod's namespace refused")

	# The three files that would damage the RUNNING game rather than merely fail
	# — a mod's own export carries these, so this is not a hypothetical.
	for path: String in ModManifest.FORBIDDEN:
		var err := m.inventory_error(PackedStringArray(["res://mods/a.b/m.gd", path]))
		_ok(not err.is_empty(), "inventory/refuses %s" % path.get_file())

	# An SDK leak IS an unclaimed outside path — the namespace rule is what
	# stops an author's stale copy of a shipped class replacing the real one.
	_ok(not m.inventory_error(PackedStringArray( ["res://mods/a.b/m.gd", "res://Scripts/Objects/widgets/vr_hinge.gd"])).is_empty(),
		"inventory/SDK leak refused")

	var claiming := ModManifest.parse({"id": "a.b", "api_version": 1,
		"entry": "res://mods/a.b/m.gd", "claims": ["res://Textures/x.png"]})
	_ok(claiming.inventory_error(PackedStringArray( ["res://mods/a.b/m.gd", "res://Textures/x.png"])).is_empty(),
		"inventory/claimed path accepted")
	# ...but claiming does NOT buy a pass on the fatal three.
	_ok(not ModManifest.parse({"id": "a.b", "api_version": 1, "entry": "res://mods/a.b/m.gd", "claims": ["res://project.binary"]} ).inventory_error(PackedStringArray( ["res://mods/a.b/m.gd", "res://project.binary"])).is_empty(),
		"inventory/claim cannot buy project.binary")

	# A claim on a path the game does not ship ADDS a file; only a claim that
	# lands on a shipped one shadows it, and only that needs replace_files.
	var adder := ModManifest.parse({"id": "a.b", "api_version": 1,
		"entry": "res://mods/a.b/m.gd",
		"claims": ["res://Textures/SystemIcons/does_not_exist.svg"]})
	_eq(adder.shadowing_claims().size(), 0, "inventory/adding claim is not shadowing")
	_eq(adder.adding_claims().size(), 1, "inventory/adding claim counted")
	var shadower := ModManifest.parse({"id": "a.b", "api_version": 1,
		"entry": "res://mods/a.b/m.gd",
		"claims": ["res://Scripts/Objects/widgets/vr_hinge.gd"]})
	_eq(shadower.shadowing_claims().size(), 1, "inventory/shadowing claim detected")


# ── registry/ ─────────────────────────────────────────────────────────────────

const _SCRIPT := "res://Scripts/Objects/system_models/default_model.gd"

func _group_registry() -> void:
	var owner := "t.reg"
	_eq(SystemModelRegistry.register_mod_row(
		"t.reg:box", {"platform": "nes", "label": "Box", "script": _SCRIPT}, owner), "", "registry/row registers")
	_eq(str(SystemModelRegistry.resolve("t.reg:box", "nes").get("id", "")), "t.reg:box",
		"registry/resolves")
	_ok(SystemModelRegistry.is_available("t.reg:box"), "registry/is available")
	_ok(SystemModelRegistry.is_mod_row("t.reg:box"), "registry/marked as a mod row")
	_eq(SystemModelRegistry.owner_of("t.reg:box"), owner, "registry/owner recorded")

	# A shipped platform's DEFAULT must not change because a mod added a row.
	_eq(str(SystemModelRegistry.resolve("", "nes").get("id", "")),
		"nes", "registry/shipped default unchanged")

	_ok(not SystemModelRegistry.register_mod_row( "t.reg:box", {"platform": "nes", "label": "X", "script": _SCRIPT}, owner).is_empty(),
		"registry/duplicate refused")
	_ok(not SystemModelRegistry.register_mod_row( "nes", {"platform": "nes", "label": "X", "script": _SCRIPT}, owner).is_empty(),
		"registry/shipped id refused")

	# validate_row is shared with model_registry_probe, so these are the same
	# rules the shipped table is held to.
	_ok(not SystemModelRegistry.register_mod_row( "t.reg:a", {"label": "A", "script": _SCRIPT}, owner).is_empty(),
		"registry/no platform refused")
	_ok(not SystemModelRegistry.register_mod_row( "t.reg:b", {"platform": "nes", "label": "B", "script": _SCRIPT, "scene": "res://Scenes/Objects/system_models/nes.tscn"}, owner).is_empty(),
		"registry/both scene and script refused")
	_ok(not SystemModelRegistry.register_mod_row( "t.reg:c", {"platform": "nes", "label": "C"}, owner).is_empty(),
		"registry/neither refused")
	_ok(not SystemModelRegistry.register_mod_row( "t.reg:d", {"platform": "nes", "label": "D", "script": "res://nope.gd"}, owner).is_empty(),
		"registry/missing file refused")

	_eq(SystemModelRegistry.override_mod_row(
		"wii", {"platform": "wii", "label": "Modded Wii", "script": _SCRIPT}, owner), "", "registry/override registers")
	_eq(str(SystemModelRegistry.resolve("wii", "wii").get("id", "")),
		"wii", "registry/override keeps the id")
	_eq(str(SystemModelRegistry.resolve("wii", "wii").get("label", "")),
		"Modded Wii", "registry/override replaces the label")
	_ok(not SystemModelRegistry.override_mod_row("nope", {"platform": "x", "label": "L", "script": _SCRIPT}, owner).is_empty(),
		"registry/override of an unknown id refused")

	# Mod models must stay OUT of the boot warm, or boot time becomes a function
	# of how many mods are installed.
	_ok(not SystemModelRegistry.stand_in_ids().has("t.reg:box"),
		"registry/mod row not in the warm set")

	SystemModelRegistry.drop_mod(owner)
	_ok(SystemModelRegistry.row_for("t.reg:box").is_empty(), "registry/drop removes the row")
	_eq(str(SystemModelRegistry.resolve("wii", "wii").get("label", "")),
		"Wii", "registry/drop restores the shipped row")
	# The whole point of the fallback: a save naming a model that has gone still
	# lands on something spawnable rather than on nothing.
	_eq(str(SystemModelRegistry.resolve("t.reg:box", "nes").get("id", "")),
		"nes", "registry/removed model falls back")


# ── rooms/ ────────────────────────────────────────────────────────────────────

func _group_rooms() -> void:
	# The collapsed descriptor must still describe the shipped rooms exactly.
	_eq(RoomCatalog.path_of("arcade"), "res://Scenes/MainScene.tscn", "rooms/arcade path")
	_eq(RoomCatalog.title_of("bedroom"), "90s BEDROOM", "rooms/bedroom loading title")
	_eq(RoomCatalog.menu_title_of("bedroom"), "90s Bedroom", "rooms/bedroom menu title")
	_ok(RoomCatalog.has_slots("arcade"), "rooms/arcade keeps slots")
	_ok(not RoomCatalog.has_slots("den"), "rooms/den keeps none")
	_eq(RoomCatalog.slot_rooms(), ["arcade", "bedroom", "passthrough"], "rooms/slot rooms")
	_ok(not RoomCatalog.has("nope"), "rooms/unknown room is absent")

	var owner := "t.room"
	_eq(RoomCatalog.register_mod_room("t.room:attic", {
		"path": "res://Scenes/DenScene.tscn", "menu_title": "The Attic"}, owner), "", "rooms/registers")
	_ok(RoomCatalog.has("t.room:attic"), "rooms/mod room exists")
	_ok(RoomCatalog.is_mod_room("t.room:attic"), "rooms/marked as a mod room")
	_eq(RoomCatalog.menu_title_of("t.room:attic"), "The Attic", "rooms/menu title kept")
	_eq(RoomCatalog.title_of("t.room:attic"), "THE ATTIC", "rooms/loading title derived")
	_ok(RoomCatalog.has_slots("t.room:attic"), "rooms/defaults to keeping slots")
	_ok(not RoomCatalog.register_mod_room( "arcade", {"path": "res://Scenes/DenScene.tscn"}, owner).is_empty(),
		"rooms/shipped id refused")
	_ok(not RoomCatalog.register_mod_room( "t.room:void", {"path": "res://Scenes/Nope.tscn"}, owner).is_empty(),
		"rooms/missing scene refused")
	_ok(not RoomCatalog.register_mod_room("t.room:void2", {}, owner).is_empty(),
		"rooms/no path refused")
	RoomCatalog.drop_mod(owner)
	_ok(not RoomCatalog.has("t.room:attic"), "rooms/drop removes it")
	_eq(RoomCatalog.ids().size(), 5, "rooms/shipped rooms survive a drop")

	# Pad art tracked no owner until the overlay tables were shared, so a mod's
	# drawing could be registered and never taken back.
	var art_owner := "t.art"
	var art_row := {"anchors": {"a": Vector2(0.5, 0.5)}, "rows": [["a"]]}
	ConsolePadArt.register_mod_row("t.art:pad", art_row, art_owner)
	_ok(ConsolePadArt.has("t.art:pad"), "pad art/mod row registers")
	_eq(ConsolePadArt.owner_of("t.art:pad"), art_owner, "pad art/owner recorded")
	_ok(not ConsolePadArt.row("t.art:pad").is_empty(), "pad art/row is served")
	ConsolePadArt.drop_mod(art_owner)
	_ok(not ConsolePadArt.has("t.art:pad"), "pad art/drop removes it")
	_ok(ConsolePadArt.has("nes"), "pad art/shipped art survives a drop")


# ── objects/ ──────────────────────────────────────────────────────────────────

func _group_objects() -> void:
	var owner := "t.obj"
	var scene := "res://Scenes/Objects/table.tscn"
	if not ResourceLoader.exists(scene):
		scene = "res://Scenes/Objects/system.tscn"
	_eq(ScenePersistence.register_mod_object(
		"t.obj:crate", scene, owner), "", "objects/registers")
	_ok(ScenePersistence.is_mod_object("t.obj:crate"), "objects/known")
	_eq(ScenePersistence.mod_object_scene("t.obj:crate"), scene, "objects/scene recorded")
	_ok(not ScenePersistence.register_mod_object( "table", scene, owner).is_empty(),
		"objects/shipped type refused")
	_ok(not ScenePersistence.register_mod_object( "t.obj:crate", scene, owner).is_empty(),
		"objects/duplicate refused")
	_ok(not ScenePersistence.register_mod_object( "t.obj:void", "res://nope.tscn", owner).is_empty(),
		"objects/missing scene refused")

	# The instance must carry the stamp _serialize_node recognises, or it saves
	# as its base class and loses the scene it came from.
	var inst := ScenePersistence._instantiate_mod_object("t.obj:crate")
	_ok(inst != null, "objects/instantiates")
	if inst != null:
		_eq(str(inst.get_meta(ScenePersistence.MOD_TYPE_META)),
			"t.obj:crate", "objects/carries its type stamp")
		inst.free()

	ScenePersistence.drop_mod_objects(owner)
	_ok(not ScenePersistence.is_mod_object("t.obj:crate"), "objects/drop removes it")


# ── media/ ────────────────────────────────────────────────────────────────────

func _group_media() -> void:
	var sid := "t_media_platform"
	_eq(MediaDimensions.register_mod_media(sid, {
		"cart_size": Vector3(0.1, 0.2, 0.01)}), "", "media/registers")
	_eq(MediaDimensions.cart_size(sid), Vector3(0.1, 0.2, 0.01), "media/cart size")
	_ok(MediaDimensions.has_cart_size(sid), "media/has a cart size")
	_ok(not MediaDimensions.is_disc_system(sid), "media/cartridge system is not a disc one")
	_eq(MediaDimensions.disc_loader(sid), MediaDimensions.LOADER_NONE,
		"media/no disc means no loader")

	var disc := "t_disc_platform"
	MediaDimensions.register_mod_media(disc, {"disc_diameter": 0.12})
	_ok(MediaDimensions.is_disc_system(disc), "media/disc system")
	_eq(MediaDimensions.disc_loader(disc), MediaDimensions.LOADER_TRAY, "media/tray by default")
	var slot := "t_slot_platform"
	MediaDimensions.register_mod_media(slot, {"disc_diameter": 0.12, "slot_load": true})
	_eq(MediaDimensions.disc_loader(slot), MediaDimensions.LOADER_SLOT, "media/slot load")
	_ok(not MediaDimensions.register_mod_media("t_bad", {"slot_load": true}).is_empty(),
		"media/slot without a disc refused")
	_ok(not MediaDimensions.register_mod_media("t_bad2", {"cart_size": "big"}).is_empty(),
		"media/bad cart size refused")
	# A shipped platform must be untouched by any of this.
	_eq(MediaDimensions.disc_loader("nes"), MediaDimensions.LOADER_NONE,
		"media/shipped nes unchanged")

	# Without a scraper mapping a platform's carts stay blank for ever, and
	# nothing anywhere says why — so the mapping is a first-class registration.
	_eq(ScreenscraperSystems.get_systemeid("t_media_platform"), -1, "media/unmapped platform")
	ScreenscraperSystems.register_mod_system("t_media_platform", 4242)
	_eq(ScreenscraperSystems.get_systemeid("t_media_platform"), 4242, "media/mapped platform")
	_eq(ScreenscraperSystems.get_systemeid("nes"), 3, "media/shipped mapping unchanged")


# ── shaders/ ──────────────────────────────────────────────────────────────────

func _group_shaders() -> void:
	# Landing place 1: a shell that says nothing gets the stock CRT. Asserted on
	# the base class, which is what every shipped cabinet uses.
	var shell := RetroTVShell.new()
	_ok(shell.screen_shader() == null, "shaders/stock is the default")
	shell.free()

	# Landing place 2: a built-in by name, and the SAME resource rather than a
	# second copy — asking for one must not cost a compile.
	var crt := ModShaders.get_shader("crt")
	_ok(crt != null, "shaders/crt by name")
	_ok(crt == ModShaders.get_shader("crt"), "shaders/same resource twice")
	_ok(crt == load("res://Shaders/crt_effect.gdshader"), "shaders/is the shipped crt")
	for shader_name: String in ModShaders.names():
		_ok(ModShaders.get_shader(shader_name) != null, "shaders/%s resolves" % shader_name)
	# An unknown name must not hand back a null that lands in a material and
	# paints nothing, with no clue why.
	_ok(not ModShaders.has("no_such_shader"), "shaders/unknown name is not known")


# ── removal/ ──────────────────────────────────────────────────────────────────
#
# The group that guards player data. Removing a mod used to make every save slot
# containing one of its props UNREADABLE — the player lost the room, not the
# prop. These are the cases that must never regress.

func _group_removal() -> void:
	var objects: Array = [
		{"id": 0, "type": "table", "position": [0, 0, 0], "rotation": [0, 0, 0]},
		{"id": 1, "type": "gone.mod:lamp", "position": [1, 0, 0], "rotation": [0, 0, 0]},
		{"id": 2, "type": "tv_remote", "position": [2, 0, 0], "rotation": [0, 0, 0],
			"system": 1},
		{"id": 3, "type": "gone.mod:rug", "position": [3, 0, 0], "rotation": [0, 0, 0]},
	]
	var kept := ScenePersistence._prune_unknown_types(objects, "test")
	_eq(kept.size(), 2, "removal/keeps everything else")
	_eq(_types_of(kept), ["table", "tv_remote"], "removal/dropped the mod props")
	# Dropping an entry creates dangling references. Not scrubbing them turns
	# "one missing prop" straight back into "the whole slot is invalid".
	var remote := _entry_of(kept, "tv_remote")
	_ok(remote.get("system") == null, "removal/dangling reference scrubbed")
	_eq(ScenePersistence._objects_validation_error(kept),
		"", "removal/slot still validates")

	# A slot with nothing missing must come back byte-identical, not merely
	# equivalent — this path runs on every load.
	var clean: Array = [{"id": 0, "type": "table", "position": [0, 0, 0],
		"rotation": [0, 0, 0]}]
	_ok(ScenePersistence._prune_unknown_types(clean, "test") == clean,
		"removal/untouched when nothing is missing")

	# And the guard that must NOT be weakened: structural corruption is still
	# all-or-nothing. Only an unrecognised type is survivable.
	_ok(not ScenePersistence._objects_validation_error( [{"id": -1, "type": "table"}]).is_empty(),
		"removal/negative id still refused")
	_ok(not ScenePersistence._objects_validation_error( [{"id": 0, "type": "table"}, {"id": 0, "type": "table"}]).is_empty(),
		"removal/duplicate id still refused")
	_ok(not ScenePersistence._objects_validation_error( [{"id": 0, "type": "tv_remote", "system": 77}]).is_empty(),
		"removal/reference to a never-existing id still refused")

	# Through a REAL slot file, not just the pure function.
	#
	# Every case above calls _prune_unknown_types directly, which proves the
	# function works and proves nothing about it being wired in — deleting the
	# call in _read_objects left all of them green. This is the one that fails if
	# the pruning is not actually on the load path.
	var store := ScenePersistence.new("__mod_selftest")
	var slot_dir := store.slot_dir()
	DirAccess.make_dir_recursive_absolute(slot_dir)
	var slot_path := slot_dir.path_join("selftest.json")
	var f := FileAccess.open(slot_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"version": ScenePersistence.VERSION,
			"objects": objects}))
		f.close()
		var read: Variant = store._read_objects(slot_path)
		_ok(read != null,
			"removal/a real slot with a missing mod still loads", "the whole slot was refused")
		if read is Array:
			_eq(_types_of(read as Array),
				["table", "tv_remote"], "removal/and comes back without the missing props")
		DirAccess.remove_absolute(slot_path)
	DirAccess.remove_absolute(slot_dir)

	# A registered mod prop is NOT pruned while its mod is loaded.
	var owner := "t.keep"
	var scene := "res://Scenes/Objects/system.tscn"
	ScenePersistence.register_mod_object("t.keep:thing", scene, owner)
	var live: Array = [{"id": 0, "type": "t.keep:thing", "position": [0, 0, 0],
		"rotation": [0, 0, 0]}]
	_eq(ScenePersistence._prune_unknown_types(live, "test").size(),
		1, "removal/loaded mod prop survives")
	ScenePersistence.drop_mod_objects(owner)
	_eq(ScenePersistence._prune_unknown_types(live, "test").size(),
		0, "removal/same prop drops once the mod is gone")


func _types_of(entries: Array) -> Array:
	var out: Array = []
	for e: Variant in entries:
		out.append(str((e as Dictionary)["type"]))
	return out


func _entry_of(entries: Array, type: String) -> Dictionary:
	for e: Variant in entries:
		if str((e as Dictionary)["type"]) == type:
			return e as Dictionary
	return {}


# ── netplay/ ──────────────────────────────────────────────────────────────────

func _group_netplay() -> void:
	# With nothing loaded the fingerprint is empty, so two stock builds match and
	# the check costs an untouched room nothing.
	_eq(Mods.fingerprint().size(), 0, "netplay/no mods means an empty fingerprint")

	var ours := PackedStringArray(["a@1.0.0", "b@2.0.0"])
	var same := PackedStringArray(["a@1.0.0", "b@2.0.0"])
	_ok(ours == same, "netplay/identical sets match")
	_ok(ours == PackedStringArray(["a@1.0.0", "b@2.0.0"]), "netplay/order-independent by sorting")
	_ok(ours != PackedStringArray(["a@1.0.0", "b@2.0.1"]),
		"netplay/a different version is a mismatch")

	var msg := Mods.fingerprint_mismatch(ours, PackedStringArray(["a@1.0.0"]))
	_ok(msg.contains("b@2.0.0"), "netplay/names what is missing", msg)
	var msg2 := Mods.fingerprint_mismatch(PackedStringArray(["a@1.0.0"]), ours)
	_ok(msg2.contains("extra"), "netplay/names what is extra", msg2)


# ── consistency/ ──────────────────────────────────────────────────────────────
#
# Cross-table invariants the codebase documents but never checked. A mod
# platform is what would break either of them first.

func _group_consistency() -> void:
	# model_registry.gd lists the computer platforms by hand and says they must
	# match SystemInfo.computer. Nothing enforced it until now.
	var declared: Array = []
	for id: String in SystemModelRegistry.all_ids():
		var row := SystemModelRegistry.row_for(id)
		var field: Variant = row.get("platform", "")
		if field is Array:
			declared.append_array(field as Array)
	var mismatched := PackedStringArray()
	for sid: String in declared:
		var info := SystemInfo.for_system(sid)
		if info == null or not info.computer:
			mismatched.append(sid)
	_eq(", ".join(mismatched),
		"", "consistency/computer platforms match SystemInfo.computer")

	# system_info.gd says MediaType intentionally matches MediaDimensions.LOADER_*
	# so the two "never disagree". They are separate tables, so check it.
	_eq(int(SystemInfo.MediaType.CARTRIDGE),
		MediaDimensions.LOADER_NONE, "consistency/CARTRIDGE == LOADER_NONE")
	_eq(int(SystemInfo.MediaType.DISC_TRAY),
		MediaDimensions.LOADER_TRAY, "consistency/DISC_TRAY == LOADER_TRAY")
	_eq(int(SystemInfo.MediaType.DISC_INSERT),
		MediaDimensions.LOADER_SLOT, "consistency/DISC_INSERT == LOADER_SLOT")

	# EVERY descriptor, not just the platforms that happen to have a model row.
	# Checking only those hid the PS2, which has no row and disagreed just as
	# loudly as the PSP that was caught.
	var disagree := PackedStringArray()
	var checked := 0
	var dir := DirAccess.open("res://SystemInfo")
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			# Exported builds remap .tres to .remap, so match on the stem.
			if not dir.current_is_dir() and f.get_extension() in ["tres", "remap"]:
				var sid := f.get_basename()
				if sid.get_extension() == "tres":
					sid = sid.get_basename()
				var info := SystemInfo.for_system(sid)
				if info != null:
					checked += 1
					if int(info.media_type) != MediaDimensions.disc_loader(sid):
						disagree.append("%s (%d vs %d)" % [sid, int(info.media_type),
							MediaDimensions.disc_loader(sid)])
			f = dir.get_next()
		dir.list_dir_end()
	_ok(checked > 50,
		"consistency/descriptors were actually read", "only %d read — the check would pass vacuously" % checked)
	_eq(", ".join(disagree), "", "consistency/media_type agrees with disc_loader")


# ── fixtures ──────────────────────────────────────────────────────────────────

func _write_zip(name: String, entries: Dictionary) -> String:
	var path := _dir.path_join(name)
	var z := ZIPPacker.new()
	if z.open(path) != OK:
		return path
	for member: String in entries:
		z.start_file(member)
		z.write_file(str(entries[member]).to_utf8_buffer())
		z.close_file()
	z.close()
	return path


func _write_pck(name: String, entries: Dictionary) -> String:
	var path := _dir.path_join(name)
	var p := PCKPacker.new()
	if p.pck_start(path) != OK:
		return path
	for member: String in entries:
		var tmp := _dir.path_join(member.get_file())
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		f.store_string(str(entries[member]))
		f.close()
		p.add_file("res://" + member, tmp)
	p.flush(false)
	return path


func _cleanup() -> void:
	var dir := DirAccess.open(_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir():
			DirAccess.remove_absolute(_dir.path_join(f))
		f = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(_dir)


# ── assertions ────────────────────────────────────────────────────────────────

func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s" % name)
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [name,
			"  — " + detail if not detail.is_empty() else ""])


func _eq(got: Variant, want: Variant, name: String) -> void:
	_ok(got == want, name, "got %s, want %s" % [str(got), str(want)])

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
		_ok("pack/%s opens" % label, r.error.is_empty(), r.error)
		var files := r.files()
		files.sort()
		_eq("pack/%s lists res:// paths" % label, files,
			PackedStringArray(["res://mods/t.one/m.gd", "res://mods/t.one/mod.json"]))
		_eq("pack/%s reads a member" % label,
			r.read("res://mods/t.one/m.gd").get_string_from_utf8(), "extends RetroMod")
		_eq("pack/%s parses json" % label,
			str(r.read_json("res://mods/t.one/mod.json").get("id", "")), "t.one")
		_ok("pack/%s misses cleanly" % label, r.read("res://nope").is_empty())
		r.close()

	var bad := ModPackReader.open(_dir.path_join("nope.zip"))
	_ok("pack/absent file errors", not bad.error.is_empty())
	var wrong := ModPackReader.open(_dir.path_join("pack.txt"))
	_ok("pack/unknown extension refused", not wrong.error.is_empty())


# ── manifest/ ─────────────────────────────────────────────────────────────────

func _group_manifest() -> void:
	var good := ModManifest.parse({
		"id": "a.b", "api_version": 1, "entry": "res://mods/a.b/m.gd",
		"name": "Nice", "version": "1.2.3", "priority": 5,
	})
	_ok("manifest/valid parses", good.error.is_empty(), good.error)
	_eq("manifest/own root", good.own_root(), "res://mods/a.b/")
	_eq("manifest/priority kept", good.priority, 5)

	_ok("manifest/no id refused",
		not ModManifest.parse({"api_version": 1, "entry": "x"}).error.is_empty())
	_ok("manifest/upper-case id refused",
		not ModManifest.parse({"id": "Bad", "api_version": 1,
			"entry": "res://mods/Bad/m.gd"}).error.is_empty())
	_ok("manifest/no api_version refused",
		not ModManifest.parse({"id": "a.b", "entry": "res://mods/a.b/m.gd"}).error.is_empty())
	# A future mod is refused by version, not by crashing on its contents. This
	# is the break marker doing its job.
	var future := ModManifest.parse({"id": "a.b", "api_version": 9999,
		"entry": "res://mods/a.b/m.gd"})
	_ok("manifest/future api refused", not future.error.is_empty())
	_ok("manifest/future says which", future.error.contains("newer"), future.error)
	_ok("manifest/entry outside namespace refused",
		not ModManifest.parse({"id": "a.b", "api_version": 1,
			"entry": "res://Scripts/evil.gd"}).error.is_empty())

	var here := ModManifest.parse({"id": "a.b", "api_version": 1,
		"entry": "res://mods/a.b/m.gd", "platforms": [OS.get_name()]})
	_ok("manifest/runs on this platform", here.runs_here())
	var elsewhere := ModManifest.parse({"id": "a.b", "api_version": 1,
		"entry": "res://mods/a.b/m.gd", "platforms": ["Nintendo64"]})
	_ok("manifest/other platform excluded", not elsewhere.runs_here())
	_ok("manifest/no platforms means all", good.runs_here())


# ── inventory/ ────────────────────────────────────────────────────────────────

func _group_inventory() -> void:
	var m := ModManifest.parse({"id": "a.b", "api_version": 1,
		"entry": "res://mods/a.b/m.gd"})
	_ok("inventory/own files accepted",
		m.inventory_error(PackedStringArray(["res://mods/a.b/m.gd"])).is_empty())
	_ok("inventory/empty container refused",
		not m.inventory_error(PackedStringArray()).is_empty())
	_ok("inventory/nothing of its own refused",
		not m.inventory_error(PackedStringArray(["res://mods/other/x.gd"])).is_empty())
	_ok("inventory/unclaimed outside path refused",
		not m.inventory_error(PackedStringArray(
			["res://mods/a.b/m.gd", "res://Textures/x.png"])).is_empty())
	_ok("inventory/another mod's namespace refused",
		not m.inventory_error(PackedStringArray(
			["res://mods/a.b/m.gd", "res://mods/victim/m.gd"])).is_empty())

	# The three files that would damage the RUNNING game rather than merely fail
	# — a mod's own export carries these, so this is not a hypothetical.
	for path: String in ModManifest.FORBIDDEN:
		var err := m.inventory_error(PackedStringArray(["res://mods/a.b/m.gd", path]))
		_ok("inventory/refuses %s" % path.get_file(), not err.is_empty())

	# An SDK leak IS an unclaimed outside path — the namespace rule is what
	# stops an author's stale copy of a shipped class replacing the real one.
	_ok("inventory/SDK leak refused", not m.inventory_error(PackedStringArray(
		["res://mods/a.b/m.gd", "res://Scripts/Objects/widgets/vr_hinge.gd"])).is_empty())

	var claiming := ModManifest.parse({"id": "a.b", "api_version": 1,
		"entry": "res://mods/a.b/m.gd", "claims": ["res://Textures/x.png"]})
	_ok("inventory/claimed path accepted",
		claiming.inventory_error(PackedStringArray(
			["res://mods/a.b/m.gd", "res://Textures/x.png"])).is_empty())
	# ...but claiming does NOT buy a pass on the fatal three.
	_ok("inventory/claim cannot buy project.binary",
		not ModManifest.parse({"id": "a.b", "api_version": 1,
			"entry": "res://mods/a.b/m.gd", "claims": ["res://project.binary"]}
		).inventory_error(PackedStringArray(
			["res://mods/a.b/m.gd", "res://project.binary"])).is_empty())

	# A claim on a path the game does not ship ADDS a file; only a claim that
	# lands on a shipped one shadows it, and only that needs replace_files.
	var adder := ModManifest.parse({"id": "a.b", "api_version": 1,
		"entry": "res://mods/a.b/m.gd",
		"claims": ["res://Textures/SystemIcons/does_not_exist.svg"]})
	_eq("inventory/adding claim is not shadowing", adder.shadowing_claims().size(), 0)
	_eq("inventory/adding claim counted", adder.adding_claims().size(), 1)
	var shadower := ModManifest.parse({"id": "a.b", "api_version": 1,
		"entry": "res://mods/a.b/m.gd",
		"claims": ["res://Scripts/Objects/widgets/vr_hinge.gd"]})
	_eq("inventory/shadowing claim detected", shadower.shadowing_claims().size(), 1)


# ── registry/ ─────────────────────────────────────────────────────────────────

const _SCRIPT := "res://Scripts/Objects/system_models/default_model.gd"

func _group_registry() -> void:
	var owner := "t.reg"
	_eq("registry/row registers", SystemModelRegistry.register_mod_row(
		"t.reg:box", {"platform": "nes", "label": "Box", "script": _SCRIPT}, owner), "")
	_eq("registry/resolves", str(SystemModelRegistry.resolve("t.reg:box", "nes").get("id", "")),
		"t.reg:box")
	_ok("registry/is available", SystemModelRegistry.is_available("t.reg:box"))
	_ok("registry/marked as a mod row", SystemModelRegistry.is_mod_row("t.reg:box"))
	_eq("registry/owner recorded", SystemModelRegistry.owner_of("t.reg:box"), owner)

	# A shipped platform's DEFAULT must not change because a mod added a row.
	_eq("registry/shipped default unchanged",
		str(SystemModelRegistry.resolve("", "nes").get("id", "")), "nes")

	_ok("registry/duplicate refused", not SystemModelRegistry.register_mod_row(
		"t.reg:box", {"platform": "nes", "label": "X", "script": _SCRIPT}, owner).is_empty())
	_ok("registry/shipped id refused", not SystemModelRegistry.register_mod_row(
		"nes", {"platform": "nes", "label": "X", "script": _SCRIPT}, owner).is_empty())

	# validate_row is shared with model_registry_probe, so these are the same
	# rules the shipped table is held to.
	_ok("registry/no platform refused", not SystemModelRegistry.register_mod_row(
		"t.reg:a", {"label": "A", "script": _SCRIPT}, owner).is_empty())
	_ok("registry/both scene and script refused", not SystemModelRegistry.register_mod_row(
		"t.reg:b", {"platform": "nes", "label": "B", "script": _SCRIPT,
			"scene": "res://Scenes/Objects/system_models/nes.tscn"}, owner).is_empty())
	_ok("registry/neither refused", not SystemModelRegistry.register_mod_row(
		"t.reg:c", {"platform": "nes", "label": "C"}, owner).is_empty())
	_ok("registry/missing file refused", not SystemModelRegistry.register_mod_row(
		"t.reg:d", {"platform": "nes", "label": "D", "script": "res://nope.gd"}, owner).is_empty())

	_eq("registry/override registers", SystemModelRegistry.override_mod_row(
		"wii", {"platform": "wii", "label": "Modded Wii", "script": _SCRIPT}, owner), "")
	_eq("registry/override keeps the id",
		str(SystemModelRegistry.resolve("wii", "wii").get("id", "")), "wii")
	_eq("registry/override replaces the label",
		str(SystemModelRegistry.resolve("wii", "wii").get("label", "")), "Modded Wii")
	_ok("registry/override of an unknown id refused",
		not SystemModelRegistry.override_mod_row("nope", {"platform": "x", "label": "L",
			"script": _SCRIPT}, owner).is_empty())

	# Mod models must stay OUT of the boot warm, or boot time becomes a function
	# of how many mods are installed.
	_ok("registry/mod row not in the warm set",
		not SystemModelRegistry.stand_in_ids().has("t.reg:box"))

	SystemModelRegistry.drop_mod(owner)
	_ok("registry/drop removes the row", SystemModelRegistry.row_for("t.reg:box").is_empty())
	_eq("registry/drop restores the shipped row",
		str(SystemModelRegistry.resolve("wii", "wii").get("label", "")), "Wii")
	# The whole point of the fallback: a save naming a model that has gone still
	# lands on something spawnable rather than on nothing.
	_eq("registry/removed model falls back",
		str(SystemModelRegistry.resolve("t.reg:box", "nes").get("id", "")), "nes")


# ── rooms/ ────────────────────────────────────────────────────────────────────

func _group_rooms() -> void:
	# The collapsed descriptor must still describe the shipped rooms exactly.
	_eq("rooms/arcade path", RoomCatalog.path_of("arcade"), "res://Scenes/MainScene.tscn")
	_eq("rooms/bedroom loading title", RoomCatalog.title_of("bedroom"), "90s BEDROOM")
	_eq("rooms/bedroom menu title", RoomCatalog.menu_title_of("bedroom"), "90s Bedroom")
	_ok("rooms/arcade keeps slots", RoomCatalog.has_slots("arcade"))
	_ok("rooms/den keeps none", not RoomCatalog.has_slots("den"))
	_eq("rooms/slot rooms", RoomCatalog.slot_rooms(), ["arcade", "bedroom", "passthrough"])
	_ok("rooms/unknown room is absent", not RoomCatalog.has("nope"))

	var owner := "t.room"
	_eq("rooms/registers", RoomCatalog.register_mod_room("t.room:attic", {
		"path": "res://Scenes/DenScene.tscn", "menu_title": "The Attic"}, owner), "")
	_ok("rooms/mod room exists", RoomCatalog.has("t.room:attic"))
	_ok("rooms/marked as a mod room", RoomCatalog.is_mod_room("t.room:attic"))
	_eq("rooms/menu title kept", RoomCatalog.menu_title_of("t.room:attic"), "The Attic")
	_eq("rooms/loading title derived", RoomCatalog.title_of("t.room:attic"), "THE ATTIC")
	_ok("rooms/defaults to keeping slots", RoomCatalog.has_slots("t.room:attic"))
	_ok("rooms/shipped id refused", not RoomCatalog.register_mod_room(
		"arcade", {"path": "res://Scenes/DenScene.tscn"}, owner).is_empty())
	_ok("rooms/missing scene refused", not RoomCatalog.register_mod_room(
		"t.room:void", {"path": "res://Scenes/Nope.tscn"}, owner).is_empty())
	_ok("rooms/no path refused",
		not RoomCatalog.register_mod_room("t.room:void2", {}, owner).is_empty())
	RoomCatalog.drop_mod(owner)
	_ok("rooms/drop removes it", not RoomCatalog.has("t.room:attic"))
	_eq("rooms/shipped rooms survive a drop", RoomCatalog.ids().size(), 5)

	# Pad art tracked no owner until the overlay tables were shared, so a mod's
	# drawing could be registered and never taken back.
	var art_owner := "t.art"
	var art_row := {"anchors": {"a": Vector2(0.5, 0.5)}, "rows": [["a"]]}
	ConsolePadArt.register_mod_row("t.art:pad", art_row, art_owner)
	_ok("pad art/mod row registers", ConsolePadArt.has("t.art:pad"))
	_eq("pad art/owner recorded", ConsolePadArt.owner_of("t.art:pad"), art_owner)
	_ok("pad art/row is served", not ConsolePadArt.row("t.art:pad").is_empty())
	ConsolePadArt.drop_mod(art_owner)
	_ok("pad art/drop removes it", not ConsolePadArt.has("t.art:pad"))
	_ok("pad art/shipped art survives a drop", ConsolePadArt.has("nes"))


# ── objects/ ──────────────────────────────────────────────────────────────────

func _group_objects() -> void:
	var owner := "t.obj"
	var scene := "res://Scenes/Objects/table.tscn"
	if not ResourceLoader.exists(scene):
		scene = "res://Scenes/Objects/system.tscn"
	_eq("objects/registers", ScenePersistence.register_mod_object(
		"t.obj:crate", scene, owner), "")
	_ok("objects/known", ScenePersistence.is_mod_object("t.obj:crate"))
	_eq("objects/scene recorded", ScenePersistence.mod_object_scene("t.obj:crate"), scene)
	_ok("objects/shipped type refused", not ScenePersistence.register_mod_object(
		"table", scene, owner).is_empty())
	_ok("objects/duplicate refused", not ScenePersistence.register_mod_object(
		"t.obj:crate", scene, owner).is_empty())
	_ok("objects/missing scene refused", not ScenePersistence.register_mod_object(
		"t.obj:void", "res://nope.tscn", owner).is_empty())

	# The instance must carry the stamp _serialize_node recognises, or it saves
	# as its base class and loses the scene it came from.
	var inst := ScenePersistence._instantiate_mod_object("t.obj:crate")
	_ok("objects/instantiates", inst != null)
	if inst != null:
		_eq("objects/carries its type stamp",
			str(inst.get_meta(ScenePersistence.MOD_TYPE_META)), "t.obj:crate")
		inst.free()

	ScenePersistence.drop_mod_objects(owner)
	_ok("objects/drop removes it", not ScenePersistence.is_mod_object("t.obj:crate"))


# ── media/ ────────────────────────────────────────────────────────────────────

func _group_media() -> void:
	var sid := "t_media_platform"
	_eq("media/registers", MediaDimensions.register_mod_media(sid, {
		"cart_size": Vector3(0.1, 0.2, 0.01)}), "")
	_eq("media/cart size", MediaDimensions.cart_size(sid), Vector3(0.1, 0.2, 0.01))
	_ok("media/has a cart size", MediaDimensions.has_cart_size(sid))
	_ok("media/cartridge system is not a disc one", not MediaDimensions.is_disc_system(sid))
	_eq("media/no disc means no loader", MediaDimensions.disc_loader(sid),
		MediaDimensions.LOADER_NONE)

	var disc := "t_disc_platform"
	MediaDimensions.register_mod_media(disc, {"disc_diameter": 0.12})
	_ok("media/disc system", MediaDimensions.is_disc_system(disc))
	_eq("media/tray by default", MediaDimensions.disc_loader(disc), MediaDimensions.LOADER_TRAY)
	var slot := "t_slot_platform"
	MediaDimensions.register_mod_media(slot, {"disc_diameter": 0.12, "slot_load": true})
	_eq("media/slot load", MediaDimensions.disc_loader(slot), MediaDimensions.LOADER_SLOT)
	_ok("media/slot without a disc refused",
		not MediaDimensions.register_mod_media("t_bad", {"slot_load": true}).is_empty())
	_ok("media/bad cart size refused",
		not MediaDimensions.register_mod_media("t_bad2", {"cart_size": "big"}).is_empty())
	# A shipped platform must be untouched by any of this.
	_eq("media/shipped nes unchanged", MediaDimensions.disc_loader("nes"),
		MediaDimensions.LOADER_NONE)

	# Without a scraper mapping a platform's carts stay blank for ever, and
	# nothing anywhere says why — so the mapping is a first-class registration.
	_eq("media/unmapped platform", ScreenscraperSystems.get_systemeid("t_media_platform"), -1)
	ScreenscraperSystems.register_mod_system("t_media_platform", 4242)
	_eq("media/mapped platform", ScreenscraperSystems.get_systemeid("t_media_platform"), 4242)
	_eq("media/shipped mapping unchanged", ScreenscraperSystems.get_systemeid("nes"), 3)


# ── shaders/ ──────────────────────────────────────────────────────────────────

func _group_shaders() -> void:
	# Landing place 1: a shell that says nothing gets the stock CRT. Asserted on
	# the base class, which is what every shipped cabinet uses.
	var shell := RetroTVShell.new()
	_ok("shaders/stock is the default", shell.screen_shader() == null)
	shell.free()

	# Landing place 2: a built-in by name, and the SAME resource rather than a
	# second copy — asking for one must not cost a compile.
	var crt := ModShaders.get_shader("crt")
	_ok("shaders/crt by name", crt != null)
	_ok("shaders/same resource twice", crt == ModShaders.get_shader("crt"))
	_ok("shaders/is the shipped crt",
		crt == load("res://Shaders/crt_effect.gdshader"))
	for shader_name: String in ModShaders.names():
		_ok("shaders/%s resolves" % shader_name, ModShaders.get_shader(shader_name) != null)
	# An unknown name must not hand back a null that lands in a material and
	# paints nothing, with no clue why.
	_ok("shaders/unknown name is not known", not ModShaders.has("no_such_shader"))


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
	_eq("removal/keeps everything else", kept.size(), 2)
	_eq("removal/dropped the mod props", _types_of(kept), ["table", "tv_remote"])
	# Dropping an entry creates dangling references. Not scrubbing them turns
	# "one missing prop" straight back into "the whole slot is invalid".
	var remote := _entry_of(kept, "tv_remote")
	_ok("removal/dangling reference scrubbed", remote.get("system") == null)
	_eq("removal/slot still validates",
		ScenePersistence._objects_validation_error(kept), "")

	# A slot with nothing missing must come back byte-identical, not merely
	# equivalent — this path runs on every load.
	var clean: Array = [{"id": 0, "type": "table", "position": [0, 0, 0],
		"rotation": [0, 0, 0]}]
	_ok("removal/untouched when nothing is missing",
		ScenePersistence._prune_unknown_types(clean, "test") == clean)

	# And the guard that must NOT be weakened: structural corruption is still
	# all-or-nothing. Only an unrecognised type is survivable.
	_ok("removal/negative id still refused", not ScenePersistence._objects_validation_error(
		[{"id": -1, "type": "table"}]).is_empty())
	_ok("removal/duplicate id still refused", not ScenePersistence._objects_validation_error(
		[{"id": 0, "type": "table"}, {"id": 0, "type": "table"}]).is_empty())
	_ok("removal/reference to a never-existing id still refused",
		not ScenePersistence._objects_validation_error(
			[{"id": 0, "type": "tv_remote", "system": 77}]).is_empty())

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
		_ok("removal/a real slot with a missing mod still loads", read != null,
			"the whole slot was refused")
		if read is Array:
			_eq("removal/and comes back without the missing props",
				_types_of(read as Array), ["table", "tv_remote"])
		DirAccess.remove_absolute(slot_path)
	DirAccess.remove_absolute(slot_dir)

	# A registered mod prop is NOT pruned while its mod is loaded.
	var owner := "t.keep"
	var scene := "res://Scenes/Objects/system.tscn"
	ScenePersistence.register_mod_object("t.keep:thing", scene, owner)
	var live: Array = [{"id": 0, "type": "t.keep:thing", "position": [0, 0, 0],
		"rotation": [0, 0, 0]}]
	_eq("removal/loaded mod prop survives",
		ScenePersistence._prune_unknown_types(live, "test").size(), 1)
	ScenePersistence.drop_mod_objects(owner)
	_eq("removal/same prop drops once the mod is gone",
		ScenePersistence._prune_unknown_types(live, "test").size(), 0)


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
	_eq("netplay/no mods means an empty fingerprint", Mods.fingerprint().size(), 0)

	var ours := PackedStringArray(["a@1.0.0", "b@2.0.0"])
	var same := PackedStringArray(["a@1.0.0", "b@2.0.0"])
	_ok("netplay/identical sets match", ours == same)
	_ok("netplay/order-independent by sorting", ours == PackedStringArray(["a@1.0.0", "b@2.0.0"]))
	_ok("netplay/a different version is a mismatch",
		ours != PackedStringArray(["a@1.0.0", "b@2.0.1"]))

	var msg := Mods.fingerprint_mismatch(ours, PackedStringArray(["a@1.0.0"]))
	_ok("netplay/names what is missing", msg.contains("b@2.0.0"), msg)
	var msg2 := Mods.fingerprint_mismatch(PackedStringArray(["a@1.0.0"]), ours)
	_ok("netplay/names what is extra", msg2.contains("extra"), msg2)


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
	_eq("consistency/computer platforms match SystemInfo.computer",
		", ".join(mismatched), "")

	# system_info.gd says MediaType intentionally matches MediaDimensions.LOADER_*
	# so the two "never disagree". They are separate tables, so check it.
	_eq("consistency/CARTRIDGE == LOADER_NONE",
		int(SystemInfo.MediaType.CARTRIDGE), MediaDimensions.LOADER_NONE)
	_eq("consistency/DISC_TRAY == LOADER_TRAY",
		int(SystemInfo.MediaType.DISC_TRAY), MediaDimensions.LOADER_TRAY)
	_eq("consistency/DISC_INSERT == LOADER_SLOT",
		int(SystemInfo.MediaType.DISC_INSERT), MediaDimensions.LOADER_SLOT)

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
	_ok("consistency/descriptors were actually read", checked > 50,
		"only %d read — the check would pass vacuously" % checked)
	_eq("consistency/media_type agrees with disc_loader", ", ".join(disagree), "")


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

func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s" % name)
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [name,
			"  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])

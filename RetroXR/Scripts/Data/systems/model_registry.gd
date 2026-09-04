## SystemModelRegistry — every hardware model RetroXR can wear, in one flat table.
##
## A model is a first-class thing with an id, not a "variant" of another model. Two
## models for the same platform are two rows that know nothing about each other, so
## either can be added or deleted without touching the other. Deleting a model is
## deleting its row and its files.
##
## "Primitive" here is only a NAME for a kind of model. It is not a mode, a flag, or
## a branch: nothing anywhere asks "am I primitive?" to decide what to load.
##
## `requires` and the availability check below have no row to act on today — every
## model ships with the app. They stay because they are the contract a model with
## external assets plugs into, and because `resolve()` leans on them to keep a save
## naming a model this build does not have from ever landing on nothing.
##
## This replaced four dictionaries in system.gd with precedence rules between them
## (`_MODEL_SCENES`, `_MODEL_SCENE_VARIANTS`, `_MODEL_VARIANTS`, `_MODEL_SCRIPTS`),
## keyed by concatenated "systemid:variant" strings, plus two special-case branches
## on a magic "primitive" variant. Notes from unpicking that:
##
##   * `_MODEL_VARIANTS` was entirely dead — all three of its keys were shadowed by
##     `_MODEL_SCENE_VARIANTS`, which was tested first.
##   * `_MODEL_SCRIPTS` contributed exactly one reachable row ("dos"); its "nes" and
##     "nintendo_64" entries were shadowed by `_MODEL_SCENES`.
##
## Lives in Data/systems beside system_icons.gd and system_asset_catalog.gd, which
## are the same species: a static table, an availability check, a graceful fallback.
## Keeping it out of Objects/ also stops SpawnCatalog (Data) reaching up into
## RetroSystem (Objects) to ask which models exist.
class_name SystemModelRegistry
extends RefCounted


## The procedural box, labelled "Primitive System" in the menu. It is the stand-in
## for hardware with no primitive model of its own. Unlike the authored primitives,
## which are ordinary rows under their platform, this box fits any console and so
## belongs to no platform — which is why it is not in _ROWS.
const PLACEHOLDER_ID := "placeholder"
const PLACEHOLDER_SCRIPT := "res://Scripts/Objects/system_models/default_model.gd"

const _SCENES := "res://Scenes/Objects/system_models/"

## Every platform the PC tower is the hardware for — the systems SystemInfo marks
## `computer = true`. They are listed rather than derived because _ROWS is a const
## table and SystemInfo is a loaded resource; a new computer system therefore has to
## be added HERE as well as given its .tres, or it falls back to the procedural box.
##
## Not all of these were towers — a C64, a Spectrum and an Amiga 500 are wedge
## keyboards with the machine inside — so this is a stand-in for them in the same
## sense the procedural box was, just a far better one: it has the sockets their
## keyboard, mouse, monitor and speakers actually plug into.
const _COMPUTER_PLATFORMS: Array[String] = [
	"apple_ii", "atari_8bit", "atari_st", "commodore_amiga",
	"commodore_c128", "commodore_c64", "commodore_vic20", "cpc", "dos", "msx",
	"pc_88", "pc_98", "scummvm", "sharp_x1", "sharp_x68000", "svi", "zx81",
	"zx_spectrum",
]


## Row fields:
##   platform  systemid this model is hardware for, or an ARRAY of them where one
##             model serves several machines. Does NOT replace RetroSystem.systemid
##             — core lookup, MediaDimensions, SystemInfo, SystemIcons and ROM
##             filtering all key off that. The row sits UNDER the platform.
##   label     spawn-menu row text.
##   scene     XOR script. Neither would mean the placeholder.
##   handheld  played in the hand; the menu labels those differently.
##   requires  assets that must be present for this row to be usable. Empty means
##             always available. Declared now, enforced in a later phase.
##
## Order matters: the FIRST row for a platform is that platform's default, which is
## what an empty model_id resolves to.
const _ROWS: Dictionary = {
	# --- consoles -------------------------------------------------------------
	# `requires` names each detailed model's GLB, so a build without the asset lists
	# the platform's stand-in instead of a row that cannot spawn.
	"atari_2600":           {"platform": "atari_2600", "label": "Atari 2600",
		"script": "res://Scripts/Objects/system_models/atari_2600_model.gd",
		"requires": ["res://imported-assets/consoles/atari_2600/atari_2600_console.glb"]},
	"nes":                  {"platform": "nes", "label": "Nintendo Entertainment System",
		"scene": _SCENES + "nes.tscn",
		"requires": ["res://imported-assets/consoles/nes/nes_console.glb"]},
	"playstation":          {"platform": "playstation", "label": "PlayStation",
		"script": "res://Scripts/Objects/system_models/playstation_model.gd",
		"requires": ["res://imported-assets/consoles/playstation/ps1_console.glb"]},
	# A scene row with the model script on its root: primitive geometry, no GLB, so
	# there is no `requires` to declare. It also still carries the core options the
	# Wii cannot run correctly without.
	"wii":                  {"platform": "wii", "label": "Wii",
		"scene": _SCENES + "wii_primitive.tscn"},
	"nintendo_64":          {"platform": "nintendo_64", "label": "Nintendo 64",
		"scene": _SCENES + "nintendo_64_primitive.tscn"},
	# --- computers ------------------------------------------------------------
	# One row across every computer platform rather than eighteen near-identical
	# ones. The tower is a single model that happens to fit them all; copies would
	# only be eighteen places for it to rot.
	"pc_tower":             {"platform": _COMPUTER_PLATFORMS, "label": "PC Tower",
		"scene": _SCENES + "pc_tower.tscn"},

	# --- handhelds ------------------------------------------------------------
	# The "(primitive)" suffix is now redundant — these are the only models their
	# platforms have — but the ids are what saves and peers name, so they stay.
	"game_boy_primitive":   {"platform": "game_boy", "label": "Game Boy", "handheld": true,
		"scene": _SCENES + "game_boy_primitive.tscn"},
	"game_boy_advance_primitive": {"platform": "game_boy_advance", "label": "Game Boy Advance", "handheld": true,
		"scene": _SCENES + "game_boy_advance_primitive.tscn"},
	"game_boy_advance_sp_primitive": {"platform": "game_boy_advance", "label": "Game Boy Advance SP", "handheld": true,
		"scene": _SCENES + "game_boy_advance_sp_primitive.tscn"},
	"nds_primitive":        {"platform": "nds", "label": "DS", "handheld": true,
		"scene": _SCENES + "nds_primitive.tscn"},
	"n3ds_primitive":       {"platform": "3ds", "label": "3DS", "handheld": true,
		"scene": _SCENES + "n3ds_primitive.tscn"},
	"psp_primitive":        {"platform": "playstation_portable", "label": "PSP", "handheld": true,
		"scene": _SCENES + "psp_primitive.tscn"},
	"virtual_boy_primitive": {"platform": "virtual_boy", "label": "Virtual Boy",
		"scene": _SCENES + "virtual_boy_primitive.tscn"},
	"atari_lynx":           {"platform": "atari_lynx", "label": "Atari Lynx", "handheld": true,
		"scene": _SCENES + "atari_lynx.tscn"},
	"wonderswan":           {"platform": "wonderswan", "label": "WonderSwan", "handheld": true,
		"scene": _SCENES + "wonderswan.tscn"},
	"neo_geo_pocket":       {"platform": "neo_geo_pocket", "label": "Neo Geo Pocket", "handheld": true,
		"scene": _SCENES + "neo_geo_pocket.tscn"},
	"pokemon_mini":         {"platform": "pokemon_mini", "label": "Pokemon Mini", "handheld": true,
		"scene": _SCENES + "pokemon_mini.tscn"},
	"supervision":          {"platform": "supervision", "label": "Supervision", "handheld": true,
		"scene": _SCENES + "supervision.tscn"},
}



## Set by tests to prove a stripped build still resolves every platform to
## something spawnable. Never set at runtime.
static var simulate_missing_assets: bool = false


## Rows contributed by mods, and shipped rows a mod has replaced.
##
## The shipped table above stays a const: a mod cannot edit it, only layer over
## it. Mod rows are merged AFTER the shipped ones so insertion order -- and with
## it the rule that a platform's FIRST row is its default -- keeps a shipped
## model as the default even when a mod adds another for the same platform.
## Overriding that default is a deliberate act (override_mod_row), not a
## side effect of load order.
static var _mod_rows: Dictionary = {}
static var _overrides: Dictionary = {}
## model_id -> the mod that contributed it, for the Mods page and for blame.
static var _owners: Dictionary = {}

## The merged view, rebuilt only when a registration changes it.
static var _merged: Dictionary = {}
static var _merged_dirty: bool = true


## Every row this build can resolve: shipped, with mod overrides applied, plus
## mod rows. Cached because the lookups below call it inside loops.
static func _table() -> Dictionary:
	if _merged_dirty:
		_merged = _ROWS.duplicate(true)
		for model_id: String in _overrides:
			_merged[model_id] = _overrides[model_id]
		for model_id: String in _mod_rows:
			_merged[model_id] = _mod_rows[model_id]
		_merged_dirty = false
	return _merged


## Is `row` a usable row? Returns "" when it is, or what is wrong with it.
##
## Extracted from Tools/models/model_registry_probe.gd so the probe and the mod
## loader cannot disagree about what a well-formed row is. The probe checks the
## shipped table at build time; this rejects a bad mod row at REGISTRATION, which
## is the only moment the mod can still be named in the complaint. Getting it
## wrong later means a spawn failing somewhere with no clue who caused it.
static func validate_row(model_id: String, row: Dictionary) -> String:
	if model_id.is_empty():
		return "no id"
	if str(row.get("platform", "")).is_empty() and not (row.get("platform") is Array):
		return "no platform"
	var has_scene: bool = not str(row.get("scene", "")).is_empty()
	var has_script: bool = not str(row.get("script", "")).is_empty()
	if has_scene == has_script:
		return "must have exactly one of scene/script"
	for k: String in ["scene", "script"]:
		var path: String = str(row.get(k, ""))
		# ResourceLoader, not FileAccess: a res:// path inside a mounted pack is
		# remapped, and FileAccess.file_exists reports false for every one.
		if not path.is_empty() and not ResourceLoader.exists(path):
			return "%s does not exist: %s" % [k, path]
	var req: Variant = row.get("requires", [])
	if not (req is Array):
		return "requires must be an array"
	return ""


## Add a mod's row. Returns "" on success.
static func register_mod_row(model_id: String, row: Dictionary, owner_id: String) -> String:
	if _ROWS.has(model_id):
		return "'%s' is a shipped model; use override_model to replace it" % model_id
	if _mod_rows.has(model_id):
		return "'%s' is already registered by mod '%s'" % [model_id, _owners.get(model_id, "?")]
	var checked := row.duplicate(true)
	checked["id"] = model_id
	var err := validate_row(model_id, checked)
	if not err.is_empty():
		return err
	_mod_rows[model_id] = checked
	_owners[model_id] = owner_id
	_merged_dirty = true
	return ""


## Replace a SHIPPED row in place, keeping its id so existing saves still resolve
## to it. Returns "" on success.
static func override_mod_row(model_id: String, row: Dictionary, owner_id: String) -> String:
	if not _ROWS.has(model_id):
		return "'%s' is not a shipped model" % model_id
	if _overrides.has(model_id):
		return "'%s' is already overridden by mod '%s'" % [model_id, _owners.get(model_id, "?")]
	var checked := row.duplicate(true)
	checked["id"] = model_id
	var err := validate_row(model_id, checked)
	if not err.is_empty():
		return err
	_overrides[model_id] = checked
	_owners[model_id] = owner_id
	_merged_dirty = true
	return ""


## Which mod contributed a model, or "" for a shipped one.
static func owner_of(model_id: String) -> String:
	return str(_owners.get(model_id, ""))


## True for a row a mod brought. Used to keep mod models out of the boot warm.
static func is_mod_row(model_id: String) -> bool:
	return _mod_rows.has(model_id) or _overrides.has(model_id)


## Drop everything a mod registered. Only used when a mod fails part-way through
## register(), so a half-registered mod leaves nothing standing.
static func drop_mod(owner_id: String) -> void:
	for model_id: String in _owners.keys():
		if _owners[model_id] != owner_id:
			continue
		_mod_rows.erase(model_id)
		_overrides.erase(model_id)
		_owners.erase(model_id)
	_merged_dirty = true


## The row for `model_id`, or the best available stand-in. Never returns empty.
##
## Four rules, none of them special cases:
##   1. known and available            -> that row
##   2. known but unavailable          -> platform's best available row
##   3. unknown (a deleted model named by an old save or a peer)  -> same
##   4. empty                          -> platform's first available row
## Rules 2 and 3 are what make deleting a model safe across old saves and peers on
## a different build.
static func resolve(model_id: String, platform: String) -> Dictionary:
	# An explicit placeholder request is an ANSWER, not a miss. Falling through to
	# the platform's first row here meant asking for the procedural box handed back
	# a platform model instead — which is what the test hallway and the menu's
	# "Primitive System" row were both doing.
	if model_id == PLACEHOLDER_ID:
		return placeholder_row()
	if not model_id.is_empty():
		if _table().has(model_id):
			if is_available(model_id):
				return _row(model_id)
			push_warning("[models] '%s' is not available in this build; falling back" % model_id)
		else:
			push_warning("[models] unknown model '%s' (deleted?); falling back" % model_id)
	var avail := rows_for(platform)
	if not avail.is_empty():
		return avail[0]
	return placeholder_row()


## Every model scene we have loaded, kept referenced.
##
## Godot's resource cache holds a WEAK reference, so freeing the last instance of
## a model drops its PackedScene and the next spawn re-reads and re-parses the
## whole thing. Measured on desktop 2026-08-01: loading the baked NES cost 442 ms
## cold and 395 ms again after its instance was freed, against 0.0 ms with a
## reference held. Quest storage is far slower than that, and this is paid on
## EVERY spawn.
##
## The cost of holding them is the scenes themselves — meshes and textures for
## models the player has already spawned once. If that becomes a problem on
## device, bound this rather than removing it.
static var _packed_scenes: Dictionary = {}


static func packed_scene(scene_path: String) -> PackedScene:
	var cached: PackedScene = _packed_scenes.get(scene_path)
	if cached != null:
		return cached
	var packed := load(scene_path) as PackedScene
	if packed != null:
		_packed_scenes[scene_path] = packed
	return packed


static func instantiate(row: Dictionary) -> RetroSystemModel:
	var scene_path: String = row.get("scene", "")
	if not scene_path.is_empty():
		var packed := packed_scene(scene_path)
		if packed == null:
			push_warning("[models] failed to load scene: " + scene_path)
			return null
		return packed.instantiate() as RetroSystemModel
	var script_path: String = row.get("script", PLACEHOLDER_SCRIPT)
	var script := load(script_path) as GDScript
	if script == null:
		push_warning("[models] failed to load script: " + script_path)
		return null
	return script.new() as RetroSystemModel


static func placeholder_row() -> Dictionary:
	return {"id": PLACEHOLDER_ID, "platform": "", "label": "Primitive System",
		"script": PLACEHOLDER_SCRIPT, "requires": []}


## Does this row provide hardware for `platform`? The field is a systemid or an
## array of them, and every lookup below goes through here so the two spellings can
## never diverge.
static func _serves(row: Dictionary, platform: String) -> bool:
	var field: Variant = row.get("platform", "")
	if field is Array:
		return (field as Array).has(platform)
	return str(field) == platform


## Every available row for a platform, in author order. The first is its default.
static func rows_for(platform: String) -> Array:
	var out: Array = []
	for id: String in _table():
		if _serves(_table()[id], platform) and is_available(id):
			out.append(_row(id))
	return out


static func is_available(model_id: String) -> bool:
	if not _table().has(model_id):
		return false
	var req: Array = _table()[model_id].get("requires", [])
	if req.is_empty():
		return true
	if simulate_missing_assets:
		return false
	for path: String in req:
		if not ResourceLoader.exists(path):
			return false
	return true


## The single platform a model belongs to, or "" when it does not belong to exactly
## one.
##
## The spawn menu uses this to let the ROW override the systemid carried in a token,
## so a model and the core it loads cannot disagree. A model serving several
## machines has no single answer, and "" hands that decision back to the token —
## which is the only thing that knows WHICH computer was asked for. Same path the
## placeholder already took, and for the same reason.
static func platform_of(model_id: String) -> String:
	if not _table().has(model_id):
		return ""
	var field: Variant = _table()[model_id].get("platform", "")
	return "" if field is Array else str(field)


static func platform_is_handheld(platform: String) -> bool:
	for id: String in _table():
		var r: Dictionary = _table()[id]
		if _serves(r, platform) and bool(r.get("handheld", false)):
			return true
	return false


static func has_any_model(platform: String) -> bool:
	for id: String in _table():
		if _serves(_table()[id], platform):
			return true
	return false


## True when this platform offers a plain model ALONGSIDE an asset-backed one, i.e.
## there is something to fall back to if the asset-backed one is unavailable.
##
## A platform whose only model happens to be plain (atari_lynx, wonderswan, …)
## returns false: nothing is being offered as an alternative to anything.
##
## No row carries external assets today, so this is false everywhere. Kept for the
## same reason `requires` is — it is how such a model would announce that the plain
## one is still there behind it.
static func has_plain_alternative(platform: String) -> bool:
	var total := 0
	var plain := 0
	for id: String in _table():
		if not _serves(_table()[id], platform):
			continue
		total += 1
		if (_table()[id].get("requires", []) as Array).is_empty():
			plain += 1
	return total > 1 and plain > 0


## A row by id, with "id" filled in. Empty for an unknown id.
static func row_for(model_id: String) -> Dictionary:
	return _row(model_id) if _table().has(model_id) else {}


## NOTE the three functions below read _ROWS directly rather than _table(): they
## are the BOOT WARM set, and mod models are deliberately excluded from it.
## Warming the shipped thirteen stand-ins costs ~1.1 s on a Quest 3, plus ~266 ms
## of first-draw pipeline compile per bespoke shell; letting an arbitrary number
## of mod consoles join that would make boot time a function of how many mods the
## player has installed. A mod model is warmed lazily instead, on first spawn --
## which is safe because the spawn path already awaits ModelWarmer.acquire() for
## every path in a row's `requires` (spawn_menu_controller.gd), and so does a
## save restore (scene_persistence.gd). The cost moves to the first spawn of that
## console rather than to every boot.

## The models that carry no external assets — the stand-ins. Every row, now.
##
## Worth naming because they were the cheap half by a wide margin, which is why
## they are the half ModelWarmer warms. Measured on a Quest 3: warming all thirteen
## costs ~1.1 s and almost no texture memory. Warming is the whole registry, and
## it is cheap because untextured primitives are cheap.
static func stand_in_ids() -> Array:
	var out: Array = []
	for id: String in _ROWS:
		if (_ROWS[id].get("requires", []) as Array).is_empty():
			out.append(id)
	return out


## The rows whose models carry external assets — the bespoke shells, the other
## half of stand_in_ids(). Only rows whose assets are present: ModelWarmer draws
## each of these once at boot, after their GLBs arrive, because first draw has
## its own cost (266 ms of pipeline compile for the Atari on a Quest 3).
static func bespoke_ids() -> Array:
	var out: Array = []
	for id: String in _ROWS:
		if not (_ROWS[id].get("requires", []) as Array).is_empty() and is_available(id):
			out.append(id)
	return out


## The external assets the bespoke shells load — the GLB each one names in
## `requires`, deduplicated, and only for rows whose assets are actually present.
##
## These are the other half of stand_in_ids(), and the expensive half: a shell's
## model loads its GLB synchronously in _ready(), which measured 6.9 s on a Quest 3
## for the NES with the main thread blocked and not one frame drawn. ModelWarmer
## pulls them in ahead of time so a spawn finds them in the resource cache.
static func shell_assets() -> Array:
	var out: Array = []
	for id: String in _ROWS:
		if not is_available(id):
			continue
		for path: String in _ROWS[id].get("requires", []):
			if not out.has(path):
				out.append(path)
	return out


static func all_ids() -> Array:
	return _table().keys()


static func _row(model_id: String) -> Dictionary:
	var r: Dictionary = (_table()[model_id] as Dictionary).duplicate()
	r["id"] = model_id
	return r

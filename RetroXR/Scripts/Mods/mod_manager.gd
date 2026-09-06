## Mods — the autoload that finds, vets and mounts mod packs.
##
## Runs before AppPrefs and SceneManager, because every registration a mod makes
## has to be in place before a room is built or a menu is populated.
##
## The shape of a boot:
##
##   1. list <mods root>/*.zip and *.pck
##   2. open each WITHOUT mounting it and read its file list
##   3. read mod.json (and thumbnail.png) out of it
##   4. check the inventory against the manifest's namespace and claims
##   5. skip anything not explicitly enabled in user://mods.json
##   6. mount what is left, in priority order, and run its entry script
##
## Steps 1-5 touch nothing and are reversible, which is what makes it safe to
## inspect every mod on disk at every boot while mounting only the enabled ones.
## Step 6 is not: ProjectSettings.load_resource_pack cannot be undone, so
## enabling or disabling a mod takes effect on the NEXT launch and the Mods page
## says so rather than pretending otherwise.
##
## One bad mod never blocks a boot. Every failure is recorded against that mod
## and the run continues, because a mod that silently vanishes is the worst
## failure this system has -- the page exists mostly to explain these.
extends Node

const STATE_PATH := "user://mods.json"
const STATE_OWNER := "ModManager"

## What happened to one mod this boot. Defined on ModRecord, which carries it;
## aliased here because the Mods page reads it as Mods.Status.
const Status := ModRecord.Status

## Emitted once discovery and loading have finished, so the Mods page can build.
signal mods_ready()

## id -> ModRecord.
var _mods: Dictionary = {}
## Containers whose id could not be read at all, keyed by file path.
var _unreadable: Array[Dictionary] = []
## ids seen more than once across containers.
var _duplicates: Dictionary = {}

var _enabled: Dictionary = {}
var _hooks: ModHooks = null
var _ready_done := false


func _ready() -> void:
	_hooks = ModHooks.new(get_tree())
	_load_state()
	_discover()
	_load_enabled()
	_ready_done = true
	mods_ready.emit()


# ── discovery ─────────────────────────────────────────────────────────────────

func _discover() -> void:
	RomLibrary.ensure_mods_root()
	var found: Dictionary = {}          # id -> Array of file paths
	for entry: Dictionary in RomLibrary.scan_mods():
		var path := str(entry["path"])
		var reader := ModPackReader.open(path)
		if not reader.error.is_empty():
			_unreadable.append({"path": path, "reason": reader.error})
			continue
		var files := reader.files()
		var manifest := _manifest_from(reader, files)
		if manifest == null:
			_unreadable.append({"path": path, "reason": "no mod.json under res://mods/<id>/"})
			reader.close()
			continue
		if not manifest.error.is_empty():
			_unreadable.append({"path": path, "reason": manifest.error})
			reader.close()
			continue
		if not found.has(manifest.id):
			found[manifest.id] = []
		(found[manifest.id] as Array).append(path)
		var rec := _record_for(manifest, path, files)
		# The thumbnail is read here, with the container open and nothing
		# mounted. That is the whole point: the page shows art for a mod that is
		# disabled and has never been loaded, which is exactly when the player is
		# deciding whether to trust it.
		rec.thumbnail = _read_thumbnail(reader, manifest)
		_mods[manifest.id] = rec
		reader.close()

	# Two copies of one mod is refused outright rather than resolved by a rule
	# the player cannot see. An ambiguous install should be visible.
	for id: String in found:
		if (found[id] as Array).size() > 1:
			_duplicates[id] = found[id]
			(_mods[id] as ModRecord).refuse("installed twice: %s" % ", ".join(
				(found[id] as Array).map(func(p): return str(p).get_file())))


## Find and parse the manifest, which is at res://mods/<id>/mod.json for exactly
## one <id>. The id is taken from the FILE LIST rather than trusted from the
## manifest, so a mod cannot file itself under a namespace it does not occupy.
func _manifest_from(reader: ModPackReader, files: PackedStringArray) -> ModManifest:
	var prefix := ModManifest.NAMESPACE_ROOT
	for path: String in files:
		if not path.begins_with(prefix) or not path.ends_with("/mod.json"):
			continue
		var rest := path.substr(prefix.length())
		var slash := rest.find("/")
		if slash < 0:
			continue
		var dir_id := rest.substr(0, slash)
		if rest != dir_id + "/mod.json":
			continue                      # nested, not the manifest
		var m := ModManifest.parse(reader.read_json(path))
		if m.error.is_empty() and m.id != dir_id:
			m.error = "manifest says id '%s' but it lives under mods/%s/" % [m.id, dir_id]
		return m
	return null


func _read_thumbnail(reader: ModPackReader, manifest: ModManifest) -> Texture2D:
	var path := manifest.own_root() + "thumbnail.png"
	if not reader.has(path):
		return null
	var data := reader.read(path)
	if data.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(data) != OK:
		return null
	return ImageTexture.create_from_image(img)


func _record_for(manifest: ModManifest, path: String,
		files: PackedStringArray) -> ModRecord:
	var rec := ModRecord.new()
	rec.id = manifest.id
	rec.manifest = manifest
	rec.path = path
	rec.size = ByteSize.on_disk(path)
	rec.files = files.size()
	var inventory_err := manifest.inventory_error(files)
	if not inventory_err.is_empty():
		rec.refuse(inventory_err)
	elif not manifest.runs_here():
		rec.refuse("not built for %s" % OS.get_name())
	return rec


# ── loading ───────────────────────────────────────────────────────────────────

func _load_enabled() -> void:
	var order := _mods.values().filter(func(r): return _should_load(r))
	# Priority, then id, so a boot is deterministic and a mod that must layer
	# over another can say so without depending on filenames.
	order.sort_custom(func(a, b):
		var pa: int = (a as ModRecord).manifest.priority
		var pb: int = (b as ModRecord).manifest.priority
		if pa != pb:
			return pa < pb
		return (a as ModRecord).id < (b as ModRecord).id)
	for rec: ModRecord in order:
		_mount_and_register(rec)


func _should_load(rec: ModRecord) -> bool:
	if rec.status == ModRecord.Status.REFUSED:
		return false
	return bool(_enabled.get(rec.id, false))


func _mount_and_register(rec: ModRecord) -> void:
	var manifest := rec.manifest
	var shadowing := manifest.shadowing_claims()
	# replace_files only when a claim actually lands on a shipped path. A mod
	# claiming nothing therefore provably cannot touch one.
	var replace := not shadowing.is_empty()
	if not ProjectSettings.load_resource_pack(rec.path, replace):
		rec.fail("the pack could not be mounted")
		return
	if not ResourceLoader.exists(manifest.entry):
		rec.fail("entry script is missing: %s" % manifest.entry)
		return
	var script := ResourceLoader.load(manifest.entry) as GDScript
	if script == null:
		rec.fail("entry script did not compile: %s" % manifest.entry)
		return
	var inst: Object = script.new()
	if not (inst is RetroMod):
		rec.fail("entry script does not extend RetroMod")
		return
	var api := ModApi.new(manifest, _hooks)
	(inst as RetroMod).register(api)
	# A mod whose contributions were REFUSED is not a loaded mod. Every registry
	# has carried a drop_mod for this since the overlay tables were shared, each
	# documented as the rollback for a registration that failed part-way — and
	# nothing outside the tests had ever called one, so a mod that failed half
	# way through kept the half that worked and was listed as fully loaded.
	#
	# Warnings do not qualify: a platform registered without pad art is
	# incomplete and still plays, which is why _warn and _fail are counted apart.
	if api.failed():
		api.withdraw()
		rec.fail("registration was refused: %s" % api.errors_text())
		return
	rec.api = api
	rec.status = ModRecord.Status.LOADED
	if not shadowing.is_empty():
		rec.reason = "replaces %d shipped file(s)" % shadowing.size()
	print("[mods] loaded %s %s — %s" % [manifest.id, manifest.version, api.summary()])


# ── enable state ──────────────────────────────────────────────────────────────
#
# Kept in its own file rather than in AppPrefs so this autoload does not depend
# on another one having run first.

func _load_state() -> void:
	var d := JsonStore.read_dict(STATE_PATH, STATE_OWNER)
	var raw: Variant = d.get("enabled", {})
	if raw is Dictionary:
		for id: Variant in (raw as Dictionary):
			_enabled[str(id)] = bool((raw as Dictionary)[id])


func _save_state() -> void:
	JsonStore.write_dict(STATE_PATH, {"enabled": _enabled}, STATE_OWNER)


## Nothing is enabled by default. A mod that arrives on disk — pushed over adb,
## dropped in by hand, or uploaded through the LAN file server — is inert until
## the player says otherwise, which is the whole of the consent model.
func is_enabled(id: String) -> bool:
	return bool(_enabled.get(id, false))


## Enable or disable a mod. Takes effect on the next launch, because a mounted
## pack cannot be unmounted.
func set_enabled(id: String, enabled: bool) -> void:
	if not _mods.has(id):
		return
	_enabled[id] = enabled
	_save_state()
	var rec: ModRecord = _mods[id]
	if rec.status == ModRecord.Status.REFUSED:
		return
	if enabled and rec.status != ModRecord.Status.LOADED:
		rec.status = ModRecord.Status.PENDING
	elif not enabled and rec.status == ModRecord.Status.LOADED:
		rec.status = ModRecord.Status.PENDING


## True when a change has been made that only a restart can apply.
func restart_pending() -> bool:
	for rec: ModRecord in _mods.values():
		if rec.status == ModRecord.Status.PENDING:
			return true
	return false


# ── what the UI and netplay ask ───────────────────────────────────────────────

## Every discovered mod, ordered for display: loaded first, then pending, then
## disabled, then everything that failed — with the problems last because they
## are what the page is mostly there to explain.
func all_mods() -> Array:
	var out := _mods.values().duplicate()
	out.sort_custom(func(a, b):
		var rank := {Status.LOADED: 0, Status.PENDING: 1, Status.DISABLED: 2,
			Status.FAILED: 3, Status.REFUSED: 4}
		var ra: int = rank.get((a as ModRecord).status, 5)
		var rb: int = rank.get((b as ModRecord).status, 5)
		if ra != rb:
			return ra < rb
		return (a as ModRecord).id < (b as ModRecord).id)
	return out


func mod(id: String) -> ModRecord:
	return _mods.get(id) as ModRecord


## Containers that could not be identified at all — a corrupt pack, or one whose
## manifest is missing. Listed on the page so a file the player put there does
## not simply fail to appear.
func unreadable() -> Array[Dictionary]:
	return _unreadable


static func status_text(status: ModRecord.Status) -> String:
	match status:
		Status.DISABLED: return "Disabled"
		Status.PENDING:  return "Restart to apply"
		Status.LOADED:   return "Loaded"
		Status.REFUSED:  return "Refused"
		Status.FAILED:   return "Failed"
	return "?"


## The enabled-and-loaded mods as "id@version", sorted — what peers compare.
##
## Sent in the netplay handshake, never the packs themselves. A mod is a file the
## player chose to install; the app is not a distribution channel for one, and a
## peer missing a mod is told so rather than sent it.
func fingerprint() -> PackedStringArray:
	var out := PackedStringArray()
	for rec: ModRecord in _mods.values():
		if rec.status != ModRecord.Status.LOADED:
			continue
		out.append("%s@%s" % [rec.manifest.id, rec.manifest.version])
	out.sort()
	return out


## Describe the difference between two fingerprints, for a rejection message.
static func fingerprint_mismatch(ours: PackedStringArray, theirs: PackedStringArray) -> String:
	var mine := {}
	for s: String in ours:
		mine[s] = true
	var yours := {}
	for s: String in theirs:
		yours[s] = true
	var missing := PackedStringArray()
	var extra := PackedStringArray()
	for s: String in ours:
		if not yours.has(s):
			missing.append(s)
	for s: String in theirs:
		if not mine.has(s):
			extra.append(s)
	var parts := PackedStringArray()
	if not missing.is_empty():
		parts.append("you are missing " + ", ".join(missing))
	if not extra.is_empty():
		parts.append("you have extra " + ", ".join(extra))
	return "; ".join(parts)

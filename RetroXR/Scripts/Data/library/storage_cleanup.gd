## StorageCleanup — finds what nothing on disk claims any more, and removes it.
##
## Two callers, one set of rules:
##   * deleting a game runs the per-ROM half (metadata_for_rom) immediately, so
##     an ordinary delete leaves nothing behind;
##   * the Clean up sweep runs the whole scan, for everything earlier versions
##     orphaned and everything a hand-deleted file left standing.
##
## Scanning and removing are separate calls on purpose. Every category is
## reported with a count and a byte total first, and nothing is unlinked until a
## caller passes those findings back to `remove()` — a sweep that deletes as it
## walks cannot be shown to anyone before it has already happened.
##
## SAVES ARE NEVER SWEPT AUTOMATICALLY. They are found and reported like
## anything else, but they are their own category and are only ever removed when
## a caller asks for that category by name: a ROM can be downloaded again and a
## save cannot. Memory cards are not scanned at all — a card is shared by every
## game on that console, so no absent ROM makes one orphaned.
class_name StorageCleanup
extends RefCounted


## Category ids.
const GAMELIST := "gamelist"
const MEDIA := "media"
const COVERS := "covers"
const CORE_OPTIONS := "core_options"
const CORE_SYSTEM := "core_system"
const PARTIALS := "partials"
const SAVES := "saves"

## Ticked when the panel opens. Everything else is found and shown but must be
## asked for by name.
##
## The two left out are the two that cannot be got back by pressing a button:
## SAVES is progress, and CORE_SYSTEM holds BIOS dumps, which are harder to
## re-acquire than the core that wanted them — no server here hands them out.
## Removing a core is a routine thing to do and should not quietly arm the
## deletion of the firmware it took effort to find.
const DEFAULT_SELECTED := [GAMELIST, MEDIA, COVERS, CORE_OPTIONS, PARTIALS]

const LABELS := {
	GAMELIST: "Library entries for missing games",
	MEDIA: "Artwork and manuals with no game",
	# Its own category because it is not an orphan, it is a cache: a cover is
	# fetched for every row you scroll past, so this is mostly art for games
	# never downloaded and every byte of it comes back the next time that
	# platform is browsed. Folded in with the rest it dominated the total and
	# made a sweep look like it reclaimed far more than it did.
	COVERS: "Cover art cache (re-downloads when you browse)",
	CORE_OPTIONS: "Settings for cores you removed",
	CORE_SYSTEM: "BIOS folders for cores you removed",
	PARTIALS: "Interrupted downloads",
	SAVES: "Saves for games you no longer have",
}


# ── Per-ROM (the delete path) ─────────────────────────────────────────────────

## Every metadata file one ROM owns. Does NOT include its saves.
##
## Called with the ROM still on disk, immediately before it is removed, because
## the media lookup keys on the ROM's own basename.
static func metadata_for_rom(systemid: String, rom_relative: String,
							 rom_id: int = 0) -> PackedStringArray:
	return RomMedia.all_for_rom(systemid, rom_relative, rom_id)


## Drop one ROM's gamelist row and unlink its artwork. Returns bytes freed.
##
## The gamelist is saved here rather than left to the caller: this runs from a
## delete that has already removed the ROM, and a row kept for a file that is
## gone is the exact stale state the whole feature exists to prevent.
static func purge_rom_metadata(systemid: String, rom_relative: String,
							   rom_id: int = 0) -> int:
	var freed := 0
	for path: String in metadata_for_rom(systemid, rom_relative, rom_id):
		freed += _unlink(path)

	var gl := GamelistManager.new()
	if gl.remove_rom(systemid, rom_relative):
		gl.save_gamelist(systemid)
	return freed


# ── Full sweep ───────────────────────────────────────────────────────────────

## Walk every system's ROM folder and the libretro root.
##
## Returns { kind: {label, count, bytes, paths: PackedStringArray} } for each
## category that found anything. Absent keys mean nothing to do — a caller can
## render `.is_empty()` as "nothing to clean up" without special-casing.
static func scan() -> Dictionary:
	var found: Dictionary = {}
	var installed := _installed_core_names()

	for systemid: String in _systems_on_disk():
		_scan_gamelist(systemid, found)
		_scan_media(systemid, found)
		_scan_partials(systemid, found)

	_scan_core_leftovers(installed, found)
	_scan_saves(installed, found)
	return found


## Remove the categories named in `kinds`. Anything not named is left alone, so
## the caller decides whether saves are in scope.
## Returns {removed: int, freed: int}.
static func remove(found: Dictionary, kinds: Array) -> Dictionary:
	var removed := 0
	var freed := 0

	for kind: String in kinds:
		var entry: Dictionary = found.get(kind, {})
		if entry.is_empty():
			continue
		# The gamelist is rows inside a shared file, not files of its own — the
		# scan already recorded which rows, so the rewrite happens here.
		if kind == GAMELIST:
			for systemid: String in entry.get("systems", []):
				var gl := GamelistManager.new()
				var gone := gl.prune_missing(systemid)
				if not gone.is_empty():
					gl.save_gamelist(systemid)
					removed += gone.size()
			continue
		for path: String in entry.get("paths", []):
			var n := _unlink_recursive(path)
			if n > 0:
				removed += 1
				freed += n

	return {"removed": removed, "freed": freed}


# ── Scanners ─────────────────────────────────────────────────────────────────

## Gamelist rows whose ROM file is gone. Counted without rewriting anything —
## prune_missing on a throwaway manager mutates only its own cache.
static func _scan_gamelist(systemid: String, found: Dictionary) -> void:
	var gl := GamelistManager.new()
	var gone := gl.prune_missing(systemid)
	if gone.is_empty():
		return
	var entry: Dictionary = found.get(GAMELIST, {
		"label": LABELS[GAMELIST], "count": 0, "bytes": 0,
		"paths": [], "systems": []})
	entry["count"] = int(entry["count"]) + gone.size()
	(entry["systems"] as Array).append(systemid)
	found[GAMELIST] = entry


## Media whose ROM is gone AND whose gamelist row is gone.
##
## Both, because either alone is wrong: art is keyed on the ROM basename while
## the file on disk may be `Game.cue` inside a folder, and a ROM that is merely
## evicted from the cache still has a row and will be downloaded again — throwing
## its box art away would mean re-scraping it.
static func _scan_media(systemid: String, found: Dictionary) -> void:
	var index := RomMedia.index(systemid)
	if index.is_empty():
		return

	var live: Dictionary = {}
	for rel: String in GamelistManager.new().known_rom_paths(systemid):
		live[rel.get_file().get_basename()] = true
	for stem: String in _rom_stems_in(systemid):
		live[stem] = true
	for rom_id: int in _romm_ids_for(systemid):
		live["romm:%d" % rom_id] = true

	for path: String in index:
		var key := str(index[path])
		if live.has(key):
			continue
		# RomMedia.index marks a cached RomM cover with a "romm:" key. Kept apart
		# from scraped art because the two are not the same kind of leftover —
		# see the COVERS label.
		_add_file(found, COVERS if key.begins_with("romm:") else MEDIA, path)


## Abandoned `.part` files — the wreckage a failed download leaves, which is
## exactly what the RomM download bug produced. Nothing distinguishes a live
## staging file from a dead one by name, so the caller must not run a sweep
## while a download is in flight; the UI gates on `RommDownloader.is_busy()`.
static func _scan_partials(systemid: String, found: Dictionary) -> void:
	var dir_path := RomLibrary.rom_dir_for_system(systemid)
	_walk_for_suffix(dir_path, ".part", found, PARTIALS)


## Per-core state left by a core that is no longer installed.
static func _scan_core_leftovers(installed: Dictionary, found: Dictionary) -> void:
	var root := CoreDownloadManager.default_core_root()

	var opts := root.path_join("core_options")
	var dir := DirAccess.open(opts)
	if dir != null:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			# Same gate as the system dirs below: a name the info database does
			# not recognise is left alone rather than assumed to be a core that
			# went away.
			var opt_core := fname.trim_suffix(".opt")
			if not dir.current_is_dir() and fname.ends_with(".opt") \
					and not installed.has(opt_core) \
					and not CoreInfoDatabase.shared().get_by_core_name(opt_core).is_empty():
				_add_file(found, CORE_OPTIONS, opts.path_join(fname))
			fname = dir.get_next()
		dir.list_dir_end()

	# A directory under system/ is only a candidate when its name IS a core this
	# app knows about and that core is not installed. "Not installed" alone was
	# wrong twice over, and both were live on a real disk:
	#
	#   system/cheats/       shared infrastructure, not a core at all — it holds
	#                        dolphin-emu/*.cht, and the sweep offered to delete
	#                        them with the box already ticked;
	#   system/melonDS DS/   made by a core that IS installed, which names its
	#                        directory after its display name rather than its
	#                        core_name (melondsds).
	#
	# Asking the info database inverts the test: a name nobody can identify is
	# left alone, which is the only safe default for a directory of unknown
	# provenance.
	var db := CoreInfoDatabase.shared()
	var system_root := root.path_join("system")
	var sys_dir := DirAccess.open(system_root)
	if sys_dir != null:
		sys_dir.list_dir_begin()
		var fname := sys_dir.get_next()
		while fname != "":
			if sys_dir.current_is_dir() and not fname.begins_with(".") \
					and not installed.has(fname) \
					and not db.get_by_core_name(fname).is_empty():
				_add_dir(found, CORE_SYSTEM, system_root.path_join(fname))
			fname = sys_dir.get_next()
		sys_dir.list_dir_end()


## Save folders under a core that is gone, or named for a game that is gone.
##
## Reported, never swept by default — see the class note. The layout is
## save/<core>/<game stem>/, so a stem with no ROM of that name anywhere is the
## test; matching across systems rather than within one is deliberate, because
## the same game can be launched from more than one system folder.
static func _scan_saves(installed: Dictionary, found: Dictionary) -> void:
	var save_root := CoreDownloadManager.default_core_root().path_join("save")
	var root_dir := DirAccess.open(save_root)
	if root_dir == null:
		return

	var stems := _rom_stems_everywhere()

	root_dir.list_dir_begin()
	var core := root_dir.get_next()
	while core != "":
		# memcards/ is a sibling of the per-core folders and is never orphaned:
		# a card belongs to the console, not to any one game.
		if root_dir.current_is_dir() and core != "memcards" and not core.begins_with("."):
			var core_path := save_root.path_join(core)
			var cd := DirAccess.open(core_path)
			if cd != null:
				cd.list_dir_begin()
				var stem := cd.get_next()
				while stem != "":
					if cd.current_is_dir() and not stem.begins_with(".") \
							and not stems.has(stem.to_lower()):
						_add_dir(found, SAVES, core_path.path_join(stem))
					stem = cd.get_next()
				cd.list_dir_end()
		core = root_dir.get_next()
	root_dir.list_dir_end()


# ── Helpers ──────────────────────────────────────────────────────────────────

static func _installed_core_names() -> Dictionary:
	var out: Dictionary = {}
	var dir := DirAccess.open(CoreDownloadManager.default_cores_dir())
	if dir == null:
		return out
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			var cn := CoreDownloadManager.core_name_from_lib_filename(fname)
			if not cn.is_empty():
				out[cn] = true
		fname = dir.get_next()
	dir.list_dir_end()
	return out


## System folders that actually exist, rather than every id the app knows about.
static func _systems_on_disk() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(RomLibrary.default_roms_root())
	if dir == null:
		return out
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if dir.current_is_dir() and not fname.begins_with("."):
			out.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()
	return out


## Every ROM basename on disk, lowercased, across all systems.
static func _rom_stems_everywhere() -> Dictionary:
	var out: Dictionary = {}
	for systemid: String in _systems_on_disk():
		for stem: String in _rom_stems_in(systemid):
			out[stem.to_lower()] = true
	return out


## Basenames of every candidate ROM in one system folder, cased as stored.
##
## A plain walk rather than RomLibrary.scan_roms, which filters by a core's
## supported extensions — the question here is "does any file of this name
## exist", and answering it through an extension list would call a ROM orphaned
## because the core that reads it happens not to be installed.
##
## Skips the sidecar trees: `media/` is what is being judged, `.romm/` is the
## server's catalog, and both would otherwise vouch for themselves.
static func _rom_stems_in(systemid: String) -> PackedStringArray:
	var out := PackedStringArray()
	_collect_stems(RomLibrary.rom_dir_for_system(systemid), out, 0)
	return out


static func _collect_stems(dir_path: String, out: PackedStringArray, depth: int) -> void:
	# A ROM tree is shallow; the bound is only so a symlink loop cannot hang a
	# sweep that the user is watching a spinner for.
	if depth > 6:
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.begins_with("."):
			pass
		elif dir.current_is_dir():
			if not (depth == 0 and fname == RomMedia.ROMM_DIR) \
					and not (depth == 0 and fname == "media"):
				# A "folder as file" game IS the ROM, so the folder's own name
				# counts as much as anything inside it.
				out.append(fname.get_basename())
				_collect_stems(dir_path.path_join(fname), out, depth + 1)
		elif fname != "gamelist.json" and not fname.ends_with(".part"):
			out.append(fname.get_basename())
		fname = dir.get_next()
	dir.list_dir_end()


## RomM ids the cache manifest still claims for a system, so a cover is only an
## orphan once its download is gone too.
## Read-only, and deliberately not through a RommCacheManifest instance.
##
## scan() runs on a worker thread (options_view starts one for the cleanup
## panel), and load_manifest() assigns the manifest's process-wide statics and
## rebuilds both of its indexes. Doing that off the main thread races every
## other toucher of those dictionaries — protect_file on each power-on,
## evict_to_fit during a download — and the losing write can leave the cache
## index empty, which reads to the player as every downloaded ROM vanishing.
static func _romm_ids_for(systemid: String) -> PackedInt64Array:
	return RommCacheManifest.rom_ids_on_disk(systemid)


static func _walk_for_suffix(dir_path: String, suffix: String,
							 found: Dictionary, kind: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		var full := dir_path.path_join(fname)
		if dir.current_is_dir():
			if not fname.begins_with("."):
				_walk_for_suffix(full, suffix, found, kind)
		elif fname.ends_with(suffix):
			_add_file(found, kind, full)
		fname = dir.get_next()
	dir.list_dir_end()


static func _add_file(found: Dictionary, kind: String, path: String) -> void:
	var entry: Dictionary = found.get(kind, {
		"label": LABELS.get(kind, kind), "count": 0, "bytes": 0, "paths": []})
	# A plain Array, never a PackedStringArray: Packed* are value types, so
	# `entry["paths"]` hands back a COPY and appending to it silently does
	# nothing — the category then reports a count with no paths behind it.
	(entry["paths"] as Array).append(path)
	entry["count"] = int(entry["count"]) + 1
	entry["bytes"] = int(entry["bytes"]) + ByteSize.on_disk(path)
	found[kind] = entry


static func _add_dir(found: Dictionary, kind: String, path: String) -> void:
	var entry: Dictionary = found.get(kind, {
		"label": LABELS.get(kind, kind), "count": 0, "bytes": 0, "paths": []})
	(entry["paths"] as Array).append(path)
	entry["count"] = int(entry["count"]) + 1
	entry["bytes"] = int(entry["bytes"]) + _dir_size(path)
	found[kind] = entry



static func _dir_size(path: String) -> int:
	var total := 0
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		var full := path.path_join(fname)
		total += _dir_size(full) if dir.current_is_dir() else ByteSize.on_disk(full)
		fname = dir.get_next()
	dir.list_dir_end()
	return total


static func _unlink(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var size := ByteSize.on_disk(path)
	return size if DirAccess.remove_absolute(path) == OK else 0


static func _unlink_recursive(path: String) -> int:
	if FileAccess.file_exists(path):
		return _unlink(path)
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	var freed := 0
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		freed += _unlink_recursive(path.path_join(fname))
		fname = dir.get_next()
	dir.list_dir_end()
	# Only after its contents; a non-empty directory refuses to go and would be
	# reported as freed anyway.
	DirAccess.remove_absolute(path)
	return freed

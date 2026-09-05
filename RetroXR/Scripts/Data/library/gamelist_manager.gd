## GamelistManager — loads, saves, and queries per-system gamelist.json files.
class_name GamelistManager
extends RefCounted


## Cached gamelists keyed by systemid.
var _gamelists: Dictionary = {}


## Load (or return cached) gamelist for a system. Returns the root dict {"games": [...]}.
func load_gamelist(systemid: String) -> Dictionary:
	if _gamelists.has(systemid):
		return _gamelists[systemid]

	var path := _gamelist_path(systemid)
	if not FileAccess.file_exists(path):
		var empty := {"games": []}
		_gamelists[systemid] = empty
		return empty

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_warning("[GamelistManager] Failed to open: %s" % path)
		var empty := {"games": []}
		_gamelists[systemid] = empty
		return empty

	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	if err != OK:
		push_warning("[GamelistManager] JSON parse error in %s: %s" % [path, json.get_error_message()])
		var empty := {"games": []}
		_gamelists[systemid] = empty
		return empty

	var data: Dictionary = json.data if json.data is Dictionary else {"games": []}
	if not data.has("games"):
		data["games"] = []
	_gamelists[systemid] = data
	return data


## Save a gamelist to disk.
func save_gamelist(systemid: String) -> void:
	if not _gamelists.has(systemid):
		return

	var path := _gamelist_path(systemid)
	var dir_path := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir_path)

	if not JsonStore.write_dict(path, _gamelists[systemid], "GamelistManager"):
		return
	print("[GamelistManager] Saved %s" % path)


## Add or merge a ROM into the gamelist.
##
## A game entry is identified by the ROMS IT HOLDS first and by its game_id only
## second. That order matters, and getting it the other way round is what put
## two entries in the list for one file: the RomM downloader writes
## "romm:<id>" and ScreenScraper writes its own numeric id, so scraping a ROM
## that came from RomM found no game with a matching id and appended a duplicate
## instead of updating the one already there. Everything reading game_id then had
## two answers to choose between, and which one it got depended on insertion
## order — a ROM scraped BEFORE it was downloaded reported no RomM id at all,
## which silently switched off save sync and save-state backup for it.
##
## game_data: {game_id, name, desc, developer, publisher, genre}
## rom_data: {path, romname, releasedate, region}
func add_or_merge_rom(systemid: String, game_data: Dictionary, rom_data: Dictionary) -> void:
	print("[GamelistManager] add_or_merge_rom: system=%s game_id=%s rom=%s" % [systemid, game_data.get("game_id", "?"), rom_data.get("path", "?")])
	# Fold away any duplicates a previous version of this function left behind,
	# so a list that is already split heals the next time anything writes to it.
	dedupe(systemid)
	var gamelist := load_gamelist(systemid)
	var games: Array = gamelist["games"]
	var game_id: String = game_data.get("game_id", "")
	var rom_path: String = rom_data.get("path", "")

	# The entry that already lists this ROM, whatever id it happens to carry.
	var existing_game := _game_holding_rom(games, rom_path)
	if existing_game.is_empty():
		for g: Dictionary in games:
			if g.get("game_id", "") == game_id:
				existing_game = g
				break

	if existing_game.is_empty():
		# New game entry — first ROM is preferred
		rom_data["preferred"] = true
		var new_game := {
			"game_id": game_data.get("game_id", ""),
			"name": game_data.get("name", ""),
			"desc": game_data.get("desc", ""),
			"developer": game_data.get("developer", ""),
			"publisher": game_data.get("publisher", ""),
			"genre": game_data.get("genre", ""),
			"roms": [rom_data],
		}
		games.append(new_game)
	else:
		existing_game["game_id"] = _best_game_id(
			str(existing_game.get("game_id", "")), game_id)
		# Field by field, keeping what is already there when the incoming value
		# is blank. The two writers fill in different things — the downloader
		# sends desc "" and no publisher, the scraper sends both — so a plain
		# overwrite means re-downloading a scraped game erases its description.
		for field: String in ["name", "desc", "developer", "publisher", "genre"]:
			existing_game[field] = _keep_better(
				str(game_data.get(field, "")), str(existing_game.get(field, "")))

		# Find existing ROM by path or add new
		var roms: Array = existing_game.get("roms", [])
		var found := false
		for i in roms.size():
			if _same_rom_path(str((roms[i] as Dictionary).get("path", "")), rom_path):
				# Update existing ROM entry (re-scrape)
				var was_preferred: bool = (roms[i] as Dictionary).get("preferred", false)
				roms[i] = rom_data
				if was_preferred:
					(roms[i] as Dictionary)["preferred"] = true
				found = true
				break
		if not found:
			roms.append(rom_data)
		existing_game["roms"] = roms


## The entry listing this ROM, or {}.
static func _game_holding_rom(games: Array, rom_path: String) -> Dictionary:
	if rom_path.is_empty():
		return {}
	for g: Dictionary in games:
		for r: Dictionary in g.get("roms", []):
			if _same_rom_path(str(r.get("path", "")), rom_path):
				return g
	return {}


## Are these two gamelist paths the same file?
##
## Exact match everywhere, plus case-insensitive where the filesystem is: on
## Windows "Super Mario Bros. 2 (USA).nes" and "super mario bros. 2 (usa).nes"
## are one file, and treating them as two put the same ROM in a game's list
## twice. NOT case-insensitive on Linux or Android, where they are genuinely two
## files and merging them would drop one.
static func _same_rom_path(a: String, b: String) -> bool:
	if a == b:
		return true
	if OS.get_name() in ["Windows", "macOS"]:
		return a.nocasecmp_to(b) == 0
	return false


## Which of two ids to keep when one entry absorbs another.
##
## A "romm:" id is load-bearing — save sync, save-state backup and the cache
## manifest all key on it — while a ScreenScraper id only ever identifies the
## scrape record. So the RomM link is adopted when it arrives and never
## surrendered when it is already held; between two scraper ids the newer wins,
## because a re-scrape is the user re-identifying the game.
static func _best_game_id(existing: String, incoming: String) -> String:
	if incoming.begins_with("romm:"):
		return incoming
	if existing.begins_with("romm:"):
		return existing
	return incoming if not incoming.is_empty() else existing


static func _keep_better(incoming: String, existing: String) -> String:
	return incoming if not incoming.is_empty() else existing


## Fold entries that describe the same ROM into one, and drop repeated ROM paths
## within an entry. Returns how many entries were removed.
##
## Repairs lists written before add_or_merge_rom matched on ROM path. Mutates the
## cache only — the caller saves, matching every other mutator here.
func dedupe(systemid: String) -> int:
	var gamelist := load_gamelist(systemid)
	var games: Array = gamelist.get("games", [])
	var removed := 0

	for gi in range(games.size() - 1, 0, -1):
		var g: Dictionary = games[gi]
		var target: Dictionary = {}
		for r: Dictionary in g.get("roms", []):
			target = _game_holding_rom(games.slice(0, gi), str(r.get("path", "")))
			if not target.is_empty():
				break
		if target.is_empty():
			continue
		target["game_id"] = _best_game_id(
			str(target.get("game_id", "")), str(g.get("game_id", "")))
		for field: String in ["name", "desc", "developer", "publisher", "genre"]:
			target[field] = _keep_better(
				str(target.get(field, "")), str(g.get(field, "")))
		var into: Array = target.get("roms", [])
		for r: Dictionary in g.get("roms", []):
			if _game_holding_rom([target], str(r.get("path", ""))).is_empty():
				into.append(r)
		target["roms"] = into
		games.remove_at(gi)
		removed += 1

	# And the same ROM listed twice inside one entry.
	for g: Dictionary in games:
		var roms: Array = g.get("roms", [])
		for i in range(roms.size() - 1, 0, -1):
			var dup := false
			for j in range(i):
				if _same_rom_path(str((roms[i] as Dictionary).get("path", "")),
						str((roms[j] as Dictionary).get("path", ""))):
					# Keep whichever of the two was marked preferred.
					if bool((roms[i] as Dictionary).get("preferred", false)):
						(roms[j] as Dictionary)["preferred"] = true
					dup = true
					break
			if dup:
				roms.remove_at(i)
		g["roms"] = roms

	if removed > 0:
		print("[GamelistManager] %s: folded %d duplicate game entries" % [systemid, removed])
	return removed


## Drop one ROM from the gamelist. Mutates the cache only — the caller saves,
## matching add_or_merge_rom.
##
## `rom_path` may be absolute or already ROM-root-relative. Returns true when
## something was removed.
##
## A game entry holds every regional/revision copy of one title, so removing the
## last ROM removes the game with it: an entry with an empty `roms` array is a
## title the library claims to have and cannot produce, which is exactly the
## stale row this is meant to stop accumulating.
func remove_rom(systemid: String, rom_path: String) -> bool:
	var relative := rom_path
	if rom_path.is_absolute_path() or rom_path.contains(":"):
		relative = _to_relative_path(systemid, rom_path)
	elif not relative.begins_with("./"):
		relative = "./" + relative.replace("\\", "/").trim_prefix("./")
	if relative.is_empty() or relative == "./":
		return false

	var gamelist := load_gamelist(systemid)
	var games: Array = gamelist.get("games", [])
	var removed := false

	for gi in range(games.size() - 1, -1, -1):
		var g: Dictionary = games[gi]
		var roms: Array = g.get("roms", [])
		var dropped_preferred := false
		for ri in range(roms.size() - 1, -1, -1):
			if str((roms[ri] as Dictionary).get("path", "")) != relative:
				continue
			dropped_preferred = dropped_preferred \
				or bool((roms[ri] as Dictionary).get("preferred", false))
			roms.remove_at(ri)
			removed = true
		if not removed:
			continue
		if roms.is_empty():
			games.remove_at(gi)
		elif dropped_preferred:
			# get_preferred_rom falls back to roms[0] when no flag is set, but a
			# set_preferred_rom later reads the flags, so leaving none set makes
			# the choice depend on which reader asked.
			(roms[0] as Dictionary)["preferred"] = true
		break

	return removed


## Drop every entry whose ROM file is no longer on disk.
## Mutates the cache only. Returns the relative paths removed.
##
## `keep` holds paths a caller knows are live even though the file check would
## say otherwise — nothing uses it yet, but a scan that runs while a download is
## promoting its .part would otherwise prune the row it is about to fill.
func prune_missing(systemid: String, keep: Dictionary = {}) -> PackedStringArray:
	var gone := PackedStringArray()
	var gamelist := load_gamelist(systemid)
	var games: Array = gamelist.get("games", [])

	for gi in range(games.size() - 1, -1, -1):
		var g: Dictionary = games[gi]
		var roms: Array = g.get("roms", [])
		var lost_preferred := false
		for ri in range(roms.size() - 1, -1, -1):
			var rel := str((roms[ri] as Dictionary).get("path", ""))
			if rel.is_empty() or keep.has(rel):
				continue
			var absolute := to_absolute_path(systemid, rel)
			# An unresolvable path is a broken row, not a present file: an
			# absolute or traversing entry cannot be launched either way.
			if not absolute.is_empty() and FileAccess.file_exists(absolute):
				continue
			lost_preferred = lost_preferred \
				or bool((roms[ri] as Dictionary).get("preferred", false))
			gone.append(rel)
			roms.remove_at(ri)
		if roms.is_empty():
			games.remove_at(gi)
		elif lost_preferred:
			(roms[0] as Dictionary)["preferred"] = true

	return gone


## Every ROM-relative path the gamelist claims, for an orphan sweep that needs to
## ask the question the other way round.
func known_rom_paths(systemid: String) -> Dictionary:
	var out: Dictionary = {}
	for g: Dictionary in load_gamelist(systemid).get("games", []):
		for r: Dictionary in g.get("roms", []):
			var rel := str(r.get("path", ""))
			if not rel.is_empty():
				out[rel] = true
	return out


## Find the game entry containing a ROM with the given path. Returns empty dict if not found.
## The game entry listing this ROM, or {}.
##
## When more than one lists it — which a list written before add_or_merge_rom
## matched on ROM path can still contain — the one carrying a "romm:" id wins.
## Returning whichever came first meant the answer depended on whether the ROM
## was scraped before or after it was downloaded, and getting the scraper's
## entry reads as "this ROM is not on RomM", which switches off save sync and
## save-state backup for a game that is.
func get_game_for_rom(systemid: String, rom_path: String) -> Dictionary:
	var relative := _to_relative_path(systemid, rom_path)
	var gamelist := load_gamelist(systemid)
	var fallback: Dictionary = {}
	for g: Dictionary in gamelist.get("games", []):
		for r: Dictionary in g.get("roms", []):
			if not _same_rom_path(str(r.get("path", "")), relative):
				continue
			if str(g.get("game_id", "")).begins_with("romm:"):
				return g
			if fallback.is_empty():
				fallback = g
			break
	return fallback


## Get the preferred ROM dict from a game entry. Returns empty dict if none found.
static func get_preferred_rom(game: Dictionary) -> Dictionary:
	for r: Dictionary in game.get("roms", []):
		if r.get("preferred", false):
			return r
	# Fallback to first ROM
	var roms: Array = game.get("roms", [])
	if not roms.is_empty():
		return roms[0]
	return {}


## Set one ROM as preferred and clear the flag on all others.
func set_preferred_rom(systemid: String, game_id: String, rom_path: String) -> void:
	var gamelist := load_gamelist(systemid)
	for g: Dictionary in gamelist.get("games", []):
		if g.get("game_id", "") == game_id:
			for r: Dictionary in g.get("roms", []):
				r["preferred"] = (r.get("path", "") == rom_path)
			break


## Invalidate cached data for a system (forces reload on next access).
func invalidate(systemid: String) -> void:
	_gamelists.erase(systemid)


## Convert an absolute ROM path to a safe ROM-root-relative path for storage.
## Keep subdirectories: a multi-disc launch manifest commonly lives below one.
static func _to_relative_path(systemid: String, rom_path: String) -> String:
	var relative := RommCacheManifest.relative_path(systemid, rom_path)
	return "./" + relative if not relative.is_empty() else ""


## Convert a relative path from gamelist to absolute.
static func to_absolute_path(systemid: String, relative_path: String) -> String:
	var rom_dir := RomLibrary.rom_dir_for_system(systemid)
	var relative := relative_path.replace("\\", "/").trim_prefix("./")
	if relative.is_empty() or relative.is_absolute_path() or relative.contains(":"):
		return ""
	for part: String in relative.split("/", true):
		if part.is_empty() or part == "." or part == "..":
			return ""
	return rom_dir.path_join(relative)


func _gamelist_path(systemid: String) -> String:
	return RomLibrary.rom_dir_for_system(systemid).path_join("gamelist.json")

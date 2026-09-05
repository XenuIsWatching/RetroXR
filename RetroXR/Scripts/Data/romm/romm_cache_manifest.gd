## RommCacheManifest — records which ROM files came from the RomM server.
##
## One server ROM may become several local files (m3u/cue/tracks). Each entry is
## therefore an eviction group keyed by the original server filename, with one
## launch path and the exact members RetroXR owns. Hand-copied neighbors are
## never listed and are never eligible for deletion.
class_name RommCacheManifest
extends RefCounted


signal changed

const VERSION := 2

## All instances in one process share the same view. RomCompat may re-key an
## archive through a short-lived instance while the menu keeps its own alive;
## separate dictionaries let a later menu touch overwrite that newer manifest.
static var _shared_entries: Dictionary = {}
static var _file_index: Dictionary = {}  # "system/relative member" -> group key
static var _rom_index: Dictionary = {}   # "system/rom id" -> group key
## File keys currently mounted by running systems. Counts matter because two
## cabinets may run the same downloaded game at once.
static var _active_files: Dictionary = {}
var _entries: Dictionary:
	get:
		return _shared_entries
	set(value):
		_shared_entries = value


## Parse the manifest file into a fresh dictionary, touching no shared state.
##
## Split out of load_manifest so a caller that only wants to READ the manifest
## can do so without publishing into the process-wide statics below — which is
## not safe from anything but the main thread. Returns {} for a missing or
## unreadable file, which is the same "start empty" the loader has always used.
static func read_entries() -> Dictionary:
	var path := manifest_path()
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		push_warning("[RommCache] JSON parse error, starting empty")
		return {}
	var data: Dictionary = json.data if json.data is Dictionary else {}
	var raw: Variant = data.get("entries", {})
	var out: Dictionary = {}
	if raw is Dictionary:
		for key: String in raw:
			var value: Variant = raw[key]
			if value is Dictionary:
				out[key] = _normalise_group(key, value)
	return out


## Every downloaded ROM id for one system, read straight off disk.
##
## The thread-safe half of rom_ids_for_system: a background scan must not reach
## it through load_manifest, because that assigns _shared_entries and rebuilds
## both indexes — process-wide state the main thread reads and writes at the
## same time (protect_file on every power-on, evict_to_fit during a download).
static func rom_ids_on_disk(systemid: String) -> PackedInt64Array:
	var out := PackedInt64Array()
	var entries := read_entries()
	for key: String in entries:
		var group: Dictionary = entries[key]
		if str(group.get("systemid", "")) != systemid:
			continue
		var rom_id := int(group.get("rom_id", 0))
		if rom_id != 0:
			out.append(rom_id)
	return out


func load_manifest() -> void:
	var path := manifest_path()
	if FileAccess.file_exists(path) and FileAccess.open(path, FileAccess.READ) == null:
		return  # unreadable rather than absent: keep whatever is already loaded
	_entries = read_entries()
	_rebuild_indexes()


## Returns false when the write did not land. This manifest is what stops the
## cache re-downloading everything, so losing it costs bandwidth rather than
## data — but silently is still the wrong way to lose it.
func save_manifest() -> bool:
	return JsonStore.write_dict(manifest_path(),
		{"version": VERSION, "entries": _entries}, "RommCache")


static func manifest_path() -> String:
	return RomLibrary.default_roms_root().path_join("romm_cache.json")


static func make_key(systemid: String, fs_name: String) -> String:
	return "%s/%s" % [systemid, fs_name]


static func local_path(systemid: String, relative: String) -> String:
	return RomLibrary.rom_dir_for_system(systemid).path_join(relative)


## ROM-root-relative spelling for an absolute or already-relative local path.
static func relative_path(systemid: String, path: String) -> String:
	var normalized := path.replace("\\", "/").simplify_path()
	var root := RomLibrary.rom_dir_for_system(systemid).replace("\\", "/").simplify_path()
	if normalized == root:
		return ""
	if normalized.begins_with(root.trim_suffix("/") + "/"):
		return normalized.trim_prefix(root.trim_suffix("/") + "/")
	return normalized.trim_prefix("./") if not normalized.is_absolute_path() else ""


static func protect_file(systemid: String, path: String) -> void:
	var relative := _safe_relative(relative_path(systemid, path))
	if relative.is_empty():
		return
	var key := make_key(systemid, relative)
	_active_files[key] = int(_active_files.get(key, 0)) + 1


static func unprotect_file(systemid: String, path: String) -> void:
	var relative := _safe_relative(relative_path(systemid, path))
	if relative.is_empty():
		return
	var key := make_key(systemid, relative)
	var remaining := int(_active_files.get(key, 0)) - 1
	if remaining > 0:
		_active_files[key] = remaining
	else:
		_active_files.erase(key)


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

## Resolve an original server name, launch path, or any owned member.
func entry(systemid: String, fs_name: String) -> Dictionary:
	var key := _key_for_file(systemid, fs_name)
	return (_entries[key] as Dictionary) if not key.is_empty() else {}


func cached_path_for_rom(systemid: String, rom_id: int, source_fs_name: String = "") -> String:
	var key := make_key(systemid, source_fs_name)
	if source_fs_name.is_empty() or not _entries.has(key):
		key = str(_rom_index.get("%s/%d" % [systemid, rom_id], ""))
	if key.is_empty() or not _group_exists(_entries[key]):
		return ""
	var group: Dictionary = _entries[key]
	return local_path(systemid, str(group.get("launch", group.get("fs_name", ""))))


func owns_file(systemid: String, fs_name: String) -> bool:
	return not _key_for_file(systemid, fs_name).is_empty()


## Total bytes attributable to server-sourced ROM groups.
func total_bytes() -> int:
	var sum := 0
	for key: String in _entries:
		sum += int((_entries[key] as Dictionary).get("size", 0))
	return sum


## Server ids this system still holds a download for.
##
## The orphan sweep asks so a cached cover is only unlinked once the ROM it
## belongs to is gone: cover art is keyed on the id, and a group whose files were
## evicted for space will be downloaded again — throwing the art away with it
## would mean re-fetching what is already on disk.
func rom_ids_for_system(systemid: String) -> PackedInt64Array:
	var out := PackedInt64Array()
	for key: String in _entries:
		var group: Dictionary = _entries[key]
		if str(group.get("systemid", "")) != systemid:
			continue
		var rom_id := int(group.get("rom_id", 0))
		if rom_id != 0:
			out.append(rom_id)
	return out


## Every downloaded ROM of one system as { rom_id: launch path }.
##
## For a caller that would otherwise ask cached_path_for_rom once per catalog
## row. That call formats a key string and probes two dictionaries, which is
## nothing on its own and 60 ms across a 49,000-row PlayStation index — to find
## the thirteen entries this system actually has. Built once, read by integer.
func cached_paths_for_system(systemid: String) -> Dictionary:
	var out: Dictionary = {}
	for key: String in _entries:
		var group: Dictionary = _entries[key]
		if str(group.get("systemid", "")) != systemid:
			continue
		var rom_id := int(group.get("rom_id", 0))
		if rom_id == 0 or not _group_exists(group):
			continue
		var launch := launch_path(systemid, group)
		if not launch.is_empty():
			out[rom_id] = launch
	return out


## The file this group is actually launched from, or "" when it cannot be named.
##
## `launch` is right whenever the download recorded one. The fallback, `fs_name`,
## is the SERVER's filename -- and for anything that arrived as an archive that is
## the .zip, which was unpacked and deleted. Handing that to a core is handing it
## a path with no file behind it: the machine refuses to start and says nothing a
## player could act on, while the row it came from looks completely normal.
##
## An unambiguous group answers with its own member instead. An ambiguous one
## answers with nothing, which is not a failure -- the caller then resolves the
## title by basename, where a multi-disc set's tracks are already scored against
## each other properly.
static func launch_path(systemid: String, group: Dictionary) -> String:
	var named := str(group.get("launch", group.get("fs_name", "")))
	if not named.is_empty():
		var path := _owned_local_path(systemid, named)
		if not path.is_empty() and FileAccess.file_exists(path):
			return path
	var members: Array = group.get("members", [])
	if members.size() == 1:
		var only := _owned_local_path(systemid, str((members[0] as Dictionary).get("path", "")))
		if not only.is_empty() and FileAccess.file_exists(only):
			return only
	return ""


func lru_keys() -> Array[String]:
	var keys: Array[String] = []
	for key: String in _entries:
		keys.append(key)
	keys.sort_custom(func(a: String, b: String) -> bool:
		return float((_entries[a] as Dictionary).get("last_used_at", 0.0)) \
			< float((_entries[b] as Dictionary).get("last_used_at", 0.0))
	)
	return keys


# ---------------------------------------------------------------------------
# Mutations
# ---------------------------------------------------------------------------

func add(systemid: String, fs_name: String, rom_id: int, size: int, md5: String) -> void:
	add_group(systemid, fs_name, fs_name, rom_id,
		[{"path": fs_name, "size": size}], md5)


## Register a complete download only after every member is in place.
func add_group(systemid: String, source_fs_name: String, launch: String, rom_id: int,
		members: Array, md5: String) -> bool:
	var safe_launch := _safe_relative(launch)
	if safe_launch.is_empty():
		return false
	var clean: Array[Dictionary] = []
	var claimed: Dictionary = {}
	var total := 0
	var has_launch := false
	for value: Variant in members:
		if not value is Dictionary:
			return false
		var member := value as Dictionary
		var member_path := _safe_relative(str(member.get("path", "")))
		if member_path.is_empty() or claimed.has(member_path.to_lower()):
			return false
		claimed[member_path.to_lower()] = true
		var member_size := maxi(0, int(member.get("size", 0)))
		clean.append({"path": member_path, "size": member_size})
		total += member_size
		has_launch = has_launch or member_path == safe_launch
	if clean.is_empty() or not has_launch:
		return false

	# Reload before mutating so a second manifest instance cannot overwrite a
	# download/rekey saved since this instance was created.
	load_manifest()
	var key := make_key(systemid, source_fs_name)
	var previous: Dictionary = _entries.get(key, {})
	_entries[key] = {
		"rom_id": rom_id,
		"systemid": systemid,
		"fs_name": source_fs_name,
		"launch": safe_launch,
		"members": clean,
		"size": total,
		"md5": md5,
		"downloaded_at": previous.get("downloaded_at",
			Time.get_datetime_string_from_system(true)),
		"last_used_at": Time.get_unix_time_from_system(),
	}
	_rebuild_indexes()
	save_manifest()
	changed.emit()
	return true


func touch(systemid: String, fs_name: String) -> void:
	load_manifest()
	var key := _key_for_file(systemid, fs_name)
	if key.is_empty():
		return
	var group: Dictionary = _entries[key]
	group["last_used_at"] = Time.get_unix_time_from_system()
	_entries[key] = group
	save_manifest()


## Delete every exact member in one cache group and forget it. Directories are
## removed only when empty, never recursively.
func evict(key: String) -> int:
	load_manifest()
	return _evict_loaded(key)


func _evict_loaded(key: String, persist: bool = true) -> int:
	if not _entries.has(key):
		return 0
	var group: Dictionary = _entries[key]
	var systemid := str(group.get("systemid", ""))
	var paths: Array[String] = []
	for member: Dictionary in group.get("members", []):
		var relative := _safe_relative(str(member.get("path", "")))
		if relative.is_empty():
			continue
		var path := _owned_local_path(systemid, relative)
		if path.is_empty():
			continue
		paths.append(path)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	for path: String in paths:
		_remove_empty_parents(systemid, path.get_base_dir())
	var size := int(group.get("size", 0))
	_entries.erase(key)
	_rebuild_indexes()
	if persist:
		save_manifest()
		changed.emit()
	return size


func remove_for_file(systemid: String, fs_name: String) -> int:
	load_manifest()
	var key := _key_for_file(systemid, fs_name)
	return _evict_loaded(key) if not key.is_empty() else -1


## Forget ownership without deleting files (used while replacing an archive
## group with the members extracted from it).
func forget(systemid: String, fs_name: String) -> void:
	load_manifest()
	var key := _key_for_file(systemid, fs_name)
	if key.is_empty():
		return
	_entries.erase(key)
	_rebuild_indexes()
	save_manifest()
	changed.emit()


func evict_to_fit(needed_bytes: int, budget_bytes: int,
		protected_keys: Array = []) -> Dictionary:
	load_manifest()
	var protected_groups: Dictionary = {}
	var candidates := protected_keys.duplicate()
	candidates.append_array(_active_files.keys())
	for candidate: String in candidates:
		if _entries.has(candidate):
			protected_groups[candidate] = true
			continue
		var slash := candidate.find("/")
		if slash > 0:
			var resolved := _key_for_file(candidate.left(slash), candidate.substr(slash + 1))
			if not resolved.is_empty():
				protected_groups[resolved] = true

	var freed := 0
	var count := 0
	var used := total_bytes()
	if used + needed_bytes <= budget_bytes:
		return {"freed": 0, "count": 0, "enough": true}

	for key: String in lru_keys():
		if protected_groups.has(key):
			continue
		var size := _evict_loaded(key, false)
		freed += size
		count += 1
		used -= size
		if used + needed_bytes <= budget_bytes:
			break
	if count > 0:
		save_manifest()
		changed.emit()
	return {
		"freed": freed,
		"count": count,
		"enough": used + needed_bytes <= budget_bytes,
	}


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _key_for_file(systemid: String, fs_name: String) -> String:
	var relative := relative_path(systemid, fs_name)
	var direct := make_key(systemid, relative)
	if _entries.has(direct):
		return direct
	return str(_file_index.get(direct, ""))


func _rebuild_indexes() -> void:
	_file_index.clear()
	_rom_index.clear()
	for key: String in _entries:
		var group: Dictionary = _entries[key]
		var systemid := str(group.get("systemid", ""))
		var rom_id := int(group.get("rom_id", 0))
		if rom_id != 0:
			_rom_index["%s/%d" % [systemid, rom_id]] = key
		var launch := str(group.get("launch", ""))
		if not launch.is_empty():
			_file_index[make_key(systemid, launch)] = key
		for member: Dictionary in group.get("members", []):
			var member_path := str(member.get("path", ""))
			if not member_path.is_empty():
				_file_index[make_key(systemid, member_path)] = key


func _group_exists(group: Dictionary) -> bool:
	var systemid := str(group.get("systemid", ""))
	var members: Array = group.get("members", [])
	if members.is_empty():
		return false
	for member: Dictionary in members:
		var relative := _safe_relative(str(member.get("path", "")))
		var path := _owned_local_path(systemid, relative)
		if path.is_empty() or not FileAccess.file_exists(path):
			return false
	return true


static func _normalise_group(key: String, raw: Dictionary) -> Dictionary:
	var slash := key.find("/")
	var systemid := str(raw.get("systemid", key.left(slash) if slash > 0 else ""))
	var fs_name := str(raw.get("fs_name", key.substr(slash + 1) if slash > 0 else key))
	var launch := str(raw.get("launch", fs_name))
	var members: Array = raw.get("members", []) if raw.get("members", []) is Array else []
	if members.is_empty():
		members = [{"path": launch, "size": int(raw.get("size", 0))}]
	var total := 0
	for member: Dictionary in members:
		total += maxi(0, int(member.get("size", 0)))
	return {
		"rom_id": int(raw.get("rom_id", 0)),
		"systemid": systemid,
		"fs_name": fs_name,
		"launch": launch,
		"members": members,
		"size": total,
		"md5": str(raw.get("md5", "")),
		"downloaded_at": raw.get("downloaded_at", ""),
		"last_used_at": float(raw.get("last_used_at", 0.0)),
	}


static func _safe_relative(path: String) -> String:
	var normalized := path.replace("\\", "/")
	if normalized.is_empty() or normalized.is_absolute_path() or normalized.contains(":"):
		return ""
	normalized = normalized.trim_prefix("./")
	for part: String in normalized.split("/", true):
		if part.is_empty() or part == "." or part == "..":
			return ""
	return normalized.simplify_path()


static func _owned_local_path(systemid: String, relative: String) -> String:
	var safe := _safe_relative(relative)
	if safe.is_empty():
		return ""
	var root := RomLibrary.rom_dir_for_system(systemid).simplify_path().trim_suffix("/")
	var candidate := root.path_join(safe).simplify_path()
	if not candidate.begins_with(root + "/"):
		return ""
	var dir := DirAccess.open(root)
	if dir == null:
		return candidate
	var parent := ""
	var parts := safe.split("/", false)
	for i in range(parts.size() - 1):
		parent = parts[i] if parent.is_empty() else parent.path_join(parts[i])
		if dir.is_link(parent):
			return ""
		if not DirAccess.dir_exists_absolute(root.path_join(parent)):
			break
	return candidate


static func _remove_empty_parents(systemid: String, directory: String) -> void:
	var root := RomLibrary.rom_dir_for_system(systemid).simplify_path().trim_suffix("/")
	var current := directory.simplify_path().trim_suffix("/")
	while current != root and current.begins_with(root + "/"):
		var dir := DirAccess.open(current)
		if dir == null or not dir.get_files().is_empty() or not dir.get_directories().is_empty():
			return
		if DirAccess.remove_absolute(current) != OK:
			return
		current = current.get_base_dir()

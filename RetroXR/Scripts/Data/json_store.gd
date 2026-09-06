## JsonStore — read and write one JSON dictionary on disk, atomically.
##
## Every store under Data/ had hand-rolled the same open / get_as_text /
## parse_string / is-it-a-Dictionary ladder, and the same open-and-stream save.
## Two of them (ControllerBindings, GamepadBindings) were byte-identical apart
## from the class name in their error message.
##
## The reason to share it is not the twenty lines. It is that ONLY StatePaths
## wrote atomically: everything else opened the live file and streamed into it,
## so a process killed mid-write — which on a Quest is ordinary app lifecycle,
## and is exactly what SceneManager's NOTIFICATION_WM_CLOSE_REQUEST handler
## exists to survive — truncated it in place. A truncated store does not read as
## an error either; it fails the is-Dictionary check and silently returns the
## default, so the player's bindings or prefs come back as "never set".
##
## Writes therefore go to `<path>.part` and are renamed over the target once the
## bytes are down, the same delete-then-rename StatePaths._write_atomic uses.
##
## Versioning is deliberately NOT handled here. The stores that carry a version
## disagree about what to do on a mismatch — ScenePersistence refuses the file,
## SceneManager and DesktopBindings sniff a known legacy shape and upgrade it,
## TVChannels writes one and never reads it — and folding those into one policy
## would change what happens to real player data. Callers keep their own.
class_name JsonStore
extends RefCounted


## Parse `path` as a JSON object. Returns {} for a file that is missing,
## unreadable, unparseable, or not an object.
##
## `owner` is the label used in the warning; pass the calling class's name so a
## complaint in the log says which store could not be read. An empty owner reads
## a missing or bad file silently, which is what a disposable cache wants.
static func read_dict(path: String, owner: String = "") -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		if not owner.is_empty():
			push_warning("%s: cannot read %s (error %d)"
				% [owner, path, FileAccess.get_open_error()])
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed as Dictionary
	if not owner.is_empty() and not text.strip_edges().is_empty():
		push_warning("%s: %s is not a JSON object, ignoring it" % [owner, path])
	return {}


## Write `data` to `path` as tab-indented JSON, via a staging file.
##
## Returns false and reports through `owner` on any failure, leaving whatever
## was already at `path` untouched — a store that cannot be replaced is better
## than one replaced by half of itself.
# ── Typed reads out of a parsed store ─────────────────────────────────────────
#
# A store on disk is a file the player can edit and a file JSON has already
# round-tripped, so a caller cannot cast what it finds — it has to check. A bool
# read with int() is 0 or 1 whatever was written, and a MISSING key casts to
# zero rather than to the default the caller supplied, which is the difference
# between "never set" and "set to off".
#
# AppPrefs and QualityManager had each written these out, and their float
# readers were byte-identical. They live beside read_dict because that is what
# produced the dictionary being read.

## `fallback` unless `key` holds a real bool.
static func get_bool(data: Dictionary, key: String, fallback: bool) -> bool:
	var value: Variant = data.get(key)
	return value if typeof(value) == TYPE_BOOL else fallback


## `fallback` unless `key` holds a number. Both int and float are accepted: JSON
## numbers come back as floats, but a value written as a whole number can read
## back as an int.
static func get_float(data: Dictionary, key: String, fallback: float) -> float:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return float(value)
	return fallback


## Same contract as get_float, truncated to a whole number.
static func get_int(data: Dictionary, key: String, fallback: int) -> int:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return int(value)
	return fallback


## `fallback` unless `key` holds an object.
static func get_dict(data: Dictionary, key: String, fallback: Dictionary) -> Dictionary:
	var value: Variant = data.get(key)
	return value if typeof(value) == TYPE_DICTIONARY else fallback


## JSON has no packed-array type, so a saved PackedStringArray reads back as a
## plain Array of whatever was in it. Rebuilt element by element, dropping
## anything that is not a non-empty string rather than trusting the file.
static func get_strings(data: Dictionary, key: String) -> PackedStringArray:
	var out := PackedStringArray()
	var value: Variant = data.get(key)
	if typeof(value) != TYPE_ARRAY:
		return out
	for v: Variant in value as Array:
		if typeof(v) == TYPE_STRING and not (v as String).is_empty():
			out.append(v)
	return out


static func write_dict(path: String, data: Dictionary, owner: String = "") -> bool:
	return write_text(path, JSON.stringify(data, "\t"), owner)


## The staged write itself, for a caller that has already serialised its own
## text — a save slot, which is not a plain Dictionary.
##
## Writes a .part beside the target, checks the store actually landed, and only
## then replaces the real file. Writing in place instead means a crash or a power
## cut between open and store leaves a truncated file, and truncated JSON does
## not parse: the save is not merely stale, it is gone.
static func write_text(path: String, text: String, owner: String = "") -> bool:
	var part := path + ".part"
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(part, FileAccess.WRITE)
	if f == null:
		if not owner.is_empty():
			push_error("%s: cannot write %s (error %d)"
				% [owner, part, FileAccess.get_open_error()])
		return false
	f.store_string(text)
	var err := f.get_error()
	f.close()
	if err != OK:
		if not owner.is_empty():
			push_error("%s: write to %s failed (error %d)" % [owner, part, err])
		DirAccess.remove_absolute(part)
		return false
	if FileAccess.file_exists(path) and DirAccess.remove_absolute(path) != OK:
		if not owner.is_empty():
			push_error("%s: cannot replace %s" % [owner, path])
		DirAccess.remove_absolute(part)
		return false
	if DirAccess.rename_absolute(part, path) != OK:
		if not owner.is_empty():
			push_error("%s: cannot promote %s" % [owner, part])
		DirAccess.remove_absolute(part)
		return false
	return true

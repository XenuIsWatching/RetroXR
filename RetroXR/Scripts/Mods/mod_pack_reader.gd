## ModPackReader — read a resource pack WITHOUT mounting it.
##
## This is the whole reason a mod can be one file. ProjectSettings.load_resource_pack
## cannot be undone: once a pack is mounted it is mounted for the session, so the
## loader must learn a mod's identity, API version and file inventory BEFORE it
## commits to anything. Mounting is not the only way to read a pack, though —
##
##   .zip  ProjectSettings.load_resource_pack mounts a zip exactly as it does a
##         pck, and ZIPReader reads any member of one with nothing mounted. This
##         is the recommended format because it needs no binary parsing at all.
##         CoreDownloadManager._extract_zip does the same thing for core archives.
##
##   .pck  The pack's own directory records each entry's OFFSET and SIZE, so a
##         member is a seek() plus get_buffer(). Parsed here against Godot 4.7's
##         core/io/file_access_pack.cpp.
##
## Both are exposed as the same two calls, files() and read(). A reader that
## failed carries `error` and answers nothing.
##
## Deliberately NOT handled: encryption (the directory cannot be read, so the
## inventory cannot be checked, so the pack cannot be trusted) and per-file
## compression in a .pck (see read() — the two files needed before mounting are
## tiny, and growing a decompressor for them is worse than telling the author to
## ship a zip).
class_name ModPackReader
extends RefCounted

## "GDPC", little-endian, as it sits at the head of a .pck.
const PACK_MAGIC := 0x43504447
## The pack format this reads. Godot 4.7 writes 4; the 4.0-era layout was 2 and
## is a DIFFERENT header, so a mismatch is refused rather than guessed at.
## Verified by dumping a PCKPacker-written pck from this engine build.
const PACK_FORMAT_VERSION := 4
## Directory-level flags.
const PACK_DIR_ENCRYPTED := 1 << 0
## File offsets are stored relative to the file base rather than absolutely.
const PACK_REL_FILEBASE := 1 << 1
## Per-file flags.
const PACK_FILE_ENCRYPTED := 1 << 0
const PACK_FILE_REMOVAL := 1 << 1

## Empty while the reader is usable; the reason it is not, otherwise.
var error: String = ""

var _path: String = ""
var _is_zip: bool = false
var _zip: ZIPReader = null
## res:// path -> {offset: int, size: int, flags: int} for the .pck path.
var _entries: Dictionary = {}


## Open `path`, choosing the reader from its extension. Never throws; check
## `error` afterwards.
static func open(path: String) -> ModPackReader:
	var r := ModPackReader.new()
	r._path = path
	match path.get_extension().to_lower():
		"zip":
			r._open_zip()
		"pck":
			r._open_pck()
		_:
			r.error = "not a .zip or .pck"
	return r


func close() -> void:
	if _zip != null:
		_zip.close()
		_zip = null


## Every res://-rooted path the container holds, unsorted.
func files() -> PackedStringArray:
	if not error.is_empty():
		return PackedStringArray()
	if _is_zip:
		var out := PackedStringArray()
		for entry: String in _zip.get_files():
			# A zip resource pack stores paths without the res:// prefix and with
			# no leading slash; a directory entry ends in one and is not a file.
			if entry.ends_with("/"):
				continue
			out.append(_as_res_path(entry))
		return out
	return PackedStringArray(_entries.keys())


func has(res_path: String) -> bool:
	if _is_zip:
		return files().has(res_path)
	return _entries.has(res_path)


## The bytes of one member, or an empty array if it is absent or unreadable.
func read(res_path: String) -> PackedByteArray:
	if not error.is_empty():
		return PackedByteArray()
	if _is_zip:
		return _zip.read_file(_as_zip_path(res_path))
	var e: Dictionary = _entries.get(res_path, {})
	if e.is_empty():
		return PackedByteArray()
	# A compressed entry is stored as compression blocks rather than as its own
	# bytes, and unpicking that in GDScript to read a manifest is not worth it.
	# Reported rather than silently empty so the author is told what to do.
	if int(e["flags"]) & PACK_FILE_ENCRYPTED:
		push_warning("[mods] '%s' is encrypted in %s" % [res_path, _path])
		return PackedByteArray()
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	f.seek(int(e["offset"]))
	var data := f.get_buffer(int(e["size"]))
	f.close()
	return data


## The member parsed as a JSON object, or {} when it is missing or not an object.
func read_json(res_path: String) -> Dictionary:
	var data := read(res_path)
	if data.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(data.get_string_from_utf8())
	return parsed as Dictionary if parsed is Dictionary else {}


# ── zip ───────────────────────────────────────────────────────────────────────

func _open_zip() -> void:
	_is_zip = true
	_zip = ZIPReader.new()
	var err := _zip.open(_path)
	if err != OK:
		_zip = null
		error = "cannot open zip (error %d)" % err


## Godot mounts a zip pack whose entries are res://-relative. Both spellings are
## accepted on the way in because packers differ about the leading slash.
static func _as_res_path(entry: String) -> String:
	var p := entry.trim_prefix("/")
	return p if p.begins_with("res://") else "res://" + p


static func _as_zip_path(res_path: String) -> String:
	return res_path.trim_prefix("res://")


# ── pck ───────────────────────────────────────────────────────────────────────

func _open_pck() -> void:
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		error = "cannot open pck (error %d)" % FileAccess.get_open_error()
		return
	if f.get_32() != PACK_MAGIC:
		# An embedded pack carries the magic at the END of the host executable.
		# Refused rather than chased: a mod is a standalone file.
		f.close()
		error = "not a pck (bad magic - an embedded pack is not supported)"
		return
	var format := f.get_32()
	if format != PACK_FORMAT_VERSION:
		f.close()
		error = "pck format %d, this build reads %d" % [format, PACK_FORMAT_VERSION]
		return
	f.get_32(); f.get_32(); f.get_32()          # engine major / minor / patch

	var dir_flags := f.get_32()
	var file_base := f.get_64()
	var dir_offset := f.get_64()
	if dir_flags & PACK_DIR_ENCRYPTED:
		f.close()
		error = "pck is encrypted, so its contents cannot be checked"
		return
	# Offsets are relative to file_base only when the pack says so; an absolute
	# pack leaves them alone. Reading this wrongly does not fail loudly - it
	# hands back bytes from the wrong part of the file - so it is taken from the
	# flag rather than assumed.
	var origin: int = file_base if (dir_flags & PACK_REL_FILEBASE) else 0

	# The directory lives AFTER the file data and is seeked to. The 16 reserved
	# words following the header are skipped by that seek.
	f.seek(dir_offset)
	var count := f.get_32()
	for _i in range(count):
		var len_path := f.get_32()
		# Paths are NUL-padded up to a 4-byte boundary and the stored length
		# INCLUDES that padding, so the buffer is cut at the first zero byte
		# before being decoded rather than decoded and stripped afterwards.
		var buf := f.get_buffer(len_path)
		var end := buf.size()
		for i in buf.size():
			if buf[i] == 0:
				end = i
				break
		var raw := buf.slice(0, end).get_string_from_utf8()
		var offset := f.get_64() + origin
		var size := f.get_64()
		f.get_buffer(16)                         # md5
		var flags := f.get_32()
		if flags & PACK_FILE_REMOVAL:
			continue
		# Stored WITHOUT the res:// prefix, exactly like a zip pack's entries.
		_entries[_as_res_path(raw)] = {
			"offset": offset, "size": size, "flags": flags,
		}
	f.close()

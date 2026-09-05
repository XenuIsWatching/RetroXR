## FirmwareState — is each declared firmware file actually there, and is it the
## right one?
##
## Presence is a filesystem check. Verification only happens where the .info
## publishes an md5 (85 of 306 files do); everything else can only be reported
## as present. A file that exists but hashes differently is the wrong dump —
## the classic wrong-region PS1 BIOS — and gets its own state rather than being
## folded into "present".
class_name FirmwareState
extends RefCounted


enum Status {
	PRESENT,           ## There, and matching its published md5 if one exists.
	MISMATCH,          ## There, but the md5 disagrees with the .info.
	MISSING_REQUIRED,  ## Absent, and the core needs it.
	MISSING_OPTIONAL,  ## Absent, but the core runs without it.
}

## Hashing a file this big to verify a BIOS is not a trade worth making; such
## an entry reports PRESENT unverified. Nothing in the bundled info database
## comes close, so this only guards against a pathological drop-in.
const MAX_VERIFY_BYTES := 64 * 1024 * 1024

static var _shared: FirmwareState = null

## "<core_name>/<firmware path>" -> {size, mtime, md5}. Keyed on size+mtime so
## a re-open never re-hashes an unchanged file.
var _cache: Dictionary = {}

var _dirty := false


static func shared() -> FirmwareState:
	if _shared == null:
		_shared = FirmwareState.new()
		_shared.load_cache()
	return _shared


## Resolve every requirement for one core.
## Returns the requirement dicts with `dest` and `status` added, in order.
func evaluate(core_name: String, reqs: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for req: Dictionary in reqs:
		var row := req.duplicate()
		var dest: String = FirmwareRequirements.destination(core_name, str(req.get("path", "")))
		row["dest"] = dest
		row["status"] = _status_for(core_name, req, dest)
		out.append(row)
	if _dirty:
		save_cache()
	return out


func _status_for(core_name: String, req: Dictionary, dest: String) -> Status:
	var optional: bool = bool(req.get("optional", true))

	# pcsx2 declares "pcsx2/bios", a folder whose contents it will not name.
	if bool(req.get("is_dir", false)):
		if DirAccess.dir_exists_absolute(dest):
			return Status.PRESENT
		return Status.MISSING_OPTIONAL if optional else Status.MISSING_REQUIRED

	if not FileAccess.file_exists(dest):
		return Status.MISSING_OPTIONAL if optional else Status.MISSING_REQUIRED

	var want := str(req.get("md5", ""))
	if want.is_empty():
		return Status.PRESENT

	var got := _md5_of(core_name, str(req.get("path", "")), dest)
	if got.is_empty():
		return Status.PRESENT
	return Status.PRESENT if got == want else Status.MISMATCH


func _md5_of(core_name: String, path: String, dest: String) -> String:
	var key := core_name + "/" + path
	var size := -1
	var mtime := 0
	var f := FileAccess.open(dest, FileAccess.READ)
	if f != null:
		size = f.get_length()
		f.close()
	mtime = int(FileAccess.get_modified_time(dest))

	var hit: Dictionary = _cache.get(key, {})
	if not hit.is_empty() and int(hit.get("size", -1)) == size and int(hit.get("mtime", 0)) == mtime:
		return str(hit.get("md5", ""))

	if size < 0 or size > MAX_VERIFY_BYTES:
		return ""

	var digest := FileAccess.get_md5(dest).to_lower()
	if digest.is_empty():
		return ""
	_cache[key] = {"size": size, "mtime": mtime, "md5": digest}
	_dirty = true
	return digest


# ── Rollup ────────────────────────────────────────────────────────────────────

## Summarise a system's rows for its home-grid tile.
## Returns {badge, missing_required, mismatched, missing_optional}.
static func summarise(rows: Array[Dictionary]) -> Dictionary:
	var missing_req := 0
	var mismatched := 0
	var missing_opt := 0
	for r: Dictionary in rows:
		match int(r.get("status", Status.PRESENT)):
			Status.MISSING_REQUIRED: missing_req += 1
			Status.MISMATCH:         mismatched += 1
			Status.MISSING_OPTIONAL: missing_opt += 1

	var badge := ""
	if missing_req > 0:
		badge = "%d required missing" % missing_req
	elif mismatched > 0:
		badge = "%d wrong file" % mismatched if mismatched == 1 else "%d wrong files" % mismatched
	elif missing_opt > 0:
		badge = "%d optional" % missing_opt
	elif not rows.is_empty():
		badge = "complete"

	return {
		"badge": badge,
		"missing_required": missing_req,
		"mismatched": mismatched,
		"missing_optional": missing_opt,
	}


# ── Cache ─────────────────────────────────────────────────────────────────────

static func cache_path() -> String:
	return CoreDownloadManager.default_core_root().path_join("firmware_state.json")


func load_cache() -> void:
	_cache.clear()
	_dirty = false
	# A disposable cache: an unreadable file means "re-hash everything", which is
	# correct but slow, so it is read without an owner and complains about nothing.
	var entries: Variant = JsonStore.read_dict(cache_path()).get("entries")
	if entries is Dictionary:
		_cache = entries as Dictionary


func save_cache() -> void:
	if JsonStore.write_dict(cache_path(), {"version": 1, "entries": _cache},
			"FirmwareState"):
		_dirty = false


## Drop a cached hash so the next evaluate() re-reads the file. Call after an
## install writes over an entry.
func invalidate(core_name: String, path: String) -> void:
	_cache.erase(core_name + "/" + path)
	_dirty = true

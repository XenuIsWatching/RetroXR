## RommDownloader — pulls a ROM from RomM onto local disk, then hands back a path
## the existing spawn/launch pipeline can use unchanged.
##
## Runs on its own Thread with a blocking HTTPClient: these are multi-GB, minutes
## long, and must never touch the main thread. Bytes stream to disk in chunks —
## a 4 GB ISO is never assembled in memory.
##
## Downloads land at roms/<systemid>/<fs_name> under the REAL filename, so
## SramPaths.game_stem, MediaDimensions.load_label_texture, ScenePersistence and
## netplay MD5 resolution all keep working with no changes. RommCacheManifest
## records which files came from the server so eviction knows what it may delete.
class_name RommDownloader
extends Node


signal download_started(rom_id: int, label: String, total_bytes: int)
signal download_progress(rom_id: int, received: int, total: int)
## attempt/max are 1-based, for "retry 2/3" in the UI.
signal download_retrying(rom_id: int, attempt: int, max_attempts: int, reason: String)
## ok=false carries a user-facing reason; `path` is the launchable file on success.
signal download_finished(rom_id: int, ok: bool, path: String, error: String)
signal download_cancelled(rom_id: int)
## Eviction made room — surfaced so files never vanish silently.
signal cache_evicted(freed_bytes: int, count: int)

## Transient failures get this many attempts, with 2/4/8 s backoff — matching
## screenscraper_client.gd's retry shape. Because every request carries a Range
## header, a retry RESUMES from the .part instead of restarting a 4 GB pull.
const MAX_RETRIES := 3

var config: RommConfig = null
var manifest: RommCacheManifest = null

var _thread: Thread = null
var _abort := false
var _current_rom_id := 0
## Created on the main thread and used by the worker, so cancellation can wake
## an extraction that is otherwise inside native decompression.
var _active_archive_extractor: RommArchiveExtractor = null
## Queue of pending {entry, systemid} — one download at a time; these are big.
var _queue: Array[Dictionary] = []


func setup(cfg: RommConfig, mf: RommCacheManifest) -> void:
	config = cfg
	manifest = mf


func _exit_tree() -> void:
	cancel_all()


func is_busy() -> bool:
	return _thread != null and _thread.is_alive()


func current_rom_id() -> int:
	return _current_rom_id


func queued_count() -> int:
	return _queue.size()


# ---------------------------------------------------------------------------
# Queueing
# ---------------------------------------------------------------------------

## `entry` is a RommCatalog row: needs id, fs_name, fs_size_bytes, md5_hash,
## name, multi, cover_large.
func enqueue(entry: Dictionary, systemid: String) -> void:
	var rom_id := int(entry.get("id", 0))
	if rom_id == 0:
		return
	if rom_id == _current_rom_id:
		return
	for q: Dictionary in _queue:
		if int((q["entry"] as Dictionary).get("id", 0)) == rom_id:
			return
	_queue.append({"entry": entry, "systemid": systemid})
	_pump()


## Cancel the in-flight download (its .part is kept, so a later tap resumes).
func cancel_current() -> void:
	if is_busy():
		_abort = true
		if _active_archive_extractor != null:
			_active_archive_extractor.request_cancel()


func cancel_all() -> void:
	_queue.clear()
	_abort = true
	if _active_archive_extractor != null:
		_active_archive_extractor.request_cancel()
	if _thread != null:
		if _thread.is_started():
			_thread.wait_to_finish()
		_thread = null
	_active_archive_extractor = null
	_abort = false
	_current_rom_id = 0


func _pump() -> void:
	if is_busy() or _queue.is_empty():
		return

	# Join a finished thread before starting the next.
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null

	var job: Dictionary = _queue.pop_front()
	var entry: Dictionary = job["entry"]
	var systemid: String = job["systemid"]
	var rom_id := int(entry.get("id", 0))
	var fs_name := str(entry.get("fs_name", ""))
	var size := int(entry.get("fs_size_bytes", 0))

	if fs_name.is_empty():
		download_finished.emit(rom_id, false, "", "Server entry has no filename")
		_pump()
		return

	# Make room BEFORE starting. Godot exposes no free-space API, so the budget
	# is the only guard — evicting after the fact means the overflow already
	# happened, and a 4 GB pull that fails at 90% wastes the whole transfer.
	if manifest != null and config != null and size > 0:
		var key := RommCacheManifest.make_key(systemid, fs_name)
		var prot: Array[String] = []
		prot.append(key)
		var res := manifest.evict_to_fit(size, config.cache_budget_bytes(), prot)
		if int(res["count"]) > 0:
			cache_evicted.emit(int(res["freed"]), int(res["count"]))
		if not bool(res["enough"]):
			download_finished.emit(rom_id, false, "",
				"Not enough space for %s (%s)" % [entry.get("name", fs_name), ByteSize.human(size)])
			_pump()
			return

	_abort = false
	_current_rom_id = rom_id
	download_started.emit(rom_id, str(entry.get("name", fs_name)), size)

	_thread = Thread.new()
	_active_archive_extractor = null
	if bool(entry.get("multi", false)):
		_active_archive_extractor = RommArchiveExtractor.new()
	var args := {
		"entry": entry,
		"systemid": systemid,
		"base_url": config.base_url,
		"headers": config.auth_headers(),
		"archive_extractor": _active_archive_extractor,
	}
	if _thread.start(_worker.bind(args)) != OK:
		_thread = null
		_active_archive_extractor = null
		_current_rom_id = 0
		download_finished.emit(rom_id, false, "", "Could not start download thread")
		_pump()


# ---------------------------------------------------------------------------
# Worker thread
# ---------------------------------------------------------------------------

func _worker(args: Dictionary) -> void:
	var entry: Dictionary = args["entry"]
	var systemid: String = args["systemid"]
	var rom_id := int(entry.get("id", 0))
	var is_multi := bool(entry.get("multi", false))
	var archive_extractor: RommArchiveExtractor = \
		args.get("archive_extractor") as RommArchiveExtractor

	RomLibrary.ensure_rom_dir(systemid)

	# A .cue/.gdi/.m3u names further files, and a library that keeps discs as
	# loose files rather than one folder per game gives each of them its own ROM
	# id on the server — `multi` is false and the download is a 98-byte manifest
	# pointing at tracks nobody fetched. Those tracks are transferred as part of
	# the same job, so the set keeps one rom_id, one progress total, and only
	# reports ready once all of it is on disk.
	var jobs: Array[Dictionary] = [entry]
	# Lowercased, because a reference's spelling need not match the server's.
	var claimed := {str(entry.get("fs_name", "")).to_lower(): true}
	# The same set under the real spelling, which is what a cache key is built on.
	var owned := PackedStringArray([str(entry.get("fs_name", ""))])
	var grand_total := int(entry.get("fs_size_bytes", 0))
	var done_bytes := 0
	var launch_path := ""
	var members: Array[Dictionary] = []
	var i := 0

	while i < jobs.size():
		var job: Dictionary = jobs[i]
		var fs_name := str(job.get("fs_name", ""))
		if fs_name.is_empty():
			_emit_finished.call_deferred(rom_id, false, "", "Server entry has no filename")
			return

		var dest := RommCacheManifest.local_path(systemid, fs_name)
		var outcome := _transfer(args, job, dest, rom_id, done_bytes, grand_total)

		match str(outcome["status"]):
			"ok":
				pass
			"cancelled":
				_remove_downloaded_members(systemid, members)
				_emit_cancelled.call_deferred(rom_id)
				return
			_:
				_remove_downloaded_members(systemid, members)
				_emit_finished.call_deferred(rom_id, false, "", str(outcome["error"]))
				return

		# ── Verified and in place ────────────────────────────────────────────
		var transfer_size := ByteSize.on_disk(dest)
		if i == 0 and is_multi:
			var extracted := _extract_multi(dest, systemid, owned, archive_extractor)
			if not str(extracted.get("error", "")).is_empty():
				_remove_downloaded_members(systemid, members)
				if _abort:
					_emit_cancelled.call_deferred(rom_id)
				else:
					_emit_finished.call_deferred(rom_id, false, "", str(extracted["error"]))
				return
			launch_path = str(extracted["launch"])
			members.append_array(extracted.get("members", []))
		else:
			if i == 0:
				launch_path = dest
			members.append({"path": fs_name, "size": transfer_size})
			var refs := _manifest_references(dest)
			if not refs.is_empty():
				var found := _resolve_companions(systemid, refs, claimed)
				var rows: Array = found["rows"]
				for extra: Dictionary in rows:
					jobs.append(extra)
					owned.append(str(extra.get("fs_name", "")))
					grand_total += int(extra.get("fs_size_bytes", 0))
				if not str(found["error"]).is_empty():
					_remove_downloaded_members(systemid, members)
					_emit_finished.call_deferred(rom_id, false, "", str(found["error"]))
					return
				if not rows.is_empty():
					_make_room.call_deferred(systemid, grand_total - done_bytes, owned)

		done_bytes += transfer_size
		i += 1

	var total_size := 0
	for member: Dictionary in members:
		total_size += int(member.get("size", 0))
	if not _reserve_cache_from_worker(systemid, total_size, owned):
		_remove_downloaded_members(systemid, members)
		if _abort:
			_emit_cancelled.call_deferred(rom_id)
		else:
			_emit_finished.call_deferred(rom_id, false, "", "Not enough cache space")
		return
	var launch_relative := RommCacheManifest.relative_path(systemid, launch_path)
	_register_group.call_deferred(systemid, str(entry.get("fs_name", "")), launch_relative,
		rom_id, members, str(entry.get("md5_hash", "")).to_lower())
	_merge_gamelist.call_deferred(systemid, entry, launch_relative)

	_emit_finished.call_deferred(rom_id, true, launch_path, "")


## Retry wrapper around one file. Returns {status, error} with status
## ok / terminal / cancelled.
func _transfer(args: Dictionary, entry: Dictionary, dest: String, rom_id: int,
			   base_done: int, grand_total: int) -> Dictionary:
	var part := dest + ".part"
	var attempt := 0
	var last_error := ""

	while attempt < MAX_RETRIES:
		if _abort:
			return {"status": "cancelled", "error": ""}

		if attempt > 0:
			# 2 s, 4 s, 8 s — same backoff shape as the scraper client.
			var delay := int(pow(2.0, float(attempt)))
			_emit_retrying.call_deferred(rom_id, attempt + 1, MAX_RETRIES, last_error)
			for i in delay * 10:
				if _abort:
					return {"status": "cancelled", "error": ""}
				OS.delay_msec(100)

		var outcome := _attempt_download(args, entry, dest, part, rom_id, base_done, grand_total)

		match str(outcome["status"]):
			"ok":
				return {"status": "ok", "error": ""}
			"cancelled":
				return {"status": "cancelled", "error": ""}
			"terminal":
				return outcome
			"restart":
				# Known-bad bytes (416 / size / hash / bad zip): drop the .part so
				# the next attempt starts clean rather than resuming garbage.
				if FileAccess.file_exists(part):
					DirAccess.remove_absolute(part)
				last_error = str(outcome["error"])
				attempt += 1
			_:  # "transient" — keep the .part and resume from where we stopped
				last_error = str(outcome["error"])
				attempt += 1

	return {"status": "terminal", "error": last_error}


## One transfer attempt. Returns {status, error} where status is one of
## ok / transient / restart / terminal / cancelled.
func _attempt_download(args: Dictionary, entry: Dictionary, dest: String, part: String,
					   rom_id: int, base_done: int, grand_total: int) -> Dictionary:
	var headers: PackedStringArray = args["headers"]
	var fs_name := str(entry.get("fs_name", ""))
	var expected_size := int(entry.get("fs_size_bytes", 0))
	var expected_md5 := str(entry.get("md5_hash", "")).to_lower()

	var http := RommHttp.new()
	if http.open(args["base_url"], func() -> bool: return _abort) != RommHttp.Result.OK:
		return {"status": "transient", "error": "Could not reach the server"}

	# Resume when a .part is already on disk.
	var have := ByteSize.on_disk(part)
	var file: FileAccess
	if have > 0:
		file = FileAccess.open(part, FileAccess.READ_WRITE)
		if file != null:
			file.seek_end()
	else:
		file = FileAccess.open(part, FileAccess.WRITE)

	if file == null:
		http.close()
		return {"status": "terminal", "error": "Cannot write to %s" % part.get_base_dir()}

	var req_headers := PackedStringArray(headers)
	req_headers.append("Range: bytes=%d-" % have)

	var path := "/api/roms/%d/content/%s" % [int(entry.get("id", 0)), fs_name.uri_encode()]
	var resp := http.download_to_file(path, req_headers, file,
		func(received: int, _total: int) -> void:
			_emit_progress.call_deferred(rom_id, base_done + have + received, grand_total),
		func() -> bool: return _abort)

	file.close()
	http.close()

	var result := int(resp["result"])
	var code := int(resp["code"])

	match result:
		RommHttp.Result.ABORTED:
			return {"status": "cancelled", "error": ""}
		RommHttp.Result.WRITE_FAILED:
			return {"status": "terminal", "error": "Not enough space, or disk unwritable"}
		RommHttp.Result.CONNECT_FAILED, RommHttp.Result.REQUEST_FAILED:
			return {"status": "transient", "error": "Connection lost"}
		RommHttp.Result.TIMED_OUT:
			return {"status": "transient", "error": "The server took too long to answer"}
		RommHttp.Result.HTTP_ERROR:
			# 401/403 and 404 are terminal and need distinct messages — a revoked
			# token looks identical to a network error at the transport layer.
			if code == 401 or code == 403:
				return {"status": "terminal", "error": "Sign in to RomM again"}
			if code == 404:
				if FileAccess.file_exists(part):
					DirAccess.remove_absolute(part)
				return {"status": "terminal", "error": RommHttp.ERR_GONE}
			if code == 416:
				# Our .part is longer than the server's file — it changed under us.
				return {"status": "restart", "error": "File changed on the server"}
			if code >= 500:
				return {"status": "transient", "error": "Server error (%d)" % code}
			return {"status": "terminal", "error": "Server refused the download (%d)" % code}

	# ── Verify before promoting the .part ────────────────────────────────────
	var got := ByteSize.on_disk(part)
	var archive := _is_archive(part)

	var verdict := verify_transfer(have, code, int(resp.get("total", 0)), got,
		expected_size, archive)
	if not verdict.is_empty():
		return {"status": "restart", "error": verdict}

	# RomM's md5_hash describes the ROM *content*, while fs_size_bytes describes
	# the file as stored. For a ROM kept as a .zip those are different things —
	# verified against the live server: a 17,086,996-byte zip whose md5_hash is
	# actually the hash of the 134 MB .3ds inside it. Hashing the container would
	# therefore never match, and every archived ROM would fail three retries and
	# go terminal.
	#
	# The response's own Content-Length is the authoritative check on what was
	# transferred, so archives are verified on length in verify_transfer. Multi-file
	# archives get their members' CRCs checked by the streaming extractor; an
	# ordinary archive may be content in its own right for the selected core and
	# must remain unopened.
	if not expected_md5.is_empty() and not archive:
		var sums := RomHasher.compute_checksums(part)
		var md5 := str(sums.get("md5", "")).to_lower()
		if not md5.is_empty() and md5 != expected_md5:
			return {"status": "restart", "error": "Downloaded file was corrupt"}

	# Atomic promote. A partial file must never be visible to RomLibrary.scan_roms
	# — it would spawn as a real cartridge and fail deep inside StartContent.
	if FileAccess.file_exists(dest):
		DirAccess.remove_absolute(dest)
	if DirAccess.rename_absolute(part, dest) != OK:
		return {"status": "terminal", "error": "Could not finalise the download"}

	return {"status": "ok", "error": ""}


## Multi-file ROMs arrive as a zip (RomM injects a generated .m3u). Inspect the
## uncompressed total before writing, then return the launch path plus every
## exact member the cache group owns.
func _extract_multi(zip_path: String, systemid: String,
		keep: PackedStringArray, extractor: RommArchiveExtractor) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		DirAccess.remove_absolute(zip_path)
		return {"launch": "", "members": [], "error": "Could not open multi-file ROM"}

	var dest_dir := RomLibrary.rom_dir_for_system(systemid)
	var plan := _archive_plan(reader, dest_dir)
	reader.close()
	if plan.is_empty():
		DirAccess.remove_absolute(zip_path)
		return {"launch": "", "members": [], "error": "Archive contains unsafe files"}

	var inspected: Dictionary = extractor.inspect(zip_path, plan)
	if not bool(inspected.get("ok", false)):
		DirAccess.remove_absolute(zip_path)
		return {"launch": "", "members": [], "error": str(inspected.get("error", ""))}
	var launch_entry := ""
	var first_playable := ""
	for item: Dictionary in inspected.get("files", []):
		var entry_name := str(item.get("entry", ""))
		var ext := entry_name.get_extension().to_lower()
		if ext == "m3u":
			launch_entry = entry_name
		elif first_playable.is_empty() and ext in ["cue", "ccd", "mds", "iso", "chd", "gdi"]:
			first_playable = entry_name
	if launch_entry.is_empty():
		launch_entry = first_playable
	if launch_entry.is_empty():
		DirAccess.remove_absolute(zip_path)
		return {"launch": "", "members": [], "error": "Archive has no launchable disc file"}
	if not _reserve_cache_from_worker(systemid, int(inspected.get("total_size", 0)), keep):
		DirAccess.remove_absolute(zip_path)
		return {"launch": "", "members": [], "error": "Not enough cache space"}

	var extracted: Dictionary = extractor.extract(zip_path, plan)
	if not bool(extracted.get("ok", false)):
		DirAccess.remove_absolute(zip_path)
		push_warning("RommDownloader: %s"
			% str(extracted.get("error", "Could not unpack archive")))
		return {"launch": "", "members": [], "error": str(extracted.get("error", ""))}
	var launch := ""
	var members: Array[Dictionary] = []

	for item: Dictionary in extracted.get("files", []):
		var relative := str(item.get("relative", ""))
		members.append({"path": relative, "size": int(item.get("size", 0))})
		if str(item.get("entry", "")) == launch_entry:
			launch = str(item.get("path", ""))
	if launch.is_empty():
		_remove_downloaded_members(systemid, members)
		DirAccess.remove_absolute(zip_path)
		return {"launch": "", "members": [], "error": "Launch file was not extracted"}
	DirAccess.remove_absolute(zip_path)

	return {"launch": launch, "members": members, "error": ""}


## Validate every member before the first mkdir/write. ZIP names are untrusted:
## RomM may index user-supplied archives, and path_join() alone accepts ../,
## absolute paths and Windows separators that can escape the ROM directory.
static func _archive_plan(reader: ZIPReader, dest_dir: String) -> Array[Dictionary]:
	var plan: Array[Dictionary] = []
	var claimed: Dictionary = {}
	var root := dest_dir.replace("\\", "/").simplify_path().trim_suffix("/")

	for raw_name: String in reader.get_files():
		var directory := raw_name.replace("\\", "/").ends_with("/")
		var member_name := raw_name.trim_suffix("/") if directory else raw_name
		var relative := ArchiveSafety.safe_member(member_name)
		if relative.is_empty():
			push_warning("RommDownloader: refusing unsafe archive member '%s'" % raw_name)
			return []

		var folded := relative.to_lower()
		if claimed.has(folded):
			push_warning("RommDownloader: refusing colliding archive member '%s'" % raw_name)
			return []
		claimed[folded] = true

		var out_path := root.path_join(relative).simplify_path()
		if not out_path.to_lower().begins_with(root.to_lower() + "/"):
			push_warning("RommDownloader: archive member escaped destination '%s'" % raw_name)
			return []
		if ArchiveSafety.parent_is_link(root, relative):
			push_warning("RommDownloader: archive member crosses a symbolic link '%s'" % raw_name)
			return []
		if directory:
			continue
		# Never overwrite a hand-copied ROM. Until extraction has been registered,
		# an existing file is user-owned from the cache's point of view.
		if FileAccess.file_exists(out_path) or DirAccess.dir_exists_absolute(out_path):
			push_warning("RommDownloader: archive member already exists '%s'" % out_path)
			return []
		plan.append({"entry": raw_name, "relative": relative, "path": out_path})

	return plan


# ---------------------------------------------------------------------------
# Disc manifests
# ---------------------------------------------------------------------------

## Ceiling on a file worth parsing for references. A manifest is a few hundred
## bytes; anything larger carrying one of these extensions is not one.
const MANIFEST_MAX_BYTES := 1 << 20


## File names a downloaded disc manifest points at, without directory parts.
## Empty for anything that is not a manifest.
static func _manifest_references(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var ext := path.get_extension().to_lower()

	# A .ccd names nothing; its companions are fixed by convention.
	if ext == "ccd":
		var stem := path.get_file().get_basename()
		out.append(stem + ".img")
		out.append(stem + ".sub")
		return out

	if ext != "cue" and ext != "gdi" and ext != "m3u":
		return out

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	if f.get_length() > MANIFEST_MAX_BYTES:
		f.close()
		return out
	var text := f.get_as_text()
	f.close()

	for raw: String in text.split("\n", false):
		var line := raw.strip_edges()
		if line.is_empty():
			continue
		var ref_name := ""
		match ext:
			"m3u":
				if not line.begins_with("#"):
					ref_name = line
			"cue":
				if line.substr(0, 4).to_upper() == "FILE":
					ref_name = _cue_file_name(line)
			"gdi":
				ref_name = _gdi_file_name(line)
		if not ref_name.is_empty():
			out.append(ref_name.get_file())

	return out


## `FILE "Game (Disc 1).bin" BINARY`. Unquoted names are legal and may contain
## spaces, so the trailing format keyword is dropped rather than the name being
## taken as the first token.
static func _cue_file_name(line: String) -> String:
	var first := line.find("\"")
	if first >= 0:
		var last := line.rfind("\"")
		return line.substr(first + 1, last - first - 1) if last > first else ""
	var rest := line.substr(4).strip_edges()
	var cut := rest.rfind(" ")
	return rest.substr(0, cut).strip_edges() if cut > 0 else rest


## `1 0 4 2352 "track01.bin" 0`. The first line of a .gdi is a track count and
## yields nothing.
static func _gdi_file_name(line: String) -> String:
	var first := line.find("\"")
	if first >= 0:
		var last := line.rfind("\"")
		return line.substr(first + 1, last - first - 1) if last > first else ""
	var parts := line.split(" ", false)
	return parts[4] if parts.size() >= 6 else ""


## Look referenced names up in the platform's synced catalog, skipping any
## already on disk or already part of this job. Returns
## {rows: Array[Dictionary], error: String} — rows found so far are returned
## even alongside an error, so a partially resolvable set still transfers what
## it can before reporting the gap.
##
## Scans index.jsonl directly rather than going through RommCatalog: this runs
## on the download thread, the catalog holds whichever platform the user is
## browsing, and a substring test rejects a line without parsing it.
func _resolve_companions(systemid: String, refs: PackedStringArray,
						 claimed: Dictionary) -> Dictionary:
	var wanted := PackedStringArray()
	for ref: String in refs:
		var key := ref.to_lower()
		if claimed.has(key):
			continue
		claimed[key] = true
		if not FileAccess.file_exists(RommCacheManifest.local_path(systemid, ref)):
			wanted.append(ref)

	var rows: Array[Dictionary] = []
	if wanted.is_empty():
		return {"rows": rows, "error": ""}

	var f := FileAccess.open(RommCatalog.index_path(systemid), FileAccess.READ)
	if f == null:
		return {"rows": rows,
				"error": "%s is not in the catalog — sync this system first" % wanted[0]}

	var needles := PackedStringArray()
	for w: String in wanted:
		needles.append(JSON.stringify(w))

	var hit := {}
	while not f.eof_reached() and hit.size() < wanted.size():
		var line := f.get_line()
		if line.is_empty():
			continue
		var candidate := false
		for n in needles.size():
			if not hit.has(n) and line.containsn(needles[n]):
				candidate = true
				break
		if not candidate:
			continue
		var parsed: Variant = JSON.parse_string(line)
		if not (parsed is Dictionary):
			continue
		var row: Dictionary = parsed
		var fs_name := str(row.get("fs_name", ""))
		for n in wanted.size():
			if not hit.has(n) and fs_name.nocasecmp_to(wanted[n]) == 0:
				hit[n] = true
				rows.append(row)
				break
	f.close()

	for n in wanted.size():
		if not hit.has(n):
			return {"rows": rows,
					"error": "%s is not in the catalog — re-sync this system" % wanted[n]}

	return {"rows": rows, "error": ""}


# ---------------------------------------------------------------------------
# Main-thread marshalling
# ---------------------------------------------------------------------------

func _emit_progress(rom_id: int, received: int, total: int) -> void:
	download_progress.emit(rom_id, received, total)


func _emit_retrying(rom_id: int, attempt: int, max_attempts: int, reason: String) -> void:
	download_retrying.emit(rom_id, attempt, max_attempts, reason)


func _emit_cancelled(rom_id: int) -> void:
	_current_rom_id = 0
	_active_archive_extractor = null
	download_cancelled.emit(rom_id)
	_pump()


func _emit_finished(rom_id: int, ok: bool, path: String, error: String) -> void:
	_current_rom_id = 0
	_active_archive_extractor = null
	if not ok:
		push_warning("[RommDownloader] rom %d failed: %s" % [rom_id, error])
	download_finished.emit(rom_id, ok, path, error)
	_pump()


func _register_group(systemid: String, source_fs_name: String, launch: String,
		rom_id: int, members: Array, md5: String) -> void:
	if manifest != null:
		manifest.add_group(systemid, source_fs_name, launch, rom_id, members, md5)


## Ask the main thread to run eviction, but never make cancel_all deadlock while
## it joins this worker: abort breaks the polling loop even if the deferred call
## cannot run until after the join returns.
func _reserve_cache_from_worker(systemid: String, bytes: int,
		keep: PackedStringArray) -> bool:
	if manifest == null or config == null or bytes <= 0:
		return true
	var completed := Semaphore.new()
	var result_guard := Mutex.new()
	var result: Dictionary = {}
	_reserve_cache_on_main.call_deferred(
		systemid, bytes, keep, result, result_guard, completed)
	while not completed.try_wait():
		if _abort:
			result_guard.lock()
			result["cancelled"] = true
			result_guard.unlock()
			return false
		OS.delay_msec(10)
	result_guard.lock()
	var enough := bool(result.get("enough", false))
	result_guard.unlock()
	return not _abort and enough


func _reserve_cache_on_main(systemid: String, bytes: int, keep: PackedStringArray,
		result: Dictionary, result_guard: Mutex, completed: Semaphore) -> void:
	result_guard.lock()
	var cancelled := bool(result.get("cancelled", false))
	result_guard.unlock()
	if cancelled:
		completed.post()
		return
	var prot: Array[String] = []
	for fs_name: String in keep:
		prot.append(RommCacheManifest.make_key(systemid, fs_name))
	var eviction := manifest.evict_to_fit(bytes, config.cache_budget_bytes(), prot)
	if int(eviction["count"]) > 0:
		cache_evicted.emit(int(eviction["freed"]), int(eviction["count"]))
	result_guard.lock()
	result["enough"] = bool(eviction["enough"])
	result_guard.unlock()
	completed.post()


static func _remove_downloaded_members(systemid: String, members: Array) -> void:
	for member: Dictionary in members:
		var relative := str(member.get("path", ""))
		if ArchiveSafety.safe_member(relative).is_empty():
			continue
		var path := RommCacheManifest.local_path(systemid, relative)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


## _pump budgeted for the manifest alone — 98 bytes for a cue — so the tracks it
## names arrive with no room made for them. Best-effort: eviction touches the
## manifest file and reports through cache_evicted, both main-thread concerns,
## and a genuinely full disk is still caught by WRITE_FAILED mid-transfer.
## `keep` is this job's own files, which must survive the pass that makes room
## for them.
func _make_room(systemid: String, bytes: int, keep: PackedStringArray) -> void:
	if manifest == null or config == null or bytes <= 0:
		return
	var prot: Array[String] = []
	for fs_name: String in keep:
		prot.append(RommCacheManifest.make_key(systemid, fs_name))
	var res := manifest.evict_to_fit(bytes, config.cache_budget_bytes(), prot)
	if int(res["count"]) > 0:
		cache_evicted.emit(int(res["freed"]), int(res["count"]))


## Merge RomM metadata into gamelist.json so the detail panel, wheel lookup and
## variant grouping all light up for server-sourced ROMs too. "romm:<id>" as the
## game_id keeps these from colliding with ScreenScraper entries.
func _merge_gamelist(systemid: String, entry: Dictionary, fs_name: String) -> void:
	var gl := GamelistManager.new()
	var companies: Array = entry.get("companies", []) if entry.get("companies") is Array else []
	var genres: Array = entry.get("genres", []) if entry.get("genres") is Array else []
	var regions: Array = entry.get("regions", []) if entry.get("regions") is Array else []

	var release := ""
	var epoch := int(entry.get("first_release_date", 0))
	if epoch > 0:
		release = Time.get_date_string_from_unix_time(epoch)

	gl.add_or_merge_rom(systemid, {
		"game_id": "romm:%d" % int(entry.get("id", 0)),
		"name": str(entry.get("name", fs_name.get_basename())),
		"desc": "",
		"developer": str(companies[0]) if not companies.is_empty() else "",
		"publisher": "",
		"genre": ", ".join(PackedStringArray(genres.map(func(g: Variant) -> String: return str(g)))),
	}, {
		"path": "./" + fs_name,
		"romname": fs_name,
		"releasedate": release,
		"region": str(regions[0]) if not regions.is_empty() else "",
	})
	gl.save_gamelist(systemid)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Detect an archive by magic bytes rather than extension — RomM serves whatever
## is on disk, and the requested filename is chosen by the caller.
static func _is_archive(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 4:
		return false
	var magic := f.get_buffer(4)
	f.close()
	if magic.size() < 4:
		return false
	# PK\x03\x04 (zip), also matches the empty/spanned variants PK\x05\x06 / PK\x07\x08
	if magic[0] == 0x50 and magic[1] == 0x4B:
		return true
	# 7z: 37 7A BC AF 27 1C
	if magic[0] == 0x37 and magic[1] == 0x7A and magic[2] == 0xBC and magic[3] == 0xAF:
		return true
	return false


## Did the bytes on disk arrive whole? Returns "" when they did, and the reason
## they did not otherwise — the caller treats any reason as `restart`.
##
##   have          bytes already in the .part before this attempt
##   code          HTTP status of this response
##   served        this response's Content-Length, 0 when it sent none
##   got           bytes in the .part now
##   expected_size the catalog's fs_size_bytes for the ROM
##   is_archive    the .part starts with zip/7z magic
##
## Two rules, in order.
##
## 1. The resume is a REQUEST, not a guarantee. Every attempt sends a Range
##    header; a server that ignores it answers 200 with the WHOLE body, which
##    lands appended onto the partial. `have + served` then equals the corrupt
##    length, so no later check can tell. RomM streams a generated archive for a
##    multi-file ROM and cannot serve a range of one, which makes this ordinary
##    rather than an edge case: without the rule, one hiccup poisons every
##    remaining attempt of only three.
##
## 2. What THIS response promised is the only authority on whether the body
##    arrived whole — HTTPClient leaves STATUS_BODY both when a body ends and
##    when the socket dies mid-stream, so a truncation looks like a clean finish.
##    `fs_size_bytes` is NOT that authority: it describes the ROM as the server
##    FILES it, and for a multi-file entry that is the sum of the members while
##    the body is a zip wrapped around them, necessarily larger by its own
##    headers. Comparing the two failed every such ROM at 100%, three times over,
##    deleting the whole transfer each time. It is used only as a fallback, and
##    only for a body that is the stored file: a streamed archive is left
##    unchecked HERE, not unchecked — a truncated zip fails to open in
##    _extract_multi, whose members are size- and CRC-verified by the extractor.
static func verify_transfer(have: int, code: int, served: int, got: int,
							expected_size: int, is_archive: bool) -> String:
	if have > 0 and code == 200:
		return "The server did not resume the download"

	if served > 0:
		var whole := have + served
		if got != whole:
			return "Incomplete download (%s)" % _size_pair(got, whole)
		return ""

	if expected_size > 0 and not is_archive and got != expected_size:
		return "Incomplete download (%s)" % _size_pair(got, expected_size)
	return ""


## "3.1 GB of 3.3 GB", or exact bytes when rounding would print the same number
## twice. A size check that fails by a few hundred bytes otherwise reports
## "204 MB of 204 MB", which reads as a bug in the message rather than a real
## mismatch — and that is precisely the size of a zip's own headers.
static func _size_pair(got: int, want: int) -> String:
	var a := ByteSize.human(got)
	var b := ByteSize.human(want)
	if a == b:
		return "%d of %d bytes" % [got, want]
	return "%s of %s" % [a, b]

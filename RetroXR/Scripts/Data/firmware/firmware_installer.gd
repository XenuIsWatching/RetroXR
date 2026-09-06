## FirmwareInstaller — fetches BIOS files and core support archives into the
## per-core libretro system directories.
##
## Two job kinds:
##   FILE    one firmware file written to N destinations. A BIOS is often
##           declared by several cores for the same machine, and the system dir
##           is per-core, so one download fans out to every core that wants it.
##   ARCHIVE a buildbot support zip, unpacked into one core's system dir with
##           its internal paths preserved.
##
## Deliberately not built on RommDownloader: that class keys everything on a
## rom_id, writes into the ROM dir, merges gamelist.json and takes part in LRU
## cache eviction — none of which applies here, and a BIOS must never be evicted
## out from under a core. The retry/backoff shape and the error classification
## are the same, because those parts were right.
##
## RommHttp is reused verbatim for both sources. It is a plain blocking
## HTTPClient with no RomM in it beyond the name, and it brings resumable Range
## requests, which HTTPRequest does not — worth having for a 79 MB archive.
class_name FirmwareInstaller
extends Node


## key identifies the job for the UI and the toast; it is the caller's to choose.
signal job_started(key: String, label: String, total_bytes: int)
signal job_progress(key: String, received: int, total: int)
signal job_retrying(key: String, attempt: int, max_attempts: int, reason: String)
signal job_finished(key: String, ok: bool, error: String)
signal job_cancelled(key: String)

const MAX_RETRIES := 3

enum Kind { FILE, ARCHIVE }

var _queue: Array[Dictionary] = []
var _thread: Thread = null
var _abort := false
var _current_key := ""


func _exit_tree() -> void:
	cancel_all()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null


func is_busy() -> bool:
	return _current_key != ""


func current_key() -> String:
	return _current_key


func queued_count() -> int:
	return _queue.size()


func is_queued(key: String) -> bool:
	if _current_key == key:
		return true
	for j: Dictionary in _queue:
		if str(j["key"]) == key:
			return true
	return false


## Fetch one firmware file and write it to every path in `dests`.
##   base_url  server root, e.g. "http://192.168.0.106:8080"
##   path      absolute request path, e.g. "/api/firmware/24/content/gba_bios.bin"
##   headers   auth headers, or empty for an unauthenticated host
##   md5       expected checksum, "" to skip verification
func enqueue_file(key: String, label: String, base_url: String, path: String,
				  headers: PackedStringArray, dests: Array[String],
				  expected_size: int = 0, md5: String = "") -> void:
	if key.is_empty() or dests.is_empty() or is_queued(key):
		return
	_queue.append({
		"kind": Kind.FILE, "key": key, "label": label,
		"base_url": base_url, "path": path, "headers": headers,
		"dests": dests, "size": expected_size, "md5": md5.to_lower(),
	})
	_pump()


## Fetch a buildbot support archive and unpack it into `core_name`'s system dir.
func enqueue_archive(key: String, core_name: String) -> void:
	if key.is_empty() or is_queued(key):
		return
	var a := SystemAssetCatalog.archive_for(core_name)
	if a.is_empty():
		return
	_queue.append({
		"kind": Kind.ARCHIVE, "key": key,
		"label": str(a["label"]), "core_name": core_name,
		"base_url": SystemAssetCatalog.BASE_URL,
		"path": SystemAssetCatalog.archive_path(core_name),
		"headers": PackedStringArray(), "size": 0,
	})
	_pump()


## Stop the running job. Its partial file is kept, so a retry resumes.
func cancel_current() -> void:
	_abort = true


## Stop one job by key, whether it is running or still waiting.
##
## The fetch-all button queues dozens at once, and `cancel_current` on a row
## whose turn has not come yet would abort a stranger's download instead. A
## queued job never reached the worker, so it is dropped here and announced
## directly — `_emit_cancelled` must not run for it: that clears `_current_key`
## and pumps, which would strand the job actually in flight.
func cancel(key: String) -> void:
	if _current_key == key:
		_abort = true
		return
	for i in range(_queue.size()):
		if str(_queue[i]["key"]) == key:
			_queue.remove_at(i)
			job_cancelled.emit(key)
			return


func cancel_all() -> void:
	_queue.clear()
	_abort = true


# ── Queue ─────────────────────────────────────────────────────────────────────

func _pump() -> void:
	if is_busy() or _queue.is_empty():
		return
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null

	var job: Dictionary = _queue.pop_front()
	_abort = false
	_current_key = str(job["key"])

	_thread = Thread.new()
	_thread.start(_worker.bind(job))


func _worker(job: Dictionary) -> void:
	var key := str(job["key"])
	var staging := _staging_path(key)
	DirAccess.make_dir_recursive_absolute(staging.get_base_dir())

	# Announced from here, not from _pump, because the size has to be asked for
	# and asking blocks. A caller that already knows it (RomM states a firmware
	# file's size in its API) is taken at its word; an archive costs one HEAD.
	job["size"] = _probe_size(job)
	_emit_started.call_deferred(key, str(job["label"]), int(job["size"]))

	var attempt := 0
	var last_error := ""
	while attempt < MAX_RETRIES:
		if _abort:
			_emit_cancelled.call_deferred(key)
			return

		if attempt > 0:
			_emit_retrying.call_deferred(key, attempt + 1, MAX_RETRIES, last_error)
			# Sliced so a cancel lands during the backoff, not after it.
			var wait_ms := int(pow(2.0, attempt) * 1000.0)
			var waited := 0
			while waited < wait_ms and not _abort:
				OS.delay_msec(100)
				waited += 100
			if _abort:
				_emit_cancelled.call_deferred(key)
				return

		var res := _attempt(job, staging)
		var status := str(res["status"])
		last_error = str(res.get("error", ""))

		if status == "ok":
			var placed := _place(job, staging)
			DirAccess.remove_absolute(staging)
			_emit_finished.call_deferred(key, bool(placed["ok"]), str(placed.get("error", "")))
			return
		if status == "cancelled":
			_emit_cancelled.call_deferred(key)
			return
		if status == "terminal":
			_emit_finished.call_deferred(key, false, last_error)
			return
		if status == "restart":
			DirAccess.remove_absolute(staging)
		attempt += 1

	_emit_finished.call_deferred(key, false, last_error)


## Ask the server how big the download is, for the toast and the progress bar.
## Purely cosmetic: a probe that fails leaves the size unknown, which the UI
## already renders as a bare label, and the transfer proceeds regardless.
func _probe_size(job: Dictionary) -> int:
	var declared := int(job.get("size", 0))
	if declared > 0:
		return declared

	var http := RommHttp.new()
	if http.open(str(job["base_url"])) != RommHttp.Result.OK:
		return 0
	var out := http.head(str(job["path"]), PackedStringArray(job["headers"]))
	http.close()

	var code := int(out.get("code", 0))
	if int(out["result"]) != RommHttp.Result.OK or code < 200 or code >= 300:
		return 0
	return int(out["total"])


## One transfer into the staging file. Resumes when a partial is already there.
func _attempt(job: Dictionary, staging: String) -> Dictionary:
	var key := str(job["key"])
	var expected := int(job.get("size", 0))

	var have := 0
	var f: FileAccess = null
	if FileAccess.file_exists(staging):
		f = FileAccess.open(staging, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
			have = int(f.get_position())
	if f == null:
		f = FileAccess.open(staging, FileAccess.WRITE)
	if f == null:
		return {"status": "terminal", "error": "Cannot write to %s" % staging.get_base_dir()}

	var http := RommHttp.new()
	var opened := http.open(str(job["base_url"]))
	if opened != RommHttp.Result.OK:
		f.close()
		return {"status": "transient", "error": "Cannot reach the server"}

	var headers := PackedStringArray(job["headers"])
	headers.append("Range: bytes=%d-" % have)

	var progress := func(received: int, total: int) -> void:
		_emit_progress.call_deferred(
			key, have + received, have + total if total > 0 else expected)

	var out: Dictionary = http.download_to_file(
		str(job["path"]), headers, f, progress, func() -> bool: return _abort)
	f.close()
	http.close()

	var result := int(out["result"])
	var code := int(out.get("code", 0))

	if result == RommHttp.Result.ABORTED:
		return {"status": "cancelled"}
	if result == RommHttp.Result.WRITE_FAILED:
		return {"status": "terminal", "error": "Not enough space, or the disk is unwritable"}
	if result == RommHttp.Result.CONNECT_FAILED or result == RommHttp.Result.REQUEST_FAILED:
		return {"status": "transient", "error": "Connection lost"}
	if result == RommHttp.Result.TIMED_OUT:
		return {"status": "transient", "error": "The server took too long to answer"}
	if result == RommHttp.Result.HTTP_ERROR:
		if code == 401 or code == 403:
			return {"status": "terminal", "error": "Sign in to RomM again"}
		if code == 404:
			DirAccess.remove_absolute(staging)
			return {"status": "terminal", "error": "Not available on the server"}
		if code == 416:
			# Already had the whole thing, or the file changed underneath us.
			return {"status": "restart", "error": "File changed on the server"}
		if code >= 500:
			return {"status": "transient", "error": "Server error (%d)" % code}
		return {"status": "terminal", "error": "Server refused the download (%d)" % code}

	# Completeness is judged against this response's Content-Length and nothing
	# else. HTTPClient leaves STATUS_BODY both when the body ends and when the
	# socket dies mid-stream, so without this a truncated archive would install
	# silently; and any size known ahead of the request would only be a guess.
	if have > 0 and code == 200:
		# Range ignored — the full body was appended onto the partial. Must be
		# caught by status, since have + total then equals the corrupt length.
		return {"status": "restart", "error": "The server did not resume the download"}

	var got := _file_size(staging)
	var whole := have + int(out.get("total", 0))
	if whole > have and got != whole:
		return {"status": "restart",
			"error": "Incomplete download (%d of %d bytes)" % [got, whole]}

	var want := str(job.get("md5", ""))
	if not want.is_empty() and FileAccess.get_md5(staging).to_lower() != want:
		return {"status": "restart", "error": "Downloaded file was corrupt"}

	return {"status": "ok"}


## Move the staged download into place. Runs on the worker thread.
func _place(job: Dictionary, staging: String) -> Dictionary:
	if int(job["kind"]) == Kind.ARCHIVE:
		var dir := CoreDownloadManager.default_system_dir(str(job["core_name"]))
		return _extract_preserving_paths(staging, dir)

	var written := 0
	for dest: String in job["dests"]:
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		var bytes := FileAccess.get_file_as_bytes(staging)
		if bytes.is_empty():
			return {"ok": false, "error": "Staged file vanished"}
		var out := FileAccess.open(dest, FileAccess.WRITE)
		if out == null:
			return {"ok": false, "error": "Cannot write %s" % dest.get_file()}
		out.store_buffer(bytes)
		var err := out.get_error()
		out.close()
		if err != OK:
			return {"ok": false, "error": "Write failed for %s" % dest.get_file()}
		written += 1
	return {"ok": written > 0, "error": "" if written > 0 else "Nothing was written"}


## Unpack keeping the archive's own directory structure.
##
## Explicitly NOT CoreDownloadManager._extract_zip, which flattens every entry
## into one directory. That is right for a core zip (a single .dll) and wrong
## here: PPSSPP.zip's ppge_atlas.zim has to land in PPSSPP/, and ScummVM.zip
## carries a two-level theme/extra tree.
func _extract_preserving_paths(zip_path: String, dest_dir: String) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return {"ok": false, "error": "Could not open the downloaded archive"}

	DirAccess.make_dir_recursive_absolute(dest_dir)
	var count := 0
	for entry: String in reader.get_files():
		if entry.ends_with("/"):
			continue
		# The member names come from the server that built the archive, not from
		# the player. Joining a raw one to dest_dir is zip-slip: an entry named
		# ../../../x walks straight out of the firmware folder.
		var relative := ArchiveSafety.safe_member(entry)
		if relative.is_empty():
			reader.close()
			return {"ok": false, "error": "Unsafe path in archive: %s" % entry}
		if ArchiveSafety.parent_is_link(dest_dir, relative):
			reader.close()
			return {"ok": false, "error": "Archive path crosses a link: %s" % entry}
		var out_path := dest_dir.path_join(relative)
		DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f == null:
			reader.close()
			return {"ok": false, "error": "Cannot write %s" % entry}
		f.store_buffer(reader.read_file(entry))
		var err := f.get_error()
		f.close()
		if err != OK:
			reader.close()
			return {"ok": false, "error": "Write failed for %s" % entry}
		count += 1
	reader.close()
	return {"ok": count > 0, "error": "" if count > 0 else "The archive was empty"}


# ── Helpers ───────────────────────────────────────────────────────────────────

## Staged outside the system dir so a half-finished transfer is never mistaken
## for an installed file by the status scan.
static func _staging_path(key: String) -> String:
	var safe := key.replace("/", "_").replace(":", "_").replace("\\", "_")
	return CoreDownloadManager.default_core_root().path_join("temp").path_join(safe + ".part")


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := int(f.get_length())
	f.close()
	return n


# ── Main-thread emitters ──────────────────────────────────────────────────────

func _emit_started(key: String, label: String, total: int) -> void:
	job_started.emit(key, label, total)


func _emit_progress(key: String, received: int, total: int) -> void:
	job_progress.emit(key, received, total)


func _emit_retrying(key: String, attempt: int, total: int, reason: String) -> void:
	job_retrying.emit(key, attempt, total, reason)


func _emit_cancelled(key: String) -> void:
	_current_key = ""
	job_cancelled.emit(key)
	_pump()


func _emit_finished(key: String, ok: bool, error: String) -> void:
	_current_key = ""
	job_finished.emit(key, ok, error)
	_pump()

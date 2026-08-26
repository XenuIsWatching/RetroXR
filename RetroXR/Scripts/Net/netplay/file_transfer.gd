## NetFileTransfer — content-addressed host→client file delivery (multiplayer M3).
##
## Fixed-path child of NetworkManager ("FileTransfer"). Files are identified by
## MD5; the receiver verifies the hash before accepting, so a transfer is either
## byte-perfect or failed.
##
## LEGAL SCOPE: only kinds in TRANSFER_KINDS may cross the wire. ROMs and
## BIOS/firmware are deliberately NOT transferable — commercial-game images are
## copyrighted and sending copies to another player is distribution. Netplay
## instead verifies by hash that each peer already owns a byte-identical copy
## (the same stance RetroArch's netplay takes), and a peer who does not have it
## may look it up on their OWN RomM server; nothing about that path fetches from
## the host. Books, videos, music, discs, posters and save data are transferable:
## generic delivery for user-content-shaped media. Music albums are folders of
## tracks, so they transfer per-track (NetObjectSync builds the manifest); each
## track is a normal single-file transfer keyed by its own MD5.
##
## Wire: chunked 64 KB on CH_FILE (reliable), window of 8 chunks in flight,
## client sends a cumulative ack every 4 chunks. Receiver writes
## user://net_cache/<kind>/<md5>.part, verifies MD5, renames to <md5><ext>.
##
## Also provides the shared MD5 hash cache (mtime+size keyed) used everywhere a
## file hash is needed (spawn entries, netplay ROM verification).
class_name NetFileTransfer
extends Node

const CH_FILE := 3
const CHUNK_SIZE := 65536
const WINDOW := 8            # chunks in flight before waiting for an ack
const ACK_EVERY := 4         # client acks every N received chunks
const REQUEST_TIMEOUT_MS := 10000   # no chunk/ack progress for this long → fail

## Kinds allowed on the wire. "rom" and "firmware" are intentionally absent, and
## this dictionary is where that rule LIVES -- a kind not named here cannot be
## served or requested, so refusing a ROM is a property of the data rather than a
## check every new call site has to remember to write. Adding a kind is a
## deliberate edit to one line, which is the point.
##
## "save" covers memory cards and scratch save folders, "dvd" the video discs,
## "poster" the wall art: all user content, none of it a commercial game image.
const TRANSFER_KINDS := {"book": true, "video": true, "music": true,
	"save": true, "dvd": true, "poster": true}

## Receiver side: what THIS peer is pulling down.
signal transfer_progress(md5: String, received: int, total: int)
signal transfer_done(md5: String, path: String)
signal transfer_failed(md5: String, reason: String)

## Sender side: what this peer is HANDING OUT, and to whom.
##
## The host had all of this and published none of it -- _req_file builds a _sends
## entry with the peer, the hash and the byte count, _pump_send finishes it and
## _file_ack counts the acks, and not one of them said a word. A player pulling a
## 700 MB video off the host was invisible to the host by construction. These
## four carry no new state; they announce what _sends already knows.
signal serve_started(peer_id: int, md5: String, kind: String, size: int)
signal serve_progress(peer_id: int, md5: String, sent: int, total: int)
signal serve_done(peer_id: int, md5: String)
signal serve_refused(peer_id: int, md5: String, reason: String)

var _nm: Node = null

# Host: md5 -> local path we are willing to serve.
var _serve: Dictionary = {}
# Host: active sends: "<peer>:<md5>" -> {peer, md5, file, size, next, acked}
var _sends: Dictionary = {}
# Client: active receives: md5 -> {kind, ext, size, file, path, received, got_chunks}
var _recv: Dictionary = {}

# ── Shared MD5 cache (mtime+size keyed) ──────────────────────────────────────

const HASH_CACHE_PATH := "user://net_cache/hash_cache.json"
static var _hash_cache: Dictionary = {}
static var _hash_cache_loaded := false
static var _hash_mutex := Mutex.new()   # hash_of runs on worker threads too

## While true, a new entry marks the cache dirty instead of rewriting the whole
## JSON file. Every hash_of() otherwise saves the entire dictionary, which is
## fine for the one-at-a-time calls it was written for and quadratic for a warm
## sweep over a library. Only warm_cache() sets it, and it always clears it.
static var _hash_defer_save := false
static var _hash_dirty := false


## MD5 of a file, via the persistent cache. "" if unreadable. First hash of a
## big file blocks (disk-bound); every later call is a dictionary hit.
## Thread-safe — object_sync hashes spawn files on WorkerThreadPool.
static func hash_of(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	_hash_mutex.lock()
	_load_hash_cache()
	var mtime := FileAccess.get_modified_time(path)
	var entry: Dictionary = _hash_cache.get(path, {})
	_hash_mutex.unlock()
	if _entry_is_current(entry, path, mtime):
		return str(entry.get("md5", ""))
	var sums := RomHasher.compute_checksums(path)
	if sums.is_empty():
		return ""
	_hash_mutex.lock()
	# sha1 is kept because RomHasher computed it on this same pass anyway and
	# discarding it means a second full read of the file later. RomM's by-hash
	# lookup falls back to sha1, and ScreenScraper matches on both.
	_hash_cache[path] = {"mtime": mtime, "md5": sums["md5"], "sha1": sums["sha1"],
		"size": sums["size"]}
	_save_hash_cache()
	_hash_mutex.unlock()
	return str(sums["md5"])


## {md5, sha1, size} for a file, via the same cache. Empty if unreadable.
##
## An entry written before sha1 was cached has only the md5, so a miss on sha1
## is a rehash rather than a wrong answer.
static func checksums_of(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	_hash_mutex.lock()
	_load_hash_cache()
	var mtime := FileAccess.get_modified_time(path)
	var entry: Dictionary = _hash_cache.get(path, {})
	_hash_mutex.unlock()
	if _entry_is_current(entry, path, mtime) \
			and not str(entry.get("sha1", "")).is_empty():
		return {"md5": str(entry["md5"]), "sha1": str(entry["sha1"]),
			"size": int(entry.get("size", 0))}
	var sums := RomHasher.compute_checksums(path)
	if sums.is_empty():
		return {}
	_hash_mutex.lock()
	_hash_cache[path] = {"mtime": mtime, "md5": sums["md5"], "sha1": sums["sha1"],
		"size": sums["size"]}
	_save_hash_cache()
	_hash_mutex.unlock()
	return {"md5": str(sums["md5"]), "sha1": str(sums["sha1"]),
		"size": int(sums["size"])}


## Cache-only lookup: returns the MD5 if already known for this exact file
## state, "" otherwise — never hashes (so it never blocks).
static func cached_hash_of(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	_hash_mutex.lock()
	_load_hash_cache()
	var entry: Dictionary = _hash_cache.get(path, {})
	_hash_mutex.unlock()
	if _entry_is_current(entry, path, FileAccess.get_modified_time(path)):
		return str(entry.get("md5", ""))
	return ""


## Is this cache entry still describing the file on disk?
##
## The size half was documented from the start ("mtime+size keyed") and never
## actually compared, which left a real hole: filesystem mtime has one-second
## granularity, so a file rewritten inside the same second kept its old hash for
## ever. Everything downstream trusts that hash to mean "these exact bytes" --
## resolve_by_md5 hands back the path, netplay boots it, and every peer is
## supposed to be running an identical image. A stale entry there is not a slow
## lookup, it is the wrong file.
##
## An entry written before size was recorded has no "size" key and is treated as
## current on mtime alone, so an existing cache is not thrown away wholesale.
static func _entry_is_current(entry: Dictionary, path: String, mtime: int) -> bool:
	if entry.is_empty() or int(entry.get("mtime", -1)) != mtime:
		return false
	if not entry.has("size"):
		return true
	return int(entry["size"]) == size_of(path)


static func size_of(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return int(f.get_length()) if f else 0


static func _load_hash_cache() -> void:
	if _hash_cache_loaded:
		return
	_hash_cache_loaded = true
	var f := FileAccess.open(HASH_CACHE_PATH, FileAccess.READ)
	if f:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			_hash_cache = parsed


## Call with the mutex held, like every other writer here.
static func _save_hash_cache() -> void:
	if _hash_defer_save:
		_hash_dirty = true
		return
	_write_hash_cache()


static func _write_hash_cache() -> void:
	DirAccess.make_dir_recursive_absolute("user://net_cache")
	var f := FileAccess.open(HASH_CACHE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_hash_cache))


## Hash a library ahead of time so resolving BY hash does not have to.
##
## resolve_by_md5 is a reverse lookup -- given a hash, find the file -- so on a
## cold cache it hashes candidate after candidate until one matches. That work
## lands at the worst possible moment: a player pressing Join, waiting on a
## progress-less pause while their ROM folder is read end to end.
##
## Warming it moves the same disk reads to an idle moment and leaves the lookup
## a dictionary hit. It is NOT required for correctness -- resolve_by_md5 still
## hashes on demand for anything the sweep has not reached -- so it can be
## cancelled, interrupted or never run at all.
##
## Runs on WorkerThreadPool, the same pool object_sync already hashes on.
## `budget` bounds a first run over a large library; the rest is picked up by
## later sweeps or on demand.
static func warm_cache(dirs: Array, extensions: Array = [], budget := 400) -> int:
	var pending: Array[String] = []
	for dir: Variant in dirs:
		_collect_unhashed(str(dir), extensions, 3, pending, budget)
		if pending.size() >= budget:
			break
	if pending.is_empty():
		return 0
	_hash_mutex.lock()
	_hash_defer_save = true
	_hash_mutex.unlock()
	# Sequential on purpose. The work is disk-bound, so hashing eight files at
	# once mostly makes the drive seek; and this runs inside a worker task
	# already, where nesting a group task would be the pool waiting on itself.
	for path: String in pending:
		hash_of(path)
	_hash_mutex.lock()
	_hash_defer_save = false
	if _hash_dirty:
		_hash_dirty = false
		_write_hash_cache()
	_hash_mutex.unlock()
	return pending.size()


## Warm the cache without blocking the caller. Fire-and-forget: nothing waits on
## the task, because nothing needs to -- an unfinished sweep only means the next
## lookup does its own hashing, which is what it did before this existed.
static func warm_cache_async(dirs: Array, extensions: Array = [], budget := 400) -> void:
	WorkerThreadPool.add_task(
		func() -> void: warm_cache(dirs, extensions, budget), false,
		"netplay hash warm-up")


## Files under `dir` with no current cache entry. Uses cached_hash_of, which
## never hashes, so building the work list costs no reads of its own.
static func _collect_unhashed(dir: String, extensions: Array, depth: int,
		out: Array[String], budget: int) -> void:
	if depth < 0 or out.size() >= budget or not DirAccess.dir_exists_absolute(dir):
		return
	for fname: String in DirAccess.get_files_at(dir):
		if out.size() >= budget:
			return
		if not extensions.is_empty() \
				and not extensions.has(fname.get_extension().to_lower()):
			continue
		var path := dir.path_join(fname)
		if cached_hash_of(path).is_empty():
			out.append(path)
	for sub: String in DirAccess.get_directories_at(dir):
		# Skip the index/metadata folders the library keeps beside its ROMs.
		if sub.begins_with("."):
			continue
		_collect_unhashed(dir.path_join(sub), extensions, depth - 1, out, budget)


## Find a local file matching `md5`. Checks `hint_path` first, then the net
## cache for `kind`, then any extra directories (recursively, size-prefiltered
## so only same-sized candidates get hashed). Returns "" when nothing matches.
static func resolve_by_md5(md5: String, kind: String, size: int, hint_path: String,
		extra_dirs: Array = []) -> String:
	if md5.is_empty():
		return ""
	if not hint_path.is_empty() and FileAccess.file_exists(hint_path) \
			and hash_of(hint_path) == md5:
		return hint_path
	var cache_dir := "user://net_cache/%s" % kind
	if DirAccess.dir_exists_absolute(cache_dir):
		for fname: String in DirAccess.get_files_at(cache_dir):
			if fname.get_basename().get_file() == md5:
				return cache_dir.path_join(fname)
	var ext := hint_path.get_extension().to_lower()
	for dir: Variant in extra_dirs:
		var found := _search_dir(str(dir), md5, size, ext, 3)
		if not found.is_empty():
			return found
	return ""


static func _search_dir(dir: String, md5: String, size: int, ext: String, depth: int) -> String:
	if depth < 0 or not DirAccess.dir_exists_absolute(dir):
		return ""
	for fname: String in DirAccess.get_files_at(dir):
		var path := dir.path_join(fname)
		if not ext.is_empty() and fname.get_extension().to_lower() != ext:
			continue
		if size > 0:
			var f := FileAccess.open(path, FileAccess.READ)
			if f == null or f.get_length() != size:
				continue
		if hash_of(path) == md5:
			return path
	for sub: String in DirAccess.get_directories_at(dir):
		var found := _search_dir(dir.path_join(sub), md5, size, ext, depth - 1)
		if not found.is_empty():
			return found
	return ""


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_nm = get_parent()


func end_session() -> void:
	for key: String in _sends.keys():
		var s: Dictionary = _sends[key]
		if s.get("file") != null:
			(s["file"] as FileAccess).close()
	_sends.clear()
	for md5: String in _recv.keys():
		_abort_recv(md5, "session ended")


## Host: offer a file for download by hash (idempotent).
func serve_register(md5: String, path: String) -> void:
	if not md5.is_empty() and not path.is_empty():
		_serve[md5] = path


# ── Client API ────────────────────────────────────────────────────────────────

## Ask the host for a file by content hash. Result arrives via transfer_done /
## transfer_failed; progress via transfer_progress. No-op if already fetching.
func request_file(md5: String, kind: String, size: int, ext: String) -> void:
	if not _nm.is_client():
		transfer_failed.emit(md5, "not a client")
		return
	if not TRANSFER_KINDS.has(kind):
		# Client-side mirror of the server-side refusal (see header).
		transfer_failed.emit(md5, "kind '%s' is not transferable" % kind)
		return
	if _recv.has(md5):
		return
	var dir := "user://net_cache/%s" % kind
	DirAccess.make_dir_recursive_absolute(dir)
	var part_path := dir.path_join(md5 + ".part")
	var f := FileAccess.open(part_path, FileAccess.WRITE)
	if f == null:
		transfer_failed.emit(md5, "cannot open cache file")
		return
	var dot_ext := ("." + ext) if not ext.is_empty() else ""
	_recv[md5] = {
		"kind": kind, "size": size, "file": f,
		"part": part_path, "path": dir.path_join(md5 + dot_ext),
		"received": 0, "chunks": 0, "last_ms": Time.get_ticks_msec(),
	}
	_req_file.rpc_id(1, md5, kind)


func is_fetching(md5: String) -> bool:
	return _recv.has(md5)


# ── Wire protocol ────────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable", CH_FILE)
func _req_file(md5: String, kind: String) -> void:
	if not _nm.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Server-side kind allowlist — the authoritative refusal.
	if not TRANSFER_KINDS.has(kind):
		_refuse(sender, md5, "kind '%s' is not transferable" % kind)
		return
	var path := str(_serve.get(md5, ""))
	if path.is_empty() or not FileAccess.file_exists(path):
		_refuse(sender, md5, "file not available")
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_refuse(sender, md5, "file unreadable")
		return
	var key := "%d:%s" % [sender, md5]
	_sends[key] = {"peer": sender, "md5": md5, "file": f,
		"size": f.get_length(), "next": 0, "acked": -1}
	serve_started.emit(sender, md5, kind, f.get_length())
	_file_begin.rpc_id(sender, md5, f.get_length())
	_pump_send(key)


## Refuse a request and say so on BOTH ends. The deny went out to the client and
## left nothing behind on the host, so a peer being turned away was something
## only the peer could know.
func _refuse(peer_id: int, md5: String, reason: String) -> void:
	_file_deny.rpc_id(peer_id, md5, reason)
	serve_refused.emit(peer_id, md5, reason)


@rpc("authority", "call_remote", "reliable", CH_FILE)
func _file_deny(md5: String, reason: String) -> void:
	_abort_recv(md5, reason)


@rpc("authority", "call_remote", "reliable", CH_FILE)
func _file_begin(md5: String, size: int) -> void:
	var r: Dictionary = _recv.get(md5, {})
	if r.is_empty():
		return
	r["size"] = size
	r["last_ms"] = Time.get_ticks_msec()


## Host: send chunks up to the flow-control window.
func _pump_send(key: String) -> void:
	var s: Dictionary = _sends.get(key, {})
	if s.is_empty():
		return
	var f: FileAccess = s["file"]
	var total_chunks := ceili(float(s["size"]) / CHUNK_SIZE) if int(s["size"]) > 0 else 0
	while int(s["next"]) < total_chunks and int(s["next"]) - int(s["acked"]) <= WINDOW:
		var idx: int = s["next"]
		f.seek(idx * CHUNK_SIZE)
		var bytes := f.get_buffer(CHUNK_SIZE)
		_file_chunk.rpc_id(int(s["peer"]), str(s["md5"]), idx, bytes)
		s["next"] = idx + 1
	if int(s["next"]) >= total_chunks and int(s["acked"]) >= total_chunks - 1:
		f.close()
		_sends.erase(key)
		serve_done.emit(int(s["peer"]), str(s["md5"]))


@rpc("authority", "call_remote", "reliable", CH_FILE)
func _file_chunk(md5: String, index: int, bytes: PackedByteArray) -> void:
	var r: Dictionary = _recv.get(md5, {})
	if r.is_empty():
		return
	var f: FileAccess = r["file"]
	f.seek(index * CHUNK_SIZE)
	f.store_buffer(bytes)
	r["received"] = maxi(int(r["received"]), index * CHUNK_SIZE + bytes.size())
	r["chunks"] = int(r["chunks"]) + 1
	r["last_ms"] = Time.get_ticks_msec()
	if int(r["chunks"]) % ACK_EVERY == 0:
		_file_ack.rpc_id(1, md5, index)
	transfer_progress.emit(md5, int(r["received"]), int(r["size"]))
	if int(r["size"]) > 0 and int(r["received"]) >= int(r["size"]):
		_file_ack.rpc_id(1, md5, index)   # final cumulative ack
		_finish_recv(md5)


@rpc("any_peer", "call_remote", "reliable", CH_FILE)
func _file_ack(md5: String, upto: int) -> void:
	if not _nm.is_host():
		return
	var key := "%d:%s" % [multiplayer.get_remote_sender_id(), md5]
	var s: Dictionary = _sends.get(key, {})
	if s.is_empty():
		return
	s["acked"] = maxi(int(s["acked"]), upto)
	# On the ack, not the chunk. The client acks every ACK_EVERY chunks, so this
	# is roughly one emission per 256 KB rather than one per 64 KB -- the same
	# rule join_state_progress follows, and for the same reason: a progress bar
	# is 300 px wide and does not need four updates to move one of them.
	var sent := mini((int(s["acked"]) + 1) * CHUNK_SIZE, int(s["size"]))
	serve_progress.emit(int(s["peer"]), str(s["md5"]), sent, int(s["size"]))
	_pump_send(key)


func _finish_recv(md5: String) -> void:
	var r: Dictionary = _recv.get(md5, {})
	if r.is_empty():
		return
	(r["file"] as FileAccess).close()
	_recv.erase(md5)
	var part := str(r["part"])
	# Byte-perfect or nothing: verify the content hash before accepting.
	var sums := RomHasher.compute_checksums(ProjectSettings.globalize_path(part))
	if str(sums.get("md5", "")) != md5:
		DirAccess.remove_absolute(part)
		transfer_failed.emit(md5, "hash mismatch after transfer")
		return
	var final_path := str(r["path"])
	if FileAccess.file_exists(final_path):
		DirAccess.remove_absolute(final_path)
	DirAccess.rename_absolute(part, final_path)
	print("[NetFileTransfer] received %s (%d bytes) -> %s" % [md5, int(r["received"]), final_path])
	transfer_done.emit(md5, final_path)


func _abort_recv(md5: String, reason: String) -> void:
	var r: Dictionary = _recv.get(md5, {})
	if r.is_empty():
		return
	(r["file"] as FileAccess).close()
	DirAccess.remove_absolute(str(r["part"]))
	_recv.erase(md5)
	transfer_failed.emit(md5, reason)


func _process(_delta: float) -> void:
	if _recv.is_empty():
		return
	var now := Time.get_ticks_msec()
	for md5: String in _recv.keys():
		if now - int(_recv[md5]["last_ms"]) > REQUEST_TIMEOUT_MS:
			_abort_recv(md5, "transfer timed out")

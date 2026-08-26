## NetplayContent -- what a shared room needs, what this peer is missing, and
## where each missing thing can legitimately come from.
##
## THE RULE THIS FILE EXISTS TO KEEP: game ROMs and BIOS/firmware are never sent
## between players. They are identified by hash, resolved out of the joiner's own
## library, and failing that looked up on the joiner's OWN RomM server. If none
## of that finds it, the answer is "you do not have this game" -- not a transfer
## offer, and not a switch that turns one on. NetFileTransfer.TRANSFER_KINDS is
## where that boundary is enforced; this file never works around it.
##
## Everything else in the room -- books, tapes, discs, posters, memory cards --
## is user media and moves over the transfer channel that already exists.
##
## It owns no transport. Room media already flows through NetObjectSync, ROMs
## already resolve by hash in RetroSystem, and RomM already has a downloader with
## progress signals. What was missing was somewhere that knows about all three at
## once, so a player can be shown one list instead of three silences.
class_name NetplayContent
extends Node

## A row's state changed. `state` is one of the STATE_* constants below.
signal item_changed(key: String, state: String, received: int, total: int)
## The row set itself changed and the page should rebuild rather than patch.
signal manifest_changed()

const STATE_HAVE := "have"
const STATE_FETCHING := "fetching"
const STATE_ROMM := "romm"
const STATE_MISSING := "missing"
const STATE_BLOCKED := "blocked"

## Kinds that are identified but never sent, whatever else is true.
const NEVER_SENT := {"rom": true, "firmware": true}

var _nm: Node = null
var _romm_client: RommClient = null
var _romm_downloader: RommDownloader = null
var _scraper: AutoScraper = null

## key -> row. The key is "<class>:<md5>" so a row survives a rebuild.
var _rows: Dictionary = {}
## md5 -> rom_id, for RomM lookups already answered.
var _romm_hits: Dictionary = {}
var _lookups_in_flight: Dictionary = {}
## systemid -> true once its folder has been swept, so a rebuild does not sweep
## it again.
var _warmed: Dictionary = {}
## md5 -> state, so rebuilding the page does not re-walk a ROM folder per row.
## Dropped whenever a download finishes or a session ends, which are the only
## things that can change the answer.
var _rom_state_cache: Dictionary = {}


func setup(nm: Node, client: RommClient, downloader: RommDownloader,
		scraper: AutoScraper) -> void:
	_nm = nm
	_romm_client = client
	_romm_downloader = downloader
	_scraper = scraper
	if _romm_downloader != null:
		_romm_downloader.download_progress.connect(_on_romm_progress)
		_romm_downloader.download_finished.connect(_on_romm_finished)
	if _nm != null and _nm.has_signal("netplay_state_progress"):
		_nm.netplay_state_progress.connect(_on_state_progress)
	if _nm != null and _nm.has_signal("session_ended"):
		_nm.session_ended.connect(func(_r: String) -> void: invalidate())


## Pre-hash only the folders this session could possibly need.
##
## NOT the whole library, deliberately. A ROM library is tens of gigabytes and a
## blanket sweep would read all of it to answer a question about one game --
## expensive anywhere, punishing on a headset. The session names the systems in
## play, so the sweep is scoped to those consoles' folders; everything else is
## never touched, and anything the sweep misses is still hashed on demand by
## resolve_by_md5 exactly as before.
##
## Mostly belt-and-braces now that lookups are narrowed by systemid AND exact
## size: it earns its keep when an older host sends no rom_size, which puts the
## size prefilter out of action.
##
## Once per system, not once per rebuild. rebuild() runs whenever the page is
## opened or the room changes, and each sweep walks a folder and stats every
## file in it -- worth doing once, pointless to repeat.
func warm_for_session(rows: Array) -> void:
	var dirs: Array = []
	for row: Dictionary in rows:
		var sid := str(row.get("systemid", ""))
		if sid.is_empty() or _warmed.has(sid):
			continue
		_warmed[sid] = true
		dirs.append(RomLibrary.rom_dir_for_system(sid))
	if not dirs.is_empty():
		NetFileTransfer.warm_cache_async(dirs)


static func key_for(content_class: String, md5: String) -> String:
	return "%s:%s" % [content_class, md5]


## True when a class of content may cross the wire at all.
##
## Asks NetFileTransfer rather than keeping its own list: two lists is how one of
## them quietly stops matching the one that enforces.
static func is_transferable(content_class: String) -> bool:
	if NEVER_SENT.has(content_class):
		return false
	return NetFileTransfer.TRANSFER_KINDS.has(content_class)


## Rebuild the row set from the room and the running session.
##
## Room media comes from NetObjectSync, which already tracks every file-backed
## object; the machines' ROMs and firmware come from the session's own specs, so
## the page describes the game being played rather than the host's whole library.
func rebuild() -> void:
	_rows.clear()
	for row: Dictionary in _room_rows():
		_rows[key_for(str(row["class"]), str(row["md5"]))] = row
	var machines := _machine_rows()
	for row: Dictionary in machines:
		_rows[key_for(str(row["class"]), str(row["md5"]))] = row
	warm_for_session(machines)
	manifest_changed.emit()


## Forget what was resolved from disk. Called when something that could change
## the answer happens -- a download landing, a session ending -- rather than on
## every rebuild, which is what made the page re-walk a ROM folder to redraw.
func invalidate() -> void:
	_rom_state_cache.clear()


## Every row, worst first: what blocks the session before what merely decorates
## it, so the top of the list is the thing to act on.
func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for key: String in _rows:
		out.append(_rows[key])
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra := _priority(a)
		var rb := _priority(b)
		if ra != rb:
			return ra < rb
		return str(a.get("label", "")) < str(b.get("label", "")))
	return out


## The rows a "Download all" would actually act on.
##
## Deliberately excludes anything missing that cannot be supplied: offering to
## fetch a ROM nobody may send is a button that lies.
func actionable() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row: Dictionary in rows():
		if _is_actionable(row):
			out.append(row)
	return out


## Total bytes a "Download all" would move, for the confirmation the player sees
## before committing a headset on Wi-Fi to it.
func actionable_bytes() -> int:
	var total := 0
	for row: Dictionary in actionable():
		total += int(row.get("size", 0))
	return total


## Start everything actionable, blocking items first.
##
## Sequential by construction: both queues behind this are single-flight, so
## enqueuing the lot lets them drain rather than saturating the same link the
## session's own traffic is using.
func download_all() -> int:
	var started := 0
	for row: Dictionary in actionable():
		if _start_row(row):
			started += 1
	return started


func cancel_all() -> void:
	if _romm_downloader != null:
		_romm_downloader.cancel_all()


## Ask this peer's OWN RomM server whether it has the ROM behind this hash.
##
## The first caller rom_by_hash has ever had. Nothing is fetched from the host
## here -- the host supplied a hash and a name, and the lookup happens entirely
## between this player and their own server.
func lookup_romm(md5: String, sha1: String) -> void:
	if _romm_client == null or md5.is_empty() or _lookups_in_flight.has(md5):
		return
	if not _romm_client.is_reachable():
		return
	_lookups_in_flight[md5] = true
	_romm_client.rom_by_hash(md5, sha1, func(ok: bool, data: Dictionary) -> void:
		_lookups_in_flight.erase(md5)
		if not ok or data.is_empty() or int(data.get("id", 0)) == 0:
			return
		_romm_hits[md5] = data
		var key := key_for("rom", md5)
		if _rows.has(key):
			var row: Dictionary = _rows[key]
			row["state"] = STATE_ROMM
			row["romm"] = data
			item_changed.emit(key, STATE_ROMM, 0, int(row.get("size", 0))))


## Scrape a ROM that has just become available, if it has no metadata yet.
##
## Called for both routes a ROM arrives by -- matched in the local library, or
## downloaded from RomM -- because a file that appeared without anyone browsing
## for it is exactly the one nobody will think to scrape by hand.
func note_rom_available(rom_path: String, systemid: String) -> void:
	if _scraper == null or rom_path.is_empty():
		return
	var sid := systemid
	if sid.is_empty():
		sid = AutoScraper.systemid_for_path(rom_path)
	_scraper.request(rom_path, sid)


func _room_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _nm == null or not ("_object_sync" in _nm):
		return out
	var sync: Object = _nm.get("_object_sync")
	if sync == null or not sync.has_method("content_manifest"):
		return out
	for entry: Dictionary in sync.content_manifest():
		var md5 := str(entry.get("md5", ""))
		if md5.is_empty():
			continue
		var content_class := str(entry.get("class", ""))
		out.append({
			"class": content_class,
			"md5": md5,
			"size": int(entry.get("size", 0)),
			"label": str(entry.get("label", "")),
			"transferable": is_transferable(content_class),
			"state": STATE_HAVE if bool(entry.get("have", false))
				else (STATE_MISSING if is_transferable(content_class) else STATE_MISSING),
			"blocking": false,
		})
	return out


## The ROM and firmware each machine in the session needs. Both are NEVER_SENT,
## and both block the session rather than decorating it.
func _machine_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _nm == null or not ("_netplay" in _nm):
		return out
	var session: Object = _nm.get("_netplay")
	if session == null or not ("_machine_specs" in session):
		return out
	for spec: Dictionary in (session.get("_machine_specs") as Array):
		if str(spec.get("mode", "")) != "rom":
			continue
		var md5 := str(spec.get("rom_md5", ""))
		if md5.is_empty():
			continue
		out.append({
			"class": "rom",
			"md5": md5,
			"sha1": str(spec.get("rom_sha1", "")),
			"size": int(spec.get("rom_size", 0)),
			"label": str(spec.get("rom_label", "")),
			"systemid": str(spec.get("systemid", "")),
			"transferable": false,
			"state": _rom_state(md5, int(spec.get("rom_size", 0)),
				str(spec.get("systemid", ""))),
			"blocking": true,
		})
	return out


## `size` matters more than it looks: resolve_by_md5 only applies its
## same-size prefilter when it is non-zero, so passing 0 makes it hash every
## file in the ROM tree instead of the handful that could possibly match.
func _rom_state(md5: String, size := 0, systemid := "") -> String:
	# Memoized: resolve_by_md5 lists a directory and may hash, and rebuild()
	# asks once per machine every time the page is opened. The answer only
	# changes when a download lands or the session ends, and both clear this.
	if _rom_state_cache.has(md5):
		return str(_rom_state_cache[md5])
	var dirs: Array = [RomLibrary.rom_dir_for_system(systemid)] if not systemid.is_empty() \
		else [RomLibrary.default_roms_root()]
	var found := NetFileTransfer.resolve_by_md5(md5, "rom", size, "", dirs)
	var state := STATE_MISSING
	if not found.is_empty():
		# Found locally rather than downloaded, which is the other way a ROM
		# turns up unscraped: it was on the shelf all along and nobody opened it.
		note_rom_available(found, "")
		state = STATE_HAVE
	elif _romm_hits.has(md5):
		state = STATE_ROMM
	_rom_state_cache[md5] = state
	return state


## Blocking problems first, then things in flight, then the merely absent.
func _priority(row: Dictionary) -> int:
	var state := str(row.get("state", ""))
	var blocking := bool(row.get("blocking", false))
	if blocking and state != STATE_HAVE:
		return 0
	if state == STATE_FETCHING:
		return 1
	if state == STATE_ROMM:
		return 2
	if state == STATE_MISSING:
		return 3
	return 4


func _is_actionable(row: Dictionary) -> bool:
	var state := str(row.get("state", ""))
	if state == STATE_HAVE or state == STATE_FETCHING:
		return false
	if state == STATE_ROMM:
		return true
	return bool(row.get("transferable", false))


func _start_row(row: Dictionary) -> bool:
	var key := key_for(str(row["class"]), str(row["md5"]))
	if str(row.get("state", "")) == STATE_ROMM:
		var hit: Dictionary = row.get("romm", _romm_hits.get(str(row["md5"]), {}))
		if hit.is_empty() or _romm_downloader == null:
			return false
		_romm_downloader.enqueue(hit, str(row.get("systemid", "")))
		row["state"] = STATE_FETCHING
		item_changed.emit(key, STATE_FETCHING, 0, int(row.get("size", 0)))
		return true
	if not bool(row.get("transferable", false)):
		return false
	# Room media is fetched by the object that needs it; NetObjectSync requests
	# the file when the spawn entry resolves, so there is nothing to start here
	# beyond reporting that it is waiting on one.
	row["state"] = STATE_FETCHING
	item_changed.emit(key, STATE_FETCHING, 0, int(row.get("size", 0)))
	return true


func _on_romm_progress(rom_id: int, received: int, total: int) -> void:
	for key: String in _rows:
		var row: Dictionary = _rows[key]
		var hit: Dictionary = row.get("romm", {})
		if int(hit.get("id", 0)) == rom_id:
			item_changed.emit(key, STATE_FETCHING, received, total)
			return


func _on_romm_finished(rom_id: int, ok: bool, path: String, _error: String) -> void:
	for key: String in _rows:
		var row: Dictionary = _rows[key]
		var hit: Dictionary = row.get("romm", {})
		if int(hit.get("id", 0)) != rom_id:
			continue
		row["state"] = STATE_HAVE if ok else STATE_MISSING
		# The file on disk just changed, so the memoized answer is now wrong.
		_rom_state_cache.erase(str(row.get("md5", "")))
		item_changed.emit(key, str(row["state"]), 0, int(row.get("size", 0)))
		if ok and not path.is_empty():
			note_rom_available(path, str(row.get("systemid", "")))
		return


func _on_state_progress(_peer_id: int, phase: String, received: int, total: int) -> void:
	item_changed.emit("netjoin:state", phase, received, total)

## EReaderCards — groups e-Reader dotcode files into cards and says which edge
## each strip is printed on.
##
## A card is one to two .raw dotcode strips. The No-Intro set names multi-strip
## cards two different ways and BOTH must be grouped, or every long+short pairing
## is silently split into two cards:
##
##   "<card> (Strip 1).raw"     / "<card> (Strip 2).raw"       two long strips
##   "<card> (Long Strip).raw"  / "<card> (Short Strip).raw"   long + short
##   "<card>.raw"                                              single strip
##
## Strip TYPE is certain — 2912 bytes is a long strip and 1872 a short one, which
## is what GBACartEReaderScan itself branches on. Strip EDGE is not recorded
## anywhere: not in the dotcode (a card's per-block headers are byte-identical
## between its strips), not in mGBA (which renders both to the same address and
## queues them FIFO), and not reliably in a scan. EDGES below is therefore
## authored, and is the only place it is stated.
##
## Every e-Reader card is the same portrait trading card, so there is no card
## SHAPE to resolve -- only which of its edges are coded. See
## MediaDimensions.CARD_SIZE_EREADER for what was tried before that was settled.
class_name EReaderCards
extends RefCounted

## Raw dotcode sizes GBACartEReaderScan accepts. Anything else it drops silently,
## so a file is checked here rather than handed over to do nothing.
const ACCEPTED_SIZES: Array[int] = [1308, 1344, 1872, 2076, 2112, 2912, 3520, 5456]

const SIZE_LONG := 2912
const SIZE_SHORT := 1872

const KIND_LONG := "long"
const KIND_SHORT := "short"

const EDGE_SIDE := "side"
const EDGE_BOTTOM := "bottom"
const EDGE_TOP := "top"
## The card's second long edge. Only a two-long card puts a dotcode here, so for
## every other shape presenting it reads nothing — which is what a card offered
## the wrong way round should do.
const EDGE_SIDE_FAR := "side_far"

## Single long strip, on one of the two side edges.
const SHAPE_LONG := "long"
## Single short strip; a long+short card whose long strip was never dumped.
const SHAPE_SHORT := "short"
## Long on the side edge, short on the bottom — the Pokemon-e TCG layout.
const SHAPE_LONG_SHORT := "long_short"
## Two long strips, one on each side edge.
const SHAPE_TWO_LONG := "two_long"
## Wrong size, or a (Strip N) with no partner.
const SHAPE_BROKEN := "broken"

## Which edge each strip of a shape is printed on, in strip order.
##
## Every row says the same thing: a long strip goes on a long edge and a short
## strip on a short one, because a 2912-byte dotcode does not fit across 63 mm of
## card. That is a physical fact rather than a choice, and it is what
## ereader_tests checks this table against.
##
## An e-Reader card is a portrait trading card, so its long edges are the two
## SIDES and its short ones the top and bottom. There is no landscape card and
## no orientation to resolve; a card whose art was scanned on its side is a badly
## framed scan, not a differently shaped card.
##
## SHAPE_TWO_LONG is unconfirmed: the two coded edges may be the two long edges of
## one face, as here, or one edge per face. Only the 295 two-long cards depend on
## it and changing it is this one row.
const EDGES: Dictionary = {
	SHAPE_LONG: [EDGE_SIDE],
	SHAPE_SHORT: [EDGE_BOTTOM],
	SHAPE_LONG_SHORT: [EDGE_SIDE, EDGE_BOTTOM],
	SHAPE_TWO_LONG: [EDGE_SIDE, EDGE_SIDE_FAR],
}


const _TAG_LONG := " (Long Strip)"
const _TAG_SHORT := " (Short Strip)"
const _TAG_NUMBERED := " (Strip "


## True when a file of this size is one GBACartEReaderScan will decode.
static func is_scannable_size(size: int) -> bool:
	return size in ACCEPTED_SIZES


## Strip kind from its byte size, or "" when the size is not a strip at all.
static func kind_of_size(size: int) -> String:
	if size == SIZE_LONG:
		return KIND_LONG
	if size == SIZE_SHORT:
		return KIND_SHORT
	return ""


## Split a file stem into its card key and strip tag.
## Returns {base, tag, order}; tag is "" for a single-strip card.
static func split_suffix(stem: String) -> Dictionary:
	if stem.ends_with(_TAG_LONG):
		return {"base": stem.left(stem.length() - _TAG_LONG.length()),
			"tag": _TAG_LONG.strip_edges(), "order": 0}
	if stem.ends_with(_TAG_SHORT):
		return {"base": stem.left(stem.length() - _TAG_SHORT.length()),
			"tag": _TAG_SHORT.strip_edges(), "order": 1}
	if stem.ends_with(")"):
		var open := stem.rfind(_TAG_NUMBERED)
		if open >= 0:
			var digits := stem.substr(open + _TAG_NUMBERED.length(),
				stem.length() - open - _TAG_NUMBERED.length() - 1)
			if digits.is_valid_int():
				return {"base": stem.left(open),
					"tag": "(Strip %s)" % digits, "order": int(digits) - 1}
	return {"base": stem, "tag": "", "order": 0}


## Group scanned files into cards.
##
## `files` is [{path, size}] — the shape RomLibrary.scan_roms gives once each
## entry has been stat'd. Returns [{key, label, shape, portrait, strips}] sorted
## by label, where each strip is {path, size, kind, edge}.
static func group(files: Array[Dictionary]) -> Array[Dictionary]:
	var by_key: Dictionary = {}
	for f: Dictionary in files:
		var path := str(f.get("path", ""))
		if path.is_empty():
			continue
		var parts := split_suffix(path.get_file().get_basename())
		var key := str(parts["base"])
		if not by_key.has(key):
			by_key[key] = []
		var group_entries: Array = by_key[key]
		group_entries.append({
			"path": path,
			"size": int(f.get("size", 0)),
			"order": int(parts["order"]),
			"tag": str(parts["tag"]),
		})

	var out: Array[Dictionary] = []
	for key: String in by_key:
		out.append(_build_card(key, by_key[key]))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["label"]).naturalnocasecmp_to(str(b["label"])) < 0)
	return out


static func _build_card(key: String, entries: Array) -> Dictionary:
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["order"]) < int(b["order"]))

	var strips: Array[Dictionary] = []
	var usable := true
	for e: Dictionary in entries:
		var size := int(e["size"])
		var kind := kind_of_size(size)
		if not is_scannable_size(size) or kind.is_empty():
			usable = false
		strips.append({"path": str(e["path"]), "size": size, "kind": kind, "edge": ""})

	var shape := SHAPE_BROKEN
	if usable:
		shape = _shape_of(strips, entries)

	var edges: Array = EDGES.get(shape, [])
	for i in strips.size():
		if i < edges.size():
			strips[i]["edge"] = str(edges[i])

	return {
		"key": key,
		"label": key,
		"shape": shape,
		"strips": strips,
	}


static func _shape_of(strips: Array[Dictionary], entries: Array) -> String:
	var kinds: Array[String] = []
	for s: Dictionary in strips:
		kinds.append(str(s["kind"]))

	if kinds.size() == 1:
		# A lone numbered strip is half of a two-long card; its partner is missing.
		if str(entries[0]["tag"]).begins_with("(Strip "):
			return SHAPE_BROKEN
		return SHAPE_LONG if kinds[0] == KIND_LONG else SHAPE_SHORT
	if kinds.size() == 2:
		if kinds[0] == KIND_LONG and kinds[1] == KIND_SHORT:
			return SHAPE_LONG_SHORT
		if kinds[0] == KIND_LONG and kinds[1] == KIND_LONG:
			return SHAPE_TWO_LONG
	return SHAPE_BROKEN


## Index of the strip a swipe reads, or -1 when nothing should be read.
##
## `face_up` is whether the card's printed face is the one presented: a dotcode is
## printed on one side, so a card swiped face-down reads nothing.
static func strip_for(card: Dictionary, edge: String, face_up: bool) -> int:
	if not face_up:
		return -1
	if str(card.get("shape", SHAPE_BROKEN)) == SHAPE_BROKEN:
		return -1
	var strips: Array = card.get("strips", [])
	for i in strips.size():
		if str((strips[i] as Dictionary).get("edge", "")) == edge:
			return i
	return -1


## The systemid dotcode cards are filed under.
const SYSTEMID := "ereader"

# One grouping of the card folder, reused. Scanning 4000 files and regrouping
# them per spawned card is not free, and the folder does not change under us
# while the room is running.
static var _cache: Array[Dictionary] = []
static var _cache_dir: String = ""
## Strip path -> the card it belongs to, so a card object can find itself from
## the one path it carries and nothing extra has to be persisted.
static var _by_path: Dictionary = {}
## The worker scan in flight, if any: its task id, the directory it reads, the
## files it produced (written on the worker, read on the main thread) and who
## asked to hear when it lands.
static var _task_id: int = -1
static var _task_dir: String = ""
static var _task_files: Array[Dictionary] = []
static var _task_mutex := Mutex.new()
static var _task_listeners: Array[Callable] = []
## Files stat'd so far and files to stat, kept for the page to show progress.
static var _task_done: int = 0
static var _task_total: int = 0


## Whether `cards()` would answer from the cache rather than scan.
static func is_warm(dir: String = "") -> bool:
	var path := dir if not dir.is_empty() else RomLibrary.rom_dir_for_system(SYSTEMID)
	return path == _cache_dir and not _cache.is_empty()


## Every card in the library, grouped. Scans once per directory.
##
## Synchronous: on a full No-Intro set this opens 4000 files and takes seconds,
## so a caller that can wait should ask `warm_async` first and only come here
## once `is_warm()`. A scan already running for this directory is joined rather
## than repeated.
static func cards(dir: String = "") -> Array[Dictionary]:
	var path := dir if not dir.is_empty() else RomLibrary.rom_dir_for_system(SYSTEMID)
	if path == _cache_dir and not _cache.is_empty():
		return _cache
	if _task_id >= 0 and _task_dir == path:
		_finish_async()
		return _cache
	_store(path, _list_files(path))
	return _cache


## Scan on a worker thread, then call `on_done` on the main thread. Calls it
## straight away (deferred) when the cache is already warm, and shares one task
## between every caller that asks while it runs.
static func warm_async(dir: String = "", on_done: Callable = Callable()) -> void:
	var path := dir if not dir.is_empty() else RomLibrary.rom_dir_for_system(SYSTEMID)
	if path == _cache_dir and not _cache.is_empty():
		if on_done.is_valid():
			on_done.call_deferred()
		return
	if on_done.is_valid():
		_task_listeners.append(on_done)
	if _task_id >= 0:
		if _task_dir == path:
			return
		# A scan of some other directory is in flight; let it land first.
		_finish_async()
	_task_dir = path
	_task_id = WorkerThreadPool.add_task(_scan_task.bind(path), false, "EReaderCards scan")


static func _scan_task(path: String) -> void:
	var files := _list_files(path, true)
	_task_mutex.lock()
	_task_files = files
	_task_mutex.unlock()
	EReaderCards._finish_async.call_deferred()


## Adopt the worker scan, blocking until it is finished. Idempotent: the
## deferred call and a synchronous `cards()` that joined the task can both
## arrive, and only the first does anything.
static func _finish_async() -> void:
	if _task_id < 0:
		return
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_mutex.lock()
	var files := _task_files
	_task_files = []
	_task_mutex.unlock()
	var path := _task_dir
	_task_id = -1
	_task_dir = ""
	_task_done = 0
	_task_total = 0
	_store(path, files)
	var listeners := _task_listeners
	_task_listeners = []
	for cb: Callable in listeners:
		if cb.is_valid():
			cb.call()


## The directory's .raw files with their sizes. Pure file I/O, safe off-thread.
static func _list_files(path: String, report: bool = false) -> Array[Dictionary]:
	var names: PackedStringArray = []
	var d := DirAccess.open(path)
	if d != null:
		d.list_dir_begin()
		var name := d.get_next()
		while not name.is_empty():
			if not d.current_is_dir() and name.get_extension().to_lower() == "raw":
				names.append(name)
			name = d.get_next()
		d.list_dir_end()
	if report:
		_task_mutex.lock()
		_task_done = 0
		_task_total = names.size()
		_task_mutex.unlock()
	var files: Array[Dictionary] = []
	for i in names.size():
		var full := path.path_join(names[i])
		files.append({"path": full, "size": _size_of(full)})
		if report and (i & 31) == 31:
			_task_mutex.lock()
			_task_done = i + 1
			_task_mutex.unlock()
	return files


## Progress of the worker scan as (files done, files total); (0, 0) when none
## is running or it has not listed the folder yet.
static func scan_progress() -> Vector2i:
	if _task_id < 0:
		return Vector2i.ZERO
	_task_mutex.lock()
	var out := Vector2i(_task_done, _task_total)
	_task_mutex.unlock()
	return out


static func _store(path: String, files: Array[Dictionary]) -> void:
	_cache = group(files)
	_cache_dir = path
	_by_path = {}
	for c: Dictionary in _cache:
		for s: Dictionary in c["strips"]:
			_by_path[str(s["path"])] = c


## Forget the scan — call after the library folder is written to.
static func invalidate() -> void:
	if _task_id >= 0:
		_finish_async()
	_cache = []
	_cache_dir = ""
	_by_path = {}


## The card a strip file belongs to, or {} when it is not in the library.
static func card_for_path(path: String, dir: String = "") -> Dictionary:
	if path.is_empty():
		return {}
	cards(dir)
	var hit: Variant = _by_path.get(path)
	if hit != null:
		return hit as Dictionary
	# A path from a save may differ in separator or case from the scan's.
	var want := path.replace("\\", "/").to_lower()
	for key: String in _by_path:
		if key.replace("\\", "/").to_lower() == want:
			return _by_path[key] as Dictionary
	return {}


## One card by its key, or {} when the library no longer holds it.
static func card_by_key(key: String, dir: String = "") -> Dictionary:
	if key.is_empty():
		return {}
	for c: Dictionary in cards(dir):
		if str(c["key"]) == key:
			return c
	return {}


static func _size_of(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return int(n)


## The card's strips in one or three characters — "L", "S", "L+S", "L+L".
##
## What a player wants off a row is how many passes the card takes and whether
## the second one is the short edge, which the label cannot say and the shape
## name is too long to. A broken card summarises as nothing: it is not swipeable,
## and naming its strips would read as an offer.
static func strip_summary(card: Dictionary) -> String:
	if str(card.get("shape", SHAPE_BROKEN)) == SHAPE_BROKEN:
		return ""
	var out: Array[String] = []
	for s: Dictionary in card.get("strips", []):
		out.append("L" if str(s.get("kind", "")) == KIND_LONG else "S")
	return "+".join(out)


## Edges of this card that carry a dotcode.
static func coded_edges(card: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if str(card.get("shape", SHAPE_BROKEN)) == SHAPE_BROKEN:
		return out
	for s: Dictionary in card.get("strips", []):
		var edge := str(s.get("edge", ""))
		if not edge.is_empty() and edge not in out:
			out.append(edge)
	return out

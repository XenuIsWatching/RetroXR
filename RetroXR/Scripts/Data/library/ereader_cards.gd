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
## queues them FIFO), and not in No-Intro's card scans (cropped to the art).
## EDGES below is therefore authored, and is the only place it is stated.
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
## The card's fourth edge. No shape puts a strip here, so presenting it reads
## nothing — which is what a card offered the wrong way round should do.
const EDGE_SIDE_FAR := "side_far"

## Single long strip, landscape card.
const SHAPE_LONG := "long"
## Single short strip; a long+short card whose long strip was never dumped.
const SHAPE_SHORT := "short"
## Long on the side edge, short on the bottom — the Pokemon-e TCG layout.
const SHAPE_LONG_SHORT := "long_short"
## Two long strips, landscape card.
const SHAPE_TWO_LONG := "two_long"
## Wrong size, or a (Strip N) with no partner.
const SHAPE_BROKEN := "broken"

## Which edge each strip of a shape is printed on, in strip order.
##
## SHAPE_TWO_LONG is unconfirmed: the two coded edges may be the two long edges of
## one face, as here, or one edge per face. Only the 295 two-long cards depend on
## it and changing it is this one row.
const EDGES: Dictionary = {
	SHAPE_LONG: [EDGE_BOTTOM],
	SHAPE_SHORT: [EDGE_BOTTOM],
	SHAPE_LONG_SHORT: [EDGE_SIDE, EDGE_BOTTOM],
	SHAPE_TWO_LONG: [EDGE_BOTTOM, EDGE_TOP],
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
		"portrait": shape == SHAPE_LONG_SHORT or shape == SHAPE_SHORT,
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


## Every card in the library, grouped. Scans once per directory.
static func cards(dir: String = "") -> Array[Dictionary]:
	var path := dir if not dir.is_empty() else RomLibrary.rom_dir_for_system(SYSTEMID)
	if path == _cache_dir and not _cache.is_empty():
		return _cache
	var files: Array[Dictionary] = []
	var d := DirAccess.open(path)
	if d != null:
		d.list_dir_begin()
		var name := d.get_next()
		while not name.is_empty():
			if not d.current_is_dir() and name.get_extension().to_lower() == "raw":
				var full := path.path_join(name)
				files.append({"path": full, "size": _size_of(full)})
			name = d.get_next()
		d.list_dir_end()
	_cache = group(files)
	_cache_dir = path
	_by_path = {}
	for c: Dictionary in _cache:
		for s: Dictionary in c["strips"]:
			_by_path[str(s["path"])] = c
	return _cache


## Forget the scan — call after the library folder is written to.
static func invalidate() -> void:
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

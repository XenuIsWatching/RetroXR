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
## The card's fourth edge. Only a portrait two-strip card puts a dotcode here, so
## for everything else presenting it reads nothing — which is what a card offered
## the wrong way round should do.
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

## Which edge each strip of a shape is printed on, in strip order — by shape and
## then by ORIENTATION, since which edge is the long one is the whole question.
##
## Every row says the same thing: a long strip goes on a long edge and a short
## strip on a short one, because a 2912-byte dotcode does not fit on 54 mm of
## card. That is a physical fact rather than a choice, and it is the one thing
## ereader_tests checks this table against.
##
## SHAPE_TWO_LONG is unconfirmed: the two coded edges may be the two long edges of
## one face, as here, or one edge per face. Only the 295 two-long cards depend on
## it and changing it is these two rows.
const EDGES: Dictionary = {
	SHAPE_LONG: {false: [EDGE_BOTTOM], true: [EDGE_SIDE]},
	SHAPE_SHORT: {false: [EDGE_SIDE], true: [EDGE_BOTTOM]},
	SHAPE_LONG_SHORT: {false: [EDGE_BOTTOM, EDGE_SIDE], true: [EDGE_SIDE, EDGE_BOTTOM]},
	SHAPE_TWO_LONG: {false: [EDGE_BOTTOM, EDGE_TOP], true: [EDGE_SIDE, EDGE_SIDE_FAR]},
}


## The edges of one shape at one orientation, in strip order.
static func edges_for(shape: String, portrait: bool) -> Array:
	var by_orientation: Dictionary = EDGES.get(shape, {})
	return (by_orientation.get(portrait, []) as Array).duplicate()

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

	var portrait := _portrait_for(shape, strips)
	var edges := edges_for(shape, portrait)
	for i in strips.size():
		if i < edges.size():
			strips[i]["edge"] = str(edges[i])

	return {
		"key": key,
		"label": key,
		"shape": shape,
		"portrait": portrait,
		"strips": strips,
	}


## Is this card taller than it is wide?
##
## The card's own ART is the ground truth and is asked first: a scan of the card
## is the card's proportions, and the strip layout is not. Inferring it from the
## shape alone said every single-strip card was landscape, which is what stood an
## Animal Crossing-e card -- a portrait card with one long strip down its side --
## in a landscape body, with the art letterboxed into the middle of it and white
## card showing either side.
##
## The shape remains the answer for a card with no art, where it is the only
## evidence there is: the Pokemon-e TCG layout (a long strip and a short one) is
## a portrait trading card, and so is a card that is the short half of one.
static func _portrait_for(shape: String, strips: Array[Dictionary]) -> bool:
	for s: Dictionary in strips:
		var art := art_size_for_strip(str(s.get("path", "")))
		if art.x > 0 and art.y > 0:
			return art.y > art.x
	return shape == SHAPE_LONG_SHORT or shape == SHAPE_SHORT


## The pixel size of the label art scraped for one strip, or a zero vector.
##
## Same file convention MediaDimensions.load_label_texture reads, and derived
## from the strip's own folder rather than from RomLibrary, so a scan pointed at
## a directory finds the art beside it.
static func art_size_for_strip(strip_path: String) -> Vector2i:
	if strip_path.is_empty():
		return Vector2i.ZERO
	var base := strip_path.get_file().get_basename()
	if base.is_empty():
		return Vector2i.ZERO
	var dir := strip_path.get_base_dir().path_join("media").path_join("label")
	for ext: String in [".png", ".jpg", ".jpeg", ".webp"]:
		var path := dir.path_join(base + ext)
		if FileAccess.file_exists(path):
			var wh := _image_size(path)
			if wh.x > 0 and wh.y > 0:
				return wh
	return Vector2i.ZERO


## An image's pixel size read from its HEADER, without decoding it.
##
## Grouping asks this once per card over a library of 3217, and decoding four
## thousand photographic scans to learn which way up they are would put seconds
## on a scan that currently costs a stat each.
static func _image_size(path: String) -> Vector2i:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return Vector2i.ZERO
	var wh := Vector2i.ZERO
	var magic := f.get_buffer(4)
	if magic.size() == 4:
		if magic[0] == 0x89 and magic[1] == 0x50:
			# PNG: the IHDR width and height are two big-endian longs at 16.
			f.seek(16)
			wh = Vector2i(_be32(f), _be32(f))
		elif magic[0] == 0xFF and magic[1] == 0xD8:
			wh = _jpeg_size(f)
		elif magic.get_string_from_ascii() == "RIFF":
			wh = _webp_size(f)
	f.close()
	return wh


static func _be32(f: FileAccess) -> int:
	var b := f.get_buffer(4)
	if b.size() < 4:
		return 0
	return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]


## Walk the JPEG marker chain to the frame header, whose height and width are the
## two big-endian shorts after its one-byte sample precision.
##
## The size is not at a fixed offset in a JPEG: any number of application, quant
## and comment segments come first, and their count varies by encoder.
static func _jpeg_size(f: FileAccess) -> Vector2i:
	f.seek(2)
	var length := f.get_length()
	while f.get_position() + 4 <= length:
		if f.get_8() != 0xFF:
			continue
		var marker := f.get_8()
		while marker == 0xFF:
			marker = f.get_8()
		# SOF0..SOF15, less the four that are not frame headers.
		if marker >= 0xC0 and marker <= 0xCF \
				and marker != 0xC4 and marker != 0xC8 and marker != 0xCC:
			f.get_16()
			f.get_8()
			var h := ((f.get_8() << 8) | f.get_8())
			var w := ((f.get_8() << 8) | f.get_8())
			return Vector2i(w, h)
		if marker == 0xD8 or marker == 0xD9 or (marker >= 0xD0 and marker <= 0xD7):
			continue
		var seg := (f.get_8() << 8) | f.get_8()
		if seg < 2:
			break
		f.seek(f.get_position() + seg - 2)
	return Vector2i.ZERO


## WebP, in the three container forms: plain VP8, lossless VP8L, extended VP8X.
static func _webp_size(f: FileAccess) -> Vector2i:
	f.seek(8)
	if f.get_buffer(4).get_string_from_ascii() != "WEBP":
		return Vector2i.ZERO
	var fourcc := f.get_buffer(4).get_string_from_ascii()
	f.get_32()
	if fourcc == "VP8X":
		f.get_32()
		# Three-byte little-endian, and each is one less than the real size.
		var w := (f.get_8() | (f.get_8() << 8) | (f.get_8() << 16)) + 1
		var h := (f.get_8() | (f.get_8() << 8) | (f.get_8() << 16)) + 1
		return Vector2i(w, h)
	if fourcc == "VP8L":
		f.get_8()
		var bits := f.get_32()
		return Vector2i((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
	if fourcc == "VP8 ":
		f.seek(f.get_position() + 6)
		return Vector2i(f.get_16() & 0x3FFF, f.get_16() & 0x3FFF)
	return Vector2i.ZERO


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

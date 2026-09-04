## AdapterRoms — finds the dumps that are HARDWARE rather than games.
##
## An e-Reader's cartridge dump is an ordinary Game Boy Advance ROM. A player who
## has one has it in roms/game_boy_advance/, and asking them to install a second
## copy into the core's system directory under a name of our choosing was the room
## inventing a BIOS where the hardware has none.
##
## So the adapter units read their program out of the library, and the library
## stops offering these files as games. Both halves are this one scan.
##
## Recognition is ExpansionCatalog.adapter_for_rom, which reads the ROM's own
## header — the GBA game code at 0xAC for a reader, the SNES title for a Super
## Game Boy. A filename rule would disagree the moment somebody renamed a file.
##
## THE CACHE IS THE DESIGN. RomLibrary.scan_roms opens no files at all today —
## it is a directory listing, and it runs on the main thread every time a platform
## is opened, over libraries of ten thousand entries. A header read per file is
## affordable exactly once per directory and never inside a scan, so the result is
## memoised here the way EReaderCards memoises its card grouping.
class_name AdapterRoms
extends RefCounted

## Which extensions can be an adapter on which platform. A platform absent from
## here is never probed, so no other library pays for this at all.
##
## Keyed by the HOST systemid, since that is the shelf the dump sits on: an
## e-Reader dump is a Game Boy Advance ROM.
const CANDIDATES: Dictionary = {
	"game_boy_advance": ["gba"],
}

## systemid -> {"units": {unit_id: path}, "paths": {path: unit_id}}
static var _cache: Dictionary = {}


## Every adapter dump on one platform's shelf, scanned once.
static func scan(systemid: String) -> Dictionary:
	if _cache.has(systemid):
		return _cache[systemid]
	var found := {"units": {}, "paths": {}}
	var exts: Array = CANDIDATES.get(systemid, [])
	if not exts.is_empty():
		_probe_dir(RomLibrary.rom_dir_for_system(systemid), exts, found)
	_cache[systemid] = found
	return found


## Where this unit's own program is, or "" when no dump of it is on disk.
##
## The host's shelf first, then the unit's own media folder: a reader dump filed
## beside the cards it reads is a reasonable place to keep it, and that folder is
## grouped by EReaderCards, which only ever looks at .raw — so a .gba there is
## invisible rather than a broken card.
static func path_for(unit_id: String) -> String:
	if unit_id.is_empty():
		return ""
	var host := ExpansionCatalog.host_of(unit_id)
	var hit := str((scan(host)["units"] as Dictionary).get(unit_id, ""))
	if not hit.is_empty():
		return hit
	var media := ExpansionCatalog.media_of(unit_id)
	if media.is_empty() or media == host:
		return ""
	var beside := {"units": {}, "paths": {}}
	_probe_dir(RomLibrary.rom_dir_for_system(media),
		CANDIDATES.get(host, []) as Array, beside)
	return str((beside["units"] as Dictionary).get(unit_id, ""))


## Is this file a piece of hardware rather than a game? Reads the cache only.
static func is_adapter_rom(systemid: String, path: String) -> bool:
	if path.is_empty() or not CANDIDATES.has(systemid):
		return false
	return (scan(systemid)["paths"] as Dictionary).has(path)


## Forget the scan — call after the library folder is written to, exactly where
## EReaderCards.invalidate() is called.
static func invalidate() -> void:
	_cache = {}


## How many files this has opened since the last reset. The cache is a promise
## about cost rather than a convenience, so the tests hold it to that.
static var probe_count: int = 0


static func reset_probe_count() -> void:
	probe_count = 0


static func _probe_dir(dir_path: String, exts: Array, into: Dictionary) -> void:
	if exts.is_empty():
		return
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while not name.is_empty():
		if not d.current_is_dir() and not name.begins_with("."):
			if name.get_extension().to_lower() in exts:
				var full := dir_path.path_join(name)
				probe_count += 1
				var unit := ExpansionCatalog.adapter_for_rom(full)
				if not unit.is_empty():
					(into["paths"] as Dictionary)[full] = unit
					# First one wins: two copies of the same dump are one reader,
					# and which of them is opened is not a choice worth making.
					if not (into["units"] as Dictionary).has(unit):
						(into["units"] as Dictionary)[unit] = full
		name = d.get_next()
	d.list_dir_end()

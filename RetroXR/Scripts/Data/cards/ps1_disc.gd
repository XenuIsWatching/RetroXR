## PS1Disc — reads a PlayStation disc image's product code.
##
## A memory card save names its game only by serial (BASCUS-94163… is FF7), and
## nothing else maps that to a game: gamelist.json has no serial field, and RomM
## does not index one — searching a serial there returns nothing. The disc does,
## in its SYSTEM.CNF boot line:
##
##     BOOT = cdrom:\SCUS_941.63;1
##
## which sits in the volume's root directory a few tens of KB in, so a 2 MB read
## finds it in under a millisecond. That is what lets RetroXR say which game a
## save on a card belongs to without ever having watched that game write it.
class_name PS1Disc
extends RefCounted

## How much of the image to search. SYSTEM.CNF lives in the root directory near
## the start; 2 MB is far past it and still a single cheap read.
const SCAN_BYTES := 2 << 20

## rom_path -> serial ("" when the disc has none). A disc's serial never changes,
## so this is resolved once per path.
static var _cache: Dictionary = {}
## rom_path -> the track file it names, so a sweep that asks both which file a
## .cue points at and what its serial is opens the .cue once.
static var _track_cache: Dictionary = {}

## Compiled once: a library sweep calls these per disc.
static var _CUE_RE := RegEx.create_from_string('FILE[^"]*"([^"]+)"')
static var _BOOT_RE := RegEx.create_from_string(
	"cdrom[^A-Za-z0-9]*([A-Z]{4})_([0-9]{3})[.]([0-9]{2})")


## "SCUS-94163", or "" when the image has no boot line (a dev disc, a non-PS1
## file, or an unreadable path).
static func serial_of(rom_path: String) -> String:
	if rom_path.is_empty():
		return ""
	if _cache.has(rom_path):
		return str(_cache[rom_path])
	var serial := _read_serial(_data_track(rom_path))
	_cache[rom_path] = serial
	return serial


## A .cue names the track file that actually holds the data; the .bin is the one
## worth reading. Anything else is taken as the image itself.
##
## Public so a caller sweeping a folder can tell which raw images its .cue files
## already speak for, and read each disc once instead of twice.
static func data_track(rom_path: String) -> String:
	return _data_track(rom_path)


static func _data_track(rom_path: String) -> String:
	if rom_path.get_extension().to_lower() != "cue":
		return rom_path
	if _track_cache.has(rom_path):
		return str(_track_cache[rom_path])
	# Not cached: nothing was learned about the file's contents, and a path that
	# cannot be opened now may open later. Every outcome below reads the .cue
	# through, so each is settled for the session.
	var f := FileAccess.open(rom_path, FileAccess.READ)
	if f == null:
		return rom_path
	var text := f.get_as_text()
	f.close()
	var m := _CUE_RE.search(text)
	var track := rom_path if m == null \
		else rom_path.get_base_dir().path_join(m.get_string(1))
	_track_cache[rom_path] = track
	return track


static func _read_serial(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var head := f.get_buffer(SCAN_BYTES)
	f.close()

	# Searched as BYTES, not as a decoded string: a disc image is mostly zeros,
	# and reading it as text stops dead at the first NUL a few bytes in. Only the
	# short run around the match is decoded, and that part is plain ASCII.

	var needle := PackedByteArray([0x63, 0x64, 0x72, 0x6F, 0x6D])   # "cdrom"
	var i := head.find(needle[0])
	while i != -1 and i + 40 < head.size():
		var hit := true
		for j in range(1, needle.size()):
			if head[i + j] != needle[j]:
				hit = false
				break
		if hit:
			var m := _BOOT_RE.search(head.slice(i, i + 40).get_string_from_ascii())
			if m != null:
				return "%s-%s%s" % [m.get_string(1), m.get_string(2), m.get_string(3)]
		i = head.find(needle[0], i + 1)
	return ""

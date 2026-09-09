## PS2Disc — reads a PlayStation 2 disc image's product code.
##
## The same problem PS1Disc solves, and almost the same answer: a save on a
## memory card names its game only by serial, and the disc is the only thing
## that maps that back to a file. The PS2 writes the line differently:
##
##     BOOT2 = cdrom0:\SLUS_200.02;1
##
## `cdrom0` rather than `cdrom` is the whole of the difference, and it is enough
## that PS1Disc's pattern does not match it — its separator class rejects the
## digit. Hence a class of its own rather than a looser regex shared by both,
## which would have let a PlayStation disc answer for a PlayStation 2 one.
##
## Compressed images (.chd, .cso, .zso) are not read: the boot line is inside
## the compressed stream, and guessing from a filename would attribute a save to
## the wrong game. Those simply have no serial here.
class_name PS2Disc
extends RefCounted

## A PS2 disc is a DVD and its root directory sits further in than a PS1 CD's,
## so the window is wider. Still one read per image, and cached for the session.
const SCAN_BYTES := 8 << 20

static var _cache: Dictionary = {}

static var _BOOT_RE := RegEx.create_from_string(
	"cdrom0[^A-Za-z0-9]*([A-Z]{4})_([0-9]{3})[.]([0-9]{2})")


## "SLUS-20002", or "" when the image has no BOOT2 line.
static func serial_of(rom_path: String) -> String:
	if rom_path.is_empty():
		return ""
	if _cache.has(rom_path):
		return str(_cache[rom_path])
	var serial := _read_serial(data_track(rom_path))
	_cache[rom_path] = serial
	return serial


## A .cue names the track file holding the data. The indirection is a property
## of the cue sheet rather than of the console, so PS1Disc's reader serves both.
static func data_track(rom_path: String) -> String:
	return PS1Disc.data_track(rom_path)


static func _read_serial(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	if path.get_extension().to_lower() in ["chd", "cso", "zso", "gz"]:
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var head := f.get_buffer(SCAN_BYTES)
	f.close()

	# Searched as BYTES: a disc image is mostly zeros, and reading it as text
	# stops dead at the first NUL. Only the short run around a match is decoded,
	# and that part is plain ASCII.
	var needle := PackedByteArray([0x63, 0x64, 0x72, 0x6F, 0x6D, 0x30])   # "cdrom0"
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

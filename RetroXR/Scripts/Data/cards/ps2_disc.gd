## PS2Disc — reads a PlayStation 2 disc image's product code.
##
## The same problem PS1Disc solves, and a different answer. A save on a memory
## card names its game only by serial, and the disc is the only thing that maps
## that back to a file. The PS2 declares it in SYSTEM.CNF:
##
##     BOOT2 = cdrom0:\SLUS_200.02;1
##
## But that line is NOT reliably near the start of a disc — on Ace Combat 04 it
## is nowhere in the first 300 MB — while the ISO9660 directory that names the
## same executable is half a megabyte in. So this looks for the executable's own
## NAME by shape, `AAAA_999.99`, which appears in the directory and in the boot
## line alike. PS1Disc's `cdrom`-anchored scan is left alone: a PlayStation disc
## really does put its boot line near the front, and it has 58 real discs behind
## the way it reads them.
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

	# Matched by SHAPE, on the executable's own NAME — `SLUS_201.52` — rather
	# than by anchoring on the `cdrom0:\` of the BOOT2 line.
	#
	# Anchoring on the boot line looks like the obvious reading of the format and
	# does not survive a real disc: measured on Ace Combat 04, whose SYSTEM.CNF
	# contents sit nowhere in the first 300 MB while the ISO9660 directory names
	# the executable half a megabyte in. The name is what is reliably near the
	# start, and the boot line contains the same shape anyway, so one scan finds
	# either.
	#
	# Searched as BYTES: a disc image is mostly zeros, and reading it as text
	# stops dead at the first NUL.
	const UNDERSCORE := 0x5F
	var i := head.find(UNDERSCORE)
	while i != -1:
		if i >= 4 and i + 7 < head.size() and _is_serial_at(head, i):
			return "%s-%s%s" % [
				head.slice(i - 4, i).get_string_from_ascii(),
				head.slice(i + 1, i + 4).get_string_from_ascii(),
				head.slice(i + 5, i + 7).get_string_from_ascii()]
		i = head.find(UNDERSCORE, i + 1)
	return ""


## Is there a `AAAA_999.99` sitting on this underscore? Four capitals before it,
## then three digits, a dot and two more.
static func _is_serial_at(b: PackedByteArray, at: int) -> bool:
	for k in range(at - 4, at):
		if b[k] < 0x41 or b[k] > 0x5A:
			return false
	for k in [at + 1, at + 2, at + 3, at + 5, at + 6]:
		if b[k] < 0x30 or b[k] > 0x39:
			return false
	return b[at + 4] == 0x2E

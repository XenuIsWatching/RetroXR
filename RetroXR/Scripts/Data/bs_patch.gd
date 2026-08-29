class_name BsPatch
extends RefCounted

## BsPatch — run a Satellaview programme that needs patching, without altering it.
##
## Some broadcasts cannot start from a dump alone. BS F-Zero Grand Prix is the
## clearest case: it was a SoundLink title whose music and timing arrived over
## the satellite during a live event, and with no broadcast it never leaves its
## opening screen. Measured here, it hangs with the CPU executing its own ROM
## header as code -- 0xFFC8 reads back as the ASCII "O KNIGHT". Grand Prix 2,
## which was not a live event, runs untouched.
##
## The fix the Satellaview community uses is an IPS patch that re-enables the
## in-game music and lets START advance past that screen. Those patches are not
## ours to ship, so this looks for one the player has put beside the programme
## and applies it to a COPY:
##
##     roms/satellaview/BS F-Zero ... .bs      <- never written to
##     roms/satellaview/BS F-Zero ... .ips     <- the patch, dropped in by hand
##     user://bs_patched/<hash>.bs             <- what the core is handed
##
## The original is the identity, so the copy is keyed by a hash of both inputs:
## replace the patch and the next launch rebuilds, and a pack with no patch
## beside it is handed over untouched with no copy made at all.

## Where patched copies are cached. Deliberately NOT the roms folder: a second
## .bs there would be a second entry on the shelf, and snes9x resolves its
## broadcast directory from the loaded file's own folder.
const CACHE_DIR := "user://bs_patched"

## IPS is five bytes of "PATCH", then records, then "EOF".
const IPS_MAGIC := "PATCH"
const IPS_EOF := "EOF"


## The patch sitting beside `rom_path`, or "" when there is none.
static func patch_path_for(rom_path: String) -> String:
	if rom_path.is_empty():
		return ""
	var ips := rom_path.get_basename() + ".ips"
	return ips if FileAccess.file_exists(ips) else ""


## What the core should actually load for `rom_path`.
##
## Returns `rom_path` itself when no patch is present, so the ordinary case costs
## one file_exists and touches nothing.
static func resolved_path(rom_path: String) -> String:
	var patch := patch_path_for(rom_path)
	if patch.is_empty():
		return rom_path
	var cached := _cache_path(rom_path, patch)
	if FileAccess.file_exists(cached):
		return cached
	var rom := FileAccess.get_file_as_bytes(rom_path)
	var ips := FileAccess.get_file_as_bytes(patch)
	if rom.is_empty() or ips.is_empty():
		return rom_path
	var out := apply_ips(rom, ips)
	if out.is_empty():
		push_warning("[BsPatch] %s is not a usable IPS patch" % patch.get_file())
		return rom_path
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var f := FileAccess.open(cached, FileAccess.WRITE)
	if f == null:
		return rom_path
	f.store_buffer(out)
	f.close()
	return cached


## Keyed on both files: a patch that changes, or a programme that does, must not
## be served from a copy made for the previous pair.
static func _cache_path(rom_path: String, patch_path: String) -> String:
	var key := "%s|%d|%s|%d" % [
		rom_path.get_file(), _file_size(rom_path),
		patch_path.get_file(), _file_size(patch_path)]
	return CACHE_DIR.path_join(key.sha256_text().substr(0, 16) + ".bs")


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n


## Apply an IPS patch. Returns the patched image, or an empty array when `ips` is
## not an IPS file or runs past its own end.
##
## The format is unforgiving in one place worth naming: a record with size 0 is
## an RLE run, not an empty write, and reading it as the latter silently drops
## every run-length record in the patch.
static func apply_ips(rom: PackedByteArray, ips: PackedByteArray) -> PackedByteArray:
	if ips.size() < 8 or ips.slice(0, 5).get_string_from_ascii() != IPS_MAGIC:
		return PackedByteArray()
	var out := rom.duplicate()
	var i := 5
	while i + 3 <= ips.size():
		if ips.slice(i, i + 3).get_string_from_ascii() == IPS_EOF:
			return out
		var offset := (ips[i] << 16) | (ips[i + 1] << 8) | ips[i + 2]
		i += 3
		if i + 2 > ips.size():
			return PackedByteArray()
		var size := (ips[i] << 8) | ips[i + 1]
		i += 2
		if size == 0:
			# Run-length record: a repeat count and one byte.
			if i + 3 > ips.size():
				return PackedByteArray()
			var run := (ips[i] << 8) | ips[i + 1]
			var value := ips[i + 2]
			i += 3
			_grow(out, offset + run)
			for n in run:
				out[offset + n] = value
		else:
			if i + size > ips.size():
				return PackedByteArray()
			_grow(out, offset + size)
			for n in size:
				out[offset + n] = ips[i + n]
			i += size
	# Ran out of records without an EOF marker: a truncated patch, not a patch.
	return PackedByteArray()


## An IPS record may write past the end of the file it patches, which is how a
## patch legitimately extends a ROM.
static func _grow(data: PackedByteArray, needed: int) -> void:
	if data.size() < needed:
		data.resize(needed)

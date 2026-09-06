## bsx_pack_tests — is this file an 8M Memory Pack, and what does it say it is?
##
## A `.bs` file IS a pack image: snes9x loads one as content and points FlashROM
## straight at it, so the detection here decides whether a file the player drops
## in their broadcast folder is treated as a pack at all. Get it wrong in one
## direction and their pack looks like an ordinary ROM; wrong in the other and a
## Super Famicom cartridge is offered as something to slot into the BS-X shell.
##
## The accepted header values were MEASURED from real images (Actraiser,
## Arkanoid Doh It Again, BS Dragon Quest I), and the table is written out in
## bsx_pack.gd's own header. The cases below drive those same values, so the
## table and the code cannot drift apart quietly.
##
## Every image here is built in memory from blank_image(). No disk, no core, no
## ROM.
##
##   "$godot" --headless --path RetroXR res://Tests/bsx_pack_tests.tscn
extends Node

## Cases in this file, NOT counting the guard below -- it is checked before
## it has recorded itself.
##
## A case that never RAN is not a case that passed. GDScript has no
## try/catch, so one bad index aborts the function it is in and every case
## after it simply never prints, leaving a green run that checked less than
## it claims. card_tests records finding this the hard way; mutation-testing
## cores_data_tests found it again.
const EXPECTED_CASES := 44

var _passed := 0
var _failed := 0


func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		push_error("[bsx] TIMEOUT")
		get_tree().quit(1))

	_group_blank()
	_group_detect()
	_group_title()
	_group_patch()

	_eq(_passed + _failed, EXPECTED_CASES, "suite/every case ran")

	print("[bsx] %d checks, %d failed" % [_passed + _failed, _failed])
	print("[bsx] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if cond:
		_passed += 1
		print("[bsx] ok   %s" % what)
	else:
		_failed += 1
		print("[bsx] FAIL %s%s" % [what, "" if detail.is_empty() else "  -- " + detail])


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what, "got %s, want %s" % [got, want])


## A blank pack with one header byte changed.
func _with(offset: int, value: int) -> PackedByteArray:
	var d := BsxPack.blank_image()
	d[BsxPack.HEADER + offset] = value
	return d


# ── blank/ ────────────────────────────────────────────────────────────────────

## What RetroXR mints when the player asks for a new pack. This is the image the
## BS-X shell will be handed, so its shape is a contract with snes9x.
func _group_blank() -> void:
	var d := BsxPack.blank_image()
	_eq(d.size(), BsxPack.SIZE, "blank/a pack is 8 Mbit")
	_eq(BsxPack.SIZE / BsxPack.BLOCK_COUNT, BsxPack.BLOCK_SIZE,
		"blank/eight blocks make the whole pack")

	# An unwritten pack is erased flash, which is 0xFF everywhere the header does
	# not reach.
	_eq(d[BsxPack.SIZE - 1], BsxPack.ERASED, "blank/the tail is erased flash")
	_eq(d[0], BsxPack.ERASED, "blank/and so is everything before the header")

	_eq(d[BsxPack.HEADER + BsxPack.OFF_MAP], BsxPack.BLANK_MAP, "blank/map mode")
	_eq(d[BsxPack.HEADER + BsxPack.OFF_BANK], BsxPack.BLANK_BANK, "blank/bank")
	_eq(d[BsxPack.HEADER + BsxPack.OFF_FIXED], BsxPack.BLANK_FIXED, "blank/fixed byte")

	_ok(BsxPack.is_pack_image(d), "blank/a freshly minted pack is recognised as one")
	_eq(BsxPack.header_offset(d), BsxPack.HEADER, "blank/its header is the LoROM one")
	_eq(BsxPack.title_of(d), BsxPack.BLANK_TITLE, "blank/it is titled MEMORY PACK")
	_eq(BsxPack.free_blocks(d), BsxPack.BLOCK_COUNT,
		"blank/every block is free on a pack with nothing on it")


# ── detect/ ───────────────────────────────────────────────────────────────────

## The header test, against the measured table.
func _group_detect() -> void:
	_ok(not BsxPack.is_pack_image(PackedByteArray()), "detect/an empty file is not a pack")
	var short := PackedByteArray()
	short.resize(64)
	short.fill(0xFF)
	_ok(not BsxPack.is_pack_image(short), "detect/a file too short to hold a header is not")

	# Bank: only 20/21/30/31 are normal, and the three measured images use 20.
	for bank: int in [0x20, 0x21, 0x30, 0x31]:
		_ok(BsxPack.is_pack_image(_with(BsxPack.OFF_BANK, bank)),
			"detect/bank 0x%02X is a normal bank" % bank)
	for bank: int in [0x00, 0x22, 0x40, 0xFF]:
		_ok(not BsxPack.is_pack_image(_with(BsxPack.OFF_BANK, bank)),
			"detect/bank 0x%02X is refused" % bank)

	# Fixed byte: 0x33 or 0xFF and nothing else.
	_ok(BsxPack.is_pack_image(_with(BsxPack.OFF_FIXED, 0x33)), "detect/fixed 0x33 accepted")
	_ok(BsxPack.is_pack_image(_with(BsxPack.OFF_FIXED, 0xFF)), "detect/fixed 0xFF accepted")
	_ok(not BsxPack.is_pack_image(_with(BsxPack.OFF_FIXED, 0x00)), "detect/fixed 0x00 refused")

	# Map mode: 0, or (b & 131) == 128. Arkanoid measured 0xFC, Actraiser 0x80.
	_ok(BsxPack.is_pack_image(_with(BsxPack.OFF_MAP, 0x80)),
		"detect/map 0x80 accepted (Actraiser)")
	_ok(BsxPack.is_pack_image(_with(BsxPack.OFF_MAP, 0xFC)),
		"detect/map 0xFC accepted (Arkanoid)")
	_ok(BsxPack.is_pack_image(_with(BsxPack.OFF_MAP, 0x00)), "detect/map 0 accepted")
	_ok(not BsxPack.is_pack_image(_with(BsxPack.OFF_MAP, 0x01)), "detect/map 0x01 refused")

	# A HiROM pack carries its header 0x8000 higher instead.
	var hi := PackedByteArray()
	hi.resize(BsxPack.SIZE)
	hi.fill(BsxPack.ERASED)
	hi[BsxPack.HEADER_HI + BsxPack.OFF_MAP] = 0x80
	hi[BsxPack.HEADER_HI + BsxPack.OFF_BANK] = 0x20
	hi[BsxPack.HEADER_HI + BsxPack.OFF_FIXED] = 0x33
	hi[BsxPack.HEADER_HI + BsxPack.OFF_TYPE] = 0xFF
	hi[BsxPack.HEADER_HI + BsxPack.OFF_ROM_SIZE] = 0xFF
	# The LoROM slot must not also look like a header, or the search stops early.
	hi[BsxPack.HEADER + BsxPack.OFF_BANK] = 0x00
	_eq(BsxPack.header_offset(hi), BsxPack.HEADER_HI,
		"detect/a HiROM pack is found at the high header")


# ── title/ ────────────────────────────────────────────────────────────────────

## Display only, never identity — the filename is the identity, as it is for a
## memory card.
func _group_title() -> void:
	var d := BsxPack.blank_image()
	var ascii := "BS Cu-On-Pa".to_ascii_buffer()
	for i in BsxPack.TITLE_LEN:
		d[BsxPack.HEADER + i] = ascii[i] if i < ascii.size() else 0x20
	_eq(BsxPack.title_of(d), "BS Cu-On-Pa",
		"title/a plain ASCII title round-trips through the Shift-JIS decoder")

	# The padding the real images use, and the 0xFF of erased flash, must all
	# trim away rather than reach the decoder — handed those it answers rubbish.
	var padded := BsxPack.blank_image()
	var name := "PACK".to_ascii_buffer()
	for i in BsxPack.TITLE_LEN:
		padded[BsxPack.HEADER + i] = name[i] if i < name.size() else 0xFF
	_eq(BsxPack.title_of(padded), "PACK", "title/erased padding is trimmed")

	var nulled := BsxPack.blank_image()
	for i in BsxPack.TITLE_LEN:
		nulled[BsxPack.HEADER + i] = name[i] if i < name.size() else 0x00
	_eq(BsxPack.title_of(nulled), "PACK", "title/NUL padding is trimmed")

	# Not a pack, no title — rather than 16 bytes of whatever was there.
	var junk := PackedByteArray()
	junk.resize(BsxPack.SIZE)
	junk.fill(0x41)
	_eq(BsxPack.title_of(junk), "", "title/a file with no BS header has no title")


## ── patch/ ────────────────────────────────────────────────────────────────────
##
## BsPatch.apply_ips, the IPS reader behind a Satellaview programme that will not
## start from its dump alone (BS F-Zero Grand Prix is the measured case).
##
## The patches themselves are not ours to ship, so every fixture here is built
## byte by byte. That is the only way to reach the record shapes that matter: a
## real patch is mostly ordinary writes, and the shape most likely to be read
## wrongly -- a size-0 record, which is a run and NOT an empty write -- may not
## appear in the one patch someone happens to test against.
func _group_patch() -> void:
	var rom := PackedByteArray()
	rom.resize(16)
	rom.fill(0x00)

	# A plain record: 3-byte offset, 2-byte size, then the payload.
	_eq(Array(BsPatch.apply_ips(rom, _ips([_rec(2, [0xAA, 0xBB])]))).slice(0, 5),
		[0x00, 0x00, 0xAA, 0xBB, 0x00],
		"patch/a plain record writes its bytes at the offset")

	# The trap the header names: size 0 means a run, not nothing. Read as an
	# empty write it would silently drop every run-length record in the patch.
	_eq(Array(BsPatch.apply_ips(rom, _ips([_rle(1, 4, 0x7F)]))).slice(0, 6),
		[0x00, 0x7F, 0x7F, 0x7F, 0x7F, 0x00],
		"patch/a size-0 record is a run of one byte, not an empty write")

	# A patch may legitimately write past the end of the file it patches.
	var grown := BsPatch.apply_ips(rom, _ips([_rec(20, [0x11, 0x22])]))
	_eq(grown.size(), 22, "patch/a record past the end grows the rom")
	_eq(grown[20], 0x11, "patch/and lands its bytes there")

	_eq(BsPatch.apply_ips(rom, _ips([])), rom,
		"patch/a patch with no records leaves the rom alone")

	# Everything below must come back EMPTY: the caller falls back to the
	# unpatched rom on empty, so a misread patch must never look like a result.
	_ok(BsPatch.apply_ips(rom, "NOTIPS__".to_ascii_buffer()).is_empty(),
		"patch/a file that is not IPS is refused")
	_ok(BsPatch.apply_ips(rom, "PATCH".to_ascii_buffer()).is_empty(),
		"patch/a patch too short to hold a record is refused")

	# No EOF marker: the records ran out instead of ending. A truncated download
	# would otherwise apply whatever records did arrive and look successful.
	var no_eof := "PATCH".to_ascii_buffer()
	no_eof.append_array(_rec(2, [0xAA, 0xBB]))
	_ok(BsPatch.apply_ips(rom, no_eof).is_empty(),
		"patch/a patch with no EOF marker is refused")

	# Cut inside a record's own payload.
	var cut := "PATCH".to_ascii_buffer()
	cut.append_array(PackedByteArray([0x00, 0x00, 0x02, 0x00, 0x08, 0xAA]))
	_ok(BsPatch.apply_ips(rom, cut).is_empty(),
		"patch/a record claiming more payload than is there is refused")

	# The identity case the ordinary launch takes: no .ips beside the programme,
	# so the file itself is what the core loads and no copy is made.
	_eq(BsPatch.patch_path_for(""), "", "patch/no path, no patch")
	_eq(BsPatch.resolved_path("res://__bs_no_such_file.bs"),
		"res://__bs_no_such_file.bs",
		"patch/a programme with no patch beside it is handed over untouched")


## One IPS record: 3-byte big-endian offset, 2-byte big-endian size, payload.
func _rec(offset: int, payload: Array) -> PackedByteArray:
	var out := PackedByteArray([
		(offset >> 16) & 0xFF, (offset >> 8) & 0xFF, offset & 0xFF,
		(payload.size() >> 8) & 0xFF, payload.size() & 0xFF,
	])
	out.append_array(PackedByteArray(payload))
	return out


## A run-length record: size 0, then a 2-byte count and the byte to repeat.
func _rle(offset: int, run: int, value: int) -> PackedByteArray:
	return PackedByteArray([
		(offset >> 16) & 0xFF, (offset >> 8) & 0xFF, offset & 0xFF,
		0x00, 0x00,
		(run >> 8) & 0xFF, run & 0xFF, value,
	])


## "PATCH" + records + "EOF".
func _ips(records: Array) -> PackedByteArray:
	var out := "PATCH".to_ascii_buffer()
	for r: PackedByteArray in records:
		out.append_array(r)
	out.append_array("EOF".to_ascii_buffer())
	return out

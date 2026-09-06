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

var _passed := 0
var _failed := 0


func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		push_error("[bsx] TIMEOUT")
		get_tree().quit(1))

	_group_blank()
	_group_detect()
	_group_title()

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

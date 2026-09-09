## Memory card self-tests — both card formats against ONE shared contract, run
## headless with no core, no ROM, no headset and no card in a console.
##
##     "$godot" --headless --path RetroXR res://Tests/card_tests.tscn
##     "$godot" --headless --path RetroXR res://Tests/card_tests.tscn -- --only=gc
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## Two reasons this exists. The obvious one is that GCCard is new. The other is
## that PS1Card never had a test at all — it was measured against real cards and
## then trusted — so running both formats through the same contract holds the
## older one to what it has only ever satisfied by inspection.
##
## Nothing here loads a fixture off disk. A real GameCube save carries the game's
## own banner and icon artwork, which this repo has no right to redistribute, so
## the pictures are BUILT here and decoded back. That is a stronger check anyway:
## a fixture proves the decoder still does what it did, a round trip proves it
## does the right thing.
extends Node

## How many cases this file contains, NOT counting the guard below — it is
## checked before it has recorded itself.
const EXPECTED_CASES := 298

var _pass := 0
var _fail := 0
var _only := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--only="):
			_only = str(a).substr("--only=".length())

	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))

	_test_registry()
	_test_gc_blank()
	_test_gc_roundtrip()
	_test_gc_reject()
	_test_gc_chain()
	_test_gc_pictures()
	_test_ps1_contract()
	_test_n64_contract()
	_test_ps2_blank()
	_test_ps2_ecc()
	_test_ps2_geometry()
	_test_ps2_roundtrip()
	_test_ps2_delete()
	_test_ps2_reject()
	_test_ps2_fat()
	_test_shared_contract()
	_test_ops()
	_test_format_registry()
	_test_format_contract()
	_test_ps1_disc()

	# A case that never RAN is not a case that passed, and GDScript has no
	# try/catch: a decoder that indexes past its buffer aborts the function it is
	# in, and every case after it simply never prints. Mutation-testing this
	# suite is how that was found — a transposed icon tile dropped six cases and
	# still exited 0, which is the exact shape of a check that cannot fail.
	#
	# Bump this when adding cases; a mismatch means either that, or a case that
	# vanished, and both are worth stopping for.
	if _only.is_empty():
		_eq(_pass + _fail, EXPECTED_CASES, "suite/every case ran")

	print("[test] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _group(name: String) -> bool:
	return _only.is_empty() or name.begins_with(_only)


func _ok(cond: bool, test_name: String, detail := "") -> void:
	if not _group(test_name):
		return
	if cond:
		_pass += 1
		print("[test] PASS  %s" % test_name)
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [test_name, "  — " + detail if not detail.is_empty() else ""])


func _eq(got: Variant, want: Variant, test_name: String) -> void:
	_ok(got == want, test_name, "got %s, want %s" % [got, want])


# --- The registry -------------------------------------------------------------

func _test_registry() -> void:
	var ps1 := CardFormats.for_family("playstation")
	var gc := CardFormats.for_family("gamecube")
	_ok(ps1 != null, "registry/the PlayStation is registered")
	_ok(gc != null, "registry/so is the GameCube")
	_ok(CardFormats.for_family("dreamcast") == null, "registry/an unknown family is null")
	_ok(CardFormats.for_family("") == null, "registry/and so is an empty one")

	# The two extensions must differ, because for_path resolves a family from a
	# filename alone and could not otherwise tell the two folders apart.
	_ok(ps1.extension() != gc.extension(), "registry/the extensions are distinct")
	_ok(ps1.save_extension() != gc.save_extension(), "registry/and so are the save extensions")
	_eq(CardFormats.for_path("/x/y/MEMORY CARD.mcr").id(),
		"playstation", "registry/a path resolves by extension")
	_eq(CardFormats.for_path("/x/y/MEMORY CARD.raw").id(),
		"gamecube", "registry/for the GameCube too")
	_ok(CardFormats.for_path("/x/y/card.bin") == null, "registry/an unknown extension is null")

	# A console reaches its family through its own descriptor, and a Wii must
	# reach the GAMECUBE's — that is the whole reason a family is not a systemid.
	_eq(CardFormats.for_system("playstation").id(),
		"playstation", "registry/a PlayStation resolves its family")
	_ok(CardFormats.for_system("nes") == null, "registry/a cartridge console has none")


# --- The GameCube blank -------------------------------------------------------

func _test_gc_blank() -> void:
	var img := GCCard.blank_image()
	_eq(img.size(), 256 * GCCard.BLOCK_SIZE, "gc/blank/a 251 card is 2 MiB")
	_ok(GCCard.is_card_image(img), "gc/blank/it parses as a card")
	_eq(GCCard.free_blocks(img), 251, "gc/blank/with 251 blocks free")
	_eq(GCCard.total_blocks(img), 251, "gc/blank/and 251 in total")
	_eq(GCCard.list_saves(img, false).size(), 0, "gc/blank/holding nothing")

	# Every system block must pass its own checksum, which is the rule the
	# 0xFFFF-becomes-0 quirk exists to satisfy. Getting that wrong makes a card
	# Dolphin refuses, and the refusal looks like a corrupt card to the player.
	_ok(GCCard._checksums_ok(img, 0, GCCard.HDR_CSUM, GCCard.HDR_CSUM),
		"gc/blank/the header checksum is right")
	for b: int in [1, 2]:
		var o := b * GCCard.BLOCK_SIZE
		_ok(GCCard._checksums_ok(img, o, GCCard.DIR_CSUM, o + GCCard.DIR_CSUM),
			"gc/blank/directory copy %d checksums" % b)
	for b: int in [3, 4]:
		var o := b * GCCard.BLOCK_SIZE
		_ok(GCCard._checksums_ok(img, o + GCCard.BAT_UPDATE, GCCard.BLOCK_SIZE - GCCard.BAT_UPDATE, o + GCCard.BAT_CSUM),
			"gc/blank/BAT copy %d checksums" % b)

	# A 59-block card is just as ordinary as a 251, and its size has to come from
	# the image rather than from the family.
	var small := GCCard.blank_image(0x04)
	_ok(GCCard.is_card_image(small), "gc/blank/a 59-block card parses")
	_eq(GCCard.total_blocks(small), 59, "gc/blank/and reports its own size")

	# The blank is deterministic given a format time, so two runs of the suite
	# compare the same bytes.
	_ok(GCCard.blank_image(GCCard.MBIT_251, 12345) == GCCard.blank_image(GCCard.MBIT_251, 12345),
		"gc/blank/it is reproducible")


# --- Round trip ---------------------------------------------------------------

## A .gci with `blocks` blocks of recognisable filler, and a two-line comment.
func _make_gci(gamecode: String, maker: String, name: String, blocks: int,
		comment_one := "A Game", comment_two := "Save Data") -> PackedByteArray:
	var gci := PackedByteArray()
	gci.resize(GCCard.DENTRY_SIZE + blocks * GCCard.BLOCK_SIZE)
	gci.fill(0)
	for i in 4:
		gci[GCCard.E_GAMECODE + i] = gamecode.unicode_at(i)
	for i in 2:
		gci[GCCard.E_MAKERCODE + i] = maker.unicode_at(i)
	for i in name.length():
		gci[GCCard.E_FILENAME + i] = name.unicode_at(i)
	gci[GCCard.E_BANNER] = 0
	GCCard._put_be16(gci, GCCard.E_FIRSTBLK, GCCard.SYSTEM_BLOCKS)
	GCCard._put_be16(gci, GCCard.E_BLOCKS, blocks)
	# No pictures unless a case asks for them.
	for i in 4:
		gci[GCCard.E_IMAGE_OFF + i] = 0xFF
	GCCard._put_be16(gci, GCCard.E_ICON_FMT, 0)
	GCCard._put_be16(gci, GCCard.E_ANIM, 0)
	# Comments live INSIDE the save data, at an offset counted from its start.
	var addr := 0x40
	for i in 4:
		gci[GCCard.E_COMMENTS + i] = (addr >> (8 * (3 - i))) & 0xFF
	var base := GCCard.DENTRY_SIZE + addr
	for i in comment_one.length():
		gci[base + i] = comment_one.unicode_at(i)
	for i in comment_two.length():
		gci[base + 32 + i] = comment_two.unicode_at(i)
	# Filler that says which save and which block, so a mis-spliced card is
	# obvious rather than merely wrong.
	for b in blocks:
		for i in 16:
			gci[GCCard.DENTRY_SIZE + b * GCCard.BLOCK_SIZE + 0x100 + i] = \
				(name.unicode_at(0) + b + i) & 0xFF
	return gci


func _test_gc_roundtrip() -> void:
	var card := GCCard.blank_image()
	var a := _make_gci("GALE", "01", "melee_save", 3, "Super Smash Bros", "Melee data")
	_ok(GCCard.is_gci(a), "gc/round/the built save is a valid gci")

	var one := GCCard.insert_save(card, a)
	_ok(not one.is_empty(), "gc/round/it splices in")
	_ok(GCCard.is_card_image(one), "gc/round/and the card still parses")
	_eq(GCCard.free_blocks(one), 248, "gc/round/three blocks are taken")

	var saves := GCCard.list_saves(one, false)
	_eq(saves.size(), 1, "gc/round/one save is listed")
	_eq(str(saves[0]["name"]), "melee_save", "gc/round/under its filename")
	_eq(str(saves[0]["serial"]), "GALE01", "gc/round/with its serial")
	_eq(int(saves[0]["blocks"]), 3, "gc/round/and its block count")
	_eq(str(saves[0]["title"]), "Super Smash Bros — Melee data",
		"gc/round/its title is both comment lines")

	# The lifted file must be byte-identical to what went in. This is the check
	# that catches a first-block field carried through instead of normalised —
	# which would make a save's hash a fact about where it sat on the card.
	var back := GCCard.extract_save(one, int(saves[0]["block"]))
	_ok(back == a, "gc/round/what comes back out is what went in")

	# A second save of a different game, and the first still readable after it.
	var b := _make_gci("GZLE", "01", "zelda_save", 2)
	var two := GCCard.insert_save(one, b)
	_ok(not two.is_empty(), "gc/round/a second save splices in")
	_eq(GCCard.list_saves(two, false).size(), 2, "gc/round/both are listed")
	_eq(GCCard.free_blocks(two), 246, "gc/round/five blocks are taken")
	_ok(GCCard.extract_save(two, GCCard.block_of(two, "melee_save")) == a,
		"gc/round/the first still extracts unchanged")
	_ok(GCCard.extract_save(two, GCCard.block_of(two, "zelda_save")) == b,
		"gc/round/and so does the second")

	# Delete frees exactly what it took and leaves the neighbour alone. Losing
	# the OTHER save is the failure this whole design is arranged against.
	var gone := GCCard.delete_save(two, GCCard.block_of(two, "melee_save"))
	_ok(not gone.is_empty(), "gc/round/delete returns a card")
	_ok(GCCard.is_card_image(gone), "gc/round/which still parses")
	_eq(GCCard.list_saves(gone, false).size(), 1, "gc/round/one save is left")
	_eq(GCCard.free_blocks(gone), 249, "gc/round/its blocks came back")
	_ok(GCCard.extract_save(gone, GCCard.block_of(gone, "zelda_save")) == b,
		"gc/round/and the neighbour is untouched")
	_eq(GCCard.block_of(gone, "melee_save"), -1, "gc/round/the deleted one is gone")

	# The freed blocks are reusable, which is the point of freeing them.
	var again := GCCard.insert_save(gone, a)
	_ok(not again.is_empty(), "gc/round/the freed blocks take a save again")
	_eq(GCCard.free_blocks(again), 246, "gc/round/back to five taken")

	# Every mutation returns a NEW image; the caller's copy must be untouched, so
	# a verify-then-write gate has something unspoiled to fall back on.
	_eq(GCCard.free_blocks(card), 251, "gc/round/the original card was not mutated")


func _test_gc_reject() -> void:
	var card := GCCard.blank_image()
	var a := _make_gci("GALE", "01", "melee_save", 3)
	var one := GCCard.insert_save(card, a)

	_ok(GCCard.insert_save(one, a).is_empty(), "gc/reject/the same name twice is refused")
	_ok(not GCCard.is_gci(PS1Card.blank_image()), "gc/reject/a PlayStation save is not a gci")
	_ok(GCCard.insert_save(card, PS1Card.blank_image()).is_empty(),
		"gc/reject/and is refused by the card")
	_ok(not GCCard.is_gci(PackedByteArray()), "gc/reject/an empty file is not a gci")

	# A truncated save: the entry says three blocks, the file holds two.
	var short := a.slice(0, GCCard.DENTRY_SIZE + 2 * GCCard.BLOCK_SIZE)
	_ok(not GCCard.is_gci(short), "gc/reject/a truncated gci is refused")

	# A card that does not fit its own header, which is what a truncated image
	# looks like — taking its word for the size would walk off the buffer.
	var chopped := card.slice(0, card.size() - GCCard.BLOCK_SIZE)
	_ok(not GCCard.is_card_image(chopped), "gc/reject/a truncated card is not a card")
	_ok(not GCCard.is_card_image(PS1Card.blank_image()), "gc/reject/nor is a PlayStation card")
	_ok(GCCard.delete_save(card, 0).is_empty(), "gc/reject/deleting a free entry does nothing")
	_ok(GCCard.delete_save(one, 9999).is_empty(), "gc/reject/an out-of-range handle does nothing")

	# A save larger than the card. A 59-block card cannot hold 60 blocks, and the
	# refusal has to come before anything is written.
	var small := GCCard.blank_image(0x04)
	var big := _make_gci("GXXE", "01", "huge", 60)
	_ok(GCCard.insert_save(small, big).is_empty(),
		"gc/reject/a save too big for the card is refused")
	_eq(GCCard.free_blocks(small), 59, "gc/reject/and the card is untouched")


func _test_gc_chain() -> void:
	# Fill a small card, free a hole in the middle, and put a save in it that is
	# bigger than any single run left. It can only fit by CHAINING through the
	# BAT — which is what the format is for, and what an allocator that assumed
	# contiguous blocks would get wrong.
	var card := GCCard.blank_image(0x04)   # 59 blocks
	var names := ["one", "two", "three", "four"]
	for i in names.size():
		card = GCCard.insert_save(card, _make_gci("GA%dE" % i, "01", str(names[i]), 10))
	_eq(GCCard.list_saves(card, false).size(), 4, "gc/chain/four saves fit")
	_eq(GCCard.free_blocks(card), 19, "gc/chain/nineteen blocks left")

	# Free two non-adjacent tens, leaving 39 free in three separate runs.
	card = GCCard.delete_save(card, GCCard.block_of(card, "one"))
	card = GCCard.delete_save(card, GCCard.block_of(card, "three"))
	_eq(GCCard.free_blocks(card), 39, "gc/chain/thirty-nine free after two deletes")

	var wide := _make_gci("GBBE", "01", "wide", 25)
	var out := GCCard.insert_save(card, wide)
	_ok(not out.is_empty(), "gc/chain/a save spanning the gaps fits")
	_ok(GCCard.is_card_image(out), "gc/chain/and the card still parses")
	_eq(GCCard.free_blocks(out), 14, "gc/chain/fourteen left")

	var idx := GCCard.block_of(out, "wide")
	var chain := GCCard.save_chain(out,
		GCCard._be16(out, GCCard.dir_offset(out) + idx * GCCard.DENTRY_SIZE
			+ GCCard.E_FIRSTBLK))
	_eq(chain.size(), 25, "gc/chain/the chain is twenty-five blocks")
	_ok(chain[chain.size() - 1] - chain[0] != 24, "gc/chain/which is genuinely not contiguous")
	_ok(GCCard.extract_save(out, idx) == wide, "gc/chain/and it reads back byte for byte")

	# The neighbours it was threaded around must be intact.
	_ok(not GCCard.extract_save(out, GCCard.block_of(out, "two")).is_empty(),
		"gc/chain/a save it stepped over is unharmed")
	_ok(not GCCard.extract_save(out, GCCard.block_of(out, "four")).is_empty(),
		"gc/chain/and so is the other")


# --- Pictures -----------------------------------------------------------------

## Encode a CI8 tile stream plus its RGB5A3 palette, the way a save carries one.
##
## `tiles` holds one [r5, g5, b5] triple per 8x4 tile, in tile order. The palette
## is built from those 5-bit values DIRECTLY rather than by scaling a Color back
## down — going through a float and multiplying by 31 does not invert LUT5 (index
## 5 is 0x29, and 0x29/255*31 rounds to 4), which is a way to make this helper
## disagree with the decoder over something the decoder gets right.
##
## Written as the inverse of the decoder rather than sharing code with it, so one
## bug cannot hide the other.
func _encode_ci8(tiles: Array, w: int, h: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(w * h + 256 * 2)
	out.fill(0)
	var i := 0
	var tile := 0
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			for iy in 4:
				for ix in 8:
					out[i + ix] = tile
				i += 8
			x += 8
			tile += 1
		y += 4
	for p in tiles.size():
		var c: Array = tiles[p]
		var v: int = 0x8000 | (int(c[0]) << 10) | (int(c[1]) << 5) | int(c[2])
		out[w * h + p * 2] = (v >> 8) & 0xFF
		out[w * h + p * 2 + 1] = v & 0xFF
	return out


func _test_gc_pictures() -> void:
	# A 32x32 icon whose every 8x4 tile is a different colour, laid out in TILE
	# order. A transposed tile loop reorders them, so the decoded image differs —
	# which a flat or symmetric test image would not catch.
	var w := GCCard.ICON_W
	var h := GCCard.ICON_H
	var tiles: Array = []
	var src := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var tile := 0
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			var c := [(tile * 3) % 32, (tile * 7 + 5) % 32, (tile * 11 + 9) % 32]
			tiles.append(c)
			var col := Color(GCCard.LUT5[c[0]] / 255.0, GCCard.LUT5[c[1]] / 255.0,
				GCCard.LUT5[c[2]] / 255.0, 1.0)
			for iy in 4:
				for ix in 8:
					src.set_pixel(x + ix, y + iy, col)
			x += 8
			tile += 1
		y += 4

	var pixels := _encode_ci8(tiles, w, h)
	var gci := _make_gci("GPIC", "01", "picture", 2)
	# One CI8 frame with its OWN palette (format 3), lasting 12 VBlanks.
	gci[GCCard.E_BANNER] = 0
	var addr := 0x400
	for i in 4:
		gci[GCCard.E_IMAGE_OFF + i] = (addr >> (8 * (3 - i))) & 0xFF
	GCCard._put_be16(gci, GCCard.E_ICON_FMT, 3)
	GCCard._put_be16(gci, GCCard.E_ANIM, 3)
	for i in pixels.size():
		gci[GCCard.DENTRY_SIZE + addr + i] = pixels[i]

	var card := GCCard.insert_save(GCCard.blank_image(), gci)
	_ok(not card.is_empty(), "gc/pictures/the save with an icon splices in")
	var saves := GCCard.list_saves(card, true)
	_eq(saves.size(), 1, "gc/pictures/one save")
	var icons: Array = saves[0]["icons"]
	_eq(icons.size(), 1, "gc/pictures/one icon frame came back")
	if icons.size() != 1:
		return

	var got := icons[0] as Image
	_eq(got.get_width(), w, "gc/pictures/it is 32 wide")
	_eq(got.get_height(), h, "gc/pictures/and 32 tall")

	# Every pixel, not a sample: an 8x4 tiling read as 4x4 still produces a
	# picture, and only a full comparison tells the two apart.
	var same := true
	var first_bad := ""
	for py in h:
		for px in w:
			if got.get_pixel(px, py).to_rgba32() != src.get_pixel(px, py).to_rgba32():
				if same:
					first_bad = "at %d,%d got %s want %s" % [px, py,
						got.get_pixel(px, py), src.get_pixel(px, py)]
				same = false
	_ok(same, "gc/pictures/the decoded icon is the icon that went in", first_bad)

	# A frame DELAY of zero ends the list, not a format of zero. With the delay
	# bits cleared the icon must vanish entirely, however the format reads.
	var muted := gci.duplicate()
	GCCard._put_be16(muted, GCCard.E_ANIM, 0)
	var mcard := GCCard.insert_save(GCCard.blank_image(), muted)
	var msaves := GCCard.list_saves(mcard, true)
	_eq((msaves[0]["icons"] as Array).size(),
		0, "gc/pictures/a zero frame delay ends the icon")

	# A save that declares no image at all must decode to no pictures rather
	# than reading whatever bytes happen to sit at offset zero.
	var plain := GCCard.insert_save(GCCard.blank_image(),
		_make_gci("GNON", "01", "noicon", 1))
	var psaves := GCCard.list_saves(plain, true)
	_eq((psaves[0]["icons"] as Array).size(),
		0, "gc/pictures/a save with no image has no icons")
	_ok(psaves[0]["banner"] == null, "gc/pictures/and no banner")


# --- The PlayStation, held to the same contract -------------------------------

func _test_ps1_contract() -> void:
	var img := PS1Card.blank_image()
	_ok(PS1Card.is_card_image(img), "ps1/the blank parses")
	_eq(PS1Card.free_blocks(img), 15, "ps1/with fifteen blocks free")
	_eq(PS1Card.list_saves(img, false).size(), 0, "ps1/holding nothing")
	_ok(not PS1Card.is_card_image(GCCard.blank_image()),
		"ps1/a GameCube card is not a PlayStation card")
	_ok(not PS1Card.is_mcs(GCCard.blank_image()), "ps1/and a GameCube save is not an mcs")

	# Frame 63 is the write-test frame, a copy of the header. Every real card
	# carries it and pcsx_rearmed does not write it; a card without it is the odd
	# one out everywhere except inside that one core.
	_eq(img[63 * PS1Card.FRAME_SIZE], 0x4D, "ps1/frame 63 carries the header")
	_eq(img[64 * PS1Card.FRAME_SIZE - 1], 0x0E, "ps1/and its checksum")


# --- The Controller Pak -------------------------------------------------------

func _zero_serial() -> PackedByteArray:
	var serial := PackedByteArray()
	serial.resize(N64Card.SERIAL_SIZE)
	return serial


func _test_n64_contract() -> void:
	var img := N64Card.blank_image(_zero_serial())
	_ok(N64Card.is_card_image(img), "n64/the blank parses")
	_eq(N64Card.free_blocks(img), 123, "n64/with 123 pages free")
	_eq(N64Card.list_saves(img, false).size(), 0, "n64/holding nothing")
	_ok(not N64Card.is_card_image(PS1Card.blank_image()), "n64/a PlayStation card is not a pak")
	_ok(not N64Card.is_card_image(GCCard.blank_image()), "n64/a GameCube card is not a pak")

	# The pak carries its ID block four times because the N64 reads whichever
	# copy still checksums. Three of them agreeing with the first is what makes
	# a scuffed pak recoverable rather than blank.
	var first := img.slice(32, 32 + N64Card.NOTE_SIZE)
	var copies_agree := true
	for offset: int in N64Card.ID_BLOCK_OFFSETS:
		if img.slice(offset, offset + N64Card.NOTE_SIZE) != first:
			copies_agree = false
	_ok(copies_agree, "n64/the ID block is copied four times")

	var sum := (img[32 + 28] << 8) | img[32 + 29]
	var isum := (img[32 + 30] << 8) | img[32 + 31]
	# The literal, NOT N64Card.ID_SUM_BASE. Checking the code against the constant
	# the code used passes however wrong the constant is; 0xFFF2 is the number the
	# N64 actually wants, so that is the number written here.
	_eq((sum + isum) & 0xFFFF, 0xFFF2, "n64/its two checksums sum to 0xFFF2")

	var table := img.slice(N64Card.PAGE_SIZE, 2 * N64Card.PAGE_SIZE)
	var backup := img.slice(2 * N64Card.PAGE_SIZE, 3 * N64Card.PAGE_SIZE)
	_ok(table == backup, "n64/the index backup matches the table")

	var running := 0
	for i in range(N64Card.DATA_START_PAGE * 2, N64Card.PAGE_SIZE):
		running += table[i]
	_eq(table[1], running & 0xFF, "n64/the index checksum covers the usable pages")

	_ok(N64Card.blank_image(_zero_serial()) == img, "n64/a fixed serial formats identically")

	# A pak the player can fill, then empty again.
	var payload := PackedByteArray()
	payload.resize(N64Card.PAGE_SIZE * 2)
	for i in payload.size():
		payload[i] = i & 0xFF
	var note := N64Card.make_note("MARIO KART", "NKTE", payload)

	var filled := N64Card.insert_save(img, note)
	_ok(not filled.is_empty(), "n64/a note goes on")
	var saves := N64Card.list_saves(filled, false)
	_eq(saves[0].get("name") if saves.size() > 0 else "", "MARIO KART", "n64/and is listed by name")
	_eq(N64Card.free_blocks(filled), 121, "n64/costing its pages")
	_ok(N64Card.extract_save(filled, N64Card.DATA_START_PAGE) == note, "n64/lifts off byte-for-byte")
	_eq(N64Card.block_of(filled, "MARIO KART"), N64Card.DATA_START_PAGE, "n64/block_of finds it")
	_eq(N64Card.block_of(filled, "ZELDA"), -1, "n64/block_of misses what is absent")
	_ok(N64Card.insert_save(filled, note).is_empty(), "n64/the same name twice is refused")

	var huge := PackedByteArray()
	huge.resize(N64Card.PAGE_SIZE * 200)
	_ok(N64Card.insert_save(img, N64Card.make_note("BIG", "NBGE", huge)).is_empty(), "n64/a note larger than the pak is refused")

	var emptied := N64Card.delete_save(filled, N64Card.DATA_START_PAGE)
	_eq(N64Card.free_blocks(emptied), 123, "n64/deleting it frees the pages")
	_eq(N64Card.list_saves(emptied, false).size(), 0, "n64/and empties the list")

	_ok(not N64Card.is_note(img), "n64/a pak image is not a note")
	_ok(N64Card.is_note(note), "n64/but a lifted note is")

	# A pak whose chain eats itself must list nothing rather than spin. This is
	# the shape a half-written pak really takes, and the menu walks it.
	var looped := filled.duplicate()
	var entry := N64Card.PAGE_SIZE + N64Card.DATA_START_PAGE * 2
	looped[entry] = 0x00
	looped[entry + 1] = N64Card.DATA_START_PAGE
	_eq(N64Card.list_saves(looped, false).size(), 0, "n64/a looping chain lists nothing")

	# Lifting the four paks back out of a cartridge save. Every N64 played before
	# the paks were objects wrote into one of these, and they are the only copy.
	var srm := PackedByteArray()
	srm.resize(0x48800)
	for i in N64Card.CARD_SIZE:
		srm[N64Card.srm_offset(2) + i] = filled[i]
	for i in N64Card.CARD_SIZE:
		srm[N64Card.srm_offset(0) + i] = img[i]

	_eq(N64Card.srm_offset(2), 0x10800, "n64/port 3's pak begins at 0x10800")
	_ok(N64Card.slice_srm(srm, 2) == filled, "n64/and lifts out whole")
	_ok(N64Card.has_notes(N64Card.slice_srm(srm, 2)), "n64/carrying its note")
	# A formatted-but-untouched pak is NOT worth rescuing, and is not all zeroes
	# either — the core formats all four at every load whether a game touched them
	# or not, so "is it blank" is the wrong question to ask of one.
	_ok(not N64Card.has_notes(N64Card.slice_srm(srm, 0)), "n64/a formatted but unused pak is not worth keeping")
	_ok(not N64Card.has_notes(N64Card.slice_srm(srm, 1)), "n64/nor is a port that was never formatted at all")
	_ok(N64Card.slice_srm(PackedByteArray(), 0).is_empty(), "n64/a save file too short to hold a pak yields nothing")


# --- What every format must do ------------------------------------------------

func _test_shared_contract() -> void:
	for fmt: CardFormat in CardFormats.all():
		var n := fmt.id()
		_ok(not fmt.label().is_empty(), "shared/%s/has a label" % n)
		_ok(not fmt.extension().is_empty(), "shared/%s/has an extension" % n)
		_ok(not fmt.save_extension().is_empty(), "shared/%s/has a save extension" % n)
		_ok(not fmt.unit_noun().is_empty(), "shared/%s/has a unit noun" % n)
		# The heading over the save list. Deliberately NOT label(), which names the
		# console family: heading the panel "PlayStation" names the machine rather
		# than the object in your hand, and heading a Controller Pak "Memory Card"
		# is simply the wrong name for it.
		_ok(not fmt.device_noun().is_empty(), "shared/%s/has a device noun" % n)
		_ok(fmt.device_noun() != fmt.label(),
			"shared/%s/which is not the console's name" % n)
		_ok(fmt.icon_fps() > 0.0, "shared/%s/animates above zero" % n)

		var blank := fmt.blank_image()
		_ok(not blank.is_empty(), "shared/%s/blanks a card" % n)
		_ok(fmt.is_card_image(blank), "shared/%s/which parses" % n)
		_eq(fmt.list_saves(blank, false).size(), 0, "shared/%s/holding nothing" % n)
		_eq(fmt.free_blocks(blank),
			fmt.total_blocks(blank), "shared/%s/with everything free" % n)
		_ok(not fmt.is_card_image(PackedByteArray()), "shared/%s/an empty image is not a card" % n)
		_ok(not fmt.is_save_file(PackedByteArray()), "shared/%s/nor is an empty file a save" % n)
		_eq(fmt.block_of(blank, "nothing"),
			-1, "shared/%s/an absent save has no handle" % n)

		# total_blocks must answer for a card that does not exist yet, because
		# that is what a freshly spawned card's panel has to show.
		_ok(fmt.total_blocks(PackedByteArray()) > 0, "shared/%s/an absent card still has a size" % n)

		# A one-block save is one block, and the arithmetic is the format's.
		var one_block: int = fmt.blocks_for_size(
			blank.size() if n == "" else _smallest_save_size(fmt))
		_ok(one_block == 1, "shared/%s/a smallest save is one block" % n, "got %d" % one_block)


## The byte size of the smallest save this format can produce — one block plus
## whatever header its single-save file carries.
func _smallest_save_size(fmt: CardFormat) -> int:
	match fmt.id():
		"gamecube":       return GCCard.DENTRY_SIZE + GCCard.BLOCK_SIZE
		"playstation":    return PS1Card.FRAME_SIZE + PS1Card.BLOCK_SIZE
		"controller_pak": return N64Card.NOTE_SIZE + N64Card.PAGE_SIZE
		# The PS2 counts a container's bytes straight into clusters rather than
		# adding a header, so its smallest one-unit save is exactly one cluster.
		"playstation2":   return PS2Card.CLUSTER_SIZE
	return 0


# --- ops/ ---------------------------------------------------------------------
#
# CardSaveOps is the layer the two card panels drive: it decides what a row may
# do before the player presses anything, so every refusal here is a message
# rather than a failure discovered half way through writing the card.
#
# Only the pure half is exercised. holder_of, write_card, restore_save and the
# backup calls want a live scene tree, a RomM server or both, and belong with
# the probes.

func _test_ops() -> void:
	var gc := CardFormats.for_family("gamecube")

	# A RomM row names the game in "title", a card's own listing in "name", and
	# the panel shows one label for both.
	_eq(CardSaveOps.title_of({"title": "SOULCALIBUR", "name": "slot-1"}), "SOULCALIBUR",
		"ops/a title is preferred when the row carries one")
	_eq(CardSaveOps.title_of({"name": "slot-1"}), "slot-1",
		"ops/the slot name is the fallback label")
	_eq(CardSaveOps.title_of({"title": "", "name": "slot-1"}), "slot-1",
		"ops/an empty title falls back too")
	_eq(CardSaveOps.title_of({}), "", "ops/a row with neither has no label")

	# Size in bytes is the server's unit; blocks are the card's.
	_eq(CardSaveOps.blocks_of(gc, {"size": _smallest_save_size(gc)}),
		gc.blocks_for_size(_smallest_save_size(gc)),
		"ops/a size is converted to the card's own blocks")
	_eq(CardSaveOps.blocks_of(null, {"size": 999999}), 1,
		"ops/with no format a row still costs something rather than nothing")

	# present_slots reads the card image itself, so a blank card holds nothing.
	var blank := gc.blank_image()
	_eq(CardSaveOps.present_slots(gc, blank).size(), 0,
		"ops/a blank card has no slots present")
	_eq(CardSaveOps.present_slots(null, blank).size(), 0,
		"ops/with no format nothing is reported present")

	# The three answers restore_blocker gives, in the order it gives them.
	var row := {"slot": "GAFE01", "size": _smallest_save_size(gc)}
	_eq(CardSaveOps.restore_blocker(gc, row, {}, 59), "",
		"ops/a save that fits an empty card is not blocked")
	_eq(CardSaveOps.restore_blocker(gc, row, {"GAFE01": true}, 59), "already on this card",
		"ops/a save already on the card is refused by name")
	var tight := CardSaveOps.restore_blocker(gc, row, {}, 0)
	_ok(tight.contains("free"), "ops/a card with no room says how much it needs", tight)
	_ok(tight.contains(gc.unit_noun()),
		"ops/and says it in the card family's own word", tight)
	# Presence is checked BEFORE size: a save already there needs no room, and
	# "needs 1 block, 0 free" would be a confusing thing to say about it.
	_eq(CardSaveOps.restore_blocker(gc, row, {"GAFE01": true}, 0), "already on this card",
		"ops/presence is reported ahead of a size refusal")


## ── registry/ (additions) ──────────────────────────────────────
##
## _test_registry above already pins the pairwise invariants. These three are
## what it does not reach.
func _test_format_registry() -> void:
	if not _group("registry"):
		return

	# The pairwise checks above compare the two families we ship. This one holds
	# for a third, which is when a clash would actually happen and when nobody
	# would think to add a case.
	var ids: Array = []
	for fmt: CardFormat in CardFormats.all():
		ids.append(fmt.id())
	_eq(ids.size(), _unique(ids).size(), "registry/every family id is distinct")

	# The id must map to the right CONCRETE adapter, not merely to something that
	# answers the id. Nothing else asserts the wiring between a family string and
	# the class that implements it, so a _build() that registered one format under
	# the other's key would satisfy every case above.
	_ok(CardFormats.for_family("playstation") is PS1CardFormat,
		"registry/the playstation family is a PS1CardFormat")
	_ok(CardFormats.for_family("gamecube") is GCCardFormat,
		"registry/the gamecube family is a GCCardFormat")

	# for_path lowercases before matching, so a card named by a tool that shouts
	# still resolves. Nothing else covers the fold.
	_eq(CardFormats.for_path("/x/y/CARD.RAW").id(), "gamecube",
		"registry/the extension match is case-insensitive")

	# BsxPackFormat is deliberately absent, and this is that decision written
	# where a change would trip it. Membership would make SramPaths.card_save_path
	# file a pack under save/memcards/, but snes9x reads its broadcast packets out
	# of the loaded ROM's own folder — so a pack filed there boots perfectly and
	# receives nothing. bsx_pack_format.gd says so in its own header.
	_ok(CardFormats.for_family("bsx") == null,
		"registry/the Satellaview pack is deliberately NOT a registered family")


## ── contract/ ─────────────────────────────────────────────────────────────────
##
## The two adapters are thin forwards, so what is worth pinning is where they
## deliberately DIFFER -- the places a caller would get wrong by assuming both
## machines behave like the one it was written against.
func _test_format_contract() -> void:
	if not _group("contract"):
		return

	var ps: CardFormat = CardFormats.for_family("playstation")
	var gc: CardFormat = CardFormats.for_family("gamecube")

	# A PlayStation card is always one 128 KB image of 16 blocks with block 0 the
	# directory, so the argument is ignored. A GameCube card's size is a property
	# of the card, and a 59 and a 251 are both ordinary.
	_eq(ps.total_blocks(PackedByteArray()), PS1Card.BLOCK_COUNT - 1,
		"contract/a PlayStation card is fixed at 15 blocks whatever it is handed")
	_eq(ps.total_blocks(ps.blank_image()), PS1Card.BLOCK_COUNT - 1,
		"contract/including its own blank")
	_eq(gc.total_blocks(gc.blank_image()), GCCard.total_blocks(gc.blank_image()),
		"contract/a GameCube card reads its block count from the image")

	# A save smaller than one block still occupies one.
	_eq(ps.blocks_for_size(0), 1, "contract/a PlayStation save never costs 0 blocks")
	_eq(gc.blocks_for_size(0), 1, "contract/nor does a GameCube save")
	_eq(ps.blocks_for_size(PS1Card.FRAME_SIZE + PS1Card.BLOCK_SIZE * 3), 3,
		"contract/a three-block PlayStation save costs three")

	# Each blank is its own format's card and not the other's. This is the pair
	# that catches a blank_image() wired to the wrong helper.
	_ok(ps.is_card_image(ps.blank_image()), "contract/a blank PlayStation card is one")
	_ok(gc.is_card_image(gc.blank_image()), "contract/a blank GameCube card is one")
	_ok(not ps.is_card_image(gc.blank_image()),
		"contract/a GameCube image is not a PlayStation card")
	_ok(not gc.is_card_image(ps.blank_image()),
		"contract/and not the other way round either")

	# Icon rate is a real per-machine number, not a shared default: the
	# PlayStation cycled at 6 Hz, a GameCube frame lasts four VBlanks (15 Hz).
	_eq(ps.icon_fps(), 6.0, "contract/the PlayStation cycles icons at 6 Hz")
	_eq(gc.icon_fps(), 15.0, "contract/the GameCube's fallback is 15 Hz")

	# An empty card has every block free, and the noun the panel prints.
	_eq(ps.free_blocks(ps.blank_image()), ps.total_blocks(ps.blank_image()),
		"contract/a blank PlayStation card is entirely free")
	_eq(gc.free_blocks(gc.blank_image()), gc.total_blocks(gc.blank_image()),
		"contract/and so is a blank GameCube card")
	_eq(ps.unit_noun(), "block", "contract/both machines count in blocks")
	_eq(gc.unit_noun(), "block", "contract/on the GameCube too")


func _unique(items: Array) -> Array:
	var seen: Array = []
	for it: Variant in items:
		if not seen.has(it):
			seen.append(it)
	return seen


## ── disc/ ───────────────────────────────────────────────────────────────
##
## PS1Disc is what lets a memory card save name its game. A save carries only a
## serial (BASCUS-94163 is FF7) and nothing else maps that to a title: gamelist
## has no serial field and RomM does not index one. The disc does, in its
## SYSTEM.CNF boot line.
##
## Every fixture is built here rather than shipped: a real image is a copyrighted
## disc, and the bytes that matter are a few dozen.
func _test_ps1_disc() -> void:
	if not _group("disc"):
		return

	var dir := OS.get_user_data_dir().path_join("__ps1disc_selftest")
	DirAccess.make_dir_recursive_absolute(dir)

	# A real boot line, backslash and all. The image around it is NUL, which is
	# the whole reason _read_serial searches BYTES: a disc is mostly zeros, and
	# reading it as text stops dead at the first NUL a few bytes in. A fixture
	# without that padding would pass against a text scan too, and prove nothing.
	var boot := ("BOOT = cdrom:" + char(92) + "SCUS_941.63;1").to_ascii_buffer()
	var img := PackedByteArray()
	img.resize(4096)
	for k in boot.size():
		img[2048 + k] = boot[k]
	var bin_path: String = dir.path_join("game.bin")
	var f := FileAccess.open(bin_path, FileAccess.WRITE)
	f.store_buffer(img)
	f.close()

	_eq(PS1Disc.serial_of(bin_path), "SCUS-94163",
		"disc/a boot line buried in NULs still yields its serial")

	# A .cue names the track that actually holds the data. Reading the .cue
	# itself would find no boot line at all.
	var cue_path: String = dir.path_join("game.cue")
	var c := FileAccess.open(cue_path, FileAccess.WRITE)
	c.store_string('FILE "game.bin" BINARY' + char(10) + "  TRACK 01 MODE2/2352" + char(10))
	c.close()
	_eq(PS1Disc.data_track(cue_path), bin_path,
		"disc/a cue resolves to the track file it names")
	_eq(PS1Disc.serial_of(cue_path), "SCUS-94163",
		"disc/and the serial is read through it")

	# Anything that is not a cue is the image itself; the path is returned even
	# when nothing is there, since a path that will not open now may open later.
	_eq(PS1Disc.data_track(bin_path), bin_path,
		"disc/a raw image is its own data track")
	_eq(PS1Disc.data_track(dir.path_join("missing.cue")), dir.path_join("missing.cue"),
		"disc/an unreadable cue falls back to itself")

	# No boot line, and no path: both answer "" rather than guessing.
	var blank := PackedByteArray()
	blank.resize(4096)
	var b_path: String = dir.path_join("blank.bin")
	var b := FileAccess.open(b_path, FileAccess.WRITE)
	b.store_buffer(blank)
	b.close()
	_eq(PS1Disc.serial_of(b_path), "", "disc/an image with no boot line has no serial")
	_eq(PS1Disc.serial_of(""), "", "disc/no path, no serial")
	_eq(PS1Disc.serial_of(dir.path_join("nope.bin")), "",
		"disc/a file that is not there has no serial")

	for leaf in ["game.bin", "game.cue", "blank.bin"]:
		DirAccess.remove_absolute(dir.path_join(leaf))
	DirAccess.remove_absolute(dir)


# --- ps2/ ---------------------------------------------------------------------
#
# The PlayStation 2's card is the only real FILESYSTEM here — a superblock, a
# doubly-indirect FAT and 512-byte directory entries two to a cluster — so the
# cases below are mostly about the parts of that a specification gets wrong.
#
# Nothing loads a fixture. The .psu and the .icn are BUILT as the inverse of the
# parsers and read back, which proves the decoders do the right thing rather
# than that they still do what they did.
#
# The four bytes this suite CANNOT judge are magic, version, card_type and
# card_flags: PCSX2 never writes a superblock, so those come from the vendored
# specification and only a console's own BIOS can confirm them. The cases here
# check that blank_image() writes what it meant to, not that what it meant to
# write is what Sony wrote.

func _test_ps2_blank() -> void:
	var img := PS2Card.blank_image()
	_eq(img.size(), 8650752, "ps2/blank/an 8 MB card is 8,650,752 bytes with ECC")
	_ok(PS2Card.is_card_image(img), "ps2/blank/it parses as a card")
	_eq(PS2Card.list_saves(img, false).size(), 0, "ps2/blank/holding nothing")
	# One cluster short of the usable count: the root directory occupies one and
	# a save can never have it, which is why total_blocks excludes it too.
	_eq(PS2Card.free_blocks(img), PS2Card.USABLE_CLUSTERS - 1,
		"ps2/blank/with everything but the root directory free")
	_eq(PS2Card.total_blocks(img), PS2Card.free_blocks(img),
		"ps2/blank/so a fresh card reads as wholly empty")

	# The truncated figure, not the 8135 the superblock allows. Both the console
	# and PCSX2 report this, and a card offering the extra 136 clusters would
	# disagree with every number the player is shown.
	_eq(PS2Card.USABLE_CLUSTERS, 7999, "ps2/blank/free space is the BIOS figure")

	# The derived geometry. PCSX2 computes each of these rather than storing
	# them, so they are arithmetic and can be checked as such.
	_eq(PS2Card.ALLOC_OFFSET, 41, "ps2/blank/the first allocatable cluster is 41")
	_eq(PS2Card.ALLOC_END, 8135, "ps2/blank/8135 allocatable clusters")
	_eq(PS2Card.BACKUP_BLOCK1, 1023, "ps2/blank/backup block 1 is the last")
	_eq(PS2Card.BACKUP_BLOCK2, 1022, "ps2/blank/backup block 2 the one before")

	# The superblock as written, read straight back out of page 0.
	var sb := img.slice(0, PS2Card.PAGE_SIZE)
	_eq(sb.slice(0, 28).get_string_from_ascii(), "Sony PS2 Memory Card Format ",
		"ps2/blank/the magic carries its trailing space")
	_eq(sb[PS2Card.SB_CARD_TYPE], 2, "ps2/blank/card_type says PS2")
	_eq(sb.decode_u16(PS2Card.SB_PAGE_LEN), 512, "ps2/blank/a page is 512 bytes of data")
	_eq(sb.decode_u16(PS2Card.SB_PAGES_PER_CLUS), 2, "ps2/blank/two pages to a cluster")
	_eq(sb.decode_u32(PS2Card.SB_CLUSTERS), 8192, "ps2/blank/8192 clusters on the card")
	_eq(sb.decode_u32(PS2Card.SB_ROOTDIR), 0, "ps2/blank/the root is at relative cluster 0")
	_eq(sb.decode_u32(PS2Card.SB_IFC_LIST), 8,
		"ps2/blank/the one indirect FAT cluster is 8")

	# Everything below was MEASURED off a real PCSX2 card backup rather than
	# taken from the specification, which gets the first of them wrong.
	#
	# card_flags 0x2B is CF_USE_ECC | CF_BAD_BLOCK and two undocumented bits. The
	# spec calls 0x52 the default — a value with CF_USE_ECC CLEAR, on a card
	# whose every page carries ECC.
	_eq(sb[PS2Card.SB_CARD_FLAGS], 0x2B, "ps2/blank/card_flags as a real card writes them")
	_eq(sb.slice(PS2Card.SB_VERSION, PS2Card.SB_VERSION + 12),
		"1.2.0.0".to_ascii_buffer() + PackedByteArray([0, 0, 0, 0, 0]),
		"ps2/blank/the version is 1.2.0.0, NUL-padded to twelve")
	# The two 32-entry lists sit side by side and are filled DIFFERENTLY: an
	# unused indirect-FAT slot is zero, an unused bad-block slot is 0xFFFFFFFF.
	_eq(sb.decode_u32(PS2Card.SB_IFC_LIST + 4), 0,
		"ps2/blank/an unused indirect-FAT slot is zero")
	_eq(sb.decode_u32(PS2Card.SB_BAD_BLOCKS), 0xFFFFFFFF,
		"ps2/blank/but an unused bad-block slot is all ones")
	_eq(sb.decode_u16(0x2E), 0xFF00, "ps2/blank/the unused half at 0x2e")
	_eq(sb.decode_u32(0x48), 0, "ps2/blank/and the padding word at 0x48 is zero")
	var tail_clean := true
	for i in range(0x152, PS2Card.PAGE_SIZE):
		if sb[i] != 0:
			tail_clean = false
			break
	_ok(tail_clean, "ps2/blank/the rest of the superblock page is zeroed, not erased")
	# The four bytes after the twelve of ECC are zero, not 0xFF.
	_eq(img.slice(PS2Card.PAGE_SIZE + 12, PS2Card.PAGE_RAW),
		PackedByteArray([0, 0, 0, 0]), "ps2/blank/a page's spare area ends in nulls")

	# The root's ".." is the one entry on the card whose mode differs from every
	# other: it drops MODE_READ and carries 0x2000. A reading of the spec alone
	# gets this wrong, and it is invisible until a console reads the card.
	var root_off := (PS2Card.ALLOC_OFFSET * PS2Card.PAGES_PER_CLUSTER) * PS2Card.PAGE_RAW
	var dot := img.slice(root_off, root_off + PS2Card.ENTRY_SIZE)
	var dotdot_off := root_off + PS2Card.PAGE_RAW
	var dotdot := img.slice(dotdot_off, dotdot_off + PS2Card.ENTRY_SIZE)
	_eq(dot.decode_u32(PS2Card.E_MODE), 0x8427,
		"ps2/blank/the root's dot is an ordinary directory")
	_eq(dot.decode_u32(PS2Card.E_LENGTH), 2, "ps2/blank/holding two slots")
	_eq(dotdot.decode_u32(PS2Card.E_MODE), 0xA426,
		"ps2/blank/the root's dotdot is the odd one")


func _test_ps2_ecc() -> void:
	# The spare area is derived, so a page of known bytes has a known answer and
	# a transposed table or a truncated loop shows up here rather than as a card
	# a console quietly refuses.
	var zeros := PackedByteArray()
	zeros.resize(0x80)
	zeros.fill(0)
	var e0 := PS2Card.calculate_ecc(zeros, 0)
	_eq(e0.size(), 3, "ps2/ecc/three bytes per 128-byte chunk")
	_eq("%02x%02x%02x" % [e0[0], e0[1], e0[2]], "777f7f",
		"ps2/ecc/an all-zero chunk is the identity")

	# An all-0xFF chunk has the SAME code as an all-zero one, because the table
	# maps both 0x00 and 0xFF to zero. That is the algorithm, not a bug, and
	# worth pinning so it is not "fixed" later.
	var ones := PackedByteArray()
	ones.resize(0x80)
	ones.fill(0xFF)
	_ok(PS2Card.calculate_ecc(ones, 0) == e0,
		"ps2/ecc/an erased chunk codes the same as a zeroed one")

	# A known vector rather than "it differs": one 0x01 in an otherwise empty
	# chunk has exactly one answer, so a table read at the wrong offset or a
	# mask applied to the wrong byte cannot pass this.
	var single := PackedByteArray()
	single.resize(0x80)
	single.fill(0)
	single[0] = 0x01
	var e2 := PS2Card.calculate_ecc(single, 0)
	_eq("%02x%02x%02x" % [e2[0], e2[1], e2[2]], "70007f",
		"ps2/ecc/a single set byte has one known code")

	# Flipping ONE bit must change the code, or the ECC is not protecting the
	# page at all — which is what a green "it computed something" would hide.
	var one_bit := zeros.duplicate()
	one_bit[7] = 0x01
	_ok(PS2Card.calculate_ecc(one_bit, 0) != e0, "ps2/ecc/one flipped bit changes it")

	# Every page the formatter writes must carry the code its own data implies.
	var img := PS2Card.blank_image()
	var bad := 0
	for page in [0, PS2Card.IFC_CLUSTER * 2, PS2Card.FIRST_FAT_CLUSTER * 2,
			PS2Card.ALLOC_OFFSET * 2]:
		var off: int = int(page) * PS2Card.PAGE_RAW
		for j in 4:
			var want := PS2Card.calculate_ecc(img, off + j * 0x80)
			for k in 3:
				if img[off + PS2Card.PAGE_SIZE + j * 3 + k] != want[k]:
					bad += 1
	_eq(bad, 0, "ps2/ecc/every written page's spare area matches its data")


func _test_ps2_geometry() -> void:
	# One reader serves an ECC image and a no-ECC one, and the stride is measured
	# rather than assumed — get this wrong and every offset past page 0 is off.
	var ecc := PackedByteArray()
	ecc.resize(PS2Card.CARD_SIZE)
	_eq(PS2Card.spare_size(ecc), 16, "ps2/geometry/a .ps2 has a 16-byte spare area")
	var no_ecc := PackedByteArray()
	no_ecc.resize(PS2Card.CARD_SIZE_NO_ECC)
	_eq(PS2Card.spare_size(no_ecc), 0, "ps2/geometry/a no-ECC image has none")
	_eq(PS2Card.spare_size(PackedByteArray()), -1, "ps2/geometry/an empty file is neither")
	var junk := PackedByteArray()
	junk.resize(1024)
	_eq(PS2Card.spare_size(junk), -1, "ps2/geometry/nor is something far too small")


## A .psu built by hand: the directory header, "." and "..", then one header and
## its padded payload per file. The inverse of PS2Card.parse_psu.
func _ps2_psu(dir_name: String, files: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.append_array(_ps2_psu_entry(0x8427, files.size() + 2, dir_name))
	out.append_array(_ps2_psu_entry(0x8427, 0, "."))
	out.append_array(_ps2_psu_entry(0x8427, 0, ".."))
	for f: Dictionary in files:
		var body: PackedByteArray = f["data"]
		out.append_array(_ps2_psu_entry(0x8497, body.size(), str(f["name"])))
		out.append_array(body)
		var pad := (1024 - (body.size() % 1024)) % 1024
		if pad > 0:
			var filler := PackedByteArray()
			filler.resize(pad)
			filler.fill(0)
			out.append_array(filler)
	return out


func _ps2_psu_entry(flags: int, size: int, entry_name: String) -> PackedByteArray:
	var e := PackedByteArray()
	e.resize(512)
	e.fill(0)
	e.encode_u32(0x00, flags)
	e.encode_u32(0x04, size)
	var raw := entry_name.to_ascii_buffer()
	for i in raw.size():
		e[0x40 + i] = raw[i]
	return e


func _ps2_body(byte: int, size: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(size)
	b.fill(byte)
	return b


func _test_ps2_roundtrip() -> void:
	var blank := PS2Card.blank_image()
	var psu := _ps2_psu("BASLUS-20488SAVE", [
		{"name": "icon.sys", "data": _ps2_body(0x11, 964)},
		{"name": "game.dat", "data": _ps2_body(0x22, 3000)},
	])
	_ok(PS2Card.is_psu(psu), "ps2/roundtrip/the built container is a psu")
	_ok(not PS2Card.is_psu(PackedByteArray()), "ps2/roundtrip/an empty file is not")

	var card := PS2Card.insert_save(blank, psu)
	_ok(not card.is_empty(), "ps2/roundtrip/it goes onto a blank card")
	_ok(PS2Card.is_card_image(card), "ps2/roundtrip/which still parses afterwards")

	var saves := PS2Card.list_saves(card, false)
	_eq(saves.size(), 1, "ps2/roundtrip/and lists one save")
	if saves.size() != 1:
		return
	_eq(str(saves[0]["name"]), "BASLUS-20488SAVE", "ps2/roundtrip/under its own name")
	# A PS2 save directory is the game's serial behind a two-letter region tag,
	# so the code is found by SHAPE and the tag is not mistaken for part of it.
	_eq(str(saves[0]["serial"]), "SLUS-20488", "ps2/roundtrip/with a serial read by shape")

	# Two files of 964 and 3000 bytes are one and three clusters, and the save's
	# own directory of four slots is two more.
	_eq(int(saves[0]["blocks"]), 6, "ps2/roundtrip/sized as its subtree")

	# The card spends SEVEN, not six: the root directory had room for two slots
	# and had to grow a cluster to hold the new entry. Directory overhead is real
	# and a save's own size is not the whole cost of putting it on a card.
	_eq(PS2Card.free_blocks(blank) - PS2Card.free_blocks(card), 7,
		"ps2/roundtrip/costing its six clusters plus the root's growth")

	var handle := PS2Card.block_of(card, "BASLUS-20488SAVE")
	_ok(handle >= 0, "ps2/roundtrip/and has a handle")
	var back := PS2Card.extract_save(card, handle)
	_ok(not back.is_empty(), "ps2/roundtrip/which extracts")
	_eq(back.size(), psu.size(), "ps2/roundtrip/to the same size it went in")
	_ok(back == psu, "ps2/roundtrip/and byte for byte the same container")

	# A save's digest must be a fact about the SAVE, not about where on the card
	# it happened to sit. Putting another save in first moves this one's
	# clusters; what comes back out must not change.
	var other := PS2Card.insert_save(blank, _ps2_psu("BASLUS-99999OTHER", [
		{"name": "x.dat", "data": _ps2_body(0x33, 700)}]))
	var both := PS2Card.insert_save(other, psu)
	_ok(not both.is_empty(), "ps2/roundtrip/a second save fits too")
	var moved := PS2Card.extract_save(both, PS2Card.block_of(both, "BASLUS-20488SAVE"))
	_ok(moved == psu, "ps2/roundtrip/and the first extracts identically from elsewhere")

	# Refusals.
	_ok(PS2Card.insert_save(card, psu).is_empty(),
		"ps2/roundtrip/the same name twice is refused")
	_ok(PS2Card.insert_save(blank, PackedByteArray()).is_empty(),
		"ps2/roundtrip/so is an empty container")
	_ok(PS2Card.insert_save(blank, _ps2_psu("HUGE", [
		{"name": "big.dat", "data": _ps2_body(0x44, 9000000)}])).is_empty(),
		"ps2/roundtrip/and one that cannot fit")


func _test_ps2_delete() -> void:
	var blank := PS2Card.blank_image()
	var psu := _ps2_psu("BASLUS-20488SAVE", [
		{"name": "game.dat", "data": _ps2_body(0x22, 2048)}])
	var card := PS2Card.insert_save(blank, psu)
	var handle := PS2Card.block_of(card, "BASLUS-20488SAVE")
	var after := PS2Card.delete_save(card, handle)
	_ok(not after.is_empty(), "ps2/delete/a save can be removed")
	_ok(PS2Card.is_card_image(after), "ps2/delete/and the card still parses")
	_eq(PS2Card.list_saves(after, false).size(), 0, "ps2/delete/and stops being listed")

	# Every cluster the save held comes back. The one the root grew by does not,
	# and should not: the root keeps the slot so the next save can reuse it.
	_eq(PS2Card.free_blocks(after), PS2Card.free_blocks(blank) - 1,
		"ps2/delete/with every cluster of the save back")

	# The slot itself stays, with MODE_USED cleared. That is what a deleted entry
	# looks like on a real card, and the root's length still counts it — which is
	# why a directory's length is a capacity and never a file count.
	var root_off := (PS2Card.ALLOC_OFFSET * PS2Card.PAGES_PER_CLUSTER) * PS2Card.PAGE_RAW
	var head := after.slice(root_off, root_off + PS2Card.ENTRY_SIZE)
	_eq(head.decode_u32(PS2Card.E_LENGTH), 3,
		"ps2/delete/the root still has three slots")

	# And the room is genuinely reusable, not merely counted as free.
	var again := PS2Card.insert_save(after, psu)
	_ok(not again.is_empty(), "ps2/delete/the freed room takes a save again")
	_eq(PS2Card.list_saves(again, false).size(), 1, "ps2/delete/which lists")
	var head2 := again.slice(root_off, root_off + PS2Card.ENTRY_SIZE)
	_eq(head2.decode_u32(PS2Card.E_LENGTH), 3,
		"ps2/delete/reusing the dead slot rather than growing the root")

	_ok(PS2Card.delete_save(card, 99).is_empty(), "ps2/delete/an absent slot is refused")
	_ok(PS2Card.delete_save(card, 0).is_empty(),
		"ps2/delete/and so is the root's own dot entry")


func _test_ps2_reject() -> void:
	# Cross-family, both ways. A save is just bytes with a name, and splicing a
	# foreign one into a card corrupts the card.
	var ps2 := PS2Card.blank_image()
	var ps1 := PS1Card.blank_image()
	var gc := GCCard.blank_image()
	_ok(not PS2Card.is_card_image(ps1), "ps2/reject/a PlayStation card is not a PS2 card")
	_ok(not PS2Card.is_card_image(gc), "ps2/reject/nor is a GameCube one")
	_ok(not PS1Card.is_card_image(ps2), "ps2/reject/and a PS2 card is not a PlayStation one")
	_ok(not GCCard.is_card_image(ps2), "ps2/reject/nor a GameCube one")

	var psu := _ps2_psu("BASLUS-20488SAVE", [
		{"name": "game.dat", "data": _ps2_body(0x22, 1024)}])
	_ok(not PS1Card.is_mcs(psu), "ps2/reject/a psu is not an mcs")
	_ok(not PS2Card.is_psu(ps1), "ps2/reject/and a card image is not a psu")

	# A card whose magic is right but whose type is not must still be refused.
	var wrong := ps2.duplicate()
	wrong[PS2Card.SB_CARD_TYPE] = 1
	_ok(not PS2Card.is_card_image(wrong), "ps2/reject/a card_type that is not 2")
	var no_magic := ps2.duplicate()
	no_magic[0] = 0x58
	_ok(not PS2Card.is_card_image(no_magic), "ps2/reject/and a broken magic")


func _test_ps2_fat() -> void:
	# The FAT is doubly indirect and its entries sit 256 to a cluster, so a save
	# long enough to cross that boundary walks a different FAT cluster than the
	# one it began in. PCSX2's own code indexes straight through the boundary by
	# exploiting contiguity, which is exactly what a literal transliteration gets
	# wrong — so a save past entry 255 is the case that catches it.
	var blank := PS2Card.blank_image()
	var big := _ps2_psu("BASLUS-30000BIG", [
		{"name": "big.dat", "data": _ps2_body(0x55, 300 * 1024)}])
	var card := PS2Card.insert_save(blank, big)
	_ok(not card.is_empty(), "ps2/fat/a 300-cluster save fits")
	# 300 clusters of payload, two for its own directory, one for the root's.
	_eq(PS2Card.free_blocks(blank) - PS2Card.free_blocks(card), 303,
		"ps2/fat/and costs its 300 clusters plus both directories")
	var back := PS2Card.extract_save(card, PS2Card.block_of(card, "BASLUS-30000BIG"))
	_ok(back == big, "ps2/fat/a chain across the FAT boundary reads back whole")

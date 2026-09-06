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
const EXPECTED_CASES := 156

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


# --- What every format must do ------------------------------------------------

func _test_shared_contract() -> void:
	for fmt: CardFormat in CardFormats.all():
		var n := fmt.id()
		_ok(not fmt.label().is_empty(), "shared/%s/has a label" % n)
		_ok(not fmt.extension().is_empty(), "shared/%s/has an extension" % n)
		_ok(not fmt.save_extension().is_empty(), "shared/%s/has a save extension" % n)
		_ok(not fmt.unit_noun().is_empty(), "shared/%s/has a unit noun" % n)
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
		"gamecube":    return GCCard.DENTRY_SIZE + GCCard.BLOCK_SIZE
		"playstation": return PS1Card.FRAME_SIZE + PS1Card.BLOCK_SIZE
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

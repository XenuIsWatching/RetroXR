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
const EXPECTED_CASES := 114

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

	# A case that never RAN is not a case that passed, and GDScript has no
	# try/catch: a decoder that indexes past its buffer aborts the function it is
	# in, and every case after it simply never prints. Mutation-testing this
	# suite is how that was found — a transposed icon tile dropped six cases and
	# still exited 0, which is the exact shape of a check that cannot fail.
	#
	# Bump this when adding cases; a mismatch means either that, or a case that
	# vanished, and both are worth stopping for.
	if _only.is_empty():
		_eq("suite/every case ran", _pass + _fail, EXPECTED_CASES)

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


func _eq(test_name: String, got: Variant, want: Variant) -> void:
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
	_eq("registry/a path resolves by extension",
		CardFormats.for_path("/x/y/MEMORY CARD.mcr").id(), "playstation")
	_eq("registry/for the GameCube too",
		CardFormats.for_path("/x/y/MEMORY CARD.raw").id(), "gamecube")
	_ok(CardFormats.for_path("/x/y/card.bin") == null, "registry/an unknown extension is null")

	# A console reaches its family through its own descriptor, and a Wii must
	# reach the GAMECUBE's — that is the whole reason a family is not a systemid.
	_eq("registry/a PlayStation resolves its family",
		CardFormats.for_system("playstation").id(), "playstation")
	_ok(CardFormats.for_system("nes") == null, "registry/a cartridge console has none")


# --- The GameCube blank -------------------------------------------------------

func _test_gc_blank() -> void:
	var img := GCCard.blank_image()
	_eq("gc/blank/a 251 card is 2 MiB", img.size(), 256 * GCCard.BLOCK_SIZE)
	_ok(GCCard.is_card_image(img), "gc/blank/it parses as a card")
	_eq("gc/blank/with 251 blocks free", GCCard.free_blocks(img), 251)
	_eq("gc/blank/and 251 in total", GCCard.total_blocks(img), 251)
	_eq("gc/blank/holding nothing", GCCard.list_saves(img, false).size(), 0)

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
	_eq("gc/blank/and reports its own size", GCCard.total_blocks(small), 59)

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
	_eq("gc/round/three blocks are taken", GCCard.free_blocks(one), 248)

	var saves := GCCard.list_saves(one, false)
	_eq("gc/round/one save is listed", saves.size(), 1)
	_eq("gc/round/under its filename", str(saves[0]["name"]), "melee_save")
	_eq("gc/round/with its serial", str(saves[0]["serial"]), "GALE01")
	_eq("gc/round/and its block count", int(saves[0]["blocks"]), 3)
	_eq("gc/round/its title is both comment lines", str(saves[0]["title"]),
		"Super Smash Bros — Melee data")

	# The lifted file must be byte-identical to what went in. This is the check
	# that catches a first-block field carried through instead of normalised —
	# which would make a save's hash a fact about where it sat on the card.
	var back := GCCard.extract_save(one, int(saves[0]["block"]))
	_ok(back == a, "gc/round/what comes back out is what went in")

	# A second save of a different game, and the first still readable after it.
	var b := _make_gci("GZLE", "01", "zelda_save", 2)
	var two := GCCard.insert_save(one, b)
	_ok(not two.is_empty(), "gc/round/a second save splices in")
	_eq("gc/round/both are listed", GCCard.list_saves(two, false).size(), 2)
	_eq("gc/round/five blocks are taken", GCCard.free_blocks(two), 246)
	_ok(GCCard.extract_save(two, GCCard.block_of(two, "melee_save")) == a,
		"gc/round/the first still extracts unchanged")
	_ok(GCCard.extract_save(two, GCCard.block_of(two, "zelda_save")) == b,
		"gc/round/and so does the second")

	# Delete frees exactly what it took and leaves the neighbour alone. Losing
	# the OTHER save is the failure this whole design is arranged against.
	var gone := GCCard.delete_save(two, GCCard.block_of(two, "melee_save"))
	_ok(not gone.is_empty(), "gc/round/delete returns a card")
	_ok(GCCard.is_card_image(gone), "gc/round/which still parses")
	_eq("gc/round/one save is left", GCCard.list_saves(gone, false).size(), 1)
	_eq("gc/round/its blocks came back", GCCard.free_blocks(gone), 249)
	_ok(GCCard.extract_save(gone, GCCard.block_of(gone, "zelda_save")) == b,
		"gc/round/and the neighbour is untouched")
	_eq("gc/round/the deleted one is gone", GCCard.block_of(gone, "melee_save"), -1)

	# The freed blocks are reusable, which is the point of freeing them.
	var again := GCCard.insert_save(gone, a)
	_ok(not again.is_empty(), "gc/round/the freed blocks take a save again")
	_eq("gc/round/back to five taken", GCCard.free_blocks(again), 246)

	# Every mutation returns a NEW image; the caller's copy must be untouched, so
	# a verify-then-write gate has something unspoiled to fall back on.
	_eq("gc/round/the original card was not mutated", GCCard.free_blocks(card), 251)


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
	_eq("gc/reject/and the card is untouched", GCCard.free_blocks(small), 59)


func _test_gc_chain() -> void:
	# Fill a small card, free a hole in the middle, and put a save in it that is
	# bigger than any single run left. It can only fit by CHAINING through the
	# BAT — which is what the format is for, and what an allocator that assumed
	# contiguous blocks would get wrong.
	var card := GCCard.blank_image(0x04)   # 59 blocks
	var names := ["one", "two", "three", "four"]
	for i in names.size():
		card = GCCard.insert_save(card, _make_gci("GA%dE" % i, "01", str(names[i]), 10))
	_eq("gc/chain/four saves fit", GCCard.list_saves(card, false).size(), 4)
	_eq("gc/chain/nineteen blocks left", GCCard.free_blocks(card), 19)

	# Free two non-adjacent tens, leaving 39 free in three separate runs.
	card = GCCard.delete_save(card, GCCard.block_of(card, "one"))
	card = GCCard.delete_save(card, GCCard.block_of(card, "three"))
	_eq("gc/chain/thirty-nine free after two deletes", GCCard.free_blocks(card), 39)

	var wide := _make_gci("GBBE", "01", "wide", 25)
	var out := GCCard.insert_save(card, wide)
	_ok(not out.is_empty(), "gc/chain/a save spanning the gaps fits")
	_ok(GCCard.is_card_image(out), "gc/chain/and the card still parses")
	_eq("gc/chain/fourteen left", GCCard.free_blocks(out), 14)

	var idx := GCCard.block_of(out, "wide")
	var chain := GCCard.save_chain(out,
		GCCard._be16(out, GCCard.dir_offset(out) + idx * GCCard.DENTRY_SIZE
			+ GCCard.E_FIRSTBLK))
	_eq("gc/chain/the chain is twenty-five blocks", chain.size(), 25)
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
	_eq("gc/pictures/one save", saves.size(), 1)
	var icons: Array = saves[0]["icons"]
	_eq("gc/pictures/one icon frame came back", icons.size(), 1)
	if icons.size() != 1:
		return

	var got := icons[0] as Image
	_eq("gc/pictures/it is 32 wide", got.get_width(), w)
	_eq("gc/pictures/and 32 tall", got.get_height(), h)

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
	_eq("gc/pictures/a zero frame delay ends the icon",
		(msaves[0]["icons"] as Array).size(), 0)

	# A save that declares no image at all must decode to no pictures rather
	# than reading whatever bytes happen to sit at offset zero.
	var plain := GCCard.insert_save(GCCard.blank_image(),
		_make_gci("GNON", "01", "noicon", 1))
	var psaves := GCCard.list_saves(plain, true)
	_eq("gc/pictures/a save with no image has no icons",
		(psaves[0]["icons"] as Array).size(), 0)
	_ok(psaves[0]["banner"] == null, "gc/pictures/and no banner")


# --- The PlayStation, held to the same contract -------------------------------

func _test_ps1_contract() -> void:
	var img := PS1Card.blank_image()
	_ok(PS1Card.is_card_image(img), "ps1/the blank parses")
	_eq("ps1/with fifteen blocks free", PS1Card.free_blocks(img), 15)
	_eq("ps1/holding nothing", PS1Card.list_saves(img, false).size(), 0)
	_ok(not PS1Card.is_card_image(GCCard.blank_image()),
		"ps1/a GameCube card is not a PlayStation card")
	_ok(not PS1Card.is_mcs(GCCard.blank_image()), "ps1/and a GameCube save is not an mcs")

	# Frame 63 is the write-test frame, a copy of the header. Every real card
	# carries it and pcsx_rearmed does not write it; a card without it is the odd
	# one out everywhere except inside that one core.
	_eq("ps1/frame 63 carries the header", img[63 * PS1Card.FRAME_SIZE], 0x4D)
	_eq("ps1/and its checksum", img[64 * PS1Card.FRAME_SIZE - 1], 0x0E)


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
		_eq("shared/%s/holding nothing" % n, fmt.list_saves(blank, false).size(), 0)
		_eq("shared/%s/with everything free" % n,
			fmt.free_blocks(blank), fmt.total_blocks(blank))
		_ok(not fmt.is_card_image(PackedByteArray()), "shared/%s/an empty image is not a card" % n)
		_ok(not fmt.is_save_file(PackedByteArray()), "shared/%s/nor is an empty file a save" % n)
		_eq("shared/%s/an absent save has no handle" % n,
			fmt.block_of(blank, "nothing"), -1)

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

## PS1Card — the PlayStation memory card image format (raw 128 KB .mcr).
##
## A card is 16 blocks of 8192 bytes. Block 0 is the directory; blocks 1-15 hold
## one save file each, chained through the directory's next-block links. Every
## PS1 core reads this same raw layout, which is why a card belongs to the
## console rather than to whichever core is currently running it.
##
## The blank produced here is byte-exact with the card ePSXe formats (md5
## 4899f80c65657f78035d962bfb5b3ef4), and its frame 63 matches all 58 real cards
## measured. It differs from what pcsx_rearmed formats for itself in exactly
## three bytes — that core omits the frame-63 write test — and differs from most
## published layouts, which also describe 0xFF filler in frames 56-62 that no
## real card carries. Every claim here was measured; trust none of it on paper.
##
## A new card must arrive formatted: RetroXR never boots the PS1 BIOS, so the
## player has no way to format one themselves.
class_name PS1Card
extends RefCounted

const FRAME_SIZE  := 128
const BLOCK_SIZE  := 8192
const BLOCK_COUNT := 16
const CARD_SIZE   := BLOCK_SIZE * BLOCK_COUNT   # 131072

## Directory entry states (byte 0 of frames 1-15).
const STATE_FIRST   := 0x51   ## in use, first block of a file
const STATE_MIDDLE  := 0x52   ## in use, middle of a chain
const STATE_LAST    := 0x53   ## in use, last block of a chain
const STATE_FREE    := 0xA0   ## free (formatted)

const LINK_NONE := 0xFFFF     ## next-block value meaning "end of chain"

## Compiled once. _serial_of runs per save, and every card list parses fifteen.
static var _SERIAL_RE := RegEx.create_from_string("([A-Z]{4})[^0-9]?([0-9]{5})")


## A freshly formatted, empty card.
static func blank_image() -> PackedByteArray:
	var img := PackedByteArray()
	img.resize(CARD_SIZE)
	img.fill(0)

	# Frame 0 — header: "MC" plus the XOR checksum of bytes 0..126 (0x4D ^ 0x43).
	img[0] = 0x4D
	img[1] = 0x43
	img[FRAME_SIZE - 1] = 0x0E

	# Frames 1-15 — directory, every entry free and terminating its own chain.
	for f in range(1, 16):
		var base := f * FRAME_SIZE
		img[base] = STATE_FREE
		img[base + 8] = 0xFF
		img[base + 9] = 0xFF
		img[base + FRAME_SIZE - 1] = STATE_FREE

	# Frames 16-35 — broken-sector list, all entries marked unused.
	for f in range(16, 36):
		var base := f * FRAME_SIZE
		for i in range(4):
			img[base + i] = 0xFF
		img[base + 8] = 0xFF
		img[base + 9] = 0xFF

	# Frame 63 — the write-test frame, a copy of the header. pcsx_rearmed leaves
	# this zero when it formats a card for itself, and following that is what the
	# first version of this did; all 58 real cards measured carry it, as does the
	# card ePSXe writes, so a card without it is the odd one out everywhere except
	# inside the one core. Written so our cards open like any other.
	img[63 * FRAME_SIZE] = 0x4D
	img[63 * FRAME_SIZE + 1] = 0x43
	img[64 * FRAME_SIZE - 1] = 0x0E

	# Frames 36-62 and blocks 1-15 stay zero.
	return img


## True when `data` looks like a PS1 card image (right size, "MC" magic).
static func is_card_image(data: PackedByteArray) -> bool:
	return data.size() == CARD_SIZE and data[0] == 0x4D and data[1] == 0x43


## XOR checksum of a frame's bytes 0..126, which is what byte 127 must equal.
static func frame_checksum(data: PackedByteArray, frame_offset: int) -> int:
	var sum := 0
	for i in range(FRAME_SIZE - 1):
		sum ^= data[frame_offset + i]
	return sum


# --- Reading the saves on a card ---------------------------------------------

## Every save file on the card, newest-block-order, one entry per save:
##   name    String   PS1 filename, e.g. "BASLUS-00972AC3NA"
##   serial  String   the game's product code pulled out of it, "SLUS-00972"
##   title   String   the save's own title, decoded from Shift-JIS
##   blocks  int      how many of the 15 blocks it occupies
##   block   int      its first block index (1-15)
##   icons   Array    Image, one per animation frame (1-3)
##
## Link blocks (0x52/0x53) are skipped: they belong to the file that starts at
## the 0x51 entry, and listing them would show one save several times.
## `with_icons` off skips decoding the animation frames, which is the expensive
## part by far — up to three 16x16 images per save, built a pixel at a time. Only
## the save list draws them; everything else wants the names and block counts.
static func list_saves(data: PackedByteArray, with_icons := true) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not is_card_image(data):
		return out
	for i in range(1, BLOCK_COUNT):
		var e := i * FRAME_SIZE
		if data[e] != STATE_FIRST:
			continue
		var raw := data.slice(e + 10, e + 31)
		var name := _ascii_until_nul(raw)
		var size := data.decode_u32(e + 4)
		var blk := i * BLOCK_SIZE
		@warning_ignore("integer_division")
		var blocks := maxi(1, size / BLOCK_SIZE)
		out.append({
			"name": name,
			"serial": _serial_of(name),
			"title": _decode_title(data.slice(blk + 4, blk + 68)),
			"blocks": blocks,
			"block": i,
			"icons": _icons(data, blk) if with_icons else [],
		})
	return out


## The first block of the save with this filename, or -1.
static func block_of(data: PackedByteArray, name: String) -> int:
	for s: Dictionary in list_saves(data, false):
		if str(s["name"]) == name:
			return int(s["block"])
	return -1


## The block indices one save occupies, in link order, starting at its first
## block. Follows the directory's next-block chain rather than assuming saves are
## contiguous — the PlayStation reuses freed blocks, so a three-block save can be
## scattered across the card.
##
## Defensive against a corrupt chain: a link out of range, or one that revisits a
## block already seen, ends the walk instead of looping forever.
static func save_chain(data: PackedByteArray, first_block: int) -> Array[int]:
	var out: Array[int] = []
	var seen := {}
	var b := first_block
	while b >= 1 and b < BLOCK_COUNT and not seen.has(b):
		seen[b] = true
		out.append(b)
		var nxt := data.decode_u16(b * FRAME_SIZE + 8)
		if nxt == LINK_NONE:
			break
		b = nxt + 1   # links are numbered from block 1, so 0 means block 1
	return out


## One save lifted out of a card as a standalone .mcs — its 128-byte directory
## entry followed by its data blocks in link order. That is the format every PS1
## card tool reads, and it is exactly what would be needed to put the save back.
static func extract_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	var out := PackedByteArray()
	if not is_card_image(data):
		return out
	var e := first_block * FRAME_SIZE
	if data[e] != STATE_FIRST:
		return out
	out.append_array(data.slice(e, e + FRAME_SIZE))
	var chain := save_chain(data, first_block)
	for b in chain:
		out.append_array(data.slice(b * BLOCK_SIZE, (b + 1) * BLOCK_SIZE))

	# Canonicalise the block links, so a lifted save says what it IS and not
	# where it happened to be sitting.
	#
	# Those two bytes name the next block on the card, and byte 127 checksums
	# them, so the same save read from two positions produced different bytes.
	# That made its md5 a fact about the card rather than the save: relocating it
	# looked like a change and re-uploaded it, the server's content_hash could
	# never match, and the restore path's verify — which re-extracts and compares
	# against what it downloaded — would have failed the moment a save landed
	# anywhere but its original blocks.
	#
	# Nothing is lost: insert_save rewrites the links for wherever it puts the
	# save, so the position was never carried by the .mcs in any useful sense.
	out.encode_u16(8, LINK_NONE if chain.size() <= 1 else 1)
	out[FRAME_SIZE - 1] = frame_checksum(out, 0)
	return out


# --- Changing a card ----------------------------------------------------------
#
# Every mutation returns a NEW image and never touches the one handed in, so a
# caller can parse the result and satisfy itself before writing anything to disk.
# A card is one file holding many games' saves: a wrong link or checksum here
# does not spoil the save being edited, it spoils every save on the card.

## Free the blocks one save occupies. Returns the new image, or empty when
## `first_block` is not the start of a save.
##
## Only the DIRECTORY is rewritten. The data blocks are left exactly as they
## were — which is what the console does as well, and means a mistake in here
## cannot reach another save's contents. The freed entries are byte-identical to
## the ones a format writes, so a deleted card is indistinguishable from a fresh
## one at those blocks.
static func delete_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	if not is_card_image(data):
		return PackedByteArray()
	if first_block < 1 or first_block >= BLOCK_COUNT:
		return PackedByteArray()
	if data[first_block * FRAME_SIZE] != STATE_FIRST:
		return PackedByteArray()

	var out := data.duplicate()
	for b in save_chain(data, first_block):
		var o := b * FRAME_SIZE
		for i in range(FRAME_SIZE):
			out[o + i] = 0
		out[o] = STATE_FREE
		out[o + 8] = 0xFF
		out[o + 9] = 0xFF
		out[o + FRAME_SIZE - 1] = frame_checksum(out, o)
	return out


## Does this look like a PS1 save file rather than some other console's?
##
## Worth asking of anything that came off a server: a save is just bytes with a
## name, and splicing a foreign one into a card would corrupt the card and hand
## the game garbage. Checks the shape a .mcs must have — a first-block directory
## entry with a filename, whole blocks after it, and the "SC" header every PS1
## save block starts with.
static func is_mcs(mcs: PackedByteArray) -> bool:
	if mcs.size() < FRAME_SIZE + BLOCK_SIZE:
		return false
	if (mcs.size() - FRAME_SIZE) % BLOCK_SIZE != 0:
		return false
	if mcs[0] != STATE_FIRST:
		return false
	if _ascii_until_nul(mcs.slice(10, 31)).is_empty():
		return false
	return mcs[FRAME_SIZE] == 0x53 and mcs[FRAME_SIZE + 1] == 0x43


## Splice a save (a .mcs, as extract_save produces) into a card. Returns the new
## image, or empty when the .mcs is malformed, a save of that name is already on
## the card, or there are not enough free blocks.
##
## Blocks are taken wherever they are free, so a save can land scattered — which
## is exactly what the console does, and why the chain has to be followed rather
## than assumed contiguous.
##
## The directory layout here is measured, not inferred, from real multi-block
## saves (Gran Turismo's five-block save among them):
##   first  0x51, size = the WHOLE file, filename set, next = the next block
##   middle 0x52, size 0, no filename, next = the next block
##   last   0x53, size 0, no filename, next = LINK_NONE
## `next` counts from 0 at card block 1, so it is always the block index minus 1.
static func insert_save(data: PackedByteArray, mcs: PackedByteArray) -> PackedByteArray:
	if not is_card_image(data) or not is_mcs(mcs):
		return PackedByteArray()
	@warning_ignore("integer_division")
	var n := (mcs.size() - FRAME_SIZE) / BLOCK_SIZE
	var name := _ascii_until_nul(mcs.slice(10, 31))
	for s in list_saves(data, false):
		if str(s["name"]) == name:
			return PackedByteArray()

	var free: Array[int] = []
	for i in range(1, BLOCK_COUNT):
		if data[i * FRAME_SIZE] >= STATE_FREE:
			free.append(i)
	if free.size() < n:
		return PackedByteArray()

	var out := data.duplicate()
	for i in range(n):
		var blk: int = free[i]
		var o := blk * FRAME_SIZE
		for j in range(FRAME_SIZE):
			out[o + j] = 0
		if i == 0:
			# Carry the original entry's identity: filename, and whatever the
			# game recorded beyond it. Size and link are rewritten below.
			for j in range(4, FRAME_SIZE - 1):
				out[o + j] = mcs[j]
			out[o] = STATE_FIRST
			out.encode_u32(o + 4, n * BLOCK_SIZE)
		else:
			out[o] = STATE_LAST if i == n - 1 else STATE_MIDDLE
		if i == n - 1:
			out[o + 8] = 0xFF
			out[o + 9] = 0xFF
		else:
			out.encode_u16(o + 8, free[i + 1] - 1)
		out[o + FRAME_SIZE - 1] = frame_checksum(out, o)

		var src := FRAME_SIZE + i * BLOCK_SIZE
		# slice/append_array copy in C++; a per-byte GDScript loop here cost
		# ~8k interpreted iterations per block, on a path a menu tap waits for.
		var dst2 := blk * BLOCK_SIZE
		out = out.slice(0, dst2) + mcs.slice(src, src + BLOCK_SIZE) + out.slice(dst2 + BLOCK_SIZE)
	return out


## How many of the 15 save blocks are still free.
static func free_blocks(data: PackedByteArray) -> int:
	if not is_card_image(data):
		return 0
	var n := 0
	for i in range(1, BLOCK_COUNT):
		if data[i * FRAME_SIZE] >= STATE_FREE:
			n += 1
	return n


static func _ascii_until_nul(raw: PackedByteArray) -> String:
	var s := ""
	for b in raw:
		if b == 0:
			break
		s += char(b)
	return s


## "BASLUS-00972AC3NA" -> "SLUS-00972". The first two letters are card and game
## region markers; the product code follows.
##
## Matched by SHAPE rather than by position, because the separator is not always
## a hyphen: of 71 real saves measured, one wrote "BASLUSP00797RR4_GAME" with a
## P where the dash belongs, and a fixed slice yields "SLUSP00797" — which would
## never match the "SLUS-00797" the disc itself reports. Normalising both to
## four letters and five digits makes them meet.
static func _serial_of(name: String) -> String:
	var m := _SERIAL_RE.search(name)
	if m == null:
		return ""
	return "%s-%s" % [m.get_string(1), m.get_string(2)]


## Decode a save's title frame. PS1 titles are Shift-JIS and almost always use
## the FULL-WIDTH forms, so reading the bytes as ASCII yields mojibake — the
## full-width blocks are contiguous, which covers every Western title. Anything
## outside them (real kana or kanji) has no ASCII equivalent and is dropped
## rather than guessed; the filename is always there as a fallback.
static func _decode_title(raw: PackedByteArray) -> String:
	const PUNCT := {
		0x8140: " ", 0x8141: ",", 0x8142: ".", 0x8143: ",", 0x8144: ".",
		0x8146: ":", 0x8147: ";", 0x8148: "?", 0x8149: "!", 0x814F: "^",
		0x8151: "_", 0x815B: "-", 0x815C: "-", 0x815D: "-", 0x815E: "/",
		0x815F: "\\", 0x8160: "~", 0x8162: "|", 0x8165: "'", 0x8166: "'",
		0x8167: "\"", 0x8168: "\"", 0x8169: "(", 0x816A: ")", 0x816D: "[",
		0x816E: "]", 0x816F: "{", 0x8170: "}", 0x817B: "+", 0x817C: "-",
		0x8181: "=", 0x8183: "<", 0x8184: ">", 0x8190: "$", 0x8193: "%",
		0x8194: "#", 0x8195: "&", 0x8196: "*", 0x8197: "@",
	}
	var s := ""
	var i := 0
	while i < raw.size():
		var b := raw[i]
		if b == 0:
			break
		# Some games just write plain ASCII.
		if b < 0x80:
			s += char(b)
			i += 1
			continue
		if i + 1 >= raw.size():
			break
		var w := (b << 8) | raw[i + 1]
		i += 2
		if w >= 0x824F and w <= 0x8258:
			s += char(0x30 + (w - 0x824F))        # full-width 0-9
		elif w >= 0x8260 and w <= 0x8279:
			s += char(0x41 + (w - 0x8260))        # full-width A-Z
		elif w >= 0x8281 and w <= 0x829A:
			s += char(0x61 + (w - 0x8281))        # full-width a-z
		elif PUNCT.has(w):
			s += str(PUNCT[w])
	return s.strip_edges()


## The save's animation frames as 16x16 RGBA images (1-3 of them).
##
## 4 bpp indices into a 16-colour CLUT of little-endian BGR555. Two pixels per
## byte, LOW nibble first — get that backwards and the icon comes out mirrored
## in pairs. Colour 0x0000 with the semi-transparency bit clear is transparent,
## which is how icons get their cut-out background.
static func _icons(data: PackedByteArray, blk: int) -> Array:
	var frames: int = clampi(data[blk + 2] & 0x0F, 1, 3)
	var pal := PackedColorArray()
	for c in range(16):
		var v := data.decode_u16(blk + 96 + c * 2)
		var a := 0.0 if (v & 0x7FFF) == 0 and (v & 0x8000) == 0 else 1.0
		pal.append(Color(
			float((v & 0x1F) << 3) / 255.0,
			float(((v >> 5) & 0x1F) << 3) / 255.0,
			float(((v >> 10) & 0x1F) << 3) / 255.0,
			a))
	var out: Array = []
	for f in range(frames):
		var src := blk + FRAME_SIZE + f * FRAME_SIZE
		var px := PackedByteArray()
		px.resize(16 * 16 * 4)
		for i in range(16 * 16):
			@warning_ignore("integer_division")
			var byte := data[src + i / 2]
			var idx := (byte & 0x0F) if i % 2 == 0 else (byte >> 4)
			var col: Color = pal[idx]
			px[i * 4]     = int(col.r * 255.0)
			px[i * 4 + 1] = int(col.g * 255.0)
			px[i * 4 + 2] = int(col.b * 255.0)
			px[i * 4 + 3] = int(col.a * 255.0)
		out.append(Image.create_from_data(16, 16, false, Image.FORMAT_RGBA8, px))
	return out

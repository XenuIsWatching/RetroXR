## VMUCard — the Dreamcast Visual Memory Unit's flash image (raw 128 KB).
##
## 256 blocks of 512 bytes. Unlike every other card here the layout runs
## DOWNWARD from the top: the root block is 255, the FAT is 254, the directory
## is a thirteen-block chain from 253 down to 241, and the 200 blocks a player
## can fill are 0-199. Blocks 200-240 are reserved and stay unallocated.
##
## Every constant below was measured against a card flycast itself formatted,
## not taken from a specification. Two of them are the reverse of the obvious
## guess and are the reason this note exists:
##
##   * FAT_UNALLOCATED is 0xFFFC and FAT_LAST is 0xFFFA. Published tables give
##     these the other way round. On a real blank card all 200 user entries read
##     0xFFFC, and the directory really is a descending chain terminating in
##     0xFFFA — which is only self-consistent under the values used here.
##   * A GAME's header sits at block 1 of the file (0x200), not at its start;
##     only a DATA file puts the header at 0x00. The directory entry's own
##     header-offset field says which, and reading a game at 0x00 yields
##     plausible garbage rather than an error, so the field must be obeyed.
##
## RetroXR never boots the Dreamcast BIOS, so a new card has to arrive
## formatted. blank_image() reproduces flycast's own freshly formatted card
## byte for byte across the system blocks (241-255), including the 1998-11-27
## stamp — the Dreamcast's Japanese launch day, which that core uses as a fixed
## format date. Matching it exactly means a card RetroXR mints and one flycast
## minted are indistinguishable to a game.
class_name VMUCard
extends RefCounted

const BLOCK_SIZE  := 512
const BLOCK_COUNT := 256
const CARD_SIZE   := BLOCK_SIZE * BLOCK_COUNT   # 131072

const USER_BLOCKS := 200        ## blocks 0-199, the only ones a save may occupy
const ROOT_BLOCK  := 255
const FAT_BLOCK   := 254
const DIR_BLOCK   := 253        ## highest directory block; the chain runs down
const DIR_BLOCKS  := 13         ## 253 down to 241

const DIR_ENTRY_SIZE := 32
const DIR_PER_BLOCK  := BLOCK_SIZE / DIR_ENTRY_SIZE          # 16
const DIR_ENTRIES    := DIR_BLOCKS * DIR_PER_BLOCK           # 208

## FAT sentinels. Measured, and the reverse of most published tables.
const FAT_UNALLOCATED := 0xFFFC
const FAT_LAST        := 0xFFFA

## Directory entry type byte.
const TYPE_FREE := 0x00
const TYPE_DATA := 0x33
const TYPE_GAME := 0xCC

const COPY_OK        := 0x00
const COPY_PROTECTED := 0xFF

# Directory entry field offsets, all little-endian.
const E_TYPE      := 0x00
const E_COPY      := 0x01
const E_FIRSTBLK  := 0x02
const E_NAME      := 0x04   ## 12 bytes, space/NUL padded
const E_NAME_LEN  := 12
const E_TIME      := 0x10   ## 8 bytes BCD
const E_BLOCKS    := 0x18
const E_HDROFF    := 0x1A   ## header position, in blocks from the file's start

# VMS header field offsets, relative to the header block.
const V_DESC       := 0x00   ## 16 chars, what the VMU's own file list shows
const V_DC_DESC    := 0x10   ## 32 chars, what the Dreamcast's menu shows
const V_APP        := 0x30   ## 16 chars, creating application
const V_ICONS      := 0x40
const V_ICON_SPEED := 0x42
const V_EYECATCH   := 0x44
const V_CRC        := 0x46
const V_DATA_SIZE  := 0x48   ## meaningful for DATA files only; a game reads 0
const V_PALETTE    := 0x60   ## 16 entries, u16 ARGB4444
const V_ICON_DATA  := 0x80

const ICON_W     := 32
const ICON_H     := 32
const ICON_BYTES := 512      ## 32 x 32 at two pixels per byte

## Eyecatch sizes by type, indexed 0-3. Type 0 is "no eyecatch"; the rest sit
## between the icon frames and the payload and so shift where data begins.
const EYECATCH_BYTES := [0, 8064, 4544, 2048]

const DCI_HEADER := DIR_ENTRY_SIZE   ## a .dci is one directory entry, then data


# --- Format -------------------------------------------------------------------

## A freshly formatted, empty card, byte-identical to flycast's own across the
## system blocks.
static func blank_image() -> PackedByteArray:
	var img := PackedByteArray()
	img.resize(CARD_SIZE)
	img.fill(0)

	var r := ROOT_BLOCK * BLOCK_SIZE

	# Sixteen 0x55 bytes are what marks the card formatted at all.
	for i in range(16):
		img[r + i] = 0x55

	# Custom colour: enabled, opaque-ish white. flycast's default, reproduced so
	# a card minted here and one minted there read the same to a game.
	img[r + 0x10] = 0x01   # use custom colour
	img[r + 0x11] = 0xFF   # blue
	img[r + 0x12] = 0xFF   # green
	img[r + 0x13] = 0xFF   # red
	img[r + 0x14] = 0x64   # alpha, 100

	# Format timestamp, BCD: 1998-11-27 00:00:59, weekday 4.
	var stamp := [0x19, 0x98, 0x11, 0x27, 0x00, 0x00, 0x59, 0x04]
	for i in range(stamp.size()):
		img[r + 0x30 + i] = int(stamp[i])

	# Geometry. 0x40 and 0x44 both read 255 on a real card; 0x52 and 0x56 carry
	# 31 and 128, whose meaning was not established — they are reproduced rather
	# than reasoned about, because a game may well read them.
	_put_u16(img, r + 0x40, 0x00FF)
	_put_u16(img, r + 0x44, 0x00FF)
	_put_u16(img, r + 0x46, FAT_BLOCK)
	_put_u16(img, r + 0x48, 1)
	_put_u16(img, r + 0x4A, DIR_BLOCK)
	_put_u16(img, r + 0x4C, DIR_BLOCKS)
	_put_u16(img, r + 0x4E, 5)             # icon shape
	_put_u16(img, r + 0x50, USER_BLOCKS)
	_put_u16(img, r + 0x52, 31)
	_put_u16(img, r + 0x56, 128)

	# The FAT: everything unallocated, then the directory's descending chain and
	# the two single-block system files that terminate themselves.
	var f := FAT_BLOCK * BLOCK_SIZE
	for b in range(BLOCK_COUNT):
		_put_u16(img, f + b * 2, FAT_UNALLOCATED)
	for b in range(DIR_BLOCK, DIR_BLOCK - DIR_BLOCKS, -1):
		var next_block := b - 1
		_put_u16(img, f + b * 2, FAT_LAST if next_block <= DIR_BLOCK - DIR_BLOCKS else next_block)
	_put_u16(img, f + FAT_BLOCK * 2, FAT_LAST)
	_put_u16(img, f + ROOT_BLOCK * 2, FAT_LAST)

	# The directory is already all zeros, and a zero type byte is a free slot.
	return img


## Does this look like a VMU card at all? Size plus the format signature; a
## file of the right length with no 0x55 run is an unformatted dump, not a card.
static func is_card_image(data: PackedByteArray) -> bool:
	if data.size() != CARD_SIZE:
		return false
	var r := ROOT_BLOCK * BLOCK_SIZE
	for i in range(16):
		if data[r + i] != 0x55:
			return false
	return true


# --- Reading ------------------------------------------------------------------

## Every save on the card. See CardFormat.list_saves for the entry shape.
static func list_saves(data: PackedByteArray, with_icons := true) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not is_card_image(data):
		return out
	for slot in range(DIR_ENTRIES):
		var e := _entry_offset(slot)
		var type_byte := data[e + E_TYPE]
		if type_byte != TYPE_DATA and type_byte != TYPE_GAME:
			continue
		var first: int = _get_u16(data, e + E_FIRSTBLK)
		var blocks: int = _get_u16(data, e + E_BLOCKS)
		if first >= USER_BLOCKS or blocks <= 0:
			continue

		var name := _read_name(data, e)
		var body := _file_bytes(data, first, blocks)
		var hdr := _get_u16(data, e + E_HDROFF) * BLOCK_SIZE
		var title := name
		var icons: Array = []
		if body.size() >= hdr + V_ICON_DATA:
			# Both descriptions are Shift-JIS, like a PlayStation save's title,
			# and a Japanese game writes real kana and kanji there. Read as
			# ASCII those came out as the low byte of every pair — Ikaruga's
			# listed as "ij" — so they go through the same decoder the Sony
			# cards use, which carries the full-width forms and drops what
			# ASCII cannot hold, leaving the on-card name to stand in.
			var desc := _sjis_title(body.slice(hdr + V_DESC, hdr + V_DESC + 16))
			if not desc.is_empty():
				title = desc
			else:
				var dc := _sjis_title(body.slice(hdr + V_DC_DESC, hdr + V_DC_DESC + 32))
				if not dc.is_empty():
					title = dc
			if with_icons:
				icons = _decode_icons(body, hdr)

		out.append({
			"name": name,
			"serial": "",          # a VMS carries no product code
			"title": title,
			"blocks": blocks,
			"block": first,
			"icons": icons,
			"is_game": type_byte == TYPE_GAME,
		})
	return out


## The first block of the save with this filename, or -1.
static func block_of(data: PackedByteArray, name: String) -> int:
	if not is_card_image(data):
		return -1
	for slot in range(DIR_ENTRIES):
		var e := _entry_offset(slot)
		var type_byte := data[e + E_TYPE]
		if type_byte != TYPE_DATA and type_byte != TYPE_GAME:
			continue
		if _read_name(data, e) == name:
			return _get_u16(data, e + E_FIRSTBLK)
	return -1


## How many of the 200 user blocks are still free.
static func free_blocks(data: PackedByteArray) -> int:
	if not is_card_image(data):
		return 0
	var f := FAT_BLOCK * BLOCK_SIZE
	var n := 0
	for b in range(USER_BLOCKS):
		if _get_u16(data, f + b * 2) == FAT_UNALLOCATED:
			n += 1
	return n


# --- Lifting a save off, and putting one back ---------------------------------

## One save as a standalone .dci: its 32-byte directory entry, then the file
## body with every 32-bit word byte-swapped.
##
## .dci rather than raw .vms because it is the only one of the two that carries
## the directory entry — the type, the on-card name, the block count and the
## header offset. A .vms alone would have to have all four invented on the way
## back in.
static func extract_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	var out := PackedByteArray()
	if not is_card_image(data):
		return out
	var e := _entry_for_block(data, first_block)
	if e < 0:
		return out
	var blocks: int = _get_u16(data, e + E_BLOCKS)
	var body := _file_bytes(data, first_block, blocks)
	if body.is_empty():
		return out

	out.resize(DCI_HEADER)
	for i in range(DIR_ENTRY_SIZE):
		out[i] = data[e + i]
	# A .dci names no position on any card; its first block reads 0, as every
	# real one measured does.
	_put_u16(out, E_FIRSTBLK, 0)
	out.append_array(_word_swap(body))
	return out


## A library .vms as the .dci a card would hold it as: the directory entry a
## Dreamcast would have written — type, a 12-char name, the block count, the
## header offset (1 for a game, whose header sits at 0x200; 0 for data) — then
## the body block-padded and word-swapped. The inverse of extract_save, for a
## file that never went through a card.
static func dci_from_vms(body: PackedByteArray, name: String, is_game := true) -> PackedByteArray:
	if body.is_empty():
		return PackedByteArray()
	var blocks := ceili(float(body.size()) / BLOCK_SIZE)
	if blocks > USER_BLOCKS:
		return PackedByteArray()
	var padded := body.duplicate()
	padded.resize(blocks * BLOCK_SIZE)
	var out := PackedByteArray()
	out.resize(DCI_HEADER)
	out.fill(0)
	out[E_TYPE] = TYPE_GAME if is_game else TYPE_DATA
	var n := name.to_ascii_buffer().slice(0, E_NAME_LEN)
	for i in range(E_NAME_LEN):
		out[E_NAME + i] = n[i] if i < n.size() else 0x20
	_put_u16(out, E_BLOCKS, blocks)
	_put_u16(out, E_HDROFF, 1 if is_game else 0)
	out.append_array(_word_swap(padded))
	return out


## Does this look like a .dci of THIS family?
static func is_dci(bytes: PackedByteArray) -> bool:
	if bytes.size() <= DCI_HEADER or (bytes.size() - DCI_HEADER) % BLOCK_SIZE != 0:
		return false
	var type_byte := bytes[E_TYPE]
	if type_byte != TYPE_DATA and type_byte != TYPE_GAME:
		return false
	var blocks: int = _get_u16(bytes, E_BLOCKS)
	if blocks <= 0 or blocks > USER_BLOCKS:
		return false
	if blocks * BLOCK_SIZE != bytes.size() - DCI_HEADER:
		return false
	return _get_u16(bytes, E_HDROFF) < blocks


## Splice a save into a card, returning a NEW image. Empty when it will not fit,
## is malformed, or a save of that name is already there.
static func insert_save(data: PackedByteArray, save: PackedByteArray) -> PackedByteArray:
	if not is_card_image(data) or not is_dci(save):
		return PackedByteArray()
	var name := _read_name(save, 0)
	if name.is_empty() or block_of(data, name) >= 0:
		return PackedByteArray()

	var blocks: int = _get_u16(save, E_BLOCKS)
	var free := _free_list(data)
	if free.size() < blocks:
		return PackedByteArray()
	var slot := _free_entry(data)
	if slot < 0:
		return PackedByteArray()

	var img := data.duplicate()
	var body := _word_swap(save.slice(DCI_HEADER))
	var f := FAT_BLOCK * BLOCK_SIZE
	for i in range(blocks):
		var b: int = free[i]
		var dst := b * BLOCK_SIZE
		for j in range(BLOCK_SIZE):
			img[dst + j] = body[i * BLOCK_SIZE + j]
		_put_u16(img, f + b * 2, FAT_LAST if i == blocks - 1 else int(free[i + 1]))

	var e := _entry_offset(slot)
	for i in range(DIR_ENTRY_SIZE):
		img[e + i] = save[i]
	_put_u16(img, e + E_FIRSTBLK, int(free[0]))
	return img


## Free the space one save occupies, returning a NEW image.
static func delete_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	if not is_card_image(data):
		return PackedByteArray()
	var e := _entry_for_block(data, first_block)
	if e < 0:
		return PackedByteArray()

	var img := data.duplicate()
	var f := FAT_BLOCK * BLOCK_SIZE
	for b in _chain(img, first_block, _get_u16(img, e + E_BLOCKS)):
		_put_u16(img, f + int(b) * 2, FAT_UNALLOCATED)
	for i in range(DIR_ENTRY_SIZE):
		img[e + i] = 0
	return img


# --- Internals ----------------------------------------------------------------

static func _get_u16(d: PackedByteArray, at: int) -> int:
	return d[at] | (d[at + 1] << 8)


static func _put_u16(d: PackedByteArray, at: int, v: int) -> void:
	d[at] = v & 0xFF
	d[at + 1] = (v >> 8) & 0xFF


## Byte offset of one directory slot. The directory runs DOWNWARD, so slot 0 is
## in block 253 and slot 207 in block 241.
static func _entry_offset(slot: int) -> int:
	@warning_ignore("integer_division")
	var block: int = DIR_BLOCK - slot / DIR_PER_BLOCK
	var within: int = slot % DIR_PER_BLOCK
	return block * BLOCK_SIZE + within * DIR_ENTRY_SIZE


static func _entry_for_block(data: PackedByteArray, first_block: int) -> int:
	for slot in range(DIR_ENTRIES):
		var e := _entry_offset(slot)
		var type_byte := data[e + E_TYPE]
		if type_byte != TYPE_DATA and type_byte != TYPE_GAME:
			continue
		if _get_u16(data, e + E_FIRSTBLK) == first_block:
			return e
	return -1


static func _free_entry(data: PackedByteArray) -> int:
	for slot in range(DIR_ENTRIES):
		if data[_entry_offset(slot) + E_TYPE] == TYPE_FREE:
			return slot
	return -1


static func _free_list(data: PackedByteArray) -> Array[int]:
	var out: Array[int] = []
	var f := FAT_BLOCK * BLOCK_SIZE
	for b in range(USER_BLOCKS):
		if _get_u16(data, f + b * 2) == FAT_UNALLOCATED:
			out.append(b)
	return out


## The blocks one file occupies, in order. Bounded by its recorded length so a
## corrupt FAT cannot spin here.
static func _chain(data: PackedByteArray, first_block: int, blocks: int) -> Array[int]:
	var out: Array[int] = []
	var f := FAT_BLOCK * BLOCK_SIZE
	var b := first_block
	var guard: int = mini(maxi(blocks, 1), USER_BLOCKS)
	while out.size() < guard:
		if b < 0 or b >= USER_BLOCKS:
			break
		out.append(b)
		var next_block := _get_u16(data, f + b * 2)
		if next_block == FAT_LAST or next_block == FAT_UNALLOCATED:
			break
		b = next_block
	return out


static func _file_bytes(data: PackedByteArray, first_block: int, blocks: int) -> PackedByteArray:
	var out := PackedByteArray()
	for b in _chain(data, first_block, blocks):
		out.append_array(data.slice(int(b) * BLOCK_SIZE, int(b) * BLOCK_SIZE + BLOCK_SIZE))
	return out


## Every 32-bit word reversed. A .dci stores its payload this way; the operation
## is its own inverse, so one function serves both directions.
static func _word_swap(body: PackedByteArray) -> PackedByteArray:
	var out := body.duplicate()
	var n: int = out.size() - out.size() % 4
	for i in range(0, n, 4):
		var a := out[i]
		var b := out[i + 1]
		out[i] = out[i + 3]
		out[i + 1] = out[i + 2]
		out[i + 2] = b
		out[i + 3] = a
	return out


static func _read_name(d: PackedByteArray, entry_at: int) -> String:
	return _read_ascii(d, entry_at + E_NAME, E_NAME_LEN)


## A Shift-JIS description as a title, or "" when nothing of it survives.
##
## The decoder keeps punctuation and drops kana and kanji, so a Japanese title
## in full-width brackets comes back as "()" — Ikaruga did — which is worse
## than no title, because the on-card name behind it is at least the game's.
## Only a decode with a letter or digit in it counts.
static func _sjis_title(raw: PackedByteArray) -> String:
	var s := Sjis.to_ascii(raw)
	for i in range(s.length()):
		var c := s.unicode_at(i)
		if (c >= 0x30 and c <= 0x39) or (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A):
			return s
	return ""


static func _read_ascii(d: PackedByteArray, at: int, length: int) -> String:
	if at < 0 or at + length > d.size():
		return ""
	var s := ""
	for i in range(length):
		var c := d[at + i]
		if c == 0:
			break
		if c >= 32 and c < 127:
			s += char(c)
	return s.strip_edges()


## The save's animation frames, decoded from the VMS header at `hdr`.
static func _decode_icons(body: PackedByteArray, hdr: int) -> Array:
	var out: Array = []
	var count: int = _get_u16(body, hdr + V_ICONS)
	if count <= 0 or count > 3:
		return out

	var palette: Array[Color] = []
	for i in range(16):
		var at := hdr + V_PALETTE + i * 2
		if at + 1 >= body.size():
			return out
		var v := _get_u16(body, at)
		# ARGB4444, one nibble each, scaled to 0-255 by x17.
		palette.append(Color8(
			((v >> 8) & 0xF) * 17,
			((v >> 4) & 0xF) * 17,
			(v & 0xF) * 17,
			((v >> 12) & 0xF) * 17))

	for frame in range(count):
		var at := hdr + V_ICON_DATA + frame * ICON_BYTES
		if at + ICON_BYTES > body.size():
			break
		var img := Image.create_empty(ICON_W, ICON_H, false, Image.FORMAT_RGBA8)
		for i in range(ICON_BYTES):
			var byte := body[at + i]
			var x := (i * 2) % ICON_W
			@warning_ignore("integer_division")
			var y := (i * 2) / ICON_W
			img.set_pixel(x, y, palette[(byte >> 4) & 0xF])
			img.set_pixel(x + 1, y, palette[byte & 0xF])
		out.append(img)
	return out

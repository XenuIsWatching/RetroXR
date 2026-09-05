## GCCard — the GameCube memory card image format (raw .raw).
##
## Everything here is BIG-endian, which is the first thing that catches you out:
## Godot's decode_u16/decode_u32 are little-endian and there is no big-endian
## variant, so every multi-byte field goes through _be16/_be32 below.
##
## A card is `size_mb * 16` blocks of 8192 bytes. Blocks 0-4 are the system area
## — header, directory, directory backup, block-allocation table, BAT backup —
## and save data starts at block 5. Of the two directory copies and the two BAT
## copies the live one is whichever has the higher update counter, so both are
## written on every change.
##
## The layout was checked against a real save before it was written down, not
## read off a wiki: `01-G4SE-gc4sword.gci`, a Four Swords Adventures save, parses
## at every offset here, and its icon and banner decode to the right pictures.
## The tiling in particular is the thing that produces a plausible WRONG image if
## you transpose it, so it was proven by rendering rather than by inspection.
##
## A new card must arrive formatted: RetroXR never boots the GameCube IPL, so the
## player has no way to format one themselves.
class_name GCCard
extends RefCounted

const BLOCK_SIZE   := 0x2000          ## 8192
const SYSTEM_BLOCKS := 5              ## header + dir + dir backup + bat + bat backup
const DENTRY_SIZE  := 0x40            ## 64
const DIR_ENTRIES  := 127
const BAT_SIZE     := 0xFFB           ## map entries, one per data block

## Card sizes in Mbit. 16 Mbit is the 251-block retail card and our default.
const MBIT_251 := 0x10
const BLOCKS_PER_MBIT := 16

const LINK_LAST := 0xFFFF             ## BAT: this is the file's last block
const LINK_FREE := 0                  ## BAT: block is unallocated

## Offsets inside the header block.
const HDR_SIZE_MB   := 0x22
const HDR_ENCODING  := 0x24
const HDR_CSUM      := 0x1FC

## Offsets inside a directory block.
const DIR_UPDATE    := 0x1FFA
const DIR_CSUM      := 0x1FFC

## Offsets inside a BAT block.
const BAT_CSUM      := 0x00
const BAT_UPDATE    := 0x04
const BAT_FREE      := 0x06
const BAT_LAST_ALLOC := 0x08
const BAT_MAP       := 0x0A

## Offsets inside a 64-byte directory entry.
const E_GAMECODE  := 0x00
const E_MAKERCODE := 0x04
const E_BANNER    := 0x07
const E_FILENAME  := 0x08
const E_MODTIME   := 0x28
const E_IMAGE_OFF := 0x2C
const E_ICON_FMT  := 0x30
const E_ANIM      := 0x32
const E_FIRSTBLK  := 0x36
const E_BLOCKS    := 0x38
const E_COMMENTS  := 0x3C

const BANNER_W := 96
const BANNER_H := 32
const ICON_W := 32
const ICON_H := 32
const MAX_ICON_FRAMES := 8
const PALETTE_ENTRIES := 256

## GameCube colour expansion is by LOOKUP, not by shifting. s_lut5to8[5] is 0x29
## and a `<< 3` would give 0x28 — small, but it is wrong on every pixel.
const LUT5 := [0x00, 0x08, 0x10, 0x18, 0x20, 0x29, 0x31, 0x39, 0x41, 0x4A, 0x52,
	0x5A, 0x62, 0x6A, 0x73, 0x7B, 0x83, 0x8B, 0x94, 0x9C, 0xA4, 0xAC,
	0xB4, 0xBD, 0xC5, 0xCD, 0xD5, 0xDE, 0xE6, 0xEE, 0xF6, 0xFF]
const LUT4 := [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
	0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
const LUT3 := [0x00, 0x24, 0x48, 0x6D, 0x91, 0xB6, 0xDA, 0xFF]


# --- Big-endian readers -------------------------------------------------------

static func _be16(data: PackedByteArray, off: int) -> int:
	return (data[off] << 8) | data[off + 1]


static func _be32(data: PackedByteArray, off: int) -> int:
	return (data[off] << 24) | (data[off + 1] << 16) \
		| (data[off + 2] << 8) | data[off + 3]


static func _put_be16(data: PackedByteArray, off: int, v: int) -> void:
	data[off] = (v >> 8) & 0xFF
	data[off + 1] = v & 0xFF


# --- Checksums ----------------------------------------------------------------

## The additive/inverse pair a system block carries, over `size` bytes at `off`.
##
## Both are plain 16-bit sums of BIG-endian words — the second over each word
## XORed with 0xFFFF — and both write 0 in place of 0xFFFF. That last rule looks
## like a quirk and is load-bearing: without it a freshly formatted card fails
## its own checksum.
static func checksums(data: PackedByteArray, off: int, size: int) -> Array[int]:
	var csum := 0
	var inv := 0
	var i := 0
	while i < size:
		var w := _be16(data, off + i)
		csum = (csum + w) & 0xFFFF
		inv = (inv + (w ^ 0xFFFF)) & 0xFFFF
		i += 2
	if csum == 0xFFFF:
		csum = 0
	if inv == 0xFFFF:
		inv = 0
	return [csum, inv]


static func _fix_checksums(data: PackedByteArray, area_off: int, area_size: int,
		store_off: int) -> void:
	var c := checksums(data, area_off, area_size)
	_put_be16(data, store_off, c[0])
	_put_be16(data, store_off + 2, c[1])


static func _checksums_ok(data: PackedByteArray, area_off: int, area_size: int,
		store_off: int) -> bool:
	var c := checksums(data, area_off, area_size)
	return _be16(data, store_off) == c[0] and _be16(data, store_off + 2) == c[1]


# --- Which copy is live -------------------------------------------------------

## Of two identical system blocks, the one to read. A block that fails its own
## checksum loses to one that passes whatever the counters say — that is the
## point of keeping a backup — and only when both pass does the higher update
## counter win.
static func _pick(data: PackedByteArray, block_a: int, block_b: int,
		area_off: int, area_size: int, store_off: int, update_off: int) -> int:
	var off_a := block_a * BLOCK_SIZE
	var off_b := block_b * BLOCK_SIZE
	var ok_a := _checksums_ok(data, off_a + area_off, area_size, off_a + store_off)
	var ok_b := _checksums_ok(data, off_b + area_off, area_size, off_b + store_off)
	if ok_a != ok_b:
		return block_a if ok_a else block_b
	return block_b if _be16(data, off_b + update_off) > \
		_be16(data, off_a + update_off) else block_a


## Byte offset of the live directory block.
static func dir_offset(data: PackedByteArray) -> int:
	return _pick(data, 1, 2, 0, DIR_CSUM, DIR_CSUM, DIR_UPDATE) * BLOCK_SIZE


## Byte offset of the live BAT block.
static func bat_offset(data: PackedByteArray) -> int:
	return _pick(data, 3, 4, BAT_UPDATE, BLOCK_SIZE - BAT_UPDATE,
		BAT_CSUM, BAT_UPDATE) * BLOCK_SIZE


# --- Card shape ---------------------------------------------------------------

## Total blocks on the card, from its byte size.
static func card_blocks(data: PackedByteArray) -> int:
	@warning_ignore("integer_division")
	return data.size() / BLOCK_SIZE


## Blocks available to saves — the card minus its five system blocks.
static func total_blocks(data: PackedByteArray) -> int:
	if not is_card_image(data):
		return MBIT_251 * BLOCKS_PER_MBIT - SYSTEM_BLOCKS
	return card_blocks(data) - SYSTEM_BLOCKS


## True when `data` is a plausible GameCube card: a valid size, a header whose
## checksum passes, and a header size field agreeing with the file's own length.
##
## The size agreement is the check worth having. A truncated or padded image
## still has a valid header, and taking its word for the size would walk the BAT
## off the end of the buffer.
static func is_card_image(data: PackedByteArray) -> bool:
	if data.size() < (SYSTEM_BLOCKS + 1) * BLOCK_SIZE:
		return false
	if data.size() % BLOCK_SIZE != 0:
		return false
	var blocks := card_blocks(data)
	@warning_ignore("integer_division")
	var mbit := blocks / BLOCKS_PER_MBIT
	if mbit * BLOCKS_PER_MBIT != blocks or not (mbit in [4, 8, 16, 32, 64, 128]):
		return false
	if not _checksums_ok(data, 0, HDR_CSUM, HDR_CSUM):
		return false
	return _be16(data, HDR_SIZE_MB) == mbit


## True when the card's strings are Shift-JIS rather than Windows-1252.
static func is_shift_jis(data: PackedByteArray) -> bool:
	return data.size() > HDR_ENCODING + 1 and _be16(data, HDR_ENCODING) == 1


# --- A blank card -------------------------------------------------------------

## A freshly formatted, empty card of `size_mb` Mbit.
##
## Mirrors GCMemcard::Format plus the three block constructors it uses, which
## disagree with each other about fill in a way that matters: the header and
## directory blocks are 0xFF-filled and the BAT block is ZERO-filled, and the
## directory's blank checksum is the constant 0xF003 rather than something
## derived. Data blocks are 0xFF.
##
## `format_time` is seconds since the GameCube epoch and seeds the card serial.
## It is a parameter so a test can produce a card byte-for-byte twice.
static func blank_image(size_mb := MBIT_251, format_time := 0) -> PackedByteArray:
	var blocks := size_mb * BLOCKS_PER_MBIT
	var img := PackedByteArray()
	img.resize(blocks * BLOCK_SIZE)
	img.fill(0xFF)

	# Header. The serial is the Nintendo LCG over the console's flash id, which
	# we do not have and do not need — it only feeds PSO/F-Zero GX copy
	# protection, which Dolphin re-derives against the card on import. A zero
	# flash id is a valid input to the same algorithm.
	var rand := format_time
	for i in 12:
		rand = ((rand * 0x41C64E6D) + 0x3039) >> 16
		img[i] = rand & 0xFF
		rand = (((rand * 0x41C64E6D) + 0x3039) >> 16) & 0x7FFF
	for i in 8:
		img[0x0C + i] = (format_time >> (8 * (7 - i))) & 0xFF
	for i in range(0x14, 0x22):
		img[i] = 0
	_put_be16(img, HDR_SIZE_MB, size_mb)
	_put_be16(img, HDR_ENCODING, 0)
	_fix_checksums(img, 0, HDR_CSUM, HDR_CSUM)

	# Directory and its backup: every entry unused (0xFF), counter 0, and the
	# fixed blank checksum pair.
	for b: int in [1, 2]:
		var o := b * BLOCK_SIZE
		_put_be16(img, o + DIR_UPDATE, 0)
		_put_be16(img, o + DIR_CSUM, 0xF003)
		_put_be16(img, o + DIR_CSUM + 2, 0)

	# BAT and its backup: zero-filled, every block free.
	for b: int in [3, 4]:
		var o := b * BLOCK_SIZE
		for i in BLOCK_SIZE:
			img[o + i] = 0
		_put_be16(img, o + BAT_FREE, blocks - SYSTEM_BLOCKS)
		_put_be16(img, o + BAT_LAST_ALLOC, SYSTEM_BLOCKS - 1)
		_fix_checksums(img, o + BAT_UPDATE, BLOCK_SIZE - BAT_UPDATE, o + BAT_CSUM)

	return img


# --- Reading the saves on a card ----------------------------------------------

## True when directory entry `index` holds a save. An unused entry is all-0xFF,
## which is what the gamecode reads as.
static func _entry_used(data: PackedByteArray, dir_off: int, index: int) -> bool:
	var e := dir_off + index * DENTRY_SIZE
	if e + DENTRY_SIZE > data.size():
		return false
	for i in 4:
		if data[e + E_GAMECODE + i] != 0xFF:
			return true
	return false


## Every save on the card, in directory order. See CardFormat.list_saves for the
## keys; `block` is the DIRECTORY INDEX here, which is the handle every other
## call takes — a GameCube save is identified by its directory entry, not by
## where its data happens to sit.
static func list_saves(data: PackedByteArray, with_icons := true) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not is_card_image(data):
		return out
	var dir_off := dir_offset(data)
	var sjis := is_shift_jis(data)
	for i in DIR_ENTRIES:
		if not _entry_used(data, dir_off, i):
			continue
		var e := dir_off + i * DENTRY_SIZE
		var gamecode := _ascii(data.slice(e + E_GAMECODE, e + E_GAMECODE + 4))
		var maker := _ascii(data.slice(e + E_MAKERCODE, e + E_MAKERCODE + 2))
		var entry := {
			"name": _ascii(data.slice(e + E_FILENAME, e + E_FILENAME + 32)),
			"serial": gamecode + maker,
			"title": _title_of(data, e, sjis),
			"blocks": _be16(data, e + E_BLOCKS),
			"block": i,
			"icons": [],
			"banner": null,
		}
		if with_icons:
			entry["icons"] = _icons(data, e)
			entry["banner"] = _banner(data, e)
		out.append(entry)
	return out


## The directory index of the save with this filename, or -1.
static func block_of(data: PackedByteArray, name: String) -> int:
	for s: Dictionary in list_saves(data, false):
		if str(s["name"]) == name:
			return int(s["block"])
	return -1


## The card blocks one save occupies, in link order.
##
## Follows the BAT chain rather than assuming the run is contiguous. Dolphin's
## own allocator only ever produces contiguous runs, but the format is a linked
## list and a card written by real hardware need not be — and a walk that assumed
## otherwise would silently read another save's data.
##
## Defensive against a corrupt chain: an out-of-range link, or one revisiting a
## block already seen, ends the walk instead of looping for ever.
static func save_chain(data: PackedByteArray, first_block: int) -> Array[int]:
	var out: Array[int] = []
	if not is_card_image(data):
		return out
	var bat := bat_offset(data)
	var blocks := card_blocks(data)
	var seen := {}
	var b := first_block
	while b >= SYSTEM_BLOCKS and b < blocks and not seen.has(b):
		seen[b] = true
		out.append(b)
		var nxt := _be16(data, bat + BAT_MAP + (b - SYSTEM_BLOCKS) * 2)
		if nxt == LINK_LAST or nxt == LINK_FREE:
			break
		b = nxt
	return out


## One save lifted off a card as a standalone .gci — its 64-byte directory entry
## followed by its data blocks in link order. That is what every GameCube save
## tool reads, and exactly what putting it back needs.
##
## The entry's first-block field is rewritten to 5 rather than carried. Those two
## bytes say where the save happened to SIT, so leaving them in would make the
## file's hash a fact about the card instead of about the save: relocating it
## would look like a change and re-upload it, and the restore path's verify —
## which re-extracts and compares — would fail the moment a save landed anywhere
## but its original blocks. insert_save rewrites them for wherever it puts the
## save, so nothing is lost.
static func extract_save(data: PackedByteArray, index: int) -> PackedByteArray:
	var out := PackedByteArray()
	if not is_card_image(data) or index < 0 or index >= DIR_ENTRIES:
		return out
	var dir_off := dir_offset(data)
	if not _entry_used(data, dir_off, index):
		return out
	var e := dir_off + index * DENTRY_SIZE
	var n := _be16(data, e + E_BLOCKS)
	var chain := save_chain(data, _be16(data, e + E_FIRSTBLK))
	if n <= 0 or chain.size() != n:
		return out
	out.append_array(data.slice(e, e + DENTRY_SIZE))
	_put_be16(out, E_FIRSTBLK, SYSTEM_BLOCKS)
	for b in chain:
		out.append_array(data.slice(b * BLOCK_SIZE, (b + 1) * BLOCK_SIZE))
	return out


## Does this look like a GameCube save rather than some other console's?
##
## Shape only, and deliberately so: a .gci is a directory entry plus whole
## blocks, the entry's block count has to agree with the file's length, and the
## entry has to name a game and a file. Anything that passes all three is a save
## this card can hold.
static func is_gci(gci: PackedByteArray) -> bool:
	if gci.size() <= DENTRY_SIZE or (gci.size() - DENTRY_SIZE) % BLOCK_SIZE != 0:
		return false
	@warning_ignore("integer_division")
	var n: int = (gci.size() - DENTRY_SIZE) / BLOCK_SIZE
	if _be16(gci, E_BLOCKS) != n or n > BAT_SIZE:
		return false
	var unused := true
	for i in 4:
		if gci[E_GAMECODE + i] != 0xFF:
			unused = false
	if unused:
		return false
	return not _ascii(gci.slice(E_FILENAME, E_FILENAME + 32)).is_empty()


# --- Changing a card ----------------------------------------------------------
#
# Every mutation returns a NEW image and never touches the one handed in, so a
# caller can parse the result and satisfy itself before writing anything to disk.
# A card is one file holding many games' saves: a wrong link or checksum here
# does not spoil the save being edited, it spoils every save on the card.


## Rewrite both copies of the directory and both of the BAT from one edited copy,
## bumping their update counters together.
##
## Both copies always, and always in step. Writing one and leaving the other is
## how a card ends up with two disagreeing directories, and which one the console
## then believes depends on a counter that no longer means anything.
static func _commit(img: PackedByteArray, dir: PackedByteArray,
		bat: PackedByteArray) -> PackedByteArray:
	var counter := (_be16(dir, DIR_UPDATE) + 1) & 0xFFFF
	_put_be16(dir, DIR_UPDATE, counter)
	_fix_checksums(dir, 0, DIR_CSUM, DIR_CSUM)
	_put_be16(bat, BAT_UPDATE, counter)
	_fix_checksums(bat, BAT_UPDATE, BLOCK_SIZE - BAT_UPDATE, BAT_CSUM)
	var out := img
	for b: int in [1, 2]:
		out = out.slice(0, b * BLOCK_SIZE) + dir + out.slice((b + 1) * BLOCK_SIZE)
	for b: int in [3, 4]:
		out = out.slice(0, b * BLOCK_SIZE) + bat + out.slice((b + 1) * BLOCK_SIZE)
	return out


## Free the blocks one save occupies. Returns the new image, or empty when
## `index` is not a save.
##
## Only the directory and the BAT are rewritten; the data blocks are left exactly
## as they were, which is what the console does too and means a mistake here
## cannot reach another save's contents.
static func delete_save(data: PackedByteArray, index: int) -> PackedByteArray:
	if not is_card_image(data) or index < 0 or index >= DIR_ENTRIES:
		return PackedByteArray()
	var dir_off := dir_offset(data)
	if not _entry_used(data, dir_off, index):
		return PackedByteArray()

	var dir := data.slice(dir_off, dir_off + BLOCK_SIZE)
	var bat_off := bat_offset(data)
	var bat := data.slice(bat_off, bat_off + BLOCK_SIZE)
	var chain := save_chain(data, _be16(data, dir_off + index * DENTRY_SIZE + E_FIRSTBLK))

	for b in chain:
		_put_be16(bat, BAT_MAP + (b - SYSTEM_BLOCKS) * 2, LINK_FREE)
	_put_be16(bat, BAT_FREE, mini(_be16(bat, BAT_FREE) + chain.size(),
		total_blocks(data)))

	var e := index * DENTRY_SIZE
	for i in DENTRY_SIZE:
		dir[e + i] = 0xFF
	return _commit(data.duplicate(), dir, bat)


## How many blocks are still free.
static func free_blocks(data: PackedByteArray) -> int:
	if not is_card_image(data):
		return 0
	return mini(_be16(data, bat_offset(data) + BAT_FREE), total_blocks(data))


## Splice a .gci into a card. Returns the new image, or empty when the file is
## malformed, a save of that name is already there, the directory is full, or
## there are not enough free blocks.
##
## Blocks are taken wherever they are free and chained through the BAT, so a save
## can land scattered. Dolphin's own allocator only ever writes contiguous runs,
## but the format is a linked list and taking any free block is both valid and
## the only way to use a card that has been written and deleted a few times.
static func insert_save(data: PackedByteArray, gci: PackedByteArray) -> PackedByteArray:
	if not is_card_image(data) or not is_gci(gci):
		return PackedByteArray()
	@warning_ignore("integer_division")
	var n: int = (gci.size() - DENTRY_SIZE) / BLOCK_SIZE
	var name := _ascii(gci.slice(E_FILENAME, E_FILENAME + 32))
	if block_of(data, name) != -1:
		return PackedByteArray()

	var dir_off := dir_offset(data)
	var slot := -1
	for i in DIR_ENTRIES:
		if not _entry_used(data, dir_off, i):
			slot = i
			break
	if slot < 0:
		return PackedByteArray()

	var bat_off := bat_offset(data)
	var blocks := card_blocks(data)
	var free: Array[int] = []
	for b in range(SYSTEM_BLOCKS, blocks):
		if _be16(data, bat_off + BAT_MAP + (b - SYSTEM_BLOCKS) * 2) == LINK_FREE:
			free.append(b)
			if free.size() == n:
				break
	if free.size() < n:
		return PackedByteArray()

	var dir := data.slice(dir_off, dir_off + BLOCK_SIZE)
	var bat := data.slice(bat_off, bat_off + BLOCK_SIZE)

	var e := slot * DENTRY_SIZE
	for i in DENTRY_SIZE:
		dir[e + i] = gci[i]
	_put_be16(dir, e + E_FIRSTBLK, free[0])
	_put_be16(dir, e + E_BLOCKS, n)

	for i in n:
		_put_be16(bat, BAT_MAP + (free[i] - SYSTEM_BLOCKS) * 2,
			LINK_LAST if i == n - 1 else free[i + 1])
	_put_be16(bat, BAT_FREE, maxi(_be16(bat, BAT_FREE) - n, 0))
	_put_be16(bat, BAT_LAST_ALLOC, free[n - 1])

	var out := data.duplicate()
	for i in n:
		# slice/append copy in C++; a per-byte GDScript loop here would be 8k
		# interpreted iterations per block, on a path a menu tap waits for.
		var dst := free[i] * BLOCK_SIZE
		var src := DENTRY_SIZE + i * BLOCK_SIZE
		out = out.slice(0, dst) + gci.slice(src, src + BLOCK_SIZE) \
			+ out.slice(dst + BLOCK_SIZE)
	return _commit(out, dir, bat)


# --- Strings ------------------------------------------------------------------

static func _ascii(raw: PackedByteArray) -> String:
	var s := ""
	for b in raw:
		if b == 0 or b == 0xFF:
			break
		s += char(b)
	return s.strip_edges()


## The save's own two comment lines, joined. Line 1 is the game, line 2 the
## save's description, and they live at an offset recorded in the entry that
## points INTO the save's own data rather than into the directory.
static func _title_of(data: PackedByteArray, entry_off: int, sjis: bool) -> String:
	var addr := _be32(data, entry_off + E_COMMENTS)
	if addr == 0xFFFFFFFF:
		return ""
	var first := _be16(data, entry_off + E_FIRSTBLK)
	var chain := save_chain(data, first)
	@warning_ignore("integer_division")
	var block_index: int = addr / BLOCK_SIZE
	if block_index >= chain.size():
		return ""
	var off := chain[block_index] * BLOCK_SIZE + (addr % BLOCK_SIZE)
	if off + 64 > data.size():
		return ""
	var one := _decode(data.slice(off, off + 32), sjis)
	var two := _decode(data.slice(off + 32, off + 64), sjis)
	if one.is_empty():
		return two
	return one if two.is_empty() else "%s — %s" % [one, two]


## Windows-1252 or Shift-JIS, per the card's own encoding field.
##
## The Western path is the common one and is trivial: bytes below 0x80 are ASCII
## and 0xA0-0xFF are their own Unicode code points. Godot has no Shift-JIS
## decoder, so a Japanese card gets the same treatment ps1_card.gd gives one —
## the full-width forms, which are contiguous, map to their ASCII equivalents and
## real kana and kanji are dropped rather than guessed. The filename is always
## there as a fallback.
static func _decode(raw: PackedByteArray, sjis: bool) -> String:
	var s := ""
	var i := 0
	while i < raw.size():
		var b := raw[i]
		if b == 0:
			break
		if b < 0x80:
			s += char(b)
			i += 1
			continue
		if not sjis:
			# 0x80-0x9F is where CP1252 and Latin-1 disagree; dropped rather
			# than guessed, which costs a curly quote and nothing else.
			if b >= 0xA0:
				s += char(b)
			i += 1
			continue
		if i + 1 >= raw.size():
			break
		var w := (b << 8) | raw[i + 1]
		i += 2
		if w >= 0x824F and w <= 0x8258:
			s += char(0x30 + (w - 0x824F))
		elif w >= 0x8260 and w <= 0x8279:
			s += char(0x41 + (w - 0x8260))
		elif w >= 0x8281 and w <= 0x829A:
			s += char(0x61 + (w - 0x8281))
		elif w == 0x8140:
			s += " "
	return s.strip_edges()


# --- Pictures -----------------------------------------------------------------

## One RGB5A3 word as a colour. The top bit picks the encoding: set means opaque
## RGB555, clear means ARGB3444.
##
## Dolphin composites the translucent case onto black and forces alpha to 0xFF.
## We keep the real alpha instead, so an icon gets the cut-out background a
## PlayStation icon gets.
static func _rgb5a3(v: int) -> Color:
	if v & 0x8000:
		return Color(LUT5[(v >> 10) & 0x1F] / 255.0, LUT5[(v >> 5) & 0x1F] / 255.0,
			LUT5[v & 0x1F] / 255.0, 1.0)
	return Color(LUT4[(v >> 8) & 0x0F] / 255.0, LUT4[(v >> 4) & 0x0F] / 255.0,
		LUT4[v & 0x0F] / 255.0, LUT3[(v >> 12) & 0x07] / 255.0)


## Decode a CI8 image: 8-bit palette indices in 8-wide by 4-tall tiles, into a
## 256-entry RGB5A3 palette.
##
## The tile size is the trap. CI8 tiles are 8x4 and RGB5A3 tiles are 4x4, and
## getting either wrong produces a scrambled picture that still looks like an
## image — which is why these were verified by rendering a real save's icon and
## banner rather than by reading the loop.
static func _decode_ci8(data: PackedByteArray, src: int, pal: int,
		w: int, h: int) -> Image:
	var px := PackedByteArray()
	px.resize(w * h * 4)
	var i := src
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			for iy in 4:
				for ix in 8:
					var idx := data[i + ix]
					var c := _rgb5a3(_be16(data, pal + idx * 2))
					var o := ((y + iy) * w + x + ix) * 4
					px[o] = int(c.r * 255.0)
					px[o + 1] = int(c.g * 255.0)
					px[o + 2] = int(c.b * 255.0)
					px[o + 3] = int(c.a * 255.0)
				i += 8
			x += 8
		y += 4
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)


## Decode an RGB5A3 image: 16-bit colours in 4-wide by 4-tall tiles.
static func _decode_rgb5a3(data: PackedByteArray, src: int, w: int, h: int) -> Image:
	var px := PackedByteArray()
	px.resize(w * h * 4)
	var i := src
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			for iy in 4:
				for ix in 4:
					var c := _rgb5a3(_be16(data, i + ix * 2))
					var o := ((y + iy) * w + x + ix) * 4
					px[o] = int(c.r * 255.0)
					px[o + 1] = int(c.g * 255.0)
					px[o + 2] = int(c.b * 255.0)
					px[o + 3] = int(c.a * 255.0)
				i += 8
			x += 4
		y += 4
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)


## Absolute byte offset of a save's image data, or -1 when it has none. The
## entry's image_offset counts from the START OF THE SAVE, not from the card, so
## it has to be walked through the block chain.
static func _image_base(data: PackedByteArray, entry_off: int) -> int:
	var addr := _be32(data, entry_off + E_IMAGE_OFF)
	if addr == 0xFFFFFFFF:
		return -1
	var chain := save_chain(data, _be16(data, entry_off + E_FIRSTBLK))
	@warning_ignore("integer_division")
	var block_index: int = addr / BLOCK_SIZE
	if block_index >= chain.size():
		return -1
	return chain[block_index] * BLOCK_SIZE + (addr % BLOCK_SIZE)


## How many bytes the banner occupies, so the icons can be found after it.
static func _banner_bytes(flags: int) -> int:
	match flags & 0x03:
		1:  return BANNER_W * BANNER_H + PALETTE_ENTRIES * 2
		2:  return BANNER_W * BANNER_H * 2
		_:  return 0


## The save's 96x32 banner, or null. The PlayStation has no equivalent; this is
## the game's own logo and comes free once the decoders exist.
static func _banner(data: PackedByteArray, entry_off: int) -> Image:
	var base := _image_base(data, entry_off)
	if base < 0:
		return null
	var flags := data[entry_off + E_BANNER]
	var n := BANNER_W * BANNER_H
	match flags & 0x03:
		1:
			if base + n + PALETTE_ENTRIES * 2 > data.size():
				return null
			return _decode_ci8(data, base, base + n, BANNER_W, BANNER_H)
		2:
			if base + n * 2 > data.size():
				return null
			return _decode_rgb5a3(data, base, BANNER_W, BANNER_H)
	return null


## The save's animation frames as 32x32 RGBA images (up to 8).
##
## Per frame, two bits of icon_format say how it is stored and two bits of
## animation_speed say how long it lasts. A frame DELAY of zero ends the list —
## not a format of zero, which is a frame that is present and unreadable. Getting
## that the wrong way round truncates every icon whose first frame is CI8.
##
## Frames that share a palette have it placed after ALL the frame data; a frame
## with its own carries it immediately after itself.
static func _icons(data: PackedByteArray, entry_off: int) -> Array:
	var out: Array = []
	var base := _image_base(data, entry_off)
	if base < 0:
		return out
	base += _banner_bytes(data[entry_off + E_BANNER])

	var fmt_bits := _be16(data, entry_off + E_ICON_FMT)
	var anim_bits := _be16(data, entry_off + E_ANIM)
	var pixels := ICON_W * ICON_H

	var offsets: Array[int] = []
	var formats: Array[int] = []
	var length := 0
	var shared := false
	for i in MAX_ICON_FRAMES:
		if (anim_bits >> (2 * i)) & 0x03 == 0:
			break
		var f := (fmt_bits >> (2 * i)) & 0x03
		offsets.append(length)
		formats.append(f)
		match f:
			1:
				length += pixels
				shared = true
			2:  length += pixels * 2
			3:  length += pixels + PALETTE_ENTRIES * 2
	if formats.is_empty():
		return out

	var shared_pal := base + length
	if shared and shared_pal + PALETTE_ENTRIES * 2 > data.size():
		return out

	for i in formats.size():
		var src := base + offsets[i]
		match formats[i]:
			1:
				if src + pixels <= data.size():
					out.append(_decode_ci8(data, src, shared_pal, ICON_W, ICON_H))
			2:
				if src + pixels * 2 <= data.size():
					out.append(_decode_rgb5a3(data, src, ICON_W, ICON_H))
			3:
				if src + pixels + PALETTE_ENTRIES * 2 <= data.size():
					out.append(_decode_ci8(data, src, src + pixels, ICON_W, ICON_H))
	return out

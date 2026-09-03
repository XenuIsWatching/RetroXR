## N64Card — the Controller Pak's 32 KiB image, as the N64 lays it out.
##
## 128 pages of 256 bytes. Page 0 carries the pak's ID block in four copies,
## pages 1 and 2 are the index table and its backup, pages 3 and 4 are the note
## table, and pages 5..127 are the 123 the player can actually fill.
##
## Measured against mupen64plus-core's own `format_mempak`, which is the only
## formatter a pak in this room will ever meet: nothing in that core validates a
## pak, so a blank that is subtly wrong does not error, it just makes the game
## offer to format the pak the player just bought.
##
## Static and scene-free on purpose, the same split PS1Card and GCCard take —
## this half is the measured layout and is the part worth testing without a
## scene. N64CardFormat is the adapter over it.
class_name N64Card

const PAGE_SIZE := 256
const PAGE_COUNT := 128
const CARD_SIZE := PAGE_SIZE * PAGE_COUNT

const INODE_PAGE := 1
const INODE_BACKUP_PAGE := 2
const NOTE_PAGE := 3
const DATA_START_PAGE := 5

const NOTE_SIZE := 32
const NOTE_COUNT := 16

## Where page 0's four copies of the ID block sit. Blocks 0, 2, 5 and 7 are
## reserved and stay zeroed.
const ID_BLOCK_OFFSETS := [32, 96, 128, 192]

## Where the four paks sit inside the one SAVE_RAM block both N64 cores publish,
## measured from libretro_memory.h's save_memory_data: eeprom (0x800), then four
## 32 KiB paks, then sram and flashram. parallel_n64 appends a 64DD region after
## those, which changes the block's total size but not where a pak begins.
##
## Here rather than beside the code that calls the core, so the measurement has
## one home: the same numbers slice a cartridge's .srm for the importer below.
const SRM_PORTS := 4
const SRM_BASE_OFFSET := 0x800

const SERIAL_SIZE := 24
const DEVICE_ID := 0x0001
const BANKS := 0x01
const VERSION := 0x00

## The constant the ID block's inverse checksum is taken from.
const ID_SUM_BASE := 0xFFF2

const INODE_FREE := 0x0003
const INODE_LAST := 0x0001

## A note's own header, prepended to its pages to make one liftable file.
const NOTE_NAME_OFFSET := 0x10
const NOTE_NAME_LEN := 16
const NOTE_EXT_OFFSET := 0x0C
const NOTE_EXT_LEN := 4
const NOTE_START_OFFSET := 0x06


static func usable_pages() -> int:
	return PAGE_COUNT - DATA_START_PAGE


# --- Bytes --------------------------------------------------------------------

static func _get_be16(data: PackedByteArray, offset: int) -> int:
	return (data[offset] << 8) | data[offset + 1]


static func _put_be16(data: PackedByteArray, offset: int, value: int) -> void:
	data[offset] = (value >> 8) & 0xFF
	data[offset + 1] = value & 0xFF


# --- The N64's own character set ----------------------------------------------

## A note name is not ASCII. The pak stores its own indices, and a game that
## wrote "MARIO" left 0x26 0x1A 0x2B 0x22 0x28 behind.
static func _to_ascii(code: int) -> String:
	if code == 0:
		return ""
	if code == 0x0F:
		return " "
	if code >= 0x10 and code <= 0x19:
		return String.chr(0x30 + (code - 0x10))
	if code >= 0x1A and code <= 0x33:
		return String.chr(0x41 + (code - 0x1A))
	const PUNCTUATION := "!\"#'*+,-./:=?@"
	if code >= 0x34 and code <= 0x41:
		return PUNCTUATION[code - 0x34]
	return " "


static func _from_ascii(ch: String) -> int:
	if ch == " ":
		return 0x0F
	var c: int = ch.unicode_at(0)
	if c >= 0x30 and c <= 0x39:
		return 0x10 + (c - 0x30)
	if c >= 0x61 and c <= 0x7A:
		c -= 0x20
	if c >= 0x41 and c <= 0x5A:
		return 0x1A + (c - 0x41)
	const PUNCTUATION := "!\"#'*+,-./:=?@"
	var idx: int = PUNCTUATION.find(ch)
	if idx >= 0:
		return 0x34 + idx
	return 0x0F


static func _decode_field(data: PackedByteArray, offset: int, length: int) -> String:
	var out := ""
	for i in length:
		out += _to_ascii(data[offset + i])
	return out.strip_edges()


static func _encode_field(text: String, length: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(length)
	for i in length:
		out[i] = _from_ascii(text[i]) if i < text.length() else 0x00
	return out


# --- Formatting ---------------------------------------------------------------

## The 32-byte ID block. An empty serial mints a random one, which is what real
## hardware carries; the deterministic form exists so a test can diff this
## against what the core writes.
static func id_block(serial := PackedByteArray()) -> PackedByteArray:
	var block := PackedByteArray()
	block.resize(NOTE_SIZE)

	var id := serial
	if id.size() != SERIAL_SIZE:
		id = PackedByteArray()
		id.resize(SERIAL_SIZE)
		for i in SERIAL_SIZE:
			id[i] = randi() & 0xFF
	for i in SERIAL_SIZE:
		block[i] = id[i]

	_put_be16(block, 24, DEVICE_ID)
	block[26] = BANKS
	block[27] = VERSION

	var accumulator := 0
	for i in range(0, 28, 2):
		accumulator = (accumulator + _get_be16(block, i)) & 0xFFFF
	_put_be16(block, 28, accumulator)
	_put_be16(block, 30, (ID_SUM_BASE - accumulator) & 0xFFFF)
	return block


static func _id_block_valid(data: PackedByteArray, offset: int) -> bool:
	var accumulator := 0
	for i in range(0, 28, 2):
		accumulator = (accumulator + _get_be16(data, offset + i)) & 0xFFFF
	if _get_be16(data, offset + 28) != accumulator:
		return false
	return _get_be16(data, offset + 30) == ((ID_SUM_BASE - accumulator) & 0xFFFF)


## The index table's single check byte: the low byte of the sum of every entry
## from the first usable page on.
static func _inode_checksum(data: PackedByteArray, base: int) -> int:
	var sum := 0
	for i in range(base + DATA_START_PAGE * 2, base + PAGE_SIZE):
		sum += data[i]
	return sum & 0xFF


static func _seal_inode(data: PackedByteArray) -> void:
	var base := INODE_PAGE * PAGE_SIZE
	data[base] = 0
	data[base + 1] = _inode_checksum(data, base)
	for i in PAGE_SIZE:
		data[INODE_BACKUP_PAGE * PAGE_SIZE + i] = data[base + i]


static func blank_image(serial := PackedByteArray()) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(CARD_SIZE)

	var block := id_block(serial)
	for offset: int in ID_BLOCK_OFFSETS:
		for i in NOTE_SIZE:
			data[offset + i] = block[i]

	var base := INODE_PAGE * PAGE_SIZE
	for page in range(DATA_START_PAGE, PAGE_COUNT):
		_put_be16(data, base + page * 2, INODE_FREE)
	_seal_inode(data)
	return data


static func is_card_image(data: PackedByteArray) -> bool:
	if data.size() != CARD_SIZE:
		return false
	for offset: int in ID_BLOCK_OFFSETS:
		if _id_block_valid(data, offset):
			return true
	return false


# --- The index table ----------------------------------------------------------

static func _inode(data: PackedByteArray, page: int) -> int:
	return _get_be16(data, INODE_PAGE * PAGE_SIZE + page * 2)


static func _set_inode(data: PackedByteArray, page: int, value: int) -> void:
	_put_be16(data, INODE_PAGE * PAGE_SIZE + page * 2, value)


## Every page one note occupies, in order. Empty when the chain leaves the card
## or loops, which a corrupt pak can do and must not hang the menu.
static func _chain(data: PackedByteArray, start_page: int) -> Array[int]:
	var pages: Array[int] = []
	var page := start_page
	while pages.size() < usable_pages():
		if page < DATA_START_PAGE or page >= PAGE_COUNT:
			return []
		if pages.has(page):
			return []
		pages.append(page)
		var next := _inode(data, page)
		if next == INODE_LAST:
			return pages
		page = next
	return []


static func free_blocks(data: PackedByteArray) -> int:
	if data.size() != CARD_SIZE:
		return 0
	var free := 0
	for page in range(DATA_START_PAGE, PAGE_COUNT):
		if _inode(data, page) == INODE_FREE:
			free += 1
	return free


static func _free_pages(data: PackedByteArray, wanted: int) -> Array[int]:
	var pages: Array[int] = []
	for page in range(DATA_START_PAGE, PAGE_COUNT):
		if pages.size() >= wanted:
			break
		if _inode(data, page) == INODE_FREE:
			pages.append(page)
	return pages


# --- The note table -----------------------------------------------------------

static func _note_offset(index: int) -> int:
	return NOTE_PAGE * PAGE_SIZE + index * NOTE_SIZE


static func _note_name(data: PackedByteArray, offset: int) -> String:
	var name := _decode_field(data, offset + NOTE_NAME_OFFSET, NOTE_NAME_LEN)
	var ext := _decode_field(data, offset + NOTE_EXT_OFFSET, NOTE_EXT_LEN)
	if ext.is_empty():
		return name
	return "%s.%s" % [name, ext]


static func _note_indices(data: PackedByteArray) -> Array[int]:
	var used: Array[int] = []
	for index in NOTE_COUNT:
		var offset := _note_offset(index)
		var start := _get_be16(data, offset + NOTE_START_OFFSET)
		if start < DATA_START_PAGE or start >= PAGE_COUNT:
			continue
		if _note_name(data, offset).is_empty():
			continue
		used.append(index)
	return used


static func list_saves(data: PackedByteArray, _with_icons := true) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if data.size() != CARD_SIZE:
		return out
	for index: int in _note_indices(data):
		var offset := _note_offset(index)
		var start := _get_be16(data, offset + NOTE_START_OFFSET)
		var pages := _chain(data, start)
		if pages.is_empty():
			continue
		out.append({
			"name": _note_name(data, offset),
			"serial": _decode_field(data, offset, 4),
			"title": _note_name(data, offset),
			"blocks": pages.size(),
			"block": start,
			"icons": [],
		})
	return out


static func block_of(data: PackedByteArray, name: String) -> int:
	if data.size() != CARD_SIZE:
		return -1
	for index: int in _note_indices(data):
		var offset := _note_offset(index)
		if _note_name(data, offset) == name:
			return _get_be16(data, offset + NOTE_START_OFFSET)
	return -1


static func _note_index_of(data: PackedByteArray, start_page: int) -> int:
	for index: int in _note_indices(data):
		if _get_be16(data, _note_offset(index) + NOTE_START_OFFSET) == start_page:
			return index
	return -1


# --- One note as a file -------------------------------------------------------

## A lifted note is its 32-byte table entry followed by its pages in chain
## order, so the file describes its own length and can be put back without the
## card it came from.
static func extract_save(data: PackedByteArray, first_page: int) -> PackedByteArray:
	var out := PackedByteArray()
	if data.size() != CARD_SIZE:
		return out
	var index := _note_index_of(data, first_page)
	if index < 0:
		return out
	var pages := _chain(data, first_page)
	if pages.is_empty():
		return out

	var offset := _note_offset(index)
	out.append_array(data.slice(offset, offset + NOTE_SIZE))
	for page: int in pages:
		out.append_array(data.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE))
	return out


static func is_note(bytes: PackedByteArray) -> bool:
	if bytes.size() <= NOTE_SIZE:
		return false
	if (bytes.size() - NOTE_SIZE) % PAGE_SIZE != 0:
		return false
	var pages := (bytes.size() - NOTE_SIZE) / PAGE_SIZE
	if pages > usable_pages():
		return false
	return not _note_name(bytes, 0).is_empty()


static func insert_save(data: PackedByteArray, save: PackedByteArray) -> PackedByteArray:
	var empty := PackedByteArray()
	if data.size() != CARD_SIZE or not is_note(save):
		return empty
	@warning_ignore("integer_division")
	var wanted := (save.size() - NOTE_SIZE) / PAGE_SIZE

	var name := _note_name(save, 0)
	if block_of(data, name) >= 0:
		return empty

	var slot := -1
	var used := _note_indices(data)
	for index in NOTE_COUNT:
		if not used.has(index):
			slot = index
			break
	if slot < 0:
		return empty

	var pages := _free_pages(data, wanted)
	if pages.size() < wanted:
		return empty

	var out := data.duplicate()
	for i in wanted:
		var page: int = pages[i]
		for b in PAGE_SIZE:
			out[page * PAGE_SIZE + b] = save[NOTE_SIZE + i * PAGE_SIZE + b]
		_set_inode(out, page, INODE_LAST if i == wanted - 1 else pages[i + 1])

	var offset := _note_offset(slot)
	for i in NOTE_SIZE:
		out[offset + i] = save[i]
	_put_be16(out, offset + NOTE_START_OFFSET, pages[0])
	_seal_inode(out)
	return out


static func delete_save(data: PackedByteArray, first_page: int) -> PackedByteArray:
	var empty := PackedByteArray()
	if data.size() != CARD_SIZE:
		return empty
	var index := _note_index_of(data, first_page)
	if index < 0:
		return empty
	var pages := _chain(data, first_page)
	if pages.is_empty():
		return empty

	var out := data.duplicate()
	for page: int in pages:
		_set_inode(out, page, INODE_FREE)
	var offset := _note_offset(index)
	for i in NOTE_SIZE:
		out[offset + i] = 0
	_seal_inode(out)
	return out


# --- Rescuing the paks players already have ------------------------------------

## Where port `port`'s pak begins inside a cartridge's .srm.
static func srm_offset(port: int) -> int:
	return SRM_BASE_OFFSET + port * CARD_SIZE


## One port's pak lifted out of a cartridge save, or an empty array when the file
## is too short to hold it.
static func slice_srm(srm: PackedByteArray, port: int) -> PackedByteArray:
	if port < 0 or port >= SRM_PORTS:
		return PackedByteArray()
	var start := srm_offset(port)
	if srm.size() < start + CARD_SIZE:
		return PackedByteArray()
	return srm.slice(start, start + CARD_SIZE)


## Is there anything on this pak worth keeping?
##
## The question the importer has to answer, and "is it all zeroes" is the wrong
## way to ask it: mupen64plus formats all four paks at every load whether or not
## a game ever touched them, so an untouched pak is a VALID, fully formatted,
## entirely empty image rather than a blank one. What makes a pak worth rescuing
## is a note on it.
static func has_notes(data: PackedByteArray) -> bool:
	return is_card_image(data) and not list_saves(data, false).is_empty()


## Build a note file from raw contents, for tests and for anything that wants to
## put a save onto a pak without a pak to copy it off.
static func make_note(name: String, serial: String, payload: PackedByteArray) -> PackedByteArray:
	var pages := maxi(1, ceili(float(payload.size()) / float(PAGE_SIZE)))
	var out := PackedByteArray()
	out.resize(NOTE_SIZE + pages * PAGE_SIZE)

	var code := _encode_field(serial, 4)
	for i in 4:
		out[i] = code[i]
	out[4] = _from_ascii("N")
	out[5] = _from_ascii("A")
	_put_be16(out, NOTE_START_OFFSET, DATA_START_PAGE)

	var label := _encode_field(name, NOTE_NAME_LEN)
	for i in NOTE_NAME_LEN:
		out[NOTE_NAME_OFFSET + i] = label[i]

	for i in payload.size():
		out[NOTE_SIZE + i] = payload[i]
	return out

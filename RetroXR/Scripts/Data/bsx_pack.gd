class_name BsxPack
extends RefCounted

## BsxPack — the 8M Memory Pack a Satellaview programme is downloaded onto.
##
## A `.bs` file IS a pack image: snes9x loads one as content and points FlashROM
## straight at it, so what the player slots in is literally the medium the BS-X
## shell writes to. Most `.bs` in circulation are single programmes carved out of
## a pack (snes9x repairs their block-allocation flags on load, and says so), but
## the format is the same at any length; a full pack is 8 Mbit.
##
## Everything below was MEASURED from real images rather than reasoned about —
## Actraiser (Japan), Arkanoid Doh It Again (Japan) and BS Dragon Quest I (Japan):
##
##   field            Actraiser  Arkanoid  DQ I     accepted
##   [0x10] blocks      0xFF       0x0F     0xFF    any, see below
##   [0x15] map         0x80       0xFC     0x80    0 or (b & 131) == 128
##   [0x16] type        0x90       0x40     0xFF    see is_pack_image
##   [0x17] rom size    0x60       0x63     0xFF
##   [0x18] bank        0x20       0x30     0x20    one of 20/21/30/31
##   [0x1A] fixed       0x33       0x33     0x33    0x33 or 0xFF
##
## The header sits at the LoROM position. All three images have 0xFF at 0xFFC0,
## i.e. nothing at the HiROM one, which is why a pack is detected as LoROM.
##
## Note an all-0xFF image does NOT pass: the bank byte would be 0xFF, which is not
## a valid bank. A blank pack is erased flash PLUS a real header, never just fill.

## 8 Mbit. FLASH_SIZE in bsx.cpp.
const SIZE := 0x100000
## Where the header lives, and how long its title field is.
##
## TWO positions are possible and both occur. A pack formatted empty carries its
## header at the LoROM offset; a programme downloaded onto one can sit at the
## HiROM offset instead -- SUPER BOMBERMAN, measured off a real used pack, is at
## 0xFFC0 with nothing but noise at 0x7FC0. snes9x tests both (bsx.cpp:1273-1274).
##
## Testing only the first is what the three sample images misled this class into
## doing: all three are single programmes carved out of a pack, so all three
## happened to be LoROM. The cost was the worst possible way round -- a pack that
## had actually been WRITTEN to was rejected as not a pack at all.
const HEADER := 0x7FC0
const HEADER_HI := 0xFFC0
const HEADER_OFFSETS: Array[int] = [HEADER, HEADER_HI]
## 16, not the SNES header's 21: BS repurposes 0x7FD0 (offset 0x10) as the block
## allocation byte, which falls INSIDE the title field and truncates it. The real
## images show it -- Actraiser's title is 16 characters and then that byte.
const TITLE_LEN := 16
## Flash erases to 0xFF; snes9x's own block-erase writes exactly this.
const ERASED := 0xFF

const OFF_BLOCK_ALLOC := 0x10
const OFF_MAP := 0x15
const OFF_TYPE := 0x16
const OFF_ROM_SIZE := 0x17
const OFF_BANK := 0x18
const OFF_FIXED := 0x1A

## The values a freshly formatted pack carries. `type`/`rom size` are both 0xFF,
## which is one of the two combinations is_bsx accepts outright and the one BS
## Dragon Quest I ships — the least assuming choice for an image with no
## programme on it yet. Bank 0x20 and map 0x80 are what two of the three samples
## use, and 0x20 also makes snes9x read the pack as PSRAM-mode rather than flash
## (FlashMode = (header[0x18] & 0xEF) == 0x20 ? FALSE : TRUE), matching all three.
const BLANK_BLOCK_ALLOC := 0xFF
const BLANK_MAP := 0x80
const BLANK_TYPE := 0xFF
const BLANK_ROM_SIZE := 0xFF
const BLANK_BANK := 0x20
const BLANK_FIXED := 0x33

## What an unused pack calls itself, in the header's 21-byte title field.
const BLANK_TITLE := "MEMORY PACK"


## A blank, formatted 8 Mbit pack: erased flash with a valid BS header.
static func blank_image() -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(SIZE)
	data.fill(ERASED)
	var title := BLANK_TITLE.to_ascii_buffer()
	for i in TITLE_LEN:
		# Space-padded, the way the real images pad theirs.
		data[HEADER + i] = title[i] if i < title.size() else 0x20
	data[HEADER + OFF_BLOCK_ALLOC] = BLANK_BLOCK_ALLOC
	data[HEADER + OFF_MAP] = BLANK_MAP
	data[HEADER + OFF_TYPE] = BLANK_TYPE
	data[HEADER + OFF_ROM_SIZE] = BLANK_ROM_SIZE
	data[HEADER + OFF_BANK] = BLANK_BANK
	data[HEADER + OFF_FIXED] = BLANK_FIXED
	return data


## Write a new blank pack into `dir_path`. Returns its path, or "" on failure.
##
## A pack's NAME IS ITS FILENAME, exactly as a memory card's is, so the shelf can
## be managed from outside RetroXR and a pack read as ordinary `.bs` content by
## anything else. Packs live in the broadcast folder rather than under save/ —
## snes9x resolves its packet directory from the loaded ROM's own folder, so a
## pack anywhere else boots and receives nothing.
static func create_blank(dir_path: String, base_name := BLANK_TITLE) -> String:
	if DirAccess.make_dir_recursive_absolute(dir_path) != OK \
			and not DirAccess.dir_exists_absolute(dir_path):
		return ""
	var path := dir_path.path_join(unique_name(dir_path, base_name) + ".bs")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("BsxPack: cannot write %s" % path)
		return ""
	f.store_buffer(blank_image())
	f.close()
	return path


## `base`, or `base 2`, `base 3`… until no pack in `dir_path` holds that name.
## Two packs sharing a filename would be one medium wearing two labels.
static func unique_name(dir_path: String, base: String) -> String:
	var name := SramPaths.sanitize_card_name(base)
	if name == "MEMORY CARD":       # the sanitiser's own empty-input fallback
		name = BLANK_TITLE
	if not FileAccess.file_exists(dir_path.path_join(name + ".bs")):
		return name
	var n := 2
	while FileAccess.file_exists(dir_path.path_join("%s %d" % [name, n]) + ".bs"):
		n += 1
	return "%s %d" % [name, n]


## snes9x's is_bsx(), re-implemented against the same header bytes.
##
## Kept here rather than inferred at the call site because this predicate decides
## whether the core treats a file as BS content at all: fail it and `Settings.BS`
## stays false and the image loads as an ordinary SNES ROM — which boots, and is
## not a memory pack. Mirrors bsx.cpp:1414 exactly, including the bank whitelist,
## which is narrower than it looks: only 0x20, 0x21, 0x30 and 0x31.
static func is_pack_image(data: PackedByteArray) -> bool:
	return header_offset(data) >= 0


## Where this image's BS header is, or -1 when it carries none.
static func header_offset(data: PackedByteArray) -> int:
	for off: int in HEADER_OFFSETS:
		if data.size() >= off + 32 and _header_is_bsx(data, off):
			return off
	return -1


static func _header_is_bsx(data: PackedByteArray, off: int) -> bool:
	var fixed := data[off + OFF_FIXED]
	if not (fixed == 0x33 or fixed == 0xFF):
		return false
	var map_mode := data[off + OFF_MAP]
	if map_mode != 0 and (map_mode & 131) != 128:
		return false
	if not _valid_normal_bank(data[off + OFF_BANK]):
		return false
	var kind := data[off + OFF_TYPE]
	var rom_size := data[off + OFF_ROM_SIZE]
	if kind == 0 and rom_size == 0:
		return true
	if kind == 0xFF and rom_size == 0xFF:
		return true
	return (kind & 0x0F) == 0 and ((kind >> 4) - 1) < 12


static func _valid_normal_bank(b: int) -> bool:
	return b == 0x20 or b == 0x21 or b == 0x30 or b == 0x31


## The title a pack carries, trimmed. Shift-JIS on a Japanese programme, so this
## is for display only and never for identity — the filename is the identity, as
## it is for a memory card.
static func title_of(data: PackedByteArray) -> String:
	var off := header_offset(data)
	if off < 0:
		return ""
	return _clean_title(data.slice(off, off + TITLE_LEN))


## The title without opening the whole megabyte: a shelf redraws per row, and the
## only bytes wanted are 16 of them.
static func title_of_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var best := ""
	for off: int in HEADER_OFFSETS:
		if f.get_length() < off + 32:
			continue
		f.seek(off)
		var head := f.get_buffer(32)
		if head.size() == 32 and _header_is_bsx(head, 0):
			best = _clean_title(head.slice(0, TITLE_LEN))
			if not best.is_empty():
				break
	f.close()
	return best


## A title is only sometimes text we can read. A Japanese broadcast writes its
## own in Shift-JIS, which has no decoder here and comes back as mojibake, so
## anything that is not plain printable ASCII is dropped and a title that
## survives as mostly nothing is reported as no title at all -- better a pack
## labelled only by its filename than one labelled with rubbish.
static func _clean_title(raw: PackedByteArray) -> String:
	var out := ""
	for b: int in raw:
		if b >= 0x20 and b < 0x7F:
			out += char(b)
	out = out.strip_edges()
	return out if out.length() >= 3 else ""

## True when `path` is a pack rather than the BS-X shell that reads one. Both live
## in the satellaview folder and only the extension separates them, which is the
## same rule MediaDimensions.cart_size uses to size them.
static func is_pack_path(path: String) -> bool:
	return path.get_extension().to_lower() == "bs"


## What a pack is CALLED on a shelf: the programme written on it, or that it is
## empty. Never the filename -- a pack is identified by what is on it, and a name
## typed over that would be a second label free to disagree with the medium.
const EMPTY_LABEL := "Empty Memory Pak"

static func display_name(path: String) -> String:
	var title := title_of_file(path)
	if title.is_empty() or title == BLANK_TITLE:
		return EMPTY_LABEL
	return title


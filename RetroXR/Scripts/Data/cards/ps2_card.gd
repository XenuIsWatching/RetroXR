## PS2Card — the PlayStation 2 memory card image format (raw 8 MB .ps2).
##
## Unlike the PlayStation's flat sixteen blocks, this is a real filesystem: a
## superblock, a doubly-indirect FAT, and 512-byte directory entries packed two
## to a 1024-byte cluster. Each save is a DIRECTORY at the root holding the
## game's own files, so a save's name is a folder name (BASLUS-20488) and its
## size is the space its whole subtree occupies.
##
## Pages carry a 16-byte spare area — twelve bytes of ECC over four 128-byte
## chunks, then four bytes neither core reads back. A page is therefore 528
## bytes on disk and 512 to the filesystem, and an image can also arrive with no
## spare area at all (a 512-stride .bin), so the stride is measured rather than
## assumed.
##
## Provenance, because none of this may be trusted on paper: the geometry, FAT
## construction, directory layout and ECC are transliterated from upstream
## PCSX2's FolderMemoryCard, which synthesises a card image and is therefore a
## writing reference and not only a reading one. The four fields PCSX2 never
## writes — magic, version, card_type, card_flags — come from Ross Ridge's
## public-domain specification, which PCSX2 vendors alongside it.
##
## PCSX2 does NOT format a card: it creates one as 8,650,752 bytes of 0xFF and
## leaves the console's BIOS to format it. RetroXR never boots a BIOS, so
## blank_image() has to do that job itself, and the check that it did it right is
## the BIOS memory card browser accepting the result.
class_name PS2Card
extends RefCounted

# --- Geometry -----------------------------------------------------------------

const PAGE_SIZE          := 512
const SPARE_SIZE         := 16
const PAGE_RAW           := PAGE_SIZE + SPARE_SIZE          # 528
const PAGES_PER_CLUSTER  := 2
const CLUSTER_SIZE       := PAGE_SIZE * PAGES_PER_CLUSTER   # 1024
const PAGES_PER_BLOCK    := 16
const TOTAL_PAGES        := 0x4000                          # 16384
const CLUSTERS_PER_CARD  := TOTAL_PAGES / PAGES_PER_CLUSTER # 8192
const CARD_SIZE          := TOTAL_PAGES * PAGE_RAW          # 8650752
const CARD_SIZE_NO_ECC   := TOTAL_PAGES * PAGE_SIZE         # 8388608

## First allocatable cluster, and the origin every FAT link and directory entry
## cluster is measured from. PCSX2 derives it as clusters/0x100 + 9.
const ALLOC_OFFSET := CLUSTERS_PER_CARD / 0x100 + 9         # 41
## One past the highest allocatable cluster, relative to ALLOC_OFFSET.
const ALLOC_END    := CLUSTERS_PER_CARD - 0x10 - ALLOC_OFFSET   # 8135

## The card reports LESS free space than alloc_end allows. PCSX2 truncates to
## this to match what the console's own browser reports, and a card that offered
## the extra 136 clusters would disagree with every figure a player sees.
const USABLE_CLUSTERS := (ALLOC_END / 1000) * 1000 - 1      # 7999

const IFC_CLUSTER       := 8       ## absolute cluster holding the indirect FAT
const FIRST_FAT_CLUSTER := 9       ## absolute; FAT occupies 9..40
const FAT_CLUSTER_COUNT := CLUSTERS_PER_CARD / (CLUSTER_SIZE / 4)   # 32
const ROOTDIR_CLUSTER   := 0       ## relative to ALLOC_OFFSET; must be zero
const BACKUP_BLOCK1     := CLUSTERS_PER_CARD / 8 - 1        # 1023
const BACKUP_BLOCK2     := CLUSTERS_PER_CARD / 8 - 2        # 1022

# --- Superblock ---------------------------------------------------------------

const MAGIC := "Sony PS2 Memory Card Format "   ## 28 bytes, trailing space, no NUL
const VERSION := "1.2.0.0"                      ## 1.2 = full bad_block_list support
const CARD_TYPE := 2                            ## must be 2 (a PS2 card)
## Physical characteristics: CF_USE_ECC 0x01 and CF_BAD_BLOCK 0x08, plus two bits
## nothing documents.
##
## MEASURED off a real PCSX2 card backup, not taken from the specification, which
## calls 0x52 the default — a value with CF_USE_ECC CLEAR, on a card whose every
## page carries ECC. Note CF_ERASE_ZEROES (0x10) is clear here too, which is why
## the unwritten body of a card is 0xFF rather than zero.
const CARD_FLAGS := 0x2B

const SB_MAGIC          := 0x00
const SB_VERSION        := 0x1C
const SB_PAGE_LEN       := 0x28
const SB_PAGES_PER_CLUS := 0x2A
const SB_PAGES_PER_BLK  := 0x2C
const SB_CLUSTERS       := 0x30
const SB_ALLOC_OFFSET   := 0x34
const SB_ALLOC_END      := 0x38
const SB_ROOTDIR        := 0x3C
const SB_BACKUP1        := 0x40
const SB_BACKUP2        := 0x44
const SB_IFC_LIST       := 0x50
const SB_BAD_BLOCKS     := 0xD0
const SB_CARD_TYPE      := 0x150
const SB_CARD_FLAGS     := 0x151

# --- Directory entries --------------------------------------------------------

const ENTRY_SIZE          := 512
const ENTRIES_PER_CLUSTER := CLUSTER_SIZE / ENTRY_SIZE      # 2
const NAME_LEN            := 32

const E_MODE      := 0x00
const E_LENGTH    := 0x04   ## bytes for a file; SLOT count for a directory
const E_CREATED   := 0x08
const E_CLUSTER   := 0x10
const E_DIR_ENTRY := 0x14
const E_MODIFIED  := 0x18
const E_ATTR      := 0x20
const E_NAME      := 0x40

const MODE_READ      := 0x0001
const MODE_WRITE     := 0x0002
const MODE_EXECUTE   := 0x0004
const MODE_PROTECTED := 0x0008
const MODE_FILE      := 0x0010
const MODE_DIRECTORY := 0x0020
const MODE_0080      := 0x0080
const MODE_0400      := 0x0400
const MODE_2000      := 0x2000
const MODE_USED      := 0x8000

const DEFAULT_DIR_MODE  := 0x8427
const DEFAULT_FILE_MODE := 0x8497
## The root's ".." carries 0x2000 and drops MODE_READ, which no subdirectory's
## does. Copied from PCSX2's CreateRootDir rather than reasoned about.
const ROOT_DOTDOT_MODE  := 0xA426

## A zero-length file points at this rather than at cluster 0.
const EMPTY_FILE_CLUSTER := 0xFFFFFFFF

# --- FAT ----------------------------------------------------------------------

const FAT_IN_USE := 0x80000000   ## bit 31: this cluster is allocated
const FAT_LAST   := 0x7FFFFFFF   ## link value meaning "end of chain"
const FAT_FREE   := 0x7FFFFFFF   ## a free entry: FAT_LAST with bit 31 clear
const FAT_ENTRIES_PER_CLUSTER := CLUSTER_SIZE / 4   # 256

## Every save on the card is a directory at the root. Slots 0 and 1 are always
## "." and "..", so a real save can never be one of them.
const FIRST_SAVE_SLOT := 2

# --- PSU (one save, lifted off the card) --------------------------------------
#
# The container every PS2 save tool reads. A stream of 512-byte headers, each
# file's header followed by its bytes padded up to a cluster. PCSX2 has no
# import or export of its own; this layout is Play!'s CSaveExporter.

const PSU_ENTRY_SIZE := 512
const PSU_DIR_FLAGS  := 0x8427
const PSU_FILE_FLAGS := 0x8497
const PSU_PAD        := 1024

const P_FLAGS    := 0x00
const P_SIZE     := 0x04
const P_CREATED  := 0x08
const P_SECTOR   := 0x10
const P_CHECKSUM := 0x14
const P_MODIFIED := 0x18
const P_NAME     := 0x40
const PSU_NAME_LEN := 0x1C0


# --- ECC ----------------------------------------------------------------------

## Column/line parity lookup, from PCSX2's FolderMemoryCard::CalculateECC.
const ECC_TABLE := [
	0x00, 0x87, 0x96, 0x11, 0xa5, 0x22, 0x33, 0xb4, 0xb4, 0x33, 0x22, 0xa5, 0x11, 0x96, 0x87, 0x00,
	0xc3, 0x44, 0x55, 0xd2, 0x66, 0xe1, 0xf0, 0x77, 0x77, 0xf0, 0xe1, 0x66, 0xd2, 0x55, 0x44, 0xc3,
	0xd2, 0x55, 0x44, 0xc3, 0x77, 0xf0, 0xe1, 0x66, 0x66, 0xe1, 0xf0, 0x77, 0xc3, 0x44, 0x55, 0xd2,
	0x11, 0x96, 0x87, 0x00, 0xb4, 0x33, 0x22, 0xa5, 0xa5, 0x22, 0x33, 0xb4, 0x00, 0x87, 0x96, 0x11,
	0xe1, 0x66, 0x77, 0xf0, 0x44, 0xc3, 0xd2, 0x55, 0x55, 0xd2, 0xc3, 0x44, 0xf0, 0x77, 0x66, 0xe1,
	0x22, 0xa5, 0xb4, 0x33, 0x87, 0x00, 0x11, 0x96, 0x96, 0x11, 0x00, 0x87, 0x33, 0xb4, 0xa5, 0x22,
	0x33, 0xb4, 0xa5, 0x22, 0x96, 0x11, 0x00, 0x87, 0x87, 0x00, 0x11, 0x96, 0x22, 0xa5, 0xb4, 0x33,
	0xf0, 0x77, 0x66, 0xe1, 0x55, 0xd2, 0xc3, 0x44, 0x44, 0xc3, 0xd2, 0x55, 0xe1, 0x66, 0x77, 0xf0,
	0xf0, 0x77, 0x66, 0xe1, 0x55, 0xd2, 0xc3, 0x44, 0x44, 0xc3, 0xd2, 0x55, 0xe1, 0x66, 0x77, 0xf0,
	0x33, 0xb4, 0xa5, 0x22, 0x96, 0x11, 0x00, 0x87, 0x87, 0x00, 0x11, 0x96, 0x22, 0xa5, 0xb4, 0x33,
	0x22, 0xa5, 0xb4, 0x33, 0x87, 0x00, 0x11, 0x96, 0x96, 0x11, 0x00, 0x87, 0x33, 0xb4, 0xa5, 0x22,
	0xe1, 0x66, 0x77, 0xf0, 0x44, 0xc3, 0xd2, 0x55, 0x55, 0xd2, 0xc3, 0x44, 0xf0, 0x77, 0x66, 0xe1,
	0x11, 0x96, 0x87, 0x00, 0xb4, 0x33, 0x22, 0xa5, 0xa5, 0x22, 0x33, 0xb4, 0x00, 0x87, 0x96, 0x11,
	0xd2, 0x55, 0x44, 0xc3, 0x77, 0xf0, 0xe1, 0x66, 0x66, 0xe1, 0xf0, 0x77, 0xc3, 0x44, 0x55, 0xd2,
	0xc3, 0x44, 0x55, 0xd2, 0x66, 0xe1, 0xf0, 0x77, 0x77, 0xf0, 0xe1, 0x66, 0xd2, 0x55, 0x44, 0xc3,
	0x00, 0x87, 0x96, 0x11, 0xa5, 0x22, 0x33, 0xb4, 0xb4, 0x33, 0x22, 0xa5, 0x11, 0x96, 0x87, 0x00,
]


## The three ECC bytes over one 128-byte chunk.
static func calculate_ecc(chunk: PackedByteArray, from: int) -> PackedByteArray:
	var c0 := 0
	var c1 := 0
	var c2 := 0
	for i in 0x80:
		var c: int = ECC_TABLE[chunk[from + i]]
		c0 ^= c
		if c & 0x80:
			c1 = (c1 ^ ~i) & 0xFF
			c2 = (c2 ^ i) & 0xFF
	return PackedByteArray([(~c0) & 0x77, (~c1) & 0x7F, (~c2) & 0x7F])


# --- Raw page access ----------------------------------------------------------

## Bytes of spare area per page in this image: 16 for an ordinary .ps2, 0 for a
## no-ECC .bin. Derived from the file's own size rather than assumed, so one
## reader serves both.
static func spare_size(data: PackedByteArray) -> int:
	var size := data.size()
	# Anything smaller than the data area of the smallest card is not a card at
	# all, and must be rejected before the recovery path below gets a chance to
	# read a stray zero as a spare area.
	if size < CARD_SIZE_NO_ECC:
		return -1
	if size % TOTAL_PAGES != 0:
		# A dump whose size is not a whole number of pages. PCSX2 recovers by
		# testing whether the word at 0x20C is zero, which it is only when a
		# spare area sits there.
		if size > 0x20C + 4 and data.decode_u32(0x20C) == 0:
			return SPARE_SIZE
		return -1
	@warning_ignore("integer_division")
	var per_page: int = size / TOTAL_PAGES
	if per_page == PAGE_RAW:
		return SPARE_SIZE
	if per_page == PAGE_SIZE:
		return 0
	return -1


static func _page_raw(data: PackedByteArray) -> int:
	var spare := spare_size(data)
	return -1 if spare < 0 else PAGE_SIZE + spare


## One cluster's 1024 data bytes, addressed ABSOLUTELY. Callers holding a
## cluster out of the FAT or a directory entry must add ALLOC_OFFSET first.
static func _read_cluster(data: PackedByteArray, cluster: int, page_raw: int) -> PackedByteArray:
	var out := PackedByteArray()
	for p in PAGES_PER_CLUSTER:
		var off := (cluster * PAGES_PER_CLUSTER + p) * page_raw
		if off + PAGE_SIZE > data.size():
			return PackedByteArray()
		out.append_array(data.slice(off, off + PAGE_SIZE))
	return out


static func _write_cluster(data: PackedByteArray, cluster: int, page_raw: int,
		bytes: PackedByteArray) -> void:
	for p in PAGES_PER_CLUSTER:
		var off := (cluster * PAGES_PER_CLUSTER + p) * page_raw
		if off + page_raw > data.size():
			return
		for i in PAGE_SIZE:
			data[off + i] = bytes[p * PAGE_SIZE + i]
		if page_raw > PAGE_SIZE:
			_write_page_ecc(data, off)


## Fill one raw page's spare area from its data. Four 3-byte ECCs, then four
## bytes PCSX2 leaves set — nothing reads them back, but a real dump has them.
static func _write_page_ecc(data: PackedByteArray, page_off: int) -> void:
	@warning_ignore("integer_division")
	var chunks: int = PAGE_SIZE / 0x80
	for j in chunks:
		var ecc := calculate_ecc(data, page_off + j * 0x80)
		data[page_off + PAGE_SIZE + j * 3 + 0] = ecc[0]
		data[page_off + PAGE_SIZE + j * 3 + 1] = ecc[1]
		data[page_off + PAGE_SIZE + j * 3 + 2] = ecc[2]
	# The four bytes after the ECC are ZERO on a real card. PCSX2's folder path
	# leaves them 0xFF because it never stores a spare area at all; the converter
	# that does write one writes nulls, and so does the hardware.
	for k in range(chunks * 3, SPARE_SIZE):
		data[page_off + PAGE_SIZE + k] = 0


# --- Superblock ---------------------------------------------------------------

## The superblock's fields, or an empty dictionary when this is not a PS2 card.
static func _superblock(data: PackedByteArray) -> Dictionary:
	var page_raw := _page_raw(data)
	if page_raw < 0:
		return {}
	var sb := data.slice(0, PAGE_SIZE)
	if sb.size() < 0x152:
		return {}
	if sb.slice(0, MAGIC.length()).get_string_from_ascii() != MAGIC:
		return {}
	if sb[SB_CARD_TYPE] != CARD_TYPE:
		return {}
	var clusters := sb.decode_u32(SB_CLUSTERS)
	var alloc_offset := sb.decode_u32(SB_ALLOC_OFFSET)
	if clusters <= 0 or alloc_offset <= 0 or alloc_offset >= clusters:
		return {}
	if sb.decode_u16(SB_PAGE_LEN) != PAGE_SIZE:
		return {}
	if sb.decode_u16(SB_PAGES_PER_CLUS) != PAGES_PER_CLUSTER:
		return {}
	var ifc: Array[int] = []
	for i in 32:
		ifc.append(sb.decode_u32(SB_IFC_LIST + i * 4))
	var out := {
		"page_raw": page_raw,
		"clusters": clusters,
		"alloc_offset": alloc_offset,
		"alloc_end": sb.decode_u32(SB_ALLOC_END),
		"rootdir": sb.decode_u32(SB_ROOTDIR),
		"ifc": ifc,
	}
	# The FAT is read once, here, and every later lookup is an array index.
	# Reading it a cluster at a time per entry instead turns allocating an
	# N-cluster save into N-squared reads of an 8 MB buffer, which is slow enough
	# on a 300-cluster save to look like a hang.
	out["fat_clusters"] = _fat_cluster_list(data, out)
	out["fat"] = _fat_load(data, out)
	return out


# --- FAT ----------------------------------------------------------------------

## The absolute clusters the FAT itself occupies, in order, read out of the
## indirect FAT. The indirection is the part that is easy to get wrong: the ifc
## list and the values inside it are ABSOLUTE cluster numbers, while everything
## the FAT stores is relative to alloc_offset.
static func _fat_cluster_list(data: PackedByteArray, sb: Dictionary) -> Array[int]:
	var out: Array[int] = []
	var ifc: Array = sb["ifc"]
	@warning_ignore("integer_division")
	var want: int = (int(sb["clusters"]) + FAT_ENTRIES_PER_CLUSTER - 1) \
		/ FAT_ENTRIES_PER_CLUSTER
	for i in ifc.size():
		var indirect_cluster: int = ifc[i]
		if indirect_cluster == 0xFFFFFFFF:
			break
		var indirect := _read_cluster(data, indirect_cluster, sb["page_raw"])
		if indirect.is_empty():
			break
		for j in FAT_ENTRIES_PER_CLUSTER:
			if out.size() >= want:
				return out
			var fat_cluster := indirect.decode_u32(j * 4)
			# Unused slots read 0xFFFFFFFF in PCSX2 and 0 on a real card, and
			# cluster 0 is the superblock either way.
			if fat_cluster == 0xFFFFFFFF or fat_cluster == 0:
				return out
			out.append(fat_cluster)
	return out


## Every FAT entry, decoded. Held as 64-bit because an entry runs to 0xFFFFFFFF
## and a 32-bit array would wrap it negative.
static func _fat_load(data: PackedByteArray, sb: Dictionary) -> PackedInt64Array:
	var out := PackedInt64Array()
	var clusters: Array = sb["fat_clusters"]
	for c in clusters:
		var raw := _read_cluster(data, int(c), sb["page_raw"])
		if raw.is_empty():
			break
		for j in FAT_ENTRIES_PER_CLUSTER:
			out.append(raw.decode_u32(j * 4))
	return out


static func _fat_store(data: PackedByteArray, sb: Dictionary) -> void:
	var fat: PackedInt64Array = sb["fat"]
	var clusters: Array = sb["fat_clusters"]
	for i in clusters.size():
		var raw := PackedByteArray()
		raw.resize(CLUSTER_SIZE)
		for j in FAT_ENTRIES_PER_CLUSTER:
			var index := i * FAT_ENTRIES_PER_CLUSTER + j
			raw.encode_u32(j * 4, fat[index] if index < fat.size() else FAT_FREE)
		_write_cluster(data, int(clusters[i]), sb["page_raw"], raw)


static func _fat_get(sb: Dictionary, index: int) -> int:
	var fat: PackedInt64Array = sb["fat"]
	if index < 0 or index >= fat.size():
		return 0
	return fat[index]


static func _fat_set(sb: Dictionary, index: int, value: int) -> void:
	var fat: PackedInt64Array = sb["fat"]
	if index < 0 or index >= fat.size():
		return
	fat[index] = value
	sb["fat"] = fat


## Every cluster of a chain, relative to alloc_offset. Defends against a link
## that leaves the card and against a cycle, either of which would otherwise
## spin here forever on a damaged image.
static func _chain(sb: Dictionary, first: int, limit := 0) -> Array[int]:
	var out: Array[int] = []
	if first == EMPTY_FILE_CLUSTER:
		return out
	var seen := {}
	var cur := first
	var alloc_end: int = sb["alloc_end"]
	while cur != FAT_LAST and cur != EMPTY_FILE_CLUSTER:
		if cur < 0 or cur >= alloc_end or seen.has(cur):
			break
		seen[cur] = true
		out.append(cur)
		if limit > 0 and out.size() >= limit:
			break
		var entry := _fat_get(sb, cur)
		if entry & FAT_IN_USE == 0:
			break
		cur = entry & FAT_LAST
	return out


## The next free cluster at or after `from`. Allocation walks forward rather
## than restarting, so filling a card stays linear instead of quadratic.
static func _free_cluster(sb: Dictionary, from: int) -> int:
	for i in range(maxi(from, 0), USABLE_CLUSTERS):
		if _fat_get(sb, i) & FAT_IN_USE == 0:
			return i
	return -1


# --- Directory entries --------------------------------------------------------

static func _entry_at(data: PackedByteArray, sb: Dictionary, rel_cluster: int,
		half: int) -> PackedByteArray:
	var cluster := _read_cluster(data, rel_cluster + int(sb["alloc_offset"]), sb["page_raw"])
	if cluster.is_empty():
		return PackedByteArray()
	return cluster.slice(half * ENTRY_SIZE, (half + 1) * ENTRY_SIZE)


static func _put_entry(data: PackedByteArray, sb: Dictionary, rel_cluster: int,
		half: int, entry: PackedByteArray) -> void:
	var abs_cluster: int = rel_cluster + int(sb["alloc_offset"])
	var cluster := _read_cluster(data, abs_cluster, sb["page_raw"])
	if cluster.is_empty():
		return
	for i in ENTRY_SIZE:
		cluster[half * ENTRY_SIZE + i] = entry[i]
	_write_cluster(data, abs_cluster, sb["page_raw"], cluster)


static func _decode_entry(raw: PackedByteArray) -> Dictionary:
	if raw.size() < ENTRY_SIZE:
		return {}
	var mode := raw.decode_u32(E_MODE)
	return {
		"mode": mode,
		"length": raw.decode_u32(E_LENGTH),
		"cluster": raw.decode_u32(E_CLUSTER),
		"attr": raw.decode_u32(E_ATTR),
		"name": _name_of(raw, E_NAME, NAME_LEN),
		"created": raw.slice(E_CREATED, E_CREATED + 8),
		"modified": raw.slice(E_MODIFIED, E_MODIFIED + 8),
		# 0xFFFFFFFF is an erased page that was never written; MODE_USED clear on
		# an otherwise valid entry is a DELETED file. The two are different, and
		# only the second leaves a slot that still counts toward `length`.
		"valid": mode != 0xFFFFFFFF,
		"used": (mode & MODE_USED) != 0,
		"is_dir": (mode & MODE_DIRECTORY) != 0,
		"is_file": (mode & MODE_FILE) != 0,
	}


static func _name_of(raw: PackedByteArray, from: int, length: int) -> String:
	var end := from
	while end < from + length and end < raw.size() and raw[end] != 0:
		end += 1
	return raw.slice(from, end).get_string_from_ascii()


## The slots of one directory, in order. `slots` is the directory entry's own
## `length`, which counts "." and ".." and every DEAD slot as well as the live
## files — so it is a capacity, never a file count.
static func _dir_slots(data: PackedByteArray, sb: Dictionary, first: int,
		slots: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if slots <= 0:
		return out
	@warning_ignore("integer_division")
	var need: int = (slots + ENTRIES_PER_CLUSTER - 1) / ENTRIES_PER_CLUSTER
	var chain := _chain(sb, first, need)
	for i in slots:
		@warning_ignore("integer_division")
		var c: int = i / ENTRIES_PER_CLUSTER
		if c >= chain.size():
			break
		var entry := _decode_entry(_entry_at(data, sb, chain[c], i % ENTRIES_PER_CLUSTER))
		if entry.is_empty():
			break
		entry["slot"] = i
		out.append(entry)
	return out


## The root directory's slots. Its own entry is slot 0, and that entry's
## `length` is how many slots the root has — the one place a directory describes
## itself rather than being described by a parent.
static func _root_slots(data: PackedByteArray, sb: Dictionary) -> Array[Dictionary]:
	var root: int = sb["rootdir"]
	var head := _decode_entry(_entry_at(data, sb, root, 0))
	if head.is_empty() or not head["valid"]:
		return []
	return _dir_slots(data, sb, root, int(head["length"]))


static func _read_file(data: PackedByteArray, sb: Dictionary, first: int,
		size: int) -> PackedByteArray:
	if size <= 0:
		return PackedByteArray()
	@warning_ignore("integer_division")
	var need: int = (size + CLUSTER_SIZE - 1) / CLUSTER_SIZE
	var chain := _chain(sb, first, need)
	var out := PackedByteArray()
	for c in chain:
		out.append_array(_read_cluster(data, c + int(sb["alloc_offset"]), sb["page_raw"]))
	return out.slice(0, mini(size, out.size()))


# --- Public: reading ----------------------------------------------------------

static func is_card_image(data: PackedByteArray) -> bool:
	return not _superblock(data).is_empty()


## Clusters this save's whole subtree occupies — its own directory plus every
## file in it. This is the figure the console shows in KB.
static func _save_blocks(data: PackedByteArray, sb: Dictionary, entry: Dictionary) -> int:
	var slots := int(entry["length"])
	@warning_ignore("integer_division")
	var total: int = (slots + ENTRIES_PER_CLUSTER - 1) / ENTRIES_PER_CLUSTER
	for child in _dir_slots(data, sb, int(entry["cluster"]), slots):
		if not child["valid"] or not child["used"] or not child["is_file"]:
			continue
		var size := int(child["length"])
		@warning_ignore("integer_division")
		var clusters: int = (size + CLUSTER_SIZE - 1) / CLUSTER_SIZE
		total += clusters
	return total


static func list_saves(data: PackedByteArray, with_icons := true) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var sb := _superblock(data)
	if sb.is_empty():
		return out
	for entry in _root_slots(data, sb):
		if int(entry["slot"]) < FIRST_SAVE_SLOT:
			continue
		if not entry["valid"] or not entry["used"] or not entry["is_dir"]:
			continue
		var name := String(entry["name"])
		if name.is_empty():
			continue
		var save := {
			"name": name,
			"serial": _serial_of(name),
			"title": name,
			"blocks": _save_blocks(data, sb, entry),
			"block": int(entry["slot"]),
			"icons": [],
		}
		var meta := _read_icon_sys(data, sb, entry)
		if not meta.is_empty():
			if not String(meta.get("title", "")).is_empty():
				save["title"] = meta["title"]
			if with_icons:
				var model := _read_icon_model(data, sb, entry, meta)
				if not model.is_empty():
					# A non-contract key, the way the GameCube's card adds
					# "banner". A PS2 icon is a 3-D model, so there is no Image
					# to put in "icons" — the panel renders this instead.
					save["icon_model"] = model
		out.append(save)
	return out


## icon.sys, the file that names a save on screen and names its three icons.
static func _read_icon_sys(data: PackedByteArray, sb: Dictionary,
		entry: Dictionary) -> Dictionary:
	for child in _dir_slots(data, sb, int(entry["cluster"]), int(entry["length"])):
		if not child["valid"] or not child["used"] or not child["is_file"]:
			continue
		if String(child["name"]).to_lower() != "icon.sys":
			continue
		var bytes := _read_file(data, sb, int(child["cluster"]), int(child["length"]))
		return PS2Icon.parse_icon_sys(bytes)
	return {}


static func _read_icon_model(data: PackedByteArray, sb: Dictionary, entry: Dictionary,
		meta: Dictionary) -> Dictionary:
	var want := String(meta.get("icon_normal", "")).to_lower()
	if want.is_empty():
		return {}
	for child in _dir_slots(data, sb, int(entry["cluster"]), int(entry["length"])):
		if not child["valid"] or not child["used"] or not child["is_file"]:
			continue
		if String(child["name"]).to_lower() != want:
			continue
		return PS2Icon.parse_icn(
			_read_file(data, sb, int(child["cluster"]), int(child["length"])))
	return {}


## A save directory is named for the game's product code, usually with a suffix
## of the game's own. Matched by SHAPE rather than by position, for the same
## reason the PlayStation's is: the code is not always where it should be.
static func _serial_of(name: String) -> String:
	var re := RegEx.new()
	re.compile("([A-Z]{4})[-_]?([0-9]{5})")
	var m := re.search(name.to_upper())
	if m == null:
		return ""
	return "%s-%s" % [m.get_string(1), m.get_string(2)]


static func block_of(data: PackedByteArray, name: String) -> int:
	for save in list_saves(data, false):
		if String(save["name"]) == name:
			return int(save["block"])
	return -1


static func free_blocks(data: PackedByteArray) -> int:
	var sb := _superblock(data)
	if sb.is_empty():
		return 0
	var free := 0
	for i in USABLE_CLUSTERS:
		if _fat_get(sb, i) & FAT_IN_USE == 0:
			free += 1
	return free


## One short of the usable count, because the root directory always occupies a
## cluster of its own and a save can never have it. The PlayStation's card
## excludes its directory block from this figure for the same reason.
static func total_blocks(_data: PackedByteArray) -> int:
	return USABLE_CLUSTERS - 1


# --- Public: one save, in and out ---------------------------------------------

## The root slot a handle names. Slots 0 and 1 are the root's own "." and "..",
## which look exactly like a save — a used directory entry — and are emphatically
## not one: deleting slot 0 would take the root directory with it.
static func _root_entry(data: PackedByteArray, sb: Dictionary, slot: int) -> Dictionary:
	if slot < FIRST_SAVE_SLOT:
		return {}
	for entry in _root_slots(data, sb):
		if int(entry["slot"]) == slot:
			return entry
	return {}


static func _psu_header(flags: int, size: int, name: String,
		created: PackedByteArray, modified: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(PSU_ENTRY_SIZE)
	out.fill(0)
	out.encode_u32(P_FLAGS, flags)
	out.encode_u32(P_SIZE, size)
	for i in mini(8, created.size()):
		out[P_CREATED + i] = created[i]
	for i in mini(8, modified.size()):
		out[P_MODIFIED + i] = modified[i]
	# P_SECTOR and P_CHECKSUM are left zero on purpose: both describe where the
	# save happened to sit, so writing them would make a save's digest a fact
	# about the card rather than about the save.
	var raw := name.to_ascii_buffer()
	for i in mini(raw.size(), PSU_NAME_LEN - 1):
		out[P_NAME + i] = raw[i]
	return out


static func extract_save(data: PackedByteArray, slot: int) -> PackedByteArray:
	var sb := _superblock(data)
	if sb.is_empty():
		return PackedByteArray()
	var entry := _root_entry(data, sb, slot)
	if entry.is_empty() or not entry["used"] or not entry["is_dir"]:
		return PackedByteArray()

	var children := _dir_slots(data, sb, int(entry["cluster"]), int(entry["length"]))
	var files: Array[Dictionary] = []
	for child in children:
		if child["valid"] and child["used"] and child["is_file"]:
			files.append(child)

	var out := PackedByteArray()
	out.append_array(_psu_header(int(entry["mode"]), files.size() + FIRST_SAVE_SLOT,
		String(entry["name"]), entry["created"], entry["modified"]))
	# "." and ".." carry timestamps of their OWN, which are not the directory
	# entry's. Copying the parent's instead is invisible in a round trip here and
	# shows up the moment another tool reads the container.
	for i in FIRST_SAVE_SLOT:
		var dot := children[i] if i < children.size() else {}
		out.append_array(_psu_header(PSU_DIR_FLAGS, 0, "." if i == 0 else "..",
			dot.get("created", entry["created"]),
			dot.get("modified", entry["modified"])))

	for f in files:
		var size := int(f["length"])
		out.append_array(_psu_header(int(f["mode"]), size, String(f["name"]),
			f["created"], f["modified"]))
		var bytes := _read_file(data, sb, int(f["cluster"]), size)
		if bytes.size() != size:
			return PackedByteArray()
		out.append_array(bytes)
		var pad := (PSU_PAD - (size % PSU_PAD)) % PSU_PAD
		if pad > 0:
			var filler := PackedByteArray()
			filler.resize(pad)
			filler.fill(0)
			out.append_array(filler)
	return out


## Split a .psu back into a directory name and its files, or {} if it is not one.
static func parse_psu(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < PSU_ENTRY_SIZE * 3:
		return {}
	var head := bytes.slice(0, PSU_ENTRY_SIZE)
	if head.decode_u32(P_FLAGS) & MODE_DIRECTORY == 0:
		return {}
	var dir_name := _name_of(head, P_NAME, PSU_NAME_LEN)
	if dir_name.is_empty():
		return {}
	var slots := head.decode_u32(P_SIZE)
	if slots < FIRST_SAVE_SLOT:
		return {}

	var files: Array[Dictionary] = []
	var dots: Array[Dictionary] = []
	var pos := PSU_ENTRY_SIZE
	var seen := 0
	# `slots` counts the entries INSIDE the directory — "." and ".." and one per
	# file — and does not count the header that declared it. Reading one fewer
	# silently drops the last file of every save.
	while pos + PSU_ENTRY_SIZE <= bytes.size() and seen < slots:
		var e := bytes.slice(pos, pos + PSU_ENTRY_SIZE)
		pos += PSU_ENTRY_SIZE
		seen += 1
		var flags := e.decode_u32(P_FLAGS)
		var name := _name_of(e, P_NAME, PSU_NAME_LEN)
		if flags & MODE_DIRECTORY != 0:
			# "." and ".." carry no payload, but they do carry timestamps of
			# their own, which are kept so a container survives a round trip
			# through a card unchanged.
			dots.append({
				"created": e.slice(P_CREATED, P_CREATED + 8),
				"modified": e.slice(P_MODIFIED, P_MODIFIED + 8),
			})
			continue
		if flags & MODE_FILE == 0:
			return {}
		var size := e.decode_u32(P_SIZE)
		if pos + size > bytes.size():
			return {}
		files.append({
			"name": name,
			"mode": flags,
			"created": e.slice(P_CREATED, P_CREATED + 8),
			"modified": e.slice(P_MODIFIED, P_MODIFIED + 8),
			"data": bytes.slice(pos, pos + size),
		})
		pos += size + (PSU_PAD - (size % PSU_PAD)) % PSU_PAD
	if files.is_empty():
		return {}
	return {
		"name": dir_name,
		"mode": head.decode_u32(P_FLAGS),
		"created": head.slice(P_CREATED, P_CREATED + 8),
		"modified": head.slice(P_MODIFIED, P_MODIFIED + 8),
		"files": files,
		"dots": dots,
	}


static func is_psu(bytes: PackedByteArray) -> bool:
	return not parse_psu(bytes).is_empty()


static func _new_entry(mode: int, length: int, cluster: int, name: String,
		created: PackedByteArray, modified: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(ENTRY_SIZE)
	out.fill(0)
	out.encode_u32(E_MODE, mode)
	out.encode_u32(E_LENGTH, length)
	out.encode_u32(E_CLUSTER, cluster)
	for i in mini(8, created.size()):
		out[E_CREATED + i] = created[i]
	for i in mini(8, modified.size()):
		out[E_MODIFIED + i] = modified[i]
	var raw := name.to_ascii_buffer()
	for i in mini(raw.size(), NAME_LEN - 1):
		out[E_NAME + i] = raw[i]
	return out


## How many clusters a parsed .psu will occupy once written.
static func _psu_cost(psu: Dictionary) -> int:
	var files: Array = psu["files"]
	var slots: int = files.size() + FIRST_SAVE_SLOT
	@warning_ignore("integer_division")
	var total: int = (slots + ENTRIES_PER_CLUSTER - 1) / ENTRIES_PER_CLUSTER
	for f in files:
		var size: int = (f as Dictionary)["data"].size()
		@warning_ignore("integer_division")
		var clusters: int = (size + CLUSTER_SIZE - 1) / CLUSTER_SIZE
		total += clusters
	return total


static func insert_save(data: PackedByteArray, save: PackedByteArray) -> PackedByteArray:
	var sb := _superblock(data)
	if sb.is_empty():
		return PackedByteArray()
	var psu := parse_psu(save)
	if psu.is_empty():
		return PackedByteArray()
	var name: String = psu["name"]
	if block_of(data, name) >= 0:
		return PackedByteArray()
	if _psu_cost(psu) > free_blocks(data):
		return PackedByteArray()

	var out := data.duplicate()
	var root_slots := _root_slots(out, sb)
	var root_head := _decode_entry(_entry_at(out, sb, int(sb["rootdir"]), 0))
	if root_head.is_empty():
		return PackedByteArray()

	# Reserve every cluster this save needs before writing any of them, so a
	# refusal half way cannot leave the card holding a partial save.
	var files: Array = psu["files"]
	var slots: int = files.size() + FIRST_SAVE_SLOT
	@warning_ignore("integer_division")
	var dir_clusters: int = (slots + ENTRIES_PER_CLUSTER - 1) / ENTRIES_PER_CLUSTER
	# Each cluster is marked in use as it is taken, and the search resumes from
	# the one after it — the lowest free cluster is always at or above the
	# cursor, so filling a card stays linear. A failure part way through simply
	# discards this working copy of the FAT; nothing has been written yet.
	var cursor := 0
	var dir_chain: Array[int] = []
	for i in dir_clusters:
		var c := _free_cluster(sb, cursor)
		if c < 0:
			return PackedByteArray()
		_fat_set(sb, c, FAT_LAST | FAT_IN_USE)
		cursor = c + 1
		dir_chain.append(c)

	var file_chains: Array = []
	for f in files:
		var size: int = (f as Dictionary)["data"].size()
		@warning_ignore("integer_division")
		var need: int = (size + CLUSTER_SIZE - 1) / CLUSTER_SIZE
		var chain: Array[int] = []
		for i in need:
			var c := _free_cluster(sb, cursor)
			if c < 0:
				return PackedByteArray()
			_fat_set(sb, c, FAT_LAST | FAT_IN_USE)
			cursor = c + 1
			chain.append(c)
		file_chains.append(chain)

	_commit_chain(sb, dir_chain)
	for chain in file_chains:
		_commit_chain(sb, chain as Array[int])

	# The save's slot in the root, decided BEFORE its directory is written
	# because the directory's own "." has to name it. A dead slot is reused
	# where one exists, since the root's `length` is a capacity and growing it
	# needlessly is how a card fills up with nothing in it.
	var slot := -1
	for entry in root_slots:
		if int(entry["slot"]) >= FIRST_SAVE_SLOT and not entry["used"]:
			slot = int(entry["slot"])
			break
	var root_len := int(root_head["length"])
	if slot < 0:
		slot = root_len
		if not _grow_root(out, sb, root_len + 1):
			return PackedByteArray()
		root_len += 1
		var head := _entry_at(out, sb, int(sb["rootdir"]), 0)
		head.encode_u32(E_LENGTH, root_len)
		_put_entry(out, sb, int(sb["rootdir"]), 0, head)

	# The save's own directory: "." and ".." first, then one slot per file.
	var created: PackedByteArray = psu["created"]
	var modified: PackedByteArray = psu["modified"]
	var blank := PackedByteArray()
	blank.resize(CLUSTER_SIZE)
	blank.fill(0)
	for c in dir_chain:
		_write_cluster(out, c + int(sb["alloc_offset"]), sb["page_raw"], blank)

	# Both dot entries have length ZERO. Only the ROOT's "." carries a slot
	# count — that is the one directory with no parent to describe it, which is
	# also why _root_slots bootstraps from it. Measured on a real card, where a
	# save's own "." reads len=0 while the root's reads the number of saves.
	var dots: Array = psu.get("dots", [])
	for i in FIRST_SAVE_SLOT:
		var dot: Dictionary = dots[i] if i < dots.size() else {}
		var dot_entry := _new_entry(DEFAULT_DIR_MODE, 0, 0, "." if i == 0 else "..",
			dot.get("created", created), dot.get("modified", modified))
		# "." also names this directory's own slot in its parent.
		if i == 0:
			dot_entry.encode_u32(E_DIR_ENTRY, slot)
		_put_slot(out, sb, dir_chain, i, dot_entry)
	for i in files.size():
		var f: Dictionary = files[i]
		var chain: Array = file_chains[i]
		var bytes: PackedByteArray = f["data"]
		var first: int = chain[0] if not chain.is_empty() else EMPTY_FILE_CLUSTER
		_put_slot(out, sb, dir_chain, i + FIRST_SAVE_SLOT, _new_entry(
			int(f["mode"]), bytes.size(), first, String(f["name"]),
			f["created"], f["modified"]))
		_write_file(out, sb, chain, bytes)

	var root_chain := _chain(sb, int(sb["rootdir"]))
	_put_slot(out, sb, root_chain, slot, _new_entry(
		DEFAULT_DIR_MODE, slots, dir_chain[0], name, created, modified))
	_fat_store(out, sb)
	return out


static func _commit_chain(sb: Dictionary, chain: Array[int]) -> void:
	for i in chain.size():
		var next: int = FAT_LAST if i == chain.size() - 1 else chain[i + 1]
		_fat_set(sb, chain[i], next | FAT_IN_USE)


static func _put_slot(data: PackedByteArray, sb: Dictionary, chain: Array,
		slot: int, entry: PackedByteArray) -> void:
	@warning_ignore("integer_division")
	var c: int = slot / ENTRIES_PER_CLUSTER
	if c >= chain.size():
		return
	_put_entry(data, sb, int(chain[c]), slot % ENTRIES_PER_CLUSTER, entry)


static func _write_file(data: PackedByteArray, sb: Dictionary, chain: Array,
		bytes: PackedByteArray) -> void:
	for i in chain.size():
		var cluster := PackedByteArray()
		cluster.resize(CLUSTER_SIZE)
		cluster.fill(0)
		var from: int = i * CLUSTER_SIZE
		var to: int = mini(from + CLUSTER_SIZE, bytes.size())
		for j in range(from, to):
			cluster[j - from] = bytes[j]
		_write_cluster(data, int(chain[i]) + int(sb["alloc_offset"]), sb["page_raw"], cluster)


## Give the root directory room for one more slot, adding a cluster when the
## slot count crosses to an odd cluster boundary. PCSX2 decides the same thing
## from `length % 2`, and a root whose length disagrees with its chain puts the
## next entry on the wrong page.
static func _grow_root(data: PackedByteArray, sb: Dictionary, slots: int) -> bool:
	@warning_ignore("integer_division")
	var need: int = (slots + ENTRIES_PER_CLUSTER - 1) / ENTRIES_PER_CLUSTER
	var chain := _chain(sb, int(sb["rootdir"]))
	if chain.size() >= need:
		return true
	var added: Array[int] = []
	var cursor := 0
	for i in need - chain.size():
		var c := _free_cluster(sb, cursor)
		if c < 0:
			return false
		_fat_set(sb, c, FAT_LAST | FAT_IN_USE)
		cursor = c + 1
		added.append(c)
	var blank := PackedByteArray()
	blank.resize(CLUSTER_SIZE)
	blank.fill(0)
	for c in added:
		_write_cluster(data, c + int(sb["alloc_offset"]), sb["page_raw"], blank)
	var full: Array[int] = chain.duplicate()
	full.append_array(added)
	_commit_chain(sb, full)
	return true


static func delete_save(data: PackedByteArray, slot: int) -> PackedByteArray:
	var sb := _superblock(data)
	if sb.is_empty():
		return PackedByteArray()
	var entry := _root_entry(data, sb, slot)
	if entry.is_empty() or not entry["used"] or not entry["is_dir"]:
		return PackedByteArray()

	var out := data.duplicate()
	var children := _dir_slots(out, sb, int(entry["cluster"]), int(entry["length"]))
	for child in children:
		if not child["valid"] or not child["used"] or not child["is_file"]:
			continue
		var size := int(child["length"])
		@warning_ignore("integer_division")
		var need: int = (size + CLUSTER_SIZE - 1) / CLUSTER_SIZE
		_free_chain(sb, _chain(sb, int(child["cluster"]), need))
	_free_chain(sb, _chain(sb, int(entry["cluster"])))

	# The slot itself stays where it is with MODE_USED cleared. That is what a
	# deleted entry looks like on a real card, and the root's `length` counts it
	# either way.
	var root_chain := _chain(sb, int(sb["rootdir"]))
	@warning_ignore("integer_division")
	var c: int = slot / ENTRIES_PER_CLUSTER
	if c >= root_chain.size():
		return PackedByteArray()
	var raw := _entry_at(out, sb, root_chain[c], slot % ENTRIES_PER_CLUSTER)
	raw.encode_u32(E_MODE, int(entry["mode"]) & ~MODE_USED)
	_put_entry(out, sb, root_chain[c], slot % ENTRIES_PER_CLUSTER, raw)
	_fat_store(out, sb)
	return out


static func _free_chain(sb: Dictionary, chain: Array[int]) -> void:
	for c in chain:
		_fat_set(sb, c, FAT_FREE)


# --- Public: formatting -------------------------------------------------------

## A formatted, empty 8 MB card with ECC.
##
## PCSX2 has no routine to compare this against — it creates a card as 0xFF and
## lets the BIOS format it — so the pieces here come from two places: the FAT,
## root directory and derived superblock fields follow PCSX2's own CreateFat /
## CreateRootDir / SetSizeInClusters, and the magic, version, card_type and
## card_flags follow the vendored specification.
static func blank_image() -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(CARD_SIZE)
	data.fill(0xFF)

	# The superblock PAGE is zeroed, not erased: measured off a real card, whose
	# every byte past card_flags is zero and whose two padding words are zero
	# too. Only the fields that really are 0xFF-filled say so below.
	var sb := PackedByteArray()
	sb.resize(PAGE_SIZE)
	sb.fill(0)
	var magic := MAGIC.to_ascii_buffer()
	for i in magic.size():
		sb[SB_MAGIC + i] = magic[i]
	for i in 12:
		sb[SB_VERSION + i] = 0
	var version := VERSION.to_ascii_buffer()
	for i in version.size():
		sb[SB_VERSION + i] = version[i]
	sb.encode_u16(SB_PAGE_LEN, PAGE_SIZE)
	sb.encode_u16(SB_PAGES_PER_CLUS, PAGES_PER_CLUSTER)
	sb.encode_u16(SB_PAGES_PER_BLK, PAGES_PER_BLOCK)
	sb.encode_u16(0x2E, 0xFF00)
	sb.encode_u32(SB_CLUSTERS, CLUSTERS_PER_CARD)
	sb.encode_u32(SB_ALLOC_OFFSET, ALLOC_OFFSET)
	sb.encode_u32(SB_ALLOC_END, ALLOC_END)
	sb.encode_u32(SB_ROOTDIR, ROOTDIR_CLUSTER)
	sb.encode_u32(SB_BACKUP1, BACKUP_BLOCK1)
	sb.encode_u32(SB_BACKUP2, BACKUP_BLOCK2)
	# An unused indirect-FAT slot is ZERO on a real card, while an unused
	# bad-block slot is 0xFFFFFFFF. The two lists sit side by side and are filled
	# differently; both were measured rather than assumed.
	for i in 32:
		sb.encode_u32(SB_IFC_LIST + i * 4, IFC_CLUSTER if i == 0 else 0)
		sb.encode_u32(SB_BAD_BLOCKS + i * 4, 0xFFFFFFFF)
	sb[SB_CARD_TYPE] = CARD_TYPE
	sb[SB_CARD_FLAGS] = CARD_FLAGS

	# The superblock is one page; the rest of its cluster stays erased.
	var sb_cluster := PackedByteArray()
	sb_cluster.resize(CLUSTER_SIZE)
	sb_cluster.fill(0xFF)
	for i in PAGE_SIZE:
		sb_cluster[i] = sb[i]
	_write_cluster(data, 0, PAGE_RAW, sb_cluster)

	# The indirect FAT names each FAT cluster, absolutely: 9 through 40.
	var ifc := PackedByteArray()
	ifc.resize(CLUSTER_SIZE)
	ifc.fill(0xFF)
	for i in FAT_CLUSTER_COUNT:
		ifc.encode_u32(i * 4, FIRST_FAT_CLUSTER + i)
	_write_cluster(data, IFC_CLUSTER, PAGE_RAW, ifc)

	# Every data cluster free, except the one the root directory sits in.
	var free_fat := PackedByteArray()
	free_fat.resize(CLUSTER_SIZE)
	for i in FAT_ENTRIES_PER_CLUSTER:
		free_fat.encode_u32(i * 4, FAT_FREE)
	for i in FAT_CLUSTER_COUNT:
		_write_cluster(data, FIRST_FAT_CLUSTER + i, PAGE_RAW, free_fat)
	var first_fat := free_fat.duplicate()
	first_fat.encode_u32(ROOTDIR_CLUSTER * 4, FAT_LAST | FAT_IN_USE)
	_write_cluster(data, FIRST_FAT_CLUSTER, PAGE_RAW, first_fat)

	# The root: "." and "..", and nothing else. Both carry zero timestamps, and
	# the root's ".." is the one entry whose mode differs from every other.
	var root := PackedByteArray()
	root.resize(CLUSTER_SIZE)
	root.fill(0)
	var zero := PackedByteArray()
	zero.resize(8)
	zero.fill(0)
	var dot := _new_entry(DEFAULT_DIR_MODE, FIRST_SAVE_SLOT, 0, ".", zero, zero)
	var dotdot := _new_entry(ROOT_DOTDOT_MODE, 0, 0, "..", zero, zero)
	for i in ENTRY_SIZE:
		root[i] = dot[i]
		root[ENTRY_SIZE + i] = dotdot[i]
	_write_cluster(data, ALLOC_OFFSET + ROOTDIR_CLUSTER, PAGE_RAW, root)

	return data

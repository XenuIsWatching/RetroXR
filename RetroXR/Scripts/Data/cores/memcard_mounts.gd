## MemcardMounts — which cores keep their memory cards as files of their own, and
## where.
##
## Most cores hand their battery to the frontend through SAVE_RAM and a card is
## just a path RetroXR sets. The PlayStation 2 cores do not: neither pcsx2 nor
## pcee2 answers retro_get_memory_data for SAVE_RAM at all. They open their own
## card files, in their own directory, under their own names — so a seated card
## has to be MIRRORED into that directory before the core loads, and read back
## out again while it runs.
##
## Dolphin is the other core that owns its card files and is deliberately not
## here: it takes a verbatim absolute path per slot, so nothing needs copying and
## memory_card_controller mounts it directly.
##
## Both rows point at "pcsx2/memcards" because both cores plant a PCSX2 data root
## inside the frontend's system directory. They are still separate rows: the
## directory is the same shape, and everything else about them differs.
class_name MemcardMounts


const _ROWS := {
	# LRPS2. Its libretro build defaults to shared cards, which is the only mode
	# with two slots at all — the per-game branch names slot 1 after the ROM and
	# DISABLES slot 2. The names are fixed and cannot be redirected: it keeps its
	# settings in memory and reads no ini, so there is no per-slot path to set.
	#
	# The cost of that is a phantom card: the core creates one for any enabled
	# slot whose file is missing, so an empty slot shows the game an unformatted
	# card rather than no card. Nothing here can prevent it.
	"pcsx2": {
		"dir": "pcsx2/memcards",
		"names": ["Mcd001.ps2", "Mcd002.ps2"],
		"file_keys": [],
		"enable_keys": [],
		"forced": {"pcsx2_shared_memory_cards": "enabled"},
		"live_swap": false,
	},
	# PCEE2, a port of current upstream PCSX2. Better behaved in all three ways
	# that matter: a card is chosen BY NAME, a slot can be genuinely empty, and a
	# change while content is running really does eject and re-open the card.
	#
	# Its card list is built by scanning the directory when the core registers
	# its options, which happens before the core would create that directory —
	# so RetroXR has to create it and put the cards in it first, or the two slot
	# options are never registered at all.
	"pcee2": {
		"dir": "pcsx2/memcards",
		"names": [],
		"file_keys": ["pcsx2_memcard_slot1_file", "pcsx2_memcard_slot2_file"],
		"enable_keys": ["pcsx2_memcard_slot1_enable", "pcsx2_memcard_slot2_enable"],
		"forced": {},
		"live_swap": true,
	},
}


## The row for a resolved core name, or {}.
static func for_core(core_name: String) -> Dictionary:
	if core_name.is_empty():
		return {}
	for key: String in _ROWS:
		if core_name.begins_with(key):
			return _ROWS[key]
	return {}


static func has(core_name: String) -> bool:
	return not for_core(core_name).is_empty()


## Where this core keeps its cards, absolute.
static func mount_dir(core_name: String) -> String:
	var row := for_core(core_name)
	if row.is_empty():
		return ""
	return CoreDownloadManager.default_system_dir(core_name) \
		.path_join(str(row["dir"]))


## The filename this core expects a card in slot `slot` to have. A core with
## fixed names gets its own; one that chooses by name gets the card's own id, so
## the file in its directory is recognisably the card the player is holding.
static func scratch_name(row: Dictionary, slot: int, card_id: String) -> String:
	var names: Array = row.get("names", [])
	if slot < names.size():
		return str(names[slot])
	if card_id.is_empty():
		return ""
	return "%s.ps2" % card_id


## True when this core re-reads a slot while content is running. Where it is
## false a card seated or pulled mid-game cannot reach the core at all, and the
## change lands at the next power cycle.
static func live_swap(core_name: String) -> bool:
	var row := for_core(core_name)
	return bool(row.get("live_swap", false)) if not row.is_empty() else false

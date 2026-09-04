## Card e-Reader (Japan, PEAJ) — the original 4 MB reader.
##
## One of three revisions, one unit each, because a reader IS its dump and the
## dumps are not interchangeable: cards are region-locked and the reader answers
## a foreign card with its own Region Error screen. See ereader_plus.gd and
## ereader_usa.gd, which differ from this file only in their label and their game
## code.
##
## See ExpansionCatalog for how a unit file is assembled into the catalog, and
## expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "ereader"

# A Game Boy Advance cartridge with a slit through its roof that a printed card
# is SLID through, dotcode edge first. LOADER_SWIPE, so it builds a through-slot
# and no bay at all -- the card is never seated, and a snap zone would capture it
# mid-swipe.
#
# The unit id IS the media systemid, so has_own_card is true and the e-Reader
# tile carries the reader and its cards and nothing else. An id that differed
# from the media put the tile back on the generic console path, which offered a
# Primitive System, a Primitive Controller and a composite lead for a cartridge.
# The other two revisions have no card of their own and are therefore carded
# HERE, which is where a player picking a reader is already standing.
#
# Its program is the e-Reader cartridge dump, and it comes out of the LIBRARY --
# AdapterRoms finds it by the header code below, on the Game Boy Advance shelf or
# beside the cards in the e-Reader one. It is not firmware: it is an ordinary GBA
# ROM, and asking a player to install a second copy of it into the core's system
# directory, under a name of ours, was the room inventing a BIOS the hardware
# does not have. The Super Game Boy still works the older way -- see
# ExpansionCatalog.firmware_rom_path for why the two differ.
#
# Size is nominal, proportioned against the GBA cart it dwarfs; not measured.
const ROW := {
	"label": "Card e-Reader",
	"host": "game_boy_advance",
	"media": "ereader",
	"mount": ExpansionDefs.MOUNT_CARTRIDGE,
	# The battery is in the READER, not in anything it reads. Its 128 KiB of
	# flash holds the scanner calibration and the cards it has already taken --
	# the "Access saved data" row on its menu is that flash -- and a card is a
	# sheet of printed paper with no memory in it at all. Without this the unit
	# owns no save: it is not a cartridge with a save_id and it has no bay, so
	# every other route in _compose_sram_path answers "", the core is handed an
	# empty SRAM path, and each launch starts from blank flash.
	"save_owner": ExpansionDefs.SAVE_OWNER_UNIT,
	"size": Vector3(0.090, 0.062, 0.023),
	"loader": MediaDimensions.LOADER_SWIPE,
	# The game code in the dump's own header, which is what mGBA's override table
	# matches to switch the reader hardware on, and what AdapterRoms matches to
	# find the program. It does three jobs from one fact: a dump in the library
	# spawns the reader rather than a cartridge, the revision follows the file
	# rather than a filename, and the dump stops being offered as a game.
	"rom_code": "PEAJ",
}


const BOOT := {
	# The e-Reader boots as an ordinary GBA cartridge -- its dump is the program,
	# and mGBA switches the reader hardware on from the game code in the header
	# (PEAJ/PSAJ/PSAE in the core's own override table), not from anything named
	# here. The cards are not content: they arrive at runtime through disk
	# control, one image per strip.
	#
	# No `subsystem`. mGBA's retro_load_game_special is a stub that returns false
	# and its .info says load_subsystem = "false", so there is no ident to name and
	# inventing one would be worse than leaving it blank.
	"game_boy_advance|ereader": {
		"core": "mgba",
		"roms": ["expansion:ereader"],
	},
}

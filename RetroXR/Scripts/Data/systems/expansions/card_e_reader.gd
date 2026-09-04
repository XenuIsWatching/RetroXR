## Card e-Reader — a Game Boy Advance cartridge that reads printed dotcode cards.
##
## One of the twelve expansion units; see ExpansionCatalog for how a unit file
## is assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "card_e_reader"

# A Game Boy Advance cartridge with a slit through its roof that a printed card
# is SLID through, dotcode edge first. LOADER_SWIPE, so it builds a through-slot
# and no bay at all -- the card is never seated, and a snap zone would capture it
# mid-swipe.
#
# `card_e_reader` rather than `e_reader` because the media systemid is `ereader`:
# two identifiers a single underscore apart is a typo waiting to happen. It is
# also the product's own name in Japan.
#
# `card` is stated even though card_systemid derives the same answer, because
# has_own_card is false here (media_of != id) and the routing is worth reading
# off the row rather than re-deriving.
#
# Its program is the e-Reader cartridge dump, read from mGBA's system dir like
# the Super Game Boy's -- the unit is spawned from a menu and has no library
# file, so without rom_from_firmware its rom_path stays empty and the launch
# degrades to a plain load silently.
#
# Size is nominal, proportioned against the GBA cart it dwarfs; not measured.
const ROW := {
	"label": "e-Reader",
	"host": "game_boy_advance",
	"media": "ereader",
	"mount": ExpansionDefs.MOUNT_CARTRIDGE,
	"size": Vector3(0.090, 0.062, 0.023),
	"loader": MediaDimensions.LOADER_SWIPE,
	"card": "ereader",
	"firmware": ["ereader.gba"],
	"rom_from_firmware": true,
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
	"game_boy_advance|card_e_reader": {
		"core": "mgba",
		"roms": ["expansion:card_e_reader"],
	},
}

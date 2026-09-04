## 32X — the mushroom in the cartridge slot, and the Tower of Power.
##
## One of the eleven expansion units; see ExpansionCatalog for how a unit file
## is assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "sega_32x"

# Into the cartridge slot, on top, with its own cartridge slot on top of that.
# The only expansion here that a game cartridge goes INTO rather than past.
const ROW := {
	"label": "32X",
	"host": "mega_drive",
	"media": "sega_32x",
	"mount": ExpansionDefs.MOUNT_CARTRIDGE,
	"size": Vector3(0.15, 0.07, 0.14),
	"loader": MediaDimensions.LOADER_NONE,
}


const BOOT := {
	# UNVERIFIED. A 32X cartridge is the game and picodrive is the core that is
	# both halves at once.
	"mega_drive|sega_32x": {
		"core": "picodrive",
		"roms": ["expansion:sega_32x"],
	},
	# UNVERIFIED. The full tower, where the disc is still what boots.
	"mega_drive|sega_cd|sega_32x": {
		"core": "picodrive",
		"roms": ["expansion:sega_cd"],
	},
}

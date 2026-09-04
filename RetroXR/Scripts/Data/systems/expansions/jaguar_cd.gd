## Jaguar CD — the toilet seat that clamps to the cartridge slot.
##
## One of the eleven expansion units; see ExpansionCatalog for how a unit file
## is assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "jaguar_cd"

# It clamps to the cartridge slot and hangs over the console's back like a
# toilet seat, which is what everybody called it. Its discs are its own
# media: virtualjaguar names jaguar_cd in secondary_systemids, so the CD half
# is a system in its own right and the unit is spawned from its own card.
const ROW := {
	"label": "Jaguar CD",
	"host": "atari_jaguar",
	"media": "jaguar_cd",
	"mount": ExpansionDefs.MOUNT_CARTRIDGE,
	"size": Vector3(0.20, 0.09, 0.18),
	"loader": MediaDimensions.LOADER_TRAY,
	# A lid, not a drawer. The Jaguar CD opens upward the way a PlayStation or
	# a GameCube does; the Mega-CD and the CD-ROM2 we model slide a tray out.
	"lid": true,
}


const BOOT := {
	# UNVERIFIED.
	"atari_jaguar|jaguar_cd": {
		"core": "virtualjaguar",
		"roms": ["expansion:jaguar_cd"],
	},
}

## CD-ROM² — the Interface Unit the PC Engine docks into.
##
## One of the eleven expansion units; see ExpansionCatalog for how a unit file
## is assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "pc_engine_cd"

# The Interface Unit the console docks into sideways. Drawn as a base here
# for the same reason everything else is: one relation, one direction.
const ROW := {
	"label": "CD-ROM²",
	"host": "pc_engine",
	"media": "pc_engine_cd",
	"mount": ExpansionDefs.MOUNT_BELOW,
	"size": Vector3(0.26, 0.09, 0.22),
	"loader": MediaDimensions.LOADER_TRAY,
}


const BOOT := {
	# UNVERIFIED. The System Card goes in the console's own slot and the game is
	# on the CD.
	"pc_engine|pc_engine_cd": {
		"core": "mednafen_pce",
		"roms": ["expansion:pc_engine_cd"],
	},
}

## Sega CD — the disc drive the Mega Drive stands on.
##
## One of the eleven expansion units; see ExpansionCatalog for how a unit file
## is assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "sega_cd"

# Model 1 and Model 2 both sat UNDER the Mega Drive, which is why the console
# ends up in the middle of the tower rather than at the bottom of it.
const ROW := {
	"label": "Sega CD",
	"host": "mega_drive",
	"media": "sega_cd",
	"mount": ExpansionDefs.MOUNT_BELOW,
	"size": Vector3(0.32, 0.08, 0.28),
	"loader": MediaDimensions.LOADER_TRAY,
}


const BOOT := {
	# UNVERIFIED. The CD is the game; the cartridge slot is empty on a Mega-CD
	# title.
	"mega_drive|sega_cd": {
		"core": "genesis_plus_gx",
		"roms": ["expansion:sega_cd"],
	},
}

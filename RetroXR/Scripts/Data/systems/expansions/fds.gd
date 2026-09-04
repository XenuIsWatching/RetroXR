## Famicom Disk System — the RAM adapter and the drive under the console.
##
## One of the eleven expansion units; see ExpansionCatalog for how a unit file
## is assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "fds"

# The RAM adapter goes into the Famicom's cartridge slot and the drive sits
# under the console. Modelled as one unit, because you cannot use either half
# on its own and RetroXR has no cable between them to draw.
const ROW := {
	"label": "Famicom Disk System",
	"host": "nes",
	"media": "fds",
	"mount": ExpansionDefs.MOUNT_BELOW,
	"size": Vector3(0.28, 0.06, 0.22),
	"loader": MediaDimensions.LOADER_SLOT,
}


const BOOT := {
	# UNVERIFIED.
	"nes|fds": {
		"core": "fceumm",
		"roms": ["expansion:fds"],
	},
}

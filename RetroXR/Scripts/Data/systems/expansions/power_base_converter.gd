## Power Base Converter — lets a Genesis take a Master System cartridge.
##
## One of the expansion units; see ExpansionCatalog for how a unit file is
## assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "power_base_converter"

# Also into the cartridge slot, on top -- but unlike the 32X it runs no
# program of its own. It exists so a Master System cartridge fits a Genesis
# slot at all; the core sees the cartridge the same way it would if the
# console had booted straight into Master System mode, so no launch recipe
# is needed beyond naming the core. card must be forced to mega_drive: the
# default fallback in card_systemid is the unit's OWN media systemid, which
# is master_system, and a player who owns a Genesis is not looking on the
# Master System card for the thing that lets a Genesis take a Master System
# cartridge.
const ROW := {
	"label": "Power Base Converter",
	"host": "mega_drive",
	"media": "master_system",
	"mount": ExpansionDefs.MOUNT_CARTRIDGE,
	"size": Vector3(0.17, 0.045, 0.125),
	"loader": MediaDimensions.LOADER_NONE,
	"card": "mega_drive",
}


const BOOT := {
	# UNVERIFIED. The converter passes the cartridge through unmodified; the
	# same core that already runs a bare Master System sees the same cartridge.
	"mega_drive|power_base_converter": {
		"core": "genesis_plus_gx",
		"roms": ["expansion:power_base_converter"],
	},
}

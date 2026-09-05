## FM Sound Unit — Sega's own Mark III / Master System accessory: a box that
## plugs into the console's cartridge slot and offers a cartridge slot of its
## own on top, the same shape as the Power Base Converter -- except both ends
## are the same systemid here, so no card override is needed (media falls back
## to host). genesis_plus_gx sees the same cartridge either way; only the
## forced FM option (ForcedCoreOptions.fm_sound_unit) changes whether the
## console has an FM chip to give it.
##
## One of the expansion units; see ExpansionCatalog for how a unit file is
## assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "fm_sound_unit"

const ROW := {
	"label": "FM Sound Unit",
	"host": "master_system",
	"media": "master_system",
	"mount": ExpansionDefs.MOUNT_CARTRIDGE,
	"size": Vector3(0.13, 0.035, 0.11),
	"loader": MediaDimensions.LOADER_NONE,
}


const BOOT := {
	# UNVERIFIED. Same shape as the converter: the unit passes the cartridge
	# through, and the FM chip it adds is a forced option, not a different core
	# or a different rom to hand over.
	"master_system|fm_sound_unit": {
		"core": "genesis_plus_gx",
		"roms": ["expansion:fm_sound_unit"],
	},
}

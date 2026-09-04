## BS-X cartridge — the middle layer, and what the 8M Memory Pack goes into.
##
## One of the eleven expansion units; see ExpansionCatalog for how a unit file
## is assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "bsx_cart"

# The BS-X cartridge: the thing the 8M Memory Pack actually goes into.
#
# Real hardware is three layers, and this is the middle one. The base station
# above is a tuner with no mouth on it; what a player holds is this cartridge,
# which goes into the Super Famicom's own slot and carries the pack in a slot
# of its own — the same nesting the 32X and the Sufami Turbo already model.
#
# It runs in a bare Super Famicom, without the base station bolted on, exactly
# as the hardware does: the shell boots and the town is there, only nothing is
# being broadcast at it. So the boot recipes below cover the cartridge alone as
# well as the full stack, rather than refusing a machine a player can build.
#
# What the core is handed is the PACK, never this cartridge: snes9x takes the
# .bs as content and sources BS-X.bin itself from the system directory.
#
# Sized as a Super Famicom cartridge, because that is what it is -- the same
# footprint CART_SIZES gives super_nes, thickened to 24 mm so the pack's well
# has a wall either side of it. A cartridge-mounting unit stands upright in
# the slot (Y is the insert axis), so a flat slab here read as a low box lying
# on the console rather than a cart standing in it.
#
# The only row that names `firmware`. The shell this cartridge runs is not
# ours and is not in the pack: it is BS-X.bin in the core's system directory,
# which snes9x sources itself. Without that file the unit is a prop -- it goes
# into the slot, the machine starts, and there is no town on the other side --
# so the menu does not offer it until the file is installed.
const ROW := {
	"label": "BS-X",
	"host": "super_nes",
	"media": "satellaview",
	"mount": ExpansionDefs.MOUNT_CARTRIDGE,
	"save_owner": ExpansionDefs.SAVE_OWNER_UNIT,
	"size": Vector3(0.137, 0.088, 0.024),
	"loader": MediaDimensions.LOADER_NONE,
	"firmware": ["BS-X.bin"],
}


const BOOT := {
	# The BS-X cartridge, with or without the base station under the console. Both
	# boot from the pack in the CARTRIDGE's own slot, because that is the medium:
	# snes9x is handed the .bs and finds BS-X.bin in the system directory itself.
	"super_nes|bsx_cart": {
		"core": "snes9x",
		"roms": ["expansion:bsx_cart"],
		# Shell + pack as a PAIR. Without it the core sources the shell from
		# BS-X.bin in the system directory, so a translated BS-X in the cartridge
		# was ignored the moment a pack went into it -- the same machine booted
		# in two different languages depending on whether its bay was full.
		# Order is the core's: bsx_roms[] is { "BS-X Shell", "Memory Pack" }.
		"subsystem": {"ident": "bsx",
			"roms": ["expansion_rom:bsx_cart", "expansion_media:bsx_cart"],
			# The pack is flash, and the .bs IS that flash -- a download is
			# written back over the medium the player inserted, not to a save
			# file beside it.
			"writable": 1},
	},
	"super_nes|satellaview|bsx_cart": {
		"core": "snes9x",
		"roms": ["expansion:bsx_cart"],
		# Shell + pack as a PAIR. Without it the core sources the shell from
		# BS-X.bin in the system directory, so a translated BS-X in the cartridge
		# was ignored the moment a pack went into it -- the same machine booted
		# in two different languages depending on whether its bay was full.
		# Order is the core's: bsx_roms[] is { "BS-X Shell", "Memory Pack" }.
		"subsystem": {"ident": "bsx",
			"roms": ["expansion_rom:bsx_cart", "expansion_media:bsx_cart"],
			# The pack is flash, and the .bs IS that flash -- a download is
			# written back over the medium the player inserted, not to a save
			# file beside it.
			"writable": 1},
	},
}

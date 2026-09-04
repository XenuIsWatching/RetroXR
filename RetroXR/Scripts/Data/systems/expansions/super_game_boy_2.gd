## Super Game Boy 2 — the 1998 revision, with a crystal of its own.
##
## One of the eleven expansion units; see ExpansionCatalog for how a unit file
## is assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "super_game_boy_2"

# The 1998 revision, and a different machine rather than a reskin: the original
# derives its clock from the SNES and runs the Game Boy about 2.4% fast, where
# this one carries its own crystal and runs at true handheld speed.
#
# That difference costs nothing to model because the cartridge IS the program
# the console runs, so handing the core a different dump is the whole of the
# change. A core that emulated the adapter internally would have wanted an
# option toggled here instead.
#
# The dump's own SNES HEADER decides which machine it is, NOT the filename
# below. Checked at source and against both files: the titles at 0x7FC0 read
# "Super GAMEBOY" and "Super GAMEBOY2", bsnes matches those against its bundled
# board database, and Cartridge::loadICD takes the ICD's oscillator out of the
# board it picked. icd.cpp branches on that one number -- zero is an SGB1 on
# the SNES's own clock, running the handheld ~2.4% fast; non-zero is an SGB2
# with a dedicated crystal at true handheld speed -- and picks the SameBoy
# model and the boot ROM to match. Both boot ROMs are compiled into bsnes,
# which is why nothing here wants the sgb1.boot.rom that higan asks for.
#
# So the names below are only where RetroXR LOOKS. An SGB1 dump installed under
# the other name gives two adapters that are both an SGB1, and nothing here
# catches that: firmware_present accepts a MISMATCH deliberately, for the
# reason written out on BS-X.bin. The BIOS tab is where the md5 verdict shows.
#
# Gated on its OWN file, so a player who has one dump and not the other is
# offered exactly the machine they can build.
const ROW := {
	"label": "Super Game Boy 2",
	"host": "super_nes",
	"media": "game_boy",
	"mount": ExpansionDefs.MOUNT_CARTRIDGE,
	"size": Vector3(0.137, 0.088, 0.024),
	"loader": MediaDimensions.LOADER_NONE,
	"card": "super_nes",
	"rom_title": "Super GAMEBOY2",
	"firmware": ["SGB2.sfc"],
	"rom_from_firmware": true,
}


const BOOT := {
	# A row of its own rather than a shared one, and not for tidiness: firmware_present
	# finds a unit's core through the unit's OWN recipe, so a unit with no recipe is
	# not gated at all -- which would offer a Super Game Boy 2 to a player who has no
	# dump of one. Both are MOUNT_CARTRIDGE and a Super Famicom has one slot, so no
	# combined row can arise.
	"super_nes|super_game_boy_2": {
		"core": "bsnes",
		"roms": ["expansion:super_game_boy_2"],
		"subsystem": {"ident": "sgb",
			"roms": ["expansion_media:super_game_boy_2", "expansion_rom:super_game_boy_2"]},
	},
}

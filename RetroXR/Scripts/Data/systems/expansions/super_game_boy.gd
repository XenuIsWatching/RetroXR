## Super Game Boy — a Super Famicom cartridge with a Game Boy slot.
##
## One of the eleven expansion units; see ExpansionCatalog for how a unit file
## is assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "super_game_boy"

# The Super Game Boy: a Super Famicom cartridge with a Game Boy slot in its
# roof, which runs the handheld's game on a television inside a border.
#
# The same three layers as the BS-X cartridge, and modelled the same way: a
# cartridge to the console it goes into, a console to the cartridge that goes
# into it. What differs is where its own program comes from -- the BS-X
# cartridge is a .sfc a player spawns out of the library, and this one is a
# BIOS the core reads from its system directory, which is what
# `rom_from_firmware` is for.
#
# `media` is game_boy, an existing system, so the handheld library already
# fills this bay: no new roms folder and no new content routing, and a Game
# Boy cartridge a player already owns is the same object either way.
#
# No save_owner. The BS-X cartridge names ExpansionDefs.SAVE_OWNER_UNIT because it has a
# battery of its own, holding the town and the player's name. A Super Game Boy
# has none -- the battery is in the cartridge seated in it -- so the default,
# which is the media, is the right one.
#
# Sized as the Super Famicom cartridge it is: the same footprint as the BS-X
# cartridge above.
const ROW := {
	"label": "Super Game Boy",
	"host": "super_nes",
	"media": "game_boy",
	"mount": ExpansionDefs.MOUNT_CARTRIDGE,
	"size": Vector3(0.137, 0.088, 0.024),
	"loader": MediaDimensions.LOADER_NONE,
	"card": "super_nes",
	"rom_title": "Super GAMEBOY",
	"firmware": ["SGB1.sfc"],
	"rom_from_firmware": true,
}


const BOOT := {
	# VERIFIED against bsnes-libretro, bsnes/target-libretro/libretro.cpp:
	#
	#   sgb_roms[]  = { "Game Boy ROM" (gb|gbc), "Super Game Boy ROM" (smc|sfc) }
	#   subsystems[] = { "Super Game Boy", "sgb", sgb_roms, 2, RETRO_GAME_TYPE_SGB }
	#
	# and retro_load_game_special assigns gameBoy.location = info[0] and
	# superFamicom.location = info[1]. So the HANDHELD's cartridge goes first and
	# the adapter's own cartridge second -- the reverse of the BS-X rows above,
	# which are shell-first, and the reason the two orders are written out per row
	# rather than assumed to be the same.
	#
	# The core is NOT the platform default, and cannot be. snes9x defines
	# RETRO_GAME_TYPE_SUPER_GAME_BOY and then never puts it in the subsystems[] it
	# publishes, so a frontend cannot reach it; retro_load_game_special drops that
	# game type into its default case and reports the load failed. The constant is
	# vestigial. Naming snes9x here would give a machine that refuses to start.
	#
	# No `writable`. That key exists for the BS-X pack, which is flash the core
	# writes a download back onto, and SetPackPath is bound to the SNES pack memory
	# region specifically. A Game Boy cartridge's save is an ordinary SRAM and
	# belongs on the ordinary path.
	"super_nes|super_game_boy": {
		"core": "bsnes",
		"roms": ["expansion:super_game_boy"],
		"subsystem": {"ident": "sgb",
			"roms": ["expansion_media:super_game_boy", "expansion_rom:super_game_boy"]},
	},
}

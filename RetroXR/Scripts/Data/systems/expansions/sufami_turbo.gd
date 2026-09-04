## Sufami Turbo — the Bandai adapter that takes two cartridges.
##
## One of the eleven expansion units; see ExpansionCatalog for how a unit file
## is assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "sufami_turbo"

# Sufami Turbo is the other thing that goes in a Super Famicom slot — on TOP,
# like the 32X — and it is the only unit here that takes TWO cartridges.
#
# That is not decoration. Nine of its thirteen games link the cartridge in the
# second slot into the game in the first: the six SD Gundam Generation titles
# lend each other their fighters, and SD Ultra Battle lends its characters
# across the pair. A one-slot Sufami Turbo would be the wrong machine, not a
# simplified one.
#
# 140 mm wide rather than the 120 it carried while it had one implicit well.
# Two wells cut for a 55 mm cartridge are 59 mm each, so two of them plus a
# wall between and a wall either side do not fit in 120 -- the box was sized
# for the bay it had, and it grows for the bay it should always have had.
#
# And SHALLOW: 38 mm front to back, not 100. The real adapter is a wide flat
# bar, and the wells cut into it are only `cart.z + 4` = 16 mm deep, so a
# 100 mm box was 84 mm of nothing behind them -- it read as a chunky console
# in its own right rather than the thin tray a cartridge stands out of.
# 30 mm tall for the same reason.
#
# 38 is close to the floor. The well needs 16, and the walls in front of and
# behind it are 11 mm each at this depth; much less and the mouth starts
# eating the front face the nameplate is printed on.
#
# Nothing here depends on either figure: the wells sit on the roof at
# s.y * 0.5, spread along X by _build_well_bay's own arithmetic, and the
# nameplate hangs below the join. Only the WIDTH is load-bearing, and only
# because two wells have to fit across it.
#
# The firmware is the adapter's own shell program, which snes9x loads itself
# from its system directory. Without it the unit is a prop, so the menu does
# not offer it -- the same contract the BS-X cartridge has, and NOT
# rom_from_firmware: STBIOS.bin is deliberately built to FAIL the core's
# is_SufamiTurbo_Cart test (it carries the "SFC-ADX BACKUP" marker that a
# cartridge must not have), which is how the core tells its BIOS from a game.
# Handed over as content it would load as a plain Super Famicom ROM.
#
# No save_owner: a Sufami Turbo has no battery. The cartridges do.
const ROW := {
	"label": "Sufami Turbo",
	"host": "super_nes",
	"media": "sufami_turbo",
	"mount": ExpansionDefs.MOUNT_CARTRIDGE,
	"size": Vector3(0.14, 0.03, 0.038),
	"loader": MediaDimensions.LOADER_NONE,
	"bays": 2,
	"firmware": ["STBIOS.bin"],
}


const BOOT := {
	# VERIFIED against snes9x source, and it is the second row here whose core has
	# a dead constant for the machine it is meant to run.
	# RETRO_GAME_TYPE_SUFAMI_TURBO is #defined AND has a working case in
	# retro_load_game_special -- and is registered in no subsystem, so no
	# frontend can reach it. Do not be fooled by the grep hit; the same trap sits
	# in this core for the Super Game Boy.
	#
	# What IS reachable is the Multi-Cart Link, which is the Sufami Turbo path in
	# all but name. Its case sniffs the FIRST cartridge --
	# is_SufamiTurbo_Cart(romptr[0]) -- and on a hit loads STBIOS.bin and calls
	# LoadMultiCartMem(A, B, bios). A cartridge that is NOT one takes a generic
	# no-BIOS multi-cart branch instead.
	#
	# Measured, because the obvious guess is wrong: a Sufami cartridge with no
	# STBIOS.bin installed does not fall through to that generic branch. The load
	# is simply refused -- rom_loaded stays false, no frames, and the machine
	# says so. Which is why `firmware` above is a gate on offering the unit at
	# all rather than a hope.
	#
	# One cartridge is a first-class configuration rather than a tolerated one:
	# retro_load_game auto-detects a lone cart from its "BANDAI SFC-ADX" header
	# and maps slot B empty. So the ordinary preference list below IS the
	# single-cart machine, and the pairing completes only when both wells are
	# full -- _start_subsystem_content falls back to the plain load on a count
	# mismatch, so the split needs no branch of its own.
	#
	# expansion_media: rather than the plain expansion: form, because the plain
	# one falls back to the unit's own ROM and there is none. An empty Sufami
	# Turbo must say its slots are empty, not try to boot its BIOS as a game.
	#
	# BOTH cartridges keep their saves, and that took a bridge change rather than
	# a data one. snes9x lays slot A's SRAM at the start of one block and slot B's
	# 0x10000 into it, and retro_get_memory_size answers RETRO_MEMORY_SAVE_RAM and
	# RETRO_MEMORY_SNES_SUFAMI_TURBO_A_RAM from the SAME case -- slot A alone, so
	# a frontend reading only SAVE_RAM keeps half a linked pair's progress. Slot B
	# lives under _B_RAM and is now read and written through Libretro.SetSramBPath,
	# to a file of its own.
	#
	# It is keyed off the CARTRIDGE, not the slot: a game carries its save between
	# the two wells, and lending it to a different pairing does not overwrite it.
	# See RetroSystem._slot_b_save_path.
	"super_nes|sufami_turbo": {
		"core": "snes9x",
		"roms": ["expansion_media:sufami_turbo", "expansion_media_b:sufami_turbo"],
		"subsystem": {"ident": "multicart_addon",
			"roms": ["expansion_media:sufami_turbo", "expansion_media_b:sufami_turbo"]},
	},
}

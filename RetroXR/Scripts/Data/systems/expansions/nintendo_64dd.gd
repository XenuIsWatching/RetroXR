## Nintendo 64DD — the drive the console stands on.
##
## One of the eleven expansion units; see ExpansionCatalog for how a unit file
## is assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "nintendo_64dd"

# The one that started this. It bolts to the N64's underside through the
# expansion port behind the hatch in the floor, and it is TALLER than the
# console it carries. Cartridge in the N64, disk in the drive, and the two
# are loaded together as one title.
const ROW := {
	"label": "Nintendo 64DD",
	"host": "nintendo_64",
	"media": "nintendo_64dd",
	"mount": ExpansionDefs.MOUNT_BELOW,
	"size": Vector3(0.30, 0.11, 0.26),
	"loader": MediaDimensions.LOADER_SLOT,
}


# VERIFIED against mupen64plus-libretro-nx source. Two quite different cases,
# which is why this row is the only one with a second core:
#
#   CART + EXPANSION DISK (F-Zero X Expansion Kit) — NOT PROPERLY SUPPORTED
#   YET, and the reason the `subsystem` entry below exists. The core is handed
#   the CARTRIDGE and looks for the disk itself, by the cart's FULL filename
#   plus ".ndd" in the SAME directory ("F-Zero X (Japan).z64.ndd", not
#   "F-Zero X (Japan).ndd"). That only works if the two files were arranged
#   for it in advance. A real library has the cart in the n64 roms dir and the
#   disk in the n64dd one, under its own name, and no arrangement of physical
#   objects in the room can change where a file lives. Staging a copy is not
#   the answer either: the rule needs file A and file A+".ndd" side by side,
#   so whichever directory you pick, a 64 MB disk gets copied per launch — on
#   Quest, before the game starts — and DirAccess has no hardlink API to make
#   it free. The core's own comment calls the sidecar "Workaround for broken
#   subsystem on static platforms"; a second workaround stacked on it is the
#   wrong direction. So this case boots the cartridge and RetroSystem WARNS,
#   by name, that the drive will be ignored — which beats a cart that boots
#   fine and looks correct, where the only tell is a missing 64DD line on the
#   title screen. retro_load_game_special is sound in the core for num_info==2
#   and is the mechanism this wants.
#
#   DISK ONLY (Mario Artist, Kyojin no Doshin) — the core is handed the .ndd
#   and no cartridge. The row names no core for that case (see
#   core_only_with_host): the machine takes whichever N64 core the player is
#   on, and both take a bare disk. parallel_n64 always could; mupen64plus_next
#   does as of the retroXR fork in core_sources.gd (tag
#   retroxr-mupen64plus-next-libretro-v1, plain and _gles3), which detects a
#   disk at load and issues DISK_OPEN rather than the M64CMD_ROM_OPEN that
#   made is_valid_rom() refuse one. Measured on the fork 2026-09-03 with
#   Mario Artist - Paint Studio: 1222 frames, IPL animation to 64DD logo to
#   title to gallery. The stock build refuses the same disk at 0 frames.
#
# Either way the IPL is the core's business: it ignores any path handed to it
# and reads <system>/Mupen64plus/IPL.n64 unconditionally.
const BOOT := {
	"nintendo_64|nintendo_64dd": {
	"core": "mupen64plus_next",
	"core_only_with_host": true,
	"roms": ["host", "expansion:nintendo_64dd"],
	"sidecar": ".ndd",
	# Verified at source: libretro.c declares dd_roms[] as { "Disk", "Cartridge" }
	# with ident "ndd" (the desc is "N64 Disk Drive"). Disk FIRST — the reverse
	# of `roms` above, which is a preference order and not a pairing.
	"subsystem": {"ident": "ndd",
		"roms": ["expansion:nintendo_64dd", "host"]},
},
}

## Satellaview — the broadcast tuner the Super Famicom stands on.
##
## One of the eleven expansion units; see ExpansionCatalog for how a unit file
## is assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "satellaview"

# The BS-X unit clips under the Super Famicom. Its "media" is the 8M memory
# pack; the broadcast that filled it is gone, so what a player has is the
# dumps of it — which is exactly what the satellaview systemid already holds.
#
# And that media does NOT go into this unit. The base station is a tuner and a
# modem, with no mouth of any kind on it: what a player pushes in is the BS-X
# cartridge, and it goes into the SUPER FAMICOM's slot, on top. media_in_host
# says so, and it is the only row here that needs to — every other expansion
# really does have a bay of its own.
#
# Modelled with a bay it produced the one arrangement that cannot work. A unit
# the console stands ON puts its bay on its ROOF, and its roof is underneath
# the Super Famicom, so the pack went into a well sandwiched between the two
# machines and disappeared. It was invisible even unstacked: a plain snap zone
# seats an object by its ORIGIN, so the cartridge's middle landed on the roof
# plane with half of it inside a 70 mm box.
const ROW := {
	"label": "Satellaview",
	"host": "super_nes",
	"media": "satellaview",
	"mount": ExpansionDefs.MOUNT_BELOW,
	"size": Vector3(0.29, 0.07, 0.24),
	"loader": MediaDimensions.LOADER_NONE,
	"media_in_host": true,
	"panel": "res://Scenes/Objects/satellaview_panel.tscn",
}


const BOOT := {
	# VERIFIED against snes9x source. The core is handed the .bs ALONE — not the
	# host cartridge — auto-detects BS-X from the content header, and sources
	# BS-X.bin itself from the ROM dir or the system dir. There is no subsystem to
	# name; the RETRO_GAME_TYPE_BSX path exists in the core but is never
	# advertised, so a frontend cannot reach it.
	#
	# This row is for a STANDALONE .bs dump of an already-downloaded programme.
	#
	# A BS-SLOTTED cartridge (Itoi Bass Fishing) plus a pack is the one case that
	# genuinely wants snes9x's "multicart_addon" subsystem, host cart first. It is
	# not written here because no subsystem path exists to carry it.
	#
	# "host", not "expansion:satellaview": the Satellaview has no bay (see
	# media_in_host on its ROWS entry), so the .bs is in the Super Famicom's own
	# slot. Same file either way — this row exists to pin the core, not to find it.
	"super_nes|satellaview": {
		"core": "snes9x",
		"roms": ["host"],
	},
}

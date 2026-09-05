## Expansion Pak — the 4 MB upgrade that unlocks a handful of N64 titles.
##
## One of the expansion units; see ExpansionCatalog for how a unit file is
## assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "expansion_pak"

# The one unit here with no bay and no launch recipe: it carries no media of
# its own and does not change which core the console resolves to, only how
# much RAM that core hands the game. It has to be MOUNT_ABOVE and not
# MOUNT_CARTRIDGE despite being cartridge-sized -- a MOUNT_CARTRIDGE unit
# fills the SAME snap zone a real cartridge does (_accepts_media shares one
# _cartridge_slot between the two). MOUNT_ABOVE grows the console its own
# ExpansionSocket instead, which is what keeps the two independent -- and
# unlike every other MOUNT_ABOVE unit, the N64 model relocates that socket
# forward, in front of the cartridge slot, and hides it behind a lift-off
# cover (RetroSystemModel.configure_expansion_socket), because that is where
# the real port is: a shaft sunk 50 mm into the deck and the base below it.
#
# Measured off a NUS-007: 51.5 wide, 46 tall, 23 front to back across the red
# top. It stands upright, which is what the console's well is a shaft for.
#
# Below the red top the real body steps in to 14 mm; this box stays 23 all the
# way down. That step is inside the well under the lid and never visible.
#
# cap_color paints the top plate red -- a perforated vent on the real part, and
# the only thing that tells a seated Expansion Pak from a Jumper Pak.
const ROW := {
	"label": "Expansion Pak",
	"host": "nintendo_64",
	"media": "",
	"mount": ExpansionDefs.MOUNT_ABOVE,
	"size": Vector3(0.0515, 0.046, 0.023),
	"loader": MediaDimensions.LOADER_NONE,
	"cap_color": Color(0.62, 0.10, 0.12),
}


## No BOOT row: see expansion_catalog.gd's own note that a combination with
## none still stacks and still launches as the bare console would. This one
## really has nothing to add there -- RetroSystem._expansion_pak_options is
## the whole of what attaching it does.
const BOOT := {}

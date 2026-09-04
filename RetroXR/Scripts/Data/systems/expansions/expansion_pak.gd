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
# the real port is: a well sunk into the deck, sized to the real Jumper/
# Expansion Pak (55 x 18 x 45 mm) rather than to the N64DD-scale box this row
# started as.
#
# cap_color paints the top plate red -- the real Expansion Pak's one visible
# difference from the Jumper Pak it replaces, and the only thing that tells
# a player which is currently seated in a bay where both are the same size
# and shape.
const ROW := {
	"label": "Expansion Pak",
	"host": "nintendo_64",
	"media": "",
	"mount": ExpansionDefs.MOUNT_ABOVE,
	"size": Vector3(0.055, 0.018, 0.045),
	"loader": MediaDimensions.LOADER_NONE,
	"cap_color": Color(0.62, 0.10, 0.12),
}


## No BOOT row: see expansion_catalog.gd's own note that a combination with
## none still stacks and still launches as the bare console would. This one
## really has nothing to add there -- RetroSystem._expansion_pak_options is
## the whole of what attaching it does.
const BOOT := {}

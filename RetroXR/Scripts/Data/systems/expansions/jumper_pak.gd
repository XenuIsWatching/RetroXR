## Jumper Pak — the dummy module every N64 ships with, in the same bay the
## Expansion Pak upgrades into.
##
## One of the expansion units; see ExpansionCatalog for how a unit file is
## assembled into the catalog, and expansion_defs.gd for the MOUNT_* values.
extends RefCounted

const ID := "jumper_pak"

# Every N64 ships with one of these already in the port: a dummy module with
# no RAM at all, there only for electrical continuity. Same socket, same
# filter as the Expansion Pak -- the two never coexist because a MOUNT_ABOVE
# socket holds one object, which is the whole mechanism behind "pull this out
# and put that in instead." RetroSystem seats one automatically the first
# time a bare N64 is built (never on a restore -- see default_occupant_for
# and _restoring_from_save in system.gd).
const ROW := {
	"label": "Jumper Pak",
	"host": "nintendo_64",
	"media": "",
	"mount": ExpansionDefs.MOUNT_ABOVE,
	# The Expansion Pak's shell (see expansion_pak.gd): the two swap into one
	# bay, so the size is the same. Only the top differs -- no red vent, hence
	# no cap_color.
	"size": Vector3(0.0515, 0.046, 0.023),
	"loader": MediaDimensions.LOADER_NONE,
	"default_occupant": true,
}


## No BOOT row, same as the Expansion Pak it shares a socket with -- and for a
## Jumper Pak there is even less reason for one, since it is functionally
## inert by definition.
const BOOT := {}

## ExpansionDefs — the enums an expansion row is written in terms of.
##
## Its own file so a unit under expansions/ can name MOUNT_BELOW without
## referencing ExpansionCatalog, which preloads that unit: GDScript refuses the
## cycle outright with "Identifier not declared in the current scope", and the
## error names the catalog rather than the cycle. ExpansionCatalog re-exports
## both sets, so callers still say ExpansionCatalog.MOUNT_BELOW.
class_name ExpansionDefs
extends RefCounted

## The console stands on the expansion — the expansion carries the top socket.
const MOUNT_BELOW := 0
## The expansion stands on the console — the console carries the top socket.
const MOUNT_ABOVE := 1
## The unit IS a cartridge: it goes into the console's own cartridge slot and
## fills it, and whatever the unit runs then goes into a slot of its own. A 32X,
## a Sufami Turbo and a Jaguar CD all attach this way, and none of the three
## consoles they attach to has a port on its roof -- modelling them as boxes
## that stand on top grew a socket on machines that never had one.
const MOUNT_CARTRIDGE := 2

## Which object holds the battery for a stack: the medium that was loaded, or
## the UNIT itself.
##
## Nearly always the medium -- a 64DD disk is magnetic and saves onto itself. The
## exception is a unit with its own battery behind the slot, where the save
## survives every medium passing through it. The BS-X cartridge is that: its
## 32 KB is the player's name and town, and keying it to the memory pack made a
## new pack look like a new BS-X.
const SAVE_OWNER_MEDIA := "media"
const SAVE_OWNER_UNIT := "unit"

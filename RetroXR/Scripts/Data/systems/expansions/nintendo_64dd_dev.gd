## Nintendo 64DD development unit -- the retail drive in the dev kit's shell.
##
## Same footprint, same bay, same launch: the difference is the case a
## developer's unit came in, so this row shares the retail unit's geometry and
## boot recipe and swaps only the colour map. See nintendo_64dd.gd.
extends RefCounted

const ID := "nintendo_64dd_dev"

const _RETAIL := preload("res://Scripts/Data/systems/expansions/nintendo_64dd.gd")

const ROW := {
	"label": "Nintendo 64DD (Development Unit)",
	"host": "nintendo_64",
	"media": "nintendo_64dd",
	"mount": ExpansionDefs.MOUNT_BELOW,
	"size": Vector3(0.26, 0.0787, 0.19),
	"loader": MediaDimensions.LOADER_SLOT,
	"shell": _RETAIL.SHELL,
	"shell_albedo": "res://imported-assets/consoles/nintendo_64dd/n64dd_drive_color_dev.png",
}

const BOOT := {
	"nintendo_64|nintendo_64dd_dev": _RETAIL.BOOT["nintendo_64|nintendo_64dd"],
}

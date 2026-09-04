## Card e-Reader+ (Japan, PSAJ) — the 8 MB revision, with the link port.
##
## The reader the Japanese card-e+ titles want, and the one that can talk to a
## second machine: the original PEAJ has no link socket at all. Same cards, same
## region as ereader.gd; a different dump and a different program.
##
## See ereader.gd for the shape of the row and why the revisions are separate.
extends RefCounted

const ID := "ereader_plus"

# Its media is `ereader`, not its own id, so has_own_card is false and this unit
# is offered from the e-Reader card rather than from a tile of its own. Three
# tiles for one shelf of cards would be three empty libraries.
const ROW := {
	"label": "Card e-Reader+",
	"host": "game_boy_advance",
	"media": "ereader",
	"mount": ExpansionDefs.MOUNT_CARTRIDGE,
	# See ereader.gd: the battery is in the reader, and each revision keeps its
	# own flash -- they are different hardware and their cards are region-locked.
	"save_owner": ExpansionDefs.SAVE_OWNER_UNIT,
	"size": Vector3(0.090, 0.062, 0.023),
	"loader": MediaDimensions.LOADER_SWIPE,
	# See ereader.gd: the header code is what a library dump is recognised by.
	"rom_code": "PSAJ",
}


const BOOT := {
	"game_boy_advance|ereader_plus": {
		"core": "mgba",
		"roms": ["expansion:ereader_plus"],
	},
}

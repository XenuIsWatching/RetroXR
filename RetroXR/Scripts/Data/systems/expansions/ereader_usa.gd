## e-Reader (USA, PSAE) — the 8 MB US reader, with the link port.
##
## The only reader that will read the 1489 US strips in the library: cards are
## region-locked and a Japanese reader answers one with its own Region Error
## screen. It is the same hardware as the Card e-Reader+, which is why both need
## the + calibration blob the fork seeds by game code.
##
## See ereader.gd for the shape of the row and why the revisions are separate.
extends RefCounted

const ID := "ereader_usa"

# Its media is `ereader`, not its own id, so has_own_card is false and this unit
# is offered from the e-Reader card rather than from a tile of its own. Three
# tiles for one shelf of cards would be three empty libraries.
const ROW := {
	"label": "e-Reader (USA)",
	"host": "game_boy_advance",
	"media": "ereader",
	"mount": ExpansionDefs.MOUNT_CARTRIDGE,
	"size": Vector3(0.090, 0.062, 0.023),
	"loader": MediaDimensions.LOADER_SWIPE,
	"firmware": ["ereader_usa.gba"],
	"rom_from_firmware": true,
}


const BOOT := {
	"game_boy_advance|ereader_usa": {
		"core": "mgba",
		"roms": ["expansion:ereader_usa"],
	},
}

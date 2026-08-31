## ScreenscraperSystems — maps project systemid strings to screenscraper.fr numeric systemeid values.
class_name ScreenscraperSystems
extends RefCounted


## Mapping from project systemid → screenscraper systemeid.
## Source: https://www.screenscraper.fr/webapi2.php (system list)
const SYSTEM_MAP := {
	"3do": 29,
	"3ds": 17,
	"amiga_cd32": 130,
	"amiga_cdtv": 129,
	"apple_ii": 86,
	"arcadia": 94,
	"atari_2600": 26,
	"atari_5200": 40,
	"atari_7800": 41,
	"atari_8bit": 43,
	"atari_jaguar": 27,
	"atari_lynx": 28,
	"atari_st": 42,
	"cdi": 133,
	"channel_f": 80,
	"colecovision": 48,
	"commodore_amiga": 64,
	"commodore_c128": 263,
	"commodore_c64": 66,
	"commodore_vic20": 73,
	"cpc": 65,
	"dos": 135,
	"dreamcast": 23,
	"fb_alpha": 75,
	"fds": 106,
	"game_boy": 9,
	"game_boy_advance": 12,
	"game_gear": 21,
	"gamecube": 13,
	# Screenscraper has no generic handheld-electronic platform, only Nintendo's
	# Game & Watch. A Tiger or Acclaim title reaches it as a name search and
	# usually misses, which costs it art rather than giving it the wrong art.
	"handheld_electronic": 52,
	"intellivision": 115,
	"jaguar_cd": 171,
	"mame": 75,
	"master_system": 2,
	"mega_drive": 1,
	"mega_duck": 90,
	"msx": 113,
	"nds": 15,
	"neo_geo_cd": 70,
	"neo_geo_pocket": 25,
	"neogeo": 142,
	"nes": 3,
	"nintendo_64": 14,
	"nintendo_64dd": 122,
	"odyssey2": 104,
	"pc_88": 221,
	"pc_98": 208,
	"pc_engine": 31,
	"pc_engine_cd": 114,
	"pc_fx": 72,
	"pico8": 234,
	"playstation": 57,
	"playstation2": 58,
	"playstation_portable": 61,
	"pokemon_mini": 211,
	"satellaview": 107,
	"scummvm": 123,
	"sega_32x": 19,
	"sega_cd": 20,
	"sega_pico": 250,
	"sega_saturn": 22,
	"sg1000": 109,
	"sharp_x1": 220,
	"sharp_x68000": 79,
	"sufami_turbo": 108,
	"super_nes": 4,
	"supergrafx": 105,
	"supervision": 207,
	"svi": 218,
	"ti_83": 205,
	"tic80": 222,
	"uzebox": 216,
	"vectrex": 102,
	"virtual_boy": 11,
	"wii": 16,
	"wonderswan": 45,
	"zx81": 77,
	"zx_spectrum": 76,
}


## Returns the screenscraper systemeid for a project systemid, or -1 if unmapped.
static func get_systemeid(systemid: String) -> int:
	if _mod_map.has(systemid):
		return int(_mod_map[systemid])
	return SYSTEM_MAP.get(systemid, -1)


## Mappings contributed by mods.
##
## A platform absent from SYSTEM_MAP can never be scraped, so a mod platform
## without one gets no box art, no wheel and no cart label -- ever. That failure
## is invisible: the carts simply stay blank, and nothing anywhere says why.
static var _mod_map: Dictionary = {}


static func register_mod_system(systemid: String, systemeid: int) -> void:
	if systemid.is_empty() or systemeid <= 0:
		return
	_mod_map[systemid] = systemeid

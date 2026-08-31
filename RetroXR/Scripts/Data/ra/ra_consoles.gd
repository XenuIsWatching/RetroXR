## RaConsoles — project systemid to RetroAchievements console id.
##
## rcheevos needs the console id before it can hash content: the hash rules are
## per-console (the iNES header is skipped for NES, N64 ROMs are byte-order
## normalised, disc images have their data track extracted), so passing the wrong
## id produces a hash that matches nothing on the server.
##
## A single map rather than an @export on each of the 76 SystemInfo resources —
## the same call RommPlatforms.SLUG_MAP makes for RomM's platform slugs.
##
## A system absent from this map, or mapped to 0, has no RetroAchievements
## equivalent and simply runs without achievements. That is the correct outcome
## for the home computers and the formats RA has no console page for; it is not a
## gap to be filled in with the nearest guess, because a wrong id means every
## hash for that system silently fails to resolve.
class_name RaConsoles


## Values are RC_CONSOLE_* from rcheevos/include/rc_consoles.h (v12.4.0).
const CONSOLE_MAP := {
	# Nintendo
	"nes": 7,                     # RC_CONSOLE_NINTENDO
	"fds": 81,                    # RC_CONSOLE_FAMICOM_DISK_SYSTEM
	"super_nes": 3,               # RC_CONSOLE_SUPER_NINTENDO
	"nintendo_64": 2,             # RC_CONSOLE_NINTENDO_64
	"gamecube": 16,               # RC_CONSOLE_GAMECUBE
	"wii": 19,                    # RC_CONSOLE_WII
	"game_boy": 4,                # RC_CONSOLE_GAMEBOY
	"game_boy_advance": 5,        # RC_CONSOLE_GAMEBOY_ADVANCE
	"nds": 18,                    # RC_CONSOLE_NINTENDO_DS
	"virtual_boy": 28,            # RC_CONSOLE_VIRTUAL_BOY
	"pokemon_mini": 24,           # RC_CONSOLE_POKEMON_MINI

	# Sega
	"master_system": 11,          # RC_CONSOLE_MASTER_SYSTEM
	"mega_drive": 1,              # RC_CONSOLE_MEGA_DRIVE
	"sega_cd": 9,                 # RC_CONSOLE_SEGA_CD
	"sega_32x": 10,               # RC_CONSOLE_SEGA_32X
	"sega_saturn": 39,            # RC_CONSOLE_SATURN
	"dreamcast": 40,              # RC_CONSOLE_DREAMCAST
	"game_gear": 15,              # RC_CONSOLE_GAME_GEAR
	"sg1000": 33,                 # RC_CONSOLE_SG1000
	"sega_pico": 68,              # RC_CONSOLE_PICO

	# Sony
	"playstation": 12,            # RC_CONSOLE_PLAYSTATION
	"playstation2": 21,           # RC_CONSOLE_PLAYSTATION_2
	"playstation_portable": 41,   # RC_CONSOLE_PSP

	# NEC
	"pc_engine": 8,               # RC_CONSOLE_PC_ENGINE
	"pc_engine_cd": 76,           # RC_CONSOLE_PC_ENGINE_CD
	# RetroAchievements files SuperGrafx titles under the PC Engine console.
	"supergrafx": 8,              # RC_CONSOLE_PC_ENGINE
	"pc_fx": 49,                  # RC_CONSOLE_PCFX
	"pc_88": 47,                  # RC_CONSOLE_PC8800
	"pc_98": 48,                  # RC_CONSOLE_PC9800

	# Atari
	"atari_2600": 25,             # RC_CONSOLE_ATARI_2600
	"atari_5200": 50,             # RC_CONSOLE_ATARI_5200
	"atari_7800": 51,             # RC_CONSOLE_ATARI_7800
	"atari_lynx": 13,             # RC_CONSOLE_ATARI_LYNX
	"atari_jaguar": 17,           # RC_CONSOLE_ATARI_JAGUAR
	"jaguar_cd": 77,              # RC_CONSOLE_ATARI_JAGUAR_CD
	"atari_st": 36,               # RC_CONSOLE_ATARI_ST

	# Other consoles and handhelds
	"3do": 43,                    # RC_CONSOLE_3DO
	"cdi": 42,                    # RC_CONSOLE_CDI
	"colecovision": 44,           # RC_CONSOLE_COLECOVISION
	"intellivision": 45,          # RC_CONSOLE_INTELLIVISION
	"vectrex": 46,                # RC_CONSOLE_VECTREX
	"odyssey2": 23,               # RC_CONSOLE_MAGNAVOX_ODYSSEY2
	"channel_f": 57,              # RC_CONSOLE_FAIRCHILD_CHANNEL_F
	"arcadia": 73,                # RC_CONSOLE_ARCADIA_2001
	"neo_geo_pocket": 14,         # RC_CONSOLE_NEOGEO_POCKET
	"wonderswan": 53,             # RC_CONSOLE_WONDERSWAN
	"supervision": 63,            # RC_CONSOLE_SUPERVISION
	"mega_duck": 69,              # RC_CONSOLE_MEGADUCK
	"handheld_electronic": 60,    # RC_CONSOLE_GAME_AND_WATCH
	"uzebox": 80,                 # RC_CONSOLE_UZEBOX

	# Arcade. Both cabinets resolve to the one RA console.
	"mame": 27,                   # RC_CONSOLE_ARCADE
	"fb_alpha": 27,               # RC_CONSOLE_ARCADE
	"neogeo": 27,                 # RC_CONSOLE_ARCADE — MVS/AES sets live here

	# Home computers
	"commodore_c64": 30,          # RC_CONSOLE_COMMODORE_64
	"commodore_vic20": 34,        # RC_CONSOLE_VIC20
	"commodore_amiga": 35,        # RC_CONSOLE_AMIGA
	"apple_ii": 38,               # RC_CONSOLE_APPLE_II
	"cpc": 37,                    # RC_CONSOLE_AMSTRAD_PC
	"msx": 29,                    # RC_CONSOLE_MSX
	"zx81": 31,                   # RC_CONSOLE_ZX81
	"zx_spectrum": 59,            # RC_CONSOLE_ZX_SPECTRUM
	"sharp_x1": 64,               # RC_CONSOLE_SHARPX1
	"sharp_x68000": 52,           # RC_CONSOLE_X68K
	"dos": 26,                    # RC_CONSOLE_MS_DOS

	# Fantasy consoles and calculators
	"tic80": 65,                  # RC_CONSOLE_TIC80
	"ti_83": 79,                  # RC_CONSOLE_TI83
}

## Systems RetroAchievements has no console page for. Listed rather than merely
## absent so the next person to add a cabinet can see these were considered:
##   amiga_cd32, amiga_cdtv  — RA tracks Amiga only as floppy-based Amiga
##   atari_8bit, commodore_c128, svi, nintendo_64dd
##   satellaview, sufami_turbo — RA hashes these into SNES subsets, not a console
##   chip_8, pico8, scummvm    — no RA console
const UNSUPPORTED := [
	"amiga_cd32", "amiga_cdtv", "atari_8bit", "commodore_c128", "svi",
	"nintendo_64dd", "satellaview", "sufami_turbo", "chip_8", "pico8", "scummvm",
]


## RC_CONSOLE_* for a systemid, or 0 when RetroAchievements has no equivalent.
static func for_systemid(systemid: String) -> int:
	if systemid.is_empty():
		return 0
	return int(CONSOLE_MAP.get(systemid, 0))


## True when this system can take part in RetroAchievements at all.
static func is_supported(systemid: String) -> bool:
	return for_systemid(systemid) > 0

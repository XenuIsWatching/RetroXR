## CoreRecommendations — the one core we suggest per system, badged in the Cores
## downloader and manager, sorted to the top of that system's list, and the set
## the Download tab's "Download All Recommended" button installs.
##
## Keyed by systemid rather than a flat set of core names: the same core can be
## the right pick for one machine and a poor one for another (the Mednafen family
## serves a dozen systems at very different quality), so a global "good cores"
## list would badge them everywhere.
##
## Exactly ONE core per system per platform. That invariant is what lets the
## download-all button install a full set without ever fetching two cores for one
## machine, so a new entry replaces the existing pick rather than joining it.
##
## `core` is the pick on desktop; `android` overrides it on Quest, where the
## budget is a phone SoC holding stereo at framerate and the more accurate core
## often buys nothing a player can see. A lighter core is named there only where
## it is mature enough to be a default — never to dodge a compatibility problem.
##
## Provenance: the table is seeded from RetroDECK's recommended-core list, which
## is community consensus rather than anything measured here. The entries below
## carrying a "measured here" note are the exceptions — those were run on this
## hardware and their reason is the observation, not the consensus. Anything else
## is a sensible default that has not been tested on a Quest.
class_name CoreRecommendations
extends RefCounted

const RECOMMENDED := {
	# ── Atari ────────────────────────────────────────────────────────────────
	"atari_2600": {
		"core": "stella",
		"why":  "Upstream Stella, still maintained; stella2014 is a fork of a decade-old snapshot",
	},
	"atari_5200": {
		"core": "atari800",
		"why":  "Covers the 5200 and the 8-bit line from one core, and is the maintained option",
	},
	"atari_7800": {
		"core": "prosystem",
		"why":  "The only 7800 core here",
	},
	"atari_lynx": {
		"core": "mednafen_lynx",
		"why":  "The most complete Lynx core; Handy is its unmaintained ancestor",
	},
	"atari_jaguar": {
		"core": "virtualjaguar",
		"why":  "The only Jaguar core here",
	},
	"jaguar_cd": {
		"core": "virtualjaguar",
		"why":  "Same core as the Jaguar — one download covers cartridge and CD games",
	},
	"atari_st": {
		"core": "hatari",
		"why":  "The only ST core here",
	},

	# ── Early consoles ───────────────────────────────────────────────────────
	"colecovision": {
		"core": "gearcoleco",
		"why":  "Purpose-built for the machine, where blueMSX reaches it as a sideline",
	},
	"intellivision": {
		"core": "freeintv",
		"why":  "The only Intellivision core here",
	},
	"odyssey2": {
		"core": "o2em",
		"why":  "The only Odyssey² core here",
	},
	"channel_f": {
		"core": "freechaf",
		"why":  "The only Channel F core here",
	},
	"vectrex": {
		"core": "vecx",
		"why":  "The only Vectrex core here",
	},
	"supervision": {
		"core": "potator",
		"why":  "The only Supervision core here",
	},
	"arduboy": {
		"core": "arduous",
		"why":  "Cheaper than Ardens and accurate enough for a 1-bit handheld",
	},

	# ── Nintendo handhelds ───────────────────────────────────────────────────
	# One entry covers Game Boy and Game Boy Color: no core in this database
	# declares a separate `game_boy_color` systemid, so the two share a tile.
	"game_boy": {
		"core":    "sameboy",
		"why":     "The most accurate GB/GBC core, and cheap enough to spend the accuracy on desktop",
		"android": "gambatte",
		"why_android": "SameBoy's sub-frame accuracy costs more than it shows on a handheld screen; Gambatte is mature and much lighter",
	},
	"game_boy_advance": {
		"core": "mgba",
		"why":  "Accurate, fast, and the only GBA core still actively developed",
	},
	"virtual_boy": {
		"core": "mednafen_vb",
		"why":  "The only Virtual Boy core here",
	},
	"pokemon_mini": {
		"core": "pokemini",
		"why":  "The only Pokémon Mini core here",
	},

	# ── Nintendo consoles ────────────────────────────────────────────────────
	"nes": {
		"core":    "mesen",
		"why":     "Cycle-accurate, and the reference for NES behaviour",
		"android": "fceumm",
		"why_android": "Mesen's accuracy is not free; FCEUmm has the widest mapper coverage of the light cores",
	},
	"super_nes": {
		"core": "snes9x",
		"why":  "Drives the SNES Mouse, and runs full speed on Quest where bsnes does not — measured here. Kept on desktop too so saves and core options are the same file on both platforms",
	},
	"nintendo_64": {
		"core":    "parallel_n64",
		"why":     "The Angrylion/ParaLLEl RDP path is the accurate one, and desktop can afford it",
		"android": "mupen64plus_next_gles3",
		"why_android": "Measured here: mupen64plus_next_gles2 runs at full speed on Quest but never draws a pixel — the gles3 build of the same core renders the same ROM correctly",
	},
	"nds": {
		"core": "melondsds",
		"why":  "The maintained melonDS port, and the one whose dual-screen layout the DS model's screen rects are cut against",
	},
	"3ds": {
		"core": "azahar",
		"why":  "The only 3DS core that emits side-by-side stereo, which the n3ds model's screen rects rely on",
	},
	# Both Dolphin systems point at the same core, and the recommendation is
	# really about WHICH BUILD: CoreSources replaces the buildbot's Dolphin with
	# our fork, which is the only one that can do Wiimote IR passthrough. On the
	# stock build a Wii Remote still points, but by a constant fitted per game.
	"gamecube": {
		"core": "dolphin",
		"why":  "The only GameCube core here, and the retroXR build adds the Wiimote IR passthrough a Wii disc in this cabinet needs",
	},
	"wii": {
		"core": "dolphin",
		"why":  "The retroXR build takes the Wiimote's aim from the real sensor bar in the room rather than a cursor position, which is what makes pointing land where you point",
	},

	# ── Sega ─────────────────────────────────────────────────────────────────
	# Genesis Plus GX serves five of these machines, so one core covers the whole
	# 8/16-bit line and the download-all button fetches it once.
	"master_system": {
		"core": "genesis_plus_gx",
		"why":  "Accurate across the whole Sega 8/16-bit line, so one core covers five systems",
	},
	"game_gear": {
		"core": "genesis_plus_gx",
		"why":  "Accurate across the whole Sega 8/16-bit line, so one core covers five systems",
	},
	"sg1000": {
		"core": "genesis_plus_gx",
		"why":  "Accurate across the whole Sega 8/16-bit line, so one core covers five systems",
	},
	"mega_drive": {
		"core": "genesis_plus_gx",
		"why":  "The accuracy reference for Mega Drive, and cheap enough to run everywhere",
	},
	"sega_cd": {
		"core": "genesis_plus_gx",
		"why":  "Best Sega CD compatibility, and shares its saves with the Mega Drive library",
	},
	"sega_32x": {
		"core": "picodrive",
		"why":  "The only core here that emulates the 32X at all",
	},
	"sega_saturn": {
		"core":    "mednafen_saturn",
		"why":     "The accurate Saturn core; it needs a fast CPU and desktop has one",
		"android": "yabasanshiro",
		"why_android": "Beetle Saturn cannot hold framerate on a phone SoC; YabaSanshiro is built for ARM and is the only practical Saturn core there",
	},
	"dreamcast": {
		"core": "flycast",
		"why":  "The only maintained Dreamcast core, and it runs well on both platforms",
	},
	"model3": {
		"core": "supermodel",
		"why":  "The only Model 3 core here",
	},

	# ── NEC ──────────────────────────────────────────────────────────────────
	"pc_engine": {
		"core":    "mednafen_pce",
		"why":     "The accurate PC Engine core, superseding the split PCE/SuperGrafx builds",
		"android": "mednafen_pce_fast",
		"why_android": "The accuracy the full core adds is not visible on this hardware, and Fast leaves headroom for the room around it",
	},
	"pc_engine_cd": {
		"core":    "mednafen_pce",
		"why":     "Same core as PC Engine — one download covers card and CD games",
		"android": "mednafen_pce_fast",
		"why_android": "Same core as PC Engine — one download covers card and CD games",
	},
	"supergrafx": {
		"core": "mednafen_supergrafx",
		"why":  "Beetle PCE Fast does not declare SuperGrafx, so this is the light option as well as the accurate one",
	},
	"pc_fx": {
		"core": "mednafen_pcfx",
		"why":  "The only PC-FX core here",
	},

	# ── Sony / 3DO ───────────────────────────────────────────────────────────
	"3do": {
		"core": "opera",
		"why":  "The only 3DO core here",
	},
	"playstation": {
		"core": "pcsx_rearmed",
		"why":  "Best speed-to-accuracy balance on Quest hardware, and kept on desktop too so saves, memory cards and core options are the same files on both platforms",
	},
	"playstation_portable": {
		"core": "ppsspp",
		"why":  "The only PSP core here, and it scales from Quest to desktop on its own settings",
	},
	"playstation2": {
		"core": "pcsx2",
		"why":  "The only PS2 core here",
	},

	# ── SNK ──────────────────────────────────────────────────────────────────
	# Keyed on fb_alpha rather than neogeo: FinalBurn Neo files itself under
	# fb_alpha, and the neogeo tile holds only Geolith.
	"fb_alpha": {
		"core": "fbneo",
		"why":  "The maintained FinalBurn line, and where Neo Geo AES/MVS support actually lives",
	},
	"neo_geo_cd": {
		"core": "neocd",
		"why":  "The only Neo Geo CD core here",
	},
	"neo_geo_pocket": {
		"core": "mednafen_ngp",
		"why":  "More complete than RACE, and cheap on both platforms",
	},
	"wonderswan": {
		"core": "mednafen_wswan",
		"why":  "The only WonderSwan core here (upstream renamed it Beetle Cygne)",
	},

	# ── Home computers ───────────────────────────────────────────────────────
	"msx": {
		"core": "bluemsx",
		"why":  "The widest machine coverage of the MSX cores, and it reaches ColecoVision, SG-1000 and SVI too",
	},
	"pc_98": {
		"core": "np2kai",
		"why":  "The maintained Neko Project fork",
	},
	"pc_88": {
		"core": "quasi88",
		"why":  "The only PC-88 core here",
	},
	"sharp_x68000": {
		"core": "px68k",
		"why":  "The only X68000 core here",
	},
	"cpc": {
		"core": "cap32",
		"why":  "More complete and better maintained than CrocoDS",
	},
	"zx_spectrum": {
		"core": "fuse",
		"why":  "The only ZX Spectrum core here",
	},
	"commodore_c64": {
		"core": "vice_x64sc",
		"why":  "The cycle-accurate VICE build; plain x64 trades that accuracy for speed neither platform needs",
	},
	"commodore_amiga": {
		"core": "puae",
		"why":  "The maintained UAE port, and it covers CD32 and CDTV from the same download",
	},
	"dos": {
		"core": "dosbox_pure",
		"why":  "Boots a game straight from its archive with no mount script, which is the only DOS core that suits a room with no keyboard",
	},

	# ── Arcade ───────────────────────────────────────────────────────────────
	"mame": {
		"core":    "mame",
		"why":     "Current MAME — the widest romset support, and desktop can carry it",
		"android": "mame2003_plus",
		"why_android": "Current MAME is far past a phone SoC's budget; 2003-Plus is the tuned ARM set and covers the arcade era this room is built around",
	},
}


## Whether this platform reads the `android` override. Quest is the only Android
## target, so the OS name is the whole test.
static func _is_mobile() -> bool:
	return OS.get_name() == "Android"


## The recommended core_name for a system on THIS platform, or "" when we have
## no opinion.
static func core_for(systemid: String) -> String:
	var entry: Dictionary = RECOMMENDED.get(systemid, {})
	if entry.is_empty():
		return ""
	if _is_mobile():
		var mobile := str(entry.get("android", ""))
		if not mobile.is_empty():
			return mobile
	return str(entry.get("core", ""))


static func is_recommended(systemid: String, core_name: String) -> bool:
	return not core_name.is_empty() and core_for(systemid) == core_name


## Every core this platform recommends, deduplicated, in table order.
##
## Deduplicated because the mapping is one core per SYSTEM, not per core: Genesis
## Plus GX is the pick for five Sega machines and Dolphin for two Nintendo ones,
## and a download-all built from the raw values would fetch each of them over
## again for every system it serves.
static func core_names() -> PackedStringArray:
	var names := PackedStringArray()
	for systemid: String in RECOMMENDED:
		var pick := core_for(systemid)
		if not pick.is_empty() and not names.has(pick):
			names.append(pick)
	return names


## Move the recommended entry to the front of a list of Dictionaries, leaving
## every other entry in the order it arrived. A partition rather than a
## sort_custom: Array.sort_custom is not stable, so ranking only by
## recommended-ness would shuffle the rest of the list arbitrarily.
static func first(systemid: String, entries: Array, key: String = "core_name") -> Array:
	var pick := core_for(systemid)
	if pick.is_empty():
		return entries
	var head: Array = []
	var tail: Array = []
	for e: Dictionary in entries:
		if str(e.get(key, "")) == pick:
			head.append(e)
		else:
			tail.append(e)
	return head + tail

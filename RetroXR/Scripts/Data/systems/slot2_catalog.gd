## Slot2Catalog — a console's SECOND native cartridge slot, and how the pair boots.
##
## The Nintendo DS has two slots moulded into the shell: Slot-1 on the back edge
## for a DS Game Card and Slot-2 on the front edge for a Game Boy Advance
## cartridge, which a DS game may read (the Pokémon dual-slot transfer, Mega Man
## ZX, Portrait of Ruin, the Boktai solar sensor). There is no box to bolt on,
## so it is not an expansion unit — but the launch is the same shape as one, a
## `roms` list and a `subsystem` pairing, so ExpansionLaunch reads it as one.
##
## VERIFIED against JesseTG/melonds-ds, src/libretro/info.cpp:
##
##   slot_1_2_roms[] = { {"Nintendo DS (Slot 1)", "nds",     need_fullpath=false, required=true},
##                       {"GBA (Slot 2)",         "gba",     need_fullpath=false, required=true},
##                       {"GBA Save Data",        "srm|sav", need_fullpath=true,  required=false} }
##   subsystems[]    = { {"Slot 1 & 2 Boot",                    "gba",      3 roms},
##                       {"Slot 1 & 2 Boot (No GBA Save Data)", "gbanosav", 2 roms} }
##
## and core/core.cpp assigns game[0] to the DS card, game[1] to the GBA ROM
## (asserting its data was read into memory, which the bridge does for every
## need_fullpath=false entry) and game[2] to the GBA save PATH.
##
## The GBA save never goes through retro_get_memory_data: the core reads that
## path itself (LoadGbaSram) and writes it back itself (FlushGbaSram, on a timer
## and at unload). Two consequences decide the row below. LoadGbaSram THROWS on
## a path that does not exist — "Failed to open GBA save file" and the load
## fails — and tolerates an empty file, so the launch creates one before the
## call (see ExpansionLaunch's slot2_save token). And `gbanosav` never writes a
## save at all, so it is not a fallback: a player's progress would be lost every
## time the machine was switched off.
##
## The core is pinned because DeSmuME publishes no such subsystem. The recipe
## exists only while a GBA cartridge is seated, so an empty Slot-2 leaves the
## player's own core choice alone.
##
## Netplay starts every machine through the single-ROM path, so a DS with a GBA
## cartridge in it boots its DS card alone in a session. Not extended here.
class_name Slot2Catalog
extends RefCounted

const ROWS: Dictionary = {
	"nds": {
		"media": "game_boy_advance",
		"core": "melondsds",
		"roms": ["host"],
		"subsystem": {"ident": "gba", "roms": ["host", "slot2", "slot2_save"]},
	},
}


## The systemid of the media a console's second slot takes, or "" for every
## console that has one slot.
static func media_of(host: String) -> String:
	return str((ROWS.get(host, {}) as Dictionary).get("media", ""))


## The launch recipe for a console with its second slot FILLED, or {}.
static func boot_for(host: String) -> Dictionary:
	var row: Dictionary = ROWS.get(host, {})
	if row.is_empty():
		return {}
	var out := row.duplicate(true)
	out.erase("media")
	return out

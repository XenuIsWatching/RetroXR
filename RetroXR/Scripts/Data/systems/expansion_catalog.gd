## ExpansionCatalog — the historical console expansions, as physical units.
##
## A 64DD is not a different Nintendo 64 and a Mega-CD is not a different Mega
## Drive. Each was a separate box you bought, carried home and BOLTED TO the
## console: the 64DD went under the N64 through the hatch in its floor, the
## Mega-CD went under the Mega Drive, the 32X went into the cartridge slot on
## top. Two machines, two pieces of media, one stack.
##
## RetroXR used to model each combination as its own systemid — "nintendo_64dd"
## and "sega_cd" sat in the systems list beside the consoles they plug into, and
## spawning one gave you a whole imaginary console that never existed. This file
## is the other way round: an expansion is a THING, it spawns on its own, and it
## only does anything once a console is actually standing on it.
##
## What a row says
## ---------------
##   label       row text in the spawn menu, and the name printed on the unit
##   host        the console systemid this unit belongs to
##   media       the systemid of the media its OWN bay takes ("nintendo_64dd" for
##               a 64DD disk). Empty when the unit takes no media of its own.
##   mount       MOUNT_BELOW — the console stands ON this unit (64DD, Mega-CD)
##               MOUNT_ABOVE — this unit stands on the CONSOLE (32X, Jaguar CD)
##   size        the primitive box, in metres
##   loader      MediaDimensions.LOADER_* for its own bay
##   media_in_host
##               this unit has NO bay: its media goes into the CONSOLE's own
##               cartridge slot. See the Satellaview row.
##
## Which way a unit mounts is the whole of the geometry: the LOWER object always
## wears the socket (a snap zone on its top face) and the UPPER object always
## wears the foot (a snap grab point on its underside). One relation, drawn from
## whichever side the row says. That is what lets the Tower of Power exist
## without a single line about towers: a Mega-CD accepts a Mega Drive on its top,
## and that same Mega Drive accepts a 32X on ITS top, so the three stack by two
## independent facts rather than by a special case.
class_name ExpansionCatalog
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


## Every expansion RetroXR models, keyed by its id. The id doubles as the media
## systemid wherever one exists, so the Games tab already spawns the right disks
## and carts for it with no second table.
const ROWS: Dictionary = {
	# The one that started this. It bolts to the N64's underside through the
	# expansion port behind the hatch in the floor, and it is TALLER than the
	# console it carries. Cartridge in the N64, disk in the drive, and the two
	# are loaded together as one title.
	"nintendo_64dd": {
		"label": "Nintendo 64DD",
		"host": "nintendo_64",
		"media": "nintendo_64dd",
		"mount": MOUNT_BELOW,
		"size": Vector3(0.30, 0.11, 0.26),
		"loader": MediaDimensions.LOADER_SLOT,
	},
	# The RAM adapter goes into the Famicom's cartridge slot and the drive sits
	# under the console. Modelled as one unit, because you cannot use either half
	# on its own and RetroXR has no cable between them to draw.
	"fds": {
		"label": "Famicom Disk System",
		"host": "nes",
		"media": "fds",
		"mount": MOUNT_BELOW,
		"size": Vector3(0.28, 0.06, 0.22),
		"loader": MediaDimensions.LOADER_SLOT,
	},
	# The BS-X unit clips under the Super Famicom. Its "media" is the 8M memory
	# pack; the broadcast that filled it is gone, so what a player has is the
	# dumps of it — which is exactly what the satellaview systemid already holds.
	#
	# And that media does NOT go into this unit. The base station is a tuner and a
	# modem, with no mouth of any kind on it: what a player pushes in is the BS-X
	# cartridge, and it goes into the SUPER FAMICOM's slot, on top. media_in_host
	# says so, and it is the only row here that needs to — every other expansion
	# really does have a bay of its own.
	#
	# Modelled with a bay it produced the one arrangement that cannot work. A unit
	# the console stands ON puts its bay on its ROOF, and its roof is underneath
	# the Super Famicom, so the pack went into a well sandwiched between the two
	# machines and disappeared. It was invisible even unstacked: a plain snap zone
	# seats an object by its ORIGIN, so the cartridge's middle landed on the roof
	# plane with half of it inside a 70 mm box.
	"satellaview": {
		"label": "Satellaview",
		"host": "super_nes",
		"media": "satellaview",
		"mount": MOUNT_BELOW,
		"size": Vector3(0.29, 0.07, 0.24),
		"loader": MediaDimensions.LOADER_NONE,
		"media_in_host": true,
		"panel": "res://Scenes/Objects/satellaview_panel.tscn",
	},
	# The BS-X cartridge: the thing the 8M Memory Pack actually goes into.
	#
	# Real hardware is three layers, and this is the middle one. The base station
	# above is a tuner with no mouth on it; what a player holds is this cartridge,
	# which goes into the Super Famicom's own slot and carries the pack in a slot
	# of its own — the same nesting the 32X and the Sufami Turbo already model.
	#
	# It runs in a bare Super Famicom, without the base station bolted on, exactly
	# as the hardware does: the shell boots and the town is there, only nothing is
	# being broadcast at it. So the boot recipes below cover the cartridge alone as
	# well as the full stack, rather than refusing a machine a player can build.
	#
	# What the core is handed is the PACK, never this cartridge: snes9x takes the
	# .bs as content and sources BS-X.bin itself from the system directory.
	#
	# Sized as a Super Famicom cartridge, because that is what it is -- the same
	# footprint CART_SIZES gives super_nes, thickened to 24 mm so the pack's well
	# has a wall either side of it. A cartridge-mounting unit stands upright in
	# the slot (Y is the insert axis), so a flat slab here read as a low box lying
	# on the console rather than a cart standing in it.
	"bsx_cart": {
		"label": "BS-X",
		"host": "super_nes",
		"media": "satellaview",
		"mount": MOUNT_CARTRIDGE,
		"save_owner": SAVE_OWNER_UNIT,
		"size": Vector3(0.137, 0.088, 0.024),
		"loader": MediaDimensions.LOADER_NONE,
	},
	# Sufami Turbo is the other thing that goes in a Super Famicom slot — on TOP,
	# like the 32X, and it takes its own small carts.
	"sufami_turbo": {
		"label": "Sufami Turbo",
		"host": "super_nes",
		"media": "sufami_turbo",
		"mount": MOUNT_CARTRIDGE,
		"size": Vector3(0.12, 0.05, 0.10),
		"loader": MediaDimensions.LOADER_NONE,
	},
	# Model 1 and Model 2 both sat UNDER the Mega Drive, which is why the console
	# ends up in the middle of the tower rather than at the bottom of it.
	"sega_cd": {
		"label": "Mega-CD",
		"host": "mega_drive",
		"media": "sega_cd",
		"mount": MOUNT_BELOW,
		"size": Vector3(0.32, 0.08, 0.28),
		"loader": MediaDimensions.LOADER_TRAY,
	},
	# Into the cartridge slot, on top, with its own cartridge slot on top of that.
	# The only expansion here that a game cartridge goes INTO rather than past.
	"sega_32x": {
		"label": "32X",
		"host": "mega_drive",
		"media": "sega_32x",
		"mount": MOUNT_CARTRIDGE,
		"size": Vector3(0.15, 0.07, 0.14),
		"loader": MediaDimensions.LOADER_NONE,
	},
	# The Interface Unit the console docks into sideways. Drawn as a base here
	# for the same reason everything else is: one relation, one direction.
	"pc_engine_cd": {
		"label": "CD-ROM²",
		"host": "pc_engine",
		"media": "pc_engine_cd",
		"mount": MOUNT_BELOW,
		"size": Vector3(0.26, 0.09, 0.22),
		"loader": MediaDimensions.LOADER_TRAY,
	},
	# It clamps to the cartridge slot and hangs over the console's back like a
	# toilet seat, which is what everybody called it. Media systemid is the
	# Jaguar's own: RetroXR has no separate jaguar_cd system, and the core takes
	# a CD image against the same platform.
	"jaguar_cd": {
		"label": "Jaguar CD",
		"host": "atari_jaguar",
		"media": "atari_jaguar",
		"mount": MOUNT_CARTRIDGE,
		"size": Vector3(0.20, 0.09, 0.18),
		"loader": MediaDimensions.LOADER_TRAY,
		# A lid, not a drawer. The Jaguar CD opens upward the way a PlayStation or
		# a GameCube does; the Mega-CD and the CD-ROM2 we model slide a tray out.
		"lid": true,
	},
}


## How a host+expansion combination is actually launched, keyed by the host
## systemid and the attached expansion ids joined with "|" in ROWS order.
##
##   core     the core the COMBINATION needs, which is often not the console's
##            own default: a Mega Drive with a 32X on it is a picodrive machine.
##   roms     which media the core would be handed, in order. "host" is the
##            console's own slot, "expansion:<id>" is that unit's bay. An entry
##            whose bay is EMPTY is skipped, and the first survivor is what the
##            core is actually given — see the note on subsystems below.
##   core_without_host
##            the core to use instead when the console's own slot is empty. The
##            64DD needs this: one core handles cart+disk and a different one
##            handles a bare disk.
##   options  core options the combination pins, the same way BiosBoot pins the
##            BIOS ones.
##   sidecar  a file extension the CORE looks for beside the host cartridge,
##            rather than being handed. See the 64DD row.
##
## Subsystems: recorded, not reachable. Every row here loads through a plain
## retro_load_game with ONE path, because libretro-godot has no array-of-paths
## channel from GDScript — Libretro::StartContent takes a single String. For most
## rows that is not a limitation at all; for ONE it is the real gap. Checked at
## source with the two sessions working on those cores:
##
##   - snes9x advertises exactly ONE subsystem, "multicart_addon", and it is not
##     the Satellaview. BS-X content is auto-detected from the ROM header and the
##     core sources BS-X.bin itself. Nothing is missing here.
##   - mupen64plus-next declares an "ndd" subsystem AND a sidecar workaround, and
##     the workaround is not good enough. See `subsystem` below.
##
## `subsystem` on a row records a VERIFIED pairing that this side cannot perform
## yet: the ident the core advertises and the order it wants its media in. It is
## deliberately kept apart from `roms`, which means something else — `roms` is the
## preference order for the single path we actually hand over today, and the two
## orders genuinely differ for the 64DD. Nothing reads `subsystem`; it is here so
## the research survives the wait, and so that wiring it up later is an edit to
## the call site rather than a second round of source-reading.
##
## An earlier version of this file asserted a "64dd" subsystem, a "bsx" one, and
## a "mupen64plus-64dd-hardware" core option. All three were invented, and the
## last one does not exist in that core at all. They are recorded here because a
## plausible guess in a data table is worse than a blank: it reads as research.
##
## A combination with no row here still stacks physically and still says what it
## is; it simply launches as the bare console would. That is deliberate: the
## point of this file is the hardware, and a missing launch recipe should cost a
## player a feature, not the ability to build the stack.
##
## UNVERIFIED marks a row nobody has checked against the core's source or run.
## The core names on those are informed guesses and nothing more.
const BOOT: Dictionary = {
	# VERIFIED against mupen64plus-libretro-nx source. Two quite different cases,
	# which is why this row is the only one with a second core:
	#
	#   CART + EXPANSION DISK (F-Zero X Expansion Kit) — NOT PROPERLY SUPPORTED
	#   YET, and the reason the `subsystem` entry below exists. The core is handed
	#   the CARTRIDGE and looks for the disk itself, by the cart's FULL filename
	#   plus ".ndd" in the SAME directory ("F-Zero X (Japan).z64.ndd", not
	#   "F-Zero X (Japan).ndd"). That only works if the two files were arranged
	#   for it in advance. A real library has the cart in the n64 roms dir and the
	#   disk in the n64dd one, under its own name, and no arrangement of physical
	#   objects in the room can change where a file lives. Staging a copy is not
	#   the answer either: the rule needs file A and file A+".ndd" side by side,
	#   so whichever directory you pick, a 64 MB disk gets copied per launch — on
	#   Quest, before the game starts — and DirAccess has no hardlink API to make
	#   it free. The core's own comment calls the sidecar "Workaround for broken
	#   subsystem on static platforms"; a second workaround stacked on it is the
	#   wrong direction. So this case boots the cartridge and RetroSystem WARNS,
	#   by name, that the drive will be ignored — which beats a cart that boots
	#   fine and looks correct, where the only tell is a missing 64DD line on the
	#   title screen. retro_load_game_special is sound in the core for num_info==2
	#   and is the mechanism this wants.
	#
	#   DISK ONLY (Mario Artist, Kyojin no Doshin) — the core is handed the .ndd
	#   and no cartridge. mupen64plus-next rejected a bare .ndd until a patch on
	#   feat/64dd-disk-only that has not shipped, so this case names parallel_n64,
	#   which takes one today and which BiosBoot already pins
	#   parallel-n64-64dd-hardware for.
	#
	# Either way the IPL is the core's business: it ignores any path handed to it
	# and reads <system>/Mupen64plus/IPL.n64 unconditionally.
	#
	# The two-core split stays correct even once the disk-only patch ships:
	# parallel_n64 remains fine for a bare disk, so collapsing to one core would be
	# an option and not a fix. Do not collapse it until mupen64plus_next actually
	# claims nintendo_64dd in its .info AND disk-only boot has been seen to work at
	# runtime, rather than to compile.
	"nintendo_64|nintendo_64dd": {
		"core": "mupen64plus_next",
		"core_without_host": "parallel_n64",
		"roms": ["host", "expansion:nintendo_64dd"],
		"sidecar": ".ndd",
		# Verified at source: libretro.c declares dd_roms[] as { "Disk", "Cartridge" }
		# with ident "ndd" (the desc is "N64 Disk Drive"). Disk FIRST — the reverse
		# of `roms` above, which is a preference order and not a pairing.
		"subsystem": {"ident": "ndd",
			"roms": ["expansion:nintendo_64dd", "host"]},
	},
	# VERIFIED against snes9x source. The core is handed the .bs ALONE — not the
	# host cartridge — auto-detects BS-X from the content header, and sources
	# BS-X.bin itself from the ROM dir or the system dir. There is no subsystem to
	# name; the RETRO_GAME_TYPE_BSX path exists in the core but is never
	# advertised, so a frontend cannot reach it.
	#
	# This row is for a STANDALONE .bs dump of an already-downloaded programme.
	#
	# A BS-SLOTTED cartridge (Itoi Bass Fishing) plus a pack is the one case that
	# genuinely wants snes9x's "multicart_addon" subsystem, host cart first. It is
	# not written here because no subsystem path exists to carry it.
	#
	# "host", not "expansion:satellaview": the Satellaview has no bay (see
	# media_in_host on its ROWS entry), so the .bs is in the Super Famicom's own
	# slot. Same file either way — this row exists to pin the core, not to find it.
	"super_nes|satellaview": {
		"core": "snes9x",
		"roms": ["host"],
	},
	# The BS-X cartridge, with or without the base station under the console. Both
	# boot from the pack in the CARTRIDGE's own slot, because that is the medium:
	# snes9x is handed the .bs and finds BS-X.bin in the system directory itself.
	"super_nes|bsx_cart": {
		"core": "snes9x",
		"roms": ["expansion:bsx_cart"],
		# Shell + pack as a PAIR. Without it the core sources the shell from
		# BS-X.bin in the system directory, so a translated BS-X in the cartridge
		# was ignored the moment a pack went into it -- the same machine booted
		# in two different languages depending on whether its bay was full.
		# Order is the core's: bsx_roms[] is { "BS-X Shell", "Memory Pack" }.
		"subsystem": {"ident": "bsx",
			"roms": ["expansion_rom:bsx_cart", "expansion_media:bsx_cart"],
			# The pack is flash, and the .bs IS that flash -- a download is
			# written back over the medium the player inserted, not to a save
			# file beside it.
			"writable": 1},
	},
	"super_nes|satellaview|bsx_cart": {
		"core": "snes9x",
		"roms": ["expansion:bsx_cart"],
		# Shell + pack as a PAIR. Without it the core sources the shell from
		# BS-X.bin in the system directory, so a translated BS-X in the cartridge
		# was ignored the moment a pack went into it -- the same machine booted
		# in two different languages depending on whether its bay was full.
		# Order is the core's: bsx_roms[] is { "BS-X Shell", "Memory Pack" }.
		"subsystem": {"ident": "bsx",
			"roms": ["expansion_rom:bsx_cart", "expansion_media:bsx_cart"],
			# The pack is flash, and the .bs IS that flash -- a download is
			# written back over the medium the player inserted, not to a save
			# file beside it.
			"writable": 1},
	},
	# UNVERIFIED. snes9x is named because it is the platform default, not because
	# anyone has confirmed it takes a Sufami Turbo cart as plain content.
	"super_nes|sufami_turbo": {
		"core": "snes9x",
		"roms": ["expansion:sufami_turbo"],
	},
	# UNVERIFIED.
	"nes|fds": {
		"core": "fceumm",
		"roms": ["expansion:fds"],
	},
	# UNVERIFIED. The CD is the game; the cartridge slot is empty on a Mega-CD
	# title.
	"mega_drive|sega_cd": {
		"core": "genesis_plus_gx",
		"roms": ["expansion:sega_cd"],
	},
	# UNVERIFIED. A 32X cartridge is the game and picodrive is the core that is
	# both halves at once.
	"mega_drive|sega_32x": {
		"core": "picodrive",
		"roms": ["expansion:sega_32x"],
	},
	# UNVERIFIED. The full tower, where the disc is still what boots.
	"mega_drive|sega_cd|sega_32x": {
		"core": "picodrive",
		"roms": ["expansion:sega_cd"],
	},
	# UNVERIFIED. The System Card goes in the console's own slot and the game is
	# on the CD.
	"pc_engine|pc_engine_cd": {
		"core": "mednafen_pce",
		"roms": ["expansion:pc_engine_cd"],
	},
	# UNVERIFIED.
	"atari_jaguar|jaguar_cd": {
		"core": "virtualjaguar",
		"roms": ["expansion:jaguar_cd"],
	},
}


## The row for an id, or an empty Dictionary.
static func row(id: String) -> Dictionary:
	return ROWS.get(id, {})


static func has(id: String) -> bool:
	return ROWS.has(id)


static func label_of(id: String) -> String:
	return str(row(id).get("label", id))


static func host_of(id: String) -> String:
	return str(row(id).get("host", ""))


static func media_of(id: String) -> String:
	return str(row(id).get("media", ""))


static func mount_of(id: String) -> int:
	return int(row(id).get("mount", MOUNT_BELOW))


static func size_of(id: String) -> Vector3:
	return row(id).get("size", Vector3(0.3, 0.08, 0.25))


## True when this unit opens with a hinged lid rather than sliding a tray out.
static func lid_of(id: String) -> bool:
	return bool(row(id).get("lid", false))


static func loader_of(id: String) -> int:
	return int(row(id).get("loader", MediaDimensions.LOADER_NONE))


## True when this unit has no bay of its own and its media goes into the
## CONSOLE's cartridge slot instead.
static func media_in_host(id: String) -> bool:
	return bool(row(id).get("media_in_host", false))


## The front panel this unit wears, if it wears one -- a scene, so what is on a
## machine's face is named beside the machine instead of branched on elsewhere.
static func panel_of(id: String) -> String:
	return str(row(id).get("panel", ""))


## Media systemids a console's OWN cartridge slot must take on top of its own,
## because the expansion that uses them has no mouth to put them in.
##
## Not gated on the unit being attached, deliberately. A BS-X cartridge works in
## a bare Super Famicom -- it boots its menu, it just has no broadcast to tune --
## and snes9x loads a .bs the same way with or without the base station. Gating
## it would mean a player holding the right cartridge for the machine in front of
## them gets a silent refusal, which is the failure mode this codebase least
## wants: a snap zone that declines an object simply does nothing.
static func host_slot_media(host: String) -> Array[String]:
	var out: Array[String] = []
	for id in ids_for_host(host):
		if media_in_host(id):
			var m := media_of(id)
			if not m.is_empty():
				out.append(m)
	return out


## True when this unit has a system tile of its own in the spawn menu.
##
## The test is whether the unit's media is a systemid of its OWN. A 64DD's disks
## are "nintendo_64dd" and a Mega-CD's discs are "sega_cd", so both are systems
## the core info knows, both appear in the systems list, and both therefore get a
## card that is the right place to spawn the unit from. A Jaguar CD runs the
## Jaguar's own media -- "atari_jaguar" -- names no systemid of its own and
## appears in no core's systemid list, so it has no card and can only be offered
## from the console's.
##
## Checked against libretro-core-info: media == id holds for exactly the seven
## ids that appear as a systemid in at least one .info file, and fails for the
## one that appears in none. The rule is not a coincidence of spelling -- a unit
## whose media is its own systemid IS a system as far as the rest of RetroXR is
## concerned, which is precisely what having a card means.
static func has_own_card(id: String) -> bool:
	return media_of(id) == id


## Every expansion that belongs to a console, in ROWS order.
static func ids_for_host(host: String) -> Array[String]:
	var out: Array[String] = []
	for id: String in ROWS:
		if str((ROWS[id] as Dictionary).get("host", "")) == host:
			out.append(id)
	return out


## True when this console has anything at all to bolt to it — what the console
## asks before growing an expansion port on its floor.
static func host_has_expansions(host: String) -> bool:
	return not ids_for_host(host).is_empty()


## True when something mounts ABOVE this console, so it needs a socket on its
## roof as well as a foot underneath (the Mega Drive, which is both).
static func host_takes_top_unit(host: String) -> bool:
	for id: String in ids_for_host(host):
		if mount_of(id) == MOUNT_ABOVE:
			return true
	return false


## True when the console itself stands on something — the reason it grows a foot
## and an expansion port on its underside.
static func host_stands_on_unit(host: String) -> bool:
	for id: String in ids_for_host(host):
		if mount_of(id) == MOUNT_BELOW:
			return true
	return false


## Sort a set of attached ids into ROWS order, which is the order BOOT keys are
## written in. Called on both sides so a tower assembled bottom-up and one
## assembled top-down produce the same key.
static func sorted_ids(ids: Array) -> Array[String]:
	var out: Array[String] = []
	for id: String in ROWS:
		if ids.has(id):
			out.append(id)
	return out


## The launch recipe for a console with these expansions attached, or an empty
## Dictionary when the combination has none. `ids` need not be sorted.
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

static func save_owner_of(id: String) -> String:
	var row: Dictionary = ROWS.get(id, {})
	return str(row.get("save_owner", SAVE_OWNER_MEDIA))


static func boot_for(host: String, ids: Array) -> Dictionary:
	var key := host
	for id in sorted_ids(ids):
		key += "|" + id
	return BOOT.get(key, {})


## The name a stack goes by — "Mega Drive + Mega-CD + 32X". Printed on the
## console's nameplate while anything is attached, so a player can see at a
## glance which machine they have actually built.
static func stack_label(host_label: String, ids: Array) -> String:
	var parts := PackedStringArray([host_label])
	for id in sorted_ids(ids):
		parts.append(label_of(id))
	return " + ".join(parts)

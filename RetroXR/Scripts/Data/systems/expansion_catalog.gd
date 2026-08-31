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
##   bays        how many cartridges this unit takes at once. One unless it says
##               otherwise, which is every unit but the Sufami Turbo. A second
##               bay is addressed by INDEX everywhere it is read -- get_media(1),
##               the expansion_media_b: token -- so a row that does not name it
##               keeps exactly the behaviour it had.
##   firmware    files the CORE must already have for this unit to do anything,
##               named as its .info names them. A unit that has not got them is
##               not offered in the spawn menu at all. The BS-X cartridge and the
##               two Super Game Boys are the only rows that name any.
##   card        the systemid whose spawn card offers this unit, overriding the
##               media rule in card_systemid. Only the Super Game Boys name it,
##               and only because a player went looking for one on the Super
##               Famicom card and did not find it there.
##   rom_title   the title in the internal header of a ROM that IS this unit, so
##               a dump sitting in the library spawns the adapter instead of a
##               cartridge. See adapter_for_rom.
##   rom_from_firmware
##               this unit's OWN program IS the firmware file above, rather than
##               something a player spawns out of the library. The BS-X cartridge
##               is the other way round -- its shell is a .sfc in the Satellaview
##               folder, and spawning it from there is what fills rom_path. A
##               Super Game Boy has no library file to be spawned from at all, so
##               without this its rom_path stays empty and a pairing that needs
##               it degrades to a plain load without saying so. See
##               RetroSystem._expansion_roms.
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
	#
	# The only row that names `firmware`. The shell this cartridge runs is not
	# ours and is not in the pack: it is BS-X.bin in the core's system directory,
	# which snes9x sources itself. Without that file the unit is a prop -- it goes
	# into the slot, the machine starts, and there is no town on the other side --
	# so the menu does not offer it until the file is installed.
	"bsx_cart": {
		"label": "BS-X",
		"host": "super_nes",
		"media": "satellaview",
		"mount": MOUNT_CARTRIDGE,
		"save_owner": SAVE_OWNER_UNIT,
		"size": Vector3(0.137, 0.088, 0.024),
		"loader": MediaDimensions.LOADER_NONE,
		"firmware": ["BS-X.bin"],
	},
	# Sufami Turbo is the other thing that goes in a Super Famicom slot — on TOP,
	# like the 32X — and it is the only unit here that takes TWO cartridges.
	#
	# That is not decoration. Nine of its thirteen games link the cartridge in the
	# second slot into the game in the first: the six SD Gundam Generation titles
	# lend each other their fighters, and SD Ultra Battle lends its characters
	# across the pair. A one-slot Sufami Turbo would be the wrong machine, not a
	# simplified one.
	#
	# 140 mm wide rather than the 120 it carried while it had one implicit well.
	# Two wells cut for a 55 mm cartridge are 59 mm each, so two of them plus a
	# wall between and a wall either side do not fit in 120 -- the box was sized
	# for the bay it had, and it grows for the bay it should always have had.
	#
	# And SHALLOW: 38 mm front to back, not 100. The real adapter is a wide flat
	# bar, and the wells cut into it are only `cart.z + 4` = 16 mm deep, so a
	# 100 mm box was 84 mm of nothing behind them -- it read as a chunky console
	# in its own right rather than the thin tray a cartridge stands out of.
	# 30 mm tall for the same reason.
	#
	# 38 is close to the floor. The well needs 16, and the walls in front of and
	# behind it are 11 mm each at this depth; much less and the mouth starts
	# eating the front face the nameplate is printed on.
	#
	# Nothing here depends on either figure: the wells sit on the roof at
	# s.y * 0.5, spread along X by _build_well_bay's own arithmetic, and the
	# nameplate hangs below the join. Only the WIDTH is load-bearing, and only
	# because two wells have to fit across it.
	#
	# The firmware is the adapter's own shell program, which snes9x loads itself
	# from its system directory. Without it the unit is a prop, so the menu does
	# not offer it -- the same contract the BS-X cartridge has, and NOT
	# rom_from_firmware: STBIOS.bin is deliberately built to FAIL the core's
	# is_SufamiTurbo_Cart test (it carries the "SFC-ADX BACKUP" marker that a
	# cartridge must not have), which is how the core tells its BIOS from a game.
	# Handed over as content it would load as a plain Super Famicom ROM.
	#
	# No save_owner: a Sufami Turbo has no battery. The cartridges do.
	"sufami_turbo": {
		"label": "Sufami Turbo",
		"host": "super_nes",
		"media": "sufami_turbo",
		"mount": MOUNT_CARTRIDGE,
		"size": Vector3(0.14, 0.03, 0.038),
		"loader": MediaDimensions.LOADER_NONE,
		"bays": 2,
		"firmware": ["STBIOS.bin"],
	},
	# The Super Game Boy: a Super Famicom cartridge with a Game Boy slot in its
	# roof, which runs the handheld's game on a television inside a border.
	#
	# The same three layers as the BS-X cartridge, and modelled the same way: a
	# cartridge to the console it goes into, a console to the cartridge that goes
	# into it. What differs is where its own program comes from -- the BS-X
	# cartridge is a .sfc a player spawns out of the library, and this one is a
	# BIOS the core reads from its system directory, which is what
	# `rom_from_firmware` is for.
	#
	# `media` is game_boy, an existing system, so the handheld library already
	# fills this bay: no new roms folder and no new content routing, and a Game
	# Boy cartridge a player already owns is the same object either way.
	#
	# No save_owner. The BS-X cartridge names SAVE_OWNER_UNIT because it has a
	# battery of its own, holding the town and the player's name. A Super Game Boy
	# has none -- the battery is in the cartridge seated in it -- so the default,
	# which is the media, is the right one.
	#
	# Sized as the Super Famicom cartridge it is: the same footprint as the BS-X
	# cartridge above.
	"super_game_boy": {
		"label": "Super Game Boy",
		"host": "super_nes",
		"media": "game_boy",
		"mount": MOUNT_CARTRIDGE,
		"size": Vector3(0.137, 0.088, 0.024),
		"loader": MediaDimensions.LOADER_NONE,
		"card": "super_nes",
		"rom_title": "Super GAMEBOY",
		"firmware": ["SGB1.sfc"],
		"rom_from_firmware": true,
	},
	# The 1998 revision, and a different machine rather than a reskin: the original
	# derives its clock from the SNES and runs the Game Boy about 2.4% fast, where
	# this one carries its own crystal and runs at true handheld speed.
	#
	# That difference costs nothing to model because the cartridge IS the program
	# the console runs, so handing the core a different dump is the whole of the
	# change. A core that emulated the adapter internally would have wanted an
	# option toggled here instead.
	#
	# The dump's own SNES HEADER decides which machine it is, NOT the filename
	# below. Checked at source and against both files: the titles at 0x7FC0 read
	# "Super GAMEBOY" and "Super GAMEBOY2", bsnes matches those against its bundled
	# board database, and Cartridge::loadICD takes the ICD's oscillator out of the
	# board it picked. icd.cpp branches on that one number -- zero is an SGB1 on
	# the SNES's own clock, running the handheld ~2.4% fast; non-zero is an SGB2
	# with a dedicated crystal at true handheld speed -- and picks the SameBoy
	# model and the boot ROM to match. Both boot ROMs are compiled into bsnes,
	# which is why nothing here wants the sgb1.boot.rom that higan asks for.
	#
	# So the names below are only where RetroXR LOOKS. An SGB1 dump installed under
	# the other name gives two adapters that are both an SGB1, and nothing here
	# catches that: firmware_present accepts a MISMATCH deliberately, for the
	# reason written out on BS-X.bin. The BIOS tab is where the md5 verdict shows.
	#
	# Gated on its OWN file, so a player who has one dump and not the other is
	# offered exactly the machine they can build.
	"super_game_boy_2": {
		"label": "Super Game Boy 2",
		"host": "super_nes",
		"media": "game_boy",
		"mount": MOUNT_CARTRIDGE,
		"size": Vector3(0.137, 0.088, 0.024),
		"loader": MediaDimensions.LOADER_NONE,
		"card": "super_nes",
		"rom_title": "Super GAMEBOY2",
		"firmware": ["SGB2.sfc"],
		"rom_from_firmware": true,
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
	# toilet seat, which is what everybody called it. Its discs are its own
	# media: virtualjaguar names jaguar_cd in secondary_systemids, so the CD half
	# is a system in its own right and the unit is spawned from its own card.
	"jaguar_cd": {
		"label": "Jaguar CD",
		"host": "atari_jaguar",
		"media": "jaguar_cd",
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
## Subsystems: REACHABLE, since the BS-X pairing was wired up. A row that names
## one is loaded through retro_load_game_special with the whole ordered set —
## Libretro::StartSubsystemContent carries the array, RetroSystem's
## _start_subsystem_content assembles it, and the C++ resolves the ident against
## whatever table the core published. A row WITHOUT a `subsystem` block still
## loads through a plain retro_load_game with one path, which for most of them is
## not a limitation at all; for the 64DD it remains the real gap. Checked at
## source with the two sessions working on those cores:
##
##   - snes9x advertises exactly ONE subsystem, "multicart_addon", and it is not
##     the Satellaview. BS-X content is auto-detected from the ROM header and the
##     core sources BS-X.bin itself. Nothing is missing here.
##   - mupen64plus-next declares an "ndd" subsystem AND a sidecar workaround, and
##     the workaround is not good enough. See `subsystem` below.
##
## `subsystem` on a row records a VERIFIED pairing: the ident the core advertises
## and the order it wants its media in. It is deliberately kept apart from `roms`,
## which means something else — `roms` is the preference order for the single path
## handed over on a plain load, and the two orders genuinely differ for the 64DD
## and again for the Super Game Boy. A row whose subsystem cannot be completed
## (an empty bay, a core bridge without the call, a core that never published the
## ident) falls back to that plain load rather than failing.
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
	# VERIFIED against snes9x source, and it is the second row here whose core has
	# a dead constant for the machine it is meant to run.
	# RETRO_GAME_TYPE_SUFAMI_TURBO is #defined AND has a working case in
	# retro_load_game_special -- and is registered in no subsystem, so no
	# frontend can reach it. Do not be fooled by the grep hit; the same trap sits
	# in this core for the Super Game Boy.
	#
	# What IS reachable is the Multi-Cart Link, which is the Sufami Turbo path in
	# all but name. Its case sniffs the FIRST cartridge --
	# is_SufamiTurbo_Cart(romptr[0]) -- and on a hit loads STBIOS.bin and calls
	# LoadMultiCartMem(A, B, bios). A cartridge that is NOT one takes a generic
	# no-BIOS multi-cart branch instead.
	#
	# Measured, because the obvious guess is wrong: a Sufami cartridge with no
	# STBIOS.bin installed does not fall through to that generic branch. The load
	# is simply refused -- rom_loaded stays false, no frames, and the machine
	# says so. Which is why `firmware` above is a gate on offering the unit at
	# all rather than a hope.
	#
	# One cartridge is a first-class configuration rather than a tolerated one:
	# retro_load_game auto-detects a lone cart from its "BANDAI SFC-ADX" header
	# and maps slot B empty. So the ordinary preference list below IS the
	# single-cart machine, and the pairing completes only when both wells are
	# full -- _start_subsystem_content falls back to the plain load on a count
	# mismatch, so the split needs no branch of its own.
	#
	# expansion_media: rather than the plain expansion: form, because the plain
	# one falls back to the unit's own ROM and there is none. An empty Sufami
	# Turbo must say its slots are empty, not try to boot its BIOS as a game.
	#
	# BOTH cartridges keep their saves, and that took a bridge change rather than
	# a data one. snes9x lays slot A's SRAM at the start of one block and slot B's
	# 0x10000 into it, and retro_get_memory_size answers RETRO_MEMORY_SAVE_RAM and
	# RETRO_MEMORY_SNES_SUFAMI_TURBO_A_RAM from the SAME case -- slot A alone, so
	# a frontend reading only SAVE_RAM keeps half a linked pair's progress. Slot B
	# lives under _B_RAM and is now read and written through Libretro.SetSramBPath,
	# to a file of its own.
	#
	# It is keyed off the CARTRIDGE, not the slot: a game carries its save between
	# the two wells, and lending it to a different pairing does not overwrite it.
	# See RetroSystem._slot_b_save_path.
	"super_nes|sufami_turbo": {
		"core": "snes9x",
		"roms": ["expansion_media:sufami_turbo", "expansion_media_b:sufami_turbo"],
		"subsystem": {"ident": "multicart_addon",
			"roms": ["expansion_media:sufami_turbo", "expansion_media_b:sufami_turbo"]},
	},
	# VERIFIED against bsnes-libretro, bsnes/target-libretro/libretro.cpp:
	#
	#   sgb_roms[]  = { "Game Boy ROM" (gb|gbc), "Super Game Boy ROM" (smc|sfc) }
	#   subsystems[] = { "Super Game Boy", "sgb", sgb_roms, 2, RETRO_GAME_TYPE_SGB }
	#
	# and retro_load_game_special assigns gameBoy.location = info[0] and
	# superFamicom.location = info[1]. So the HANDHELD's cartridge goes first and
	# the adapter's own cartridge second -- the reverse of the BS-X rows above,
	# which are shell-first, and the reason the two orders are written out per row
	# rather than assumed to be the same.
	#
	# The core is NOT the platform default, and cannot be. snes9x defines
	# RETRO_GAME_TYPE_SUPER_GAME_BOY and then never puts it in the subsystems[] it
	# publishes, so a frontend cannot reach it; retro_load_game_special drops that
	# game type into its default case and reports the load failed. The constant is
	# vestigial. Naming snes9x here would give a machine that refuses to start.
	#
	# No `writable`. That key exists for the BS-X pack, which is flash the core
	# writes a download back onto, and SetPackPath is bound to the SNES pack memory
	# region specifically. A Game Boy cartridge's save is an ordinary SRAM and
	# belongs on the ordinary path.
	"super_nes|super_game_boy": {
		"core": "bsnes",
		"roms": ["expansion:super_game_boy"],
		"subsystem": {"ident": "sgb",
			"roms": ["expansion_media:super_game_boy", "expansion_rom:super_game_boy"]},
	},
	# A row of its own rather than a shared one, and not for tidiness: firmware_present
	# finds a unit's core through the unit's OWN recipe, so a unit with no recipe is
	# not gated at all -- which would offer a Super Game Boy 2 to a player who has no
	# dump of one. Both are MOUNT_CARTRIDGE and a Super Famicom has one slot, so no
	# combined row can arise.
	"super_nes|super_game_boy_2": {
		"core": "bsnes",
		"roms": ["expansion:super_game_boy_2"],
		"subsystem": {"ident": "sgb",
			"roms": ["expansion_media:super_game_boy_2", "expansion_rom:super_game_boy_2"]},
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
## card that is the right place to spawn the unit from.
##
## Checked against libretro-core-info: media == id holds for eight of the eleven
## ids, and every one of those eight appears as a systemid in at least one .info
## file. The rule is not a coincidence of spelling -- a unit whose media is its
## own systemid IS a system as far as the rest of RetroXR is concerned, which is
## precisely what having a card means.
##
## The Jaguar CD used to be an exception for a reason that was fixable: nothing
## named its discs, so it ran under "atari_jaguar" and had to be offered from the
## console's card. It names itself now, through virtualjaguar's
## secondary_systemids, so it has a tile like the rest.
##
## The three that remain are exceptions on purpose, and no .info entry would fix
## them. A BS-X cartridge runs Satellaview downloads and a Super Game Boy runs
## Game Boy cartridges: the media each takes already belongs to another system,
## and minting an id for the ADAPTER would put a tile in the systems list for a
## machine nobody owns separately -- the imaginary-console mistake this whole file
## was written to undo. They are offered from the card of whatever they play.
static func has_own_card(id: String) -> bool:
	return media_of(id) == id


## The systemid whose card this unit is offered from.
##
## A unit with a tile of its own is offered from that tile. A unit WITHOUT one
## belongs on the card of the media it runs, because that is the card a player
## reaching for it is already on. The BS-X cartridge is the case that made this
## a rule: it runs Satellaview downloads, so it belongs on the Satellaview card
## and not on the Super Famicom's, where it sat beside a console it is only one
## third of and where a player who had never heard of the base station met it
## first. The Jaguar CD moved the same way and for the same reason: it used to
## sit among the Jaguar's pads because its discs were filed as Jaguar media, and
## now that they are jaguar_cd it is reached from the Jaguar CD's own card.
##
## `card` on a row overrides all of that, and the Super Game Boys are why. The
## media rule put them on the Game Boy card, which is arguable -- it is where you
## are standing when you want to play a Game Boy game -- and was tried. It failed
## the only test that counts: the person who asked for the feature went looking
## for it, on the Super Famicom card, and did not find it. A Super Game Boy IS a
## Super Famicom cartridge and goes into a Super Famicom slot, so that is where a
## hand reaches for it. An override rather than a change to the rule, because the
## rule is still right for the BS-X cartridge and the reasoning above still holds.
static func card_systemid(id: String) -> String:
	if has_own_card(id):
		return id
	var override := str(row(id).get("card", ""))
	if not override.is_empty():
		return override
	var m := media_of(id)
	return m if not m.is_empty() else host_of(id)


## The units offered from `systemid`'s card -- those with no tile of their own
## that are filed here. In ROWS order.
##
## Firmware is NOT filtered here: this answers where a unit belongs, and
## firmware_present answers whether it can be offered at all. Keeping them apart
## means a unit does not silently change cards when a file appears on disk.
static func ids_carded_on(systemid: String) -> Array[String]:
	var out: Array[String] = []
	for id: String in ROWS:
		if not has_own_card(id) and card_systemid(id) == systemid:
			out.append(id)
	return out


## How many cartridges this unit holds at once. One unless the row says more.
##
## Clamped at the bottom rather than trusted: a row typo of 0 would build a unit
## with no bay at all, which reads as a solid box a player cannot load and gives
## no clue why.
static func bays_of(id: String) -> int:
	return maxi(1, int(row(id).get("bays", 1)))


## Firmware this unit cannot work without, named exactly as the core's .info
## names it. Empty for every unit whose hardware is entirely ours to draw.
static func firmware_of(id: String) -> Array:
	return (row(id).get("firmware", []) as Array).duplicate()


## The unit a ROM in the library IS, or "" for an ordinary piece of media.
##
## A Super Game Boy dump is a perfectly good Super Famicom .sfc and sits in the
## snes folder with everything else, so without this it spawns as a cartridge --
## a slab with nowhere to put a Game Boy game in it. Same problem the BS-X shell
## had, and the same answer: recognise it on the way out of the library and spawn
## the unit instead.
##
## Matched on the ROM's INTERNAL HEADER, not its filename. That is what bsnes
## itself matches on to decide which adapter it is emulating, so the two agree by
## construction; a filename rule would disagree the moment somebody renamed a
## file, and would have to guess at "Super Game Boy (Japan, USA) (Rev 1)" versus
## "Super Game Boy 2 (Japan)" -- where the first two revisions are both an SGB1
## and only the third is a different machine.
##
## Both header positions are read because the position is a fact about the ROM
## rather than about the system, and a copier header is skipped: those add 512
## bytes on the front, which is exactly what a size that is not a whole number of
## kibibytes means.
static func adapter_for_rom(path: String) -> String:
	if path.is_empty():
		return ""
	var wanted := false
	for id: String in ROWS:
		if not str(ROWS[id].get("rom_title", "")).is_empty():
			wanted = true
			break
	if not wanted:
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var length := f.get_length()
	var skip: int = 512 if (length % 1024) == 512 else 0
	var titles: Array[String] = []
	for base: int in [0x7FC0, 0xFFC0]:
		var at: int = base + skip
		if at + 21 > length:
			continue
		f.seek(at)
		titles.append(f.get_buffer(21).get_string_from_ascii().strip_edges())
	f.close()
	for id: String in ROWS:
		var title := str(ROWS[id].get("rom_title", ""))
		if not title.is_empty() and titles.has(title):
			return id
	return ""


## Where this unit's own program lives when the unit IS its firmware.
##
## Empty for every unit that does not set `rom_from_firmware`, which is all of
## them but the two Super Game Boys — a BS-X cartridge carries a shell a player
## spawned it from, and answering with BS-X.bin here would quietly swap the
## cartridge in their hand for the one in the system directory.
##
## The FIRST firmware name, not any that happens to be present. firmware_of is a
## list of alternatives for the gate, but a unit runs one program: the Super Game
## Boy 2 names SGB2.sfc and must not fall back to SGB1.sfc, or a player with both
## dumps would build one machine and be handed the other.
##
## Returns the path whether or not the file is there. Existence is
## firmware_present's question, and it is asked before the unit can be spawned at
## all.
static func firmware_rom_path(id: String) -> String:
	if not bool(row(id).get("rom_from_firmware", false)):
		return ""
	var wanted := firmware_of(id)
	if wanted.is_empty():
		return ""
	var core := str(boot_for(host_of(id), [id]).get("core", ""))
	if core.is_empty():
		return ""
	return FirmwareRequirements.destination(core, str(wanted[0]))


## Is this unit's firmware actually installed?
##
## True for a unit that names none, which is all of them but one. Otherwise ANY
## of the group being on disk satisfies it -- alternatives, not a checklist.
##
## ON DISK, not verified, and this is where it parts company with BiosBoot. That
## one refuses a MISMATCH because a PS1 BIOS from the wrong region really does
## boot to a black screen, so offering the boot is worse than withholding it.
## BS-X.bin is the opposite case: snes9x runs whatever is under that name, and
## the dumps a player legitimately has -- Rev 0, or one of the fan translations
## the Satellaview scene actually uses -- are none of them the Rev 1 whose md5
## snes9x's .info publishes. Verifying here would hide the cartridge from the
## players most likely to want it, over a file that works.
##
## The core comes from the unit's own BOOT recipe rather than being named twice:
## a firmware path is a fact about the core that runs the combination, and that
## core is already written down above. A unit with no recipe cannot say whose
## system directory to look in, so it is not gated at all.
static func firmware_present(id: String) -> bool:
	var wanted := firmware_of(id)
	if wanted.is_empty():
		return true
	var core := str(boot_for(host_of(id), [id]).get("core", ""))
	if core.is_empty():
		return true

	var declared := false
	for status_row: Dictionary in FirmwareState.shared().evaluate(
			core, FirmwareRequirements.for_core(core)):
		if not wanted.has(str(status_row.get("path", ""))):
			continue
		declared = true
		var status := int(status_row.get("status", -1))
		if status == FirmwareState.Status.PRESENT \
				or status == FirmwareState.Status.MISMATCH:
			return true
	if declared:
		return false

	# The core's .info does not declare the file. Its location is still fixed --
	# the core looks in its own system directory and nowhere else -- so look
	# there rather than hiding hardware over a missing line of metadata.
	for name: Variant in wanted:
		if FileAccess.file_exists(FirmwareRequirements.destination(core, str(name))):
			return true
	return false


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

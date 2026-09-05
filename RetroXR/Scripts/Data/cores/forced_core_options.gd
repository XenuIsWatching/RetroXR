## ForcedCoreOptions — the core options a machine pins for a run.
##
## Some options are not preferences: they are what makes the hardware that
## hardware. A 64DD with its drive switched off has nothing to load a disk into;
## an N64 whose core defaults to "Expansion Pak installed" has 8 MB whether or
## not a player ever placed the pack. Each function here answers one such
## question, and every answer was MEASURED against the core rather than guessed
## — the comments say which probe and what it showed.
##
## Lifted out of RetroSystem, which had grown eight subsystems' vocabularies in
## one class. These decisions need no node: they are questions about a core and
## a machine's description, so they take that description as arguments and this
## file has no scene, no state and no side effects.
##
## RetroSystem._all_forced_options is still the entry point, and merges what the
## model demands on top of these. One place, so the .opt seam and the options
## panel can never disagree about which keys the player is allowed to move.
class_name ForcedCoreOptions
extends RefCounted


## Everything this machine pins for a run, in the order the layers apply.
static func all(core: String, systemid: String, rom_path: String,
		expansions: Array, card_family: String, memcard0: bool,
		media_path: String) -> Dictionary:
	var out: Dictionary = {}
	out.merge(removable_media(core, card_family, memcard0), true)
	out.merge(disk_drive(core, systemid, expansions, media_path), true)
	out.merge(expansion_pak(core, expansions), true)
	out.merge(fm_sound_unit(core, systemid, expansions), true)
	out.merge(bios_pinned(core, systemid, rom_path), true)
	return out


## Make the console report an EMPTY slot when no card is seated.
##
## The SAVE_RAM interface cannot express this: it always hands back a 128 KB
## buffer, so an unbacked run still looks like a card — merely a blank one, and
## the game offers to format it instead of saying no card is present.
## pcsx_rearmed's own memcard1 option can, because "none" disables the slot down
## at the SIO level (McdDisable -> no_device), which is what the hardware does.
##
## Read by the core at content load, so it is composed here with the other
## start-time options rather than swapped mid-run. Cores built before the option
## shipped ignore the key harmlessly, so this is safe on an older build.
static func removable_media(core: String, card_family: String, memcard0: bool) -> Dictionary:
	# The PlayStation FAMILY, not merely any console with card slots. These keys
	# are pcsx_rearmed's own and mean nothing to another console's core, so a
	# GameCube must not write them into a .opt on the strength of having slots.
	if card_family != "playstation" or not core.begins_with("pcsx_rearmed"):
		return {}
	return {
		"pcsx_rearmed_memcard1": "libretro" if memcard0 else "none",
		# The PlayStation has one card slot here, so slot 2 is empty. Said out
		# loud rather than left to the core's default, which is a shared card
		# every game can see and no object in the room accounts for.
		"pcsx_rearmed_memcard2": "none",
		# And whether the card is actually IN it, which is a different question
		# from what kind of card the slot holds and the only one that can change
		# while the game runs. Set here too so a machine starts up agreeing with
		# the room: the key is read at load like the others, and _set_card_presence
		# keeps it honest from then on.
		"pcsx_rearmed_memcard1_inserted":
			"enabled" if memcard0 else "disabled",
	}


static func disk_drive(core: String, systemid: String, expansions: Array,
		media_path: String) -> Dictionary:
	# A 64DD reaches a machine two ways, and the systemid only says one of them.
	# Launching a disk from the library makes a nintendo_64dd machine; bolting
	# the drive under a console leaves the console a nintendo_64 with an
	# expansion, and asking only about the systemid misses it entirely -- which
	# left the assembled machine running with its drive switched off, on the one
	# machine that visibly has one.
	if systemid != "nintendo_64dd" and not expansions.has("nintendo_64dd"):
		return {}
	if core == "parallel_n64":
		return {"parallel-n64-64dd-hardware": "enabled"}
	# mupen64plus_next boots a bare disk correctly and then draws nothing at all
	# under GLideN64, which is its default renderer. Measured on the same core,
	# the same disk and the same machine, changing only this option: GLideN64
	# reaches the 64DD IPL logo and goes black and stays black, while parallel
	# and angrylion both reach Mario Artist's title screen. The emulation is
	# fine either way -- the frame counter climbs identically in all three -- so
	# this is a renderer that cannot draw a cartridge-less boot, not a machine
	# that fails to start.
	#
	# parallel rather than angrylion because angrylion is a software rasteriser
	# and this has to run on a headset. Pinned for the same reason the drive
	# above is: with the default the player gets a black screen, and no amount
	# of fiddling elsewhere fixes it.
	#
	# Only while this core is actually being offered Vulkan, which is the
	# default for every core and can be overridden per core in CORES > Manager >
	# FRONTEND. ParaLLEl-RDP is a Vulkan renderer: pinning it on a core the
	# player has moved to GL would turn a black screen into a refused load,
	# which is a worse answer to the same question. Angrylion is the fallback
	# because it needs no API at all -- slow, and still a picture.
	#
	# Only when the cartridge slot is empty, which is the boot GLideN64 cannot
	# draw. With a cartridge in, the same core and the same drive render
	# perfectly on the stock renderer -- measured -- and forcing a different one
	# there would be changing the player's picture for no reason, on a file
	# every nintendo_64 machine shares.
	#
	# Cartridge-less is a fact about what the CORE is handed, not about whether
	# the console's own slot is occupied, and the two come apart here. A machine
	# spawned as a nintendo_64dd holds its disk in that very slot and still boots
	# with no cartridge; an assembled machine keeps the cartridge in the console
	# and the disk in the drive underneath. Reading the slot alone got this
	# backwards for the standalone machine -- the case the pin was written for --
	# and it went black again.
	var cartridge_less := systemid == "nintendo_64dd" or media_path.is_empty()
	if core == "mupen64plus_next" and cartridge_less:
		var api := AppPrefs.hw_render_for(core)
		return {"mupen64plus-rdp-plugin": "parallel" if api == "vulkan" else "angrylion"}
	return {}


## The Expansion Pak is a physical RAM module with no media of its own -- unlike
## the 64DD above, there is no launch recipe for it, so this is the only thing
## it does at all.
##
## Both cores were measured (Tools/cores/core_options_probe.gd) rather than
## guessed, and both already emulate WITH the pak installed by default:
## mupen64plus_next's mupen64plus-ForceDisableExtraMem defaults to False (the
## description reads "Disable Expansion Pak", so False means the pak stays in),
## and parallel_n64's parallel-n64-disable_expmem defaults to "enabled" (its own
## description is "Enable Expansion Pak RAM", so "enabled" names the RAM, not
## the disabling). That is why this pins BOTH directions and not only the
## attached one, unlike _disk_drive_options above -- a bare console has to be
## pushed OFF the core's own default, or every Nintendo 64 in the room would
## already have 8 MB whether or not a player ever placed the pack.
static func expansion_pak(core: String, expansions: Array) -> Dictionary:
	var attached := expansions.has("expansion_pak")
	if core == "mupen64plus_next":
		return {"mupen64plus-ForceDisableExtraMem": "False" if attached else "True"}
	if core == "parallel_n64":
		return {"parallel-n64-disable_expmem": "enabled" if attached else "disabled"}
	return {}


## The FM Sound Unit adds a YM2413 chip an export Master System never had.
## genesis_plus_gx_ym2413 (measured, Tools/cores/core_options_probe.gd) defaults
## to "auto", which follows the ROM's own region byte -- a fact about the
## cartridge, not about whether this room's player ever placed the accessory.
## So "auto" is left alone for nothing: pinned "enabled" with the unit on and
## "disabled" with it off, the same both-directions shape as the Expansion Pak
## above and for the same reason.
##
## Gated on systemid rather than only on expansions, unlike the Pak: this
## core also runs the Mega Drive, Game Gear and SG-1000, none of which this key
## means anything for, and expansions is empty on all of them regardless --
## without the gate every one of those machines would be pinned "disabled" too.
static func fm_sound_unit(core: String, systemid: String, expansions: Array) -> Dictionary:
	if systemid != "master_system" or core != "genesis_plus_gx":
		return {}
	return {"genesis_plus_gx_ym2413": "enabled" if expansions.has("fm_sound_unit") else "disabled"}


## The measured options that make this machine show its own boot screen, unless
## the player has taken them back in OPTIONS > Systems.
##
## Which half of the row applies is decided from what is in the slot, not from
## the table: an empty slot reaches the BIOS by different keys from a loaded
## game, and reading it from rom_path means the options panel shows the pin that
## matches what the machine would actually start with right now.
##
## Pinned rather than seeded because a pin is the only kind of write that beats a
## saved value. A core serialises its whole option set on shutdown, so one run
## that left mgba_skip_bios "ON" behind would otherwise skip the BIOS for ever.
static func bios_pinned(core: String, systemid: String, rom_path: String) -> Dictionary:
	if AppPrefs.bios_boot_override:
		return {}
	var empty := rom_path.is_empty() and BiosBoot.can_boot_empty(core, systemid)
	return BiosBoot.pinned_options(core, systemid, empty)

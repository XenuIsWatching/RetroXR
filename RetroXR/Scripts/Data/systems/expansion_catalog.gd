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

## Re-exported from ExpansionDefs, which owns them so a unit file can name one
## without referencing this class -- see expansion_defs.gd. Callers keep saying
## ExpansionCatalog.MOUNT_BELOW.
const MOUNT_BELOW := ExpansionDefs.MOUNT_BELOW
const MOUNT_ABOVE := ExpansionDefs.MOUNT_ABOVE
const MOUNT_CARTRIDGE := ExpansionDefs.MOUNT_CARTRIDGE
const SAVE_OWNER_MEDIA := ExpansionDefs.SAVE_OWNER_MEDIA
const SAVE_OWNER_UNIT := ExpansionDefs.SAVE_OWNER_UNIT


## Every expansion is a file of its own under expansions/, holding its ROW, the
## BOOT recipes only it takes part in, and the notes for both. A combination
## recipe belongs to the unit that decides its core -- the Tower of Power is
## picodrive because of the 32X, so it lives in sega_32x.gd.
const _UNITS: Array = [
	preload("res://Scripts/Data/systems/expansions/nintendo_64dd.gd"),
	preload("res://Scripts/Data/systems/expansions/fds.gd"),
	preload("res://Scripts/Data/systems/expansions/satellaview.gd"),
	preload("res://Scripts/Data/systems/expansions/bsx_cart.gd"),
	preload("res://Scripts/Data/systems/expansions/sufami_turbo.gd"),
	preload("res://Scripts/Data/systems/expansions/super_game_boy.gd"),
	preload("res://Scripts/Data/systems/expansions/super_game_boy_2.gd"),
	preload("res://Scripts/Data/systems/expansions/sega_cd.gd"),
	preload("res://Scripts/Data/systems/expansions/sega_32x.gd"),
	preload("res://Scripts/Data/systems/expansions/pc_engine_cd.gd"),
	preload("res://Scripts/Data/systems/expansions/jaguar_cd.gd"),
	preload("res://Scripts/Data/systems/expansions/ereader.gd"),
]

## The canonical order of the units, and it is LOAD-BEARING: sorted_ids() hands
## back ids in this order and boot_for() builds its "host|id|id" key from that,
## so a pair reordered here stops matching its BOOT row -- silently, since the
## lookup just misses. Assembly walks this list rather than either source, so a
## unit file reordered in _UNITS cannot change it.
const _ORDER: Array = [
	"nintendo_64dd", "fds", "satellaview", "bsx_cart", "sufami_turbo",
	"super_game_boy", "super_game_boy_2", "sega_cd", "sega_32x",
	"pc_engine_cd", "jaguar_cd", "ereader",
]


## How a host+expansion combination is actually launched, keyed by the host
## systemid and the attached expansion ids joined with "|" in ROWS order.
##
##   core     the core the COMBINATION needs, which is often not the console's
##            own default: a Mega Drive with a 32X on it is a picodrive machine.
##   roms     which media the core would be handed, in order. "host" is the
##            console's own slot, "expansion:<id>" is that unit's bay. An entry
##            whose bay is EMPTY is skipped, and the first survivor is what the
##            core is actually given — see the note on subsystems below.
##   core_only_with_host
##            `core` above applies only while the CONSOLE's own slot is filled.
##            With it empty, expansion_boot() drops the core and the machine
##            resolves one the way a bare console does -- the player's own
##            pick, or the manager's default for the systemid. Set it only for
##            a stack whose empty-slot boot is an ordinary way to play AND
##            whose every candidate core handles it; without it a row pins its
##            core either way, which is what the other rows need.
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
## The assembled tables. Public because callers read ExpansionCatalog.ROWS
## directly, and a Dictionary built here reads exactly like the const it
## replaced.
##
## Assembled in _static_init rather than lazily: it runs once when the class is
## first loaded, so no accessor has to remember to prime the table first, and
## there is no state where ROWS is half built.
static var ROWS: Dictionary = {}
static var BOOT: Dictionary = {}


static func _static_init() -> void:
	var by_id: Dictionary = {}
	for unit: Script in _UNITS:
		by_id[unit.ID] = unit
	# Walked in _ORDER rather than in _UNITS order: insertion order IS
	# sorted_ids' order, so it must be stated once here and not be a property of
	# how the preloads happen to be listed.
	for id: String in _ORDER:
		ROWS[id] = (by_id[id] as Script).ROW
	for unit: Script in _UNITS:
		BOOT.merge(unit.BOOT)


## The core a recipe names on this platform: `android` when there is one and we
## are on it, else `core`.
##
## Split out and given `mobile` rather than asking the OS itself, because the
## branch that matters cannot be reached from a desktop test run -- and it is
## the branch that shipped broken. A Quest resolved to "mupen64plus_next", a
## name the buildbot publishes for Windows only, and reported the core missing.
static func core_of(spec: Dictionary, mobile: bool) -> String:
	if mobile:
		var over := str(spec.get("android", ""))
		if not over.is_empty():
			return over
	return str(spec.get("core", ""))

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


static func save_owner_of(id: String) -> String:
	return str(row(id).get("save_owner", SAVE_OWNER_MEDIA))


## The launch recipe for a console with these expansions attached, or an empty
## Dictionary when the combination has none. `ids` need not be sorted.
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

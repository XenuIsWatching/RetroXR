## SpawnCatalog — the per-system list of things the spawn menu can spawn.
##
## The Systems tab shows a title card per system; opening a card lists that
## system's spawnable ITEMS — its hardware model(s) plus the peripherals that go
## with it (e.g. PlayStation → Primitive System + Memory Card + Primitive
## Controller + Composite Cable).
##
## Hardware rows are NOT authored here. Every model is a row in
## SystemModelRegistry that already knows its own label and which platform it sits
## under, so this file asks for them and only hand-authors the peripherals. That is
## what makes adding or deleting a model a one-row edit: the menu follows.
##
## Each item is a Dictionary:
##   kind     : "system"     → a RetroSystem console (system.tscn)
##              "peripheral" → an existing pickable scene spawned by name
##   label    : row text — the HARDWARE's name, not a category ("DS Lite",
##              "PSP-1000"), so the row says what it actually spawns
##   model_id : (kind=="system")     the SystemModelRegistry row to spawn
##   spawn    : (kind=="peripheral") an EXISTING spawn string that
##                                   SpawnMenuController._on_spawn_requested already
##                                   handles ("retro_controller", "memory_card", …)
class_name SpawnCatalog
extends RefCounted

## The stand-in pad — also the "Primitive Controller" row's spawn token.
const PRIMITIVE_CONTROLLER := "retro_controller"


## systemid → the peripherals that belong to that hardware. Systems with no entry
## just have none; their hardware rows still come from the registry.
##
## What is listed is the hardware RetroXR models itself: the memory card, and the
## Virtual Boy pad — that one is here rather than dropped to the generic row
## because it carries the console's POWER switch, so the platform is unplayable
## without it.
##
## Every non-handheld gets the "Primitive Controller" row appended by items_for
## below, so a platform losing its entry here loses a name, not a way to play.
const _PERIPHERALS: Dictionary = {
	# Both pads are named here rather than left to the generic Controllers row
	# because the console moulds its own sockets and each pad wears the matching
	# connector (plug_mesh_path), so they only look right together. The digital
	# pad shipped with the console; the DualShock is the later one you bought.
	"playstation": [
		{"kind": "peripheral", "label": "Controller", "spawn": "ps1_controller"},
		{"kind": "peripheral", "label": "DualShock", "spawn": "ps1_dualshock"},
		{"kind": "peripheral", "label": "Memory Card", "spawn": "memory_card"},
	],
	"playstation2": [
		{"kind": "peripheral", "label": "Memory Card", "spawn": "memory_card"},
	],
	"gamecube": [
		{"kind": "peripheral", "label": "Memory Card", "spawn": "memory_card"},
	],
	# The remote is named here even though it fits no socket: it is the Wii's
	# controller, and a player who spawns a Wii should be offered one without
	# having to know it lives under Controllers. The Nunchuk comes with it because
	# half the library needs one.
	"wii": [
		{"kind": "peripheral", "label": "Wiimote", "spawn": "wiimote"},
		{"kind": "peripheral", "label": "Nunchuk", "spawn": "nunchuk"},
		# A Wii playing a GameCube disc writes to a GameCube card, and its two
		# slots are real — under the memory flap beside the controller ports.
		{"kind": "peripheral", "label": "Memory Card", "spawn": "memory_card"},
		# Offered here too, because the games that need it need it absolutely:
		# without the dongle a remote reports no rotation and Wii Sports Resort
		# will not start.
		{"kind": "peripheral", "label": "Wii MotionPlus", "spawn": "motion_plus"},
		# Listed first among equals in spirit: without it the remote has nothing to
		# look at, and no amount of pressing SYNC produces a pointer.
		{"kind": "peripheral", "label": "Sensor Bar", "spawn": "sensor_bar"},
		# The one console whose lead is not interchangeable with anybody else's: an
		# AV Multi Out at the machine and three phonos at the set, so a plain
		# composite lead fits the television and nothing at this end.
		{"kind": "peripheral", "label": "RVL-009", "spawn": "wii_av_cable"},
	],
	"virtual_boy": [
		{"kind": "peripheral", "label": "Controller", "spawn": "vb_controller"},
	],
	# The NES pad is named here rather than left to the generic row because the
	# console moulds its own connector and the pad wears it (plug_mesh_path), so
	# the two only look right together. No cartridge row: a cart comes from the
	# Games tab, which already spawns one per ROM keyed on systemid.
	"nes": [
		{"kind": "peripheral", "label": "Controller", "spawn": "nes_controller"},
		# The console wears sockets rather than a captive lead, so the lead it
		# shipped with is listed on its own card: video and ONE audio channel,
		# which is all an NES puts out.
		{"kind": "peripheral", "label": "Mono Composite Cable",
			"spawn": "mono_composite_cable"},
		# How this console actually reached a set in 1985, and the reason its rear
		# panel wears an RF SWITCH socket and a CH3/CH4 slide beside it.
		{"kind": "peripheral", "label": "RF Switch (RXR-003)", "spawn": "rf_switch"},
	],
	# Same reasoning as the NES: the console moulds its own DE-9 sockets and the
	# stick wears the matching plug, so the two only look right together. Named
	# CX40 because the 2600 shipped two quite different controllers and the
	# paddle is still to come.
	"atari_2600": [
		{"kind": "peripheral", "label": "CX40 Joystick", "spawn": "atari_2600_cx40"},
	],
	# The SNES Mouse is here rather than left to the generic Controllers-tab mouse
	# because it wears its own connector and only fits a Super NES; the generic one
	# stays universal. The primitives are NOT dropped from this card — there is no
	# SNES console model or pad yet, so they are still the way to play it.
	"super_nes": [
		{"kind": "peripheral", "label": "SNES Mouse", "spawn": "snes_mouse"},
	],
}


## Platforms that model their own console AND their own pad, so the generic
## stand-ins are only clutter on their card. Everything else keeps them: for a
## platform with no hardware of its own they are the whole way to play it.
const _NO_STANDINS: Array[String] = ["nes", "atari_2600", "playstation"]


## Platforms that name their own A/V lead above, so the generic one would be a
## second cable doing the same job. The NES puts out one audio channel and lists the
## mono lead its console shipped with; the Wii has no phono sockets at all, so the
## generic lead would fit its television and nothing on the console.
const _OWN_AV_LEAD: Array[String] = ["nes", "wii"]

## Hardware whose picture leaves on a captive pigtail rather than through sockets
## (av_port_channels() is empty), so a spawned lead has nothing to enter at that
## end. Every handheld is one — items_for reads the registry's flag for those —
## and so is the Virtual Boy, which stands on a table and is not flagged handheld
## but wears no A/V sockets either.
##
## A platform with no model of its own is NOT one of these: it spawns the
## primitive box, which does wear the three sockets, and the lead is how its
## picture reaches the set.
const _NO_AV_SOCKETS: Array[String] = ["virtual_boy"]

## The lead every other platform reaches the TV with. Consoles spawn wearing a
## captive one, so this row is a spare — for a lead thrown in the trash, or a
## second TV.
const _AV_CABLE: Dictionary = {"kind": "peripheral", "label": "Composite Cable",
	"spawn": "composite_cable"}

## How a home computer is actually played. SystemInfo.computer marks the systems
## whose core reads the mouse on port 0 and takes keys globally — for those the
## pad is the odd peripheral and these two are the hardware, so they are listed
## on the card rather than left to the Controllers tab.
const _COMPUTER_INPUT: Array = [
	{"kind": "peripheral", "label": "Keyboard", "spawn": "retro_keyboard"},
	{"kind": "peripheral", "label": "Mouse", "spawn": "retro_mouse"},
]

## How a computer's picture reaches its monitor. Listed for computers only: the
## sockets it fits are the PC tower's and the CRT monitor's, and a console has
## neither. It does not replace the composite lead on those cards — VGA carries no
## sound, so a tower wired this way still needs the phono pair for audio, which is
## what the real machine needed too.
const _VGA_CABLE: Dictionary = {"kind": "peripheral", "label": "VGA Cable",
	"spawn": "vga_cable"}

## How a computer's sound reaches its speakers, and the speakers themselves. Listed
## for computers only, for the same reason the VGA lead is: the sockets a 3.5 mm plug
## fits are the tower's line out and the right speaker's line in, and a console has
## neither.
## The link lead, offered on the platforms that have a socket to put it in. Two
## handhelds and one cable is the whole of GBA multiplayer, and that lead carries
## a junction so a third and fourth can chain on.
##
## The Game Boy's is a different lead: black, and with nothing in the middle,
## because a Game Boy link is two machines and no more. The PlayStation's is
## different again -- different connector, different protocol -- so the three are
## three entries and can never be offered as one.
const _LINK_CABLE: Dictionary = {"kind": "peripheral", "label": "Link Cable", "spawn": "link_cable"}
const _GB_LINK_CABLE: Dictionary = {"kind": "peripheral", "label": "Link Cable",
	"spawn": "gb_link_cable"}
const _PSX_LINK_CABLE: Dictionary = {"kind": "peripheral", "label": "Link Cable",
	"spawn": "psx_link_cable"}

## The console-to-handheld lead, offered on BOTH platforms it joins. A player
## spawning a GameCube for Four Swords Adventures should be offered one without
## having to know it is filed under the handheld, and a player spawning a Game
## Boy Advance should be offered it without having to know it is filed under the
## console: it is one cable and it belongs to neither of them.
const _GC_GBA_CABLE: Dictionary = {"kind": "peripheral", "label": "GC-GBA Cable",
	"spawn": "gc_gba_cable"}
const _GC_GBA_PLATFORMS: Array = ["gamecube", "game_boy_advance"]

## Which lead each platform is offered, keyed on the PLATFORM rather than the
## model: the GBA and the SP are two models of one platform and both have the
## socket.
const _LINK_LEADS: Dictionary = {
	"game_boy_advance": _LINK_CABLE,
	"game_boy": _GB_LINK_CABLE,
	"playstation": _PSX_LINK_CABLE,
}


## The gun, offered on the platforms that sold one. One prop rather than a row per
## card because RetroXR models no Super Scope and no Light Phaser -- it is the
## generic stand-in, the same one the Controllers tab offers, so it is labelled
## for what it spawns rather than for the gun a given console shipped.
##
## Listed is hardware that really existed for the platform: the Zapper, the Super
## Scope, the Light Phaser, the Menacer and the Justifier, the Saturn's Stunner,
## the GunCon, Atari's XG-1, the Magnum Light Phaser on the three home computers
## it was sold for, the 3DO's Gamegun and the CD-i's Peacekeeper. A console that
## never had one does not get the row, so the card stays a hardware fact.
const _LIGHT_GUN: Dictionary = {"kind": "peripheral", "label": "Light Gun",
	"spawn": "light_gun"}
const _LIGHT_GUN_PLATFORMS: Array = [
	# No sega_cd: its card is the Mega-CD UNIT now, not a console, and the
	# Menacer and the Justifier plug into the Mega Drive underneath it -- whose
	# card is listed here and still offers the row. A gun on a card that spawns a
	# drive would describe a socket the drive does not have.
	"nes", "super_nes", "master_system", "mega_drive", "sega_saturn",
	"dreamcast", "playstation", "playstation2", "atari_2600", "atari_7800",
	"atari_8bit", "commodore_c64", "zx_spectrum", "cpc", "3do", "cdi",
]


const _TRS_KIT: Array = [
	{"kind": "peripheral", "label": "Speakers", "spawn": "speaker_pair"},
	{"kind": "peripheral", "label": "3.5 mm Cable", "spawn": "trs_cable"},
]


## The spawnable items for a system: its stand-in hardware, then the models that
## need imported assets, then its peripherals.
##
## The stand-ins lead the list — the platform's authored primitive models where it
## has any, then the Primitive System box, which is the only stand-in a platform
## without one has.
##
## `system_name` is unused now — a hardware row is labelled by its registry row
## rather than by the system's name, so a platform with two models says which is
## which. Kept in the signature because the menu passes it.
static func items_for(systemid: String, _system_name: String = "") -> Array:
	# An expansion with a card of its own IS this card, and is the whole of it.
	#
	# Almost every unit is also a systemid -- a 64DD's disks are "nintendo_64dd",
	# a Mega-CD's discs are "sega_cd" -- so each already had a tile in the systems
	# list, sitting beside the console it bolts to. That tile opened on "Primitive
	# System", because no model registry row serves those ids and the generic box
	# is the fallback. Pressing it spawned a whole imaginary console: a "Nintendo
	# 64DD system" that never existed, which is the exact fiction ExpansionCatalog
	# was written to replace. The tile was always the right home for the unit; it
	# was spawning the wrong thing.
	#
	# Nothing else belongs on this card. An expansion has no controller ports and
	# no sockets for a television -- it borrows both from the console standing on
	# it, and that console's own card still offers them. Offering a pad "for your
	# 64DD" would describe hardware that has nowhere to plug it in. The Mega-CD
	# loses its light-gun row the same way and for the same reason: the Menacer
	# goes into the Mega Drive, whose card already lists it.
	if ExpansionCatalog.has(systemid) and ExpansionCatalog.has_own_card(systemid):
		return [{"kind": "peripheral",
			"label": ExpansionCatalog.label_of(systemid),
			"spawn": "expansion:%s" % systemid}]

	var primitive: Array = []
	var imported: Array = []
	for row: Dictionary in SystemModelRegistry.rows_for(systemid):
		var item := {"kind": "system", "model_id": row.get("id", ""),
			"label": row.get("label", "Console")}
		if (row.get("requires", []) as Array).is_empty():
			primitive.append(item)
		else:
			imported.append(item)

	# Anything not played in the hand can also take the primitive box and the
	# primitive pad. A handheld gets neither: a console box is shaped nothing like
	# the device, and its controls are its own buttons. Nor does a platform in
	# _NO_STANDINS, which brings both of its own.
	var handheld := SystemModelRegistry.platform_is_handheld(systemid)
	var standins := not handheld and not _NO_STANDINS.has(systemid)

	var items: Array = []
	items.append_array(primitive)
	# The generic box stands in for a platform with NO plain model of its own.
	# Where the platform authored one — the PC tower, the Virtual Boy — it is a
	# second and worse console on the same card.
	if standins and primitive.is_empty():
		items.append({"kind": "system", "label": "Primitive System",
			"model_id": SystemModelRegistry.PLACEHOLDER_ID})
	items.append_array(imported)
	items.append_array((_PERIPHERALS.get(systemid, []) as Array).duplicate(true))
	# The machines that bolt onto this one -- but ONLY those with no card of
	# their own, or the unit would be offered from two places at once and the
	# console's card would grow a row that duplicates a whole tile.
	#
	# In practice that is the Jaguar CD alone: it runs the Jaguar's own media, so
	# it names no systemid, so it has no tile, so this card is the only place it
	# can be reached from. Read from ExpansionCatalog rather than listed, so a new
	# unit lands in the right place by having a row rather than an entry here.
	for expansion_id: String in ExpansionCatalog.ids_for_host(systemid):
		if ExpansionCatalog.has_own_card(expansion_id):
			continue
		items.append({"kind": "peripheral",
			"label": ExpansionCatalog.label_of(expansion_id),
			"spawn": "expansion:%s" % expansion_id})
	# With the peripherals rather than the leads below: it is something you hold.
	if _LIGHT_GUN_PLATFORMS.has(systemid):
		items.append(_LIGHT_GUN.duplicate())
	if _LINK_LEADS.has(systemid):
		items.append((_LINK_LEADS[systemid] as Dictionary).duplicate())
	if _GC_GBA_PLATFORMS.has(systemid):
		items.append(_GC_GBA_CABLE.duplicate())
	var info := SystemInfo.for_system(systemid)
	if info != null and info.computer:
		items.append_array(_COMPUTER_INPUT.duplicate(true))
		items.append(_VGA_CABLE.duplicate())
		items.append_array(_TRS_KIT.duplicate(true))
	if standins:
		items.append({"kind": "peripheral", "label": "Primitive Controller",
			"spawn": PRIMITIVE_CONTROLLER})
	if not handheld and not _NO_AV_SOCKETS.has(systemid) \
			and not _OWN_AV_LEAD.has(systemid):
		items.append(_AV_CABLE.duplicate())
	return items


## The single place that turns a catalog item into the string emitted on
## SpawnMenu2D.spawn_requested. Keeping this here means SpawnMenuController stays
## the one and only spawn authority.
##   system     → "model:<systemid>:<model_id>"
##   peripheral → the item's existing spawn string, verbatim
##
## The systemid rides along because the placeholder row belongs to no platform, so
## its id alone cannot say which core to load.
static func spawn_token(systemid: String, item: Dictionary) -> String:
	if item.get("kind", "system") == "peripheral":
		return item.get("spawn", "")
	return "model:%s:%s" % [systemid, item.get("model_id", "")]

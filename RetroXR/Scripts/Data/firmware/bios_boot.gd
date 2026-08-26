## BiosBoot — which machines can show their own BIOS, and what it takes.
##
## Two separate things live here because a player thinks of them as one:
##
##   * `empty_media` — the machine switched on with NOTHING in it lands in the
##     console's own BIOS. A PlayStation with no disc shows "Please insert
##     PlayStation CD-ROM" and its CD player / memory card menu.
##   * `splash` — a game IS loaded, and the machine plays the real boot ROM
##     first instead of skipping straight to it. The GameCube IPL animation.
##
## Both are gated on `boot_rom`, which is the answer to "is the BIOS actually
## there?". It is an ANY-OF group, and that is the thing the .info's own
## `firmwareN_opt` flag cannot express: pcsx_rearmed lists four PS1 BIOSes all
## marked optional because you need exactly one of them, and neocd lists twelve
## for the same reason. Reading `optional` there would conclude a machine with
## no BIOS at all is fully provisioned.
##
## PROVENANCE. Every row was measured on 2026-08-20 by Tools/bios_boot_probe,
## run one core per process by Tools/bios_boot_survey.sh. Nothing here is
## inferred from the .info files, and in particular nothing is inferred from
## `supports_no_game`: all sixteen candidates declare it false, including
## pcsx_rearmed, whose BIOS this feature demonstrably reaches.
##
## What the survey ruled OUT, so nobody re-derives these rows from the tables in
## the original request:
##
##   * NO core starts with no content at all. Sixteen were tried both ways the
##     libretro API allows (a null retro_game_info and a zeroed one) and six
##     crash the process outright: mgba and parallel_n64 dereference a null,
##     while mednafen_saturn, neocd, dolphin and same_cdi die on a zeroed one.
##     That is why the mechanism here is empty MEDIA -- a real file, taking the
##     ordinary content path -- and not an empty path.
##   * Only pcsx_rearmed accepts an empty image. flycast (gdi/cdi/chd),
##     mednafen_saturn, mednafen_pce and neocd all refuse a zero-byte file, so
##     Dreamcast, Saturn, PC Engine CD and Neo Geo CD have no `empty_media`.
##   * mgba, flycast, mednafen_pce and pcsx_rearmed already ship with their
##     boot-ROM options set the way this feature wants them. mgba's and
##     pcsx_rearmed's measured keys carry a `splash` anyway: these values are
##     PINNED every launch rather than seeded once, and a pin's job is to beat a
##     saved value, which a shipped default cannot do -- a run that left
##     mgba_skip_bios "ON" behind is the case, and the survey itself produced
##     one. flycast and mednafen_pce have no `splash` because the survey never
##     recorded their key names, and a key a core does not declare is rejected
##     rather than applied.
##   * The N64 has no BIOS. Both N64 cores' only firmware entry is the 64DD IPL,
##     and the N64's own boot animation lives in each cartridge's IPL3. The real
##     machine here is nintendo_64dd, which does boot to the 64DD menu.
##
## Keyed on "<core>/<systemid>", never on core alone. mgba wants gba_bios.bin on
## a GBA and the Game Boy boot ROMs on a Game Boy; dolphin wants an IPL on a
## GameCube and a NAND on a Wii; and the filenames differ between cores serving
## one machine too (sameboy's dmg_boot.bin against gambatte's gb_bios.bin).
class_name BiosBoot


const _ROWS := {
	# ── Nintendo ─────────────────────────────────────────────────────────────
	# The one machine here that boots with NOTHING in it rather than with an
	# empty image, and the only reason it can is that this fork's mgba was taught
	# to. Upstream's retro_load_game dereferences the game info without checking
	# it, so the core could not even be asked; it declares SET_SUPPORT_NO_GAME
	# now and creates a Game Boy Advance directly when there is no content.
	#
	# It is worth having beyond the BIOS animation. A GBA with no cartridge is
	# what sits on the end of a GameCube lead in Four Swords Adventures and what
	# receives a program in single-cartridge play: the BIOS draws its screen and
	# then listens on the link port, which is the whole of how both work.
	#
	"mgba/game_boy_advance": {
		"boot_rom": ["gba_bios.bin"],
		"empty_media": "",
		"no_content": true,
		"empty_options": {"mgba_use_bios": "ON", "mgba_skip_bios": "OFF"},
		"splash": {"mgba_use_bios": "ON", "mgba_skip_bios": "OFF"},
		"why": "Boots its own BIOS with no cartridge, and then listens on the link port",
	},
	# ── Sony ─────────────────────────────────────────────────────────────────
	# The one machine that reaches a full BIOS UI. Verified visually: an empty
	# .cue gives the real "Please insert PlayStation CD-ROM" screen, from which
	# the CD player and memory card manager are reachable. Its four BIOSes are
	# regional and any one will do.
	"pcsx_rearmed/playstation": {
		"boot_rom": ["scph5501.bin", "scph5500.bin", "scph5502.bin", "psxonpsp660.bin"],
		"empty_media": "cue",
		"empty_options": {"pcsx_rearmed_show_bios_bootlogo": "enabled",
			"pcsx_rearmed_bios": "auto"},
		"splash": {"pcsx_rearmed_show_bios_bootlogo": "enabled",
			"pcsx_rearmed_bios": "auto"},
		"why": "An empty disc gives the PS1 BIOS; measured, and the only machine where this works",
	},
	# Two PS2 cores, and they do NOT share the option key -- pcee2 says
	# pcsx2_fast_boot where LRPS2 says pcsx2_fastboot. Measured; the natural
	# guess is the wrong way round.
	"pcee2/playstation2": {
		"boot_rom": ["pcsx2/bios"],
		"empty_media": "",
		"splash": {"pcsx2_fast_boot": "disabled"},
		"why": "Fast Boot skips the PS2 boot animation and browser",
	},
	"pcsx2/playstation2": {
		"boot_rom": ["pcsx2/bios"],
		"empty_media": "",
		"splash": {"pcsx2_fastboot": "disabled"},
		"why": "Same switch as pcee2 under a different key",
	},

	# ── Nintendo ─────────────────────────────────────────────────────────────
	# GameCube only. A Wii row would need a NAND dump, which dolphin's .info
	# does not declare a path for, so there is nothing to check the option
	# against -- and enabling the Wii menu without one gives a black screen.
	"dolphin/gamecube": {
		"boot_rom": [
			"dolphin-emu/Sys/GC/USA/IPL.bin",
			"dolphin-emu/Sys/GC/EUR/IPL.bin",
			"dolphin-emu/Sys/GC/JAP/IPL.bin",
		],
		"empty_media": "",
		"splash": {"dolphin_skip_gc_bios": "disabled"},
		"why": "Plays the GameCube IPL animation before the disc",
	},
	# The 64DD, not the N64. parallel_n64 is the nintendo_64dd core and this is
	# a genuine boot-to-menu; pointing it at a plain N64 would boot every
	# cartridge through a disk drive that is not there.
	"parallel_n64/nintendo_64dd": {
		"boot_rom": ["64DD_IPL.bin"],
		"empty_media": "",
		"splash": {"parallel-n64-boot-device": "64DD IPL"},
		"why": "Boots the 64DD IPL menu rather than straight into the disk",
	},

	# ── Sega ─────────────────────────────────────────────────────────────────
	# One core, five machines, one option key -- but a different boot ROM each
	# time, which is exactly why these rows cannot be keyed on the core alone.
	"genesis_plus_gx/mega_drive": {
		"boot_rom": ["bios_MD.bin"],
		"empty_media": "",
		"splash": {"genesis_plus_gx_bios": "enabled"},
		"why": "Plays the Mega Drive TMSS startup screen",
	},
	"genesis_plus_gx/master_system": {
		"boot_rom": ["bios_U.sms", "bios_E.sms", "bios_J.sms"],
		"empty_media": "",
		"splash": {"genesis_plus_gx_bios": "enabled"},
		"why": "Plays the Master System boot ROM",
	},
	"genesis_plus_gx/game_gear": {
		"boot_rom": ["bios.gg"],
		"empty_media": "",
		"splash": {"genesis_plus_gx_bios": "enabled"},
		"why": "Plays the Game Gear boot ROM",
	},
	"genesis_plus_gx/sega_cd": {
		"boot_rom": ["bios_CD_U.bin", "bios_CD_E.bin", "bios_CD_J.bin"],
		"empty_media": "",
		"splash": {"genesis_plus_gx_bios": "enabled"},
		"why": "Plays the Sega CD boot ROM; the CD BIOS is required for the system anyway",
	},
}


## The row for one machine, or {} when it has nothing to offer.
static func entry(core_name: String, systemid: String) -> Dictionary:
	if core_name.is_empty() or systemid.is_empty():
		return {}
	return _ROWS.get(core_name + "/" + systemid, {})


## Is this machine's boot ROM actually on disk?
##
## ANY of the group satisfies it -- they are regional alternatives, not a set.
## A MISMATCH does not count: a file whose md5 disagrees with the .info is the
## wrong dump, classically a PS1 BIOS from the wrong region, and booting it is
## a worse outcome than not offering the boot at all.
static func boot_rom_present(core_name: String, systemid: String) -> bool:
	var row := entry(core_name, systemid)
	if row.is_empty():
		return false
	var wanted: Array = row.get("boot_rom", [])
	if wanted.is_empty():
		return false
	for status_row: Dictionary in _firmware_rows(core_name):
		if not wanted.has(str(status_row.get("path", ""))):
			continue
		if int(status_row.get("status", -1)) == FirmwareState.Status.PRESENT:
			return true
	return false


## Extension of the empty image that reaches this machine's BIOS, or "" when
## switching it on with an empty slot cannot get there.
static func empty_media_extension(core_name: String, systemid: String) -> String:
	return str(entry(core_name, systemid).get("empty_media", ""))


## Can this machine be switched on with nothing in it and show its own BIOS?
## The two halves are separate on purpose: a PlayStation with no BIOS installed
## has to keep saying "no game inserted", because an empty disc would only get
## it to a black screen.
static func can_boot_empty(core_name: String, systemid: String) -> bool:
	var has_empty := not empty_media_extension(core_name, systemid).is_empty()
	if not has_empty and not boots_with_no_content(core_name, systemid):
		return false
	return boot_rom_present(core_name, systemid)


## Does this machine start with NOTHING handed to it, rather than with an empty
## image standing in for a disc?
##
## Two different mechanisms, and the difference is not cosmetic. Empty media is a
## real file taking the ordinary content path, which is what a PlayStation needs
## because its BIOS wants a drive to look at. No content at all is the core being
## asked to start with a null game info, which most cores do not survive -- of
## sixteen surveyed, six took the process down -- so this is opt-in per row and
## measured, never assumed.
static func boots_with_no_content(core_name: String, systemid: String) -> bool:
	return bool(entry(core_name, systemid).get("no_content", false))


## Options that make an empty-slot boot take the measured BIOS path. They are
## explicit even when they match a core's shipped defaults: netplay cannot let
## one peer's saved option skip the BIOS while another waits in it.
static func empty_boot_options(core_name: String, systemid: String) -> Dictionary:
	return (entry(core_name, systemid).get("empty_options", {}) as Dictionary).duplicate()


## Firmware paths whose bytes decide the BIOS boot. Public for netplay's local
## fingerprint; firmware is never transferred.
static func boot_rom_paths(core_name: String, systemid: String) -> Array:
	return (entry(core_name, systemid).get("boot_rom", []) as Array).duplicate()


## Core options that make a loaded game play its boot ROM first. Empty unless
## the boot ROM is there -- every one of these tells a core to run a file, and
## switching them on without it is how a machine that used to start a game ends
## up on a black screen instead.
static func splash_options(core_name: String, systemid: String) -> Dictionary:
	var row := entry(core_name, systemid)
	var splash: Dictionary = row.get("splash", {})
	if splash.is_empty():
		return {}
	if not boot_rom_present(core_name, systemid):
		return {}
	return splash.duplicate()


## The options this machine's run pins, for the slot it is actually starting
## with. An empty slot and a loaded game reach the BIOS by different keys, so the
## caller says which boot it is rather than this guessing from the table.
##
## Both halves stay separately callable: net_boot_spec composes a launch
## description rather than a set of pins, and picks its own half.
static func pinned_options(core_name: String, systemid: String, empty_boot: bool) -> Dictionary:
	if empty_boot:
		return empty_boot_options(core_name, systemid)
	return splash_options(core_name, systemid)


## Every key any row for this core pins, as a set. For the core manager, which
## edits a core's options with no machine in front of it and so has no systemid
## to ask with -- a key one of this core's machines pins is shown locked for all
## of them, which is the safe way round: the alternative offers an edit that the
## next power-on silently reverts.
##
## Keys only. A value here would be a value for the wrong machine, since one core
## serves several and genesis_plus_gx's five rows share a key.
static func pinned_keys_for_core(core_name: String) -> Dictionary:
	var out: Dictionary = {}
	if core_name.is_empty():
		return out
	for row_key: String in _ROWS:
		if row_key.get_slice("/", 0) != core_name:
			continue
		var row: Dictionary = _ROWS[row_key]
		for group: String in ["splash", "empty_options"]:
			for key: Variant in (row.get(group, {}) as Dictionary):
				out[str(key)] = true
	return out


## Files this core cannot run at all without, and has not got.
##
## Straight from the .info's own required flag rather than from `boot_rom`:
## those two answer different questions. `boot_rom` asks whether a BIOS UI is
## reachable, which is a bonus; this asks whether the core will start, which
## decides whether the power button does anything. A machine can be missing its
## boot ROM and still play games perfectly (a Mega Drive), or have every
## optional file and still refuse to start (a PS2 with no bios folder).
##
## Returns the FirmwareState rows, each carrying `path`, `desc` and `dest`.
static func missing_required(core_name: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row: Dictionary in _firmware_rows(core_name):
		if int(row.get("status", -1)) == FirmwareState.Status.MISSING_REQUIRED:
			out.append(row)
	return out


static func _firmware_rows(core_name: String) -> Array[Dictionary]:
	var reqs := FirmwareRequirements.for_core(core_name)
	if reqs.is_empty():
		return [] as Array[Dictionary]
	return FirmwareState.shared().evaluate(core_name, reqs)


# ── Empty media ───────────────────────────────────────────────────────────────

## A zero-byte image for a machine switched on with an empty slot.
##
## Kept in the libretro temp dir rather than the ROM library: it is not a game,
## nothing should index it, and a player browsing their PlayStation folder must
## never be offered it. One file per extension, reused -- it is read-only to the
## core, so two machines can share it.
##
## Returns "" if it could not be written, which the caller must treat as "this
## machine cannot show its BIOS" rather than pressing on with an empty path.
static func empty_media_path(extension: String) -> String:
	if extension.is_empty():
		return ""
	var dir := CoreDownloadManager.default_core_root().path_join("temp")
	if DirAccess.make_dir_recursive_absolute(dir) != OK and not DirAccess.dir_exists_absolute(dir):
		push_warning("[BiosBoot] cannot create %s" % dir)
		return ""
	var path := dir.path_join("no_disc." + extension)
	if FileAccess.file_exists(path):
		return path
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[BiosBoot] cannot write %s" % path)
		return ""
	f.close()
	return path

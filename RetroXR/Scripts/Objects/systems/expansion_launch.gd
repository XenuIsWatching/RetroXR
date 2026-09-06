## ExpansionLaunch — what a stacked expansion hands the core at boot.
##
## The six functions that turn an expansion stack into a launch: which ROMs the
## unit contributes, which of them the console should boot from, the subsystem
## call for an adapter that takes two cartridges, and the warning when a sidecar
## file the row promised is not on disk.
##
## Split from the expansion HARDWARE, which stays on RetroSystem. That half
## parents sockets to the console, reads its global_position and touches
## fourteen of its private names — moving it would need thirteen new accessors
## and leave a helper reaching back on every line, which is not a boundary. This
## half reaches three, so it is one.
##
## Held like MemoryCardController and SaveStateController: a child node built in
## RetroSystem._init with a `_host` back-reference.
class_name ExpansionLaunch
extends Node

var _host: RetroSystem = null

## True while the console's rom_path holds a path the STACK chose rather than
## its own cartridge. Only such a path may be taken back out when the stack
## stops offering one. Moved here with the launch half: nothing else reads it.
var _stack_set_rom_path := false


func setup(host: RetroSystem) -> void:
	_host = host


## The launch recipe for the machine as assembled, or {} when this combination
## has none -- which is the ordinary state of a bare console.
func expansion_boot() -> Dictionary:
	var spec := ExpansionCatalog.boot_for(_host.systemid, _host.expansion_ids())
	if spec.is_empty():
		return spec
	# A row that pins its core only while the console's own slot is filled drops
	# that core for a lone disk, so the machine resolves one the way a bare
	# console does -- the player's own pick, or the manager's default. Every
	# other row keeps its core whether or not a cartridge is in the console.
	if spec.get("core_only_with_host", false) and host_media_path().is_empty():
		spec = spec.duplicate()
		spec.erase("core")
		return spec
	# `core` is a desktop core_name, and the buildbot does not publish every core
	# under one name on every platform -- mupen64plus_next is plain on Windows and
	# only _gles2/_gles3 on Android. A row naming one of those carries an
	# `android` override, read here the way CoreRecommendations reads its own:
	# without it a Quest resolved to a core that cannot be installed there, and
	# the machine reported the core missing when it was asked to start.
	var resolved := ExpansionCatalog.core_of(spec, OS.get_name() == "Android")
	if resolved != str(spec.get("core", "")):
		spec = spec.duplicate()
		spec["core"] = resolved
	return spec


## What is in the CONSOLE's own slot -- read from the cartridge, not from
## _host.rom_path, which the launch path overwrites with whatever the stack boots
## from. Asking twice must give the same answer.
func host_media_path() -> String:
	if is_instance_valid(_host.get_snapped_cartridge()) \
			and "rom_path" in _host.get_snapped_cartridge():
		return str(_host.get_snapped_cartridge().get("rom_path"))
	return ""


## The paths the recipe names, in its order, skipping any bay that is empty. An
## empty result means the stack has nothing to run, which is the ordinary state
## of a drive with no disk in it and not a fault.
##
## The core is handed the FIRST survivor and no more: every combination in the
## catalog loads through a plain retro_load_game with one path, because that is
## what the cores themselves do. The rest of the list is not dead -- it is what
## makes "cartridge if there is one, otherwise the disk" fall out of an ordered
## list rather than a special case.
## Public because expansion_tests asserts against it directly - 23 call sites.
## An underscore would promise the name may change freely, and a suite that
## names it is a caller that cannot.
func expansion_roms(spec: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for token: String in spec.get("roms", []):
		var path := ""
		if token == "host":
			path = host_media_path()
		else:
			# Three ways to name a unit's content, because the BS-X cartridge has
			# two of them: the shell moulded into the cartridge and the pack in
			# its bay. The plain form prefers the bay and falls back to the shell,
			# which is what makes an empty BS-X cart still bootable. The two
			# explicit forms do NOT fall back -- a subsystem pairing needs the
			# halves kept apart, and a fallback there would hand the core the
			# shell twice whenever the bay stood empty.
			var kind := "expansion"
			var id := ""
			# No prefix here may be a literal prefix of another, or the order of
			# this list silently starts deciding which one matches.
			# "expansion_media_b:" and "expansion_media:" diverge at the
			# sixteenth character -- "_" against ":" -- so neither contains the
			# other. The longer is listed first regardless, as the house rule for
			# whoever adds the next one.
			for prefix in ["expansion_media_b:", "expansion_rom:",
					"expansion_media:", "expansion:"]:
				if token.begins_with(prefix):
					kind = prefix.trim_suffix(":")
					id = token.substr(prefix.length())
					break
			for unit in _host.get_expansions():
				if unit.expansion_id != id:
					continue
				match kind:
					"expansion_rom":
						path = unit.rom_path
						if path.is_empty():
							path = ExpansionCatalog.firmware_rom_path(id)
					"expansion_media":
						path = unit.get_media_path()
					# The second cartridge of a unit that takes two. No fallback,
					# for the same reason the first has none: a pairing needs its
					# halves kept apart, and a unit with only one bay filled must
					# come up SHORT so the count check sends it to the plain load.
					"expansion_media_b":
						path = unit.get_media_path(1)
					_:
						path = unit.get_media_path()
						if path.is_empty():
							path = unit.rom_path
							if path.is_empty():
								path = ExpansionCatalog.firmware_rom_path(id)
				# A broadcast that cannot start from its dump alone is handed to
				# the core as a PATCHED COPY, never as the player's file. With no
				# patch beside it this is the same path back again.
				path = BsPatch.resolved_path(path)
				break
		if not path.is_empty():
			out.append(path)
	return out


## Say so when a disk is in the drive and the core is about to ignore it.
##
## mupen64plus_next attaches a 64DD disk to a cartridge only when the disk sits
## beside the cartridge named after it, which is a convention no arrangement of
## objects in a room can satisfy. The cartridge boots and looks completely
## correct; the only tell is a missing line on the title screen. Better to say
## it out loud than to let it pass for working.
func warn_missing_sidecar(spec: Dictionary) -> void:
	var sidecar := str(spec.get("sidecar", ""))
	if sidecar.is_empty() or host_media_path().is_empty():
		return
	var disk := ""
	for unit in _host.get_expansions():
		var p := unit.get_media_path()
		if not p.is_empty():
			disk = p
			break
	if disk.is_empty():
		return
	var expected := host_media_path() + sidecar
	if FileAccess.file_exists(expected):
		return
	push_warning("[RetroSystem] %s can only read a disk named %s from the cartridge's own folder; %s will be IGNORED and the cartridge will boot without the drive attached (see ExpansionCatalog)"
		% [str(spec.get("core", "")), expected.get_file(), disk.get_file()])


## Point _host.rom_path at whatever the ASSEMBLED machine boots from, and return the
## recipe so power_on can also ask about the sidecar and the pinned options.
##
## _host.rom_path itself, rather than a second field carried alongside it: everything
## downstream of here -- the power-on verdict, the content resolver, the SRAM
## path, the achievements claim, the netplay hash -- reads that one field, and a
## second source of truth would have to be threaded through all of them. The
## console's own cartridge is not lost by this; it is still in the slot, which is
## what host_media_path asks, and the field is recomputed from scratch on the
## next power-on.
func apply_expansion_launch() -> Dictionary:
	var spec := expansion_boot()
	var roms := expansion_roms(spec) if not spec.is_empty() else ([] as Array[String])

	if roms.is_empty():
		# Nothing to boot from the stack: either it has been unbolted, or every
		# bay in it is empty, which is the ordinary state of a drive with no disk
		# in it. Either way the last disk this machine saw is not in it any more,
		# and only what WE put in _host.rom_path may be taken back out -- a cartridge
		# in the console's own slot is not ours to clear.
		if _stack_set_rom_path:
			_host.rom_path = host_media_path()
			_stack_set_rom_path = false
		return spec

	_host.rom_path = roms[0]
	_stack_set_rom_path = true
	return spec


## Hand the core every piece of the assembled machine at once, and say whether
## that happened.
##
## This is what a cartridge and its expansion disk actually need. The single-path
## load can only attach the two by filename convention -- the disk has to sit
## beside the cartridge, named after it -- which no arrangement of objects in a
## room can satisfy, so a stack that is plainly loaded boots as if the drive were
## empty. libretro's own answer is a subsystem: the core publishes what
## combinations it accepts and the frontend hands over the ordered set.
##
## Returns false whenever the ordinary load should be used instead: a combination
## with no subsystem, a core bridge too old to have the call, or a bay standing
## empty. An empty bay is the ordinary state of a drive with no disk in it, not a
## fault, and the machine should still start on whatever IS loaded.
##
## The order is the CORE's, not the preference order the rest of this file uses.
## For the 64DD the core declares its disk first and the cartridge second, which
## is the reverse of which one a lone machine would boot from.
func start_subsystem_content(dir: String, core: String, spec: Dictionary) -> bool:
	var sub: Dictionary = spec.get("subsystem", {})
	if sub.is_empty():
		return false
	var ident := str(sub.get("ident", ""))
	if ident.is_empty():
		return false
	if not _host.get_libretro_node().has_method("StartSubsystemContent"):
		return false
	var wanted: Array = sub.get("roms", [])
	var paths := expansion_roms(sub)
	if paths.size() != wanted.size():
		return false
	# One of the pair can be a WRITABLE medium rather than a read-only ROM: a
	# BS-X memory pack is flash, and the .bs handed over IS the flash, so what the
	# core writes has to go back to that same file. Named by index because only
	# the recipe knows which half of a pairing is the medium.
	var writable := int(sub.get("writable", -1))
	if writable >= 0 and writable < paths.size() and _host.get_libretro_node().has_method("SetPackPath"):
		_host.get_libretro_node().SetPackPath(paths[writable])
	# A second cartridge has a second battery, and the core keeps it in a region
	# of its own. Set before the load, because the bridge reads the file back
	# into the core as the content comes up.
	var slot_b := _host.slot_b_save_path(core)
	if not slot_b.is_empty() and _host.get_libretro_node().has_method("SetSramBPath"):
		_host.get_libretro_node().SetSramBPath(slot_b)
	print("[RetroSystem] subsystem load: %s %s <- %s" % [core, ident, str(paths)])
	_host.get_libretro_node().StartSubsystemContent(dir, core, _host.rom_path, ident, PackedStringArray(paths))
	return true


## Where the SECOND cartridge's battery is kept, or "" on every machine that
## holds one cartridge.
##
## Keyed off that cartridge's OWN save_id, exactly as the first one is, so a save
## follows the cartridge rather than the slot: swap which game is in slot B and
## it brings its own progress with it, and putting it in slot A later finds the
## same file. Keying it off the slot instead would give a linked pair one save
## per POSITION, so lending a cartridge to a different game would overwrite it.

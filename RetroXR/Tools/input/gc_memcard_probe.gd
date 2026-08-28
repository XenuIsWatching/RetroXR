## Drives a real Dolphin with real GameCube memory cards in both slots, which is
## the half no headless suite can reach: that the fork's dolphin_memcard_*_path
## options seat the exact files RetroXR named, verbatim and per slot.
##
##     "$godot" --headless --path RetroXR res://Tools/input/gc_memcard_probe.tscn -- \
##         "--gc-rom=$HOME/retroxr/roms/gamecube/Some Game.rvz"
##
## Exits non-zero on failure. A probe rather than a test: it wants the Dolphin
## core, a GameCube ROM, and firmware.
##
## What it proves, in order:
##   1. two cards RetroXR formatted are accepted and the core comes up
##   2. the paths are used VERBATIM -- no .USA, no .251, no <region>/ subdir,
##      which is what Config::GetMemcardPath would otherwise impose
##   3. a card can be pulled mid-game, and the eject is what makes it durable
extends Node

const FRAMES_TO_RUN := 900
const CARD_A := "__gc_probe_a"
const CARD_B := "__gc_probe_b"

var _sys: Node3D = null
var _fail := 0
var _rom := ""


func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("[probe] PASS  %s" % name)
	else:
		_fail += 1
		print("[probe] FAIL  %s%s" % [name, "  - " + detail if not detail.is_empty() else ""])


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--gc-rom="):
			_rom = str(a).substr("--gc-rom=".length())
	if _rom.is_empty() or not FileAccess.file_exists(_rom):
		print("[probe] need --gc-rom=<path to a GameCube disc image>")
		get_tree().quit(1)
		return
	await _run()
	print("[probe] ---- %s ----" % ["FAIL" if _fail > 0 else "PASS"])
	get_tree().quit(1 if _fail > 0 else 0)


func _run() -> void:
	# Fresh cards each run, so "the file changed" means this run changed it.
	for id in [CARD_A, CARD_B]:
		var p := SramPaths.card_save_path("gamecube", id)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	var path_a := SramPaths.ensure_card("gamecube", CARD_A)
	var path_b := SramPaths.ensure_card("gamecube", CARD_B)
	print("[probe] card A = %s" % path_a)
	print("[probe] card B = %s" % path_b)
	_ok("blank A is a card", GCCard.is_card_image(FileAccess.get_file_as_bytes(path_a)))
	_ok("blank B is a card", GCCard.is_card_image(FileAccess.get_file_as_bytes(path_b)))

	_sys = preload("res://Scenes/Objects/system.tscn").instantiate() as Node3D
	_sys.set("systemid", "gamecube")
	_sys.set("rom_path", _rom)
	add_child(_sys)
	await get_tree().process_frame

	var card_a := _spawn_card(CARD_A)
	var card_b := _spawn_card(CARD_B)
	_sys.call("restore_memory_card", card_a, 0)
	_sys.call("restore_memory_card", card_b, 1)
	await get_tree().process_frame
	_ok("card A seated", _sys.call("get_snapped_memcard", 0) != null)
	_ok("card B seated", _sys.call("get_snapped_memcard", 1) != null)

	_sys.call("toggle_power")

	# The options the core is about to read. Written before StartContent, so they
	# are on disk by now whether or not the core has come up.
	var core: String = _sys.call("_resolve_core")
	var opts := _read_opt(str(_sys.call("_resolve_dir")), core)
	var opt_a := str(opts.get("dolphin_memcard_a_path", ""))
	var opt_b := str(opts.get("dolphin_memcard_b_path", ""))
	print("[probe] option A = %s" % opt_a)
	print("[probe] option B = %s" % opt_b)
	_ok("slot A option is card A's exact path", opt_a == path_a, opt_a)
	_ok("slot B option is card B's exact path", opt_b == path_b, opt_b)

	var frames := 0
	while frames < FRAMES_TO_RUN:
		await get_tree().process_frame
		frames += 1

	# Nothing beside our two files. This is the check that would go red if the
	# region rewriting were still reaching the path: it would produce
	# "__gc_probe_a.USA.251.raw" beside them, or a USA/ subdirectory.
	var dir := SramPaths.cards_dir("gamecube")
	var strays: Array[String] = []
	for f: String in DirAccess.get_files_at(dir):
		if not f.begins_with("__gc_probe"):
			continue
		if f != "%s.raw" % CARD_A and f != "%s.raw" % CARD_B:
			strays.append(f)
	_ok("no region-mangled twin was created", strays.is_empty(), ", ".join(strays))
	var subdirs := DirAccess.get_directories_at(dir)
	_ok("and no region subdirectory", subdirs.is_empty(), ", ".join(subdirs))

	# Pulling a card is its durability point: ChangeDevice destroys the device
	# and ~MemoryCard joins its flush thread.
	#
	# Shutting the zone for the move is the whole gesture, not tidiness:
	# drop_object() alone leaves the card sitting inside a zone that grabs it
	# straight back, and the log reads "removed" immediately followed by
	# "inserted". The A/V suite pulls a phono plug exactly this way.
	var before := FileAccess.get_modified_time(path_a)
	var zone := _sys.get_node("MemoryCardSlot")
	zone.set("enabled", false)
	zone.call("drop_object")
	card_a.global_position += Vector3(0, 0.5, 0)
	for i in 240:
		await get_tree().process_frame
	_ok("card A came out", _sys.call("get_snapped_memcard", 0) == null)
	var after_bytes := FileAccess.get_file_as_bytes(path_a)
	_ok("and its file is still a valid card", GCCard.is_card_image(after_bytes))
	print("[probe] card A mtime %d -> %d, %d bytes"
		% [before, FileAccess.get_modified_time(path_a), after_bytes.size()])

	# The watcher that stands in for sram_flushed, which Dolphin never raises.
	# Splice a save into slot B's file behind the core's back, which is what a
	# game writing one looks like from out here, and confirm the poll notices and
	# attributes it. _changed_card_saves is the half that decides what gets sent
	# to RomM, so this is the sync path end to end short of a server.
	var gci := PackedByteArray()
	gci.resize(GCCard.DENTRY_SIZE + GCCard.BLOCK_SIZE)
	gci.fill(0)
	for i in 4:
		gci[GCCard.E_GAMECODE + i] = "GPRB".unicode_at(i)
	for i in 2:
		gci[GCCard.E_MAKERCODE + i] = "01".unicode_at(i)
	for i in "probe_save".length():
		gci[GCCard.E_FILENAME + i] = "probe_save".unicode_at(i)
	for i in 4:
		gci[GCCard.E_IMAGE_OFF + i] = 0xFF
		gci[GCCard.E_COMMENTS + i] = 0xFF
	GCCard._put_be16(gci, GCCard.E_FIRSTBLK, GCCard.SYSTEM_BLOCKS)
	GCCard._put_be16(gci, GCCard.E_BLOCKS, 1)
	_ok("the probe's save is a valid gci", GCCard.is_gci(gci))

	var merged := GCCard.insert_save(FileAccess.get_file_as_bytes(path_b), gci)
	_ok("it splices into card B", not merged.is_empty())
	var f := FileAccess.open(path_b, FileAccess.WRITE)
	f.store_buffer(merged)
	f.close()

	# What is asserted is that the WATCHER fired, not that an upload happened:
	# _sync_card_saves bails without a configured server, and on this box there
	# may not be one. The mtime the poll recorded is the mechanism's own
	# evidence that it looked at the file and accepted it.
	var seen := false
	for i in 300:
		await get_tree().process_frame
		var mtimes: Array = _sys.get("_card_mtimes")
		if int(mtimes[1]) != 0:
			seen = true
			break
	_ok("the poll noticed card B was written", seen,
		"mtime never recorded after 300 frames")
	print("[probe] SaveSync available = %s" % SaveSync.is_available())

	var listed := GCCard.list_saves(FileAccess.get_file_as_bytes(path_b), false)
	_ok("card B now holds the save", listed.size() == 1)
	_ok("under its own name",
		listed.size() == 1 and str(listed[0]["name"]) == "probe_save")

	_sys.call("toggle_power")
	for i in 120:
		await get_tree().process_frame
	for p in [path_a, path_b]:
		_ok("%s survives power-off intact" % p.get_file(),
			GCCard.is_card_image(FileAccess.get_file_as_bytes(p)))


func _spawn_card(id: String) -> Node3D:
	var card: Node3D = preload("res://Scenes/Objects/media/gc_memory_card.tscn").instantiate()
	card.set("card_id", id)
	card.set("card_label", id)
	add_child(card)
	return card


## The options file the core actually reads, parsed the way the C++ parses it:
## key up to the first "=", value in quotes after it.
func _read_opt(root: String, core: String) -> Dictionary:
	var out: Dictionary = {}
	var path := root.path_join("core_options").path_join(core + ".opt")
	if not FileAccess.file_exists(path):
		print("[probe] no options file at %s" % path)
		return out
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var eq := line.find("=")
		if eq < 0:
			continue
		var value := line.substr(eq + 1).strip_edges()
		out[line.substr(0, eq).strip_edges()] = \
			value.trim_prefix("\"").trim_suffix("\"")
	return out

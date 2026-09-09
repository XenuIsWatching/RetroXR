## Drives a real PlayStation 2 core with real memory cards in both slots — the
## half no headless suite can reach.
##
##     "$godot" --headless --path RetroXR res://Tools/input/ps2_memcard_probe.tscn -- \
##         "--ps2-rom=$HOME/retroxr/roms/playstation2/Some Game.iso" --ps2-core=pcsx2
##
## Exits non-zero on failure. A probe rather than a test: it wants a PS2 core, a
## PS2 BIOS in <system>/<core>/pcsx2/bios, and a disc image.
##
## What it proves, in order:
##   1. a disc's BOOT2 line yields its serial, which is how a save on a card gets
##      attributed to a game
##   2. two cards RetroXR FORMATTED are copied into the directory the core reads,
##      under the names that core expects, before the core loads
##   3. the core comes up with them
##   4. whatever the core writes comes back out to the player's own card files,
##      and they are still cards afterwards
##
## The one assertion this cannot make itself is the one that matters most: LRPS2
## logs each slot as "Formatted" or "UNFORMATTED" as it opens it, and `Libretro`
## publishes no log signal, so the CALLER greps the run for it:
##
##     ... 2>&1 | grep -a "McdSlot"
extends Node

const CARD_A := "__ps2_probe_a"
const CARD_B := "__ps2_probe_b"
const RUN_SECONDS := 120.0

var _sys: Node3D = null
var _fail := 0
var _rom := ""
var _core := "pcsx2"
var _shots := ""


## The core's frame arrives with an alpha channel it never fills, so a straight
## save_png writes a fully transparent image that every viewer paints blank.
func _rgb_bytes(img: Image) -> PackedByteArray:
	var src := img.get_data()
	var out := PackedByteArray()
	out.resize(img.get_width() * img.get_height() * 3)
	var i := 0
	var o := 0
	while o < out.size():
		out[o] = src[i]
		out[o + 1] = src[i + 1]
		out[o + 2] = src[i + 2]
		o += 3
		i += 4
	return out


func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		print("[probe] PASS  %s" % name)
	else:
		_fail += 1
		print("[probe] FAIL  %s%s" % [name, "  - " + detail if not detail.is_empty() else ""])


func _ready() -> void:
	get_tree().create_timer(420.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--ps2-rom="):
			_rom = s.substr("--ps2-rom=".length())
		elif s.begins_with("--ps2-core="):
			_core = s.substr("--ps2-core=".length())
		elif s.begins_with("--shots="):
			_shots = s.substr("--shots=".length())
			DirAccess.make_dir_recursive_absolute(
				ProjectSettings.globalize_path(_shots))
	if _rom.is_empty() or not FileAccess.file_exists(_rom):
		print("[probe] need --ps2-rom=<path to a PS2 disc image>")
		get_tree().quit(1)
		return
	await _run()
	print("[probe] ---- %s ----" % ["FAIL" if _fail > 0 else "PASS"])
	get_tree().quit(1 if _fail > 0 else 0)


func _run() -> void:
	# A disc's own serial. Nothing else maps a save's product code to a library
	# entry, so this is the front half of RomM attribution.
	var serial := PS2Disc.serial_of(_rom)
	_ok("the disc names its serial", not serial.is_empty(), "got '%s'" % serial)
	print("[probe] %s -> %s" % [_rom.get_file(), serial])

	# Fresh cards each run, so "the file changed" means this run changed it.
	for id in [CARD_A, CARD_B]:
		var p := SramPaths.card_save_path("playstation2", id)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	var path_a := SramPaths.ensure_card("playstation2", CARD_A)
	var path_b := SramPaths.ensure_card("playstation2", CARD_B)
	print("[probe] card A = %s" % path_a)
	print("[probe] card B = %s" % path_b)
	var blank_a := FileAccess.get_file_as_bytes(path_a)
	_ok("blank A is a formatted card", PS2Card.is_card_image(blank_a))
	_ok("blank B is a formatted card",
		PS2Card.is_card_image(FileAccess.get_file_as_bytes(path_b)))
	_ok("and reports its whole self free",
		PS2Card.free_blocks(blank_a) == PS2Card.total_blocks(blank_a))

	_sys = preload("res://Scenes/Objects/system.tscn").instantiate() as Node3D
	_sys.set("systemid", "playstation2")
	_sys.set("rom_path", _rom)
	add_child(_sys)
	await get_tree().process_frame
	_ok("the machine has two card slots", int(_sys.call("card_slot_count")) == 2,
		"got %d" % int(_sys.call("card_slot_count")))

	var card_a := _spawn_card(CARD_A)
	var card_b := _spawn_card(CARD_B)
	_sys.call("restore_memory_card", card_a, 0)
	_sys.call("restore_memory_card", card_b, 1)
	await get_tree().process_frame
	_ok("card A seated", _sys.call("get_snapped_memcard", 0) != null)
	_ok("card B seated", _sys.call("get_snapped_memcard", 1) != null)

	_sys.call("toggle_power")

	# The mirror lands BEFORE the core loads, so by here the directory exists and
	# holds both cards under the names this core looks for.
	var core: String = _sys.call("_resolve_core")
	print("[probe] resolved core = %s" % core)
	var row := MemcardMounts.for_core(core)
	_ok("the core is one that owns its card files", not row.is_empty())
	var dir := MemcardMounts.mount_dir(core)
	print("[probe] mount dir = %s" % dir)
	_ok("its card directory exists", DirAccess.dir_exists_absolute(dir))

	var leaf_a := MemcardMounts.scratch_name(row, 0, CARD_A)
	var leaf_b := MemcardMounts.scratch_name(row, 1, CARD_B)
	var mir_a := dir.path_join(leaf_a)
	var mir_b := dir.path_join(leaf_b)
	print("[probe] slot 1 -> %s" % leaf_a)
	print("[probe] slot 2 -> %s" % leaf_b)
	_ok("slot 1's card was staged", FileAccess.file_exists(mir_a), mir_a)
	_ok("slot 2's card was staged", FileAccess.file_exists(mir_b), mir_b)
	_ok("staged byte for byte from the player's own card",
		FileAccess.get_file_as_bytes(mir_a) == blank_a)

	# Shared cards is the only mode with two slots at all: the per-game branch
	# names slot 1 after the ROM and disables slot 2.
	if row.get("forced", {}).has("pcsx2_shared_memory_cards"):
		var opts := _read_opt(str(_sys.call("_resolve_dir")), core)
		_ok("shared memory cards is forced on",
			str(opts.get("pcsx2_shared_memory_cards", "")) == "enabled",
			str(opts.get("pcsx2_shared_memory_cards", "<unset>")))

	# The core comes up asynchronously; its identity is empty until content has
	# loaded, which makes it the readiness test as well as the identity.
	var lib: Object = _sys.call("get_libretro_node")
	var up := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 90000:
		await get_tree().process_frame
		var ident: Dictionary = lib.call("GetCoreIdentity")
		if not ident.is_empty():
			up = true
			print("[probe] core up after %d ms: %s %s"
				% [Time.get_ticks_msec() - t0, ident.get("library_name", "?"),
					ident.get("library_version", "?")])
			break
	_ok("the core came up with the cards seated", up,
		"no identity in 90 s - BIOS missing, or the disc was refused")
	if not up:
		return

	# Let the game run, sampling its picture. This is the only way to hear the
	# console's own verdict on the card: LRPS2 logs each slot as "Formatted" or
	# "UNFORMATTED" as it opens it, but nothing forwards a core's log out of
	# here, so the game saying "no save data" rather than "unformatted" is the
	# evidence. Run WINDOWED for this — headless hands back a correctly sized
	# frame with nothing drawn in it.
	var t1 := Time.get_ticks_msec()
	var next_shot := 0.0
	var next_press := 1.0
	var holding := false
	while Time.get_ticks_msec() - t1 < RUN_SECONDS * 1000.0:
		await get_tree().process_frame
		var at := (Time.get_ticks_msec() - t1) / 1000.0

		# A game will not reach its memory card until somebody presses a button:
		# Ace Combat 04 opens on a language chooser and waits there forever. So
		# tap CROSS — RetroPad B on a PlayStation — every couple of seconds, held
		# long enough for the game to see an edge and released so the next tap
		# is a fresh one.
		if at >= next_press:
			holding = not holding
			lib.call("SetJoypadState", 0, 1 if holding else 0, 0, 0, 0, 0)
			next_press = at + (0.15 if holding else 1.6)
		if _shots.is_empty() or at < next_shot:
			continue
		next_shot = at + 5.0
		var img: Image = lib.call("GetVideoImage")
		if img == null or img.is_empty():
			print("[probe] t=%4.1f  (no image)" % at)
			continue
		var flat := Image.create_from_data(img.get_width(), img.get_height(),
			false, Image.FORMAT_RGB8, _rgb_bytes(img))
		flat.save_png("%s/ps2_run_%05.1f.png" % [_shots, at])
		print("[probe] t=%4.1f  %dx%d  frames=%d"
			% [at, img.get_width(), img.get_height(), int(lib.call("GetFrameCount"))])

	var wrote_a := FileAccess.get_modified_time(mir_a)
	print("[probe] staged A mtime %d, %d bytes"
		% [wrote_a, FileAccess.get_file_as_bytes(mir_a).size()])
	_ok("the staged card is still a card after a run",
		PS2Card.is_card_image(FileAccess.get_file_as_bytes(mir_a)))

	# Power off, then wait out the drain: StopContent is non-blocking and the
	# core's own last write lands on the emulation thread afterwards.
	_sys.call("toggle_power")
	var t2 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t2 < 20000:
		await get_tree().process_frame

	for p in [path_a, path_b]:
		var bytes := FileAccess.get_file_as_bytes(p)
		_ok("%s survives power-off as a card" % p.get_file(),
			PS2Card.is_card_image(bytes))
		print("[probe]   %s  %d saves, %d/%d free" % [p.get_file(),
			PS2Card.list_saves(bytes, false).size(),
			PS2Card.free_blocks(bytes), PS2Card.total_blocks(bytes)])


func _spawn_card(id: String) -> Node3D:
	var card: Node3D = preload("res://Scenes/Objects/media/ps2_memory_card.tscn").instantiate()
	card.set("card_id", id)
	card.set("card_label", id)
	add_child(card)
	return card


## The options file the core actually reads, parsed the way the C++ parses it.
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

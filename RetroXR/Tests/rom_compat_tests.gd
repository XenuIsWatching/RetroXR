## rom_compat_tests — will this core accept this file, and what do we tell the
## player when it will not?
##
## RomCompat exists because libretro-godot hands a path straight to
## retro_load_game and a refusal signals nothing back to GDScript: the machine
## sits powered on with a black screen. Every rule here is the difference between
## that and a sentence saying what is wrong, so the rules are worth pinning.
##
## The one that must never break is the archive exception. For fbneo, MAME and
## daphne a .zip IS the ROM — a romset is a directory of named entries, not a
## wrapper round one file — so a core that DECLARES zip is handed the archive
## untouched. 67 of the 314 vendored .info files declare it and every one means
## it; "helpfully" unpacking for them would break games that work today.
##
## Nothing here touches the disk or needs a core: evaluate() judges a path
## against a declared extension list, and the archive helpers take the entry
## names as an array.
##
##   "$godot" --headless --path RetroXR res://Tests/rom_compat_tests.tscn
extends Node

var _passed := 0
var _failed := 0


func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		push_error("[romcompat] TIMEOUT")
		get_tree().quit(1))

	_group_entries()
	_group_wording()
	_group_verdict()

	print("[romcompat] %d checks, %d failed" % [_passed + _failed, _failed])
	print("[romcompat] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if cond:
		_passed += 1
		print("[romcompat] ok   %s" % what)
	else:
		_failed += 1
		print("[romcompat] FAIL %s%s" % [what, "" if detail.is_empty() else "  -- " + detail])


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what, "got %s, want %s" % [got, want])


# ── entries/ ──────────────────────────────────────────────────────────────────

## Which member of an archive gets launched, and which are not even candidates.
func _group_entries() -> void:
	var exts: Array[String] = ["cue", "bin", "iso"]

	# A disc manifest names the tracks beside it, so handing the core a raw .bin
	# out of an unpacked cue/bin pair throws the track layout away — the game
	# loads and then has no audio, or no second track at all.
	_eq(RomCompat._choose_entry(
			PackedStringArray(["game (Track 1).bin", "game.cue"]), exts),
		"game.cue", "entries/a cue is preferred over the bin beside it")
	_eq(RomCompat._choose_entry(PackedStringArray(["game.bin"]), exts),
		"game.bin", "entries/a lone bin is still launchable")

	# LAUNCH_PRIORITY order, best first: m3u beats cue because a multi-disc game
	# has to arrive as the whole set rather than as disc one.
	_eq(RomCompat._choose_entry(
			PackedStringArray(["d.cue", "all.m3u"]), ["m3u", "cue"] as Array[String]),
		"all.m3u", "entries/an m3u outranks a cue")

	# Nothing the core declares is nothing to launch, even in a full archive.
	_eq(RomCompat._choose_entry(
			PackedStringArray(["readme.txt", "cover.png"]), exts),
		"", "entries/an archive with nothing loadable chooses nothing")

	# The safety filter. A poisoned first entry used to be picked as the launch
	# target and then refused on the way out, failing an archive that held a
	# perfectly good ROM.
	_ok(not RomCompat._is_safe_entry("../escape.cue"), "entries/a parent segment is unsafe")
	_ok(not RomCompat._is_safe_entry("/abs/path.cue"), "entries/an absolute name is unsafe")
	_ok(not RomCompat._is_safe_entry("__MACOSX/._game.cue"),
		"entries/the macOS resource fork is skipped")
	_ok(not RomCompat._is_safe_entry("sub/.hidden.cue"), "entries/a dotfile is skipped")
	_ok(not RomCompat._is_safe_entry("folder/"), "entries/a directory is not an entry")
	_ok(RomCompat._is_safe_entry("sub/game.cue"), "entries/an ordinary nested name is fine")
	_eq(RomCompat._choose_entry(
			PackedStringArray(["../evil.cue", "good.cue"]), exts),
		"good.cue", "entries/an unsafe name is never the launch target")

	# What was actually in there, for a message that says so.
	var listed := RomCompat._distinct_extensions(
		PackedStringArray(["a.bin", "b.BIN", "c.txt", "../d.iso", "e"]))
	_ok(listed.has("bin") and listed.has("txt"), "entries/extensions are collected")
	_ok(not listed.has("iso"), "entries/an unsafe entry contributes no extension")
	_eq(listed.count("bin"), 1, "entries/case does not duplicate an extension")


# ── wording/ ──────────────────────────────────────────────────────────────────

## The sentence a player reads is the only explanation they get.
func _group_wording() -> void:
	_eq(RomCompat._ext_list([] as Array[String]), "nothing",
		"wording/no extensions reads as nothing")
	_eq(RomCompat._ext_list(["lnx"] as Array[String]), ".lnx",
		"wording/one extension needs no list")
	_eq(RomCompat._ext_list(["lnx", "o"] as Array[String]), ".lnx or .o",
		"wording/two are joined with or")
	_eq(RomCompat._ext_list(["lnx", "lyx", "o"] as Array[String]), ".lnx, .lyx or .o",
		"wording/three are comma-listed with a final or")


# ── verdict/ ──────────────────────────────────────────────────────────────────

## evaluate() with no core name and no .info: the no-opinion path. A core we know
## nothing about must be let through rather than refused, or a freshly downloaded
## core would be unable to load anything.
func _group_verdict() -> void:
	var unknown := RomCompat.evaluate("/roms/nes/game.nes", "no_such_core_xyz")
	_eq(unknown["verdict"], RomCompat.Verdict.UNKNOWN,
		"verdict/a core with no .info gets no opinion")
	_eq(unknown["path"], "/roms/nes/game.nes", "verdict/and the path is untouched")

	_eq(RomCompat.evaluate("", "fceumm")["verdict"], RomCompat.Verdict.UNKNOWN,
		"verdict/an empty path is judged as unknown")
	_eq(RomCompat.evaluate("/roms/g.nes", "")["verdict"], RomCompat.Verdict.UNKNOWN,
		"verdict/an empty core name is judged as unknown")

	# Every returned shape carries the four keys, because callers read them
	# unconditionally.
	for key: String in ["verdict", "path", "entry", "message"]:
		_ok(unknown.has(key), "verdict/the result always carries '%s'" % key)

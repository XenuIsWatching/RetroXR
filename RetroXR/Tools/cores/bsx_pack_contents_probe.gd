## BS-X memory pack contents probe — what is actually written on each pack.
##
## A probe rather than a test: it reads the player's real satellaview folder, and
## the interesting case (a pack with TWO programmes on it) only exists once
## someone has downloaded twice onto one pack. With no packs present it SKIPs.
##
## What it is guarding. A pack is a medium holding up to eight blocks' worth of
## programmes, and BsxPack answered for block 0 alone until this was measured, so
## a second download was invisible everywhere in the room. The numbers asserted
## below are the ones read off a real pack:
##
##   blk0 Hi @0x00FFC0  alloc=0x0F  blocks 0-3  "BS SUPERCOOKED"
##   blk4 Hi @0x08FFC0  alloc=0xF0  blocks 4-7  "12/21虎ﾏｶﾞ大作戦"
##
## Run: godot --headless --path RetroXR res://Tools/cores/bsx_pack_contents_probe.tscn
extends Node

var _fails := 0
var _checks := 0


func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		print("[pack] TIMEOUT")
		get_tree().quit(1))
	var dir := RomLibrary.rom_dir_for_system("satellaview")
	print("[pack] dir = %s" % dir)
	var d := DirAccess.open(dir)
	if d == null:
		print("[pack] SKIP: no satellaview folder")
		get_tree().quit(0)
		return

	var packs: Array[String] = []
	for f: String in d.get_files():
		if BsxPack.is_pack_path(f):
			packs.append(dir.path_join(f))
	packs.sort()
	if packs.is_empty():
		print("[pack] SKIP: no .bs packs present")
		get_tree().quit(0)
		return

	for p: String in packs:
		_report(p)

	# Invariants that must hold for EVERY pack, whatever is on it. These are the
	# ones worth failing on: the specific titles above depend on what the player
	# happened to download, but these do not.
	for p: String in packs:
		var progs := BsxPack.programmes_of_file(p)
		var data := FileAccess.get_file_as_bytes(p)
		_check(p, "programmes_of == programmes_of_file",
			BsxPack.programmes_of(data).size() == progs.size())
		_check(p, "at most one programme per block", progs.size() <= BsxPack.BLOCK_COUNT)
		var seen := 0
		var overlap := false
		for prog: Dictionary in progs:
			for b: int in prog["blocks"]:
				if seen & (1 << b):
					overlap = true
				seen |= 1 << b
		_check(p, "no two programmes claim one block", not overlap)
		var free_n: int = BsxPack.free_blocks(data)
		_check(p, "free is within the pack", free_n >= 0 and free_n <= BsxPack.BLOCK_COUNT)
		# A pack with nothing written on it has all of itself left. It reported 0
		# free before the placeholder was excluded, because a blank is minted with
		# every allocation bit set — so the panel called an empty pack full.
		if BsxPack.programme_titles(p).is_empty():
			_check(p, "an empty pack is entirely free", free_n == BsxPack.BLOCK_COUNT)
		# A pack that holds something must not be called empty, and one that holds
		# nothing must not be called after the placeholder a blank is minted with.
		var label := BsxPack.display_name(p)
		var titles := BsxPack.programme_titles(p)
		if titles.is_empty():
			_check(p, "empty pack reads as empty", label == BsxPack.EMPTY_LABEL)
		else:
			_check(p, "label names every programme",
				label == BsxPack.LABEL_JOIN.join(titles))
			_check(p, "label names as many as are on it",
				label.count(BsxPack.LABEL_JOIN) == titles.size() - 1)

	# A freshly minted blank, in memory. The player's folder may hold no empty
	# pack — and the empty case is the one that was wrong — so it is built here
	# rather than waited for.
	var blank := BsxPack.blank_image()
	_check("<blank>", "a blank is a pack", BsxPack.is_pack_image(blank))
	_check("<blank>", "a blank has all %d blocks free" % BsxPack.BLOCK_COUNT,
		BsxPack.free_blocks(blank) == BsxPack.BLOCK_COUNT)
	_check("<blank>", "a blank lists no programme",
		BsxPackFormat.new().list_saves(blank, false).is_empty())
	_check("<blank>", "a blank's placeholder is not a title",
		BsxPack.programmes_of(blank).size() == 1)

	print("[pack] %d checks, %s" % [_checks, "ALL PASS" if _fails == 0 else "%d FAILED" % _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _report(path: String) -> void:
	var progs := BsxPack.programmes_of_file(path)
	var data := FileAccess.get_file_as_bytes(path)
	print("[pack] %s" % path.get_file())
	print("[pack]   label     = \"%s\"" % BsxPack.display_name(path))
	print("[pack]   own pack  = %s" % BsxPack.is_own_pack_path(path))
	print("[pack]   free      = %d of %d blocks" % [BsxPack.free_blocks(data), BsxPack.BLOCK_COUNT])
	for p: Dictionary in progs:
		print("[pack]   blk%d %s @0x%06X blocks=%s title=\"%s\"" % [
			p["block"], "Lo" if p["lorom"] else "Hi", p["offset"],
			str(p["blocks"]), p["title"]])


func _check(path: String, what: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("[pack] FAIL %s: %s" % [path.get_file(), what])

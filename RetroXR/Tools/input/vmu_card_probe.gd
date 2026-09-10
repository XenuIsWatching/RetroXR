## VMU card probe — VMUCard against REAL files, which the suite cannot use.
##
## `card_tests` builds its fixtures rather than loading them, because this repo
## has no right to redistribute anybody's saves. That is the right call, and it
## leaves one gap: a generated fixture only proves the parser agrees with the
## generator. This probe closes it, against files you already have.
##
##     "$godot" --headless --path RetroXR res://Tools/input/vmu_card_probe.tscn -- \
##         --card="$HOME/retroxr/libretro/system/flycast/dc/vmu_save_A1.bin" \
##         --dci=/path/to/Something.dci --vms=/path/to/Something.vms
##
## Every argument is optional and each drives an independent check:
##
##   --card  a real VMU image. Its SYSTEM blocks (241-255) must match the blank
##           this code formats, byte for byte. That single comparison covers the
##           root signature, the whole geometry table, both FAT sentinels and the
##           directory chain at once — which is how the sentinels were settled in
##           the first place. The user area is deliberately NOT compared: a real
##           card keeps bytes from deleted saves.
##   --dci   a save lifted off a card. It must be recognised, insert into a blank,
##           list with its own title, and lift back off byte for byte.
##   --vms   the same save's raw body. Un-swapping the .dci payload must
##           reproduce it exactly — an independent oracle that no word-swap,
##           header-offset or type-byte bug survives.
##
## Exits non-zero if a check that was asked for fails.
extends Node

var _card_path := ""
var _dci_path := ""
var _vms_path := ""
var _fail := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--card="):
			_card_path = s.substr("--card=".length())
		elif s.begins_with("--dci="):
			_dci_path = s.substr("--dci=".length())
		elif s.begins_with("--vms="):
			_vms_path = s.substr("--vms=".length())
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))

	if _card_path.is_empty() and _dci_path.is_empty():
		print("[probe] nothing to check - pass --card= and/or --dci= (see the header)")
		get_tree().quit(0)
		return

	_check_card()
	_check_save()

	print("[probe] ---- %s ----" % ("all checks passed" if _fail == 0 else "%d FAILED" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if not cond:
		_fail += 1
	print("[probe] %s  %s%s" % ["PASS" if cond else "FAIL", what,
		"" if detail.is_empty() else "  - " + detail])


func _read(path: String) -> PackedByteArray:
	if path.is_empty():
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("[probe] cannot read %s" % path)
		return PackedByteArray()
	var b: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	return b


## A real card's system blocks against the blank this code formats.
func _check_card() -> void:
	var real := _read(_card_path)
	if real.is_empty():
		return
	_ok(VMUCard.is_card_image(real), "a real card parses as a card")
	if not VMUCard.is_card_image(real):
		return

	var blank := VMUCard.blank_image()
	var diffs := 0
	var first := -1
	for b in range(VMUCard.DIR_BLOCK - VMUCard.DIR_BLOCKS + 1, VMUCard.BLOCK_COUNT):
		for i in range(VMUCard.BLOCK_SIZE):
			var at := b * VMUCard.BLOCK_SIZE + i
			if blank[at] != real[at]:
				diffs += 1
				if first < 0:
					first = at
	var detail := ""
	if first >= 0:
		@warning_ignore("integer_division")
		var blk: int = first / VMUCard.BLOCK_SIZE
		detail = "%d bytes differ, first at block %d +0x%X (ours %02X, card %02X)" % [
			diffs, blk, first % VMUCard.BLOCK_SIZE, blank[first], real[first]]
	_ok(diffs == 0, "our blank matches it across the system blocks 241-255", detail)

	var saves := VMUCard.list_saves(real, false)
	print("[probe] it holds %d save(s), %d of 200 blocks free"
		% [saves.size(), VMUCard.free_blocks(real)])
	for s in saves:
		print("[probe]   %-12s %-16s %3d blocks  %s"
			% [s["name"], s["title"], s["blocks"], "game" if s["is_game"] else "data"])


## A real save, through the whole insert / list / lift-off path.
func _check_save() -> void:
	var dci := _read(_dci_path)
	if dci.is_empty():
		return
	_ok(VMUCard.is_dci(dci), "a real .dci is recognised")
	if not VMUCard.is_dci(dci):
		return

	# The independent oracle: the .dci payload un-swapped IS the .vms.
	var vms := _read(_vms_path)
	if not vms.is_empty():
		_ok(VMUCard._word_swap(dci.slice(VMUCard.DCI_HEADER)) == vms,
			"un-swapping its payload reproduces the .vms byte for byte")

	var card := VMUCard.insert_save(VMUCard.blank_image(), dci)
	_ok(not card.is_empty(), "it inserts into a blank card")
	if card.is_empty():
		return

	var saves := VMUCard.list_saves(card, true)
	_ok(saves.size() == 1, "and lists once")
	if saves.is_empty():
		return
	var s: Dictionary = saves[0]
	print("[probe] read back: name=%s title=%s blocks=%d %s icons=%d"
		% [s["name"], s["title"], s["blocks"],
			"game" if s["is_game"] else "data", (s["icons"] as Array).size()])
	_ok(not str(s["title"]).is_empty(), "with a title decoded from its header")
	_ok((s["icons"] as Array).size() > 0, "and at least one icon frame")

	_ok(VMUCard.extract_save(card, int(s["block"])) == dci,
		"and lifts back off byte for byte")

	var gone := VMUCard.delete_save(card, int(s["block"]))
	_ok(VMUCard.free_blocks(gone) == VMUCard.USER_BLOCKS,
		"deleting it returns every block")

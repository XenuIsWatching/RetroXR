## memcard2_probe — does a PlayStation's SECOND memory card slot reach the core?
##
## A probe, not a test: it wants pcsx_rearmed and a real disc.
##
## The oracle is the SIZE the core reports for each slot's region, and it cannot
## pass by accident. Slot 1 is RETRO_MEMORY_SAVE_RAM and has always answered;
## slot 2 is a memory id of the core's own, so a core built without it answers 0
## and the run says so. Both legs are worth running:
##
##   --leg=patched   both cards mount, both regions 131072 bytes
##   --leg=stock     with a core that has no second region, slot 2 reports none
##
## The extension publishes no log signal, so the branch is asserted by the CALLER
## grepping the run for the SRAM B lines — the same arrangement sufficient for
## sufami_probe.
##
##   "$godot" --headless --path RetroXR res://Tools/cores/memcard2_probe.tscn -- \
##     --core=pcsx_rearmed "--rom=$HOME/retroxr/roms/playstation/<disc>.cue"
extends Node

const FRAMES := 240

var _sys: RetroSystem = null
var _card_a: Node3D = null
var _card_b: Node3D = null


func _ready() -> void:
	# A probe must never hang a run.
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		_say("TIMEOUT")
		get_tree().quit(1))
	_run.call_deferred()


func _say(msg: String) -> void:
	print("[memcard2] ", msg)


func _arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.split("=", true, 1)[1]
	return fallback


func _run() -> void:
	var core := _arg("core", "pcsx_rearmed")
	var rom := _arg("rom", "")
	if rom.is_empty() or not FileAccess.file_exists(rom):
		_say("FAIL no disc — pass --rom=<.cue>")
		get_tree().quit(1)
		return

	_sys = preload("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	_sys.systemid = "playstation"
	add_child(_sys)
	await get_tree().process_frame

	_say("slots=%d family=%s" % [_sys.card_slot_count(), _sys.card_family()])
	if _sys.card_slot_count() < 2:
		_say("FAIL the console reports fewer than two slots")
		get_tree().quit(1)
		return

	# Two cards with DIFFERENT ids, so the two images cannot be the same file —
	# which is the failure this probe exists to catch.
	_card_a = _make_card("PROBE CARD A")
	_card_b = _make_card("PROBE CARD B")
	_sys._memcards._snapped_memcards[0] = _card_a
	_sys._memcards._snapped_memcards[1] = _card_b

	var opts := _sys._removable_media_options(core)
	_say("memcard1=%s/%s memcard2=%s/%s" % [
		opts.get("pcsx_rearmed_memcard1", "?"),
		opts.get("pcsx_rearmed_memcard1_inserted", "?"),
		opts.get("pcsx_rearmed_memcard2", "?"),
		opts.get("pcsx_rearmed_memcard2_inserted", "?")])

	var path_a := SramPaths.card_save_path("playstation", str(_card_a.card_id))
	var path_b := SramPaths.card_save_path("playstation", str(_card_b.card_id))
	if path_a == path_b:
		_say("FAIL both slots resolved to one file: %s" % path_a)
		_finish(1)
		return
	_say("slot1 -> %s" % path_a)
	_say("slot2 -> %s" % path_b)

	_sys.rom_path = rom
	_sys.power_on()
	var frames := 0
	while frames < FRAMES:
		await get_tree().process_frame
		frames += 1
	var ident: Dictionary = _sys.get_libretro_node().GetCoreIdentity()
	_say("identity=%s %s" % [ident.get("library_name", "?"),
		ident.get("library_version", "?")])
	if ident.is_empty():
		_say("FAIL core never came up")
		_finish(1)
		return

	# Deliberately NOT asserted on: both images exist either way. The frontend
	# formats a blank card for a slot as it mounts it, so a file appears for
	# slot 2 even against a core that never took it — measured, and it is the
	# check that looked green in both legs.
	_sys.get_libretro_node().RequestSramFlush()
	for i in 60:
		await get_tree().process_frame
	_say("grep the run for the SRAM B line: 'watching 131072 bytes' is the pass,")
	_say("'core reports no second region' is a core without slot 2")
	_finish(0)


func _make_card(label: String) -> Node3D:
	var card: Node3D = preload("res://Scenes/Objects/media/memory_card.tscn").instantiate()
	card.card_label = label
	add_child(card)
	return card


func _finish(code: int) -> void:
	if _sys != null and _sys.is_powered_on:
		_sys.power_off()
		for i in 30:
			await get_tree().process_frame
	# The cards this run minted are the player's files, in the player's folder.
	# Take them away again, or a shelf of PROBE CARD A 2, A 3, A 4 accumulates.
	for card in [_card_a, _card_b]:
		if card == null:
			continue
		var path := SramPaths.card_save_path("playstation", str(card.card_id))
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_say("done")
	get_tree().quit(code)

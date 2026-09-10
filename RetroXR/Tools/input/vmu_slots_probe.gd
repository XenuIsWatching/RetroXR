## VMU slots probe — do a Dreamcast pad's two slots appear, and take a card?
##
## The slots are BUILT rather than authored: the Dreamcast has no controller
## scene, so VmuPort creates them when a pad is plugged into one and removes them
## when it is unplugged. That makes "are they there" a runtime question rather
## than something a scene file can be read for, which is what this answers.
##
##     "$godot" --headless --path RetroXR res://Tools/input/vmu_slots_probe.tscn
##
## No core, no ROM, no headset. It builds a Dreamcast and a NES, plugs the same
## kind of pad into each, and checks that only the Dreamcast grows slots — a pad
## that carried another console's sockets around would be the obvious bug.
##
## Exits non-zero on failure.
extends Node

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const PAD_SCENE := preload("res://Scenes/Objects/controllers/retro_controller.tscn")
const VMU_SCENE := preload("res://Scenes/Objects/controllers/dreamcast/vmu_card.tscn")

var _fail := 0


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	await _run()
	print("[probe] ---- %s ----" % ("all checks passed" if _fail == 0 else "%d FAILED" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if not cond:
		_fail += 1
	print("[probe] %s  %s%s" % ["PASS" if cond else "FAIL", what,
		"" if detail.is_empty() else "  - " + detail])


func _make_system(systemid: String) -> RetroSystem:
	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = systemid
	add_child(sys)
	return sys


func _run() -> void:
	var dc := _make_system("dreamcast")
	var nes := _make_system("nes")
	var pad_dc := PAD_SCENE.instantiate() as RetroController
	var pad_nes := PAD_SCENE.instantiate() as RetroController
	add_child(pad_dc)
	add_child(pad_nes)
	for i in range(4):
		await get_tree().process_frame

	_ok(pad_dc.vmu_slot_count() == 0, "a loose pad has no VMU slots")

	pad_dc.on_plugged_in(dc, 0)
	pad_nes.on_plugged_in(nes, 0)
	await get_tree().process_frame

	_ok(pad_dc.vmu_slot_count() == 2, "a pad on a Dreamcast grows two",
		"got %d" % pad_dc.vmu_slot_count())
	_ok(pad_nes.vmu_slot_count() == 0, "a pad on a NES grows none",
		"got %d" % pad_nes.vmu_slot_count())
	_ok(pad_dc.get_node_or_null("VmuSlot1") != null, "slot 1 exists by name")
	_ok(pad_dc.get_node_or_null("VmuSlot2") != null, "slot 2 exists by name")

	# An empty slot must say "None" and not "" — "" means the pad has no slot at
	# all, and answering it for an empty one would leave flycast's default VMU
	# fitted to a slot the player just emptied.
	_ok(pad_dc.vmu_slot_option_value(0) == "None", "an empty slot reads None",
		pad_dc.vmu_slot_option_value(0))
	_ok(pad_nes.vmu_slot_option_value(0) == "", "a pad with no slots reads empty",
		"'%s'" % pad_nes.vmu_slot_option_value(0))

	# Seat one.
	var card := VMU_SCENE.instantiate() as VmuCard
	add_child(card)
	await get_tree().process_frame
	pad_dc.restore_vmu(card, 0)
	await get_tree().process_frame
	await get_tree().process_frame

	_ok(pad_dc.get_vmu(0) == card, "a VMU seats in slot 1")
	_ok(pad_dc.vmu_slot_option_value(0) == "VMU", "and the slot then reads VMU",
		pad_dc.vmu_slot_option_value(0))
	_ok(pad_dc.get_vmu(1) == null, "slot 2 is still empty")
	_ok(pad_dc.vmu_slot_option_value(1) == "None", "and still reads None")

	# Unplugging the pad takes its sockets with it, so a pad moved to another
	# console does not carry a Dreamcast's slots around.
	pad_dc.on_unplugged()
	await get_tree().process_frame
	_ok(pad_dc.vmu_slot_count() == 0, "unplugging removes the slots",
		"got %d" % pad_dc.vmu_slot_count())
	_ok(pad_dc.get_node_or_null("VmuSlot1") == null, "and the nodes with them")

	# Where the storage layer would put this card's bytes, and what flycast reads.
	print("[probe] card image  : %s" % card.image_path())
	print("[probe] core file A1: %s"
		% VmuStorage.core_vmu_path("<root>", "flycast", 0, 0))
	print("[probe] core file B2: %s"
		% VmuStorage.core_vmu_path("<root>", "flycast", 1, 1))

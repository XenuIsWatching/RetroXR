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
## A PAD RECEIVER is driven through the same route, because the player using a
## real gamepad holds no virtual pad and reaches a card only through the dongle.
## Its seat is authored in its scene rather than built from VmuPort's constants,
## so the probe reads the seated card's BASIS back as well as counting sockets:
## a .tscn transform is written by rows and constructed by columns, and a card
## seated upside down would still count as one card.
##
## Exits non-zero on failure.
extends Node

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const PAD_SCENE := preload("res://Scenes/Objects/controllers/retro_controller.tscn")
const DONGLE_SCENE := preload("res://Scenes/Objects/controllers/pad_receiver.tscn")
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

	# --- The dongle ---------------------------------------------------------
	#
	# Same rules, different host: a seat authored in a scene rather than one of
	# VmuPort's constants, and one slot rather than two because a 47 mm card does
	# not go twice across a 70 mm case.
	var rx_dc := DONGLE_SCENE.instantiate() as PadReceiver
	var rx_nes := DONGLE_SCENE.instantiate() as PadReceiver
	add_child(rx_dc)
	add_child(rx_nes)
	# A RigidBody with no floor falls, and every measurement below is taken in the
	# dongle's own frame anyway -- but a still bench is one less thing to explain.
	rx_dc.freeze = true
	rx_nes.freeze = true
	for i in range(4):
		await get_tree().process_frame

	_ok(rx_dc.vmu_slot_count() == 0, "a loose dongle has no VMU slot")
	rx_dc.on_plugged_in(dc, 1)
	rx_nes.on_plugged_in(nes, 1)
	await get_tree().process_frame
	_ok(rx_dc.vmu_slot_count() == 1, "a dongle on a Dreamcast grows one",
		"got %d" % rx_dc.vmu_slot_count())
	_ok(rx_nes.vmu_slot_count() == 0, "a dongle on a NES grows none",
		"got %d" % rx_nes.vmu_slot_count())
	_ok(rx_dc.vmu_slot_option_value(0) == "None", "its empty slot reads None",
		rx_dc.vmu_slot_option_value(0))
	# There is no slot 2, which is not the same as an empty one: "" is what tells
	# flycast to leave its own default alone rather than pulling a card out.
	_ok(rx_dc.vmu_slot_option_value(1) == "", "and it has no slot 2 at all",
		"'%s'" % rx_dc.vmu_slot_option_value(1))

	var rx_card := VMU_SCENE.instantiate() as VmuCard
	add_child(rx_card)
	await get_tree().process_frame
	rx_dc.restore_vmu(rx_card, 0)
	for i in range(3):
		await get_tree().process_frame
	_ok(rx_dc.get_vmu(0) == rx_card, "a VMU seats in the dongle")
	_ok(rx_dc.vmu_slot_option_value(0) == "VMU", "and the slot then reads VMU",
		rx_dc.vmu_slot_option_value(0))

	# Which way up it went in. The card's +Y is its connector and its +Z is the
	# screen; seated, the connector must point DOWN into the boss and the screen
	# must face the dongle's front, the face with the LED and the name on it.
	# Counting sockets cannot tell an upside-down card from a right way up one.
	# Read in the DONGLE's frame, so a bench that lets the body move measures the
	# same thing a bolted-down one would.
	var rel := rx_dc.global_transform.affine_inverse() * rx_card.global_transform
	print("[probe] seated card basis y=%s z=%s"
		% [str(rel.basis.y.snappedf(0.001)), str(rel.basis.z.snappedf(0.001))])
	_ok(rel.basis.y.dot(Vector3.DOWN) > 0.99, "with its connector pointing into the boss",
		"y=%s" % str(rel.basis.y.snappedf(0.001)))
	_ok(rel.basis.z.dot(Vector3.FORWARD) > 0.99, "and its screen facing the dongle's front",
		"z=%s" % str(rel.basis.z.snappedf(0.001)))
	# And how deep. The end of the card that carries the connector has to finish
	# INSIDE the boss -- below its 40 mm lid, above the 20 mm case top -- or the
	# card is either perched on the lid or swallowed. "It is in the slot" cannot
	# tell those apart; the card counts as seated in all three.
	var tip: Vector3 = rel * Vector3(0, 0.040, 0)
	_ok(tip.y > 0.020 and tip.y < 0.040, "up to its connector in the boss",
		"card ends at y=%.1f mm, boss is 20.0..40.0" % (tip.y * 1000.0))

	rx_dc.on_unplugged()
	await get_tree().process_frame
	_ok(rx_dc.vmu_slot_count() == 0, "unplugging the dongle removes its slot",
		"got %d" % rx_dc.vmu_slot_count())

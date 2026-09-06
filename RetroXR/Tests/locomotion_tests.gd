## locomotion_tests — who is allowed to stop the player walking, and when they
## get it back.
##
## LocomotionManager gates the two thumbsticks and the desktop movers behind a
## set of BLOCKS, and a block is held under an owner KEY. Everything here turns
## on one property of that design: a block is stored and erased by key, so two
## holders that pick the same key are one holder as far as this class is
## concerned. Put one down and the other's claim goes with it.
##
## That is not hypothetical. HandheldInput blocked under the literal
## &"handheld_hold" while every sibling derived a per-instance key from
## VrHold — and a room can hold several handhelds, which is the whole premise
## of a link cable. Setting one down freed the hand still holding the other.
##
## The failure is also the worst shape a bug can have here: the player is
## standing in a headset, holding something, and the floor stops responding —
## or starts responding while they hold something that should have pinned them.
## There is nothing on screen to say why, and no log line either.
##
##   "$godot" --headless --path RetroXR res://Tests/locomotion_tests.tscn
extends Node

var _passed := 0
var _failed := 0


func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		push_error("[locomotion] TIMEOUT")
		get_tree().quit(1))

	_group_blocks()
	_group_owner_keys()

	print("[locomotion] %d checks, %d failed" % [_passed + _failed, _failed])
	print("[locomotion] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if cond:
		_passed += 1
		print("[locomotion] ok   %s" % what)
	else:
		_failed += 1
		print("[locomotion] FAIL %s%s" % [what, "" if detail.is_empty() else "  -- " + detail])


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what, "got %s, want %s" % [got, want])


## A manager with no providers wired. _apply() walks null members and is a no-op,
## which is what lets the block bookkeeping be tested without an XR rig.
func _manager() -> LocomotionManager:
	var m := LocomotionManager.new()
	add_child(m)
	return m


# ── blocks/ ───────────────────────────────────────────────────────────────────

func _group_blocks() -> void:
	var m := _manager()

	_ok(not m.is_blocked(LocomotionManager.CHANNEL_LEFT), "blocks/nothing blocks a fresh manager")

	m.set_block(&"a", LocomotionManager.CHANNEL_LEFT, true)
	_ok(m.is_blocked(LocomotionManager.CHANNEL_LEFT), "blocks/one owner blocks its channel")
	_ok(not m.is_blocked(LocomotionManager.CHANNEL_RIGHT),
		"blocks/and only its channel")

	# THE case. Two holders, one hand each on the same channel: the second
	# releasing must not free a channel the first is still holding.
	m.set_block(&"b", LocomotionManager.CHANNEL_LEFT, true)
	m.set_block(&"b", LocomotionManager.CHANNEL_LEFT, false)
	_ok(m.is_blocked(LocomotionManager.CHANNEL_LEFT),
		"blocks/one owner releasing leaves another owner's block standing")

	m.set_block(&"a", LocomotionManager.CHANNEL_LEFT, false)
	_ok(not m.is_blocked(LocomotionManager.CHANNEL_LEFT),
		"blocks/the last owner releasing frees the channel")

	# Setting the same block twice must not need two releases: the pickup path
	# calls _update_locomotion_block on every state change, not only on changes.
	m.set_block(&"a", LocomotionManager.CHANNEL_RIGHT, true)
	m.set_block(&"a", LocomotionManager.CHANNEL_RIGHT, true)
	m.set_block(&"a", LocomotionManager.CHANNEL_RIGHT, false)
	_ok(not m.is_blocked(LocomotionManager.CHANNEL_RIGHT),
		"blocks/blocking twice still takes one release")

	# CHANNEL_ALL is both sticks, not a third set.
	m.set_block(&"c", LocomotionManager.CHANNEL_ALL, true)
	_ok(m.is_blocked(LocomotionManager.CHANNEL_LEFT)
		and m.is_blocked(LocomotionManager.CHANNEL_RIGHT),
		"blocks/ALL takes both sticks")
	_ok(m.is_blocked(LocomotionManager.CHANNEL_ALL), "blocks/and reads back as blocked")
	m.set_block(&"c", LocomotionManager.CHANNEL_ALL, false)
	_ok(not m.is_blocked(LocomotionManager.CHANNEL_ALL), "blocks/ALL releases both")

	# The desktop channel is its own: a hand block must not gate WASD, and a
	# desktop block must not gate a stick.
	m.set_block(&"d", LocomotionManager.CHANNEL_LEFT, true)
	_ok(not m.is_blocked(LocomotionManager.CHANNEL_DESKTOP_MOVE),
		"blocks/a hand block does not stop the keyboard")
	m.set_block(&"d", LocomotionManager.CHANNEL_LEFT, false)
	m.set_block(&"d", LocomotionManager.CHANNEL_DESKTOP_MOVE, true)
	_ok(not m.is_blocked(LocomotionManager.CHANNEL_ALL),
		"blocks/a desktop block does not stop the sticks")

	# clear_owner is the teardown path: an object freed mid-hold never reaches
	# its own release, and a block left behind is a hand that never walks again.
	m.set_block(&"d", LocomotionManager.CHANNEL_ALL, true)
	m.set_block(&"e", LocomotionManager.CHANNEL_LEFT, true)
	m.clear_owner(&"d")
	_ok(not m.is_blocked(LocomotionManager.CHANNEL_RIGHT),
		"blocks/clear_owner drops that owner on every channel")
	_ok(not m.is_blocked(LocomotionManager.CHANNEL_DESKTOP_MOVE),
		"blocks/including the desktop one")
	_ok(m.is_blocked(LocomotionManager.CHANNEL_LEFT),
		"blocks/clear_owner leaves every other owner alone")

	m.clear_owner(&"e")
	m.clear_owner(&"e")
	_ok(not m.is_blocked(LocomotionManager.CHANNEL_ALL),
		"blocks/clearing an owner twice is harmless")

	# An unknown channel warns and changes nothing rather than blocking a
	# channel the caller did not name.
	m.set_block(&"f", &"not_a_channel", true)
	_ok(not m.is_blocked(LocomotionManager.CHANNEL_ALL),
		"blocks/an unknown channel blocks nothing")
	_ok(not m.is_blocked(&"not_a_channel"), "blocks/and never reads back as blocked")

	m.queue_free()


# ── owners/ ───────────────────────────────────────────────────────────────────

## The keys themselves, which is where the handheld bug actually lived.
func _group_owner_keys() -> void:
	var a := Node.new()
	var b := Node.new()
	add_child(a)
	add_child(b)

	_ok(VrHold.vr_block_owner(a) != VrHold.vr_block_owner(b),
		"owners/two objects never share a VR key")
	_eq(VrHold.vr_block_owner(a), VrHold.vr_block_owner(a),
		"owners/the same object always gets the same key")
	_ok(VrHold.vr_block_owner(a) != VrHold.desktop_block_owner(a),
		"owners/one object's VR and desktop keys differ")
	# Kept apart so releasing a desktop hold cannot clear a VR block still
	# wanted — the two are taken and given back at different moments.
	_ok(VrHold.desktop_block_owner(a) != VrHold.desktop_block_owner(b),
		"owners/two objects never share a desktop key")

	# The whole point, end to end: two holders of the same KIND, blocking the
	# same hand, are still two owners.
	var m := _manager()
	m.set_block(VrHold.vr_block_owner(a), LocomotionManager.CHANNEL_LEFT, true)
	m.set_block(VrHold.vr_block_owner(b), LocomotionManager.CHANNEL_LEFT, true)
	m.set_block(VrHold.vr_block_owner(b), LocomotionManager.CHANNEL_LEFT, false)
	_ok(m.is_blocked(LocomotionManager.CHANNEL_LEFT),
		"owners/putting one handheld down does not free the hand holding the other")
	m.set_block(VrHold.vr_block_owner(a), LocomotionManager.CHANNEL_LEFT, false)
	_ok(not m.is_blocked(LocomotionManager.CHANNEL_LEFT),
		"owners/putting both down frees the hand")

	m.queue_free()
	a.queue_free()
	b.queue_free()

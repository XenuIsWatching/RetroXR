## VmuPort — the TWO expansion slots on a Dreamcast controller.
##
## Shaped after N64PakPort, and different from it in the one way that matters:
## there are two, and they are not interchangeable.
##
## Researched rather than recalled, because nobody here grew up with the
## hardware. From flycast's own createDreamcastDevices(): the pad is created at
## maple port 5, and its accessories are MapleExpansionDevices[bus][0] -> maple
## port 0 and [bus][1] -> maple port 1. Those are the `..._slot1` and `..._slot2`
## core options, and they map onto the vmu_save_<Port><Slot>.bin filenames — A1
## and A2 for port A. Four pads, two slots each, eight VMUs per console.
##
## **Only the front slot has a window.** The hardware reference is explicit that
## the screen of the VMU in the front slot is what shows through the controller;
## a VMU in slot 2 is buried. flycast reproduces exactly that — its
## `vmu<N>_screen_display` options are indexed per PORT, not per slot, and the
## code gates on MapleExpansionDevices[i][0] alone. So slot 1 lights up, slot 2
## never does, and that is the hardware rather than a shortcut.
##
## Not every Dreamcast peripheral has two: a Light Gun, Twin Stick, Ascii Stick
## and Racing Controller each create only [0]. Hence a slot COUNT rather than an
## assumption of two.
##
## Unlike the N64's, these zones are BUILT rather than authored. The Dreamcast
## has no controller scene — it wears the primitive box, as its console does — so
## there is no shell to hang an authored node off. They appear when the pad is
## plugged into a Dreamcast and go when it is unplugged, which also means a pad
## moved between machines never carries another console's sockets around.
class_name VmuPort
extends RefCounted

const SNAP_ZONE_SCENE := preload("res://addons/godot-xr-tools/objects/snap_zone.tscn")

## Objects in this group, and nothing else, seat here. snap_require alone would
## also take a cable plug, because every ControllerPlug is in the
## "controller_plug" group the zone requires.
const VMU_GROUP := &"vmu"

## The console whose pads have these.
const HOST_SYSTEMID := "dreamcast"

## How many slots a standard Dreamcast pad has.
const SLOTS := 2

## Where the two sockets sit on the primitive pad, in its local space.
##
## PLACEHOLDER GEOMETRY, and deliberately labelled as such. The Dreamcast wears
## the primitive box (152 x 26 x 64 mm), so there is no measured shell to seat
## these against and their position is a design choice rather than a fidelity
## claim. A VMU is 80 mm long, so it stands proud of a 26 mm pad whatever is
## done — which is also true of the real thing. If a Dreamcast pad shell is ever
## authored, measure the seats then and move these onto authored markers.
const SLOT_POSITIONS := [
	Vector3(-0.030, 0.023, -0.005),
	Vector3(0.030, 0.023, -0.005),
]

const GRAB_DISTANCE := 0.05

var _owner: Node = null
var _on_change: Callable = Callable()
var _zones: Array[XRToolsSnapZone] = []
var _cards: Array = [null, null]


## Bind to a host. No sockets exist yet — they appear when the host is plugged
## into a Dreamcast, see sync_to_system().
func attach(owner: Node, on_change: Callable = Callable()) -> void:
	_owner = owner
	_on_change = on_change


## Build the sockets when this pad is on a Dreamcast, tear them down otherwise.
## Called on plug-in and unplug, and idempotent either way.
func sync_to_system(system: Node) -> void:
	var wanted := is_instance_valid(system) \
		and str(system.get("systemid")) == HOST_SYSTEMID
	if wanted == has_ports():
		return
	if wanted:
		_build()
	else:
		_teardown()


func has_ports() -> bool:
	return not _zones.is_empty()


func slot_count() -> int:
	return _zones.size()


func _build() -> void:
	if _owner == null or not is_instance_valid(_owner):
		return
	for slot in range(SLOTS):
		var zone := SNAP_ZONE_SCENE.instantiate() as XRToolsSnapZone
		zone.name = "VmuSlot%d" % (slot + 1)
		zone.snap_require = "controller_plug"
		zone.snap_filter = _accepts
		zone.grab_distance = GRAB_DISTANCE
		_owner.add_child(zone)
		(zone as Node3D).position = SLOT_POSITIONS[slot]
		zone.has_picked_up.connect(_on_seated.bind(slot))
		zone.has_dropped.connect(_on_removed.bind(slot))
		_zones.append(zone)
	_cards = [null, null]


func _teardown() -> void:
	for zone in _zones:
		if is_instance_valid(zone):
			if zone.has_snapped_object():
				zone.drop_object()
			zone.queue_free()
	_zones.clear()
	_cards = [null, null]


## The systemid sentinel is what narrows a socket that would otherwise take any
## cable plug in the room to this one object.
func _accepts(obj: Node3D) -> bool:
	return obj != null and obj.is_in_group(VMU_GROUP)


func _on_seated(obj: Node3D, slot: int) -> void:
	if slot < 0 or slot >= _cards.size():
		return
	_cards[slot] = obj as VmuCard
	if _cards[slot] != null and _owner is CollisionObject3D:
		(_owner as CollisionObject3D).add_collision_exception_with(_cards[slot])
	announce()


## has_dropped carries no argument, so this hears that a slot emptied, not what
## left. Which is enough — a slot holds one thing and _cards[slot] is it.
func _on_removed(slot: int) -> void:
	if slot < 0 or slot >= _cards.size():
		return
	if is_instance_valid(_cards[slot]) and _owner is CollisionObject3D:
		(_owner as CollisionObject3D).remove_collision_exception_with(_cards[slot])
	_cards[slot] = null
	announce()


## Tell the machine what is in the slots now.
##
## MEASURED: flycast does not re-create its maple devices when the per-slot
## option changes at runtime, so this cannot take effect on a hand movement. The
## system records it and applies it at the next content start; see
## Tools/cores/vmu_slot_probe for the measurement and why the obvious probe for
## it proves nothing.
func announce(system: Node = null) -> void:
	var sys: Node = system
	if sys == null and _owner != null and _owner.has_method("get_connected_system"):
		sys = _owner.call("get_connected_system")
	if is_instance_valid(sys) and sys.has_method("reapply_vmu"):
		sys.call("reapply_vmu", _owner)
	if _on_change.is_valid():
		_on_change.call()


## The card in one slot, or null.
func get_card(slot: int) -> VmuCard:
	if slot < 0 or slot >= _cards.size():
		return null
	return _cards[slot] if is_instance_valid(_cards[slot]) else null


## Put a card back into a slot after a load.
func restore_card(card: VmuCard, slot: int) -> void:
	if slot < 0 or slot >= _zones.size() or not is_instance_valid(card):
		return
	_zones[slot].pick_up_object(card)


## What flycast's `reicast_device_port<N>_slot<S>` should be set to.
##
## "" means this pad has no slots AT ALL, which is not the same as an empty one:
## flycast fits a VMU to every port's slot 1 by default, and answering "None" for
## a pad that cannot take one would quietly pull out a card the player has been
## saving to. "None" must mean genuinely absent rather than a blank card, or a
## game offers to format something instead of saying no card is present.
func slot_option_value(slot: int) -> String:
	if slot < 0 or slot >= _zones.size():
		return ""
	var card := get_card(slot)
	if card == null:
		return "None"
	return card.slot_option_value()

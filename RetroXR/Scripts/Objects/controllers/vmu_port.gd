## VmuPort — the expansion slots a Dreamcast controller carries.
##
## Shaped after N64PakPort, and different from it in the one way that matters:
## there is more than one, and they are not interchangeable.
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
## Unlike the N64's, these zones are BUILT rather than authored, because the
## Dreamcast has no controller scene — it wears the primitive box, as its console
## does — so there is no shell to hang an authored node off. They appear when the
## host is plugged into a Dreamcast and go when it is unplugged, which also means
## a pad moved between machines never carries another console's sockets around.
##
## A host that DOES have a scene says where its seats are in that scene, as
## "VmuSeat1", "VmuSeat2", ... markers — see authored_seats(). The pad receiver is
## the one such host: a player on a real gamepad holds no virtual pad, so without
## a socket on the dongle a VMU had nowhere to go that player could reach, which
## is the same gap N64PakPort was lifted out of RetroController to close.
class_name VmuPort
extends RefCounted

const SNAP_ZONE_SCENE := preload("res://addons/godot-xr-tools/objects/snap_zone.tscn")

## Objects in this group, and nothing else, seat here. snap_require alone would
## also take a cable plug, because every ControllerPlug is in the
## "controller_plug" group the zone requires.
const VMU_GROUP := &"vmu"

## The console whose pads have these.
const HOST_SYSTEMID := "dreamcast"

## Where the two sockets sit on the primitive pad, in its local space.
##
## A seat is a whole TRANSFORM rather than a position, because the card bakes in
## no insertion offset of its own: its grab point is the identity at the body
## centre, so the seat is the entire seating geometry. The card's axes are +Y the
## 80 mm length with the connector on that end, and +Z the face carrying the
## screen (see vmu_card.tscn).
##
## They go into the pad's TOP EDGE, which is where a Dreamcast's are, and they
## RISE out of it at 30 degrees rather than lying flat. That angle is forced by
## the shell, and both ways of not tilting were tried and measured:
##
##   into the rear face   the shoulders are cylinders of r=5 at y=+7 and the
##                        triggers are 26 mm blocks below them, together filling
##                        x=16..46 on both sides. The clear span between them is
##                        32 mm and a VMU is 47 across, so no card fits through
##                        that row at any depth.
##   flat along the top   clears the shoulders, and then covers the d-pad and the
##                        X and Y buttons instead — the face buttons sit as far
##                        back as z=-23.5 and the card is 80 mm long.
##
## Tilted, the connector end meets the top face at its rear corner and the body
## climbs away behind the pad, over the shoulders and clear of every control. It
## is also what the hardware does: a Dreamcast's cards stand up out of a housing
## above the face rather than lying on it.
##
## The basis is a half turn about the axis between the card's +Y and +Z (which
## sends the connector into the pad and turns the screen upward, flipping X with
## them) and then 30 degrees about the pad's X. The origin follows from the
## connector tip landing at y=+14, z=-30: the centre is 40 mm back along the
## card, which is (0, +20, -34.6) from there.
##
## PLACEHOLDER GEOMETRY all the same, and deliberately labeled as such: the
## Dreamcast wears the primitive box, so there is no measured shell to seat these
## against. If a Dreamcast pad shell is ever authored, measure the seats then and
## author them as markers, the way a host with a scene does below.
const PAD_SEATS: Array[Transform3D] = [
	Transform3D(Vector3(-1, 0, 0), Vector3(0, -0.5, 0.866), Vector3(0, 0.866, 0.5),
		Vector3(-0.0245, 0.034, -0.0646)),
	Transform3D(Vector3(-1, 0, 0), Vector3(0, -0.5, 0.866), Vector3(0, 0.866, 0.5),
		Vector3(0.0245, 0.034, -0.0646)),
]

const GRAB_DISTANCE := 0.05

var _owner: Node = null
var _on_change: Callable = Callable()
var _zones: Array[XRToolsSnapZone] = []
var _seats: Array[Transform3D] = []
var _cards: Array = []


## Bind to a host. No sockets exist yet — they appear when the host is plugged
## into a Dreamcast, see sync_to_system().
func attach(owner: Node, on_change: Callable = Callable()) -> void:
	_owner = owner
	_on_change = on_change
	_seats = authored_seats(owner)
	if _seats.is_empty():
		_seats = PAD_SEATS.duplicate()


## The seats a host's SCENE authors, as "VmuSeat1", "VmuSeat2", ... taken in
## order until one is missing.
##
## The primitive pad has no scene, which is the whole reason PAD_SEATS exists; a
## host that does have one authors its seats there instead, so the numbers sit
## beside the geometry they were measured against rather than in a script that
## cannot see it. The slot COUNT comes from the same place — a pad receiver is
## 70 mm wide and a VMU is 47, so it seats one where a pad seats two, and that is
## a shape this already had to allow for: a Light Gun, Twin Stick, Ascii Stick
## and Racing Controller each create only [0].
static func authored_seats(owner: Node) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	if not is_instance_valid(owner):
		return out
	var seat := owner.get_node_or_null(NodePath("VmuSeat1")) as Node3D
	while seat != null:
		out.append(seat.transform)
		seat = owner.get_node_or_null(
			NodePath("VmuSeat%d" % (out.size() + 1))) as Node3D
	return out


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
	for slot in range(_seats.size()):
		var zone := SNAP_ZONE_SCENE.instantiate() as XRToolsSnapZone
		zone.name = "VmuSlot%d" % (slot + 1)
		zone.snap_require = "controller_plug"
		zone.snap_filter = _accepts
		zone.grab_distance = GRAB_DISTANCE
		_owner.add_child(zone)
		# The whole transform, not the position: a seat says which way up the
		# card goes in as well as where, and a dongle's is a half turn from a
		# pad's.
		(zone as Node3D).transform = _seats[slot]
		zone.has_picked_up.connect(_on_seated.bind(slot))
		zone.has_dropped.connect(_on_removed.bind(slot))
		_zones.append(zone)
	_cards.resize(_seats.size())
	_cards.fill(null)


func _teardown() -> void:
	# Unseat explicitly rather than trusting drop_object's signal to arrive: the
	# zone is freed on the same pass, and a card left thinking it is still seated
	# would keep driving a screen for a machine it is no longer plugged into.
	for card in _cards:
		if is_instance_valid(card):
			card.unseated()
	for zone in _zones:
		if is_instance_valid(zone):
			if zone.has_snapped_object():
				zone.drop_object()
			zone.queue_free()
	_zones.clear()
	_cards.clear()


## The systemid sentinel is what narrows a socket that would otherwise take any
## cable plug in the room to this one object.
func _accepts(obj: Node3D) -> bool:
	return obj != null and obj.is_in_group(VMU_GROUP)


func _on_seated(obj: Node3D, slot: int) -> void:
	if slot < 0 or slot >= _cards.size():
		return
	_cards[slot] = obj as VmuCard
	if _cards[slot] != null:
		if _owner is CollisionObject3D:
			(_owner as CollisionObject3D).add_collision_exception_with(_cards[slot])
		# The card cannot work out which slot took it, or reach the machine on
		# the far side of this pad, so it is told. Only slot 1 drives a screen.
		_cards[slot].seated_in(_owner, slot)
	announce()


## has_dropped carries no argument, so this hears that a slot emptied, not what
## left. Which is enough — a slot holds one thing and _cards[slot] is it.
func _on_removed(slot: int) -> void:
	if slot < 0 or slot >= _cards.size():
		return
	if is_instance_valid(_cards[slot]):
		if _owner is CollisionObject3D:
			(_owner as CollisionObject3D).remove_collision_exception_with(_cards[slot])
		# Back to a dark panel: a card in a hand shows nothing.
		_cards[slot].unseated()
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

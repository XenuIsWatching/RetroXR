## The RXR-003 RF Switch: a lump in the middle of a lead.
##
## A black phono plug on a long lead into the console's RF OUT, a short coax pigtail
## into the set's aerial socket, and a grey box between them wearing an ANT socket of
## its own. It is how an NES was hooked up before anyone had a composite input.
##
## ── Why it IS a CompositeCable ───────────────────────────────────────────────
## Everything about the ROUTING is a lead's. What this carries is decided, as always,
## by the two sockets its ends sit in, so with its plugs named PlugA0 and PlugB0 the
## inherited links() already reports exactly the pair that matters —
## {"out": <console RF OUT>, "in": <the set's aerial socket>, "cord": 0} — because
## _resolve direction-sorts an OUT against an IN and does not care what sits in the
## middle. There is no links() override here, and RetroSystem needs no new code: the
## console resolves this set as its video sink exactly as it would over composite.
##
## The type is also load-bearing three times over, which is the real argument against
## writing a slim sibling that only implements links():
##   * StorageBox._free_lead casts plug.cable to CompositeCable — a sibling is
##     un-binnable, and both of its plugs delete nothing
##   * ScenePersistence dispatches on `is CompositeCable` for both save and restore
##   * the netplay seat/release events are all inherited
##
## ── What is NOT a lead's, and is overridden ─────────────────────────────────
## The GEOMETRY. A CompositeCable's two ends are the two ends of ONE rope; these are
## the far ends of two ropes of different lengths with a rigid body between them. So
## _build_rope wires two, and _physics_process tethers each plug to its OWN attach
## point rather than to the other plug — the base clamps the pair to each other,
## which here would let the 1.8 m deck lead drag the 25 cm pigtail across the room.
##
## The ANT socket routes nothing today: there is no aerial in the room. It is a real
## CoaxPort all the same, so the day there is one it seats, reports and carries
## whatever is on its far end with no change here.
class_name RfSwitch
extends CompositeCable

@onready var _body: RigidBody3D = $Body
@onready var _deck_rope: VerletRope = $VerletRope
@onready var _tv_rope: VerletRope = $TvRope
@onready var _deck_attach: Node3D = $Body/DeckLeadAttach
@onready var _tv_attach: Node3D = $Body/TvLeadAttach

var _deck_reach := 0.0
var _tv_reach := 0.0


## Both connectors black, which is the whole of "tint the phono plug black".
##
## The base tints PlugX0's SURFACE 0 from this, and on both meshes surface 0 is the
## moulding: the phono plug's body, yellow in the bake and black here, and the coax
## plug's boot, which was already black. Surface 1 is metal on both and is never
## touched — that split is why the mechanism works at all.
func _init() -> void:
	cord_colors = PackedColorArray([Color(0.07, 0.07, 0.08)])


func _ready() -> void:
	super._ready()
	# A dangling connector must not shove its own box across the desk.
	for e in [End.A, End.B]:
		for plug: RcaPlug in _end_plugs(e):
			plug.add_collision_exception_with(_body)


## So RcaPort.get_device() finds an owner for the ANT socket.
##
## get_device() walks up the tree looking for exactly this method, and a socket whose
## walk finds nothing accepts plugs, routes nothing, and pushes "socket belongs to no
## device" on every seat. A no-op for the reason RetroTV's is: from here the box is a
## sink with nothing behind it.
func on_av_topology_changed(_links: Array) -> void:
	pass


## Two leads, one rope each.
##
## NOT super's, which builds a single rope from PlugA0 to PlugB0 and would run the
## wire straight through the box as though it were not there.
func _build_rope() -> void:
	if not is_inside_tree():
		return          # a netplay client's local copy is freed before we get here
	_wire(_deck_rope, _deck_attach, _plugs[End.A][0] as RcaPlug)
	_wire(_tv_rope, _tv_attach, _plugs[End.B][0] as RcaPlug)
	_deck_reach = float(_deck_rope.segment_count) * _deck_rope.segment_length
	_tv_reach = float(_tv_rope.segment_count) * _tv_rope.segment_length
	# The base guards _physics_process on this, so an override that forgets it
	# silently disables the tether below.
	_rope_built = true


func _wire(rope: VerletRope, attach: Node3D, plug: RcaPlug) -> void:
	rope.fray_segments_start = 0
	rope.fray_segments_end = 0
	rope.start_node = attach
	rope.end_node = plug
	# End at the connector's cable boss, not at the plug's origin, which sits on the
	# mating face well forward of where the cord actually enters.
	rope.end_anchor_offset = plug.cable_anchor
	rope._init_points()


## Keep each lead within its own reach, moving whichever end is NOT being held.
##
## The base's _clamp_pair holds the two plugs within one rest length of EACH OTHER,
## which is right for a lead whose two ends are the rope's two ends. Here they are
## the far ends of two different ropes anchored to the same box, so the pigtail's
## 25 cm would be measured against the deck lead's 1.8 m and the two would drag each
## other about.
##
## WHICH end moves is the part that matters, and the first version got it backwards:
## it only ever pulled the plug back toward the box and skipped a held plug outright,
## so walking away with a connector stretched the lead without limit and left the box
## sitting where it was. _clamp_pair's rule is the right one — the held end is the
## anchor and the loose end follows — and here the loose end is usually the BOX.
##
## So: plug held (a hand, a laser, or seated in a socket) and box free, the box is
## dragged along behind. Box held and plug free, the plug is reeled in. Both held —
## one in each hand, or one in a socket and one in a hand — nothing moves, because
## something else owns each transform and the reach is the hands' problem. Same call
## _clamp_pair makes.
##
## Both leads are resolved before the box is touched. Applying them one at a time
## would let two over-extended leads shove it back and forth every frame; summing
## them means a box stretched between two anchors simply stays put, which is what a
## real one does — which is why CableHaul returns its backstop rather than applying
## it, and why the two calls below are added together before the box moves. That
## helper is also where the argument for hauling rather than sliding the box lives;
## the speaker pair's loose cabinet is dragged by exactly the same rule.
func _physics_process(_delta: float) -> void:
	if not _rope_built or _plugs.is_empty():
		return
	if _body == null or not is_instance_valid(_body):
		return
	var clamp_back := Vector3.ZERO
	clamp_back += _tether(_plugs[End.A][0] as RcaPlug, _deck_attach, _deck_reach)
	clamp_back += _tether(_plugs[End.B][0] as RcaPlug, _tv_attach, _tv_reach)
	if clamp_back != Vector3.ZERO:
		_body.global_position += clamp_back


## Resolve one lead: reel a loose connector in, or haul the box after a held one.
## Returns the positional backstop the box owes, which the caller sums over both leads.
func _tether(plug: RcaPlug, attach: Node3D, reach: float) -> Vector3:
	if plug == null or not is_instance_valid(plug):
		return Vector3.ZERO
	if attach == null or not is_instance_valid(attach):
		return Vector3.ZERO
	# Boss to boss, not origin to origin: the cord leaves the hood some 32 mm behind
	# the mating face, and that is the span the rope actually has.
	var from: Vector3 = attach.global_position
	var to: Vector3 = plug.global_transform * plug.cable_anchor
	if not plug.is_held():
		# Loose connector, reel it in. A hard move, not a haul: a plug is a light thing
		# on the end of a cord that a rope already turns to face the tangent.
		var away: Vector3 = to - from
		var d: float = away.length()
		if d > reach and d > 0.0001:
			plug.global_position -= away * ((d - reach) / d)
		return Vector3.ZERO
	if _body_is_held():
		return Vector3.ZERO                  # both ends owned; nothing to do
	return CableHaul.haul(_body, from, to, reach)


## True while a hand, a laser or a snap zone owns the box's pose.
##
## `freeze`, for the reason RcaPlug.is_held gives: a ray grab never calls pick_up(),
## so is_picked_up() reads false for the whole hold, while every path that takes an
## object freezes the body.
func _body_is_held() -> bool:
	return is_instance_valid(_body) and _body.freeze


# ── save / restore ────────────────────────────────────────────────────────────

## The box's pose, for ScenePersistence.
##
## A plain lead has no body, so _serialize_cable saves the ROOT's transform and that
## is the whole object. This root never moves — the player carries the Body, which is
## a rigid body in world space — so without these two the box restores at the origin
## and the tether above immediately hauls both plugs out of their sockets to reach it.
func carried_body_pose() -> Dictionary:
	if _body == null or not is_instance_valid(_body):
		return {}
	var p := _body.global_position
	var r := _body.global_rotation_degrees
	return {"position": [p.x, p.y, p.z], "rotation": [r.x, r.y, r.z]}


func restore_carried_body(data: Dictionary) -> void:
	if _body == null or not is_instance_valid(_body) or data.is_empty():
		return
	var p: Array = data.get("position", [])
	var r: Array = data.get("rotation", [])
	if p.size() == 3:
		_body.global_position = Vector3(p[0], p[1], p[2])
	if r.size() == 3:
		_body.global_rotation_degrees = Vector3(r[0], r[1], r[2])
	# The ropes were built around wherever the box stood a frame ago.
	call_deferred("_build_rope")

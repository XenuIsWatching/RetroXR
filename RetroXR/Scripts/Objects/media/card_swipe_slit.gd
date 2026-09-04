## CardSwipeSlit — the groove an e-Reader card is SLID through.
##
## A guide, not a bay. The card is never seated and never leaves the hand: its
## coded edge drops into the groove, the pose is constrained to one axis, and a
## full monotonic pass along the groove reads that edge's strip. Backing out the
## way you came in reads nothing, which is what a botched swipe does on hardware.
##
## Local frame, matching the way it is built onto a unit:
##   +X  along the groove — the travel axis
##   +Y  up, out of the groove; the card's body stands in this direction
##   +Z  the read side, which the card's printed face must look towards
##
## The card is a slab from cartridge.tscn's frame: X wide, Y tall, Z thick, with
## the printed face on +Z.
class_name CardSwipeSlit
extends Area3D

## A full pass; `strip` indexes the card's strips, or -1 when that edge is blank.
signal swiped(card: Node3D, edge: String, strip: int)
## Entered and left by the same end, or let go of part-way.
signal aborted(card: Node3D)

## Length of the groove. A pass must cross essentially all of it.
@export var travel: float = 0.11
## Seconds to square a card up once its edge is in the groove.
@export var snap_time: float = 0.10
## Group a node must be in to be swipeable.
@export var card_group: StringName = &"cartridge"

## Optional extra acceptance test, the way a snap zone's snap_filter works. Set
## it or every cartridge in the room is swipeable, not just a dotcode card.
var card_filter: Callable = Callable()

## Fraction of `travel` a card must still cover for the pass to count. Below 1.0
## because the ends are where a hand slows and stops short.
const COMPLETE_FRACTION := 0.92
## Fraction of `travel` a reversal must undo before it counts as backing out.
## Without a band, hand tremor at the entry threshold aborts every attempt.
const REVERSE_FRACTION := 0.12

var _card: Node3D = null
var _edge: String = ""
var _face_up: bool = false
var _entry_sign: float = 0.0
var _extreme: float = 0.0
var _snap: float = 0.0
var _seated_basis: Basis = Basis.IDENTITY
## Half the card dimension that stands up out of the groove. Which one that is
## depends on the edge presented: an edge on X leaves the card's WIDTH standing.
var _stand_half: float = 0.0


func _ready() -> void:
	# xr-tools drives a held body from _physics_process at a negative priority --
	# -90 force bodies, -80 a hand grab, -70+depth a snap zone. Running after all
	# of them is what lets the constraint below win the frame it is written in.
	process_physics_priority = 10
	monitoring = true
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


# ── Geometry, pure so it can be tested without a hand or a physics step ───────

## Which of the card's four edges is sitting in the groove.
##
## The coded edge is the one lying along the groove, so it is the edge whose
## midpoint is nearest the groove's centre line — not the one pointing most
## nearly along it, which cannot separate an edge in the groove from the
## parallel one at the top of the card.
static func presented_edge(card: Transform3D, card_size: Vector3,
		slit: Transform3D) -> String:
	var half_w := card_size.x * 0.5
	var half_h := card_size.y * 0.5
	var candidates := {
		EReaderCards.EDGE_BOTTOM: Vector3(0.0, -half_h, 0.0),
		EReaderCards.EDGE_TOP: Vector3(0.0, half_h, 0.0),
		EReaderCards.EDGE_SIDE: Vector3(-half_w, 0.0, 0.0),
		EReaderCards.EDGE_SIDE_FAR: Vector3(half_w, 0.0, 0.0),
	}
	var to_slit := slit.affine_inverse()
	var best := ""
	var best_d := INF
	for name: String in candidates:
		var local: Vector3 = to_slit * (card * (candidates[name] as Vector3))
		# Distance from the groove line (the slit's own X axis), so travel along
		# the groove does not change which edge is judged to be in it.
		var d := Vector2(local.y, local.z).length()
		if d < best_d:
			best_d = d
			best = name
	return best


## Whether the card's printed face is the one presented to the reader.
static func is_face_up(card: Transform3D, slit: Transform3D) -> bool:
	return card.basis.z.dot(slit.basis.z) > 0.0


## How far along the groove the card currently sits, in metres from the centre.
static func travel_of(card: Transform3D, slit: Transform3D) -> float:
	return (slit.affine_inverse() * card.origin).x


## Half the card dimension left standing when `edge` is down in the groove.
static func stand_half(edge: String, card_size: Vector3) -> float:
	match edge:
		EReaderCards.EDGE_SIDE, EReaderCards.EDGE_SIDE_FAR:
			return card_size.x * 0.5
		_:
			return card_size.y * 0.5


## The pose a card is held at once it is square in the groove.
static func seated_basis(edge: String, face_up: bool, slit: Transform3D) -> Basis:
	# Bring the presented edge to the groove (card -Y) and the printed face to
	# the read side (card +Z), then express that in the slit's frame.
	var yaw := Basis.IDENTITY
	match edge:
		EReaderCards.EDGE_TOP:
			yaw = Basis(Vector3.FORWARD, PI)
		EReaderCards.EDGE_SIDE:
			yaw = Basis(Vector3.FORWARD, -PI * 0.5)
		EReaderCards.EDGE_SIDE_FAR:
			yaw = Basis(Vector3.FORWARD, PI * 0.5)
		_:
			yaw = Basis.IDENTITY
	if not face_up:
		yaw = Basis(Vector3.UP, PI) * yaw
	return slit.basis * yaw


# ── The pass ─────────────────────────────────────────────────────────────────

func _on_body_entered(body: Node3D) -> void:
	if _card != null or not body.is_in_group(card_group):
		return
	if card_filter.is_valid() and not bool(card_filter.call(body)):
		return
	if not _is_held(body):
		return
	var size := _card_size(body)
	var xform := body.global_transform
	_card = body
	_edge = presented_edge(xform, size, global_transform)
	_face_up = is_face_up(xform, global_transform)
	_seated_basis = seated_basis(_edge, _face_up, global_transform)
	_stand_half = stand_half(_edge, size)
	_snap = 0.0
	var t := travel_of(xform, global_transform)
	_entry_sign = signf(t) if not is_zero_approx(t) else 1.0
	_extreme = t


func _on_body_exited(body: Node3D) -> void:
	if body != _card:
		return
	_finish(false)


func _physics_process(delta: float) -> void:
	if _card == null:
		return
	if not is_instance_valid(_card) or not _is_held(_card):
		_finish(false)
		return

	var t := travel_of(_card.global_transform, global_transform)

	# Constrain: the hand supplies travel along the groove and nothing else.
	if _snap < 1.0 and snap_time > 0.0:
		_snap = minf(1.0, _snap + delta / snap_time)
	else:
		_snap = 1.0
	var target := global_transform
	# The card STANDS in the groove: its centre rides half a card above the line,
	# or it would sit half buried in the case.
	target.origin = global_transform * Vector3(t, _stand_half, 0.0)
	target.basis = _seated_basis
	var held := _card.global_transform
	_card.global_transform = Transform3D(
		held.basis.slerp(target.basis, _snap),
		held.origin.lerp(target.origin, _snap))

	var half := travel * 0.5
	# Travelled far enough, and out the far end rather than the near one.
	if absf(t) >= half * COMPLETE_FRACTION and signf(t) != _entry_sign:
		_finish(true)
		return
	# Backed up appreciably towards the end it came in by.
	if signf(t) == _entry_sign and absf(t) > absf(_extreme) + travel * REVERSE_FRACTION:
		_finish(false)
		return
	if absf(t) < absf(_extreme) or signf(t) != _entry_sign:
		_extreme = t


func _finish(complete: bool) -> void:
	var card := _card
	var edge := _edge
	_card = null
	_edge = ""
	_snap = 0.0
	if card == null:
		return
	if complete:
		swiped.emit(card, edge, _strip_index(card, edge))
	else:
		aborted.emit(card)


func _strip_index(card: Node3D, edge: String) -> int:
	if not card.has_method("get_card_data"):
		return -1
	var data: Variant = card.call("get_card_data")
	if typeof(data) != TYPE_DICTIONARY:
		return -1
	return EReaderCards.strip_for(data as Dictionary, edge, _face_up)


static func _is_held(body: Node3D) -> bool:
	# Covers a hand grab and a pointer-ray grab alike; both report picked up, and
	# a card that merely fell through the groove reports neither.
	return body.has_method("is_picked_up") and bool(body.call("is_picked_up"))


static func _card_size(body: Node3D) -> Vector3:
	if body.has_method("get_card_size"):
		var s: Variant = body.call("get_card_size")
		if typeof(s) == TYPE_VECTOR3:
			return s as Vector3
	return MediaDimensions.CARD_SIZE_EREADER

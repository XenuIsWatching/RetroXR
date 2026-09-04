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

## How square to the groove a card has to be before it counts as presented: the
## cosine between its face normal and the groove's up axis, so 0.5 is 60 degrees
## off flat. Generous on purpose — this rejects a card being carried in over the
## roof, not a card held at a slight angle.
const FLAT_LIMIT := 0.5

## How near the groove's centre line the leading edge has to be, in metres, and
## how far the runner-up has to be behind it. The margin is what makes a card
## offered corner-first WAIT instead of guessing: at 45 degrees two edges are
## equidistant, and whichever the dictionary happened to list first would win.
const ARM_DISTANCE := 0.015
## 12 mm, which is what it takes to actually reject a diagonal: at 45 degrees a
## 63 x 88 card's bottom and side midpoints differ by only (h - w) / 2 / sqrt(2),
## just under 9 mm. A smaller margin looks like a check and arms anyway.
const ARM_MARGIN := 0.012

var _card: Node3D = null
var _edge: String = ""
var _face_up: bool = false
var _entry_sign: float = 0.0
var _extreme: float = 0.0
var _snap: float = 0.0
var _seated_basis: Basis = Basis.IDENTITY
## False while the card is still being lined up — see is_presenting.
var _armed: bool = false
## The card's own dimensions, read once when it arrives.
var _size: Vector3 = Vector3.ZERO
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

## How far each of the card's four edges is from the groove's centre line.
##
## Distance from the LINE (the slit's own X axis), so travel along the groove
## does not change the answer. Midpoint distance rather than how nearly an edge
## points along the groove: that second test cannot separate an edge lying in the
## groove from the parallel one at the top of the card, which is equally parallel.
static func edge_distances(card: Transform3D, card_size: Vector3,
		slit: Transform3D) -> Dictionary:
	var half_w := card_size.x * 0.5
	var half_h := card_size.y * 0.5
	var candidates := {
		EReaderCards.EDGE_BOTTOM: Vector3(0.0, -half_h, 0.0),
		EReaderCards.EDGE_TOP: Vector3(0.0, half_h, 0.0),
		EReaderCards.EDGE_SIDE: Vector3(-half_w, 0.0, 0.0),
		EReaderCards.EDGE_SIDE_FAR: Vector3(half_w, 0.0, 0.0),
	}
	var to_slit := slit.affine_inverse()
	var out: Dictionary = {}
	for name: String in candidates:
		var local: Vector3 = to_slit * (card * (candidates[name] as Vector3))
		out[name] = Vector2(local.y, local.z).length()
	return out


## Which of the card's four edges is sitting in the groove.
static func presented_edge(card: Transform3D, card_size: Vector3,
		slit: Transform3D) -> String:
	var d := edge_distances(card, card_size, slit)
	var best := ""
	var best_d := INF
	for name: String in d:
		if float(d[name]) < best_d:
			best_d = float(d[name])
			best = name
	return best


## Is the card being PRESENTED to the groove, rather than merely overlapping it?
##
## The Area3D fires the moment a corner touches, which for a hand carrying a card
## in flat over the roof is long before any edge has been offered — and the pose
## latched there decided the strip for the whole pass. Measured: a card held flat
## a millimetre above the groove answers "side", and the same card rotated in its
## own plane answers "bottom", neither of which the player has presented.
##
## Three tests, all of which a real presentation passes easily:
##
##   - the card stands ACROSS the groove rather than lying over it. Its face
##     normal has to be within 60 degrees of horizontal, so a card being carried
##     in flat is refused however close it gets.
##   - some edge is genuinely near the line, not merely inside the trigger box.
##   - and it beats the runner-up by a clear margin, so a card offered at 45
##     degrees waits rather than guessing between two edges.
static func is_presenting(card: Transform3D, card_size: Vector3,
		slit: Transform3D) -> bool:
	if absf(card.basis.z.normalized().dot(slit.basis.y.normalized())) > FLAT_LIMIT:
		return false
	var d := edge_distances(card, card_size, slit)
	var best := INF
	var runner_up := INF
	for name: String in d:
		var v: float = d[name]
		if v < best:
			runner_up = best
			best = v
		elif v < runner_up:
			runner_up = v
	return best <= ARM_DISTANCE and (runner_up - best) >= ARM_MARGIN


## Whether the card's printed face is the one presented to the reader.
##
## THE SCANNER LOOKS ALONG THE UNIT'S -Z, so a card reads when its art faces the
## player rather than away. The slit takes the unit's own basis, and the unit's
## -Z is the side its name plate is on -- the side you read the reader from once
## it is socketed in the Game Boy, which is the side you feed a card from too.
##
## Nothing in mGBA has an opinion here: it scans whatever was queued and has no
## concept of a face, so this sign IS the decision. Its partner is the branch in
## seated_basis, which has to turn the same way.
static func is_face_up(card: Transform3D, slit: Transform3D) -> bool:
	return card.basis.z.dot(slit.basis.z) < 0.0


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
	# Bring the presented edge to the groove (card -Y) and leave the printed face
	# where the hand is holding it, then express that in the slit's frame.
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
	# The yaws above leave the card's art along the slit's +Z, which is the side
	# the scanner does NOT look at -- so it is the FACE-UP card that needs the
	# half turn, not the face-down one. See is_face_up: the two signs are one
	# decision and flipping either alone seats every card backwards.
	if face_up:
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
	# Watched, not latched. What the card is doing at first touch is not what it
	# is being offered as -- see is_presenting.
	_card = body
	_size = _card_size(body)
	_armed = false
	_snap = 0.0


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

	# Still being lined up: watch, take nothing, and do not move the card. The
	# hand owns it entirely until it is offering an edge.
	if not _armed:
		if not is_presenting(_card.global_transform, _size, global_transform):
			return
		_arm()

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


## Take the pose the card is being offered at, and hold it to that for the rest
## of the pass.
##
## Latched ONCE. A wrist rolls during a swipe, and recomputing the edge per frame
## flips the choice halfway and reads the other strip; recomputing the face would
## make a card blink between readable and not. The pass is also measured from
## here rather than from first touch, so backing out is judged against where the
## card actually entered the groove.
func _arm() -> void:
	var xform := _card.global_transform
	_edge = presented_edge(xform, _size, global_transform)
	_face_up = is_face_up(xform, global_transform)
	_seated_basis = seated_basis(_edge, _face_up, global_transform)
	_stand_half = stand_half(_edge, _size)
	_snap = 0.0
	var t := travel_of(xform, global_transform)
	_entry_sign = signf(t) if not is_zero_approx(t) else 1.0
	_extreme = t
	_armed = true


func _finish(complete: bool) -> void:
	var card := _card
	var edge := _edge
	var armed := _armed
	_card = null
	_edge = ""
	_snap = 0.0
	_armed = false
	if card == null:
		return
	# A card that was never offered to the groove did not abort a pass; it was
	# carried past. Reporting that as an abort would toast the player for walking
	# their card over the machine.
	if not armed:
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

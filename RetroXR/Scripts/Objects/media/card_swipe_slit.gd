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

## How near the groove's centre line the card has to actually BE, in metres.
##
## Measured to the nearest CORNER, not to the nearest edge midpoint. A midpoint
## climbs as the card tilts even though the card is touching the groove -- at 30
## degrees it is 15.7 mm up and at 45 degrees 22.3 mm -- so a threshold on it
## rejects every card that is not nearly square, which is a 40-degree hole a hand
## falls into constantly. The corner is on the line whenever the card is.
const ARM_DISTANCE := 0.008

## How far the runner-up edge must be behind the leading one, in metres, judged
## on midpoints -- which is what actually distinguishes the four edges.
##
## Measured over an in-plane sweep of a 63 x 88 card: the gap is 44 mm upright,
## 22 mm at 30 degrees, and collapses to 0.6 mm at 55 degrees, where the card
## really is diagonal and neither edge is being offered. 6 mm leaves a wait of
## about ten degrees around that, and takes everything else.
const ARM_MARGIN := 0.006

## The tick a card gives back when a strip is actually read. Sized off
## Haptics.CLICK_DOWN, since that is the weight of a control latching, and one
## frame for the reason the click constants give: the manager re-drives the
## hardware every frame an event is alive, so two frames is already a buzz.
const SCAN_MAGNITUDE := 0.5
const SCAN_MS := 10
const HAPTIC_KEY := &"card_swipe"

## How far the card has to actually MOVE along the groove before the pass has a
## direction. Until then neither end is "the way it came in", so neither
## completing nor backing out can be judged.
const DIRECTION_MM := 0.006

var _card: Node3D = null
var _edge: String = ""
var _face_up: bool = false
var _entry_sign: float = 0.0
var _extreme: float = 0.0
var _snap: float = 0.0
var _seated_basis: Basis = Basis.IDENTITY
## False while the card is still being lined up — see is_presenting.
var _armed: bool = false
## Where along the groove the card armed, and true once it has moved far enough
## from there to say which way it is going.
var _arm_travel: float = 0.0
var _have_direction: bool = false
## Set by an abort, cleared when the card stops being offered. Without it an
## aborted card re-arms on the very next frame, still presenting, and the pass
## flaps in and out under the hand.
var _rearm_block: bool = false
## The card's own dimensions, read once when it arrives.
var _size: Vector3 = Vector3.ZERO
## The body the groove is cut into, exempted from colliding with the card for the
## length of a pass. See _arm.
var _host: PhysicsBody3D = null
## Half the card dimension that stands up out of the groove. Which one that is
## depends on the edge presented: an edge on X leaves the card's WIDTH standing.
var _stand_half: float = 0.0


func _ready() -> void:
	# xr-tools drives a held body from _physics_process at a negative priority --
	# -90 force bodies, -80 a hand grab, -70+depth a snap zone. Running after all
	# of them is what lets the constraint below win the frame it is written in.
	process_physics_priority = 10
	monitoring = true
	_host = get_parent() as PhysicsBody3D
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


# ── Geometry, pure so it can be tested without a hand or a physics step ───────

## How far DOWN the groove each of the card's four edges sits, in the slit's own
## frame — lower is further into the slot.
##
## The slit runs along its X and takes a card down its -Y, so the edge going in
## is simply the lowest one. Depth along -Y rather than distance from the groove
## LINE, which was the old rule: distance also counts displacement in Z, so a
## card held a little in front of or behind the slot could have its answer
## changed by where the hand was rather than by how the card was turned.
static func edge_depths(card: Transform3D, card_size: Vector3,
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
		out[name] = (to_slit * (card * (candidates[name] as Vector3))).y
	return out


## How far the card's nearest CORNER is from the groove's centre line.
##
## What "the card is at the groove" means, and the only one of the three arming
## tests that is about position rather than pose: a corner is on the line
## whenever any part of the card is, at any tilt.
static func corner_distance(card: Transform3D, card_size: Vector3,
		slit: Transform3D) -> float:
	var half_w := card_size.x * 0.5
	var half_h := card_size.y * 0.5
	var to_slit := slit.affine_inverse()
	var best := INF
	for corner: Vector3 in [Vector3(half_w, half_h, 0.0), Vector3(-half_w, half_h, 0.0),
			Vector3(half_w, -half_h, 0.0), Vector3(-half_w, -half_h, 0.0)]:
		var local: Vector3 = to_slit * (card * corner)
		best = minf(best, Vector2(local.y, local.z).length())
	return best


## Which of the card's four edges is sitting in the groove.
static func presented_edge(card: Transform3D, card_size: Vector3,
		slit: Transform3D) -> String:
	var d := edge_depths(card, card_size, slit)
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
##   - the card is genuinely AT the groove, measured to its nearest corner, not
##     merely inside the trigger box.
##   - and one edge beats the runner-up by a clear margin, so a card held
##     diagonally waits rather than guessing between the two that meet at the
##     corner it is resting on.
##
## The three are deliberately measured on three different things. Asking the
## midpoint how near the card is conflates "not close" with "not square", and
## cost a hand every offer past 28 degrees off upright.
static func is_presenting(card: Transform3D, card_size: Vector3,
		slit: Transform3D) -> bool:
	if absf(card.basis.z.normalized().dot(slit.basis.y.normalized())) > FLAT_LIMIT:
		return false
	if corner_distance(card, card_size, slit) > ARM_DISTANCE:
		return false
	var d := edge_depths(card, card_size, slit)
	var best := INF
	var runner_up := INF
	for name: String in d:
		var v: float = d[name]
		if v < best:
			runner_up = best
			best = v
		elif v < runner_up:
			runner_up = v
	return (runner_up - best) >= ARM_MARGIN


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
	_card = null
	_rearm_block = false


func _physics_process(delta: float) -> void:
	if _card == null:
		return
	if not is_instance_valid(_card) or not _is_held(_card):
		# Dropped or freed: the card is gone as far as this groove is concerned,
		# and _finish alone would leave it watched -- which is a second abort on
		# the very next frame, and every frame after.
		_finish(false)
		_card = null
		_rearm_block = false
		return

	# Still being lined up: watch, take nothing, and do not move the card. The
	# hand owns it entirely until it is offering an edge.
	if not _armed:
		if not is_presenting(_card.global_transform, _size, global_transform):
			# Offered, refused, and now taken away again: it may be offered afresh.
			_rearm_block = false
			return
		if _rearm_block:
			return
		_arm()

	var t := travel_of(_card.global_transform, global_transform)

	# Constrain: the hand supplies travel along the groove and nothing else.
	if _snap < 1.0 and snap_time > 0.0:
		_snap = minf(1.0, _snap + delta / snap_time)
	else:
		_snap = 1.0
	# A teleported body still accumulates whatever the solver handed it before the
	# write. Left in, that is spent the moment the card is released -- it leaves
	# the groove with the velocity of a fight it was never allowed to win.
	var rb := _card as RigidBody3D
	if rb != null:
		rb.linear_velocity = Vector3.ZERO
		rb.angular_velocity = Vector3.ZERO

	var target := global_transform
	# The card STANDS in the groove: its centre rides half a card above the line,
	# or it would sit half buried in the case.
	target.origin = global_transform * Vector3(t, _stand_half, 0.0)
	target.basis = _seated_basis
	var held := _card.global_transform
	_card.global_transform = Transform3D(
		held.basis.slerp(target.basis, _snap),
		held.origin.lerp(target.origin, _snap))

	# Which end the card came in by is LEARNED, not guessed.
	#
	# It used to be read off the card's position the instant it armed, falling
	# back to "the +X end" when that position was near the middle. Arming happens
	# on the card's pose now, so it can happen anywhere along the groove -- and a
	# card armed near the middle was given a direction by a coin toss, then judged
	# to have backed out the moment the hand pushed it the other way. That is the
	# snap-in-snap-out: abort, the hand carries it clear, it presents again, and
	# the same coin comes up.
	#
	# So until the card has actually travelled, the pass has no direction and
	# neither ending can be judged.
	if not _have_direction:
		var moved := t - _arm_travel
		if absf(moved) < DIRECTION_MM:
			return
		_have_direction = true
		_entry_sign = -signf(moved)
		_extreme = _arm_travel

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
	_arm_travel = travel_of(xform, global_transform)
	_extreme = _arm_travel
	_entry_sign = 0.0
	_have_direction = false
	_armed = true

	# The card and the machine are on the same collision layer, and a swiped card
	# rides with its edge ON the case rather than above it -- so the solver has a
	# contact to resolve on every step of the pass, while this constraint teleports
	# the body back onto the groove line right after it. Each fights the other at
	# the physics rate, which is the jitter.
	#
	# The card is deliberately NOT frozen: freeze covers all three kinds of hold,
	# so setting it would end the grab mid-swipe. Exempting the pair is the half
	# that can be undone cleanly, and it lasts exactly as long as the pass.
	var body := _card as PhysicsBody3D
	if body != null and _host != null:
		body.add_collision_exception_with(_host)


func _finish(complete: bool) -> void:
	var card := _card
	var edge := _edge
	var armed := _armed
	var body := card as PhysicsBody3D
	if is_instance_valid(body) and _host != null:
		body.remove_collision_exception_with(_host)
	# The card is KEPT when a pass ends inside the groove -- it is still in the
	# trigger volume, and body_entered will not fire again until it leaves. What
	# is dropped is the pass. Only _on_body_exited forgets the card itself.
	_edge = ""
	_snap = 0.0
	_armed = false
	_have_direction = false
	# Any ended pass blocks the next one until the card is taken away and offered
	# again -- a completed one as much as an abort. A card that has just been
	# drawn out of the far end is still inside the trigger volume and still
	# standing square, so without this it starts a second pass on the next frame
	# and reads the same strip again.
	_rearm_block = armed
	if card == null:
		return
	# A card that was never offered to the groove did not abort a pass; it was
	# carried past. Reporting that as an abort would toast the player for walking
	# their card over the machine.
	if not armed:
		return
	if not complete:
		aborted.emit(card)
		return
	var strip := _strip_index(card, edge)
	if strip >= 0:
		# The one moment the hand has no other way of knowing it worked: the
		# reader's own answer is a screen away, and a swipe that read nothing
		# looks exactly like a swipe that read something until you look up.
		# A single short tick, at the weight of a control latching rather than a
		# buzz -- a card passing a scanner head is a click, not an event.
		#
		# Only on a READ. A completed pass that took nothing (wrong edge, wrong
		# way up) must feel like nothing, or the tick stops meaning anything.
		# Null-safe by design in Haptics.pulse, which is what makes this correct
		# on the desktop hand as well: it has no controller and must not rumble.
		Haptics.pulse(card.get_picked_up_by_controller() if card.has_method(
			"get_picked_up_by_controller") else null, SCAN_MAGNITUDE, SCAN_MS, HAPTIC_KEY)
	swiped.emit(card, edge, strip)


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

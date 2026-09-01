## MediaTray — a reusable top-loading disc tray with a hinged lid (PlayStation-style).
## The sibling of MediaSlot for decks that open a lid rather than swallow the media:
## press OPEN, the lid flips up, drop a disc in the well (or lift one out), close the
## lid, and the disc spins while it plays. Used by the CD player.
##
## Shares MediaSlot's core trick — while loaded the disc is a FROZEN, STATIC-freeze
## rigid child of the well, so it rides the deck through the scene graph with no
## per-frame code — but there's no insert/eject ride: the disc is simply seated in
## the well, and the LID (not an eject button) gates access. The disc is grabbable
## and the well accepts a new disc only while the lid is open; closed, it's sealed
## and spinnable.
##
## The host wires two signals:
##   loaded(media)   — disc placed in the well; read its album / start state here.
##   unloaded()      — disc taken out; stop playback.
## and drives it with toggle_open() / set_open(), is_open(), can_spin(),
## has_media(), get_media(), restore(media).
class_name MediaTray
extends Node


## Disc placed in the well.
signal loaded(media: Node3D)
## Disc left the well (lifted out).
signal unloaded()
## Lid finished opening / closing.
signal opened()
signal closed()


## The body the disc attaches to and is collision-excepted against (the deck).
@export var host: PhysicsBody3D
## The well's snap zone (a child of `host`, so it rides with it). Only enabled while
## the lid is open.
@export var slot: XRToolsSnapZone
## Orientation of the disc relative to the well when seated (IDENTITY = as-authored).
@export var media_local_basis: Basis = Basis.IDENTITY
## Where the disc sits in the well, relative to the slot origin.
@export var seat_offset: Vector3 = Vector3.ZERO
## Optional hinged lid to animate. Rotates `lid_open_deg` about its local X when open.
@export var lid_pivot: Node3D
@export var lid_open_deg: float = -110.0
## Lid animation duration (seconds).
@export var lid_time: float = 0.4
## Optional pivot the seated disc should physically ride along with instead of
## staying fixed to `slot` — a flip-open tray assembly (the PSP's UMD door)
## where the disc's resting slot is part of the door itself, unlike a spindle
## console (PS1, GameCube...) where the disc rests on the BASE and only the
## lid mesh swings. Null (default): disc stays fixed under `slot`, as before.
@export var disc_lid_pivot: Node3D


var _media: Node3D = null
var _holder: Node3D = null
var _open: bool = false
var _lid_tween: Tween = null
var _orig_freeze_mode: RigidBody3D.FreezeMode = RigidBody3D.FREEZE_MODE_KINEMATIC
## `slot`'s rest pose relative to `disc_lid_pivot`, captured once at _ready()
## (slot is a fixed child of `host`, not `disc_lid_pivot`, so its transform
## has to be driven every frame in _process instead of via reparenting — it's
## a shared XRToolsSnapZone with other wiring that assumes a stable parent).
var _slot_rest_offset := Transform3D.IDENTITY


func _ready() -> void:
	_holder = Node3D.new()
	_holder.name = "MediaHolder"
	if disc_lid_pivot != null:
		disc_lid_pivot.add_child(_holder)
		if slot != null:
			_slot_rest_offset = disc_lid_pivot.global_transform.affine_inverse() * slot.global_transform
	elif slot:
		slot.add_child(_holder)
	if slot:
		slot.has_picked_up.connect(_on_slot_captured)
	# Start closed: the well can't take or give a disc until the lid opens.
	_apply_open(false, false)
	set_process(disc_lid_pivot != null)


## Only running while `disc_lid_pivot` is set (every other console pays
## nothing): keep the drop-in zone itself tracking the swinging door live, so
## a new disc can be dropped onto the visibly open tray instead of wherever
## the door's CLOSED rest position happened to be.
func _process(_delta: float) -> void:
	if disc_lid_pivot != null and slot != null:
		slot.global_transform = disc_lid_pivot.global_transform * _slot_rest_offset


func has_media() -> bool:
	return _media != null


func get_media() -> Node3D:
	return _media


func is_open() -> bool:
	return _open


## Spins only while sealed shut over a disc (purely visual, host-driven).
func can_spin() -> bool:
	return not _open and _media != null


## Keep the two access gates in sync with the lid + load state: the well accepts a
## new disc only while open AND empty (so it never re-detects the disc it's already
## holding), and the loaded disc is grabbable only while the lid is open.
func _sync_gates() -> void:
	slot.enabled = _open and _media == null
	if is_instance_valid(_media) and "enabled" in _media:
		_media.enabled = _open


# --- Lid -----------------------------------------------------------------------

func toggle_open() -> void:
	set_open(not _open)


## Open or close the lid: gates the well's snap zone and the disc's grabbability
## (both only while open) and animates the lid mesh.
##
## `animate` is false for a RESTORE, which is a state the room was already in
## rather than something the player just did — the same rule the models'
## set_lid_angle_deg follows. Everything else here still happens: the gates are
## the point, and they are what a restored lid used to be missing.
func set_open(open: bool, animate: bool = true) -> void:
	if open == _open:
		return
	_apply_open(open, animate)


func _apply_open(open: bool, animate: bool) -> void:
	_open = open
	_sync_gates()
	if lid_pivot != null:
		var target := lid_open_deg if open else 0.0
		if animate:
			if _lid_tween:
				_lid_tween.kill()
			_lid_tween = lid_pivot.create_tween()
			_lid_tween.tween_property(lid_pivot, "rotation_degrees:x", target, lid_time) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		else:
			lid_pivot.rotation_degrees.x = target
	if open:
		opened.emit()
	else:
		closed.emit()


# --- Load / unload -------------------------------------------------------------

## Snap zone captured a dropped disc (only fires while open). Take ownership next
## idle frame (clear of the zone's pick-up call stack).
func _on_slot_captured(media: Node3D) -> void:
	call_deferred("_accept", media, true)


## Programmatic seat for save / net restore (no zone, filter bypassed).
func restore(media: Node3D) -> void:
	_accept(media, false)


## Unseat with no hand involved — a net event, or a scripted eject. The mirror of
## restore(), and the reason it exists: a seated disc is NOT held by the snap zone
## (accept dropped it and reparented the disc to this tray's own holder), so a
## caller reaching for the zone's drop_object() unseats nothing at all.
func release() -> void:
	if _media != null:
		_on_media_taken(_media)


func _accept(media: Node3D, by_hand: bool = false) -> void:
	if not is_instance_valid(media) or _media != null:
		return
	if slot.has_snapped_object():
		slot.drop_object()
	_media = media
	if media is RigidBody3D:
		var rb := media as RigidBody3D
		_orig_freeze_mode = rb.freeze_mode
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		rb.freeze = true
	media.reparent(_holder)
	var seat := media_local_basis
	if by_hand:
		seat = RetroDisc.seat_basis(media_local_basis, media, _holder)
	media.transform = Transform3D(seat, seat_offset)
	if is_instance_valid(host):
		host.add_collision_exception_with(media)
	if not media.picked_up.is_connected(_on_media_taken):
		media.picked_up.connect(_on_media_taken)
	# Now holding a disc: the well stops accepting, and the disc is grabbable only
	# while the lid is open.
	_sync_gates()
	loaded.emit(media)


# --- Grab hand-off (mirrors MediaSlot) ----------------------------------------

func _on_media_taken(media: Node3D) -> void:
	if media.picked_up.is_connected(_on_media_taken):
		media.picked_up.disconnect(_on_media_taken)
	# Hand off with the disc's normal freeze mode, and make sure it un-freezes (falls)
	# when released — it was frozen in the well, so XR-tools captured restore_freeze
	# = true otherwise.
	if media is RigidBody3D:
		(media as RigidBody3D).freeze_mode = _orig_freeze_mode
	if "restore_freeze" in media:
		media.restore_freeze = false
	_media = null
	# Well is empty again — accept a new disc if the lid is still open.
	_sync_gates()
	unloaded.emit()
	# Hold the host exception until the hand drops the disc, so it never clips the
	# deck while being lifted out.
	if media.has_signal("dropped") and not media.dropped.is_connected(_drop_host_exception):
		media.dropped.connect(_drop_host_exception, CONNECT_ONE_SHOT)
	call_deferred("_release_media", media)


func _release_media(media: Node3D) -> void:
	if is_instance_valid(media) and media.get_parent() == _holder:
		media.reparent(get_tree().current_scene)


func _drop_host_exception(media: Node3D) -> void:
	if is_instance_valid(host) and is_instance_valid(media) and media != _media:
		host.remove_collision_exception_with(media)

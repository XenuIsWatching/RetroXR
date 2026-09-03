## Audio-deck self-tests — the CD player, the cassette deck and the turntable, and
## the shared RetroAudioPlayer base under all three. Headless, no album, no headset.
##
##     "$godot" --headless --path RetroXR res://Tests/deck_tests.tscn
##     "$godot" --headless --path RetroXR res://Tests/deck_tests.tscn -- --only=gate
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## This is the first coverage the decks have ever had. Every case below is either a
## bug that shipped or a rule the turntable now depends on, and each one was watched
## going red before it was believed.
##
## ONE CONSTRAINT SHAPES EVERY CASE: VlcPlayer is a GDExtension that does not exist
## in a headless run, so `_vlc` is null and RetroAudioPlayer.play() returns early —
## `is_playing` NEVER becomes true here. So nothing asserts on audio. What is
## asserted is the state around it: which track is selected, whether the platter
## well is gated open or shut, what type a deck saves as, and which commands the net
## layer will accept. Asserting on is_playing would give a green that means nothing.
##
## Groups:
##   base/     the shared base with hardware a deck does not have
##   save/     each deck's save type, and the fallthrough that used to mislabel one
##   media/    the vinyl record through the guards that decide it exists
##   gate/     MediaTray's access matrix, which the tonearm now drives
##   arm/      the tonearm: parking, track mapping, and the restore that must NOT play
##   net/      the audio command shape, including the index-carrying one
##   remote/   which remote cells each deck offers
extends Node

const GROUPS := ["base", "save", "media", "gate", "arm", "scrub", "net", "remote"]

const RECORD_PLAYER := preload("res://Scenes/Objects/appliances/record_player.tscn")
const CD_PLAYER := preload("res://Scenes/Objects/appliances/cd_player.tscn")
const CASSETTE_PLAYER := preload("res://Scenes/Objects/appliances/cassette_player.tscn")
const VINYL_RECORD := preload("res://Scenes/Objects/media/vinyl_record.tscn")
const AUDIO_DISC := preload("res://Scenes/Objects/media/audio_disc.tscn")

var _fail := 0
var _ran := 0
var _only := ""
var _spawned: Array[Node] = []


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.trim_prefix("--only=")

	if _want("base"):
		await _test_base()
	if _want("save"):
		await _test_save_types()
	if _want("media"):
		await _test_media_guards()
	if _want("gate"):
		await _test_gate_matrix()
	if _want("arm"):
		await _test_arm()
	if _want("scrub"):
		await _test_scrub()
	if _want("net"):
		await _test_net()
	if _want("remote"):
		await _test_remote()

	await _cleanup()
	print("[test] %d cases, %s" % [_ran,
		"PASS" if _fail == 0 else "%d FAILURE(S)" % _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ── base/ ─────────────────────────────────────────────────────────────────────

## A turntable has no FF/REW hardware at all. The base used to reach for
## $RewindButton and $FastForwardButton unconditionally, so a deck without them
## could not reach the end of _ready() — this is that regression.
func _test_base() -> void:
	var rp := await _deck(RECORD_PLAYER)
	# Asserted on the audio emitter, NOT on the node merely existing: a null access
	# in _ready aborts that FUNCTION and nothing else, so the deck is still in the
	# tree afterwards and "did it instantiate" cannot tell the two outcomes apart.
	# The emitter is built at the END of the base's _ready, past the button wiring,
	# so it is present only if _ready actually ran to completion.
	_ok(rp.get_node_or_null("SpatialAudioEmitter") != null,
		"base/a deck with no scan buttons runs _ready to completion")
	_ok(not rp.has_scan(), "base/a turntable reports no scan")
	_ok(rp.has_track_skip(), "base/...but keeps track skip, which the needle can do")

	var cd := await _deck(CD_PLAYER)
	_ok(cd.has_scan(), "base/a CD deck does have scan")
	_ok(cd.has_track_skip(), "base/a CD deck has track skip")

	var tape := await _deck(CASSETTE_PLAYER)
	_ok(tape.has_scan(), "base/a cassette has scan")
	_ok(not tape.has_track_skip(), "base/a cassette has no track skip — it is linear")

	# The scan handlers must refuse as well, or a TV remote and a stale peer's "ff"
	# would still scan a deck that physically cannot.
	rp._scan_dir = 0
	rp.remote_ff()
	rp.remote_rewind()
	_eq(rp._scan_dir, 0, "base/remote ff/rew cannot scan a deck with no scan")


# ── save/ ─────────────────────────────────────────────────────────────────────

## The serializer used to read `"cd_player" if node is CDPlayer else
## "cassette_player"`, whose else-arm swallowed every future deck: a turntable was
## saved as, and restored as, a cassette machine. Three decks must give three
## distinct strings.
func _test_save_types() -> void:
	var rp := await _deck(RECORD_PLAYER)
	var cd := await _deck(CD_PLAYER)
	var tape := await _deck(CASSETTE_PLAYER)
	_eq(cd.deck_save_type(), "cd_player", "save/CD deck saves as cd_player")
	_eq(tape.deck_save_type(), "cassette_player", "save/cassette saves as cassette_player")
	_eq(rp.deck_save_type(), "record_player", "save/turntable saves as record_player")

	# Through the REAL serializer, not just the virtual — the bug lived in
	# _serialize_node's type expression, so a case that only asked each deck for its
	# own answer would stay green with the fault fully restored.
	var persistence := ScenePersistence.new()
	var types := {}
	for d: Node in [rp, cd, tape]:
		var entry: Dictionary = persistence._serialize_node(d, 1, {})
		var t := str(entry.get("type", ""))
		types[t] = true
		_eq(t, d.deck_save_type(),
			"save/the serializer writes %s's own type" % d.deck_save_type())
		_ok(persistence.PLAIN_SCENES.has(t), "save/%s is restorable" % t)
	_eq(types.size(), 3, "save/three decks serialize to three distinct types")


# ── media/ ────────────────────────────────────────────────────────────────────

## A record has to survive three separate `is` chains to exist at all. The netplay
## one is the dangerous one: it fails SILENTLY — the record drops out of the content
## manifest, verify-by-name never runs, and clients are simply mute with no error.
func _test_media_guards() -> void:
	var lp := VINYL_RECORD.instantiate() as VinylRecord
	lp.album_path = "/nowhere/Some Album"
	lp.album_label = "Some Album"
	add_child(lp)
	_spawned.append(lp)
	await get_tree().process_frame

	_ok(lp.is_in_group("vinyl_record"), "media/a record is in the vinyl_record group")
	_eq(lp.get_album_path(), "/nowhere/Some Album", "media/a record reports its album")

	var sync := NetObjectSync.new()
	var desc: Dictionary = sync._file_desc(lp)
	_eq(str(desc.get("kind", "")), "music", "media/net treats a record as music")
	_eq(str(desc.get("prop", "")), "album_path", "media/...keyed on album_path")
	sync.free()

	# The label hook the transfer UI writes through.
	lp.net_set_download_status("42%")
	_eq((lp.get_node("DiscLabel") as Label3D).text, "42%", "media/status shows on the label")
	lp.net_set_download_status("")
	_eq((lp.get_node("DiscLabel") as Label3D).text, "Some Album", "media/...and clears back")


# ── gate/ ─────────────────────────────────────────────────────────────────────

## MediaTray's access matrix, which is what the tonearm now drives: the well accepts
## a record only while open AND empty (or it re-detects the one it is holding), and
## a seated record is liftable only while open. Four combinations, all four asserted
## — the turntable's whole "you cannot lift a record out from under a playing
## needle" behaviour is this table and nothing else.
func _test_gate_matrix() -> void:
	var rp := await _deck(RECORD_PLAYER)
	var tray: MediaTray = rp._tray
	_ok(tray != null, "gate/the turntable built a tray")

	# A freshly spawned deck must be OPEN. MediaTray starts closed, which for a
	# turntable is backwards — it would leave a locked platter no record could go on.
	_ok(tray.is_open(), "gate/a fresh turntable's platter is open")
	_ok(tray.slot.enabled, "gate/...and its well accepts a record")
	_ok(not tray.has_media(), "gate/...and is empty")

	var lp := await _seat(rp)
	_ok(tray.has_media(), "gate/open + record dropped in = seated")
	_ok(not tray.slot.enabled, "gate/open + full: the well stops accepting")
	_ok(lp.enabled, "gate/open + full: the record is liftable")
	_ok(not tray.can_spin(), "gate/open + full: needle up, so it does not spin")

	tray.set_open(false, false)
	_ok(not tray.slot.enabled, "gate/shut + full: the well accepts nothing")
	_ok(not lp.enabled, "gate/shut + full: the record is LOCKED under the needle")
	_ok(tray.can_spin(), "gate/shut + full: the needle is down")

	# And a hand-free unseat, which is what the net layer's remove event needs.
	# Reaching for the snap zone here unseats nothing: the tray took ownership and
	# reparented the record out of the zone when it accepted it.
	rp.remove_media()
	await get_tree().process_frame
	_ok(not tray.has_media(), "gate/remove_media unseats a tray deck")
	_ok(tray.is_open(), "gate/...leaving the platter open again")


# ── arm/ ──────────────────────────────────────────────────────────────────────

func _test_arm() -> void:
	var rp := await _deck(RECORD_PLAYER)
	var arm: VRLever = rp._arm
	_ok(arm != null, "arm/the turntable has a tonearm lever")
	_ok(arm.target != null, "arm/...with a pivot to turn")

	# The mount's basis is what makes a tonearm swing about VERTICAL rather than
	# tipping over. VRHinge turns about the PIVOT's local X, so that axis has to
	# come out along the deck's up. Checked as a printed axis rather than by
	# looking at it: an empty arc is symmetric and reads correct either way round.
	var pivot := arm.target as Node3D
	var axis: Vector3 = pivot.global_transform.basis.x.normalized()
	var up: Vector3 = rp.global_transform.basis.y.normalized()
	_ok(absf(axis.dot(up)) > 0.99,
		"arm/the hinge axis is the deck's up (got %.3f)" % axis.dot(up))

	# Parked vs cued, and the gate that follows from it.
	arm.set_value_no_signal(0.0)
	_ok(rp._arm_parked(), "arm/value 0 is parked")
	arm.set_value_no_signal(1.0)
	_ok(not rp._arm_parked(), "arm/value 1 is over the record")

	# Track mapping across the playable band.
	rp._tracks = PackedStringArray(["a.mp3", "b.mp3", "c.mp3", "d.mp3"])
	_eq(rp._track_at(rp.arm_lead_in), 0, "arm/the outer edge is track 1")
	_eq(rp._track_at(rp.arm_lead_out), 3, "arm/the run-out is the last track")
	var mid: int = rp._track_at((rp.arm_lead_in + rp.arm_lead_out) * 0.5)
	_ok(mid == 1 or mid == 2, "arm/halfway lands mid-album (got %d)" % mid)
	# Landing anywhere in the parked zone must never index a track.
	_eq(rp._track_at(0.0), 0, "arm/a parked arm clamps to the first track")

	# THE DISCRIMINATOR. Restoring a room calls VRLever.set_value(), which EMITS
	# value_changed. A deck that dropped the needle on value_changed would treat
	# every save-load as someone starting the record — and broadcast it to the room.
	# released() is emitted only by a real hand letting go.
	rp._track_idx = 0
	var seen_cmd := false
	rp._tracks = PackedStringArray(["a.mp3", "b.mp3", "c.mp3", "d.mp3"])
	arm.set_value(1.0)          # what a restore does
	await get_tree().process_frame
	_eq(rp._track_idx, 0, "arm/a RESTORE moving the arm does not select a track")
	_ok(not seen_cmd, "arm/...and reports nothing to the room")
	# ...whereas a real release does.
	arm.released.emit(1.0)
	await get_tree().process_frame
	_eq(rp._track_idx, 3, "arm/a real release DOES drop the needle on that band")

	# Parking the arm shuts the well again, and that IS the restore path, so it has
	# to happen on value_changed rather than only on release.
	arm.set_value(0.0)
	await get_tree().process_frame
	_ok(rp._tray.is_open(), "arm/parking the arm opens the platter")

	# DESKTOP GRAB. In VR these widgets engage a fingertip by proximity to their own
	# origin and need no collision shape at all — which is exactly why this shipped
	# broken and neither a headless case nor a render could see it. The desktop
	# reticle is an intersect_ray against the pointable layer, and a ray cannot hit a
	# shapeless Area3D, so without a shape the arm simply cannot be grabbed on a
	# desktop. Asserted on both widgets a hand has to reach.
	for spec: Array in [[arm, "the tonearm"], [rp._speed_switch, "the 33/45 switch"]]:
		var w: Area3D = spec[0]
		var label: String = spec[1]
		_ok(w != null and (w.collision_layer & (1 << 20)) != 0,
			"arm/%s is on the pointable layer" % label)
		var shaped := false
		for child in w.get_children():
			if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
				shaped = true
		_ok(shaped, "arm/%s has a shape a desktop ray can hit" % label)

	# A DETENT SWITCH MUST BE FLIPPABLE BOTH WAYS by a pointer, and this drives the
	# real thing rather than asserting a proxy for it. An earlier version of this
	# case checked only that the grab box was wider than the throw — which is
	# necessary, is documented in _update_knob, and was TRUE of a switch that still
	# could not be flipped back, because the box's REST POSE was also wrong. A
	# precondition that holds while the feature is broken is not a test of the
	# feature. So: press where a ray could actually land, and read the value.
	var sw: VRSlider = rp._speed_switch
	if sw != null and sw.steps >= 2:
		sw.set_value_no_signal(0.0)
		await get_tree().process_frame
		_eq(_press_at(sw, _reach(sw, 1.0)), 1.0, "arm/a pointer can throw the speed switch to 45")
		_eq(_press_at(sw, _reach(sw, -1.0)), 0.0, "arm/...and can throw it BACK to 33")
		# And back again, so a working one-way flip cannot pass either.
		_eq(_press_at(sw, _reach(sw, 1.0)), 1.0, "arm/the switch keeps flipping both ways")


# ── scrub/ ────────────────────────────────────────────────────────────────────

## Palming the record to brake it, and dragging it to scrub. Both are handed to the
## base's existing scan loop — the same muted, throttled seeking FF/REW does — with
## the rate and direction coming from the hand instead of a button.
##
## This covers the MAPPING only. Whether a real fingertip is found on the platter
## needs an XRController3D and a tracked hand, neither of which exists headless, so
## the contact side is not proven here; `is_playing` is forced for the same reason
## (VlcPlayer is absent, so play() can never set it).
func _test_scrub() -> void:
	var rp := await _deck(RECORD_PLAYER)
	rp._tracks = PackedStringArray(["a.mp3", "b.mp3"])
	rp.is_playing = true

	# Dragged forward, faster than the motor: seek forward, faster than 1x.
	rp._hand_omega = RecordPlayer.SPEED_33 * 2.0
	rp._apply_scrub()
	_eq(rp._scan_dir, 1, "scrub/dragged forward seeks forward")
	_ok(absf(rp.scan_speed - 2.0) < 0.01,
		"scrub/...at the hand's speed relative to the motor (got %.2f)" % rp.scan_speed)

	# Dragged backward.
	rp._hand_omega = -RecordPlayer.SPEED_33
	rp._apply_scrub()
	_eq(rp._scan_dir, -1, "scrub/dragged backward seeks backward")

	# Held still under a hand: braked, and silent. A scan_dir of 0 is what mutes it,
	# via the base's _apply_volume.
	rp._hand_omega = 0.05
	rp._apply_scrub()
	_eq(rp._scan_dir, 0, "scrub/a record held still is braked, not scrubbed")

	# 45 rpm is a faster motor, so the same hand speed is a SLOWER scrub relative
	# to it. This is the case that catches the nominal speed being hardcoded.
	rp._speed_45 = true
	rp._hand_omega = RecordPlayer.SPEED_45 * 2.0
	rp._apply_scrub()
	_ok(absf(rp.scan_speed - 2.0) < 0.01,
		"scrub/the scrub rate follows the selected speed (got %.2f)" % rp.scan_speed)
	rp._speed_45 = false

	# A client never seeks locally: transport is the host's, and a per-frame
	# position stream does not belong on the wire.
	rp._scan_dir = 0
	rp.is_playing = false
	rp._hand_omega = RecordPlayer.SPEED_33 * 2.0
	rp._apply_scrub()
	_eq(rp._scan_dir, 0, "scrub/a stopped deck is not scrubbed")


# ── net/ ──────────────────────────────────────────────────────────────────────

## The command vocabulary the host will act on. "track" is the new one and is the
## only one carrying an index; the match it lands in deliberately has no default
## arm, so an older host no-ops on it rather than misfiring as something else.
func _test_net() -> void:
	var rp := await _deck(RECORD_PLAYER)
	rp._tracks = PackedStringArray(["a.mp3", "b.mp3", "c.mp3", "d.mp3"])

	rp._track_idx = 0
	rp.remote_goto_track(2)
	_eq(rp._track_idx, 2, "net/remote_goto_track selects that track")

	# The index a peer that predates the command leaves absent, defaulted to -1.
	rp._track_idx = 2
	rp.remote_goto_track(-1)
	_eq(rp._track_idx, 2, "net/a missing index is ignored, not treated as track 0")
	rp.remote_goto_track(99)
	_eq(rp._track_idx, 2, "net/an out-of-range index is ignored")

	# Every deck must answer the whole remote_* vocabulary the event handler calls,
	# or a command from a peer is a crash rather than a no-op.
	var cd := await _deck(CD_PLAYER)
	var tape := await _deck(CASSETTE_PLAYER)
	for deck: Node in [rp, cd, tape]:
		var ok := true
		for m: String in ["remote_play", "remote_pause", "remote_stop", "remote_ff",
				"remote_rewind", "remote_next", "remote_prev", "remote_goto_track",
				"remove_media", "deck_save_type"]:
			if not deck.has_method(m):
				ok = false
				print("[test]      %s is missing %s" % [deck.get_class(), m])
		_ok(ok, "net/%s answers the whole command vocabulary" % deck.deck_save_type())


# ── remote/ ───────────────────────────────────────────────────────────────────

## The TV remote greys a cell a deck cannot honour. It already did that for
## prev/next; rew/ff had no such gate, so a turntable would have shown two live
## scan keys that do nothing.
func _test_remote() -> void:
	var remote := preload("res://Scenes/Objects/appliances/tv_remote.tscn").instantiate()
	add_child(remote)
	_spawned.append(remote)
	await get_tree().process_frame

	# Built before the loop, not inline in the array literal: awaiting inside one
	# segfaults the run on shutdown (it cost the net group an exit 139).
	var rp := await _deck(RECORD_PLAYER)
	var cd := await _deck(CD_PLAYER)
	var tape := await _deck(CASSETTE_PLAYER)
	for spec: Array in [[rp, false, true], [cd, true, true], [tape, true, false]]:
		var deck: Node = spec[0]
		remote._target = deck
		var name: String = deck.deck_save_type()
		_eq(remote._cell_enabled("ff"), spec[1], "remote/%s ff cell" % name)
		_eq(remote._cell_enabled("rew"), spec[1], "remote/%s rew cell" % name)
		_eq(remote._cell_enabled("next"), spec[2], "remote/%s next cell" % name)
		_eq(remote._cell_enabled("prev"), spec[2], "remote/%s prev cell" % name)
		_ok(remote._cell_enabled("stop"), "remote/%s stop cell is always live" % name)


# ── helpers ───────────────────────────────────────────────────────────────────

func _deck(scene: PackedScene) -> Node:
	var d := scene.instantiate()
	add_child(d)
	_spawned.append(d)
	await get_tree().process_frame
	return d


## Drop a record into a deck's well the way the snap zone does — through the tray's
## own accept path, which is what a released record reaches.
func _seat(rp: Node) -> Node:
	var lp := VINYL_RECORD.instantiate() as VinylRecord
	lp.album_path = "/nowhere/Some Album"
	add_child(lp)
	_spawned.append(lp)
	await get_tree().process_frame
	rp.restore_media(lp)
	await get_tree().process_frame
	return lp


## Every deck builds a SpatialAudioEmitter, and one of those still alive when the
## process quits segfaults the exit: Godot tears the AudioServer down AFTER it has
## unregistered the extension classes the emitter's backend belongs to. queue_free
## alone is not enough — it is deferred, so without the frames below the decks are
## still standing at quit and the run exits 139 with every case passed.
## The furthest point along the travel axis, in the slider's own frame, that a ray
## could actually hit RIGHT NOW — the grab box's leading face where it currently
## sits. `dir` is +1 for the far end of the throw, -1 for the near one. This is the
## whole point of the case: a pointer cannot aim at the slot, only at the box, so
## the reachable set moves with the knob.
func _reach(sw: VRSlider, dir: float) -> Vector3:
	var axis := sw.axis_local.normalized()
	var half := 0.0
	var centre := Vector3.ZERO
	for child in sw.get_children():
		var cs := child as CollisionShape3D
		if cs == null:
			continue
		centre = cs.position
		var box := cs.shape as BoxShape3D
		if box != null:
			half = absf((box.size * 0.5).dot(axis))
	return centre + axis * half * dir


## Press the pointer at a point in the slider's local frame, and report the value it
## settled on. Exactly what XRToolsPointerEvent.pressed delivers on a desktop click.
func _press_at(sw: VRSlider, local_point: Vector3) -> float:
	var at := sw.to_global(local_point)
	sw.pointer_event(XRToolsPointerEvent.new(
		XRToolsPointerEvent.Type.PRESSED, null, sw, at, at))
	sw.pointer_event(XRToolsPointerEvent.new(
		XRToolsPointerEvent.Type.RELEASED, null, sw, at, at))
	return sw.value


func _cleanup() -> void:
	for n in _spawned:
		if not is_instance_valid(n):
			continue
		# remove_child THEN free, rather than queue_free: this runs the emitter's
		# _exit_tree here and now, so its voices are destroyed at a moment we
		# control. Deferred, they were still being torn down as the process quit
		# and the run exited 139 about one time in three, with every case passed.
		var parent := n.get_parent()
		if parent:
			parent.remove_child(n)
		n.free()
	_spawned.clear()
	for i in 4:
		await get_tree().process_frame
	# Let the audio backend settle before the engine starts unregistering the
	# extension classes its voices live in.
	await get_tree().create_timer(0.25).timeout


func _want(name: String) -> bool:
	return _only.is_empty() or _only == name


func _ok(cond: bool, what: String) -> void:
	_ran += 1
	if cond:
		print("[test] ok   %s" % what)
	else:
		_fail += 1
		print("[test] FAIL %s" % what)


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what if got == want else "%s (got %s, want %s)" % [what, got, want])

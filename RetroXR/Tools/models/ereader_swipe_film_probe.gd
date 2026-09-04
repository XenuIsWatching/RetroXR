## Films a dotcode card being slid through the e-Reader's groove, with the
## reader seated in a Game Boy Advance.
##
##     "$godot" --path RetroXR --resolution 960x720 --position 20,20 \
##         res://Tools/models/ereader_swipe_film_probe.tscn -- --out=C:/path/to/frames
##
## Windowed, never --headless: the dummy renderer draws nothing, and nothing is
## exactly what a film of it would contain.
##
## The card is carried by a real grab rather than teleported, so CardSwipeSlit
## sees what it sees in the room -- a held body crossing the groove -- and the
## swiped/aborted signals in the log are the real ones. A miming probe would show
## the same picture and prove nothing.
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const EXPANSION_SCENE := preload("res://Scenes/Objects/expansion.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")

const STAGE := Vector3(0, 1.0, 0)


## The hand. XRToolsPickable.pick_up reads exactly one property off whatever is
## doing the grabbing, so this is all a stand-in needs to be a real grab: the
## grab driver then carries the card from this node the way a controller would.
class FakeHand:
	extends Node3D

	var picked_up_ranged := false

var out_dir := ""
var _shot := 0
var _cam: Camera3D
var _swipes: Array[String] = []
var _aborts := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--out="):
			out_dir = String(a).trim_prefix("--out=")
	if out_dir.is_empty():
		push_error("need --out=<dir>")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	_stage()
	await _film()
	print("[film] wrote %d frames to %s" % [_shot, out_dir])
	print("[film] swipes=%s aborts=%d" % [str(_swipes), _aborts])
	get_tree().quit(0)


func _stage() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.10, 0.13)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.52, 0.58)
	e.ambient_light_energy = 0.55
	env.environment = e
	add_child(env)

	var key := DirectionalLight3D.new()
	key.light_energy = 1.5
	key.rotation_degrees = Vector3(-42, 38, 0)
	key.shadow_enabled = true
	add_child(key)

	# The boot overlay is an autoload and owns a panel right in front of the
	# default camera, so a film taken without dismissing it is a film of a
	# progress bar.
	var overlay: Node = get_node_or_null("/root/LoadingOverlay")
	if overlay != null:
		for o: Variant in overlay.call("owners"):
			overlay.call("end", o)

	# The window's own viewport, the way expansion_film_probe does it. A
	# SubViewport sharing the main world films that same panel instead.
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true
	_look_from(STAGE + Vector3(0.30, 0.20, 0.34))


var _focus := STAGE


func _look_from(pos: Vector3) -> void:
	_cam.global_position = pos
	_cam.look_at(_focus)


func _wait(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _grab() -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/f%04d.png" % [out_dir, _shot])
	_shot += 1


func _hold(n: int) -> void:
	for i in n:
		await _wait(1)
		await _grab()


func _film() -> void:
	# The reader IS a cartridge: it goes into the handheld's own slot.
	var unit := EXPANSION_SCENE.instantiate() as RetroExpansion
	unit.expansion_id = "ereader"
	unit.freeze = true
	add_child(unit)
	unit.global_position = STAGE
	await _wait(30)

	var host := SYSTEM_SCENE.instantiate() as RetroSystem
	host.systemid = "game_boy_advance"
	host.freeze = true
	add_child(host)
	host.global_position = STAGE + Vector3(0.34, -0.22, 0.0)
	await _wait(30)
	await _hold(10)
	host.restore_expansion(unit)
	await _wait(8)
	await _hold(16)

	var slit := unit.get_node_or_null("SwipeSlit") as CardSwipeSlit
	if slit == null:
		push_error("no SwipeSlit on the unit")
		return
	slit.swiped.connect(func(_c: Node3D, edge: String, strip: int) -> void:
		_swipes.append("%s:%d" % [edge, strip]))
	slit.aborted.connect(func(_c: Node3D) -> void: _aborts += 1)

	# A real card out of the library, so its shape and strips are the real ones.
	var cards := EReaderCards.cards()
	var card_data := {}
	for c: Dictionary in cards:
		if str(c["shape"]) == EReaderCards.SHAPE_LONG_SHORT:
			card_data = c
			break
	var media := CART_SCENE.instantiate() as RetroCartridge
	media.systemid = EReaderCards.SYSTEMID
	if not card_data.is_empty():
		var strips: Array = card_data["strips"]
		media.rom_path = str((strips[0] as Dictionary)["path"])
		media.game_label = str(card_data["label"])
	media.freeze = true
	add_child(media)
	await _wait(20)

	# The hand. pick_up drives the card from this node, which is what puts a
	# real grab under the swipe instead of a teleport.
	var hand := FakeHand.new()
	add_child(hand)
	var groove := slit.global_position
	var stand: float = media.get_card_size().y * 0.5
	var travel: float = slit.travel

	# Frame the groove itself, close. The machine is 90 mm across.
	_focus = groove
	_look_from(groove + Vector3(0.10, 0.10, 0.20))

	# Square to the groove and printed side towards the reader. A dotcode is on
	# one face, so a card carried in the other way round reads nothing -- correct,
	# but not what this film is meant to show.
	# Everything below is in the GROOVE's frame, not the world's: the reader is
	# seated in the handheld and carries its rotation, so a path laid out on
	# world axes runs across the slot rather than along it.
	hand.global_transform = Transform3D(slit.global_transform.basis,
		slit.global_transform * Vector3(-travel * 0.80, stand + 0.05, 0.0))
	media.global_transform = hand.global_transform
	await _wait(6)
	if media.has_method("pick_up"):
		media.pick_up(hand)
	await _wait(8)
	print("[film] card held: %s" % media.is_picked_up())
	# The grab driver places the card by its grab point, not its origin, so the
	# card sits at a fixed offset from the hand. Measure it once and aim the hand
	# so the CARD lands where the groove is, or the swipe misses by that offset.
	var lead := media.global_position - hand.global_position
	print("[film] card lags hand by %s" % lead)
	print("[film] groove=%s card=%s stand=%.4f travel=%.4f" % [groove, media.global_position, stand, travel])
	var shape := slit.get_child(0) as CollisionShape3D
	if shape != null:
		print("[film] slit box=%s at %s" % [(shape.shape as BoxShape3D).size, shape.global_position])
	var aabb := media.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if aabb != null:
		print("[film] card aabb=%s" % aabb.get_aabb())
	await _hold(10)

	# Down to the groove, then through it and out the far side.
	var g := slit.global_transform
	await _card_to(hand, lead, g * Vector3(-travel * 0.66, stand, 0.0), 14)
	await _hold(6)
	await _card_to(hand, lead, g * Vector3(travel * 0.66, stand, 0.0), 48)
	await _hold(10)
	await _card_to(hand, lead, g * Vector3(travel * 0.80, stand + 0.06, 0.0), 12)
	await _hold(16)

	# Once round the assembled machine, so the reader in the handheld reads.
	for i in range(36):
		var a: float = lerp(0.0, TAU * 0.5, float(i) / 35.0)
		_look_from(groove + Vector3(cos(a + 0.5) * 0.22, 0.11, sin(a + 0.5) * 0.22))
		await _wait(1)
		await _grab()


## Move the hand so the CARD reaches `to`, filming every step.
func _card_to(hand: Node3D, lead: Vector3, to: Vector3, steps: int) -> void:
	var from := hand.global_position
	var target := to - lead
	for i in range(1, steps + 1):
		hand.global_position = from.lerp(target, float(i) / float(steps))
		await _wait(1)
		await _grab()

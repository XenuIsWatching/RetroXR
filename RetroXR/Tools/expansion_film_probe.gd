## Films a console being bolted to an expansion and loaded with media.
##
## Not a test — expansion_tests.gd already proves the joins hold. This exists to
## SHOW one: a Nintendo 64 lowered onto a 64DD, a cartridge into the console, a
## disk into the drive underneath, captured frame by frame so it can be watched
## rather than read off a pass list.
##
##     "$godot" --path RetroXR --resolution 960x720 --position 20,20 \
##         res://Tools/expansion_film_probe.tscn -- --out=C:/path/to/frames
##
## Windowed, never --headless: the dummy renderer draws nothing, and nothing is
## exactly what a film of it would contain.
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const EXPANSION_SCENE := preload("res://Scenes/Objects/expansion.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")

## Where the hardware sits. Everything else is framed around this.
const STAGE := Vector3(0, 1.0, 0)

var out_dir := ""
var _shot := 0
var _cam: Camera3D


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--out="):
			out_dir = String(a).trim_prefix("--out=")
	if out_dir.is_empty():
		push_error("need --out=<dir>")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	_light()
	await _film()
	print("[film] wrote %d frames to %s" % [_shot, out_dir])
	get_tree().quit(0)


## Plain three-point-ish lighting and a mid-grey void. The room's own
## environment is a bedroom; this wants the hardware legible, not dressed.
func _light() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.17, 0.20)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.52, 0.58)
	env.ambient_light_energy = 0.9
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, -38, 0)
	key.light_energy = 1.5
	add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, 130, 0)
	fill.light_energy = 0.5
	add_child(fill)

	_cam = Camera3D.new()
	add_child(_cam)
	_look_from(Vector3(0.62, 1.34, 0.62))


func _look_from(pos: Vector3) -> void:
	_cam.position = pos
	_cam.look_at(STAGE, Vector3.UP)


func _wait(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## One frame to disk. Captured after the draw, or the image is whatever the
## viewport happened to hold last.
func _grab() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/f%04d.png" % [out_dir, _shot])
	_shot += 1


## Hold the shot for `n` frames so the moment is readable at speed.
func _hold(n: int) -> void:
	for i in n:
		await _wait(1)
		await _grab()


## Carry `what` to `to` over `steps`, filming every step. The physical join is
## made by the snap zone at the end; this is the approach, which is the part
## worth seeing.
func _carry(what: Node3D, to: Vector3, steps: int) -> void:
	var from := what.global_position
	for i in range(1, steps + 1):
		what.global_position = from.lerp(to, float(i) / float(steps))
		await _wait(1)
		await _grab()


func _film() -> void:
	# The drive first, alone on the stage: it is the base the console stands on.
	var dd := EXPANSION_SCENE.instantiate() as RetroExpansion
	dd.expansion_id = "nintendo_64dd"
	dd.freeze = true
	add_child(dd)
	dd.global_position = STAGE
	await _wait(20)
	await _hold(20)

	# The console, brought in from the side and lowered onto it.
	var n64 := SYSTEM_SCENE.instantiate() as RetroSystem
	n64.systemid = "nintendo_64"
	n64.freeze = true
	add_child(n64)
	n64.global_position = STAGE + Vector3(0.42, 0.30, 0.0)
	await _wait(30)
	await _hold(12)
	await _carry(n64, STAGE + Vector3(0.0, 0.16, 0.0), 26)

	# The join itself. pick_up_object is what a release into the socket ends in,
	# so the console seats exactly where a hand would have put it.
	# Unfrozen for the join: a snap zone poses what it picks up by moving the
	# body, and a frozen one simply stays where it was left.
	# Unfrozen for the join, as a carried machine would be.
	n64.freeze = false
	dd.get_socket().pick_up_object(n64)
	await _wait(6)
	print("[film] seated: gap=%.4f (0 = flush)" % [
		(n64.global_position.y + n64._body_aabb().position.y)
		- (dd.global_position.y + dd.size().y * 0.5)])
	await _hold(26)

	# A cartridge into the console on top.
	var cart := CART_SCENE.instantiate() as Node3D
	cart.systemid = "nintendo_64"
	cart.rom_path = "Z:/roms/n64/F-Zero X (Japan).z64"
	cart.freeze = true
	add_child(cart)
	cart.global_position = n64.global_position + Vector3(0.0, 0.34, -0.02)
	await _wait(20)
	await _hold(12)
	await _carry(cart, n64.global_position + Vector3(0.0, 0.10, -0.02), 20)
	n64.restore_cartridge(cart)
	await _wait(6)
	await _hold(24)

	# And a disk into the drive underneath — the half the console has no slot for.
	var disk := CART_SCENE.instantiate() as Node3D
	disk.systemid = "nintendo_64dd"
	disk.rom_path = "Z:/roms/n64dd/F-Zero X - Expansion Kit (Japan).ndd"
	disk.freeze = true
	add_child(disk)
	disk.global_position = dd.global_position + Vector3(0.34, 0.02, 0.16)
	await _wait(20)
	await _hold(12)
	await _carry(disk, dd.global_position + Vector3(0.02, 0.0, 0.10), 20)
	dd.restore_media(disk)
	await _wait(6)
	await _hold(20)

	# Round the assembled machine, so both halves and both pieces of media are
	# visible in one move.
	for i in range(56):
		var a: float = lerp(0.0, TAU * 0.5, float(i) / 55.0)
		_look_from(STAGE + Vector3(cos(a + 0.8) * 0.78, 0.34, sin(a + 0.8) * 0.78))
		await _wait(1)
		await _grab()

	print("[film] stack=%s core=%s" % [str(n64.expansion_ids()), n64.resolve_core_name()])
	await _hold(16)

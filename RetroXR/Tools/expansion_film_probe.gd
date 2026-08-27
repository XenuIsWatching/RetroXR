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


## Every combination the catalog knows, each with a piece of its own media.
## Paths are only labels here -- nothing is launched, so a file that is not
## present still shows the shape of the media going in.
const REEL := [
	{"host": "nintendo_64",  "unit": "nintendo_64dd", "media": "nintendo_64dd"},
	{"host": "nes",          "unit": "fds",           "media": "fds"},
	{"host": "super_nes",    "unit": "satellaview",   "media": "satellaview"},
	{"host": "super_nes",    "unit": "sufami_turbo",  "media": "sufami_turbo"},
	{"host": "mega_drive",   "unit": "sega_cd",       "media": "sega_cd"},
	{"host": "mega_drive",   "unit": "sega_32x",      "media": "sega_32x"},
	{"host": "pc_engine",    "unit": "pc_engine_cd",  "media": "pc_engine_cd"},
	{"host": "atari_jaguar", "unit": "jaguar_cd",     "media": "atari_jaguar"},
]


func _film() -> void:
	for entry: Dictionary in REEL:
		await _one(str(entry["host"]), str(entry["unit"]), str(entry["media"]))


## One machine: assemble it, load it, look around it, take it away again.
func _one(host_id: String, unit_id: String, media_id: String) -> void:
	var unit := EXPANSION_SCENE.instantiate() as RetroExpansion
	unit.expansion_id = unit_id
	unit.freeze = true
	add_child(unit)
	unit.global_position = STAGE
	await _wait(24)

	var host := SYSTEM_SCENE.instantiate() as RetroSystem
	host.systemid = host_id
	host.freeze = true
	add_child(host)
	# Brought in from the side, then lowered on -- whichever way this pair
	# stacks, restore_expansion takes both directions.
	var above := ExpansionCatalog.mount_of(unit_id) == ExpansionCatalog.MOUNT_ABOVE
	host.global_position = STAGE + (Vector3(0.42, -0.24, 0.0) if above else Vector3(0.42, 0.30, 0.0))
	await _wait(30)
	await _hold(10)
	await _carry(host, STAGE + (Vector3(0.0, -0.16, 0.0) if above else Vector3(0.0, 0.16, 0.0)), 20)
	# Left frozen. Whichever of the two gets picked up is frozen by the pickup
	# itself; unfreezing the console meant that for a unit which mounts ABOVE it
	# -- where the UNIT is the thing taken -- nothing held the console at all and
	# it fell out of shot.
	host.restore_expansion(unit)
	await _wait(6)
	await _hold(18)

	# The media the unit itself takes -- a disk, a disc, a pack, a cartridge.
	var media := CART_SCENE.instantiate() as Node3D
	media.systemid = media_id
	media.rom_path = "Z:/roms/%s/demo" % media_id
	media.freeze = true
	add_child(media)
	var bay := unit.global_position + Vector3(0.30, 0.10, 0.22)
	media.global_position = bay
	await _wait(18)
	await _hold(10)
	await _carry(media, unit.global_position + Vector3(0.0, 0.02, 0.14), 18)
	unit.restore_media(media)
	await _wait(6)
	await _hold(22)

	# Once round the assembled machine.
	for i in range(40):
		var a: float = lerp(0.0, TAU * 0.45, float(i) / 39.0)
		_look_from(STAGE + Vector3(cos(a + 0.7) * 0.80, 0.30, sin(a + 0.7) * 0.80))
		await _wait(1)
		await _grab()
	_look_from(Vector3(0.62, 1.34, 0.62))

	print("[film] %s + %s -> %s" % [host_id, unit_id, host.resolve_core_name()])
	for n in [media, host, unit]:
		if is_instance_valid(n):
			n.queue_free()
	await _wait(12)

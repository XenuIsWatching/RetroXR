## Does the last machine's picture survive a source change or a reset?
##
## The CRT's phosphor accumulator ping-pongs between two SubViewports and blends
## each new frame with what it already holds. Nothing cleared it, so the decayed
## image of the PREVIOUS source came back — visibly — whenever a new one started.
##
## Two solid colours make it measurable: fill the accumulator with RED, switch to a
## GREEN source, and read the red still on the glass.
##
##   godot --path RetroXR --resolution 480x360 --position 20,20 \
##     res://Tools/av/phosphor_ghost_probe.tscn
## Windowed: a SubViewport renders nothing under the dummy driver.
extends Node3D

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")

var _sv: SubViewport = null
var _tv: RetroTV = null


class StubSource extends Node3D:
	var texture: Texture2D = null
	func get_video_texture() -> Texture2D:
		return texture
	func set_audio_volume(_v: float) -> void:
		pass


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[ghost] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _solid(c: Color) -> Texture2D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)


func _run() -> void:
	print("[ghost] starting")
	_sv = SubViewport.new()
	_sv.size = Vector2i(480, 360)
	_sv.own_world_3d = true
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0, 0, 0, 1)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.4
	env.environment = e
	_sv.add_child(env)

	_tv = TV_SCENE.instantiate() as RetroTV
	_tv.position = Vector3(0, 1, 0)
	_tv.freeze = true
	_sv.add_child(_tv)
	_tv.add_to_group("spawned")
	await _wait(40)
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.0, 0.42)
	cam.fov = 40.0
	_sv.add_child(cam)
	cam.current = true

	print("[ghost] built the set; persistence=%.2f crt=%s" % [
		float(_tv.get_crt_params().get("crt_persistence", 0.0)), _tv.crt_enabled])

	var red := StubSource.new()
	red.texture = _solid(Color(1, 0, 0, 1))
	var green := StubSource.new()
	green.texture = _solid(Color(0, 1, 0, 1))
	add_child(red)
	add_child(green)
	_tv._panel._connected_systems[RetroTV.Source.COMPOSITE_1] = red
	_tv._panel._connected_systems[RetroTV.Source.COMPOSITE_2] = green
	_tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(45)          # let the accumulator saturate red
	print("[ghost] on the red source:   %s" % await _screen())

	# 1. Switch inputs. The green machine's picture must not arrive tinted by the
	#    red one's afterglow.
	_tv.set_source(RetroTV.Source.COMPOSITE_2)
	for f in [1, 2, 4, 8]:
		await _wait(f if f == 1 else f / 2)
		print("[ghost] %d frame(s) after the switch: %s" % [f, await _screen()])

	# 2. A reset: the source stops offering a picture, then offers a new one. This
	#    is what "press RESET and the last machine flashes up" was.
	await _wait(20)
	green.texture = null
	await _wait(12)
	print("[ghost] while it is restarting: %s" % await _screen())
	green.texture = _solid(Color(0, 0, 1, 1))     # comes back BLUE, a third colour
	await _wait(2)
	print("[ghost] 2 frames after restart:  %s" % await _screen())
	await _wait(6)
	print("[ghost] 8 frames after restart:  %s" % await _screen())
	DirAccess.make_dir_recursive_absolute("res://probe_out")
	_sv.get_texture().get_image().save_png("res://probe_out/ghost.png")
	get_tree().quit(0)


## The average colour of the middle of the glass.
func _screen() -> String:
	await RenderingServer.frame_post_draw
	var img := _sv.get_texture().get_image()
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0
	for y in range(img.get_height() / 3, img.get_height() * 2 / 3, 3):
		for x in range(img.get_width() / 3, img.get_width() * 2 / 3, 3):
			var c := img.get_pixel(x, y)
			r += c.r
			g += c.g
			b += c.b
			n += 1
	return "R=%.3f G=%.3f B=%.3f" % [r / n, g / n, b / n]


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame

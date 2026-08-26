extends Node

## What the loading screen actually LOOKS like over a room that is really there.
##
##   godot --path RetroXR --resolution 960x720 --position 20,20 \
##       res://Tools/loading_screen_probe.tscn
##
## Windowed, not --headless: the dummy renderer returns a blank image, so nothing
## here can be checked without a display. That is the point — the headless suite
## (Tests/loading_overlay_tests.tscn) proves the bookkeeping, and this proves the
## one thing an assertion cannot, which is whether the curtain really hides the
## room behind it.
##
## The furniture is deliberate. A curtain is easy to get right against an empty
## world and easy to get WRONG against near geometry: a wall about a metre away
## and a box well inside arm's reach are the two cases where depth sorting, not
## distance, decides what the player sees. Both are placed in front of the camera
## on purpose.
##
## Frames land in res://probe_out/loading/ (gitignored).

const OUT_DIR := "res://probe_out/loading"
const SIZE := Vector2i(960, 720)
## Frames per state. At 15 fps this reads as roughly a second each.
const FRAMES := 15

var _sv: SubViewport = null
var _panel: LoadingPanel = null
var _cam: Camera3D = null
var _n := 0


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_build()
	await _run()
	print("[probe] wrote %d frames to %s" % [_n, OUT_DIR])
	get_tree().quit(0)


func _build() -> void:
	_sv = SubViewport.new()
	_sv.size = SIZE
	_sv.own_world_3d = true
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.14)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.8, 0.9)
	e.ambient_light_energy = 0.6
	env.environment = e
	_sv.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 35, 0)
	_sv.add_child(sun)

	# A wall at ~1.2 m and a box at ~0.4 m: near geometry is what breaks a
	# curtain that relies on being closer than the room rather than on depth
	# state, so the probe has to contain some.
	_slab(Vector3(0, 1.5, -1.2), Vector3(6, 3, 0.1), Color(0.55, 0.42, 0.34))
	_slab(Vector3(0, 0.0, -1.0), Vector3(6, 0.1, 4), Color(0.32, 0.30, 0.28))
	_slab(Vector3(0.35, 1.35, -0.4), Vector3(0.22, 0.22, 0.22), Color(0.85, 0.25, 0.2))
	_slab(Vector3(-0.5, 1.1, -0.9), Vector3(0.5, 0.35, 0.3), Color(0.2, 0.5, 0.85))

	_cam = Camera3D.new()
	_cam.position = Vector3(0, 1.6, 0)
	_sv.add_child(_cam)
	_cam.current = true

	_panel = preload("res://Scenes/UI/loading_panel.tscn").instantiate()
	_sv.add_child(_panel)
	# The panel sits at the head, like it does on a player: its own geometry is
	# authored ~10 m out in front of that.
	_panel.position = Vector3(0, 1.6, 0)


func _slab(at: Vector3, size: Vector3, colour: Color) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	box.material = mat
	mi.mesh = box
	mi.position = at
	_sv.add_child(mi)


func _run() -> void:
	# The room on its own, so the footage shows what is being covered.
	_panel.visible = false
	await _shoot(FRAMES, "the room, uncovered")
	_panel.visible = true

	_panel.set_title("STARTING UP")
	for i in FRAMES:
		_panel.set_progress(float(i) / float(FRAMES - 1) * 0.45)
		_panel.set_status("WARMING STAND-INS  %d / %d" % [i + 1, FRAMES])
		await _shoot(1, "")
	print("[probe] boot warm")

	for i in FRAMES:
		_panel.set_progress(0.45 + float(i) / float(FRAMES - 1) * 0.5)
		_panel.set_status("RESTORING OBJECTS  %d / 31" % (i * 2 + 1))
		await _shoot(1, "")
	print("[probe] slot restore")

	_panel.set_title("JOINING ROOM")
	for i in FRAMES:
		var got := float(i) / float(FRAMES - 1) * 4.0
		_panel.set_status("RECEIVING WORLD")
		_panel.set_detail(PackedStringArray([
			"RECEIVING STATE  %.1f / 4.0 MB" % got]))
		await _shoot(1, "")
	print("[probe] netplay join")

	_panel.set_detail(PackedStringArray())
	_panel.show_load_error("RETRY OR CHOOSE ANOTHER ROOM")
	await _shoot(FRAMES, "load failed")

	# Down again: nothing of the panel may survive, or the room is left with a
	# quad hanging in it.
	_panel.queue_free()
	await get_tree().process_frame
	await _shoot(FRAMES, "the room, uncovered again")
	var leftovers := _sv.find_children("*", "LoadingPanel", true, false)
	print("[probe] panels left in the world after teardown: %d" % leftovers.size())


func _shoot(count: int, label: String) -> void:
	if not label.is_empty():
		print("[probe] %s" % label)
	for _i in count:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		_sv.get_texture().get_image().save_png("%s/f%04d.png" % [OUT_DIR, _n])
		_n += 1

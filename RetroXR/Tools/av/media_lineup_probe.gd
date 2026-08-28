extends Node3D

## Every cartridge and every disc, spawned through the real spawn path and laid
## out on a grid so their SIZES can be compared against each other at a glance.
##
## Windowed, not --headless — the dummy renderer returns a blank image:
##   godot --path RetroXR --resolution 1600x1000 --position 20,20 res://Tools/av/media_lineup_probe.tscn
## PNG lands in res://probe_out/media_lineup.png (gitignored).

const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")
const DISC_SCENE := preload("res://Scenes/Objects/media/disc.tscn")
const UMD_SCENE  := preload("res://Scenes/Objects/media/umd_disc.tscn")

const COLS := 6
const PITCH := Vector3(0.165, 0.0, 0.175)

var _sv: SubViewport = null


func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func(): get_tree().quit(1))
	await _build()


func _build() -> void:
	_sv = SubViewport.new()
	_sv.size = Vector2i(1600, 1000)
	_sv.own_world_3d = true
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.17, 0.20)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.85, 0.87, 0.92)
	e.ambient_light_energy = 0.85
	env.environment = e
	_sv.add_child(env)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	key.light_energy = 1.5
	_sv.add_child(key)

	# Cartridges first, in the table's own order, then the discs.
	var carts: Array = MediaDimensions.CART_SIZES.keys()
	var discs: Array = MediaDimensions.DISC_DIAMETERS.keys()

	var i := 0
	for sid: String in carts:
		# The PSP is a UMD caddy, not a cart — it comes in with the discs.
		if sid == "playstation_portable":
			continue
		_place(_spawn_for(sid), sid, i, MediaDimensions.cart_size(sid))
		i += 1
	# One tile for the floppy, standing for all seventeen systems in
	# MediaDimensions.FLOPPY_SYSTEMS: they share FLOPPY_SIZE exactly, and this
	# image exists to compare SIZES, so seventeen identical squares would only
	# shrink every other item to fit them in.
	var floppy: String = str(MediaDimensions.FLOPPY_SYSTEMS.keys()[0])
	_place(_spawn_for(floppy), "3.5in floppy", i, MediaDimensions.FLOPPY_SIZE)
	i += 1
	# Start the disc row on a fresh line so the two families read apart.
	i += (COLS - (i % COLS)) % COLS
	for sid: String in discs:
		var d := MediaDimensions.disc_diameter(sid)
		# 1.2 mm is the real disc thickness the baked platter carries; the caption
		# is a hand-written constant, so it has to be kept in step with gen_disc.gd.
		var sz := Vector3(d, d, 0.0012)
		_place(_spawn_for(sid), sid, i, sz)
		i += 1

	# Straight down: a plan view is the only framing where every footprint is
	# measurable against every other one. Ortho, so nothing is foreshortened and
	# two carts the same width MEASURE the same width on the image.
	var rows := int(ceil(float(i) / float(COLS)))
	# The size caption hangs below each item, so the bottom margin is the deeper one.
	var need_w := (COLS - 1) * PITCH.x + 0.16
	var need_h := (rows - 1) * PITCH.z + 0.26
	var aspect := float(_sv.size.x) / float(_sv.size.y)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.size = maxf(need_h, need_w / aspect)
	cam.position = Vector3((COLS - 1) * PITCH.x * 0.5, 1.2, (rows - 1) * PITCH.z * 0.5 + 0.03)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.near = 0.05
	_sv.add_child(cam)
	cam.current = true

	for f in range(12):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame

	DirAccess.make_dir_recursive_absolute("res://probe_out")
	var img := _sv.get_texture().get_image()
	img.save_png("res://probe_out/media_lineup.png")
	print("[media] %d items rendered -> probe_out/media_lineup.png" % i)
	get_tree().quit(0)


## Exactly what SpawnMenuController._on_spawn_cartridge_requested does.
func _spawn_for(systemid: String) -> RetroCartridge:
	var scene := CART_SCENE
	if MediaDimensions.is_disc_system(systemid):
		scene = UMD_SCENE if systemid == "playstation_portable" else DISC_SCENE
	var m := scene.instantiate() as RetroCartridge
	m.systemid = systemid
	m.game_label = systemid
	return m


func _place(m: RetroCartridge, sid: String, idx: int, sz: Vector3) -> void:
	m.freeze = true
	m.position = Vector3(float(idx % COLS) * PITCH.x, 0.0, float(idx / COLS) * PITCH.z)
	# A cartridge stands upright — body up +Y, label facing +Z — so a plan view
	# sees only its top edge. Tip it onto its back so its LABEL faces the camera
	# and its footprint is what the image measures. Discs already lie flat.
	if not MediaDimensions.is_disc_system(sid):
		m.rotation_degrees.x = -90.0
	_sv.add_child(m)

	var tag := Label3D.new()
	tag.text = "%s\n%.0f x %.0f x %.1f mm" % [sid, sz.x * 1000.0, sz.y * 1000.0, sz.z * 1000.0]
	tag.font_size = 28
	tag.outline_size = 10
	tag.pixel_size = 0.00055
	tag.modulate = Color(1, 1, 1)
	tag.outline_modulate = Color(0, 0, 0)
	tag.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	tag.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	tag.position = m.position + Vector3(0.0, 0.05, PITCH.z * 0.42)
	_sv.add_child(tag)

extends Node3D

## The SNES Mouse, plugged into a Super NES, with its buttons clicking.
##
## Windowed, not --headless — the dummy renderer returns a blank image:
##   godot --path RetroXR --resolution 320x240 --position 20,20 res://Tools/input/snes_mouse_probe.tscn
## Frames land in res://probe_out/snes_mouse/ (gitignored); encode at 24 fps.
##
## The SubViewport deliberately does NOT own its world: cables parent themselves
## to the current scene, which in a probe is this node, so an owned world would
## render the mouse with no lead at all — the one thing this is meant to show.
##
## Buttons are driven by feeding real InputEventMouseButtons to the Input
## singleton, so the shell moves through _poll_buttons() exactly as it does in
## play. Poking _animate_buttons() directly would prove only that the animation
## code runs, not that it is connected to anything.

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const SNES_MOUSE_SCENE := preload("res://Scenes/Objects/peripherals/snes_mouse.tscn")
const RETRO_MOUSE_SCENE := preload("res://Scenes/Objects/peripherals/retro_mouse.tscn")

const OUT_DIR := "res://probe_out/snes_mouse"
const FPS := 24
const FRAMES := 240
const VIEW := Vector2i(900, 675)

# frame -> (left, right) held. Anything before the first entry is at rest.
const SCHEDULE: Array = [
	[96, true, false],
	[120, false, false],
	[132, false, true],
	[156, false, false],
	[168, true, true],
	[192, false, false],
]

var _sv: SubViewport = null
var _cam: Camera3D = null
var _sys: RetroSystem = null
var _mouse: SnesMouse = null
var _btn_state: Dictionary = {}
var _rest_y: float = 0.0
var _min_y: float = 1e9
var _max_y: float = -1e9


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func(): get_tree().quit(1))
	await _run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.13, 0.14, 0.17)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.80, 0.84, 0.92)
	e.ambient_light_energy = 0.35
	env.environment = e
	add_child(env)

	# The shell is near-white, so a key at play strength blows it flat and the
	# scribe lines between the buttons stop reading.
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	key.light_energy = 1.05
	key.shadow_enabled = true
	add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20.0, 140.0, 0.0)
	fill.light_energy = 0.35
	add_child(fill)

	_add_desk()

	# ── the console ─────────────────────────────────────────────────────────
	_sys = SYSTEM_SCENE.instantiate() as RetroSystem
	_sys.systemid = "super_nes"
	add_child(_sys)
	_sys.freeze = true
	_sys.global_position = Vector3(-0.28, 0.0, -0.10)
	await get_tree().process_frame
	await get_tree().process_frame

	# ── the mouse ───────────────────────────────────────────────────────────
	_mouse = SNES_MOUSE_SCENE.instantiate() as SnesMouse
	add_child(_mouse)
	_mouse.freeze = true
	_mouse.global_position = Vector3(0.16, 0.0, 0.06)
	_mouse.rotation.y = deg_to_rad(-18.0)
	# Two frames: the cable is added deferred, and _init_points runs after that.
	await get_tree().process_frame
	await get_tree().process_frame

	_report_ports()
	_plug_in()
	await get_tree().process_frame
	await get_tree().process_frame
	_report_connection()

	_mouse._desktop_held = true
	var lb: MeshInstance3D = _mouse._find_button("LeftButton")
	if lb == null:
		print("[probe] FAIL: LeftButton mesh not found under MouseVisual")
		return _finish(1)
	_rest_y = lb.transform.origin.y
	print("[probe] cached %d animated button(s)" % _mouse._anim_btns.size())

	# let the rope settle before the first frame is kept
	for i in range(40):
		await get_tree().process_frame

	_build_camera()
	await _verify_press()
	await _shoot(lb)
	_finish(0)


## Rest / left / right, from a camera that does NOT move, then diff them.
## The travel figure alone can't tell a button hinging DOWN from one lifting, and
## the video's camera drifts, so nothing there settles it either.
func _verify_press() -> void:
	# The rope never stops moving, and it crosses this framing. Left in, it
	# dominates the diff — 9.8% of the frame changed between two shots whose only
	# intended difference was a 1 mm button.
	var cable: Node3D = _mouse._cable_instance
	cable.visible = false
	_cam.global_position = _mouse.global_position \
		+ _mouse.global_transform.basis * Vector3(0.0, 0.135, -0.185)
	_cam.look_at(_mouse.global_position + _mouse.global_transform.basis * Vector3(0, 0.026, -0.024),
		Vector3.UP)
	var shots: Dictionary = {}
	for row: Array in [["rest", false, false], ["left", true, false], ["right", false, true]]:
		_inject(MOUSE_BUTTON_LEFT, bool(row[1]))
		_inject(MOUSE_BUTTON_RIGHT, bool(row[2]))
		for i in range(24):        # let the lerp finish settling
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := _sv.get_texture().get_image()
		img.save_png("%s/verify_%s.png" % [OUT_DIR, row[0]])
		shots[row[0]] = img
		print("[probe] %-5s left-button tip y = %+.5f m" % [row[0], _tip_y("LeftButton")])
	_diff(shots["rest"], shots["left"], "left")
	_diff(shots["rest"], shots["right"], "right")
	_inject(MOUSE_BUTTON_LEFT, false)
	_inject(MOUSE_BUTTON_RIGHT, false)
	cable.visible = true


## World height of a button's FRONT TIP — the end that should dip. The node's own
## origin is nowhere near it (the .glb shares one origin across every mesh), so
## watching transform.origin says nothing about which way the cap tilts.
func _tip_y(stem: String) -> float:
	var m := _mouse._find_button(stem)
	var ab: AABB = m.mesh.get_aabb()
	return (m.global_transform * Vector3(ab.get_center().x, ab.end.y, ab.position.z)).y


## Report WHERE the image changed. A press that moves the correct half of the
## shell shows a blob over that button; one that moves the whole model, or
## nothing, shows up here immediately.
func _diff(a: Image, b: Image, label: String) -> void:
	var w := a.get_width()
	var h := a.get_height()
	var n := 0
	var x0 := w; var x1 := -1; var y0 := h; var y1 := -1
	for y in range(h):
		for x in range(w):
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			if absf(pa.r - pb.r) + absf(pa.g - pb.g) + absf(pa.b - pb.b) > 0.02:
				n += 1
				x0 = mini(x0, x); x1 = maxi(x1, x)
				y0 = mini(y0, y); y1 = maxi(y1, y)
	if n == 0:
		print("[probe] DIFF %s: NO PIXELS CHANGED" % label)
		return
	print("[probe] DIFF %s: %d px (%.2f%%), box x %d..%d y %d..%d, centre x=%d (frame mid %d)"
		% [label, n, 100.0 * n / float(w * h), x0, x1, y0, y1, (x0 + x1) / 2, w / 2])


func _add_desk() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.4, 0.04, 1.6)
	shape.shape = box
	shape.position = Vector3(0, -0.02, 0)
	body.add_child(shape)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	mi.position = Vector3(0, -0.02, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.27, 0.24)
	mat.roughness = 0.85
	mi.material_override = mat
	body.add_child(mi)
	add_child(body)


func _report_ports() -> void:
	var zones: Array = _sys._port_zones
	print("[probe] system has %d port zone(s)" % zones.size())
	for i in range(zones.size()):
		var z = zones[i]
		print("[probe]   port %d enabled=%s at %s" % [i, z.enabled, z.global_position])
	# The systemid filter, asserted both ways on the SAME plug.
	var plug: ControllerPlug = _mouse._cable_plug
	print("[probe] plug systemid = '%s'" % plug.systemid)
	print("[probe] super_nes accepts it: %s (want true)" % _sys._accepts_plug(plug))
	var other := SYSTEM_SCENE.instantiate() as RetroSystem
	other.systemid = "nes"
	add_child(other)
	other.freeze = true
	other.global_position = Vector3(0, -5.0, 0)
	print("[probe] nes accepts it: %s (want false)" % other._accepts_plug(plug))
	# A generic mouse must still fit everything.
	var generic := RETRO_MOUSE_SCENE.instantiate() as RetroMouse
	add_child(generic)
	generic.global_position = Vector3(0, -5.0, 0.4)
	print("[probe] generic mouse systemid = '%s' -> nes accepts: %s (want true)"
		% [generic.systemid, other._accepts_plug(generic)])


func _plug_in() -> void:
	_mouse.restore_port_connection(_sys, 0)


func _report_connection() -> void:
	print("[probe] mouse._connected_system = %s port=%d device_type=%d (2 = RETRO_DEVICE_MOUSE)"
		% [_mouse._connected_system, _mouse._port_index, _mouse.device_type])
	var plug: ControllerPlug = _mouse._cable_plug
	print("[probe] plug at %s | port 0 at %s | gap %.1f mm"
		% [plug.global_position, _sys._port_zones[0].global_position,
			plug.global_position.distance_to(_sys._port_zones[0].global_position) * 1000.0])
	print("[probe] plug mesh node: %s" % (plug.get_node_or_null("PlugModel") != null))
	print("[probe] cable_anchor = %s" % plug.cable_anchor)


func _build_camera() -> void:
	_sv = SubViewport.new()
	_sv.size = VIEW
	_sv.own_world_3d = false
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)
	_cam = Camera3D.new()
	# 25 px/degree, Quest 3 lens-centre density: a 675 px tall view wants 27 deg.
	_cam.fov = 27.0
	_cam.near = 0.02
	_sv.add_child(_cam)
	_cam.current = true


## Wide enough for the console, the lead and the mouse; then in on the buttons.
func _aim(t: float) -> void:
	var k := clampf(smoothstep(0.10, 0.42, t), 0.0, 1.0)
	var wide_at := (_sys.global_position + _mouse.global_position) * 0.5 + Vector3(0, 0.045, 0)
	var close_at := _mouse.global_position + Vector3(0, 0.026, 0.0)
	var look := wide_at.lerp(close_at, k)

	# Wide: a world-azimuth arc that keeps the console in shot.
	var az := deg_to_rad(38.0)
	var el := deg_to_rad(34.0)
	var wide_pos := wide_at + Vector3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * 0.92
	# Close: built in the MOUSE's own frame. Its face is -Z, and the first cut of
	# this shot carried the world azimuth all the way in, which parked the camera
	# behind the shell — the buttons were on the far side for the whole press.
	var spin := Basis(Vector3.UP, deg_to_rad(sin(t * TAU * 0.5) * 16.0))
	var close_pos: Vector3 = _mouse.global_position \
		+ _mouse.global_transform.basis * (spin * Vector3(0.085, 0.112, -0.185))

	_cam.global_position = wide_pos.lerp(close_pos, k)
	_cam.look_at(look, Vector3.UP)


func _buttons_at(frame: int) -> Array:
	var state := [false, false]
	for row: Array in SCHEDULE:
		if frame >= int(row[0]):
			state = [bool(row[1]), bool(row[2])]
	return state


func _inject(btn: int, down: bool) -> void:
	if bool(_btn_state.get(btn, false)) == down:
		return
	_btn_state[btn] = down
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = down
	Input.parse_input_event(ev)


func _shoot(lb: MeshInstance3D) -> void:
	for f in range(FRAMES):
		var s := _buttons_at(f)
		_inject(MOUSE_BUTTON_LEFT, bool(s[0]))
		_inject(MOUSE_BUTTON_RIGHT, bool(s[1]))
		_aim(float(f) / float(FRAMES))
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var y := lb.transform.origin.y
		_min_y = minf(_min_y, y)
		_max_y = maxf(_max_y, y)
		var img := _sv.get_texture().get_image()
		img.save_png("%s/frame_%04d.png" % [OUT_DIR, f])
	print("[probe] left button travel: %.3f mm (rest y %.5f, range %.5f..%.5f)"
		% [(_max_y - _min_y) * 1000.0, _rest_y, _min_y, _max_y])
	if _max_y - _min_y < 0.0002:
		print("[probe] FAIL: the button never moved — input never reached _poll_buttons")
	else:
		print("[probe] OK: the button moved through the real input path")
	print("[probe] wrote %d frames to %s" % [FRAMES, OUT_DIR])


func _finish(code: int) -> void:
	get_tree().quit(code)

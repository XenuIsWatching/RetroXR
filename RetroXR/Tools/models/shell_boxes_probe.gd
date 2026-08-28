## Films the collision volumes of the shells whose controls their own box was hiding.
##
## One pass per shell: a lap round the machine, then a close approach on the
## control that was buried, with that control's box picked out in white. What the
## close pass has to show is the white box standing PROUD of the shell around it —
## that is the whole difference between a control a ray can reach and one it cannot.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/models/shell_boxes_probe.tscn
##
## Windowed, not --headless: the dummy renderer hands back a blank image.
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const OUT_DIR := "res://probe_out/shell_boxes"
const SHOT := Vector2i(960, 720)
const HIGHLIGHT := Color(1.0, 1.0, 1.0)

## One entry per shell: what to spawn, which controls were buried, and the two
## framings. `focus` is relative to the console's own origin, which sits at y = 1.
const SHOTS := [
	{
		"model": "virtual_boy_primitive", "platform": "virtual_boy",
		"controls": ["PowerButton", "ResetButton", "VolumeSlider"],
		"caption": "VIRTUAL BOY — pointer body is visor + column + base, not one slab",
		"close_caption": "START/STOP sat 12 mm inside it, beside the column",
		"focus": Vector3(0, 0.18, 0), "dist": 0.80, "pitch": 12.0,
		"close_focus": Vector3(0, 0.028, 0.030), "close_dist": 0.36,
		"close_yaw": 38.0, "close_pitch": 20.0,
		"side_focus": Vector3(0, 0.19, 0), "side_size": 0.46,
		"side_caption": "SIDE ELEVATION — orthographic, so the silhouettes compare directly",
	},
	{
		"model": "atari_2600", "platform": "atari_2600",
		"controls": ["PowerSwitch", "ResetSwitch"],
		"caption": "ATARI 2600 — deck box, plateau box, and a wedge for the slope",
		"close_caption": "The levers stand in the open trough at their own size",
		"focus": Vector3(0, 0.045, 0), "dist": 0.62, "pitch": 20.0,
		"close_focus": Vector3(0, 0.076, -0.020), "close_dist": 0.46,
		"close_yaw": 8.0, "close_pitch": 9.0,
		"side_focus": Vector3(0, 0.044, 0), "side_size": 0.21,
		"side_caption": "SIDE ELEVATION — deck, wedge, plateau against the real profile",
	},
	{
		"model": "nes", "platform": "nes",
		"controls": ["ChannelSwitch"],
		"caption": "NES — the CH3/CH4 switch is in the recessed rear panel",
		"close_caption": "Its box reaches back out through the deck's rear face",
		"focus": Vector3(0, 0.047, 0), "dist": 0.50, "pitch": 18.0,
		"close_focus": Vector3(0.078, 0.031, -0.098), "close_dist": 0.15,
		"close_yaw": 196.0, "close_pitch": 14.0,
		"side_focus": Vector3(0, 0.047, 0), "side_size": 0.20,
		"side_caption": "SIDE ELEVATION — the bay mouth carved out of the front",
	},
]

var _sub: SubViewport = null
var _cam: Camera3D = null
var _caption: Label = null
var _frame := 0
var _origin := Vector3(0, 1, 0)


func _ready() -> void:
	get_tree().create_timer(600.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_build_world()
	_build_camera()

	for shot in SHOTS:
		await _film(shot)

	print("[probe] wrote %d frames to %s" % [_frame, ProjectSettings.globalize_path(OUT_DIR)])
	get_tree().quit(0)


func _film(shot: Dictionary) -> void:
	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = str(shot["platform"])
	sys.model_id = str(shot["model"])
	sys.position = _origin
	sys.ignore_gravity = true
	add_child(sys)
	sys.add_to_group("spawned")
	await _wait(40)

	# A fresh CollisionDebug per console. It only rescans on a 0.5 s timer, and one
	# left running from before the spawn has no overlays for this machine yet;
	# re-enabling makes its _ready scan the tree that exists now.
	CollisionDebug.set_enabled(self, false)
	CollisionDebug.set_enabled(self, true)
	await _wait(3)
	_show_spheres(false)
	var picked := _highlight(sys, shot["controls"])
	print("[probe] %-22s highlighted %d of %d controls"
		% [str(shot["model"]), picked, (shot["controls"] as Array).size()])

	var focus: Vector3 = _origin + (shot["focus"] as Vector3)
	await _orbit(str(shot["caption"]), focus, 0.0, 360.0,
		float(shot["pitch"]), float(shot["dist"]), 64)

	var close: Vector3 = _origin + (shot["close_focus"] as Vector3)
	var yaw: float = float(shot["close_yaw"])
	await _orbit(str(shot["close_caption"]), close, yaw - 26.0, yaw + 26.0,
		float(shot["close_pitch"]), float(shot["close_dist"]), 40)

	# Orthographic, dead side on: the only view where the collision silhouette and
	# the shell's own silhouette can be compared without perspective flattering it.
	var side: Vector3 = _origin + (shot["side_focus"] as Vector3)
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = float(shot["side_size"])
	await _orbit(str(shot["side_caption"]), side, 90.0, 90.0, 0.0, 0.6, 26)
	await _orbit(str(shot["side_caption"]), side, 90.0, 62.0, 0.0, 0.6, 26)
	_cam.projection = Camera3D.PROJECTION_PERSPECTIVE

	CollisionDebug.set_enabled(self, false)
	sys.queue_free()
	await _wait(10)


## Repaint the named controls' overlays so the box under discussion is findable
## among a dozen others. Returns how many were actually found.
func _highlight(sys: RetroSystem, names: Array) -> int:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = HIGHLIGHT
	mat.no_depth_test = true
	mat.render_priority = 5
	var found := 0
	var stack: Array[Node] = [sys]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not names.has(String(node.name)):
			continue
		for child in node.get_children():
			var overlay := child as MeshInstance3D
			if overlay != null and overlay.name.begins_with("CollisionDebugShape"):
				overlay.material_override = mat
				overlay.visible = true
				found += 1
	return found


## Hide every overlay that is not a box. The snap zones' grab spheres are the
## largest volumes on any of these machines and they drown the boxes.
func _show_spheres(on: bool) -> void:
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		var overlay := node as MeshInstance3D
		if overlay == null or overlay.name != "CollisionDebugShape":
			continue
		var body := overlay.get_parent() as CollisionObject3D
		if body == null:
			continue
		var oid: int = overlay.get_meta(&"owner_id", 0)
		if body.shape_owner_get_shape_count(oid) == 0:
			continue
		overlay.visible = on or body.shape_owner_get_shape(oid, 0) is BoxShape3D


func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.10, 0.12)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.62, 0.64, 0.70)
	e.ambient_light_energy = 0.55
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.9
	sun.rotation_degrees = Vector3(-48, -32, 0)
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.55
	fill.rotation_degrees = Vector3(-12, 148, 0)
	add_child(fill)


func _build_camera() -> void:
	_sub = SubViewport.new()
	_sub.size = SHOT
	_sub.own_world_3d = false
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sub)

	_cam = Camera3D.new()
	_cam.fov = 42.0
	_sub.add_child(_cam)
	_cam.current = true

	var box := ColorRect.new()
	box.color = Color(0, 0, 0, 0.55)
	box.position = Vector2(0, SHOT.y - 76)
	box.size = Vector2(SHOT.x, 76)
	_sub.add_child(box)

	_caption = Label.new()
	_caption.position = Vector2(20, SHOT.y - 66)
	_caption.add_theme_font_size_override("font_size", 20)
	_caption.add_theme_color_override("font_color", Color(1, 1, 1))
	_sub.add_child(_caption)

	var legend := Label.new()
	legend.position = Vector2(20, 16)
	legend.add_theme_font_size_override("font_size", 17)
	legend.add_theme_color_override("font_color", Color(0.85, 0.87, 0.92))
	legend.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	legend.add_theme_constant_override("outline_size", 5)
	legend.text = "white = the control that was buried\n" \
		+ "3 Pickable (body)\n21 XRPointer (what the ray hits)"
	_sub.add_child(legend)
	for i in range(2):
		var swatch := ColorRect.new()
		swatch.color = CollisionDebug.LAYER_COLORS.get([3, 21][i], Color.WHITE)
		swatch.position = Vector2(200, 41 + i * 22)
		swatch.size = Vector2(30, 12)
		_sub.add_child(swatch)


func _orbit(caption: String, focus: Vector3, yaw_from: float, yaw_to: float,
		pitch: float, dist: float, count: int) -> void:
	_caption.text = caption
	for i in range(count):
		var t := float(i) / float(maxi(count - 1, 1))
		var ry := deg_to_rad(lerpf(yaw_from, yaw_to, t))
		var rp := deg_to_rad(pitch)
		_cam.global_position = focus + Vector3(
			cos(rp) * sin(ry), sin(rp), cos(rp) * cos(ry)) * dist
		_cam.look_at(focus, Vector3.UP)
		await _grab()


func _grab() -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_sub.get_texture().get_image().save_png("%s/f%04d.png" % [OUT_DIR, _frame])
	_frame += 1


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame

## Films every slider in the room running end to end, with its touch shape drawn.
##
## The thing to watch is the white box: it should ride the switch the whole way
## rather than sitting still while the knob leaves it behind.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/vr/slider_travel_probe.tscn
##
## Windowed, not --headless: the dummy renderer hands back a blank image.
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const OUT_DIR := "res://probe_out/slider_travel"
const SHOT := Vector2i(960, 720)
const SWEEP_FRAMES := 22
const HIGHLIGHT := Color(1.0, 1.0, 1.0)

var _sub: SubViewport = null
var _cam: Camera3D = null
var _caption: Label = null
var _frame := 0


func _ready() -> void:
	get_tree().create_timer(1200.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_build_world()
	_build_camera()
	for id in SystemModelRegistry.all_ids():
		await _film(str(id))
	print("[probe] wrote %d frames to %s" % [_frame, ProjectSettings.globalize_path(OUT_DIR)])
	get_tree().quit(0)


func _film(model_id: String) -> void:
	var row: Dictionary = SystemModelRegistry.row_for(model_id)
	var served: Variant = row.get("platform", "")
	var platform := str(served[0]) if served is Array and not served.is_empty() else str(served)
	if platform.is_empty():
		return

	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = platform
	sys.model_id = model_id
	sys.position = Vector3(0, 1, 0)
	sys.ignore_gravity = true
	add_child(sys)
	await _wait(35)

	var sliders := _sliders_of(sys)
	if sliders.is_empty():
		sys.queue_free()
		await _wait(5)
		return

	# A fresh CollisionDebug per console: it only rescans on a 0.5 s timer, so one
	# left running from a previous machine has no overlays for this one.
	CollisionDebug.set_enabled(self, false)
	CollisionDebug.set_enabled(self, true)
	await _wait(3)
	_show_only_boxes()
	_highlight(sliders)

	# One shot per slider, not one per machine. Two sliders on opposite faces put
	# the camera in the middle of the device looking at neither.
	for s in sliders:
		var sl := s as VRSlider
		_frame_on(sys, sl)
		_caption.text = "%s — %s, %.1f mm travel" % [model_id, sl.name, sl.travel * 1000.0]
		print("[probe] %-24s %s" % [model_id, sl.name])
		# Out and back, eased so the ends read as detents rather than a bounce.
		for i in range(SWEEP_FRAMES):
			var t := float(i) / float(SWEEP_FRAMES - 1)
			sl.set_value_no_signal(0.5 - 0.5 * cos(t * TAU))
			await _grab()
		sl.set_value_no_signal(0.0)

	CollisionDebug.set_enabled(self, false)
	sys.queue_free()
	await _wait(6)


func _sliders_of(sys: RetroSystem) -> Array:
	var out: Array = []
	var stack: Array[Node] = [sys]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is VRSlider:
			out.append(node)
	return out


## Orthographic, square on to the face this slider sits on, so its travel runs
## across the frame instead of toward the camera.
func _frame_on(sys: RetroSystem, sl: VRSlider) -> void:
	var focus: Vector3 = sl.global_position
	var outward: Vector3 = focus - sys.global_position
	if outward.length() < 0.001:
		outward = Vector3.UP
	outward = outward.normalized()
	var view: Vector3 = (outward * 0.75 + Vector3.UP * 0.5).normalized()
	# Never from underneath: a device read from below is upside down and unplaceable.
	if view.y < 0.15:
		view = (view + Vector3.UP * 0.6).normalized()
	# If the travel runs along the view it moves toward the lens and is invisible.
	var axis: Vector3 = (sys.global_transform.basis * sl.axis_local).normalized()
	if absf(view.dot(axis)) > 0.75:
		view = (view + axis.cross(Vector3.UP).normalized() * 1.1).normalized()

	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = maxf(sl.travel * 6.0, 0.05)
	_cam.global_position = focus + view * 0.6
	_cam.look_at(focus, Vector3.UP)


func _highlight(sliders: Array) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = HIGHLIGHT
	mat.no_depth_test = true
	mat.render_priority = 5
	for s in sliders:
		for child in (s as Node).get_children():
			var overlay := child as MeshInstance3D
			if overlay != null and overlay.name.begins_with("CollisionDebugShape"):
				overlay.material_override = mat
				overlay.visible = true


func _show_only_boxes() -> void:
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		var overlay := node as MeshInstance3D
		if overlay == null or not overlay.name.begins_with("CollisionDebugShape"):
			continue
		var body := overlay.get_parent() as CollisionObject3D
		if body == null:
			continue
		var oid: int = overlay.get_meta(&"owner_id", 0)
		if body.shape_owner_get_shape_count(oid) == 0:
			continue
		overlay.visible = body.shape_owner_get_shape(oid, 0) is BoxShape3D


func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.10, 0.12)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.70, 0.72, 0.78)
	e.ambient_light_energy = 0.8
	env.environment = e
	add_child(env)
	for spec in [[Vector3(-48, -32, 0), 1.9], [Vector3(-12, 148, 0), 0.7],
			[Vector3(-8, 40, 0), 0.6]]:
		var light := DirectionalLight3D.new()
		light.rotation_degrees = spec[0]
		light.light_energy = spec[1]
		add_child(light)


func _build_camera() -> void:
	_sub = SubViewport.new()
	_sub.size = SHOT
	_sub.own_world_3d = false
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sub)
	_cam = Camera3D.new()
	_sub.add_child(_cam)
	_cam.current = true

	var bar := ColorRect.new()
	bar.color = Color(0, 0, 0, 0.55)
	bar.position = Vector2(0, SHOT.y - 76)
	bar.size = Vector2(SHOT.x, 76)
	_sub.add_child(bar)
	_caption = Label.new()
	_caption.position = Vector2(20, SHOT.y - 66)
	_caption.add_theme_font_size_override("font_size", 20)
	_caption.add_theme_color_override("font_color", Color(1, 1, 1))
	_sub.add_child(_caption)

	var legend := Label.new()
	legend.position = Vector2(20, 16)
	legend.add_theme_font_size_override("font_size", 17)
	legend.add_theme_color_override("font_color", Color(0.88, 0.90, 0.94))
	legend.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	legend.add_theme_constant_override("outline_size", 5)
	legend.text = "white = the slider's touch shape"
	_sub.add_child(legend)


func _grab() -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_sub.get_texture().get_image().save_png("%s/f%04d.png" % [OUT_DIR, _frame])
	_frame += 1


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame

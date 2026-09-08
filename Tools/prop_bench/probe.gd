extends Node3D

# Synthetic occlusion stress test, NOT an arcade FPS prediction. Same geometry,
# eye resolution, shader arithmetic and textures in both arms; only ALPHA differs.
var camera: Camera3D
var anchor: Node3D
var boxes: Array[MeshInstance3D] = []
var variants: Array[ShaderMaterial] = []
var runs: Array = []


func _ready() -> void:
	for path in ["res://reference.gdshader", "res://prop.gdshader"]:
		var mat := ShaderMaterial.new()
		mat.shader = load(path)
		# Small real 3D textures exercise both production GI fetches.
		for param in ["gi_irr", "gi_dir"]:
			var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
			img.fill(Color(0.6, 0.6, 0.6, 0) if param == "gi_irr" else Color(0.5, 1, 0.5, 0.5))
			var tex := ImageTexture3D.new()
			tex.create(Image.FORMAT_RGBA8, 4, 4, 4, false, [img, img, img, img])
			mat.set_shader_parameter(param, tex)
		mat.set_shader_parameter("gi_min", Vector3(-10, -10, -10))
		mat.set_shader_parameter("gi_size", Vector3(20, 20, 20))
		variants.append(mat)
	if "--visual" in OS.get_cmdline_user_args():
		_visual.call_deferred()
	else:
		_benchmark.call_deferred()


func _box(parent: Node, size: Vector3, pos: Vector3) -> MeshInstance3D:
	var box := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	box.mesh = mesh
	box.position = pos
	parent.add_child(box)
	return box


func _benchmark() -> void:
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr != null and xr.is_initialized():
		xr.render_target_size_multiplier = 1.5
		get_viewport().use_xr = true
		xr.set_display_refresh_rate(72.0)
		xr.set_gpu_level(OpenXRInterface.PERF_SETTINGS_LEVEL_SUSTAINED_HIGH)
		xr.set_cpu_level(OpenXRInterface.PERF_SETTINGS_LEVEL_SUSTAINED_HIGH)
		var origin := XROrigin3D.new()
		add_child(origin)
		camera = XRCamera3D.new()
		origin.add_child(camera)
	else:
		camera = Camera3D.new()
		add_child(camera)
	anchor = Node3D.new()
	add_child(anchor)
	for layer in 4:
		for y in 5:
			for x in 7:
				boxes.append(_box(anchor, Vector3(0.48, 0.4, 0.3),
					Vector3((x - 3) * 0.45, (y - 2) * 0.37, -2.0 - layer * 0.45)))
	var rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	for layers in [1, 4]:
		for i in boxes.size():
			boxes[i].visible = i < layers * 35
		for repeat in 3:
			for index in ([1, 0] if repeat == 1 else [0, 1]):
				for box in boxes:
					box.material_override = variants[index]
				await _frames(120)
				var times: Array[float] = []
				for frame in 600:
					await RenderingServer.frame_post_draw
					times.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
				times.sort()
				var result := {"layers": layers, "repeat": repeat, "variant": index,
					"median_ms": times[300], "p95_ms": times[570],
					"eye_size": str(xr.get_render_target_size()) if xr != null and xr.is_initialized() else str(get_viewport().size)}
				runs.append(result)
				print("[propbench] ", JSON.stringify(result))
				_write("user://timings.json", runs)
	print("[propbench] COMPLETE")
	get_tree().quit()


func _process(_delta: float) -> void:
	if anchor != null and camera != null:
		anchor.global_transform = camera.global_transform


func _frames(count: int) -> void:
	for i in count:
		await RenderingServer.frame_post_draw


func _visual() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(512, 512)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var cam := Camera3D.new()
	vp.add_child(cam)
	var box := _box(vp, Vector3(1, 1, 0.2), Vector3(0, 0, -2))
	var images: Array[Image] = []
	for mat in variants:
		box.material_override = mat
		await _frames(8)
		images.append(vp.get_texture().get_image())
	var identical := images[0].get_data() == images[1].get_data()
	# A later transparent draw BEHIND the prop must fail the depth test.
	var rear := _box(vp, Vector3(0.5, 0.5, 0.1), Vector3(0, 0, -3))
	var red := ShaderMaterial.new()
	red.shader = Shader.new()
	red.shader.code = "shader_type spatial; render_mode unshaded; void fragment() { ALBEDO = vec3(1,0,0); ALPHA = 1.0; }"
	red.render_priority = 1
	rear.material_override = red
	await _frames(8)
	var depth_ok := vp.get_texture().get_image().get_data() == images[1].get_data()
	box.material_override = variants[0]
	await _frames(8)
	var detects_bug := vp.get_texture().get_image().get_data() != images[0].get_data()
	var result := {"opaque_colour_identical": identical, "occluded_draw_rejected": depth_ok,
		"reference_exhibits_depth_bug": detects_bug}
	print("[propbench] visual ", JSON.stringify(result))
	_write("user://visual.json", result)
	get_tree().quit(0 if identical and depth_ok and detects_bug else 1)


func _write(path: String, value: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value, "\t"))

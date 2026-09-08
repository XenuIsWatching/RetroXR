extends Node3D
## Standalone synthetic CRT A/B test. No RetroXR autoloads or saved preferences.
##
## Three variants of the tube stage: `reference` (the frozen pre-optimisation
## crt_band / crt_mask / crt_beam), `current` (the shipped crt_filter) and
## `mobile` (crt_effect_mobile, the unshaded opaque tier, which exists for the
## crt_effect caller only). A run compares one PAIR, given as `--pair=a,b` on the
## command line or as the second word of user://mode.txt on device
## ("benchmark current,mobile"). reference/current is an identity check and
## fails on a difference of more than one 8-bit level; a pair that includes
## `mobile` differs by design, so it reports the errors, saves every image pair
## for viewing, and never fails.
const WRAPPERS := ["crt_effect", "screen_window", "vcr_effect", "tv_static"]
const SUFFIX := {"reference": "_reference", "current": "", "mobile": "_mobile"}
const SAMPLES := 600
const WARMUP := 120
var materials: Dictionary = {}
var source: ImageTexture
var screens: Array[MeshInstance3D] = []
var anchor: Node3D
var camera: Camera3D
var xr: XRInterface
var results: Array = []
var run_mode := "benchmark"
var pair: Array = ["current", "mobile"]

func _ready() -> void:
	_build_materials()
	var visual := "--visual" in OS.get_cmdline_user_args()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pair="):
			pair = Array(arg.trim_prefix("--pair=").split(","))
	if FileAccess.file_exists("user://mode.txt"):
		var words := FileAccess.get_file_as_string("user://mode.txt").strip_edges().split(" ", false)
		if words.size() > 0:
			run_mode = words[0]
		if words.size() > 1:
			pair = Array(words[1].split(","))
		visual = run_mode == "visual"
	assert(pair.size() == 2 and SUFFIX.has(pair[0]) and SUFFIX.has(pair[1]), "pair must name two of %s" % [SUFFIX.keys()])
	print("[crtbench] pair ", pair)
	if visual:
		_visual.call_deferred()
	else:
		_benchmark.call_deferred()

## True for the identity pair, where any difference is a defect.
func _strict() -> bool:
	return not pair.has("mobile")

func _build_materials() -> void:
	var img := Image.create(640, 480, false, Image.FORMAT_RGBA8)
	for y in range(480):
		for x in range(640):
			var c := Color(float(x) / 639.0, float(y) / 479.0, 0.3, 1.0)
			if y < 160:
				c = Color.WHITE if (x / 4 + y / 4) % 2 == 0 else Color.BLACK
			elif y > 320:
				c = Color.from_hsv(float(x / 80) / 8.0, 0.8, 0.9)
			img.set_pixel(x, y, c)
	source = ImageTexture.create_from_image(img)
	for wrapper in WRAPPERS:
		var variants := {}
		for variant in SUFFIX:
			var path := "res://Shaders/%s%s.gdshader" % [wrapper, SUFFIX[variant]]
			if not ResourceLoader.exists(path):
				continue
			var mat := ShaderMaterial.new()
			mat.shader = load(path)
			mat.set_shader_parameter("source_tex", source)
			mat.set_shader_parameter("crt_enabled", true)
			if wrapper == "screen_window":
				mat.set_shader_parameter("source_rect", Vector4(0, 0, 0.5, 1))
				mat.set_shader_parameter("eye_shift", 0.5)
			variants[variant] = mat
		materials[wrapper] = variants

func _screen(parent: Node, curved: bool = true) -> MeshInstance3D:
	var screen := MeshInstance3D.new()
	if curved:
		screen.mesh = load("res://screen.res")
		var bounds := screen.mesh.get_aabb()
		screen.scale = Vector3(0.35 / bounds.size.x, 0.2625 / bounds.size.y, 1.0)
	else:
		var quad := QuadMesh.new()
		quad.size = Vector2(0.35, 0.2625)
		screen.mesh = quad
	parent.add_child(screen)
	return screen

func _process(_dt: float) -> void:
	# Fixed eye-relative test poses remove headset movement from the A/B workload.
	if anchor != null and camera != null:
		anchor.global_transform = camera.global_transform

func _benchmark() -> void:
	xr = XRServer.find_interface("OpenXR")
	if OS.get_name() == "Android" and (xr == null or not xr.is_initialized()):
		push_error("[crtbench] OpenXR not initialized; refusing non-XR mobile timings")
		get_tree().quit(1)
		return
	if xr != null and xr.is_initialized():
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
	for i in range(9):
		screens.append(_screen(anchor))
	var vp := get_viewport()
	RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	var metadata := {"device": OS.get_model_name(), "renderer": RenderingServer.get_current_rendering_method(),
		"gpu": RenderingServer.get_video_adapter_name(), "msaa": vp.msaa_3d, "pair": pair,
		"foveation": 0, "performance_request": "sustained_high", "samples": SAMPLES, "warmup": WARMUP,
		"manifest": JSON.parse_string(FileAccess.get_file_as_string("res://manifest.json"))}
	if xr != null and xr.is_initialized():
		metadata["eye_size"] = str(xr.get_render_target_size())
		metadata["refresh_hz"] = xr.get_display_refresh_rate()
	print("[crtbench] metadata ", JSON.stringify(metadata))
	if run_mode.begins_with("capture_"):
		for i in range(screens.size()):
			screens[i].position = Vector3((i % 3 - 1) * 0.37, (i / 3 - 1) * 0.2825, -1.0)
		while true:
			# capture_<variant>; "optimized" is the old name for "current".
			var variant := run_mode.trim_prefix("capture_").replace("optimized", "current")
			_set_variant(variant)
			await _frames(WARMUP)
			print("[crtbench] CAPTURE READY ", run_mode)
			await _frames(600)
			run_mode = FileAccess.get_file_as_string("user://mode.txt").strip_edges().split(" ", false)[0]
		return
	for count in [1, 9]:
		for distance in [0.35, 1.0, 2.0]:
			for i in range(screens.size()):
				var s := screens[i]
				s.visible = i < count
				var col := i % 3 - 1 if count > 1 else 0
				var row := i / 3 - 1 if count > 1 else 0
				s.position = Vector3(col * 0.37, row * 0.2825, -distance)
			# Prime both variants before the measured alternating runs.
			for variant in pair:
				_set_variant(variant)
				await _frames(WARMUP)
			for repeat in range(3):
				# AB / BA / AB balances short-term thermal/clock drift.
				var order: Array = pair if repeat % 2 == 0 else [pair[1], pair[0]]
				for variant in order:
					_set_variant(variant)
					await _frames(WARMUP)
					# The refresh request takes effect after OpenXR begins its session.
					if xr != null and xr.is_initialized():
						metadata["refresh_hz"] = xr.get_display_refresh_rate()
					var times: Array[float] = []
					for frame in range(SAMPLES):
						await RenderingServer.frame_post_draw
						times.append(RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid()))
					var sorted := times.duplicate()
					sorted.sort()
					var result := {"count": count, "distance": distance, "repeat": repeat,
						"variant": variant,
						"median_ms": sorted[SAMPLES / 2], "p95_ms": sorted[int(SAMPLES * 0.95)], "samples_ms": times}
					results.append(result)
					var short := result.duplicate()
					short.erase("samples_ms")
					print("[crtbench] result ", JSON.stringify(short))
					_write_json("user://timings.json", {"metadata": metadata, "runs": results})
	print("[crtbench] COMPLETE ", ProjectSettings.globalize_path("user://timings.json"))
	get_tree().quit()

func _set_variant(variant: String) -> void:
	for screen in screens:
		screen.material_override = materials["crt_effect"][variant]

func _frames(count: int) -> void:
	for i in range(count):
		await RenderingServer.frame_post_draw

func _write_json(path: String, value: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value, "\t"))

## Error statistics between two RGBA8 images: the worst channel, how many
## channels moved at all, and the mean absolute difference over the whole image
## and over its central half, which is where the picture is when the corners are
## what differ (the mobile tier paints its rounded corner black instead of
## transparent, and the tube collar hides that in the real set).
func _compare(a_img: Image, b_img: Image) -> Dictionary:
	var a := a_img.get_data()
	var b := b_img.get_data()
	var w := a_img.get_width()
	var h := a_img.get_height()
	var max_error := 0
	var changed := 0
	var total := 0
	var centre_max := 0
	var centre_total := 0
	var centre_n := 0
	for i in range(a.size()):
		var diff := absi(a[i] - b[i])
		max_error = maxi(max_error, diff)
		total += diff
		if diff > 0:
			changed += 1
		var px := (i / 4) % w
		var py := (i / 4) / w
		if px >= w / 4 and px < 3 * w / 4 and py >= h / 4 and py < 3 * h / 4:
			centre_max = maxi(centre_max, diff)
			centre_total += diff
			centre_n += 1
	return {"max_byte_error": max_error, "changed_channels": changed,
		"mean_error": float(total) / float(a.size()),
		"centre_max_error": centre_max, "centre_mean_error": float(centre_total) / float(maxi(centre_n, 1))}

func _visual() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(512, 512)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_2X
	add_child(vp)
	# A black world behind the quad: the full stage's transparent corner and the
	# mobile stage's opaque black one then read the same, as they do behind the
	# collar in tv.tscn.
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color.BLACK
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.3, 0.3, 0.3)
	vp.add_child(env)
	var cam := Camera3D.new()
	cam.fov = 70
	vp.add_child(cam)
	var screen := _screen(vp, false)
	var cases: Array = []
	for wrapper in WRAPPERS:
		if not (materials[wrapper].has(pair[0]) and materials[wrapper].has(pair[1])):
			continue
		for mode in range(4):
			for pose in [[0.2, 0.0], [0.5, 0.0], [1.0, 0.0], [2.0, 0.0], [0.5, 0.7]]:
				for eye in [-0.032, 0.032]:
					cases.append({"wrapper": wrapper, "mode": mode, "distance": pose[0], "angle": pose[1], "eye": eye})
	# Orthographic full-quad coverage gives exact controllable cycles/pixel.
	for footprint in [0.1499, 0.15, 0.1501, 0.2249, 0.225, 0.2251, 0.4499, 0.45, 0.4501, 0.7999, 0.8, 0.8001]:
		for mode in range(4):
			cases.append({"wrapper": "crt_effect", "mode": mode, "footprint": footprint})
	cases.append({"wrapper": "crt_effect", "mode": 0, "disabled": true})
	var worst := 0
	var failed := 0
	var report: Array = []
	DirAccess.make_dir_recursive_absolute("user://visual")
	for index in range(cases.size()):
		var c: Dictionary = cases[index]
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL if c.has("footprint") else Camera3D.PROJECTION_PERSPECTIVE
		cam.size = 0.35
		cam.position.x = c.get("eye", 0.0)
		screen.position = Vector3(0, 0, -c.get("distance", 0.5))
		screen.rotation.y = c.get("angle", 0.0)
		var images: Array[Image] = []
		for variant in pair:
			var mat: ShaderMaterial = materials[c.wrapper][variant]
			if c.wrapper == "screen_window":
				# SubViewports are mono; explicitly exercise each packed eye region.
				mat.set_shader_parameter("stereo_mode", 2 if c.get("eye", 0.0) > 0 else 1)
			mat.set_shader_parameter("crt_mask_mode", c.mode)
			mat.set_shader_parameter("crt_scanline_strength", 0.0 if c.get("disabled", false) else 0.6)
			mat.set_shader_parameter("crt_mask_strength", 0.0 if c.get("disabled", false) else 0.55)
			mat.set_shader_parameter("crt_mask_triads", 512.0 * c.footprint if c.has("footprint") else 175.0)
			mat.set_shader_parameter("crt_mask_rows", 384.0 * c.footprint if c.has("footprint") else 83.0)
			mat.set_shader_parameter("crt_scanline_count", 384.0 * c.footprint if c.has("footprint") else 240.0)
			screen.material_override = mat
			await _frames(3)
			var img := vp.get_texture().get_image()
			img.convert(Image.FORMAT_RGBA8)
			images.append(img)
		var stats := _compare(images[0], images[1])
		var max_error: int = stats["max_byte_error"]
		worst = maxi(worst, max_error)
		if _strict() and max_error > 1:
			failed += 1
		if not _strict() or max_error > 1 or index in [0, 4, 8, 9, 12]:
			for v in range(2):
				images[v].save_png("user://visual/%03d_%s.png" % [index, pair[v]])
		c.merge(stats)
		report.append(c)
		if index % 20 == 0:
			print("[crtbench] visual %d/%d worst=%d" % [index + 1, cases.size(), worst])
	_write_json("user://visual.json", {"pair": pair, "strict": _strict(), "cases": report,
		"worst_byte_error": worst, "failed": failed})
	print("[crtbench] VISUAL COMPLETE pair=%s cases=%d worst=%d failed=%d path=%s" % [
		pair, cases.size(), worst, failed, ProjectSettings.globalize_path("user://visual.json")])
	get_tree().quit(1 if failed > 0 else 0)

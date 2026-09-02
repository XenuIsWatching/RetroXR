extends Node3D
## Minimal reproduction for an upstream report: on a Quest 3 (Godot 4.7, vendors 5.1,
## Vulkan mobile renderer) any VRS density map combined with Meta dynamic resolution
## (XR_META_recommended_layer_resolution) takes the GPU down within seconds.
##
## Ships as its own app (`QuestVrsRepro` presets, package com.xenu.vrsrepro) so the real
## install is never touched. The scene is a GPU-heavy filler - enough lit spheres that the
## runtime's recommended resolution drops below the target, because dynamic resolution
## only engages under load - and at START_FRAME it switches VRS on in the mode named by
## the external files dir's mode.txt:
##   off      no VRS attachment (control: must survive)
##   texture  Godot's XRVRS map, VRS_TEXTURE, focus (0,0) per eye
##   xr       VRS_XR - on Quest the runtime's XR_FB fragment-density map, level 3,
##            subsampled images off
## A heartbeat prints every second with the LIVE render-target size and the measured GPU
## time, so the log tells "crashed at t" apart from "running but not ticking" and shows
## whether dynamic resolution actually engaged. Nothing here is RetroXR: no autoload is
## read, no pref is written.
##
##   adb push mode.txt /sdcard/Android/data/com.xenu.vrsrepro/files/mode.txt
##   adb logcat -s godot:* | grep vrsrepro

const MODE_PATH := "/sdcard/Android/data/com.xenu.vrsrepro/files/mode.txt"
const START_FRAME := 300
const RUN_SECONDS := 90.0
const SPHERES := 400
const LIGHTS := 8

var _frames := 0
var _elapsed := 0.0
var _since_report := 0.0
var _mode := "off"
var _armed := false
var _vrs_generator: Object = null
## Optional knobs after the mode word in mode.txt, each a RetroXR condition the bare
## scene lacks: arm=N (arm VRS at frame N, RetroXR arms before the first frame),
## msaa=0|1|2 (Viewport.MSAA_*; RetroXR ships 2x-4x), glow=1 (WorldEnvironment glow),
## sub=1 (a SubViewport rendering every frame onto a quad), stencil=1 (RetroXR's
## outline mask, a stencil-writing material, on one sphere).
var _flags: Dictionary = {}


func _ready() -> void:
	get_tree().create_timer(RUN_SECONDS).timeout.connect(func() -> void:
		print("[vrsrepro] ===== survived %d s in mode %s =====" % [int(RUN_SECONDS), _mode])
		get_tree().quit(0))
	var xri: XRInterface = XRServer.find_interface("OpenXR")
	var initialized: bool = xri != null and xri.is_initialized()
	print("[vrsrepro] OpenXR interface=%s initialized=%s" % [xri != null, initialized])
	if initialized:
		xri.set_play_area_mode(XRInterface.XR_PLAY_AREA_ROOMSCALE)
		get_viewport().use_xr = true
	print("[vrsrepro] dynamic_resolution=%s foveation_level=%s subsampled=%s" % [
		ProjectSettings.get_setting("xr/openxr/extensions/meta/dynamic_resolution", "unset"),
		ProjectSettings.get_setting("xr/openxr/foveation_level", "unset"),
		ProjectSettings.get_setting("xr/openxr/foveation_with_subsampled_images", "unset")])
	_mode = _read_mode()
	print("[vrsrepro] mode=%s flags=%s (from %s), VRS arms at frame %d" % [
		_mode, _flags, MODE_PATH, _arm_frame()])
	if _flags.has("msaa"):
		get_viewport().msaa_3d = clampi(int(_flags["msaa"]), 0, 3) as Viewport.MSAA
	if _flags.get("glow", "0") == "1":
		var env: Environment = $WorldEnvironment.environment
		env.glow_enabled = true
		env.glow_intensity = 0.8
	print("[vrsrepro] msaa=%d glow=%s" % [get_viewport().msaa_3d, $WorldEnvironment.environment.glow_enabled])
	var origin := XROrigin3D.new()
	add_child(origin)
	var cam := XRCamera3D.new()
	origin.add_child(cam)
	_build_filler()
	if _flags.get("sub", "0") == "1":
		_build_subviewport()
	if _flags.get("stencil", "0") == "1":
		_apply_stencil()
	if _flags.has("shader"):
		_apply_shader(String(_flags["shader"]), String(_flags.get("pass2", "")))
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _arm_frame() -> int:
	return maxi(int(_flags.get("arm", str(START_FRAME))), 1)


## What RetroXR's TV panels and menus are: a SubViewport re-rendered every frame,
## shown on a quad in the eye view.
func _build_subviewport() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(800, 620)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var label := Label.new()
	label.text = "SubViewport"
	label.add_theme_font_size_override("font_size", 96)
	sv.add_child(label)
	add_child(sv)
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.8, 0.62)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = sv.get_texture()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.material = mat
	quad.mesh = qm
	quad.position = Vector3(0.0, 1.5, -1.5)
	add_child(quad)
	print("[vrsrepro] subviewport 800x620 UPDATE_ALWAYS on a quad")


## RetroXR's pickable outline: a stencil-writing mask pass with the outline as its
## next_pass, on one sphere. The mobile notes say stencil under VRS is what hung.
func _apply_stencil() -> void:
	var mask := ShaderMaterial.new()
	mask.shader = load("res://Shaders/outline_mask.gdshader")
	mask.render_priority = 1
	var outline := ShaderMaterial.new()
	outline.shader = load("res://Shaders/outline.gdshader")
	mask.next_pass = outline
	var n := 0
	for child in get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).mesh is SphereMesh:
			(child as MeshInstance3D).material_override = mask
			n += 1
			if n >= 8:
				break
	print("[vrsrepro] stencil outline mask on %d spheres" % n)


## Any shader on eight spheres: `shader=<name>` (+ `pass2=<name>` as next_pass). A bare
## name resolves under Tools/perf/vrs_shaders/, a name with a slash is a res:// path
## under Shaders/. This is how the fault got bisected to a render feature rather than
## to "the outline".
func _apply_shader(name: String, pass2: String) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load(_shader_path(name))
	mat.render_priority = 1
	if not pass2.is_empty():
		var second := ShaderMaterial.new()
		second.shader = load(_shader_path(pass2))
		second.render_priority = 2
		mat.next_pass = second
	var n := 0
	for child in get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).mesh is SphereMesh:
			(child as MeshInstance3D).material_override = mat
			n += 1
			if n >= 8:
				break
	print("[vrsrepro] shader %s%s on %d spheres" % [name, (" + " + pass2) if not pass2.is_empty() else "", n])


func _shader_path(name: String) -> String:
	if name.begins_with("t_"):
		return "res://Tools/perf/vrs_shaders/%s.gdshader" % name
	return "res://Shaders/%s.gdshader" % name


func _live_region() -> Rect2i:
	if not Engine.has_singleton("OpenXRMetaRecommendedLayerResolutionExtension"):
		return Rect2i()
	var ext: Object = Engine.get_singleton("OpenXRMetaRecommendedLayerResolutionExtension")
	if ext == null or not ext.has_method("get_render_region"):
		return Rect2i()
	return ext.call("get_render_region") as Rect2i


func _read_mode() -> String:
	if not FileAccess.file_exists(MODE_PATH):
		return "off"
	var f := FileAccess.open(MODE_PATH, FileAccess.READ)
	if f == null:
		return "off"
	var words := f.get_as_text().strip_edges().to_lower().split(" ", false)
	if words.is_empty():
		return "off"
	for w in words.slice(1):
		var kv := w.split("=")
		_flags[kv[0]] = kv[1] if kv.size() > 1 else "1"
	return words[0] if words[0] in ["off", "texture", "xr"] else "off"


## A room of lit, normal-mapped spheres. Forward Mobile shades every light whose range
## reaches an object per pixel, so eight omnis over four hundred spheres is a fill cost
## that exceeds 72 Hz at 1680x1760 - the condition under which the runtime lowers the
## recommended resolution.
func _build_filler() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 0.12
	mesh.height = 0.24
	mesh.radial_segments = 24
	mesh.rings = 12
	var noise := NoiseTexture2D.new()
	noise.as_normal_map = true
	noise.width = 256
	noise.height = 256
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.6, 0.5)
	mat.roughness = 0.4
	mat.normal_enabled = true
	mat.normal_texture = noise
	mesh.material = mat
	var side := int(ceil(pow(SPHERES, 1.0 / 3.0)))
	var n := 0
	for x in side:
		for y in side:
			for z in side:
				if n >= SPHERES:
					break
				var mi := MeshInstance3D.new()
				mi.mesh = mesh
				mi.position = Vector3((x - side / 2.0) * 0.4, 0.4 + y * 0.35, -1.0 - z * 0.4)
				add_child(mi)
				n += 1
	for i in LIGHTS:
		var light := OmniLight3D.new()
		light.light_color = Color.from_hsv(float(i) / LIGHTS, 0.5, 1.0)
		light.light_energy = 1.5
		light.omni_range = 6.0
		light.shadow_enabled = false
		light.position = Vector3(cos(TAU * i / LIGHTS) * 2.0, 1.8, -2.0 + sin(TAU * i / LIGHTS) * 2.0)
		add_child(light)
	var floor := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(12, 12)
	plane.material = mat
	floor.mesh = plane
	add_child(floor)


func _arm_vrs() -> void:
	var root := get_viewport()
	var xr: XRInterface = XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized():
		print("[vrsrepro] no OpenXR interface, mode %s not applied" % _mode)
		return
	match _mode:
		"texture":
			var size: Vector2 = xr.get_render_target_size()
			_vrs_generator = ClassDB.instantiate("XRVRS")
			_vrs_generator.set("vrs_min_radius", 20.0)
			_vrs_generator.set("vrs_strength", 2.0)
			var texture: RID = _vrs_generator.call("make_vrs_texture", size,
				PackedVector2Array([Vector2.ZERO, Vector2.ZERO]))
			RenderingServer.viewport_set_vrs_texture(root.get_viewport_rid(), texture)
			root.vrs_mode = Viewport.VRS_TEXTURE
			print("[vrsrepro] armed VRS_TEXTURE, XRVRS map for %dx%d, radius 20 strength 2" % [int(size.x), int(size.y)])
		"xr":
			xr.set("foveation_with_subsampled_images", false)
			xr.set("foveation_dynamic", false)
			xr.set("foveation_level", 3)
			root.vrs_mode = Viewport.VRS_XR
			print("[vrsrepro] armed VRS_XR, xr foveation_level 3, subsampled off")
		_:
			root.vrs_mode = Viewport.VRS_DISABLED
			print("[vrsrepro] control: VRS_DISABLED")


func _process(delta: float) -> void:
	_frames += 1
	_elapsed += delta
	_since_report += delta
	if not _armed and _frames >= _arm_frame():
		_armed = true
		_arm_vrs()
	if _since_report < 1.0:
		return
	_since_report = 0.0
	var xr: XRInterface = XRServer.find_interface("OpenXR")
	var size: Vector2 = xr.get_render_target_size() if xr != null else Vector2.ZERO
	print("[vrsrepro] alive t=%.1fs frames=%d mode=%s armed=%s eye=%dx%d region=%s gpu=%.2fms" % [
		_elapsed, _frames, _mode, _armed, int(size.x), int(size.y), _live_region(),
		RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())])

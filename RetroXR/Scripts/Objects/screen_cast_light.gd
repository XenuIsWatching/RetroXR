## Screen-driven light cast by a television or handheld display.
##
## A tiny canvas viewport turns the live picture into a heavily blurred 12x8
## texture. Three overlapping ordinary spotlights take the left/centre/right
## averages from it. This stays world-locked in XR (Light3D projectors do not),
## while the full video frame never leaves the GPU.
class_name ScreenCastLight
extends SpotLight3D

const BLUR_SHADER := preload("res://Shaders/screen_cast_light.gdshader")

## Stock CRT tube used as the physical-output reference.
const REFERENCE_AREA_M2 := 0.35 * 0.25
const REFERENCE_ENERGY := 1.2
const REFERENCE_RANGE_M := 4.5
const MIN_ENERGY := 0.06
const MAX_ENERGY := 3.0
const MIN_RANGE_M := 0.25
const MAX_RANGE_M := 8.0
const GLOW_ANGLE_DEG := 65.0
const SAMPLE_SIZE := Vector2i(12, 8)

var _screen_size_m := Vector2(0.35, 0.25)
var _local_screen_width_m := 0.35
var _lit_energy := REFERENCE_ENERGY
var _source: Texture2D = null
var _source_rect := Rect2(0.0, 0.0, 1.0, 1.0)
var _sample_viewport: SubViewport = null
var _sample_material: ShaderMaterial = null
var _refresh_frame := 0
var _picture_active := false
var _output_active := false
var _have_colours := false
var _left_light: SpotLight3D = null
var _right_light: SpotLight3D = null


func _ready() -> void:
	shadow_enabled = false
	spot_angle = GLOW_ANGLE_DEG
	_left_light = _make_region_light("LeftGlow")
	_right_light = _make_region_light("RightGlow")
	_refresh_frame = randi() % _refresh_interval()
	_apply_physical_output()
	_apply_energy()


## Set the physical panel dimensions. Both intensity and reach follow its linear
## scale (the square root of area), so a pocket LCD never throws a TV-sized cone.
func configure_screen(size_m: Vector2, inherited_scale: float = 1.0) -> void:
	_screen_size_m = Vector2(maxf(size_m.x, 0.001), maxf(size_m.y, 0.001))
	_local_screen_width_m = _screen_size_m.x / maxf(inherited_scale, 0.001)
	_apply_physical_output()


func show_picture(texture: Texture2D,
		region: Rect2 = Rect2(0.0, 0.0, 1.0, 1.0)) -> void:
	if texture == null:
		turn_off()
		return
	_ensure_sampler()
	var changed := texture != _source or region != _source_rect or not _picture_active
	_source = texture
	_source_rect = region
	_picture_active = true
	_output_active = true
	_apply_energy()
	if changed:
		_sample_material.set_shader_parameter("source_tex", texture)
		_sample_material.set_shader_parameter("source_rect", Vector4(
			region.position.x, region.position.y, region.size.x, region.size.y))
		_request_refresh()


## Static states need neither a viewport nor a sampled texture.
func show_solid(color: Color) -> void:
	_picture_active = false
	_output_active = true
	_source = null
	_set_region_colours(color, color, color, true)
	_apply_energy()
	_disable_sampler()


func turn_off() -> void:
	_picture_active = false
	_output_active = false
	_source = null
	_apply_energy()
	_disable_sampler()


func _process(_delta: float) -> void:
	if not _picture_active or _sample_viewport == null:
		return
	_refresh_frame += 1
	if _refresh_frame < _refresh_interval():
		return
	_refresh_frame = 0
	_capture_regions()
	_request_refresh()


func _apply_physical_output() -> void:
	var linear_scale := sqrt((_screen_size_m.x * _screen_size_m.y) / REFERENCE_AREA_M2)
	_lit_energy = clampf(REFERENCE_ENERGY * linear_scale, MIN_ENERGY, MAX_ENERGY)
	var reach := clampf(REFERENCE_RANGE_M * linear_scale, MIN_RANGE_M, MAX_RANGE_M)
	spot_range = reach
	spot_angle = GLOW_ANGLE_DEG
	if _left_light != null:
		_left_light.spot_range = reach
		_right_light.spot_range = reach
		_left_light.spot_angle = GLOW_ANGLE_DEG
		_right_light.spot_angle = GLOW_ANGLE_DEG
		_left_light.position.x = -_local_screen_width_m * 0.28
		_right_light.position.x = _local_screen_width_m * 0.28
	_apply_energy()


func _make_region_light(light_name: String) -> SpotLight3D:
	var light := SpotLight3D.new()
	light.name = light_name
	light.shadow_enabled = false
	light.spot_angle = GLOW_ANGLE_DEG
	add_child(light)
	return light


func _apply_energy() -> void:
	# Off means GONE, not dimmed to nothing. The mobile renderer shades every
	# light whose range reaches an object for every pixel of that object, energy
	# or not — it only ranks lights by energy once an object is over its cap. Three
	# spotlights per dark screen, reaching 4-8 m, put the whole floor's light list
	# at the cap: measured 1.5 ms per switched-off Game Boy on a Quest 3.
	visible = _output_active
	# The three shares add back to the configured physical output. The stronger
	# centre wash prevents three visibly separate cones where they overlap. A
	# solid colour has no left and right to tell apart, so it is one cone at the
	# full output and the side lights are gone for the same reason as above.
	var split := _output_active and _picture_active
	light_energy = (_lit_energy * 0.5 if split else _lit_energy) if _output_active else 0.0
	if _left_light != null:
		_left_light.visible = split
		_right_light.visible = split
		_left_light.light_energy = _lit_energy * 0.25 if split else 0.0
		_right_light.light_energy = _lit_energy * 0.25 if split else 0.0


func _ensure_sampler() -> void:
	if _sample_viewport != null:
		return
	_sample_viewport = SubViewport.new()
	_sample_viewport.name = "GlowSampler"
	_sample_viewport.disable_3d = true
	_sample_viewport.size = SAMPLE_SIZE
	_sample_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_sample_viewport)

	_sample_material = ShaderMaterial.new()
	_sample_material.shader = BLUR_SHADER
	var rect := ColorRect.new()
	rect.name = "BlurredPicture"
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.material = _sample_material
	_sample_viewport.add_child(rect)


func _capture_regions() -> void:
	# Headless uses the dummy texture server; there is no rendered image to read.
	if RenderingServer.get_rendering_device() == null:
		return
	var image := _sample_viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return
	var sums := [Color(0.0, 0.0, 0.0), Color(0.0, 0.0, 0.0), Color(0.0, 0.0, 0.0)]
	var counts := [0, 0, 0]
	for y in image.get_height():
		for x in image.get_width():
			var zone := mini(int(x * 3 / image.get_width()), 2)
			sums[zone] += image.get_pixel(x, y)
			counts[zone] += 1
	for zone in 3:
		sums[zone] /= float(maxi(counts[zone], 1))
	_set_region_colours(sums[0], sums[1], sums[2])


func _set_region_colours(left: Color, centre: Color, right: Color,
		immediate := false) -> void:
	var weight := 1.0 if immediate or not _have_colours else 0.45
	light_color = light_color.lerp(centre, weight)
	if _left_light != null:
		_left_light.light_color = _left_light.light_color.lerp(left, weight)
		_right_light.light_color = _right_light.light_color.lerp(right, weight)
	_have_colours = true


func _request_refresh() -> void:
	if _sample_viewport != null:
		# Re-arm explicitly. UPDATE_ONCE is consumed by the renderer, but assigning
		# the same enum again is not a reliable dirty signal on every backend.
		_sample_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_sample_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _disable_sampler() -> void:
	if _sample_viewport != null:
		_sample_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _refresh_interval() -> int:
	return maxi(int(QualityManager.screen_light_interval), 1) if QualityManager else 6

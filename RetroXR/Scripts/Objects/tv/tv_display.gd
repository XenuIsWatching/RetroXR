## TvDisplay — what is actually on the glass: the screen's own states, the CRT
## stage, the phosphor trail, the stereo window, the aspect fit, and the guard that
## decides who may paint.
##
## A child of the RetroTV it serves, created unconditionally in _init, in the same
## shape as TvResize, TvFit, TvOsd, TvAudio and TvPanel.
##
## The set PULLS its picture: every frame it reads the selected input's texture and
## installs one of its own materials over it, rather than a host pushing a material
## onto the screen. That is why every material below belongs to the set and why
## drop_sampled() exists — a host handed a screen still wearing our CRT wrapper
## would capture the wrapper as the material to restore later.
##
## crt_enabled, stereo_mode and widescreen stay on RetroTV: scene_persistence and
## object_sync read all three by name, and the bezel keys write them.
##
## The two phosphor SubViewports stay there too, being @onready paths into the
## set's own scene, as does the screen mesh everything here draws onto.
##
## av_suite and Tools/av/rca_channel_probe read _crt_material, _crt_source_tex,
## _blue_texture, _dark_material and _phosphor_fresh off this helper.
class_name TvDisplay
extends Node

## The set whose glass this owns.
var _tv: RetroTV = null

## The CRT wrapper the set installs over a source's texture.
var _crt_material: ShaderMaterial = null

## The side-by-side window material, for a source handing over a stereo frame.
var _stereo_material: ShaderMaterial = null

## The authored CRT values. crt_mask_pitch_mm and crt_persistence are NOT shader
## uniforms — they are the authoring values behind ones that are, see
## _apply_derived_crt_params and update_phosphor.
var _crt_params := {
	"crt_curvature": 0.0,          # geometry now — see Tools/gen/gen_curved_screen.gd
	"crt_corner_radius": 0.04,
	"crt_mask_mode": 1,
	"crt_mask_strength": 0.55,
	"crt_mask_pitch_mm": 2.0,
	"crt_scanline_strength": 0.6,
	"crt_beam_min": 0.18,
	"crt_beam_max": 0.35,
	"crt_gamma": 1.09,
	"crt_halation": 0.08,
	"crt_glow_radius": 6.0,
	"crt_notch": 0.0,
	"crt_persistence": 0.3,
	"crt_grain": 0.1,
	"crt_smear": 0.0,
	"crt_wiggle": 0.0,
	"crt_vignette": 0.18,
	"crt_brightness": 1.0,
	"crt_glass_reflection": 0.35,
	"crt_glass_roughness": 0.12,
	"crt_glass_wear": 0.35,
	"crt_character": 0.35,
}

## The scale/size the derived uniforms were last solved for, so they are re-solved
## only when one of those actually moves.
var _crt_derived_key: Array = []

## The texture currently being sampled onto the glass.
var _crt_source_tex: Texture2D = null

## Phosphor ping-pong: which of the two viewports is being written this frame.
var _phosphor_write_a: bool = true

## Frames of genuinely new picture since the trail was dropped, so a fresh source
## does not inherit the last one's afterglow.
var _phosphor_fresh: int = 0

## The no-signal blue and the powered-off black, as textures rather than materials
## so they go through the tube stage like every other picture.
var _blue_texture: Texture2D = null
var _dark_texture: Texture2D = null
var _dark_material: ShaderMaterial = null

## Analog snow for an aerial channel with nothing on it. Built on first use.
var _rf_static_material: ShaderMaterial = null

## The CRT power-on animation (a thin horizontal line expanding to full height).
var _poweron_tween: Tween = null


func setup(tv: RetroTV) -> void:
	_tv = tv


## Build the two flat states the set paints when nothing live is showing. Called
## from RetroTV._ready once the fitted tube's size is known.
func build_states() -> void:
	# A texture rather than a material: the no-signal screen is SAMPLED like every
	# other picture, so it goes through the tube stage instead of being a flat
	# rectangle of blue over a curved glass.
	var blue_img := Image.create(2, 2, false, Image.FORMAT_RGB8)
	blue_img.fill(RetroTV.BLUE_SCREEN_COLOR)
	_blue_texture = ImageTexture.create_from_image(blue_img)
	var dark_img := Image.create(2, 2, false, Image.FORMAT_RGB8)
	dark_img.fill(Color.BLACK)
	_dark_texture = ImageTexture.create_from_image(dark_img)
	_dark_material = ShaderMaterial.new()
	_dark_material.shader = RetroTV.CRT_SHADER
	_dark_material.set_shader_parameter("source_tex", _dark_texture)
	_dark_material.set_shader_parameter("crt_enabled", _tv.crt_enabled)
	apply_crt_params(_dark_material)


## Region of a composite framebuffer that is actually visible on the tube. A
## shared 3D light cannot differ per eye, so stereo uses the selected eye when
## forced and the left-eye region in the ordinary per-eye mode.
func screen_light_rect(mat: Material) -> Rect2:
	if not (mat is ShaderMaterial) or (mat as ShaderMaterial).shader != RetroTV.WINDOW_SHADER:
		return Rect2(0.0, 0.0, 1.0, 1.0)
	var shader_mat := mat as ShaderMaterial
	var packed: Variant = shader_mat.get_shader_parameter("source_rect")
	if not (packed is Vector4):
		return Rect2(0.0, 0.0, 1.0, 1.0)
	var value := packed as Vector4
	var rect := Rect2(value.x, value.y, value.z, value.w)
	if _tv.stereo_mode == 2:
		var shift: Variant = shader_mat.get_shader_parameter("eye_shift")
		if shift is float:
			rect.position.x += float(shift)
	return rect


# ── Screen source (blue / dark states) ─────────────────────────────────────────

## Own the "no signal" presentation like a retro TV: ON with no live input →
## blue screen; OFF → black phosphors behind the same reflective glass. Live
## sources (the C++ video handler, the VCR) install their own materials over ours and this
## backs off automatically; when they blank/restore a textureless material we
## take over again next frame.
func update_screen_source() -> void:
	# On the TV input the tuner owns the glass outright: it always has something
	# to show (a picture, or static carrying the reason there isn't one), so the
	# blue screen below must not get a look in. Nothing else is driving the mesh
	# either -- the connected host was muted with set_screen_enabled(false) when
	# the input changed.
	#
	# A broadcast is SAMPLED like every other picture. The tuner used to hand the
	# set a finished StandardMaterial3D, which is the one route onto the glass that
	# skips _show_sampled — so the 4:3/16:9 fit, the tube stage, the OSD and the
	# phosphor all stopped at the TV input while working on composite, and the
	# aspect button appeared dead. Static is still a material of the tuner's own:
	# snow fills the whole tube whatever shape the picture would have been.
	if _tv.is_on() and _tv.current_source == RetroTV.Source.TV and _tv.tuner() != null:
		var tex := _tv.tuner().picture_texture()
		if tex != null:
			_show_sampled(_crt_screen_material(), tex)
			return
		var snow := _tv.tuner().static_material()
		if _tv.screen_mesh().get_surface_override_material(0) != snow:
			drop_sampled()
			_paint(snow)
		return

	# The aerial input paints its own no-signal. A set tuned to a channel nothing is
	# broadcasting on shows SNOW, not a blue screen — and here "nothing" is the
	# ordinary state of whichever of the two channels the switch is not using, so the
	# blue no-signal screen would read as a fault every time you stepped past it.
	# When the channel does match, the host owns the glass and this falls through.
	if _tv.is_on() and _tv.current_source == RetroTV.Source.RF and not _tv.panel().rf_tuned():
		var snow := rf_static()
		if _tv.screen_mesh().get_surface_override_material(0) != snow:
			drop_sampled()
			_paint(snow)
		return

	# The selected input's picture, sampled into a material this set owns.
	if _tv.is_on() and _pull_from_selected():
		return

	# Nothing to show. Every material on the glass is the set's own now, so this no
	# longer has to work out whether it is allowed to paint over what is up there:
	# it is. What stood here read the installed material back to guess whether some
	# host was still live, counted any ShaderMaterial as a picture, and kept a list
	# of which blank states were safe to reclaim while the set was off.
	if not _tv.is_on():
		if _tv.screen_mesh().get_surface_override_material(0) != _dark_material:
			drop_sampled()
			_paint(_dark_material)
		return
	# The blue screen is a picture like any other, so it takes the same route and
	# comes out curved, scanlined and fitted to the tube.
	_show_sampled(_crt_screen_material(), _blue_texture)


## Retro CRT turn-on: the picture starts as a thin horizontal line and expands
## to full height. Scaling the screen mesh squashes everything (picture, OSD).
func play_power_on_anim() -> void:
	if _poweron_tween:
		_poweron_tween.kill()
	_tv.screen_mesh().scale = Vector3(1.0, 0.02, 1.0)
	# Snap to the thin line instantly — don't let physics interpolation smooth
	# the collapse (the expansion itself is tweened below).
	_tv.screen_mesh().reset_physics_interpolation()
	_poweron_tween = create_tween()
	_poweron_tween.tween_interval(0.07)
	_poweron_tween.tween_property(_tv.screen_mesh(), "scale", Vector3.ONE, 0.3) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func stop_power_on_anim() -> void:
	if _poweron_tween:
		_poweron_tween.kill()
		_poweron_tween = null
	_tv.screen_mesh().scale = Vector3.ONE


# ── CRT filter ─────────────────────────────────────────────────────────────────

## Keep the tube stage and the stereo mode in step with the buttons.
##
## Was 118 lines of watching the override each frame to see whether a host had
## installed a new material, reading the texture back out of it, wrapping it in
## ours, and unwrapping it again when the toggle went off - all because the
## material on the glass belonged to somebody else. It belongs to the set, so this
## only writes uniforms. The tube is a stage inside every display shader
## (crt_filter.gdshaderinc), switched by _tv.crt_enabled, whether that shader is the
## set's own or one a source asked for.
func update_crt() -> void:
	var mat := _tv.screen_mesh().get_surface_override_material(0) as ShaderMaterial
	if mat == null:
		return
	var powered: Variant = mat.get_shader_parameter("crt_powered")
	if powered == null or bool(powered) != _tv.is_on():
		mat.set_shader_parameter("crt_powered", _tv.is_on())
	# Writing a uniform a shader does not declare is harmless, so this does not
	# have to know which of the display shaders is currently showing.
	var cur: Variant = mat.get_shader_parameter("_tv.crt_enabled")
	if (cur == true) != _tv.crt_enabled:
		mat.set_shader_parameter("_tv.crt_enabled", _tv.crt_enabled)
		if _tv.crt_enabled:
			apply_crt_params(mat)
	if mat.shader == RetroTV.WINDOW_SHADER:
		var cur_mode: Variant = mat.get_shader_parameter("_tv.stereo_mode")
		if cur_mode != _tv.stereo_mode:
			mat.set_shader_parameter("_tv.stereo_mode", _tv.stereo_mode)


## Show the selected host by SAMPLING the picture it offers, in a material this
## set owns. False when there is nothing to sample — no host on this input, no
## picture yet — and the caller falls through to the set's own no-signal states.
##
## The set has always owned a material that samples a source texture: the CRT
## wrapper. What is new is where the texture comes from. Wrapping meant waiting for
## a host to paint, reading the texture back out of whatever it painted, and
## re-wrapping every time it changed its mind — which is why the old path needed
## _extract_texture, _crt_wrapped and an unwrap ordered against every handover.
func _pull_from_selected() -> bool:
	var host := _tv.panel().selected_system()
	var tex: Texture2D = null
	# Being ON this input is not the same as SENDING a picture to it. The set
	# files a machine on a video input as soon as any cord lands there, on
	# purpose, so its sound routes — and a phono plug fits any phono socket, so
	# an AUDIO cord in the yellow input is ordinary hardware rather than a fault.
	# Without this the set pulled the machine's picture anyway: red lead into the
	# yellow socket, no video cord anywhere, and the game appeared on the glass.
	# The two decks never had the bug because each already refuses its own
	# texture unless a picture cord reached the set (VCRPlayer._feed_video); a
	# console's accessor hands the core's frame to anyone who asks, so the guard
	# has to be here as well as there. Asked of the source, per set.
	if host != null and host.has_method("sends_video_to") and not host.sends_video_to(_tv):
		host = null
	if host != null and host.has_method("get_video_texture"):
		tex = host.get_video_texture()
	if tex == null:
		drop_sampled()
		return false

	# A source may ask for a stage of its own — the VHS effect is one — and the set
	# runs it in a material the set owns. It does not need to know what the stage
	# means: the shader and its uniforms both come from the source, and the CRT
	# stage chains inside it exactly as it did when the deck owned the material.
	# Named, because the answer can depend on which set is asking: a dual-screen
	# machine cabled to two televisions shows each of them a different window of
	# the same frame.
	var stage: Dictionary = host.get_video_stage(_tv) \
		if host.has_method("get_video_stage") else {}
	var shader := stage.get("shader") as Shader
	var stereo := _source_is_sbs()
	var mat: ShaderMaterial
	if shader != null:
		mat = _stage_screen_material(shader)
		var params: Dictionary = stage.get("params", {})
		for key: String in params:
			mat.set_shader_parameter(key, params[key])
	elif stereo:
		mat = _stereo_screen_material()
	else:
		mat = _crt_screen_material()
	_show_sampled(mat, tex)
	return true


## Install one of the set's own materials and point it at a texture. The one place
## a picture reaches the glass, whether it came from a machine, a deck, or the
## set's own no-signal screen.
func _show_sampled(mat: ShaderMaterial, tex: Texture2D) -> void:
	if _tv.screen_mesh().get_surface_override_material(0) != mat:
		drop_sampled()
		_paint(mat)
	# Against _crt_source_tex rather than the material, because the phosphor
	# accumulator legitimately swaps source_tex for its ping-pong buffer — reading
	# it back would look like a source change every frame and undo the persistence.
	var on_crt := mat == _crt_material
	var current: Texture2D = _crt_source_tex if on_crt \
		else mat.get_shader_parameter("source_tex") as Texture2D
	if current == tex:
		return
	mat.set_shader_parameter("source_tex", tex)
	# A different picture: the afterglow of the last one is not this one's history.
	_phosphor_fresh = 2
	# The fit does not survive a new source, and the scanline count is derived
	# from the source's own resolution.
	apply_aspect()
	apply_crt_params(mat)
	if on_crt:
		_crt_source_tex = tex     # what the phosphor accumulator reads


## The set's own material for a sampled picture. _tv.crt_enabled is set at creation
## because the shader's own default is ON, so a set with the tube switched off
## would show one frame of it before update_crt caught up.
func _crt_screen_material() -> ShaderMaterial:
	if _crt_material == null:
		_crt_material = ShaderMaterial.new()
		# A cabinet may paint its screen with a shader of its own. Null is the
		# normal answer and every shipped shell gives it, so this is the stock
		# CRT unless a mod set has genuinely different glass.
		var custom: Shader = _tv.shell().screen_shader() if _tv.shell() != null else null
		_crt_material.shader = custom if custom != null else RetroTV.CRT_SHADER
		# Written unconditionally: a shader that does not declare this uniform
		# ignores it harmlessly, and one that does needs it set before first draw
		# (the shader's own default is ON, so a set with the tube off would
		# otherwise show one frame of it).
		_crt_material.set_shader_parameter("_tv.crt_enabled", _tv.crt_enabled)
	return _crt_material


## True for a material this set samples a source into, as against one a host
## painted for itself. The distinction is what tells "a picture is up" from "the
## set is holding a picture that has stopped arriving".
func _is_sampling_material(mat: Material) -> bool:
	return mat != null and (mat == _crt_material or mat == _stereo_material
		or _stage_materials.values().has(mat))


## Forget the picture the set was sampling, when the source stops offering one —
## a machine switched off, a picture cord pulled out.
##
## Only the set's record of it. The material keeps the dead texture and is simply
## painted over: a sampling material counts as showing nothing (see _effective in
## update_screen_source), and clearing the uniform instead would also strip the
## CRT wrapper when what it happens to be wrapping is the set's own blue screen —
## which renders as a white panel, not a blue one.
func drop_sampled() -> void:
	_crt_source_tex = null
	_crt_derived_key = []
	_phosphor_fresh = 2


## One material per stage shader a source has asked for, kept because the uniforms
## on it (the VHS tuning, the CRT stage's own) are worth not rebuilding per frame.
## Keyed by shader, so two decks asking for the same stage share nothing but the
## shader itself — only one of them can be on the glass at a time.
var _stage_materials := {}


func _stage_screen_material(shader: Shader) -> ShaderMaterial:
	var mat: ShaderMaterial = _stage_materials.get(shader)
	if mat == null:
		mat = ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("_tv.crt_enabled", _tv.crt_enabled)
		_stage_materials[shader] = mat
	return mat


## The same for a full-frame side-by-side source (Virtual Boy): the windowing
## shader takes the left half and shifts +0.5 for the right eye, with the CRT
## stage chained inside it.
func _stereo_screen_material() -> ShaderMaterial:
	if _stereo_material == null:
		_stereo_material = ShaderMaterial.new()
		_stereo_material.shader = RetroTV.WINDOW_SHADER
		_stereo_material.set_shader_parameter("source_rect", Vector4(0.0, 0.0, 0.5, 1.0))
		_stereo_material.set_shader_parameter("eye_shift", 0.5)
		_stereo_material.set_shader_parameter("_tv.stereo_mode", _tv.stereo_mode)
		_stereo_material.set_shader_parameter("_tv.crt_enabled", _tv.crt_enabled)
	return _stereo_material


## Phosphor persistence: run the live frame through the decay accumulator and feed
## the CRT stage the result instead of the raw texture.
##
## Rides the crt_effect wrapper only. The chained VCR and dual-screen window
## shaders keep sampling their source directly — three more ping-pong pairs isn't
## worth it for a tape deck that has its own artefacts and for a handheld panel
## that isn't a tube in the first place.
func update_phosphor() -> void:
	if _crt_material == null or _crt_source_tex == null:
		return
	if _tv.screen_mesh().get_surface_override_material(0) != _crt_material:
		return

	var amount: float = float(_crt_params.get("crt_persistence", 0.0))
	if not _tv.crt_enabled or amount <= 0.001:
		# Hand the raw picture back so turning persistence off is a true bypass.
		if _crt_material.get_shader_parameter("source_tex") != _crt_source_tex:
			_crt_material.set_shader_parameter("source_tex", _crt_source_tex)
		return

	var sz := Vector2i(_crt_source_tex.get_size())
	if sz.x < 2 or sz.y < 2:
		return

	var write: SubViewport = _tv._phosphor_a if _phosphor_write_a else _tv._phosphor_b
	var read: SubViewport = _tv._phosphor_b if _phosphor_write_a else _tv._phosphor_a
	if write.size != sz:
		write.size = sz
		read.size = sz

	var rect := write.get_child(0) as ColorRect
	var pm := rect.material as ShaderMaterial
	pm.set_shader_parameter("src", _crt_source_tex)
	# A fresh source has no afterglow of its own yet, and the buffers still hold the
	# last one's. Blend against the source itself until both have been written.
	if _phosphor_fresh > 0:
		_phosphor_fresh -= 1
		pm.set_shader_parameter("prev", _crt_source_tex)
	else:
		pm.set_shader_parameter("prev", read.get_texture())
	# Red decays slowest, blue fastest, so the afterglow goes warm as it fades.
	pm.set_shader_parameter("decay", Vector3(amount, amount * 0.85, amount * 0.7))
	# UPDATE_ONCE re-armed every frame, never UPDATE_ALWAYS — an ALWAYS render
	# target hangs headless runs.
	write.render_target_update_mode = SubViewport.UPDATE_ONCE

	_crt_material.set_shader_parameter("source_tex", write.get_texture())
	_phosphor_write_a = not _phosphor_write_a


## True when the source ON SCREEN outputs a side-by-side stereo frame (Virtual Boy).
## The one showing, not merely one connected: a VB left plugged into an input nobody
## has selected must not put the other input's picture through a per-eye split.
func _source_is_sbs() -> bool:
	var system := _tv.panel().selected_system()
	return system != null \
		and system.has_method("is_stereo_output") \
		and system.is_stereo_output()


## True while what's showing is a stereo source: a full-frame SBS system (VB)
## or a dual-screen system's window channel with a per-eye shift (3DS top).
## True while something 3D is playing — what both the bezel's 3D key and the
## remote's hide themselves on.
func has_stereo_source() -> bool:
	return _stereo_source_active()


func _stereo_source_active() -> bool:
	if _source_is_sbs():
		return true
	var override := _tv.screen_mesh().get_surface_override_material(0)
	if override is ShaderMaterial and override != _stereo_material \
			and (override as ShaderMaterial).shader == RetroTV.WINDOW_SHADER:
		var es: Variant = (override as ShaderMaterial).get_shader_parameter("eye_shift")
		return es != null and float(es) != 0.0
	return false


## Show the 3D button only while a stereo source is connected. Hidden buttons
## also stop processing and drop off the pointable layer so an invisible
## button can't eat pokes or laser clicks.
func update_stereo_button() -> void:
	if _tv.stereo_btn() == null:
		return
	var active := _stereo_source_active()
	if _tv.stereo_btn().visible != active:
		_tv.stereo_btn().set_active(active)


## Push every tunable CRT uniform onto a material carrying the CRT display stage
## (our wrapper or the chained VCR shader).
func apply_crt_params(mat: ShaderMaterial) -> void:
	for key: String in _crt_params:
		mat.set_shader_parameter(key, _crt_params[key])
	mat.set_shader_parameter("crt_glass_wear_tex", RetroTV.GLASS_WEAR_TEXTURE)
	_apply_derived_crt_params(mat)


func _is_tv_display_shader(shader: Shader) -> bool:
	return shader == RetroTV.CRT_SHADER or shader == RetroTV.VCR_SHADER or shader == RetroTV.WINDOW_SHADER \
		or shader == RetroTV.STATIC_SHADER


## Every cached or currently installed material that can carry the shared tube
## stage. Keeping this list in one place means a glass control changed while the
## set is off still reaches VHS/static/stereo when that source comes back.
func known_display_materials() -> Array[ShaderMaterial]:
	var result: Array[ShaderMaterial] = []
	var candidates: Array[Variant] = [
		_crt_material, _stereo_material, _dark_material, _rf_static_material,
	]
	for candidate: Variant in _stage_materials.values():
		candidates.append(candidate)
	if _tv.screen_mesh() != null:
		candidates.append(_tv.screen_mesh().get_surface_override_material(0))
	for candidate: Variant in candidates:
		if candidate is ShaderMaterial:
			var mat := candidate as ShaderMaterial
			if mat.shader != null and _is_tv_display_shader(mat.shader) and not result.has(mat):
				result.append(mat)
	return result


## Uniforms derived from the set and its current signal rather than authored by a
## slider. They keep the mask/raster fixed to the glass and vary the shared wear
## map between otherwise identical televisions.
func _apply_derived_crt_params(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("crt_powered", _tv.is_on())
	var wear_variant := int(get_instance_id() % 4)
	mat.set_shader_parameter("crt_glass_wear_flip", Vector2(
		float(wear_variant & 1), float((wear_variant >> 1) & 1)))
	# Phosphor pitch is a property of the glass, so the triad count follows the
	# screen's WORLD width: scaling the TV up adds triads instead of stretching
	# them, exactly as a physically bigger tube would.
	var pitch_m: float = maxf(float(_crt_params.get("crt_mask_pitch_mm", 2.0)), 0.05) * 0.001
	var triads: float = (_tv.screen_size_m().x * _tv.scale_factor) / pitch_m
	mat.set_shader_parameter("crt_mask_triads", triads)
	# Slot/shadow phosphor cells run about 1.5x taller than they are wide.
	mat.set_shader_parameter("crt_mask_rows",
		triads * (_tv.screen_size_m().y / _tv.screen_size_m().x) / 1.5)

	# Active lines in the signal, taken from the source itself. A fixed count is
	# the point: the raster belongs to the signal, so walking backwards must not
	# change how many scanlines are on the tube.
	var lines := 240.0
	var tex := mat.get_shader_parameter("source_tex") as Texture2D
	if tex != null:
		var tex_size := tex.get_size()
		if tex_size.x > 0 and tex_size.y > 0:
			mat.set_shader_parameter("crt_source_texel_size", Vector2.ONE / Vector2(tex_size))
		var h: float = tex.get_size().y
		# A window shader shows one sub-rect of a composite framebuffer, so a DS
		# panel has half the lines the texture does.
		var rect: Variant = mat.get_shader_parameter("source_rect")
		if rect is Vector4:
			h *= maxf((rect as Vector4).w, 0.01)
		if h >= 16.0:
			lines = h
	mat.set_shader_parameter("crt_scanline_count", lines)


## The installed material carrying the CRT display stage, if any.
func _active_crt_material() -> ShaderMaterial:
	var override := _tv.screen_mesh().get_surface_override_material(0)
	if override is ShaderMaterial:
		var sh := (override as ShaderMaterial).shader
		if sh != null and _is_tv_display_shader(sh):
			return override as ShaderMaterial
	return null


## Recompute the derived uniforms when what they depend on moves — the TV's
## display scale, the mask pitch, or the source's resolution. Cheap signature
## check so the steady state costs nothing.
func refresh_crt_derived() -> void:
	var mat := _active_crt_material()
	if mat == null:
		return
	var tex := mat.get_shader_parameter("source_tex") as Texture2D
	# Compared as values, not formatted into a string: this runs every frame
	# on every set in the room, and the steady state is meant to cost nothing.
	var key: Array = [
		mat.get_instance_id(), _tv.scale_factor,
		float(_crt_params.get("crt_mask_pitch_mm", 2.0)),
		Vector2i(-1, -1) if tex == null else tex.get_size(),
	]
	if key == _crt_derived_key:
		return
	_crt_derived_key = key
	_apply_derived_crt_params(mat)


## Set one CRT display-stage uniform live (from the TV options panel) and apply
## it to whichever material currently shows the CRT stage.
func set_crt_param(pname: String, value: Variant) -> void:
	if not _crt_params.has(pname):
		return
	_crt_params[pname] = value
	for mat: ShaderMaterial in known_display_materials():
		mat.set_shader_parameter(pname, value)
	# crt_mask_pitch_mm isn't a uniform — it feeds the derived triad count.
	_crt_derived_key = []


## Current CRT tuning values, for the options panel to populate its controls.
func get_crt_params() -> Dictionary:
	return _crt_params.duplicate()


## Seed the CRT tuning from a save. Merges only keys we already know, so a save
## written by a build with a different set of uniforms can't inject stray shader
## parameters, and coerces through the current value's type — JSON gives every
## number back as a float, but crt_mask_mode is an int uniform.
func set_crt_params(values: Dictionary) -> void:
	for key: String in values:
		if not _crt_params.has(key):
			continue
		if typeof(_crt_params[key]) == TYPE_INT:
			_crt_params[key] = int(values[key])
		else:
			_crt_params[key] = float(values[key])
	_crt_derived_key = []
	# Seeded before _ready (scene restore instantiates then sets): the values are
	# in place and get pushed when the filter first wraps a source.
	if _tv.screen_mesh() == null:
		return
	for mat: ShaderMaterial in known_display_materials():
		apply_crt_params(mat)


## Pull the picture texture out of a screen material, whichever shape it has:
## the C++ video handler uses emission, the VCR uses albedo or a video_tex
## uniform, and our own CRT wrapper uses source_tex.
## Replaces _extract_texture, which had to guess where the picture was: the C++
## handler used emission, a deck used albedo or its own video_tex uniform, the
## set's wrapper used source_tex. One convention now, because the set writes them.
func screen_texture() -> Texture2D:
	var mat := _tv.screen_mesh().get_surface_override_material(0)
	if mat is ShaderMaterial:
		return (mat as ShaderMaterial).get_shader_parameter("source_tex") as Texture2D
	if mat is StandardMaterial3D:
		var std := mat as StandardMaterial3D
		return std.emission_texture if std.emission_texture != null else std.albedo_texture
	return null

## How much of the glass the picture should cover, as a fraction per axis.
##
## The tube is whatever shape the shell gave it — not necessarily 4:3 — so the
## fit is computed against the real glass rather than assumed. Whichever axis is
## too generous gets shrunk about the centre and the rest becomes bar.
func _aspect_fit() -> Vector2:
	if _tv.screen_size_m().x <= 0.0 or _tv.screen_size_m().y <= 0.0:
		return Vector2.ONE
	var glass := _tv.screen_size_m().x / _tv.screen_size_m().y
	var want := RetroTV.ASPECT_16_9 if _tv.widescreen else RetroTV.ASPECT_4_3
	if is_equal_approx(glass, want):
		return Vector2.ONE
	if want > glass:
		return Vector2(1.0, glass / want)   # wider than the glass -> bars above/below
	return Vector2(want / glass, 1.0)       # taller -> bars either side


## Push the fit onto whichever material is currently showing the picture. Called
## on every material change as well as on the button, because the display path
## swaps materials underneath us (raw source, CRT wrapper, window shader).
func apply_aspect() -> void:
	var fit := _aspect_fit()
	for mat in [_crt_material, _stereo_material]:
		if mat != null:
			(mat as ShaderMaterial).set_shader_parameter("fit_scale", fit)
	var override := _tv.screen_mesh().get_surface_override_material(0) as ShaderMaterial
	if override != null and override.shader == RetroTV.CRT_SHADER:
		override.set_shader_parameter("fit_scale", fit)


## True when the picture needs shrinking to fit. The raw source material has no
## fit of its own, so this is what decides the CRT wrapper has to go on even
## with the tube effect switched off — otherwise turning CRT off would silently
## stretch the picture back out again.
func aspect_needs_fit() -> bool:
	return not _aspect_fit().is_equal_approx(Vector2.ONE)

## Returns the screen MeshInstance3D so Libretro can render onto it
func get_screen_mesh() -> MeshInstance3D:
	return _tv.screen_mesh()


# ── Who may paint the glass ───────────────────────────────────────────────────
#
# One mesh, one material slot, and until now five things wrote it directly: the
# C++ video handler, both decks, this script, and a dual-screen console's mirror.
# Nothing owned it, so who was showing had to be inferred from whatever material
# happened to be installed — and every bug in this area came from that. A host
# painting an input nobody selected produced a picture on the wrong input; a host
# that stopped painting produced no picture at all. Both were SILENT.
#
# The rule is now stated: a host may put a picture on the glass only while the set
# is showing its input, and may always take its own picture off again. Breaking it
# is an error rather than a wrong picture.


## Who last painted the glass — the set itself, or the host on the shown input.
var _screen_owner: Object = null

## The last caller refused, so a host that keeps asking is reported once rather
## than once per frame.
var _refused: Object = null


## True when `who` is allowed to show a picture right now: the set itself, or the
## host on the selected input while the set is on. RF adds its own condition — a
## console on the aerial input only appears on the channel its switch is using.
func can_paint(who: Object) -> bool:
	if who == _tv:
		return true
	if not _tv.is_on() or who == null:
		return false
	if _tv.current_source == RetroTV.Source.RF and not _tv.panel().rf_tuned():
		return false
	return who == _tv.panel().selected_system()


## Put a material on the glass. Refused, loudly, unless `who` may paint.
func paint_screen(who: Object, mat: Material) -> bool:
	if not can_paint(who):
		if _refused != who:
			_refused = who
			push_error("[RetroTV] %s tried to paint %s while it is showing %s"
				% [who, name, RetroTV.SOURCE_NAMES[_tv.current_source]])
		return false
	_refused = null
	_screen_owner = who
	_tv.screen_mesh().set_surface_override_material(0, mat)
	return true


## Take `who`'s picture off the glass. Always allowed — a host may stop showing
## whenever it likes — but it only clears when the picture up there is actually
## theirs, so a deck being unplugged cannot blank the input somebody is watching.
func release_screen(who: Object) -> void:
	# Or while the set is showing their input: what is on the glass then is
	# theirs by definition, even when the set has wrapped it in its own CRT
	# material and taken nominal ownership doing so.
	if _screen_owner != who and not can_paint(who):
		return
	# update_screen_source paints the right nothing (blue while on, dark while
	# off) on the next frame; clearing the override is what lets it.
	drop_sampled()
	_paint(null)
	_screen_owner = null


## The set's own writes. Separate from paint_screen so the set does not have to
## police itself, and so every write still passes through one place.
func _paint(mat: Material) -> void:
	_screen_owner = _tv
	if mat is ShaderMaterial:
		var shader_mat := mat as ShaderMaterial
		if shader_mat.shader != null and _is_tv_display_shader(shader_mat.shader):
			apply_crt_params(shader_mat)
	_tv.screen_mesh().set_surface_override_material(0, mat)

## Snow for an aerial channel with nothing on it. Built on first use, like the tuner
## — a set that never leaves the composite inputs should not pay for it.
func rf_static() -> ShaderMaterial:
	if _rf_static_material == null:
		_rf_static_material = ShaderMaterial.new()
		_rf_static_material.shader = RetroTV.STATIC_SHADER
	return _rf_static_material


## Feed the room light off whatever the glass is showing. Last in the frame, after
## every material decision above has been made.
##
## Static states do not run the tiny projector viewport: a live full-resolution
## picture stays on the GPU and only its already-blurred 12x8 result is transferred.
func tick_ambilight() -> void:
	# Not gated on the light being visible: the light hides itself while off
	# (ScreenCastLight._apply_energy), so that test would keep a doused set
	# dark for ever - which is what it did between 92294bee and this line.
	if not _tv.ambilight():
		return
	var override := _tv.screen_mesh().get_surface_override_material(0)
	if not _tv.is_on() or override == _dark_material:
		_tv.ambilight().turn_off()
		return
	if _crt_source_tex == _blue_texture:
		_tv.ambilight().show_solid(RetroTV.BLUE_SCREEN_COLOR)
		return
	if override is ShaderMaterial and (override as ShaderMaterial).shader == RetroTV.STATIC_SHADER:
		_tv.ambilight().show_solid(RetroTV.STATIC_LIGHT_COLOR)
		return
	var tex := screen_texture()
	if not tex:
		_tv.ambilight().turn_off()
		return
	_tv.ambilight().show_picture(tex, screen_light_rect(override))

## TvOsd — the set's on-screen display: the corner banner and the volume bar.
##
## A child of the RetroTV it serves, created unconditionally in _init, in the same
## shape as TvResize and TvFit.
##
## The text lives in two places: a 2D Label rendered into OSDViewport (composited
## INSIDE the CRT/VHS shaders so the OSD curves and scanlines with the picture)
## and the legacy OSDLabel Label3D used as a fallback when no shader owns the
## screen. route() picks the right one every frame, from RetroTV._process.
##
## The two tokens are what make a timed message cancellable: every show bumps its
## token, and a pending timer only acts if the token it captured is still current.
## Clearing a bar therefore means bumping the token as well as blanking the text —
## blanking alone leaves an armed timer that blanks it again later.
##
## show_osd / show_osd_timed / hide_osd stay on RetroTV and forward here: the DVD
## and VCR call them on whatever they are cabled to, unguarded, and speaker_pair.gd
## implements the same three names to absorb that.
class_name TvOsd
extends Node

## The set this draws on. The labels and the viewport are its children.
var _tv: RetroTV = null

# Long OSD messages (e.g. "AUDIO: English (Dolby Digital 5.1)" from the DVD/VHS
# track cycling) would otherwise overflow past the edge of the screen at the
# base font size. Short messages ("PLAY", "MUTE", "POWER"...) stay full-size;
# anything past OSD_FIT_CHARS scales down (never below the min) to fit.
const OSD_FIT_CHARS := 10
const OSD_BASE_FONT_SIZE_3D := 64
const OSD_MIN_FONT_SIZE_3D := 24
const OSD_BASE_FONT_SIZE_2D := 44
const OSD_MIN_FONT_SIZE_2D := 18

# One segment per volume step, so the bar has exactly the granularity the keys do.
const VOL_OSD_SEGMENTS := 10
# The margin the bar keeps at each end, as a fraction of the picture width. The
# CRT stage samples the OSD through crt_warp, which pulls the outer few percent
# of the texture off past the curved glass.
const VOL_OSD_SIDE_MARGIN := 0.055
# A ceiling only. The bar is a fixed cell count, so on a normal 4:3 picture the
# solved size lands well under this; the clamp is there so a freak narrow
# viewport can't ask for a 300 px font.
const VOL_OSD_MAX_FONT_SIZE := 128

var _osd_token: int = 0
var _vol_osd_token: int = 0

# What the last route() saw, so an idle OSD on unchanged glass costs nothing.
var _routed: bool = false
var _routed_active: bool = false
var _routed_mat: Material = null


func setup(tv: RetroTV) -> void:
	_tv = tv


## Show a persistent OSD message (stays until replaced or hidden).
func show_text(text: String) -> void:
	_osd_token += 1
	_set_osd_text(text)


## Show an OSD message that auto-hides after `seconds` (unless superseded).
func show_text_timed(text: String, seconds: float) -> void:
	_osd_token += 1
	var tok := _osd_token
	_set_osd_text(text)
	get_tree().create_timer(seconds).timeout.connect(func():
		if tok == _osd_token:
			clear()
	)


## Clear the OSD.
func clear() -> void:
	_osd_token += 1
	_set_osd_text("")


func _fit_osd_font_size(text: String, base_size: int, min_size: int) -> int:
	var length := text.length()
	if length <= OSD_FIT_CHARS:
		return base_size
	return maxi(min_size, int(base_size * OSD_FIT_CHARS / float(length)))


func _set_osd_text(text: String) -> void:
	_tv._osd_label.text = text
	_tv._osd_label.font_size = _fit_osd_font_size(text, OSD_BASE_FONT_SIZE_3D, OSD_MIN_FONT_SIZE_3D)
	_tv._osd_text_2d.text = text
	_tv._osd_text_2d.add_theme_font_size_override(
			"font_size", _fit_osd_font_size(text, OSD_BASE_FONT_SIZE_2D, OSD_MIN_FONT_SIZE_2D))
	_refresh_osd_texture(text)


## Volume-bars OSD (bottom of screen, like an old set): VOL |||||||---
## Independent of the corner OSD; auto-hides after 2 s.
func show_volume() -> void:
	_vol_osd_token += 1
	var tok := _vol_osd_token
	var filled := roundi(_tv._volume * VOL_OSD_SEGMENTS)
	var text := "VOL " + "|".repeat(filled) + "-".repeat(VOL_OSD_SEGMENTS - filled)
	_set_vol_osd_text(text)
	get_tree().create_timer(2.0).timeout.connect(func():
		if tok == _vol_osd_token:
			clear_volume()
	)


## Take the bar down now, cancelling any pending auto-hide with it.
func clear_volume() -> void:
	_vol_osd_token += 1
	_set_vol_osd_text("")


## Solve the font size that makes `text` span `avail` units wide, measuring the
## real font rather than assuming a cell width (the mono family resolves
## differently per platform — Consolas on Windows, Droid Sans Mono on Quest).
## `unit` is the world size of one font pixel (1.0 for a 2D label). Returns 0
## when there is nothing to measure, meaning "leave the size as it is".
func _fit_font_size_to_width(font: Font, text: String, avail: float, unit: float) -> int:
	if font == null or text.is_empty() or avail <= 0.0 or unit <= 0.0:
		return 0
	const PROBE := 64
	var probe_w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, PROBE).x
	if probe_w <= 0.0:
		return 0
	return clampi(int(PROBE * (avail / unit) / probe_w), 8, VOL_OSD_MAX_FONT_SIZE)


# The bar is as wide as the picture, the way a real set draws it. Both copies
# size themselves from the space they actually have — the viewport's width for
# the composited one, the screen quad's own extent for the Label3D fallback —
# so a shell with a different tube gets a bar that still spans it.
func _set_vol_osd_text(text: String) -> void:
	_tv._vol_osd_label.text = text
	var size_3d := _fit_font_size_to_width(_tv._vol_osd_label.font,
			text, _vol_osd_label_width(), _tv._vol_osd_label.pixel_size)
	if size_3d > 0:
		_tv._vol_osd_label.font_size = size_3d
	_tv._vol_osd_text_2d.text = text
	var size_2d := _fit_font_size_to_width(_tv._vol_osd_text_2d.get_theme_font("font"),
			text, _vol_osd_text_2d_width(), 1.0)
	if size_2d > 0:
		_tv._vol_osd_text_2d.add_theme_font_size_override("font_size", size_2d)
	_refresh_osd_texture(text)


## The composited copy fills its own rect, which the tscn insets from the
## viewport edge. Before the first layout pass that rect is still empty, so fall
## back to the inset the constant describes.
func _vol_osd_text_2d_width() -> float:
	var w := _tv._vol_osd_text_2d.size.x
	if w > 0.0:
		return w
	return _tv._osd_viewport.size.x * (1.0 - 2.0 * VOL_OSD_SIDE_MARGIN)


## The Label3D runs rightward from its own origin, so its room is whatever lies
## between that origin and the far margin of the screen quad it hangs on.
func _vol_osd_label_width() -> float:
	if _tv._screen_mesh.mesh == null:
		return 0.0
	var quad_w := _tv._screen_mesh.mesh.get_aabb().size.x
	return quad_w * (0.5 - VOL_OSD_SIDE_MARGIN) - _tv._vol_osd_label.position.x


func _refresh_osd_texture(text: String) -> void:
	# One-shot re-render of the OSD texture (skipped headless — no GPU).
	if text != "" and DisplayServer.get_name() != "headless":
		_tv._osd_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	route()


## Route the OSD to the screen shader when one is active (our CRT wrapper or
## the VCR's VHS material), else to the fallback Label3Ds. Both the corner OSD
## and the volume bars share the same OSD viewport texture.
func route() -> void:
	var main_active := _tv._osd_label.text != ""
	var vol_active := _tv._vol_osd_label.text != ""
	var mat := _tv._screen_mesh.get_surface_override_material(0)
	# Idle on the same glass as last time: every write below would be a repeat.
	var active := main_active or vol_active
	if not active and _routed and not _routed_active and mat == _routed_mat:
		return
	_routed = true
	_routed_active = active
	_routed_mat = mat
	var sm: ShaderMaterial = null
	if mat is ShaderMaterial:
		var candidate := mat as ShaderMaterial
		if candidate == _tv._display._crt_material or candidate.shader == RetroTV.VCR_SHADER \
				or candidate.shader == RetroTV.WINDOW_SHADER \
				or candidate.shader == RetroTV.STATIC_SHADER:
			sm = candidate
	if sm != null:
		sm.set_shader_parameter("osd_tex", _tv._osd_viewport.get_texture())
		sm.set_shader_parameter("osd_enabled", main_active or vol_active)
		_tv._osd_label.visible = false
		_tv._vol_osd_label.visible = false
	else:
		_tv._osd_label.visible = main_active
		_tv._vol_osd_label.visible = vol_active

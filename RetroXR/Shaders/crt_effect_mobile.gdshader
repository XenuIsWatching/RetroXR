// The mobile tier of crt_effect.gdshader: the same wrapper RetroTV installs over
// a picture source, drawn unshaded and opaque, with the tube stage from
// crt_mobile.gdshaderinc. RetroTV.crt_shader() hands this out in place of
// crt_effect when QualityManager.crt_fast is set, which is the mobile renderer's
// default; the uniform contract (source_tex, osd_tex/osd_enabled, fit_scale,
// crt_enabled and the crt_* params) is the full shader's, so TvDisplay does not
// know which of the two it is feeding.
//
// The budget: one source tap under magnification, four under minification, one
// OSD tap while an OSD is showing, and the mask/beam arithmetic. No glow taps,
// no wear texture, no lit glass. See the include for what that costs in look.
shader_type spatial;
// The rounded glass corner is cut with an alpha SCISSOR, so the material stays
// in the OPAQUE pass (no sorting, no blend, depth written). The full shader
// blends instead, which puts every screen in the transparent pass whatever it
// is showing. Not alpha_to_coverage: with that render mode (and its
// ALPHA_ANTIALIASING_EDGE) the picture rendered at half brightness on Forward+,
// measured 236 -> 120 on a white block, so the cut edge is a plain hard step.
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

#include "res://Shaders/crt_mobile.gdshaderinc"
#include "res://Shaders/pixel_aa.gdshaderinc"

// filter_linear is REQUIRED by pixel_aa (it does the sub-pixel ramp).
uniform sampler2D source_tex : source_color, filter_linear, repeat_disable;
uniform sampler2D osd_tex : source_color, filter_linear, repeat_disable;
uniform bool osd_enabled = false;
uniform vec2 fit_scale = vec2(1.0, 1.0);
uniform bool crt_enabled = true;

void fragment() {
	vec2 wuv = crt_enabled ? crt_warp(UV) : UV;
	vec2 fuv = (wuv - 0.5) / fit_scale + 0.5;
	vec3 col = pixel_aa_fast(source_tex, fuv).rgb;

	// Letterbox bars, before the OSD so the menu still reads over them.
	if (any(lessThan(fuv, vec2(0.0))) || any(greaterThan(fuv, vec2(1.0)))) {
		col = vec3(0.0);
	}
	if (osd_enabled) {
		vec4 osd = texture(osd_tex, wuv);
		col = mix(col, osd.rgb, osd.a);
	}
	// The rounded glass corner: the full shader fades ALPHA there and blends;
	// this one scissors it, so the corner shows the bezel just the same while
	// the draw stays opaque. With the tube off the quad is the whole picture and
	// the corner stays square, as it does on the full shader.
	float border = 1.0;
	if (crt_enabled) {
		col = crt_apply(col, wuv);
		border = crt_border(wuv);
		col *= border;
	}
	vec3 picture = clamp(col, 0.0, 1.0);
	ALBEDO = crt_glass_albedo(wuv) + picture + crt_glass_sheen(picture, NORMAL, VIEW);
	ALPHA = border;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}

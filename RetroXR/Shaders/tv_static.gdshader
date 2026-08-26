// Analog snow for RetroXR TV screens — what the set shows on the TV input when
// there is nothing to show: no channel list, an unreachable tuner, a channel
// that will not decode.
//
// Generated rather than sampled, so it costs no texture and never repeats. The
// OSD is composited in exactly as crt_effect.gdshader does it, which is what
// puts the error text on the tube; RetroTV feeds osd_tex/osd_enabled to whatever
// shader is on the screen, so declaring the same two uniforms is the whole
// contract. Runs through the same crt_apply_full stage, so static curves,
// scanlines and blooms like a real picture.
shader_type spatial;
render_mode cull_disabled, shadows_disabled, fog_disabled;

#include "res://Shaders/crt_filter.gdshaderinc"

uniform sampler2D osd_tex : source_color, filter_linear, repeat_disable;
uniform bool osd_enabled = false;

// Driven by RetroTV._update_crt, exactly as the VCR and screen-window shaders
// are. Without it the static would stay curved while the picture path went flat,
// so the screen would change shape when the CRT filter is switched off.
uniform bool crt_enabled = true;

// Snow brightness. Broadcast static is not full-range white noise -- a tube's
// beam never rests, so the floor sits above black -- but it is a good deal
// darker than mid grey, and a bright wall of fizz is both wrong and unpleasant
// to look at on a headset.
uniform float static_level : hint_range(0.0, 1.0) = 0.34;
uniform float static_contrast : hint_range(0.0, 1.0) = 0.62;
// Cells across the screen. Deliberately coarse, and deliberately not square:
// analog snow is chunky grain, not per-pixel fizz. Fine cells also beat against
// the CRT aperture mask and print regular vertical streaks over the whole tube.
uniform vec2 static_cells = vec2(230.0, 170.0);
// Noise regeneration rate. Stepped rather than continuous for the same reason
// crt_filter's grain is: at full amplitude, per-frame noise boils in a headset.
uniform float static_rate = 24.0;
// Slow horizontal roll bar, the drifting band an untuned set shows.
uniform float rollbar_speed = 0.13;
uniform float rollbar_strength : hint_range(0.0, 1.0) = 0.22;

void fragment() {
	vec2 wuv = crt_enabled ? crt_warp(UV) : UV;

	// floor() on BOTH the cell and the time step, for the reason spelled out in
	// crt_filter.gdshaderinc: a hash that varies per render pixel puts different
	// noise in each eye, and the binocular rivalry is genuinely unpleasant. Fixed
	// cells on the glass are something both eyes agree on.
	vec2 cell = floor(wuv * static_cells) + floor(TIME * static_rate) * 131.7;
	float n = crt_hash(cell);

	// A second, coarser layer at a different rate breaks up the uniform fizz --
	// one hash alone reads as a flat grey shimmer rather than snow.
	vec2 coarse = floor(wuv * static_cells * 0.35) + floor(TIME * static_rate * 0.5) * 57.3;
	n = mix(n, crt_hash(coarse), 0.35);

	float v = static_level + (n - 0.5) * static_contrast * 2.0;

	// The roll bar darkens a band that drifts down the screen and wraps.
	float bar = fract(wuv.y - TIME * rollbar_speed);
	v *= 1.0 - rollbar_strength * smoothstep(0.14, 0.0, abs(bar - 0.5) - 0.36);

	vec3 col = vec3(max(v, 0.0));

	if (osd_enabled) {
		vec4 osd = texture(osd_tex, wuv);
		col = mix(col, osd.rgb, osd.a);
	}

	// No glow term: static has no bright source to bloom from, and feeding it one
	// makes the whole screen haze over.
	if (crt_enabled) {
		col = crt_apply_full(col, vec3(0.0), wuv);
	}
	vec3 picture = clamp(col, 0.0, 1.0);
	ALBEDO = vec3(0.006, 0.008, 0.012) * crt_glass_reflection;
	EMISSION = picture + crt_glass_sheen(picture, wuv, NORMAL, VIEW);
	METALLIC = 0.0;
	SPECULAR = 0.5 * crt_glass_reflection;
	ROUGHNESS = crt_glass_roughness;
	CLEARCOAT = crt_glass_reflection;
	CLEARCOAT_ROUGHNESS = crt_glass_roughness;
	// ALPHA is written unconditionally: with the filter off the border term is a
	// flat 1.0, and writing it either way keeps this a transparency-enabled
	// material rather than flipping the pipeline when the toggle moves.
	ALPHA = crt_enabled ? crt_border(wuv) : 1.0;
}

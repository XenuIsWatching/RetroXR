// CRT display filter for RetroXR TV screens.
// Applied by RetroTV as a wrapper over whatever picture source is showing —
// the libretro game texture or the VCR video (when the VHS effect is off).
// The VHS-enabled VCR path instead chains the same filter inside
// vcr_effect.gdshader (see crt_filter.gdshaderinc).
//
// The picture is emitted from behind the shared lit glass surface.
shader_type spatial;
render_mode cull_disabled, shadows_disabled, fog_disabled;

#include "res://Shaders/crt_filter.gdshaderinc"
#include "res://Shaders/pixel_aa.gdshaderinc"

// filter_linear is REQUIRED by pixel_aa (it does the sub-pixel ramp).
//
// This used to sample with plain bilinear on the theory that the CRT stage masks
// the softness anyway, and that pixel-grid snapping would make the VCR's magnified
// video blocky. Neither holds: it left this as the only core-picture path in the
// project that wasn't pixel-AA sampled (and the softest), and at the ~1:1 ratio a
// 640x480 video hits on a 0.35 m tube pixel_aa is within a hair of bilinear, so the
// video concern never bites in practice.
uniform sampler2D source_tex : source_color, filter_linear, repeat_disable;

// On-screen display (green corner text) rendered by the TV into a transparent
// SubViewport texture and composited into the picture BEFORE the CRT stage,
// so the OSD is curved/scanlined like everything else on the tube.
uniform sampler2D osd_tex : source_color, filter_linear, repeat_disable;
uniform bool osd_enabled = false;

// NOTE: stereo side-by-side sources (Virtual Boy) are no longer split here —
// RetroTV wraps them with screen_window.gdshader instead (which chains this
// CRT stage inside it), so the per-eye split works with the CRT off too.

// Aspect fit: how much of the glass the picture occupies on each axis. (1,1)
// fills it, which is what every source did before there was a choice. Below 1
// on an axis, the picture shrinks about the centre and the remainder is black
// bar — set by RetroTV from its 4:3 / 16:9 button.
uniform vec2 fit_scale = vec2(1.0, 1.0);

// Tube stage on/off, same contract as screen_window/vcr_effect/tv_static. The
// wrapper cannot simply be removed to turn the tube off, because it is also what
// carries fit_scale — and a tube whose glass is neither 4:3 nor 16:9 always needs
// a fit, so on those sets the wrapper is pinned and this is the only bypass.
uniform bool crt_enabled = true;

void fragment() {
	vec2 wuv = crt_enabled ? crt_warp(UV) : UV;
	// Fit inside the glass, not around it: the bars are part of the picture the
	// tube shows, so they go through the same stage and curve with it.
	vec2 fuv = (wuv - 0.5) / fit_scale + 0.5;
	// suv is the single-tap position, which the smear and notch taps are placed
	// around; the picture itself comes from pixel_aa, which averages the pixel's
	// footprint when the tube is showing more source texels than it has pixels.
	vec2 suv = pixel_aa_uv(source_tex, fuv);

	vec3 col = pixel_aa(source_tex, fuv).rgb;
	vec3 glow = vec3(0.0);
	if (crt_enabled) {
		col = crt_smear_sample(source_tex, suv, col);
		col = crt_notch_sample(source_tex, suv, col);
		glow = crt_glow(source_tex, fuv);
	}

	// Bars before the OSD, so the OSD still reads over them — a real set draws
	// its menu on top of the letterbox rather than being clipped by it.
	if (any(lessThan(fuv, vec2(0.0))) || any(greaterThan(fuv, vec2(1.0)))) {
		col = vec3(0.0);
		glow = vec3(0.0);
	}

	if (osd_enabled) {
		vec4 osd = texture(osd_tex, wuv);
		col = mix(col, osd.rgb, osd.a);
	}

	if (crt_enabled) {
		col = crt_apply_full(col, glow, wuv);
		// Beyond the curved glass edge the quad is transparent (not black), so the
		// TV bezel shows through instead of a dark rectangle. Only with the tube on:
		// off, the picture fills the quad and ALPHA stays 1, which keeps the surface
		// opaque (it is what the eye buffer's alpha carries under passthrough).
		ALPHA = crt_border(wuv);
	}
	vec3 picture = clamp(col, 0.0, 1.0);
	ALBEDO = vec3(0.006, 0.008, 0.012) * crt_glass_reflection;
	EMISSION = picture + crt_glass_sheen(picture, wuv, NORMAL, VIEW);
	METALLIC = 0.0;
	SPECULAR = 0.5 * crt_glass_reflection;
	ROUGHNESS = crt_glass_roughness;
	CLEARCOAT = crt_glass_reflection;
	CLEARCOAT_ROUGHNESS = crt_glass_roughness;
}

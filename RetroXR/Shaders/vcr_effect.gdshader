// VCR / VHS screen effect for the RetroXR video player.
// Applied as a ShaderMaterial on the TV screen mesh; samples the live video
// texture produced by VlcPlayer and adds the classic tape look:
// chromatic aberration, scanlines, tape grain, a scrolling tracking band,
// horizontal wobble, color washout and a vignette.
//
// The picture is emitted from behind the shared lit glass surface, so room light
// can catch the faceplate without tinting or dimming the tape image itself.
shader_type spatial;
render_mode cull_disabled, shadows_disabled, fog_disabled;

#include "res://Shaders/crt_filter.gdshaderinc"

uniform sampler2D source_tex : source_color, filter_linear, repeat_disable;

// Chained CRT display stage (set by the connected RetroTV when its CRT filter
// is on): tape signal (VHS effects above) → tube (curvature/scanlines/mask).
uniform bool crt_enabled = false;

// On-screen display (green corner text) from the connected TV, composited
// clean over the tape picture (the OSD is generated after tape decode, so it
// doesn't get tape noise) but before the CRT stage (so it curves with the tube).
uniform sampler2D osd_tex : source_color, filter_linear, repeat_disable;
uniform bool osd_enabled = false;

// Master switch (0 = pass the picture through untouched, 1 = full effect).
uniform float effect_amount : hint_range(0.0, 1.0) = 1.0;

uniform float aberration : hint_range(0.0, 0.01) = 0.0025;
uniform float scanline_strength : hint_range(0.0, 1.0) = 0.22;
uniform float scanline_count = 240.0;
uniform float noise_strength : hint_range(0.0, 1.0) = 0.10;
uniform float wobble_strength : hint_range(0.0, 0.02) = 0.0016;
uniform float tracking_speed = 0.18;
uniform float tracking_strength : hint_range(0.0, 0.1) = 0.02;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.30;
uniform float desaturation : hint_range(0.0, 1.0) = 0.15;
uniform float brightness = 1.12;

// ── Extra VHS artifacts (ported from pend00's CC0 "VHS and CRT monitor effect")
// Vertical roll: a slow bright bar that scrolls up the picture, dragging the
// image sideways as it passes (the classic "vertical hold" slip).
uniform float roll_amount : hint_range(0.0, 0.05) = 0.008;
uniform float roll_speed = 0.5;
uniform float roll_size = 8.0;
// Banded noise: animated horizontal bands of static that flicker per-line.
uniform float banded_noise_opacity : hint_range(0.0, 1.0) = 0.15;
uniform float noise_bands = 24.0;
uniform float noise_speed = 8.0;
// Pixelate: crush the sample UV into a coarse grid (VHS luma resolution loss).
uniform bool pixelate = true;
uniform vec2 pixelate_resolution = vec2(640.0, 480.0);
// Discolor: the contrast half of the VHS colour crush (saturation-cut half is
// the existing `desaturation`); pushes mids apart for that punchy tape look.
uniform float vhs_contrast : hint_range(0.5, 2.0) = 1.12;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	if (crt_enabled) {
		// Curve into tube coordinates first: the VHS signal distortions below
		// then happen "on the tube", and the border/scanlines stay fixed to it.
		uv = crt_warp(uv);
	}
	vec2 crt_uv = uv;
	float amt = effect_amount;

	// Scrolling tracking band — a distorted stripe that crawls up the screen,
	// plus a mirrored one near the bottom edge.
	float band = fract(uv.y + TIME * tracking_speed);
	float track = (smoothstep(0.965, 1.0, band) + smoothstep(0.035, 0.0, band)) * amt;

	// Horizontal wobble: a slow sine plus per-scanline jitter, amplified inside
	// the tracking band.
	float line_jitter = hash(vec2(floor(uv.y * scanline_count), floor(TIME * 24.0))) - 0.5;
	float wob = sin(uv.y * 60.0 + TIME * 5.0) * wobble_strength;
	uv.x += (wob + line_jitter * tracking_strength * track) * amt;

	// Vertical roll: a soft bar scrolling up the frame that slips the picture
	// sideways as it passes (distinct, slower than the tracking band above).
	float rb = fract(uv.y * roll_size - TIME * roll_speed);
	float roll = smoothstep(0.0, 0.2, rb) * smoothstep(0.4, 0.2, rb);
	uv.x += roll * roll_amount * amt;

	// Pixelate the sample UV into a coarse grid (VHS luma-only resolution loss).
	if (pixelate) {
		vec2 puv = (floor(uv * pixelate_resolution) + 0.5) / pixelate_resolution;
		uv = mix(uv, puv, amt);
	}

	// Chromatic aberration — split the colour channels horizontally, stronger in
	// the tracking band.
	float ab = aberration * amt * (1.0 + track * 4.0);
	float r = texture(source_tex, uv + vec2(ab, 0.0)).r;
	float g = texture(source_tex, uv).g;
	float b = texture(source_tex, uv - vec2(ab, 0.0)).b;
	vec3 col = vec3(r, g, b);

	// Slight colour washout, then the VHS contrast crush (discolor).
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(luma), desaturation * amt);
	col = mix(col, (col - 0.5) * vhs_contrast + 0.5, amt);

	// Scanlines.
	float scan = sin(uv.y * scanline_count * 3.14159) * 0.5 + 0.5;
	col *= 1.0 - scanline_strength * scan * amt;

	// Tape grain.
	float n = hash(uv * vec2(320.0, 240.0) + fract(TIME) * 60.0);
	col += (n - 0.5) * noise_strength * amt;

	// Banded noise: horizontal stripes of static that flicker per-line.
	float nb = hash(vec2(floor(uv.y * noise_bands), floor(TIME * noise_speed)));
	col *= 1.0 - banded_noise_opacity * amt * step(0.6, nb);

	// Bright static crackle inside the tracking band.
	col += track * (hash(uv + fract(TIME)) - 0.3) * 0.5;

	// Vignette.
	vec2 vc = uv - 0.5;
	col *= 1.0 - dot(vc, vc) * vignette_strength * 2.0 * amt;

	col *= mix(1.0, brightness, amt);

	if (osd_enabled) {
		// Sample in tube space (pre-wobble) so the OSD stays put while the
		// tape picture swims underneath it.
		vec4 osd = texture(osd_tex, crt_uv);
		col = mix(col, osd.rgb, osd.a);
	}

	if (crt_enabled) {
		// Display stage: scanlines/mask/vignette in tube space (pre-wobble so
		// the tube geometry doesn't jitter with the tape). Beyond the curved
		// glass edge the quad goes transparent so the bezel shows through.
		col = crt_apply(col, crt_uv);
		ALPHA = crt_border(crt_uv);
	}

	vec3 picture = clamp(col, 0.0, 1.0);
	ALBEDO = vec3(0.006, 0.008, 0.012) * crt_glass_reflection;
	EMISSION = picture + crt_glass_sheen(picture, crt_uv, NORMAL, VIEW);
	METALLIC = 0.0;
	SPECULAR = 0.5 * crt_glass_reflection;
	ROUGHNESS = crt_glass_roughness;
	CLEARCOAT = crt_glass_reflection;
	CLEARCOAT_ROUGHNESS = crt_glass_roughness;
}

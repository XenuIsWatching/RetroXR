// The mobile tube stage: crt_filter.gdshaderinc with everything that does not
// survive a headset's viewing distance taken out, for the Quest's fragment budget.
//
// Included by crt_effect_mobile.gdshader, which RetroTV installs instead of
// crt_effect.gdshader when QualityManager.crt_fast is set (the mobile renderer's
// default). Same uniform names as the full stage, so TvDisplay pushes the same
// _crt_params at it and the options panel's sliders keep working where the
// feature exists; a slider for a feature this tier drops (halation, grain,
// composite blend, smear, glass wear) is inert on this shader rather than an error.
//
// What is kept, and why each survives:
//   * Tube-UV anchoring and analytic antialiasing of mask and raster. These are
//     the binocular-comfort decisions the full file explains at length; a mobile
//     tier that keyed anything to FRAGCOORD would shimmer in the headset.
//   * Zero-mean mask and beam, so the picture's brightness does not drift with
//     distance and crt_brightness stays 1.0.
//   * The brightness-dependent beam. The full stage integrates a Gaussian over
//     the pixel footprint with six erf evaluations; this evaluates the same
//     periodic Gaussian's first two Fourier harmonics, each box-filtered by the
//     footprint, which is the same integral truncated after the second term.
//     At the shipped sigmas (0.18..0.35 scanlines) the third harmonic is below
//     0.6% and the result is visually the full beam; only a beam thinned well
//     below 0.15 shows the truncation as a softer gap between lines.
//   * The aperture grille, evaluated from ONE sin/cos pair: the three phosphor
//     phases and the second harmonic are rotations of it, so the output is the
//     full stage's grille to float precision.
//   * Gamma, vignette, the glass edge and a Fresnel sheen cue.
//
// What is gone: slot/shadow masks (they read as an aperture grille on this tier),
// halation and the CRT-character bloom (four source taps), grain (a hash per
// pixel, and TIME), convergence (colour derivatives), the composite notch and
// chroma smear (two taps each), the fingerprint mask (a texture tap), and the lit
// PBR glass with its clearcoat. The caller is unshaded and draws in the opaque
// pass: the rounded corner is an alpha SCISSOR under alpha-to-coverage rather
// than the blended fade the full stage writes. (The tube collar in tv.tscn does
// not hide that corner, as a render of the set with no cut confirmed.)
//
// Colour space is linear throughout, as in the full stage: `source_color`
// samplers hand back linear and ALBEDO on an unshaded material is linear.

// Uniforms the options panel drives. Ranges match crt_filter.gdshaderinc.
uniform float crt_curvature : hint_range(0.0, 0.3) = 0.0;
uniform float crt_corner_radius : hint_range(0.001, 0.2) = 0.04;
// 0 = off; any other mode draws the aperture grille.
uniform int crt_mask_mode : hint_range(0, 3) = 1;
uniform float crt_mask_strength : hint_range(0.0, 1.0) = 0.55;
uniform float crt_mask_triads = 175.0;
uniform float crt_scanline_strength : hint_range(0.0, 1.0) = 0.6;
uniform float crt_scanline_count = 240.0;
uniform float crt_beam_min : hint_range(0.05, 0.5) = 0.18;
uniform float crt_beam_max : hint_range(0.05, 0.8) = 0.35;
uniform float crt_gamma : hint_range(0.8, 1.4) = 1.09;
uniform float crt_vignette : hint_range(0.0, 1.0) = 0.18;
uniform float crt_brightness : hint_range(0.5, 2.0) = 1.0;
uniform float crt_glass_reflection : hint_range(0.0, 1.0) = 0.35;
uniform bool crt_powered = true;
const vec3 CRT_GLASS_TINT = vec3(0.42, 0.56, 0.72);


float crt_luminance(vec3 col) {
	return dot(col, vec3(0.2126, 0.7152, 0.0722));
}

// The pixel-area (box) response of a cosine harmonic sampled at `f` cycles per
// pixel: the integral of the harmonic over one pixel, normalised.
float crt_box(float f) {
	float a = PI * f;
	return (a < 1e-4) ? 1.0 : sin(a) / a;
}

// Box response plus the Nyquist guard, exactly as the full stage defines it: the
// box alone still passes 64% of a harmonic at two samples per cycle, and what it
// passes beats against the pixel grid into broad bands.
float crt_band(float f) {
	if (f >= 0.45) {
		return 0.0;
	}
	return max(crt_box(f), 0.0) * (1.0 - smoothstep(0.25, 0.45, f));
}


// ── Tube coordinates ──────────────────────────────────────────────────────────

vec2 crt_warp(vec2 uv) {
	if (crt_curvature > 0.0) {
		vec2 cc = uv * 2.0 - 1.0;
		cc *= 1.0 + crt_curvature * dot(cc, cc);
		return cc * 0.5 + 0.5;
	}
	return uv;
}

// 1.0 inside the rounded glass, 0.0 outside. Multiplied into the picture rather
// than written to ALPHA: the caller is opaque.
float crt_border(vec2 wuv) {
	vec2 b = abs(wuv - 0.5) - (vec2(0.5) - vec2(crt_corner_radius));
	float d = length(max(b, vec2(0.0))) - crt_corner_radius;
	return 1.0 - smoothstep(-0.006, 0.0, d);
}


// ── Glass ─────────────────────────────────────────────────────────────────────

vec3 crt_glass_albedo(vec2 uv) {
	vec2 edge_uv = abs(uv - 0.5) * 2.0;
	float edge = smoothstep(0.70, 1.0, max(edge_uv.x, edge_uv.y));
	vec3 active = vec3(0.006, 0.008, 0.012) * crt_glass_reflection;
	vec3 unlit = vec3(0.008, 0.013, 0.022)
		* mix(0.62, 1.32, crt_glass_reflection) * mix(1.0, 0.55, edge);
	return crt_powered ? active : unlit;
}

// The front-surface glint reduced to its Fresnel term. The full stage reflects a
// world-space room lobe and lets the renderer add real light and probe response;
// this tier has neither, so a fixed environment share stands in for the lobe.
// `normal` and `view` are the fragment built-ins, already unit length.
vec3 crt_glass_sheen(vec3 picture, vec3 normal, vec3 view) {
	if (crt_glass_reflection <= 0.0) {
		return vec3(0.0);
	}
	float ndv = clamp(abs(dot(normal, view)), 0.0, 1.0);
	float f = 1.0 - ndv;
	float f2 = f * f;
	float fresnel = 0.04 + 0.96 * f2 * f2 * f;
	float darkness = 1.0 - smoothstep(0.03, 0.75, crt_luminance(picture));
	float off_boost = crt_powered ? 1.0 : 0.62;
	float strength = (0.12 * fresnel + 0.021)
		* mix(0.28, 1.0, darkness) * crt_glass_reflection * off_boost;
	return CRT_GLASS_TINT * strength;
}


// ── Display stage ─────────────────────────────────────────────────────────────

// Aperture grille from one sin/cos pair. Each channel is
// 1 + a1 cos(phi_k) + 0.5 a2 cos(2 phi_k) with phi_k = phi - k 2pi/3, and every
// cos(phi - k 2pi/3) is -0.5 cos(phi) +/- 0.866 sin(phi), so the three phases and
// the second harmonic all come from cos(phi), sin(phi) and the double-angle
// identities. Same series, same coefficients and same antialiasing as
// crt_filter's mode 1, without three of the four transcendentals.
vec3 crt_mask(vec2 wuv) {
	if (crt_mask_mode == 0 || crt_mask_strength <= 0.0) {
		return vec3(1.0);
	}
	float tx = wuv.x * crt_mask_triads;
	float fw = fwidth(tx);
	float a1 = crt_band(fw);
	if (a1 <= 0.0) {
		return vec3(1.0);
	}
	float a2 = crt_band(2.0 * fw);
	float ph = TAU * tx;
	float c = cos(ph);
	float s = sin(ph);
	const float H = 0.8660254;
	vec3 m = vec3(1.0) + a1 * vec3(c, -0.5 * c + H * s, -0.5 * c - H * s);
	if (a2 > 0.0) {
		float c2 = c * c - s * s;
		float s2 = 2.0 * c * s;
		// cos(2 phi - 4pi/3) and cos(2 phi - 8pi/3): the green and blue phases
		// swap sides relative to the first harmonic.
		m += (0.5 * a2) * vec3(c2, -0.5 * c2 - H * s2, -0.5 * c2 + H * s2);
	}
	return mix(vec3(1.0), max(m, vec3(0.0)), crt_mask_strength);
}

// Electron beam profile as a truncated Fourier series of the pixel-integrated
// periodic Gaussian. The n-th harmonic of a unit-area Gaussian of sigma (in
// scanlines) repeated every scanline has amplitude 2 exp(-2 pi^2 sigma^2 n^2);
// box-filtering each over the footprint `ph` is the integral the full stage
// evaluates with erf. Fade-out and early-out thresholds are the full stage's.
float crt_beam(vec2 wuv, float lum) {
	if (crt_scanline_strength <= 0.0) {
		return 1.0;
	}
	float sl = wuv.y * crt_scanline_count;
	float ph = max(fwidth(sl), 1e-4);
	if (ph >= 0.8) {
		return 1.0;
	}
	float sig = mix(crt_beam_min, crt_beam_max, pow(clamp(lum, 0.0, 1.0), 1.0 / 3.0));
	// 2 pi^2 log2(e), so one exp2 gives exp(-2 pi^2 sigma^2).
	float g = exp2(-28.4776 * sig * sig);
	float c = cos(TAU * sl);
	float w = 1.0 + 2.0 * g * crt_box(ph) * c;
	float g4 = g * g;
	g4 *= g4;
	w += 2.0 * g4 * crt_box(2.0 * ph) * (2.0 * c * c - 1.0);
	w = max(w, 0.0);
	w = mix(w, 1.0, smoothstep(0.4, 0.8, ph));
	return mix(1.0, w, crt_scanline_strength);
}

vec3 crt_apply(vec3 col, vec2 wuv) {
	col = pow(max(col, vec3(0.0)), vec3(crt_gamma));
	col *= crt_beam(wuv, max(max(col.r, col.g), col.b));
	col *= crt_mask(wuv);
	vec2 vc = wuv - 0.5;
	col *= 1.0 - dot(vc, vc) * crt_vignette * 2.0;
	return col * crt_brightness;
}

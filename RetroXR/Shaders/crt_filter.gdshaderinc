// Shared CRT display filter for RetroXR TV screens.
//
// Included by crt_effect.gdshader (wraps any picture source), screen_window.gdshader
// (dual-screen handhelds mirrored to a TV) and vcr_effect.gdshader (chained after
// the VHS pass). Public interface:
//   crt_warp(uv)                  → tube UV (VHS wiggle + optional extra barrel)
//   crt_border(wuv)               → glass-edge alpha
//   crt_notch_sample(t, uv, base) → composite-cable horizontal notch
//   crt_glow(tex, uv)             → halation, added AFTER the mask
//   crt_apply(col, wuv)           → beam + mask + vignette
//   crt_apply_full(col, glow, wuv)
//
// ── Why this is not a port of a libretro CRT shader ──────────────────────────
//
// Every desktop CRT shader (Lottes, royale, guest, easymode) keys its mask and
// scanlines off gl_FragCoord, because a fullscreen post-process may assume the
// tube fills the display and that the display's pixel grid is the finest thing
// that exists. On a world-space tube seen through two eyes, both halves fail:
//
//   * The tube is an object at a variable distance. Its phosphor pitch and
//     scanline count are properties of the GLASS, not of the panel. Keyed to
//     FRAGCOORD, a triad stays the same number of render pixels wide however
//     close you get — so leaning in never resolves the phosphors, it just shows
//     the same fixed screen-space dither. (The version this replaced claimed the
//     opposite in its header comment; it was wrong.)
//   * Anything derived from FRAGCOORD lands on a different phase in each eye.
//     A high-contrast stripe pattern that differs per eye is binocular rivalry:
//     it shimmers, refuses to fuse, and causes eye strain.
//
// So mask and beam are computed in TUBE UV and antialiased against the screen-space
// derivative. Everything below follows from that one decision.
//
// Colour space: this whole file works in LINEAR light. `source_color` samplers hand
// back linear (Godot binds the sRGB texture view), and ALBEDO is linear on an
// unshaded spatial material, with the renderer doing the sRGB encode. Mask and beam
// multiplies are light-transport operations and belong exactly here.

// ── Geometry ────────────────────────────────────────────────────────────────
// The tube face is real curved GEOMETRY now (Scenes/Objects/tv_models/tv_screen_curved.res),
// so this barrel warp defaults to off. A UV warp is monoscopic — it has no parallax
// and no binocular depth, so in a headset it reads as a flat sticker. Kept only as
// an extra stylistic knob.
uniform float crt_curvature : hint_range(0.0, 0.3) = 0.0;
uniform float crt_corner_radius : hint_range(0.001, 0.2) = 0.04;

// ── Phosphor mask ───────────────────────────────────────────────────────────
// 0 = off, 1 = aperture grille, 2 = slot mask, 3 = shadow mask.
uniform int crt_mask_mode : hint_range(0, 3) = 1;
uniform float crt_mask_strength : hint_range(0.0, 1.0) = 0.55;
// Triads across the tube's width and phosphor rows down its height. Both are set
// from tv.gd out of a physical pitch in mm times the screen's world size, so
// scaling the TV up adds triads instead of growing them.
uniform float crt_mask_triads = 175.0;
uniform float crt_mask_rows = 83.0;

// ── Electron beam ───────────────────────────────────────────────────────────
uniform float crt_scanline_strength : hint_range(0.0, 1.0) = 0.6;
// Active lines in the signal — 224, 240, 480… Set from the source texture height.
uniform float crt_scanline_count = 240.0;
// Beam sigma in scanline units, for black and for full white. The beam gets FATTER
// as it gets brighter (more gun current = bigger spot); that bloom is the strongest
// single "this is a tube" cue.
uniform float crt_beam_min : hint_range(0.05, 0.5) = 0.18;
uniform float crt_beam_max : hint_range(0.05, 0.8) = 0.35;

// ── Tube response ───────────────────────────────────────────────────────────
// CRT gamma over panel gamma (2.4 / 2.2). Content was authored on ~2.4 gamma tubes;
// the headset panel is ~2.2, so without this the shadows sit flat and washed out.
uniform float crt_gamma : hint_range(0.8, 1.4) = 1.09;
uniform float crt_halation : hint_range(0.0, 0.5) = 0.08;
uniform float crt_glow_radius : hint_range(1.0, 16.0) = 6.0;

// ── Signal artefacts ────────────────────────────────────────────────────────
uniform float crt_notch : hint_range(0.0, 1.0) = 0.0;
uniform float crt_grain : hint_range(0.0, 1.0) = 0.10;
uniform float crt_smear : hint_range(0.0, 1.0) = 0.0;
uniform float crt_wiggle : hint_range(0.0, 0.2) = 0.0;

// ── Tube light ──────────────────────────────────────────────────────────────
uniform float crt_vignette : hint_range(0.0, 1.0) = 0.18;
// 1.0 is correct: the mask and the beam are both normalised to a mean of exactly
// 1.0, so neither costs any light and there is nothing to compensate for.
uniform float crt_brightness : hint_range(0.5, 2.0) = 1.0;

// ── Faceplate glass ─────────────────────────────────────────────────────
// The picture is emitted from behind a dark dielectric surface rather than
// written straight into unshaded ALBEDO. The renderer supplies the real light /
// reflection-probe response; the analytic world-space sheen below is a cheap
// fallback for the mobile renderer and rooms without a useful probe.
uniform float crt_glass_reflection : hint_range(0.0, 1.0) = 0.35;
uniform float crt_glass_roughness : hint_range(0.02, 0.6) = 0.12;
uniform float crt_glass_wear : hint_range(0.0, 1.0) = 0.35;
uniform float crt_character : hint_range(0.0, 1.0) = 0.35;
uniform bool crt_powered = true;
uniform vec2 crt_source_texel_size = vec2(0.0015625, 0.0020833333);
uniform sampler2D crt_glass_wear_tex : hint_default_black, filter_linear_mipmap, repeat_disable;
// One of four mirrored orientations, assigned per set so a row of televisions
// does not advertise that it shares one fingerprint mask.
uniform vec2 crt_glass_wear_flip = vec2(0.0);
const vec3 CRT_GLASS_TINT = vec3(0.42, 0.56, 0.72);


// ── Helpers ─────────────────────────────────────────────────────────────────

// Integer-free hash. The classic sin(dot(p, k)) * 43758.5453 bands rather than
// dithers at large UV magnitudes on mobile mediump.
float crt_hash(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

float crt_luminance(vec3 col) {
	return dot(col, vec3(0.2126, 0.7152, 0.0722));
}

float crt_glass_wear_mask(vec2 uv) {
	if (crt_glass_wear <= 0.0) {
		return 0.0;
	}
	vec2 wear_uv = mix(uv, vec2(1.0) - uv, crt_glass_wear_flip);
	// Lift faint cleaning streaks without turning the mask's clean black areas
	// into a veil. Mip filtering keeps fingerprint ridges stable in both XR eyes.
	float mask = texture(crt_glass_wear_tex, wear_uv).r;
	return smoothstep(0.018, 0.72, mask) * crt_glass_wear;
}

float crt_glass_roughness_value(float wear) {
	return mix(crt_glass_roughness, max(crt_glass_roughness, 0.46), wear);
}

float crt_glass_specular_value(float wear) {
	return clamp(0.5 * crt_glass_reflection * mix(1.0, 1.42, wear), 0.0, 1.0);
}

float crt_glass_clearcoat_value(float wear) {
	return crt_glass_reflection * mix(1.0, 0.58, wear);
}

float crt_glass_clearcoat_roughness_value(float wear) {
	return mix(crt_glass_roughness, max(crt_glass_roughness, 0.38), wear);
}

// The unlit tube is absorptive blue-grey glass rather than a black emissive
// picture. Extra density at the perimeter suggests the longer path through the
// curved faceplate while the separate collar supplies actual binocular depth.
vec3 crt_glass_albedo(vec2 uv) {
	vec2 edge_uv = abs(uv - 0.5) * 2.0;
	float edge = smoothstep(0.70, 1.0, max(edge_uv.x, edge_uv.y));
	vec3 active = vec3(0.006, 0.008, 0.012) * crt_glass_reflection;
	vec3 unlit = vec3(0.008, 0.013, 0.022)
		* mix(0.62, 1.32, crt_glass_reflection) * mix(1.0, 0.55, edge);
	return crt_powered ? active : unlit;
}

// A restrained front-surface glint. The reflected ray is transformed to WORLD
// space before it meets the fallback room light, so turning or carrying the set
// moves the reveal across the fingerprints instead of pinning it to one screen
// corner. inv_view is passed in because Godot exposes built-ins only directly in
// fragment(), not inside included helpers.
vec3 crt_glass_sheen(vec3 picture, vec3 normal, vec3 view, float wear, mat4 inv_view) {
	if (crt_glass_reflection <= 0.0) {
		return vec3(0.0);
	}
	vec3 n = normalize(normal);
	vec3 v = normalize(view);
	float ndv = clamp(abs(dot(n, v)), 0.0, 1.0);
	float fresnel = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);

	// A broad overhead/window lobe in the room, not on the tube. The curved glass
	// supplies a changing normal across its face, while moving the TV changes that
	// normal in world space. Both make the highlight travel naturally.
	vec3 reflected_world = normalize((inv_view * vec4(reflect(-v, n), 0.0)).xyz);
	vec3 room_light = normalize(vec3(-0.48, 0.68, 0.56));
	float window_lobe = pow(max(dot(reflected_world, room_light), 0.0), 5.0);
	float overhead = smoothstep(0.18, 0.82, reflected_world.y) * 0.28;
	float environment = max(window_lobe, overhead);

	// Bright phosphors overpower reflections; black glass carries them clearly.
	float darkness = 1.0 - smoothstep(0.03, 0.75, crt_luminance(picture));
	float off_boost = crt_powered ? 1.0 : 0.62;
	float strength = (0.12 * fresnel + 0.075 * environment)
		* mix(0.28, 1.0, darkness) * crt_glass_reflection * off_boost;
	// Wear is revealed only where the faceplate is already reflective. Dark
	// phosphors and grazing angles expose it; a bright picture overwhelms it.
	float reflection = max(fresnel, environment);
	float artifact = wear * (0.025 + 0.20 * reflection)
		* mix(0.20, 1.0, darkness) * crt_glass_reflection;
	return CRT_GLASS_TINT * (strength + artifact);
}

// How much of a cosine harmonic survives being sampled at a footprint of `f`
// cycles per pixel — the term that makes the mask and the raster antialias
// themselves, with no mip chain, no LUT and no hand-tuned fade.
//
// Two factors, and BOTH are needed:
//
//   sin(pi f)/(pi f)   the exact box-filter (pixel-area) response.
//   1 - smoothstep     a Nyquist guard.
//
// The box filter alone is not enough, and assuming it was is a real trap: it only
// ATTENUATES at Nyquist rather than removing anything. At 2 samples per cycle it
// still passes 64% of the harmonic, which then beats against the pixel grid into
// broad low-frequency bands — far uglier than the detail it was trying to keep.
// A box filter is the right pre-filter only if you then reconstruct continuously;
// we point-sample, so anything left above Nyquist aliases. Hence the guard, which
// takes each harmonic to zero shortly before its own Nyquist limit.
float crt_band(float f) {
	float a = PI * f;
	float box = (abs(a) < 1e-4) ? 1.0 : sin(a) / a;
	return max(box, 0.0) * (1.0 - smoothstep(0.25, 0.45, f));
}

// erf, approximated: max abs error ~2.8e-3 for 1 exp2 + 1 sqrt.
float crt_erf(float x) {
	float s = sign(x);
	float a = x * x;
	return s * sqrt(max(1.0 - exp2(-1.8368 * a), 0.0));   // -4/(pi*ln2)
}

vec3 rgb2yiq(vec3 c) {
	return vec3(
		0.2989 * c.r + 0.5959 * c.g + 0.2115 * c.b,
		0.5870 * c.r - 0.2744 * c.g - 0.5229 * c.b,
		0.1140 * c.r - 0.3216 * c.g + 0.3114 * c.b);
}

vec3 yiq2rgb(vec3 c) {
	return vec3(
		c.x + c.y + c.z,
		0.956 * c.x - 0.2720 * c.y - 1.1060 * c.z,
		0.6210 * c.x - 0.6474 * c.y + 1.7046 * c.z);
}


// ── Tube coordinates ────────────────────────────────────────────────────────

// Quad UV → tube UV. Curvature is geometry now, so by default this only carries
// the VCR's wiggle.
vec2 crt_warp(vec2 uv) {
	if (crt_wiggle > 0.0) {
		uv.x += (crt_hash(vec2(uv.y * 8.0, floor(TIME * 30.0))) - 0.5) * crt_wiggle * 0.15;
	}
	if (crt_curvature > 0.0) {
		vec2 cc = uv * 2.0 - 1.0;
		cc *= 1.0 + crt_curvature * dot(cc, cc);
		return cc * 0.5 + 0.5;
	}
	return uv;
}

// 1.0 inside the rounded screen glass, fading to 0.0 outside.
float crt_border(vec2 wuv) {
	vec2 b = abs(wuv - 0.5) - (vec2(0.5) - vec2(crt_corner_radius));
	float d = length(max(b, vec2(0.0))) - crt_corner_radius;
	return 1.0 - smoothstep(-0.006, 0.0, d);
}


// ── Signal ──────────────────────────────────────────────────────────────────

// Composite-cable horizontal notch: [1, 2, 1] / 4 at exactly one source-texel pitch.
//
// That kernel's frequency response has an exact zero at Nyquist, and a 2-pixel
// alternating dither sits exactly at Nyquist — so it collapses to a flat 50% blend.
// This is the actual mechanism by which a composite cable's chroma trap turned
// Sonic's waterfall dither into transparency, not an imitation of it.
vec3 crt_notch_sample(sampler2D tex, vec2 uv, vec3 base) {
	if (crt_notch <= 0.0) {
		return base;
	}
	float tx = 1.0 / float(textureSize(tex, 0).x);
	vec3 l = texture(tex, uv - vec2(tx, 0.0)).rgb;
	vec3 r = texture(tex, uv + vec2(tx, 0.0)).rgb;
	return mix(base, 0.25 * l + 0.5 * base + 0.25 * r, crt_notch);
}

// Windowed form for a screen packed beside another screen in one texture.
// Clamp to texel centres; a bilinear tap on rect.xy itself spans both windows.
vec3 crt_notch_sample_rect(sampler2D tex, vec2 uv, vec3 base, vec4 rect) {
	if (crt_notch <= 0.0) {
		return base;
	}
	vec2 texel = 1.0 / vec2(textureSize(tex, 0));
	vec2 lo = rect.xy + 0.5 * texel;
	vec2 hi = rect.xy + rect.zw - 0.5 * texel;
	vec3 l = texture(tex, clamp(uv - vec2(texel.x, 0.0), lo, hi)).rgb;
	vec3 r = texture(tex, clamp(uv + vec2(texel.x, 0.0), lo, hi)).rgb;
	return mix(base, 0.25 * l + 0.5 * base + 0.25 * r, crt_notch);
}

// Optional NTSC-style chroma smear: keep luma sharp, bleed I/Q from taps to the
// right. Offsets are in source texels so the bleed distance doesn't change with
// the core's resolution.
//
// `base` is the picture colour at `uv`, passed in rather than sampled here so the
// luma this keeps is the caller's footprint-aware one (see pixel_aa.gdshaderinc);
// the I/Q taps are single taps because chroma is being deliberately blurred anyway.
vec3 crt_smear_sample(sampler2D tex, vec2 uv, vec3 base) {
	if (crt_smear <= 0.0) {
		return base;
	}
	float d = crt_smear * 3.0 / float(textureSize(tex, 0).x);
	vec3 y0 = rgb2yiq(base);
	vec3 yi = rgb2yiq(texture(tex, uv + vec2(d, 0.0)).rgb);
	vec3 yq = rgb2yiq(texture(tex, uv + vec2(d * 2.2, 0.0)).rgb);
	return yiq2rgb(vec3(y0.x, yi.y, yq.z));
}

// Halation: light scattered under the faceplate, re-exciting distant phosphors.
// Squared because it is superlinear in brightness (it only really shows on
// near-white content), and warm because the red phosphor scatters most.
//
// `rect` is the (x, y, w, h) UV window the picture actually occupies, so a screen
// windowed out of a composite framebuffer (a DS panel) can't pull glow in from the
// other screen packed alongside it.
vec3 crt_glow_rect(sampler2D tex, vec2 uv, vec4 rect) {
	if (crt_halation <= 0.0 && crt_character <= 0.0) {
		return vec3(0.0);
	}
	vec2 r = crt_glow_radius / vec2(textureSize(tex, 0));
	vec2 half_texel = 0.5 / vec2(textureSize(tex, 0));
	vec2 lo = rect.xy + half_texel;
	vec2 hi = rect.xy + rect.zw - half_texel;
	vec3 g = texture(tex, clamp(uv + vec2( r.x,  r.y), lo, hi)).rgb
	       + texture(tex, clamp(uv + vec2(-r.x,  r.y), lo, hi)).rgb
	       + texture(tex, clamp(uv + vec2( r.x, -r.y), lo, hi)).rgb
	       + texture(tex, clamp(uv + vec2(-r.x, -r.y), lo, hi)).rgb;
	g *= 0.25;
	// CRT character adds a small broad phosphor bloom without taking ownership of
	// the existing expert Halation control. At zero, this is bit-identical to the
	// old path. A squared response keeps the subtle default at 0.0196 additional
	// gain while opening enough range at 1.00 to be easy to judge.
	float character_shape = crt_character * crt_character;
	float glow_strength = crt_halation + 0.160 * character_shape;
	return g * g * vec3(1.0, 0.82, 0.68) * glow_strength;
}

vec3 crt_glow(sampler2D tex, vec2 uv) {
	return crt_glow_rect(tex, uv, vec4(0.0, 0.0, 1.0, 1.0));
}


// ── Display stage ───────────────────────────────────────────────────────────

// RGB phosphor mask, locked to the tube and antialiased analytically.
//
// Each channel is 1 + a1*cos(phi) + 0.5*a2*cos(2 phi), which is the first two terms
// of the Fourier series of a 1/3-duty square pulse (the exact coefficient ratio is
// 1.654 : 0.827). Two things fall out of writing it this way:
//
//   * Every harmonic has zero mean, so each channel averages EXACTLY 1.0 at every
//     distance. The mask costs no light — which is why crt_brightness is 1.0 and
//     why the tube's brightness doesn't drift as you walk toward it.
//   * Attenuating each harmonic by its own crt_band() antialiases it. The harmonics
//     die off in order — sharp bars up close, soft stripes mid-range, perfectly
//     flat vec3(1.0) far away — so there is no moire and nothing to crawl.
vec3 crt_mask(vec2 wuv) {
	if (crt_mask_mode == 0 || crt_mask_strength <= 0.0) {
		return vec3(1.0);
	}

	float tx = wuv.x * crt_mask_triads;    // horizontal position, in triads
	float fw = fwidth(tx);                 // triads covered by this pixel
	float a1 = crt_band(fw);
	float a2 = crt_band(2.0 * fw);

	float ty = wuv.y * crt_mask_rows;      // vertical position, in phosphor rows
	float fy = fwidth(ty);

	// Slot / shadow masks stagger alternate phosphor rows by half a triad. Built
	// from odd harmonics so it antialiases the same way and flattens to a constant
	// (a harmless global phase shift) once the rows stop resolving.
	float stagger = 0.0;
	if (crt_mask_mode >= 2) {
		float sq = 0.5 + 0.63662 * (crt_band(fy) * sin(TAU * ty)
			+ crt_band(3.0 * fy) * sin(3.0 * TAU * ty) / 3.0);
		stagger = 0.5 * sq;
	}

	vec3 ph = TAU * (tx - stagger) - vec3(0.0, TAU / 3.0, 2.0 * TAU / 3.0);
	vec3 m = vec3(1.0) + a1 * cos(ph) + (0.5 * a2) * cos(2.0 * ph);

	// Dark band between phosphor rows. Zero mean too, and independent of the
	// horizontal term, so the product still averages exactly 1.0.
	if (crt_mask_mode >= 2) {
		float depth = (crt_mask_mode == 3) ? 0.8 : 0.45;
		m *= 1.0 + depth * crt_band(fy) * cos(TAU * ty);
	}

	return mix(vec3(1.0), max(m, vec3(0.0)), crt_mask_strength);
}

// Electron beam profile down the raster.
//
// The beam is Gaussian and widens with gun current, so sigma comes from max(r,g,b)
// — the widest-driven channel sets the spot size — through a cube root, which keeps
// the spot soft instead of turning it into a diamond the way a linear ramp does.
//
// The profile is INTEGRATED over the pixel's vertical footprint rather than point
// sampled. That buys two things at once: a Gaussian integrates to 1, so brightness
// is conserved for any sigma (the beam can bloom without lifting or crushing the
// picture); and being a true area integral it is automatically antialiased, so as
// the tube recedes the raster dissolves into the correct flat average instead of
// aliasing into moire the way the step() it replaced did.
float crt_beam(vec2 wuv, float lum) {
	if (crt_scanline_strength <= 0.0) {
		return 1.0;
	}
	float sig = mix(crt_beam_min, crt_beam_max, pow(clamp(lum, 0.0, 1.0), 1.0 / 3.0));

	float sl = wuv.y * crt_scanline_count;
	float d = fract(sl) - 0.5;             // distance from this scanline's centre
	float ph = max(fwidth(sl), 1e-4);      // pixel footprint, in scanlines
	float k = 1.0 / (max(sig, 1e-3) * 1.41421356);
	float hp = 0.5 * ph;

	// Three lines is exact while the footprint stays under ~3 scanlines, which is
	// far past the point where the raster is resolvable at all.
	float w = 0.0;
	for (int n = -1; n <= 1; n++) {
		float dn = d - float(n);
		w += 0.5 * (crt_erf((dn + hp) * k) - crt_erf((dn - hp) * k));
	}
	w /= ph;

	// Same Nyquist argument as the mask: the raster is one cycle per scanline, so
	// below ~2 pixels per scanline it cannot be sampled without beating, however
	// exactly the beam was integrated. Hand over to the flat average it is
	// converging on rather than let it alias.
	w = mix(w, 1.0, smoothstep(0.4, 0.8, ph));
	return mix(1.0, w, crt_scanline_strength);
}

// Approximate a sub-texel gun convergence error from local derivatives of the
// finished source colour. This avoids extra texture taps and therefore works on
// gameplay, VHS, static and packed stereo through the same shared stage. The
// displacement is radial, zero through the centre, and capped below one source
// texel at the corners.
vec3 crt_apply_convergence(vec3 col, vec2 wuv) {
	if (crt_character <= 0.0) {
		return col;
	}
	vec2 centred = (wuv - 0.5) * 2.0;
	float edge = smoothstep(0.58, 1.15, length(centred));
	vec2 delta_uv = normalize(centred + vec2(1e-6))
		* crt_source_texel_size * (0.75 * crt_character * edge);

	vec2 uv_dx = dFdx(wuv);
	vec2 uv_dy = dFdy(wuv);
	float det = uv_dx.x * uv_dy.y - uv_dx.y * uv_dy.x;
	if (abs(det) < 1e-8) {
		return col;
	}
	vec2 screen_delta = vec2(
		delta_uv.x * uv_dy.y - delta_uv.y * uv_dy.x,
		uv_dx.x * delta_uv.y - uv_dx.y * delta_uv.x
	) / det;
	vec3 slope = dFdx(col) * screen_delta.x + dFdy(col) * screen_delta.y;
	vec3 shifted = col;
	shifted.r += slope.r;
	shifted.b -= slope.b;
	return max(shifted, vec3(0.0));
}

vec3 crt_apply_full(vec3 col, vec3 glow, vec2 wuv) {
	col = crt_apply_convergence(col, wuv);
	// Gun transfer characteristic. Applied to the signal before the beam paints it,
	// so the beam width below responds to post-gamma brightness like real current.
	col = pow(max(col, vec3(0.0)), vec3(crt_gamma));

	if (crt_grain > 0.0) {
		// floor() matters twice over. Without it the hash varies per RENDER pixel,
		// which puts different noise in each eye — the binocular rivalry this whole
		// file exists to avoid; with it the grain sits in fixed cells on the glass
		// that both eyes agree on. Stepped at ~15 Hz because regenerating it every
		// frame at full amplitude boils in VR.
		vec2 cell = floor(wuv * vec2(640.0, 480.0)) + floor(TIME * 15.0) * 71.7;
		float g = crt_hash(cell) - 0.5;
		// Multiplicative, not additive: this is signal noise, and it rides the
		// signal. Adding a constant in linear light would be amplified enormously
		// in the shadows by the sRGB encode — 0.015 of linear is 13% grey once
		// encoded, which turns black into visible static.
		col *= 1.0 + g * crt_grain;
	}

	col *= crt_beam(wuv, max(max(col.r, col.g), col.b));
	col *= crt_mask(wuv);

	// Halation has already crossed the faceplate and lost the phosphor structure,
	// so it is added after the mask rather than filtered through it.
	col += glow;

	// Bright phosphors softly catch the thick inner edge of the faceplate. This is
	// local to the perimeter and disappears exactly at CRT character zero.
	vec2 rim_uv = abs(wuv - 0.5) * 2.0;
	float rim = smoothstep(0.76, 0.98, max(rim_uv.x, rim_uv.y));
	float hot = pow(max(crt_luminance(col) - 0.48, 0.0), 2.0);
	float character_shape = crt_character * crt_character;
	col += vec3(1.0, 0.72, 0.48) * hot * rim * (0.200 * character_shape);

	vec2 vc = wuv - 0.5;
	col *= 1.0 - dot(vc, vc) * crt_vignette * 2.0;

	return col * crt_brightness;
}

vec3 crt_apply(vec3 col, vec2 wuv) {
	return crt_apply_full(col, vec3(0.0), wuv);
}

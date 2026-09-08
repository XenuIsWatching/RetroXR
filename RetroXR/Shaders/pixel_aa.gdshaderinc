// Pixel-area ("pixel-AA") sampling for emulator pictures.
//
// A core frame is a small fixed grid — 240x160 on a GBA — shown on a surface in a
// 3D scene, so the ratio of screen pixels to source texels is some arbitrary
// non-integer number that changes with distance and angle. Neither hardware filter
// handles that well:
//
//   filter_linear   blends every texel with its neighbours at every ratio. Uniformly
//                   soft, which is how the GBA screen ended up looking blurry.
//   filter_nearest  is crisp only at INTEGER scale. Below 1:1 it DROPS source rows
//                   and columns outright (at 0.94x about 6% of them — glyph columns
//                   vanish, "SCORE" reads "SCOOR_"), and above 1:1 it makes texels
//                   unevenly sized. Either way the pattern crawls as the head moves.
//
// This samples the texel GRID instead: inside a texel the result is that texel's
// exact colour, and across a texel boundary it ramps over a distance of one screen
// pixel. Sharp edges, no dropped source pixels, nothing that crawls — the standard
// pixel-art AA trick, and the reason it is cheap is that the ramp is done by the
// hardware's own bilinear unit.
//
// The sampler MUST therefore be declared `filter_linear` (not nearest): this
// function positions the sample point so that bilinear only ever interpolates
// within one screen pixel of a texel edge.
//
// A screen pixel covering MORE than one texel cannot be represented by a single tap
// however that tap is positioned — that is undersampling, and against periodic source
// content it shows as moire whose fringe spacing and angle swing with view distance
// and head tilt. So above one texel per pixel, pixel_aa() box-averages the pixel's
// own footprint instead; at or below one it is the single snapped tap, unchanged.
// A Wii's 640x528 on a 0.35 m tube is about 2.6 texels per pixel, which is the case
// this covers; three taps per axis hold to roughly 3x before under-covering again.
//
// pixel_aa_uv() is the bare position and is deliberately NOT footprint-aware: a
// caller that samples through it is taking one tap and owns minification itself.

// Sample position for `uv`, snapped to the texel grid with a one-screen-pixel ramp.
vec2 pixel_aa_uv(sampler2D tex, vec2 uv) {
	vec2 tsize = vec2(textureSize(tex, 0));
	vec2 tuv = uv * tsize;                       // uv in texels
	// fwidth = how many texels this screen pixel covers. >1 minifying, <1 magnifying.
	vec2 fw = max(fwidth(tuv), vec2(1e-5));
	// Distance from the texel centre, remapped so the transition is exactly one
	// screen pixel wide and clamped to the texel's own half-width: magnifying hard
	// (fw << 1) clamps to +/-0.5 and lands on texel centres, i.e. crisp like nearest.
	vec2 ramp = clamp((fract(tuv) - 0.5) / fw, -0.5, 0.5);
	return (floor(tuv) + 0.5 + ramp) / tsize;
}

// The same filter, with every hardware tap confined to [lo, hi]. Bounds are
// texel CENTRES, not texture edges: bilinear sampling on an edge would still
// mix the texels on its two sides.
vec4 pixel_aa_bounded(sampler2D tex, vec2 uv, vec2 lo, vec2 hi) {
	// Derivatives are undefined inside non-uniform control flow, so everything the
	// branch below needs is taken here, before it.
	vec2 fw = max(fwidth(uv * vec2(textureSize(tex, 0))), vec2(1e-5));
	vec2 dx = dFdx(uv);
	vec2 dy = dFdy(uv);
	vec2 snapped = clamp(pixel_aa_uv(tex, uv), lo, hi);
	float foot = max(fw.x, fw.y);          // texels this screen pixel covers

	// The dead zone below has to clear 1:1 rather than sit on it. A TV's aspect fit
	// alone samples at 1/0.952 = 1.05 texels per pixel (crt_effect's fit_scale), so a
	// threshold at 1.0 would put a nominally 1:1 screen just inside the box path and
	// shift its sample position by a fraction of a texel — measured at 15/255 on hard
	// edges, which is exactly the softening this must not introduce.
	if (foot <= 1.25) {
		return texture(tex, snapped);
	}

	// Box-average the pixel's own footprint, stepping along dFdx/dFdy so the box
	// follows the surface however it is rotated or foreshortened — which is what
	// keeps the result stable as the head tilts.
	//
	// `t` ramps the box in over 1.25 -> 2.0 so there is no visible switch, and both
	// terms below vanish with it: at t = 0 the taps collapse onto `snapped` and this
	// is bit-identical to the single tap.
	float t = clamp((foot - 1.25) / 0.75, 0.0, 1.0);
	// Each bilinear tap already covers about one texel, so three taps per axis
	// spanning (foot - 1) texels cover foot in total: k is that half-span in pixels.
	float k = t * (foot - 1.0) / (2.0 * foot);
	// The snapped position is a texel centre, which is the right place for one tap
	// and the wrong centre for a box; hand the box the true position instead.
	vec2 centre = mix(snapped, clamp(uv, lo, hi), t);

	vec4 acc = vec4(0.0);
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 tap = centre + (float(i) * k) * dx + (float(j) * k) * dy;
			acc += texture(tex, clamp(tap, lo, hi));
		}
	}
	return acc * (1.0 / 9.0);
}

vec4 pixel_aa(sampler2D tex, vec2 uv) {
	vec2 half_texel = 0.5 / vec2(textureSize(tex, 0));
	return pixel_aa_bounded(tex, uv, half_texel, vec2(1.0) - half_texel);
}

// Windowed composite sources (DS top/bottom, 3DS eyes/screens) share one
// texture. Confining every footprint tap to this window prevents a neighbouring
// screen's outer row or column from entering the filter.
vec4 pixel_aa_rect(sampler2D tex, vec2 uv, vec4 rect) {
	vec2 half_texel = 0.5 / vec2(textureSize(tex, 0));
	vec2 lo = rect.xy + half_texel;
	vec2 hi = rect.xy + rect.zw - half_texel;
	return pixel_aa_bounded(tex, uv, lo, hi);
}

// The mobile tier's minification: the same single snapped tap at or below 1.25
// texels per pixel, and a 2x2 box above it instead of the 3x3 (four taps for
// nine), covering up to FOUR texels per axis where the 3x3 covers three.
//
// The trick is where the taps land. A bilinear tap on a texel centre returns
// that texel; a tap on a texel CORNER returns the equal mean of the two texels
// either side. So two taps per axis at texel centres one apart box two texels,
// and two taps at corners two apart box four texels exactly, with nothing
// double-counted and no gap between. In between, the weights ramp smoothly from
// one to the other. The box is therefore snapped to the texel grid instead of
// centred on the pixel; that moves it by up to half a texel, which is under a
// quarter of a pixel at the footprints where the box is in use.
//
// The extent is per axis, from the axis-aligned footprint (fwidth) rather than
// stepped along dFdx/dFdy, so an oblique view over-covers a little on the
// foreshortened axis instead of following the rotated footprint.
vec4 pixel_aa_fast_bounded(sampler2D tex, vec2 uv, vec2 lo, vec2 hi) {
	vec2 tsize = vec2(textureSize(tex, 0));
	vec2 tuv = uv * tsize;
	vec2 fw = max(fwidth(tuv), vec2(1e-5));
	vec2 snapped = clamp(pixel_aa_uv(tex, uv), lo, hi);
	float foot = max(fw.x, fw.y);
	if (foot <= 1.25) {
		return texture(tex, snapped);
	}
	// Same 1.25 -> 2.0 ramp as pixel_aa_bounded, and bit-identical to the single
	// tap at t = 0: the four taps collapse onto `snapped`.
	float t = clamp((foot - 1.25) / 0.75, 0.0, 1.0);
	// Half the tap spacing, in texels: 0.5 boxes two texels, 1.0 boxes four.
	vec2 half_gap = clamp(fw * 0.25, vec2(0.5), vec2(1.0)) * t;
	vec2 centre = mix(snapped * tsize, round(tuv), t);
	vec2 ox = vec2(half_gap.x, 0.0);
	vec2 oy = vec2(0.0, half_gap.y);
	vec4 acc = texture(tex, clamp((centre - ox - oy) / tsize, lo, hi))
	         + texture(tex, clamp((centre + ox - oy) / tsize, lo, hi))
	         + texture(tex, clamp((centre - ox + oy) / tsize, lo, hi))
	         + texture(tex, clamp((centre + ox + oy) / tsize, lo, hi));
	return acc * 0.25;
}

vec4 pixel_aa_fast(sampler2D tex, vec2 uv) {
	vec2 half_texel = 0.5 / vec2(textureSize(tex, 0));
	return pixel_aa_fast_bounded(tex, uv, half_texel, vec2(1.0) - half_texel);
}

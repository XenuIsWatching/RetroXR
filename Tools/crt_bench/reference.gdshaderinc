// Frozen pre-optimization functions for the CRT A/B probe.

float crt_band(float f) {
	float a = PI * f;
	float box = (abs(a) < 1e-4) ? 1.0 : sin(a) / a;
	return max(box, 0.0) * (1.0 - smoothstep(0.25, 0.45, f));
}

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

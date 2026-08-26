// One 12" record: both faces, one surface, one draw call.
//
// Reads what Tools/gen_disc.gd's _bake_lp writes, using the same convention as
// Shaders/disc.gdshader:
//   UV     planar over the disc's bounding square, so label art maps 1:1
//   UV2.x  face class: 1.0 label / 0.0 grooves / 0.5 rim, bore and the land ramps
// and, like that shader, derives the radius from length(VERTEX.xz) rather than
// baking it — exact, one vertex instruction, immune to attribute compression and
// to node scale.
//
// It is a SEPARATE shader from disc.gdshader on purpose, and the reason is not
// tidiness. That one models an optical disc: a clear polycarbonate substrate with
// aluminium sputtered into the middle of it, hence a transparent queue, a
// depth_prepass_alpha, a metal mask and a four-order analytic diffraction grating
// summed per light. A record has none of those things — it is opaque dyed vinyl,
// all the way through, with a paper label glued on. Reusing the optical shader
// would have meant switching off most of it and still paying for the grating loop
// on a Quest, to draw something black.
//
// What a record HAS that the CD shader has no notion of is the groove: ~100 um
// pitch, far too coarse to diffract visibly (that is why a record does not show a
// CD's rainbow), but easily coarse enough to see as concentric relief and, more
// importantly, to make the highlight smear ALONG the groove. That anisotropy —
// a light source drawn out into an arc rather than a round dot — is the single
// cue that reads as vinyl, and it is most of what this shader does.
shader_type spatial;
render_mode cull_back;

// Dyed vinyl. Never truly black: a real record lifts to a dark grey-brown where
// the light catches it, and pure 0.0 reads as a hole in the world.
uniform vec3 vinyl_color : source_color = vec3(0.022, 0.020, 0.024);
// Coloured pressings are a real thing and cost nothing to allow.
uniform vec3 sheen_tint : source_color = vec3(1.0, 0.97, 0.92);
// The ungrooved lands — label area and outer lip — are smoother than the grooves.
uniform float groove_roughness : hint_range(0.0, 1.0) = 0.34;
uniform float land_roughness : hint_range(0.0, 1.0) = 0.16;
// Groove pitch in MICROMETRES. An LP is ~100 (about 60x a CD's 1.6). Used for the
// visible relief banding, not for diffraction — at this pitch there is none.
uniform float groove_pitch = 100.0;
// How strongly the highlight smears along the groove. This is the vinyl cue.
uniform float anisotropy : hint_range(0.0, 1.0) = 0.85;
uniform float sheen_gain : hint_range(0.0, 4.0) = 1.1;
// Per-record jitter, 0..1, so a stack of them is not visibly cloned.
uniform float record_seed : hint_range(0.0, 1.0) = 0.5;

uniform sampler2D label_tex : source_color, hint_default_transparent,
	filter_linear_mipmap_anisotropic, repeat_disable;

// Zone radii in metres, matching the bake.
uniform float r_label_end = 0.0508;
uniform float r_lead_out = 0.1455;

varying vec3 v_radial;    // view-space radial — across the grooves
varying vec3 v_tangent;   // view-space azimuthal — ALONG the grooves
varying float v_radius;
// Written in fragment(), read in light(). SPECULAR is not readable inside light()
// — disc.gdshader carries v_irid/v_blur across the same way.
varying float v_spec;


void vertex() {
	v_radius = length(VERTEX.xz);
	// The bore is 7.24 mm across, so this is never degenerate.
	v_radial = normalize((MODELVIEW_MATRIX * vec4(VERTEX.x, 0.0, VERTEX.z, 0.0)).xyz);
	// Azimuthal direction: perpendicular to the radius in the disc plane.
	v_tangent = normalize((MODELVIEW_MATRIX * vec4(-VERTEX.z, 0.0, VERTEX.x, 0.0)).xyz);
}


void fragment() {
	float face = UV2.x;
	float r = v_radius;

	// Concentric groove relief. fwidth-limited so the bands fade to a flat sheen
	// once a groove period falls under a pixel, instead of aliasing into moire —
	// which at 100 um and arm's length is most of the disc, and is exactly what a
	// record looks like.
	float period = groove_pitch * 1e-6;
	float phase = r / period;
	float fade = 1.0 - smoothstep(0.25, 0.9, fwidth(phase));
	float groove = sin(phase * 6.2831853) * 0.5 + 0.5;
	// Only the grooved band actually has grooves.
	float grooved = smoothstep(r_label_end, r_label_end + 0.002, r)
		* (1.0 - smoothstep(r_lead_out, r_lead_out + 0.002, r));

	vec3 base = vinyl_color * (1.0 + (record_seed - 0.5) * 0.10);

	if (face > 0.75) {
		// --- paper label ---
		vec4 art = texture(label_tex, UV);
		art.a *= 1.0 - smoothstep(r_label_end - 0.0015, r_label_end, r);
		ALBEDO = mix(base, art.rgb, art.a);
		METALLIC = 0.0;
		// Paper is matte; the vinyl land around it is not.
		ROUGHNESS = mix(land_roughness, 0.85, art.a);
		SPECULAR = mix(0.5, 0.15, art.a);
		v_spec = SPECULAR;
	} else if (face > 0.25) {
		// --- rim, bore wall and the land ramps ---
		// A cut edge of dyed vinyl: same material, slightly glossier than the
		// grooves because nothing is cut into it.
		ALBEDO = base;
		METALLIC = 0.0;
		ROUGHNESS = land_roughness;
		SPECULAR = 0.5;
		v_spec = SPECULAR;
	} else {
		// --- grooved face, and the ungrooved lands within it ---
		// The relief darkens the groove walls a little where it is still resolved.
		ALBEDO = base * (1.0 - grooved * fade * 0.35 * (1.0 - groove));
		METALLIC = 0.0;
		ROUGHNESS = mix(land_roughness, groove_roughness, grooved);
		SPECULAR = 0.5;
		v_spec = SPECULAR;
	}
}


// The anisotropic highlight. Godot's built-in BRDF has no notion of a grooved
// surface, so the specular lobe is written here: the half-vector's component
// ACROSS the grooves is stretched, which draws a point light out into an arc
// following the groove instead of leaving a round dot. Defining light() compiles
// the built-in BRDF out entirely, so the diffuse term is written too.
void light() {
	vec3 N = normalize(NORMAL);
	vec3 L = normalize(LIGHT);
	vec3 V = normalize(VIEW);
	float ndl = max(dot(N, L), 0.0);
	vec3 radiance = LIGHT_COLOR * ATTENUATION;

	DIFFUSE_LIGHT += ALBEDO * radiance * ndl;

	vec3 H = normalize(L + V);
	float a = max(ROUGHNESS * ROUGHNESS, 0.004);
	// Split the half-vector into the two surface directions. Compressing the
	// along-groove term and stretching the across-groove one is what smears the
	// highlight; at anisotropy 0 this collapses back to plain Blinn-Phong.
	float ht = dot(H, normalize(v_tangent));
	float hr = dot(H, normalize(v_radial));
	float ax = a * (1.0 + anisotropy * 6.0);
	float ay = a / (1.0 + anisotropy * 0.7);
	float ndh = max(dot(N, H), 0.0);
	// Elliptical falloff about the mirror direction, in the groove frame.
	float d = (ht * ht) / (ax * ax) + (hr * hr) / (ay * ay);
	float spec = exp(-d) * ndh;

	SPECULAR_LIGHT += radiance * ndl * spec * sheen_tint * sheen_gain * v_spec;
}

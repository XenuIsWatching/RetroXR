shader_type spatial;

// The headset variant of `pbr_surface`. Same surface, same tiling, same contact
// darkening — but it lights itself instead of handing the fragment to Godot.
//
// WHY. Measured on a Quest 3 with RenderDoc, on a bedroom frame: sixteen draws
// wearing `pbr_surface` were 61% of the whole frame's GPU clocks, and the worst
// single one — a two-triangle wall quad covering most of the eye — was 31% on
// its own. Substituting a constant-colour fragment shader for that draw took it
// from 3,498,210 clocks to 266,736; substituting one that did nothing but the
// three material texture fetches took it to 360,338. So the material's own work
// is under 3% of the draw and the other ~90% is Godot's per-fragment lighting:
// 22 texture fetch instructions of which only three are ours, plus 133 dot
// products and 69 normalizes, over a near-full-eye quad, times sixteen draws.
//
// Cutting texture RESOLUTION does not touch it — all four maps forced to 256
// with full mipchains moved the frame 2.8% and that draw 1.4%. Mips already
// handle resolution. It is the fetch COUNT and the light loop.
//
// WHAT IT GIVES UP, and what it deliberately does not. Unshaded means no shadow
// maps, no reflection probes, no light clustering, no SSAO — none of which the
// mobile backend was giving this shell anyway. What it WOULD have given up is
// the room's interactivity: the wall switch, the two lamp pull-cords, the TV's
// screen-cast light and the time-of-day lever all reach the walls through that
// light loop. So the loop is not removed, it is replaced with a four-light
// analytic one costing no texture fetches, fed from the room's real Light3D
// nodes by `shell_lighting.gd`. Flipping the switch still lights the walls.
//
// The four slots are a budget, not a limit of the idea: `shell_lighting.gd`
// picks the four that matter most to each material and drops the rest, which is
// what the mobile backend's own cluster would have done with more machinery.

render_mode blend_mix, depth_draw_opaque, cull_back, unshaded;

#include "res://Shaders/pbr_surface_common.gdshaderinc"

const int MAX_SHELL_LIGHTS = 4;

// How many of the slots below carry a light. Slots past this are not read.
uniform int light_count : hint_range(0, 4) = 0;

// xyz: world position for a point or spot, or the direction TO the light for a
// directional. w: range in metres, or a negative w to mean "directional".
uniform vec4 light_vec[MAX_SHELL_LIGHTS];
// rgb: light colour. a: energy.
uniform vec4 light_rgbe[MAX_SHELL_LIGHTS];
// xyz: the direction a spot points. w: cosine of its half-angle, or any value
// above 1.0 to mean "omni", which no cone can satisfy.
uniform vec4 light_axis[MAX_SHELL_LIGHTS];
// x: the light's distance attenuation exponent. y: a spot's angle attenuation.
// Both are the Light3D's own properties rather than a constant, because the
// room authors them — the bedroom's floor bounce runs at 0.35, which is a very
// different shape from the default 1.0 and is most of what makes it read as
// bounce rather than as a second lamp.
uniform vec4 light_falloff[MAX_SHELL_LIGHTS];

// Hemispheric ambient. Godot's own is a single constant colour, which leaves a
// normal map completely flat wherever no light reaches; splitting it by the
// world normal's Y costs one mix and keeps the plaster's relief readable in the
// parts of the room the lamps do not get to.
//
// LINEAR, like every colour below. Not `source_color`: these are fed from script
// beside `light_rgbe`, which cannot be a `source_color` uniform because it
// carries an energy in its alpha — so one converter in `shell_lighting.gd`
// handles them all rather than half being converted by the engine and half not.
uniform vec3 ambient_sky = vec3(0.35, 0.33, 0.30);
uniform vec3 ambient_ground = vec3(0.16, 0.14, 0.13);
uniform float ambient_energy : hint_range(0.0, 4.0) = 1.0;

// Lambert goes hard to black at the terminator, which on a large flat wall reads
// as a seam. Wrapping the diffuse pushes the terminator round the back and is
// what a rough painted surface with a lot of local bounce actually looks like.
// Kept small: at 0.35 it lifted every unlit wall and the room read flat.
uniform float diffuse_wrap : hint_range(0.0, 1.0) = 0.12;

// A single Blinn lobe, so the roughness map is not fetched for nothing. Small by
// default: the shell is plaster and carpet, not polish.
uniform float specular_strength : hint_range(0.0, 1.0) = 0.15;

// --- Baked irradiance volume -------------------------------------------------
// When a room ships a bake, the light loop above is not run at all: the lighting
// comes from a volume indexed by world position, which costs two fetches and no
// arithmetic. Measured on a Quest 3 at eye buffer 1.00x, bedroom: Godot's
// lighting 20.04 ms, the analytic loop 14.72 ms, a bake-shaped profile 12.34 ms
// — 72 fps, the refresh cap. The loop is kept for rooms with no bake, and for
// the exterior surfaces, which sit outside the volume.
//
// `gi_dir` is what stops a volume looking like flat ambient. Irradiance at a
// point knows nothing about which way a surface faces, so the ceiling under the
// globe would read as brightly as the floor. The dominant direction and how
// directional the point is (a = 1 one lamp, a = 0 fully diffuse) put the normal
// back in.
uniform bool use_gi = false;
uniform sampler3D gi_irr : filter_linear, repeat_disable;
uniform sampler3D gi_dir : filter_linear, repeat_disable;
uniform vec3 gi_min = vec3(0.0);
uniform vec3 gi_size = vec3(1.0);


void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_local_pos = VERTEX;
	v_local_normal = normalize(NORMAL);
}


// The world-space tangent frame for the UV the axis-pick chose.
//
// Built from the pick rather than from Godot's TANGENT/BINORMAL, which are view
// space and describe the mesh's own UVs — the ones this shader threw away. The
// pick already says which two world axes the texture lies along, so the frame is
// exact and costs no cross products.
mat3 shell_tbn() {
	vec3 n = abs(v_world_normal);
	vec3 t;
	vec3 b;
	if (n.y > max(n.x, n.z)) {
		t = vec3(1.0, 0.0, 0.0);
		b = vec3(0.0, 0.0, 1.0);
	} else if (n.x > n.z) {
		t = vec3(0.0, 0.0, 1.0);
		b = vec3(0.0, 1.0, 0.0);
	} else {
		t = vec3(1.0, 0.0, 0.0);
		b = vec3(0.0, 1.0, 0.0);
	}
	if (swap_uv) {
		vec3 s = t;
		t = b;
		b = s;
	}
	return mat3(t, b, v_world_normal);
}


// Godot's own omni/spot distance falloff, copied shape for shape.
//
// This is NOT a linear ramp to the range, which is the intuitive guess and is
// what the first version did — it made every lamp far too weak and left the
// room lit by nothing but its blue night ambient. `light_energy` is an
// INTENSITY and `omni_range` is a cull boundary, so the curve is an inverse
// power of distance windowed by the range, and a lamp authored against the
// desktop renderer only reads the same here if the window matches too.
float omni_attenuation(float dist, float inv_range, float decay) {
	float nd = dist * inv_range;
	nd *= nd;
	nd *= nd;
	nd = max(1.0 - nd, 0.0);
	nd *= nd;
	return nd * pow(max(dist, 0.0001), -decay);
}


void fragment() {
	vec2 uv = shell_uv();
	float contact = shell_contact();
	vec3 albedo = shell_albedo(uv) * contact;
	float rough = shell_roughness(uv);

	// Tangent-space normal, by hand: `unshaded` never reads NORMAL_MAP.
	//
	// Z is RECONSTRUCTED, not read. A `hint_normal` map compresses to a
	// two-channel EAC_RG11 on this platform — there is no blue channel to read,
	// and taking one gives -1, which points every surface normal INTO the wall.
	// That zeroes N.L for every light on every surface, and the room renders on
	// its ambient alone: warm plaster lit only by a blue night sky. It looks
	// like a colour bug and is a geometry one. Godot does this reconstruction
	// itself for NORMAL_MAP, which is why the shaded variant never had to.
	vec2 nxy = (texture(normal_tex, uv).rg * 2.0 - 1.0) * normal_strength;
	vec3 tn = vec3(nxy, sqrt(max(1.0 - dot(nxy, nxy), 0.0)));
	vec3 n = normalize(shell_tbn() * tn);

	vec3 view = normalize((INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz - v_world_pos);

	// Ambient LIGHTS the surface, it is not painted over it: the term is the
	// wall's own colour under that light, so a blue night ambient tints beige
	// plaster rather than replacing it with blue. Leaving the albedo out is what
	// turned the whole shell the colour of the sky on the first render.
	//
	// Contact darkens it as well as the albedo, which is where a flat ambient
	// shows itself — the same reason the desktop variant feeds AO.
	float sky_mix = n.y * 0.5 + 0.5;
	vec3 lit = albedo * mix(ambient_ground, ambient_sky, sky_mix) * ambient_energy * contact;

	// The branch is on a uniform, so it is coherent across every fragment in the
	// draw and only one side is ever taken. `return` cannot be used to skip the
	// loop instead: Godot rejects it outright in fragment().
	if (use_gi) {
		vec3 uvw = clamp((v_world_pos - gi_min) / gi_size, vec3(0.0), vec3(1.0));
		vec4 dr = texture(gi_dir, uvw);
		vec3 gl = normalize(dr.rgb * 2.0 - 1.0);
		float gndl = clamp((dot(n, gl) + diffuse_wrap) / (1.0 + diffuse_wrap), 0.0, 1.0);
		// The volume already carries the room's ambient, so this REPLACES `lit`
		// rather than adding to it - adding would count the ambient twice.
		lit = albedo * texture(gi_irr, uvw).rgb * mix(1.0, gndl, dr.a) * contact;
	} else {

	float shine = exp2(mix(4.0, 10.0, 1.0 - rough));
	for (int i = 0; i < light_count; i++) {
		vec4 lv = light_vec[i];
		vec3 l;
		float atten;
		if (lv.w < 0.0) {
			l = normalize(lv.xyz);
			atten = 1.0;
		} else {
			vec3 d = lv.xyz - v_world_pos;
			float dist = length(d);
			l = d / max(dist, 0.0001);
			// Godot's own inverse-square-with-cutoff, in the shape the engine
			// uses for an omni: fade to nothing exactly at the range so a light
			// leaving the budget does not pop.
			atten = omni_attenuation(dist, 1.0 / max(lv.w, 0.0001),
				light_falloff[i].x);
			float cone = light_axis[i].w;
			if (cone <= 1.0) {
				// Godot's spot rim, not a smoothstep: the cone's soft edge is
				// authored by `spot_angle_attenuation` and a different curve
				// makes the window's sun patch a different shape.
				float scos = max(dot(-l, normalize(light_axis[i].xyz)), cone);
				float rim = (1.0 - scos) / max(1.0 - cone, 0.0001);
				atten *= 1.0 - pow(rim, max(light_falloff[i].y, 0.0001));
			}
		}
		if (atten <= 0.0) {
			continue;
		}
		vec4 rgbe = light_rgbe[i];
		vec3 energy = rgbe.rgb * rgbe.a * atten;

		float ndl = clamp((dot(n, l) + diffuse_wrap) / (1.0 + diffuse_wrap), 0.0, 1.0);
		lit += albedo * energy * ndl * contact;

		float spec = pow(max(dot(n, normalize(l + view)), 0.0), shine);
		lit += energy * spec * specular_strength * ndl;
	}

	}

	ALBEDO = lit;
}

shader_type spatial;

// The headset lighting path for a PROP — a console, a television, a table.
//
// The shell got this treatment first and the props were left on Godot's
// lighting, which turned out to be where the frame went next. Measured on a
// Quest 3 at eye buffer 1.75x with the shell already baked: the shell is 22% of
// the frame, and the props are 24% — five high-polygon draws carrying the
// machines and the sets. Substituting a constant-colour fragment shader for
// that pipeline took 21.6% off the whole frame, which is more than the shell was
// still worth.
//
// Unlike `pbr_surface_unshaded` this samples the prop's OWN maps through its own
// UVs, because a console's albedo is authored art rather than a tiling surface.
// Everything else is the same idea: no light loop, no shadow maps, no probes —
// the lighting comes from the room's baked irradiance volume, indexed by world
// position, at two texture fetches and no arithmetic.
//
// A prop that is picked up and carried keeps working, and correctly: it samples
// the volume wherever it now is, so a console lifted toward the ceiling globe
// brightens. That is the whole reason the volume is indexed by position rather
// than baked per-object.

render_mode blend_mix, depth_draw_opaque, cull_back, unshaded;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform sampler2D emission_tex : source_color, filter_linear_mipmap;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec3 emission_color : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
uniform bool has_albedo_tex = false;
uniform bool has_normal_tex = false;
uniform bool has_emission_tex = false;
uniform float normal_scale : hint_range(0.0, 2.0) = 1.0;

// The room's baked irradiance volume, shared with the shell.
uniform sampler3D gi_irr : filter_linear, repeat_disable;
uniform sampler3D gi_dir : filter_linear, repeat_disable;
uniform vec3 gi_min = vec3(0.0);
uniform vec3 gi_size = vec3(1.0);

// Lambert to black at the terminator reads as a seam on a large flat panel like
// a television's side. Same small wrap the shell uses.
uniform float diffuse_wrap : hint_range(0.0, 1.0) = 0.12;

// A prop that leaves the volume — carried out of the room, or a machine spawned
// beyond it — would otherwise clamp to the volume's edge texel and take that
// wall's lighting with it. This is the level it falls back to instead.
uniform vec3 outside_light : source_color = vec3(0.35, 0.33, 0.30);

varying vec3 v_world_pos;
varying vec3 v_world_normal;
varying vec3 v_world_tangent;
varying vec3 v_world_binormal;


void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_world_tangent = normalize((MODEL_MATRIX * vec4(TANGENT, 0.0)).xyz);
	v_world_binormal = normalize((MODEL_MATRIX * vec4(BINORMAL, 0.0)).xyz);
}


void fragment() {
	vec3 albedo = albedo_color.rgb;
	if (has_albedo_tex) {
		albedo *= texture(albedo_tex, UV).rgb;
	}

	vec3 n = normalize(v_world_normal);
	if (has_normal_tex) {
		// Z reconstructed, not read: a hint_normal map compresses to two-channel
		// EAC_RG11 here, and taking a blue channel that does not exist points
		// every normal into the surface. The shell shader learned this the
		// expensive way - it zeroed N.L on every light in the room.
		vec2 nxy = (texture(normal_tex, UV).rg * 2.0 - 1.0) * normal_scale;
		vec3 tn = vec3(nxy, sqrt(max(1.0 - dot(nxy, nxy), 0.0)));
		n = normalize(mat3(v_world_tangent, v_world_binormal, v_world_normal) * tn);
	}

	// Where the fragment sits in the room's volume, and whether it is in it at
	// all. `inside` goes to 0 across the last texel rather than at the boundary,
	// so a prop carried out of the room fades to the fallback instead of popping.
	vec3 uvw = (v_world_pos - gi_min) / gi_size;
	vec3 slack = clamp(min(uvw, vec3(1.0) - uvw) * 8.0, vec3(0.0), vec3(1.0));
	float inside = min(min(slack.x, slack.y), slack.z);

	vec3 c = clamp(uvw, vec3(0.0), vec3(1.0));
	vec4 dr = texture(gi_dir, c);
	vec3 l = normalize(dr.rgb * 2.0 - 1.0);
	float ndl = clamp((dot(n, l) + diffuse_wrap) / (1.0 + diffuse_wrap), 0.0, 1.0);
	vec3 lit = texture(gi_irr, c).rgb * mix(1.0, ndl, dr.a);

	vec3 light = mix(outside_light, lit, inside);
	vec3 emission = emission_color * emission_energy;
	if (has_emission_tex) {
		emission *= texture(emission_tex, UV).rgb;
	}

	ALBEDO = albedo * light + emission;
	ALPHA = albedo_color.a;
}

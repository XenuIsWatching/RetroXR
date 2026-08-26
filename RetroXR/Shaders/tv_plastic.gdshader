shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Fine, object-locked moulded plastic. Three-dimensional noise avoids UV seams
// on the primitive cabinet and tapered monitor hood, and stays attached when a
// television is carried or resized.
uniform vec4 plastic_color : source_color = vec4(0.10, 0.10, 0.10, 1.0);
uniform float plastic_roughness : hint_range(0.2, 1.0) = 0.62;
uniform float grain_scale : hint_range(100.0, 1600.0) = 720.0;
uniform float grain_normal : hint_range(0.0, 0.25) = 0.055;
uniform float grain_roughness : hint_range(0.0, 0.25) = 0.07;

varying vec3 object_position;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float value_noise(vec3 p) {
	vec3 cell = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash31(cell);
	float n100 = hash31(cell + vec3(1.0, 0.0, 0.0));
	float n010 = hash31(cell + vec3(0.0, 1.0, 0.0));
	float n110 = hash31(cell + vec3(1.0, 1.0, 0.0));
	float n001 = hash31(cell + vec3(0.0, 0.0, 1.0));
	float n101 = hash31(cell + vec3(1.0, 0.0, 1.0));
	float n011 = hash31(cell + vec3(0.0, 1.0, 1.0));
	float n111 = hash31(cell + vec3(1.0));
	float z0 = mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y);
	float z1 = mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y);
	return mix(z0, z1, f.z);
}

void vertex() {
	object_position = VERTEX;
}

void fragment() {
	vec3 p = object_position * grain_scale;
	float grain = value_noise(p);
	// A cheap local slope turns the same grain into isotropic micro-normal relief.
	// The pattern coordinates remain object-locked; at this tiny strength the
	// view-space perturbation reads as mould texture without directional brushing.
	float step_size = 0.16;
	vec3 slope = vec3(
		value_noise(p + vec3(step_size, 0.0, 0.0)) - grain,
		value_noise(p + vec3(0.0, step_size, 0.0)) - grain,
		value_noise(p + vec3(0.0, 0.0, step_size)) - grain
	) / step_size;
	NORMAL = normalize(NORMAL - vec3(slope.xy, 0.0) * grain_normal);

	float variation = grain - 0.5;
	ALBEDO = plastic_color.rgb * (1.0 + variation * 0.035);
	ROUGHNESS = clamp(plastic_roughness + variation * grain_roughness, 0.12, 1.0);
	SPECULAR = 0.34;
	CLEARCOAT = 0.055;
	CLEARCOAT_ROUGHNESS = 0.38;
}

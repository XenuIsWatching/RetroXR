// Low-frequency copy of a live display for three regional SpotLight3D colours.
// The deliberately tiny target and wide kernel retain broad colour regions but
// cannot paint a recognisable copy of the game onto the room.
shader_type canvas_item;

uniform sampler2D source_tex : source_color, filter_linear, repeat_disable;
uniform vec4 source_rect = vec4(0.0, 0.0, 1.0, 1.0);

void fragment() {
	// Five separable Gaussian weights, applied as a 5x5 kernel. A quarter of the
	// selected source window is covered by the kernel at every output texel.
	const float weights[5] = float[5](1.0, 4.0, 6.0, 4.0, 1.0);
	vec2 radius = source_rect.zw * 0.0625;
	vec2 centre = source_rect.xy + UV * source_rect.zw;
	vec2 half_texel = 0.5 / vec2(textureSize(source_tex, 0));
	// Do not let bilinear taps cross from one packed DS/3DS panel into the other.
	vec2 lo = source_rect.xy + half_texel;
	vec2 hi = source_rect.xy + source_rect.zw - half_texel;
	vec3 colour = vec3(0.0);
	float total = 0.0;
	for (int y = 0; y < 5; y++) {
		for (int x = 0; x < 5; x++) {
			float weight = weights[x] * weights[y];
			vec2 offset = vec2(float(x - 2), float(y - 2)) * radius;
			colour += texture(source_tex, clamp(centre + offset, lo, hi)).rgb * weight;
			total += weight;
		}
	}
	COLOR = vec4(colour / total, 1.0);
}

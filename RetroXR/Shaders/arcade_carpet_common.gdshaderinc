// The arcade carpet's pattern, shared by the desktop and headset variants of
// `arcade_carpet`.
//
// Same split, and the same reason, as `pbr_surface_common`: the two shaders
// differ ONLY in how they turn this colour into a lit fragment. A pattern living
// in one and not the other is drift, and drift here shows up as the floor
// changing under a player who put the headset on.

// Marks a material as room SHELL rather than a prop. `shell_lighting.gd` only
// swaps a shell material to the unshaded variant, and `bake_shell_gi.gd` fits
// the volume to the shell's own bounds - both ask this uniform. Nothing but the
// arcade floor wears this shader today, so it looks redundant; it is the same
// question the other shell shaders are asked, and answering it differently here
// would mean two rules for one decision.
uniform bool shell = false;

uniform vec3 base_color : source_color = vec3(0.06, 0.04, 0.08);
uniform vec3 color_cyan : source_color = vec3(0.0, 0.9, 0.9);
uniform vec3 color_pink : source_color = vec3(0.95, 0.1, 0.5);
uniform vec3 color_green : source_color = vec3(0.2, 1.0, 0.3);
uniform float tile_scale : hint_range(0.5, 10.0) = 4.0;


float diamond(vec2 uv) {
	return step(abs(uv.x) + abs(uv.y), 0.35);
}


float zigzag(vec2 uv) {
	float y_off = abs(fract(uv.x * 2.0) - 0.5) * 0.6;
	return step(abs(uv.y - y_off), 0.04);
}


float circle_ring(vec2 uv, float radius) {
	float d = length(uv);
	return step(abs(d - radius), 0.03);
}


// 80s arcade carpet - dark purple-black base with neon geometric shapes.
vec3 carpet_albedo(vec2 base_uv) {
	vec2 uv = base_uv * tile_scale;
	vec2 cell = fract(uv) - 0.5;
	vec2 cell_id = floor(uv);

	vec3 col = base_color;

	// Layer 1: diamonds on even cells
	float even = step(0.5, mod(cell_id.x + cell_id.y, 2.0));
	col = mix(col, color_cyan * 0.6, diamond(cell * 1.2) * even * 0.7);

	// Layer 2: zigzag lines
	col = mix(col, color_pink * 0.5, zigzag(uv * 0.5) * 0.6);

	// Layer 3: circle rings on odd cells
	float odd = 1.0 - even;
	col = mix(col, color_green * 0.5, circle_ring(cell, 0.25) * odd * 0.6);

	// Small accent dots at cell centers
	float dot_mask = step(length(cell), 0.05);
	col = mix(col, color_pink * 0.8, dot_mask * even * 0.5);

	return col;
}

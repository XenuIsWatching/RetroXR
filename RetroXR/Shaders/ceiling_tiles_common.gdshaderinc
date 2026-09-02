// The drop-ceiling pattern, shared by the desktop and headset variants of
// `ceiling_tiles`. Same split, and the same reason, as `arcade_carpet_common`.

// Marks a material as room SHELL rather than a prop - see
// `arcade_carpet_common` for why this is asked of a shader only the shell wears.
uniform bool shell = false;

uniform vec3 tile_color : source_color = vec3(0.88, 0.86, 0.82);
uniform vec3 grid_color : source_color = vec3(0.25, 0.25, 0.25);
uniform float tile_scale : hint_range(0.5, 10.0) = 5.0;
uniform float grid_width : hint_range(0.005, 0.05) = 0.02;


// Off-white tiles with dark aluminium grid lines. Returns the tile/grid mix in
// `x` so a caller can shade the two differently: the grid is the metal runner
// and the tile is mineral fibre, which the desktop variant spends a roughness
// and a metallic on.
float ceiling_grid(vec2 base_uv) {
	vec2 cell = fract(base_uv * tile_scale);
	float grid = step(cell.x, grid_width) + step(1.0 - grid_width, cell.x);
	grid += step(cell.y, grid_width) + step(1.0 - grid_width, cell.y);
	return clamp(grid, 0.0, 1.0);
}


vec3 ceiling_albedo(float grid) {
	return mix(tile_color, grid_color, grid);
}

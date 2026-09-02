shader_type spatial;

// The arcade's drop ceiling. DESKTOP variant: it hands the surface to Godot's
// lighting and gets the full PBR treatment.
//
// On a headset `shell_lighting.gd` swaps this material to
// `ceiling_tiles_unshaded.gdshader`. The ceiling is the second largest surface
// in the room after the floor, and the four fixtures sit right against it.

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://Shaders/ceiling_tiles_common.gdshaderinc"

void fragment() {
	float grid = ceiling_grid(UV);
	ALBEDO = ceiling_albedo(grid);
	ROUGHNESS = mix(0.9, 0.5, grid);
	METALLIC = mix(0.0, 0.4, grid);
}

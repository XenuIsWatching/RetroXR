shader_type spatial;

// The arcade floor. DESKTOP variant: it hands the surface to Godot's lighting
// and gets the full PBR treatment.
//
// On a headset `shell_lighting.gd` swaps this material to
// `arcade_carpet_unshaded.gdshader`, which lights the same pattern from the
// room's baked irradiance volume instead. The floor is the single largest
// fragment coverage in the room, so it is the draw that swap exists for.

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://Shaders/arcade_carpet_common.gdshaderinc"

void fragment() {
	ALBEDO = carpet_albedo(UV);
	ROUGHNESS = 0.95;
	METALLIC = 0.0;
}

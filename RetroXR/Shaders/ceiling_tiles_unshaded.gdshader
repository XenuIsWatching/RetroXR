shader_type spatial;

// The headset variant of `ceiling_tiles`. Same grid, lit from the room's baked
// irradiance volume instead of by Godot. See `arcade_carpet_unshaded` for why
// these variants have no analytic light loop of their own.
//
// The grid's METALLIC is the one thing that does not survive the swap, and it is
// deliberate rather than an omission: a metal runner's look is its specular
// highlight, which is a per-light term, and there are no per-light terms here.
// What is left is the albedo step between fibre and runner, which is what reads
// from three metres below on a mobile display anyway.

render_mode blend_mix, depth_draw_opaque, cull_back, unshaded;

#include "res://Shaders/ceiling_tiles_common.gdshaderinc"
#include "res://Shaders/shell_gi.gdshaderinc"

varying vec3 v_world_pos;
varying vec3 v_world_normal;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	ALBEDO = ceiling_albedo(ceiling_grid(UV))
		* shell_indirect(v_world_pos, normalize(v_world_normal));
}

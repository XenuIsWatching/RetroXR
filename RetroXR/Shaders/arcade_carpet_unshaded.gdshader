shader_type spatial;

// The headset variant of `arcade_carpet`. Same pattern, lit from the room's
// baked irradiance volume instead of by Godot.
//
// WHY. The measurement is `pbr_surface_unshaded`'s and is not repeated here:
// on a mobile frame it is the per-fragment lighting, not the material's own
// work, that costs - a near-full-eye quad wearing the shaded variant spent
// about 90% of its clocks in Godot's light loop. The arcade floor is a single
// 10 x 10 m plane and is the largest such quad in the room.
//
// It has no analytic light loop of its own, and that is the difference from
// `pbr_surface_unshaded`. That shader keeps one because the bedroom's walls must
// follow a wall switch, two pull-cords and a time-of-day lever through it. This
// floor follows the same wall-switch rebind - `shell_lighting.gd` binds the
// on-volume or the off-volume - and nothing else in the arcade moves light
// across the carpet, so a four-light loop would be arithmetic run every frame
// to reproduce a value the volume already holds.

render_mode blend_mix, depth_draw_opaque, cull_back, unshaded;

#include "res://Shaders/arcade_carpet_common.gdshaderinc"
#include "res://Shaders/shell_gi.gdshaderinc"

varying vec3 v_world_pos;
varying vec3 v_world_normal;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	ALBEDO = carpet_albedo(UV) * shell_indirect(v_world_pos, normalize(v_world_normal));
}

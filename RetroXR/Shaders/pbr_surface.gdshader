shader_type spatial;

// Room shell surface — walls, floor and ceiling of a boxed room.
//
// Two jobs a StandardMaterial3D could not do here.
//
// 1. WORLD-METRIC TILING. Every wall in these rooms is a BoxMesh, and Godot
//    normalises a box's UVs to 0..1 per face whatever the box's size. One
//    material with one uv1_scale therefore puts the SAME tile count across a
//    5.2 m wall and a 0.5 m strip beside a door — a 10x density step at the
//    corner where they meet, plus a 2:1 stretch on the wide walls (2.5 tiles
//    across 5.2 m against 2.5 up 2.6 m). Here the UV comes from world position
//    instead, so `tiles_per_metre` means what it says on every surface.
//
// 2. CONTACT DARKENING. Shadows are off on Quest and SSAO/SSIL are no-ops on
//    the mobile backend (quality_manager.gd gates them behind Forward+), so
//    nothing whatsoever darkens a corner there. A tiling AO map cannot do it
//    either — it describes the texture's own micro-relief and knows nothing
//    about where the room's corners are. So the corner shading is analytic,
//    from world position against the room's own extents, and costs no texture
//    read. It is authored lighting, not a measurement.
//
// This is the DESKTOP variant: it hands the surface to Godot's lighting and
// gets the full PBR treatment. On a headset a shell material is swapped to
// `pbr_surface_unshaded.gdshader` instead, which measured 10x cheaper on the
// draws that dominate the bedroom frame. See that file for why.

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://Shaders/pbr_surface_common.gdshaderinc"

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_local_pos = VERTEX;
	v_local_normal = normalize(NORMAL);
}

void fragment() {
	vec2 uv = shell_uv();
	float contact = shell_contact();

	ALBEDO = shell_albedo(uv) * contact;
	ROUGHNESS = shell_roughness(uv);
	METALLIC = 0.0;
	NORMAL_MAP = texture(normal_tex, uv).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
	// Feed the same term to AO so it darkens the ambient/indirect contribution
	// too, not only the albedo — that is where a flat constant ambient shows.
	AO = contact;
	AO_LIGHT_AFFECT = 0.0;
}

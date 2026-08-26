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
//    The plane is PICKED from the dominant world-normal axis rather than
//    blended across all three. That is the whole reason this costs the same as
//    a StandardMaterial3D: full triplanar would be three samples per map, nine
//    for colour/roughness/normal, over the largest fragment coverage in the
//    room. Every surface here is axis-aligned, so the blend would buy nothing.
//    A surface at 45 deg WOULD show a seam — this shader is for the shell, not
//    for props.
//
// 2. CONTACT DARKENING. Shadows are off on Quest and SSAO/SSIL are no-ops on
//    the mobile backend (quality_manager.gd gates them behind Forward+), so
//    nothing whatsoever darkens a corner there. A tiling AO map cannot do it
//    either — it describes the texture's own micro-relief and knows nothing
//    about where the room's corners are. So the corner shading is analytic,
//    from world position against the room's own extents, and costs no texture
//    read. It is authored lighting, not a measurement.

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D roughness_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float tiles_per_metre : hint_range(0.1, 4.0) = 0.75;

// Sample in the MODEL's own frame instead of the room's. For the shell this
// must stay false — a wall's model frame is its own centre, so neighbouring
// wall pieces would each restart their tiling and the corners would step again,
// which is the whole bug this shader exists to fix. It is true for a prop that
// wants grain in its own axes (the door), where world space would run the grain
// through the object at whatever angle the prop happens to be yawed to.
uniform bool object_space = false;

// Mix the sampled colour TOWARD the tint rather than multiplying by it. A tint
// can only ever darken a texture, so there is no multiplier that turns oak into
// a white door — but paint does not darken wood either, it covers it while the
// grain and the mill marks still read through in the relief and the sheen. At 0
// this is off and `tint` behaves as an ordinary multiplier; at 1 the colour is
// pure paint and only the normal and roughness maps survive.
uniform float paint_over : hint_range(0.0, 1.0) = 0.0;
// Swap the two UV axes. A wood set's grain runs along one axis of the image;
// on a door the stiles want it vertical, and which way that falls out depends
// on the face the axis-pick lands on.
uniform bool swap_uv = false;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float roughness_scale : hint_range(0.0, 2.0) = 1.0;

// The set has no AmbientOcclusion map (the whole ambientCG Plaster series ships
// none — a flat painted wall has no self-occlusion to bake). Leave this false
// and ao_tex is never read.
uniform bool ao_enabled = false;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;

// --- Contact darkening -------------------------------------------------------
// Room half-extents and the floor/ceiling heights, in the scene's own frame, so
// the shader can measure a fragment's distance to the nearest junction. These
// must match the room the material is used in; they are not derived from
// anything, because a shader cannot see the scene.
uniform vec2 room_half_extent = vec2(2.525, 2.125);
uniform float floor_y = 0.0;
uniform float ceiling_y = 2.6;
uniform float contact_strength : hint_range(0.0, 1.0) = 0.45;
uniform float contact_distance : hint_range(0.05, 1.5) = 0.45;
// Corners read deeper than a flat junction because two surfaces close in.
uniform float corner_boost : hint_range(0.0, 1.0) = 0.5;

varying vec3 v_world_pos;
varying vec3 v_world_normal;
varying vec3 v_local_pos;
varying vec3 v_local_normal;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_local_pos = VERTEX;
	v_local_normal = normalize(NORMAL);
}

// 0 at the junction, 1 once `contact_distance` clear of it.
float open(float dist) {
	return smoothstep(0.0, contact_distance, max(dist, 0.0));
}

void fragment() {
	vec3 n = abs(object_space ? v_local_normal : v_world_normal);
	vec3 p = object_space ? v_local_pos : v_world_pos;

	// Pick the sampling plane from the dominant axis. Each choice drops the axis
	// the surface faces along, so the texture lies IN the surface.
	vec2 uv;
	if (n.y > max(n.x, n.z)) {
		uv = p.xz;          // floor / ceiling
	} else if (n.x > n.z) {
		uv = p.zy;          // east / west walls
	} else {
		uv = p.xy;          // north / south walls
	}
	if (swap_uv) {
		uv = uv.yx;
	}
	uv *= tiles_per_metre;

	vec3 sampled = texture(albedo_tex, uv).rgb;
	vec3 albedo = mix(sampled * tint.rgb, tint.rgb, paint_over);
	float rough = clamp(texture(roughness_tex, uv).r * roughness_scale, 0.0, 1.0);

	if (ao_enabled) {
		float ao = texture(ao_tex, uv).r;
		albedo *= mix(1.0, ao, ao_strength);
	}

	// Contact is a ROOM-space idea, so it always measures against world position
	// and the world normal — never the local ones the UV pick may have used.
	vec3 wp = v_world_pos;
	vec3 wn = abs(v_world_normal);

	// Distance to each of the six planes, as an openness in 0..1.
	float ox = open(room_half_extent.x - abs(wp.x));
	float oz = open(room_half_extent.y - abs(wp.z));
	float oy = min(open(wp.y - floor_y), open(ceiling_y - wp.y));

	// A fragment ON a wall sits at distance ~0 from its own plane, which would
	// darken the entire wall rather than its edges. So each axis only counts
	// when the surface does not face along it: weight by (1 - |n|).
	float wx = mix(1.0, ox, 1.0 - wn.x);
	float wz = mix(1.0, oz, 1.0 - wn.z);
	float wy = mix(1.0, oy, 1.0 - wn.y);

	float openness = wx * wz * wy;
	// Two closing surfaces (a true corner) read deeper than one.
	float pair = wx * wz * wy / max(min(min(wx, wz), wy), 0.001);
	openness *= mix(1.0, pair, corner_boost);

	float contact = mix(1.0 - contact_strength, 1.0, clamp(openness, 0.0, 1.0));

	ALBEDO = albedo * contact;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	NORMAL_MAP = texture(normal_tex, uv).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
	// Feed the same term to AO so it darkens the ambient/indirect contribution
	// too, not only the albedo — that is where a flat constant ambient shows.
	AO = contact;
	AO_LIGHT_AFFECT = 0.0;
}

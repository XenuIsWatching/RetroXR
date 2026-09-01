// Everything `pbr_surface` and `pbr_surface_unshaded` share: the material's
// uniforms, the world-metric UV pick and the analytic contact darkening.
//
// The two variants differ ONLY in how they turn that into a colour — one hands
// the surface to Godot's lighting, the other lights it itself. Anything else
// living in one and not the other is drift, and drift here shows up as the
// walls changing appearance when a player puts the headset on.
//
// Uniforms are declared HERE rather than in each shader: a `.gdshaderinc`
// parameter cannot shadow a uniform, so a shared block has to be the only
// declaration of each name.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D roughness_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float tiles_per_metre : hint_range(0.1, 4.0) = 0.75;

// Marks a material as room SHELL — a wall, a floor, a ceiling, the ground or the
// road — rather than a prop that happens to use the same shader. Only a shell
// material is swapped to the unshaded variant on a headset, because a shell is
// the only thing whose fragment count makes the swap worth its loss of
// generality: a prop is small on screen and wants the real lighting.
//
// It lives on the MATERIAL rather than in a node group because the material is
// what the decision is about, and a room's shell is thirty-odd MeshInstance3D
// nodes sharing seven of them.
uniform bool shell = false;

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
// Slide the tile, in tiles, after scaling. World-position UVs start counting at
// the world origin, which is fine for a texture that only has to tile — and
// wrong for one whose CONTENT has to land somewhere specific. The road is the
// case: its tile carries two solid edge lines and a dashed centre line, so the
// tile boundary has to sit exactly on the kerb rather than wherever z=0 happens
// to fall, or the lane markings run down the wrong part of the tarmac.
uniform vec2 uv_offset = vec2(0.0, 0.0);
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

// The four lines that fill these live in each shader's own vertex() rather than
// in a helper here: Godot refuses a varying assigned anywhere but vertex()
// itself ("Varying may not be assigned in the 'shell_vertex' function"), so the
// duplication is the compiler's rule and not a choice.


// The world-metric UV, from the dominant world-normal axis.
//
// The plane is PICKED rather than blended across all three. That is the whole
// reason this costs the same as a StandardMaterial3D: full triplanar would be
// three samples per map, nine for colour/roughness/normal, over the largest
// fragment coverage in the room. Every surface here is axis-aligned, so the
// blend would buy nothing. A surface at 45 deg WOULD show a seam — this shader
// is for the shell, not for props.
vec2 shell_uv() {
	vec3 n = abs(object_space ? v_local_normal : v_world_normal);
	vec3 p = object_space ? v_local_pos : v_world_pos;

	// Each choice drops the axis the surface faces along, so the texture lies IN
	// the surface.
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
	return uv * tiles_per_metre + uv_offset;
}


// 0 at the junction, 1 once `contact_distance` clear of it.
float shell_open(float dist) {
	return smoothstep(0.0, contact_distance, max(dist, 0.0));
}


// How lit a fragment is by virtue of not being in a corner, in 0..1.
//
// Contact is a ROOM-space idea, so it always measures against world position and
// the world normal — never the local ones the UV pick may have used.
float shell_contact() {
	vec3 wp = v_world_pos;
	vec3 wn = abs(v_world_normal);

	// Distance to each of the six planes, as an openness in 0..1.
	float ox = shell_open(room_half_extent.x - abs(wp.x));
	float oz = shell_open(room_half_extent.y - abs(wp.z));
	float oy = min(shell_open(wp.y - floor_y), shell_open(ceiling_y - wp.y));

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

	return mix(1.0 - contact_strength, 1.0, clamp(openness, 0.0, 1.0));
}


vec3 shell_albedo(vec2 uv) {
	vec3 sampled = texture(albedo_tex, uv).rgb;
	vec3 albedo = mix(sampled * tint.rgb, tint.rgb, paint_over);
	if (ao_enabled) {
		float ao = texture(ao_tex, uv).r;
		albedo *= mix(1.0, ao, ao_strength);
	}
	return albedo;
}


float shell_roughness(vec2 uv) {
	return clamp(texture(roughness_tex, uv).r * roughness_scale, 0.0, 1.0);
}

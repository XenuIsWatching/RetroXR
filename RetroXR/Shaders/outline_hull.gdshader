// Inverted-hull outline — the stencil-free stand-in for outline_mask + outline.
//
// Why this exists: on a Quest 3 (Adreno, Godot 4.7 + vendors 5.1) drawing the
// stencil pair while VRS/foveation is on loses the Vulkan device within about a
// second and a half — a GPU fault in the opaque pass, reproduced two runs out of
// two, and not reproducible with VRS off. It is the stencil specifically: the
// same geometry drawn as this hull, with the depth test off, survives
// indefinitely at 72 fps. So a foveated session gets this shader instead, and
// nothing that runs under VRS touches a stencil buffer.
//
// The technique is the classic one. `cull_front` keeps only the BACKfaces of a
// normal-inflated copy of the mesh, which is the band that pokes out past the
// silhouette; the object's own material still draws and covers the middle, so no
// mask pass is needed to hollow it out. That last part is load-bearing — this is
// only an outline while it is an OVERLAY beside a mesh that is still rendering.
// Give it `material_override` on the object itself and it reads as a solid blob.
//
// What is lost against the stencil pair: the x-ray. That version disables the
// depth test and uses the stencil to carve the middle out, so an outline shows
// through furniture and walls; this one is depth-tested and is hidden by
// whatever is in front of it. Disabling the depth test HERE does not recover the
// effect, it just fills the silhouette in, because there is nothing left to carve
// with. That is the trade a foveated session makes.
shader_type spatial;
render_mode cull_front, unshaded, depth_draw_never, shadows_disabled;

uniform vec4  outline_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float outline_width : hint_range(0.0, 8.0) = 1.0;
uniform float glow_strength : hint_range(0.0, 8.0) = 2.0;
uniform float fade_start    : hint_range(0.0, 10.0) = 0.0;
uniform float fade_end      : hint_range(0.1, 50.0) = 10.0;

varying float v_view_dist;

void vertex() {
	vec3 view_pos    = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 view_normal = normalize(mat3(MODELVIEW_MATRIX) * NORMAL);

	v_view_dist = length(view_pos);

	// View-space size of one pixel at this depth, so the band stays the same
	// number of pixels wide however far away the object is. abs() because
	// Godot's Vulkan projection has a negative Y scale — never hand-map offsets
	// into clip space here, push in view space and let PROJECTION_MATRIX sign it.
	float pixel_size = 2.0 * max(-view_pos.z, 0.01)
		/ (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);

	// Inflate along the screen-plane component of the normal, renormalized so the
	// band keeps full width even where the normal tilts toward the camera.
	float n_len = length(view_normal.xy);
	if (n_len > 1e-4) {
		view_pos += vec3(view_normal.xy / n_len, 0.0) * outline_width * pixel_size;
	}

	POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
}

void fragment() {
	float dist_fade = 1.0 - smoothstep(fade_start, fade_end, v_view_dist);
	// unshaded skips EMISSION, so the HDR glow goes through ALBEDO, exactly as
	// outline.gdshader does it. What is deliberately NOT copied is that shader's
	// ALPHA write: it is there to force the stencil pair into the transparent
	// pass, and writing ALPHA here would do the same, dropping the depth test
	// this outline needs to stay a ring. So the distance fade dims the band
	// instead of dissolving it.
	ALBEDO = outline_color.rgb * (1.0 + glow_strength) * dist_fade;
}

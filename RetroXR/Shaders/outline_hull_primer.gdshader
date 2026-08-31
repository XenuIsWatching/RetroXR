// Screen-footprint primer for the stencil-free hull outline (pass 1 of 2).
//
// The hull has no mask, so it carves its middle out with the depth buffer, and
// a depth buffer holding the object's OWN depth cannot do that job. Two ways it
// fails, both measured:
//   - a transparent source (a disc's clear polycarbonate) never writes depth at
//     all, so the hull fills the whole disc rather than ringing it;
//   - a part raised off the panel it sits on (a remote's button pad, a cartridge
//     label) has its own silhouette, and its band lies IN FRONT of that panel,
//     so the panel's depth cannot reject it — an outline through the middle of
//     the object, on 83 of 210 camera angles.
//
// So this pass does not write the object's depth. It stamps the object's screen
// FOOTPRINT at the near plane: clip z is overridden while clip xy is left alone,
// which is a projection of the silhouette and not a translation of it. The hull
// behind it is then rejected everywhere the object covers and survives only
// outside — the same rule outline_mask.gdshader gets from the stencil, reached
// with the depth test instead, because no stencil may be drawn under VRS.
//
// It must be the BASE material with the hull as its next_pass: passes of one
// instance draw in chain order, which is the only ordering guarantee here.
//
// cull_disabled so a mesh that is not closed still stamps its whole footprint,
// and ALPHA 0 rather than discard because a discarded fragment writes no depth.
shader_type spatial;
render_mode cull_disabled, unshaded, depth_draw_always, shadows_disabled;

void vertex() {
	// z = w puts NDC z at 1.0, which is the NEAR end: Godot's Vulkan projection
	// is reverse-Z. Measured, not assumed — 0.0 leaves every interior outline
	// exactly where it was (10 of 10 angles), 1.0 removes all of them.
	vec4 clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	clip.z = clip.w;
	POSITION = clip;
}

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA  = 0.0;
}

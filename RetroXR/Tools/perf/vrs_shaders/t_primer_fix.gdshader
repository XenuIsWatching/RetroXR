// vrs_dynres_repro: one render feature per file, to find which one the Adreno
// fragment-density path refuses. See Tools/perf/vrs_dynres_repro.gd.
// outline_hull_primer with one interpolant consumed in the fragment stage.
shader_type spatial;
render_mode cull_disabled, unshaded, depth_draw_always, shadows_disabled;
varying float v_keep;
void vertex() {
	vec4 clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	clip.z = clip.w;
	POSITION = clip;
	v_keep = clip.w;
}
void fragment() {
	ALBEDO = vec3(0.0) * min(v_keep, 0.0);
	ALPHA  = 0.0;
}

// vrs_dynres_repro: one render feature per file, to find which one the Adreno
// fragment-density path refuses. See Tools/perf/vrs_dynres_repro.gd.
shader_type spatial;
render_mode unshaded, depth_draw_never;
void fragment() { ALBEDO = vec3(0.2, 1.0, 0.2); }

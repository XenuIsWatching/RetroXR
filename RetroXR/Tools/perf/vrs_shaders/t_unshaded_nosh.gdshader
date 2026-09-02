// vrs_dynres_repro: one render feature per file, to find which one the Adreno
// fragment-density path refuses. See Tools/perf/vrs_dynres_repro.gd.
shader_type spatial;
render_mode unshaded, shadows_disabled;
void fragment() { ALBEDO = vec3(1.0, 0.5, 0.2); }

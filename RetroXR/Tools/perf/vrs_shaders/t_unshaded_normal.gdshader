// vrs_dynres_repro: one render feature per file, to find which one the Adreno
// fragment-density path refuses. See Tools/perf/vrs_dynres_repro.gd.
shader_type spatial;
render_mode unshaded;
void vertex() { VERTEX += NORMAL * 0.001; }
void fragment() { ALBEDO = vec3(0.9, 0.9, 0.2); }

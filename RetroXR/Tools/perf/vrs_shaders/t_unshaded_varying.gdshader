// vrs_dynres_repro: one render feature per file, to find which one the Adreno
// fragment-density path refuses. See Tools/perf/vrs_dynres_repro.gd.
shader_type spatial;
render_mode unshaded;
varying float v_d;
void vertex() { v_d = length(VERTEX); }
void fragment() { ALBEDO = vec3(v_d, 0.3, 0.9); }

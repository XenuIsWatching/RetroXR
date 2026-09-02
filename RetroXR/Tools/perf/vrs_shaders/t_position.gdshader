// vrs_dynres_repro: one render feature per file, to find which one the Adreno
// fragment-density path refuses. See Tools/perf/vrs_dynres_repro.gd.
shader_type spatial;
render_mode unshaded;
void vertex() { POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX * 1.05, 1.0); }
void fragment() { ALBEDO = vec3(1.0, 1.0, 0.2); }

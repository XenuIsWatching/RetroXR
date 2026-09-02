// vrs_dynres_repro: one render feature per file, to find which one the Adreno
// fragment-density path refuses. See Tools/perf/vrs_dynres_repro.gd.
shader_type spatial;
render_mode unshaded;
uniform vec4 tint : source_color = vec4(0.2, 0.9, 0.4, 1.0);
void fragment() { ALBEDO = tint.rgb; }

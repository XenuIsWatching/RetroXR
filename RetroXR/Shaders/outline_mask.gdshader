// Outline mask — stencil-masked inverted hull (pass 1 of 2).
//
// Draws the un-inflated mesh invisibly (ALPHA = 0) with depth testing disabled,
// writing ref 2 into the stencil buffer wherever the object lands on screen.
// outline.gdshader (chained via next_pass, priority 2) then renders the
// inflated hull only where the stencil does NOT equal 2 — the ring just
// outside this footprint.
//
// ALPHA is written solely to force this draw into the transparent pass, where
// render_priority ordering guarantees all masks land before any outline pass
// (and where stencil access is supported — reads fail in the opaque pass).
shader_type spatial;
render_mode cull_disabled, unshaded, depth_draw_never, depth_test_disabled;
stencil_mode write, compare_always, 2;

// The fragment stage must read SOMETHING the compiler cannot fold away. A pass whose
// compiled fragment output is a plain constant - as this one was, ALBEDO 0 / ALPHA 0 -
// loses the Vulkan device on a Quest 3's Adreno the moment a VRS density map is
// attached (Tools/perf/vrs_dynres_repro, 12 shader variants, 2026-09-02). Reading a
// uniform is the cheapest input the optimiser has to keep; it defaults to the 0 this
// pass always meant.
uniform float alpha_bias : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA  = alpha_bias;
}

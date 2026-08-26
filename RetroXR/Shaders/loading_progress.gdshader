shader_type spatial;
// depth_test_disabled puts the bar in the transparent pass, where render_priority
// is honoured, so the panel can be drawn over a curtain that is itself covering a
// live room. ALPHA is never written, so it still paints solid.
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform bool failed = false;

void fragment() {
	float segment = step(0.14, fract(UV.x * 18.0));
	float inside = step(0.06, UV.y) * step(UV.y, 0.94);
	float filled = step(UV.x, progress);
	float pulse = 0.88 + 0.12 * sin(TIME * 4.0 - UV.x * 9.0);
	vec3 track = vec3(0.075, 0.085, 0.17);
	vec3 success = mix(vec3(0.28, 0.55, 1.0), vec3(0.20, 1.0, 0.70), UV.x);
	vec3 error_color = mix(vec3(1.0, 0.18, 0.12), vec3(1.0, 0.55, 0.12), UV.x);
	vec3 active = (failed ? error_color : success) * pulse;
	vec3 color = mix(track, active, filled * segment * inside);
	ALBEDO = color;
}

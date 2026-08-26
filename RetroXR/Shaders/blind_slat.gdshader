shader_type spatial;

// Vinyl mini-blind slats. Vinyl, not paper: a little sheen so the slats separate
// under the sun rather than reading as one flat sheet.
//
// The sway is done HERE, in the vertex stage, and that is a performance decision
// rather than an aesthetic one. The slats are 48 MultiMesh instances; nudging
// them from GDScript would be 48 set_instance_transform calls every frame, on a
// build that is already CPU-bound at 120 Hz. In the vertex shader it costs the
// CPU nothing at all and the GPU a sine per vertex.
//
// It also means the SHADOW matches. Godot runs this same vertex function for the
// shadow pass, so the slat shadows thrown across the floor on desktop breathe
// with the slats instead of standing still while the blind moves.

render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 slat_color : source_color = vec4(0.87, 0.85, 0.79, 1.0);
uniform float slat_roughness : hint_range(0.0, 1.0) = 0.42;

// Peak deflection of a slat's middle, in metres. Set to 0 by the script when the
// blind is fully raised — a stack of slats bunched against the headrail has no
// free length to move.
uniform float sway_amplitude : hint_range(0.0, 0.05) = 0.006;
uniform float sway_speed : hint_range(0.0, 4.0) = 1.1;
// How much the wave is offset per metre DOWN the blind, so the movement travels
// through the stack instead of every slat swinging as one board.
uniform float sway_wavelength : hint_range(0.5, 30.0) = 7.0;
// Half the slat's width, for the bow shape below.
uniform float slat_half_width = 0.72;
// A second, slower wave at a different rate so the motion never visibly repeats.
uniform float sway_secondary : hint_range(0.0, 1.0) = 0.45;

void vertex() {
	// A slat is held at its ends by the ladder cords and free in the middle, so
	// it BOWS rather than sliding: full deflection at the centre, none at the
	// ends. (1 - (x/half)^2) is that curve.
	float across = clamp(VERTEX.x / slat_half_width, -1.0, 1.0);
	float bow = 1.0 - across * across;

	// Per-instance phase from the slat's own height. For a MultiMesh, MODEL_MATRIX
	// carries the per-instance transform, so this differs slat to slat and the
	// wave travels down the blind.
	float phase = MODEL_MATRIX[3].y * sway_wavelength;

	float wave = sin(TIME * sway_speed + phase)
		+ sway_secondary * sin(TIME * sway_speed * 0.41 + phase * 1.7);

	// Deflect along the slat's thickness axis — into and out of the room.
	VERTEX.z += wave * bow * sway_amplitude;
}

void fragment() {
	ALBEDO = slat_color.rgb;
	ROUGHNESS = slat_roughness;
	METALLIC = 0.0;
}

shader_type spatial;

// One material for every baked connector in the room.
//
// A phono jack used to be three surfaces on three StandardMaterial3Ds, and
// recolouring one for the audio pair duplicated a material per jack: a
// television's thirteen sockets were thirty-nine draws and thirty-seven
// distinct materials, and the plugs on every lead the same again. The mobile
// renderer batches nothing, so that was the single largest draw count in an
// eight-machine arcade.
//
// The part is carried in the VERTEX COLOUR instead: rgb is the part's own
// albedo, alpha is its class (Tools/gen/plug_materials.gd names them):
//   1.0   gloss plastic in the INSTANCE tint - the channel-coded body
//   0.85  gloss plastic in its own colour   - a black coax or DIN body
//   0.7   matte plastic in its own colour   - a hood, a surround
//   0.5   plated metal                       - collars, pins, flanges
//   0.0   the dark recessed contact
// The channel colour comes in as an INSTANCE uniform, so a white or red jack
// is a per-instance parameter on one shared material rather than a copy of
// it. One surface, one draw, no duplicates.
//
// The looks are plug_materials.gd's recipes, kept here verbatim so a
// connector on this shader is indistinguishable from the StandardMaterial3D
// it replaced: clearcoated gloss, dry matte, plating backed off to 0.8
// metallic because these rooms have no radiance map to reflect, and a rough
// near-black bore.

render_mode cull_back;

instance uniform vec4 tint : source_color = vec4(0.95, 0.74, 0.02, 1.0);


void fragment() {
	float cls = COLOR.a;
	float tinted = step(0.92, cls);
	float gloss = step(0.78, cls);            // tinted or own-colour gloss
	float matte = step(0.6, cls) * (1.0 - gloss);
	float metal = step(0.35, cls) * (1.0 - gloss) * (1.0 - matte);
	float socket = 1.0 - gloss - matte - metal;
	float plastic = gloss + matte;

	ALBEDO = mix(COLOR.rgb, tint.rgb, tinted);
	METALLIC = 0.8 * (1.0 - plastic);
	ROUGHNESS = 0.30 * gloss + 0.72 * matte + 0.20 * metal + 0.55 * socket;
	SPECULAR = 0.55 * gloss + 0.28 * matte + 0.75 * (metal + socket);
	CLEARCOAT = 0.55 * gloss;
	CLEARCOAT_ROUGHNESS = 0.12;
	RIM = 0.30 * gloss;
	RIM_TINT = 0.25;
}

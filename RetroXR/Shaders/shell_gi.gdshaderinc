// What a room's shell surface is lit BY, on a headset: a baked irradiance volume
// when the room ships one, and a hemispheric ambient when it does not.
//
// Extracted so the three shell shaders share one definition of it. They differ
// in what they paint — plaster from a texture set, a procedural arcade carpet, a
// procedural ceiling grid — and agreed exactly on how they read the volume,
// which is the sort of agreement that survives right up until someone fixes a
// bug in one copy. `pbr_surface_unshaded` was the original and this is its
// sampling, moved rather than rewritten.
//
// The PROP shader deliberately does not use this. `pbr_prop_unshaded` fades to a
// fallback across the volume's last texel, because a prop can be carried out of
// the room and a wall cannot, and folding that in would put a branch in the
// shell's hot path to serve a case the shell does not have.
//
// Varyings are NOT declared here. `pbr_surface_common.gdshaderinc` already
// declares `v_world_pos` and `v_world_normal`, a `.gdshaderinc` parameter cannot
// shadow a uniform, and a shader that includes both would collide — so world
// position and normal come in as arguments instead.

// Hemispheric ambient, fed by `shell_lighting.gd`. Godot's own is a single
// constant colour, which leaves a normal map completely flat wherever no light
// reaches; splitting it by the world normal's Y costs one mix and keeps a
// surface's relief readable in the parts of the room the lamps do not get to.
//
// LINEAR, not `source_color`: these are written from script beside the light
// array, whose alpha carries an energy and so cannot be a `source_color`
// uniform. One converter in `shell_lighting.gd` handles them all rather than
// half being converted by the engine and half not.
uniform vec3 ambient_sky = vec3(0.35, 0.33, 0.30);
uniform vec3 ambient_ground = vec3(0.16, 0.14, 0.13);
uniform float ambient_energy : hint_range(0.0, 4.0) = 1.0;

// Lambert goes hard to black at the terminator, which on a large flat wall reads
// as a seam. Wrapping the diffuse pushes the terminator round the back and is
// what a rough painted surface with a lot of local bounce actually looks like.
// Kept small: at 0.35 it lifted every unlit wall and the room read flat.
uniform float diffuse_wrap : hint_range(0.0, 1.0) = 0.12;

// When a room ships a bake, the shader's light loop is not run at all: the
// lighting comes from a volume indexed by world position, which costs two
// fetches and no arithmetic. Measured on a Quest 3 at eye buffer 1.00x,
// bedroom: Godot's lighting 20.04 ms, an analytic four-light loop 14.72 ms, a
// bake-shaped profile 12.34 ms - 72 fps, the refresh cap.
uniform bool use_gi = false;
uniform sampler3D gi_irr : filter_linear, repeat_disable;
uniform sampler3D gi_dir : filter_linear, repeat_disable;
uniform vec3 gi_min = vec3(0.0);
uniform vec3 gi_size = vec3(1.0);


float shell_wrapped_ndl(vec3 n, vec3 l) {
	return clamp((dot(n, l) + diffuse_wrap) / (1.0 + diffuse_wrap), 0.0, 1.0);
}


vec3 shell_ambient(vec3 n) {
	return mix(ambient_ground, ambient_sky, n.y * 0.5 + 0.5) * ambient_energy;
}


// The volume's light at a point, for a surface facing `n`.
//
// `gi_dir` is what stops a volume looking like flat ambient. Irradiance at a
// point knows nothing about which way a surface faces, so the ceiling under a
// lamp would read as brightly as the floor. The dominant direction and how
// directional the point is (a = 1 one lamp, a = 0 fully diffuse) put the normal
// back in.
vec3 shell_gi_irradiance(vec3 world_pos, vec3 n) {
	vec3 uvw = clamp((world_pos - gi_min) / gi_size, vec3(0.0), vec3(1.0));
	vec4 dr = texture(gi_dir, uvw);
	vec3 l = normalize(dr.rgb * 2.0 - 1.0);
	return texture(gi_irr, uvw).rgb * mix(1.0, shell_wrapped_ndl(n, l), dr.a);
}


// What multiplies a shell surface's albedo, whether or not the room has a bake.
//
// The branch is on a uniform, so it is coherent across every fragment in the
// draw and only one side is ever taken. For a shader with no analytic light loop
// of its own this is the whole of its lighting, and the ambient side is a floor
// rather than a second lit look: a room without a bake is not the case those
// shaders were written for, it is the case they must not go black in.
vec3 shell_indirect(vec3 world_pos, vec3 n) {
	if (use_gi) {
		return shell_gi_irradiance(world_pos, n);
	}
	return shell_ambient(n);
}

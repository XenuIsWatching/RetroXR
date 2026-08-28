## Shared material recipes for the baked connector meshes.
##
## Used at BAKE time only — gen_rca_plug.gd and gen_ps2_plug.gd call these and the
## result is serialised into the .res, so nothing loads this at runtime. It exists
## so the RCA and PS/2 plugs cannot drift apart in finish; they sit on the same
## desk and a difference in gloss between them reads as one of them being wrong.
##
## Preloaded rather than given a class_name, to keep it out of the global class
## list for something only two tool scripts use:
##
##   const PlugMats := preload("res://Tools/gen/plug_materials.gd")
extends RefCounted


## Injection-moulded connector plastic.
##
## The clearcoat lobe is the important part. Without it these read as flat
## vertex-coloured plastic; with it every rib crest and ring groove picks up a
## tight highlight, which is what makes moulded detail legible under a single key
## light. Rim adds a little edge sheen so a barrel still has a silhouette against
## a dark cabinet.
static func plastic(albedo: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = 0.30
	m.metallic = 0.0
	m.specular = 0.55
	m.clearcoat_enabled = true
	m.clearcoat = 0.55
	m.clearcoat_roughness = 0.12
	m.rim_enabled = true
	m.rim = 0.30
	m.rim_tint = 0.25
	return m


## Moulded connector plastic with no lacquer on it — a hood, a strain relief, a
## panel-mount surround.
##
## The clearcoat is the whole difference from plastic() above, and it is why this
## exists rather than a roughness argument: a clearcoat lobe reads as a WET surface at
## any roughness, so an RVL-011 hood given the glossy recipe came back looking like
## polished acrylic instead of the dry, slightly rubbery grey it is. Specular drops
## with it, and the rim sheen goes — an edge highlight on a matte moulding is another
## thing that says "varnished".
##
## Kept as a sibling rather than a flag so the two families cannot drift: every phono
## and DE-15 connector in the room is glossy and stays that way.
static func matte(albedo: Color, roughness: float = 0.72) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = roughness
	m.metallic = 0.0
	m.specular = 0.28
	return m


## Plated metal — connector shells, collars, pins.
##
## NOT metallic 1.0, deliberately. A fully metallic surface takes essentially all
## its colour from environment reflections, and these rooms light with
## ambient_light_source = COLOR and no ReflectionProbe. There is no radiance map to
## reflect, so full metal renders as a dark blob carrying a single direct-light
## highlight. Backing off to 0.8 leaves a diffuse component the flat ambient can
## light, and the part still reads as plated.
static func metal(albedo: Color, roughness: float = 0.20) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.metallic = 0.80
	m.roughness = roughness
	m.specular = 0.75
	return m


static func chrome() -> StandardMaterial3D:
	return metal(Color(0.82, 0.83, 0.86), 0.20)


static func brass() -> StandardMaterial3D:
	return metal(Color(0.86, 0.78, 0.48), 0.26)

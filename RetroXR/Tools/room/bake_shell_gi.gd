## Bakes a room's shell lighting into a pair of irradiance volumes — one with the
## ceiling light on, one with it off.
##
## WHY A VOLUME AND NOT A LIGHTMAP. Every shell surface in these rooms is a
## BoxMesh or a PlaneMesh, and a primitive carries no UV2 (measured: `BoxMesh
## UV=true UV2=false`). A LightmapGI bake would therefore mean converting all
## thirty-odd of them to ArrayMesh and unwrapping each one, which throws away the
## readable `size = Vector3(...)` the room is authored with. A volume is indexed
## by world position, which `pbr_surface_unshaded` already carries as a varying,
## so nothing about the geometry has to change.
##
## WHY IT IS WORTH BAKING AT ALL. Measured on a Quest 3, bedroom, VrApi App time
## at eye buffer 1.00x: Godot's lighting 20.04 ms, the four-light analytic loop
## 14.72 ms, and a lightmap-shaped profile — one extra texture fetch, no loop —
## 12.34 ms, which is 72 fps and the refresh cap. The loop's arithmetic costs
## more than a fetch, which is the opposite of what the capture's saturated
## texture pipe suggested.
##
## It also buys something the analytic loop could never have: OCCLUSION. Each
## grid point raycasts to each light, so the wardrobe and the bed actually cast
## shade here. Nothing has cast a shadow on this shell on a headset before.
##
## Run it windowed or headless — it is physics and arithmetic, no rendering:
##   godot --headless --path RetroXR res://Tools/room/bake_shell_gi.tscn
extends Node

const OUT_DIR := "res://Scenes/baked"

## Metres per texel. The smallest thing the field has to describe is a lamp's
## falloff across a wall, not a hard edge, so this is about resolution of a
## gradient rather than of a shadow. 0.16 puts the bedroom at 33x17x28.
const TEXEL := 0.16

## Pad the grid past the room's bounds so a wall ON the boundary samples inside
## the volume rather than off its clamped edge, where the value belongs to the
## texel centre half a texel away.
const PAD := 0.4

## Lights whose state the two bakes differ by. Everything else is baked as it
## stands at bake time.
const SWITCHED_GROUP := "ceiling_light"

## Only the room's INTERIOR is baked. The ground, road, kerbs and soil outside
## the window wear shell materials too, and including them put the volume's
## bounds at 140 x 3.6 x 140 m — a grid of 17.8 million texels describing a
## street at 16 cm, to light a bedroom. They are on render layer 2 (set by
## bedroom_exterior.gd) and stay on the analytic loop, which is the right place
## for a surface lit by two directional lights and no local lamps.
const INTERIOR_LAYER := 1

## Refuse to bake a grid past this. A wrong bounds is otherwise an overnight run
## that ends in a texture nothing can sample.
const MAX_TEXELS := 4_000_000


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var scene := "res://Scenes/BedroomScene.tscn"
	var name := "bedroom"
	for a in args:
		if a.begins_with("--scene="):
			scene = a.substr(8)
		elif a.begins_with("--name="):
			name = a.substr(7)
	await _bake(scene, name)
	get_tree().quit(0)


func _bake(scene_path: String, out_name: String) -> void:
	var room: Node3D = load(scene_path).instantiate() as Node3D
	add_child(room)
	# Physics needs a tick before a raycast reports anything, and the room's own
	# _ready work (blinds duplicating the environment, time of day writing every
	# light) has to land before the lights are read.
	for i in 20:
		await get_tree().process_frame
	await get_tree().physics_frame

	var bounds := _shell_bounds(room)
	if bounds.size == Vector3.ZERO:
		push_error("[bake] no shell meshes found in %s" % scene_path)
		return
	bounds = bounds.grow(PAD)
	var dims := Vector3i(
		maxi(2, int(ceil(bounds.size.x / TEXEL))),
		maxi(2, int(ceil(bounds.size.y / TEXEL))),
		maxi(2, int(ceil(bounds.size.z / TEXEL))))
	var texels := dims.x * dims.y * dims.z
	print("[bake] %s  bounds %s  size %s  grid %s (%d texels)" % [
		out_name, bounds.position, bounds.size, dims, texels])
	if texels > MAX_TEXELS:
		push_error("[bake] %d texels exceeds the %d cap - check the bounds" % [
			texels, MAX_TEXELS])
		return

	var switched: Array[Light3D] = []
	for node in room.find_children("*", "Light3D", true, false):
		if node.is_in_group(SWITCHED_GROUP):
			switched.append(node as Light3D)
	print("[bake] switched lights: %d" % switched.size())

	var was := []
	for l in switched:
		was.append(l.visible)

	for state in ["on", "off"]:
		for l in switched:
			l.visible = state == "on"
		await get_tree().physics_frame
		var pair := _bake_state(room, bounds, dims)
		_save(pair[0], pair[1], bounds, dims, "%s_gi_%s" % [out_name, state])

	for i in switched.size():
		switched[i].visible = was[i]


## Union of the AABBs of every mesh wearing a shell material — the volume only
## has to cover the surfaces that will sample it.
func _shell_bounds(room: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for node in room.find_children("*", "GeometryInstance3D", true, false):
		var gi := node as GeometryInstance3D
		if gi.layers & INTERIOR_LAYER == 0 or not _wears_shell(gi):
			continue
		var box := gi.global_transform * gi.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out


func _wears_shell(gi: GeometryInstance3D) -> bool:
	var mats: Array[ShaderMaterial] = []
	var over := gi.material_override as ShaderMaterial
	if over != null:
		mats.append(over)
	var mi := gi as MeshInstance3D
	if mi != null and mi.mesh != null:
		for i in mi.mesh.get_surface_count():
			var m := mi.get_surface_override_material(i) as ShaderMaterial
			if m == null:
				m = mi.mesh.surface_get_material(i) as ShaderMaterial
			if m != null:
				mats.append(m)
	for m in mats:
		if m.shader != null and m.get_shader_parameter("shell") == true:
			return true
	return false


## One state, as two images: irradiance and dominant direction.
func _bake_state(room: Node3D, bounds: AABB, dims: Vector3i) -> Array:
	var lights: Array[Light3D] = []
	for node in room.find_children("*", "Light3D", true, false):
		var l := node as Light3D
		if l.is_visible_in_tree() and l.light_energy > 0.0:
			lights.append(l)

	var amb := Color(0, 0, 0)
	var found := room.find_children("*", "WorldEnvironment", true, false)
	if not found.is_empty():
		var env: Environment = (found[0] as WorldEnvironment).environment
		if env != null:
			amb = env.ambient_light_color.srgb_to_linear() * env.ambient_light_energy

	var space := (room.get_viewport() as Viewport).world_3d.direct_space_state
	var irr := PackedByteArray()
	var dir := PackedByteArray()
	var step := bounds.size / Vector3(dims)

	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				var p := bounds.position + (Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5)) * step
				var sum := Vector3(amb.r, amb.g, amb.b)
				var axis := Vector3.ZERO
				for l in lights:
					var contrib := _contribution(l, p, space)
					if contrib[0] == Vector3.ZERO:
						continue
					sum += contrib[0]
					axis += (contrib[1] as Vector3) * _luma(contrib[0])
				_push_rgbah(irr, sum)
				var lum := _luma(sum)
				var frac: float = clampf(axis.length() / maxf(lum, 0.0001), 0.0, 1.0)
				var n: Vector3 = axis.normalized() if axis.length() > 0.0001 else Vector3.UP
				_push_rgba8(dir, n, frac)
	return [irr, dir]


## What one light puts at a point, and the direction it comes from.
##
## Uses the engine's own omni curve rather than a linear ramp, so the bake and
## the shader's fallback loop agree — `light_energy` is an intensity and
## `omni_range` a cull boundary, and a ramp makes every lamp far too weak.
func _contribution(l: Light3D, p: Vector3, space: PhysicsDirectSpaceState3D) -> Array:
	var col := l.light_color.srgb_to_linear()
	var to_light: Vector3
	var atten := 1.0
	var target: Vector3
	if l is DirectionalLight3D:
		to_light = l.global_transform.basis.z.normalized()
		target = p + to_light * 50.0
	else:
		var d := l.global_position - p
		var dist := d.length()
		to_light = d / maxf(dist, 0.0001)
		target = l.global_position
		var spot := l as SpotLight3D
		var range_m: float = spot.spot_range if spot != null else (l as OmniLight3D).omni_range
		var decay: float = spot.spot_attenuation if spot != null \
			else (l as OmniLight3D).omni_attenuation
		if dist >= range_m:
			return [Vector3.ZERO, Vector3.UP]
		var nd := dist / range_m
		nd = nd * nd
		nd = nd * nd
		nd = maxf(1.0 - nd, 0.0)
		atten = nd * nd * pow(maxf(dist, 0.0001), -maxf(decay, 0.0001))
		if spot != null:
			var cone := cos(deg_to_rad(spot.spot_angle))
			var scos: float = maxf((-to_light).dot(-spot.global_transform.basis.z.normalized()), cone)
			var rim := (1.0 - scos) / maxf(1.0 - cone, 0.0001)
			atten *= 1.0 - pow(rim, maxf(spot.spot_angle_attenuation, 0.0001))
	if atten <= 0.0:
		return [Vector3.ZERO, Vector3.UP]

	# Occlusion. The whole reason a bake beats the analytic loop on looks rather
	# than only on cost: the room's own furniture gets to block a lamp.
	var query := PhysicsRayQueryParameters3D.create(p, target)
	query.collide_with_areas = false
	if not space.intersect_ray(query).is_empty():
		return [Vector3.ZERO, Vector3.UP]

	var e := Vector3(col.r, col.g, col.b) * l.light_energy * atten
	return [e, to_light]


func _luma(v: Vector3) -> float:
	return v.x * 0.2126 + v.y * 0.7152 + v.z * 0.0722


func _push_rgbah(out: PackedByteArray, v: Vector3) -> void:
	# RGBAH: irradiance routinely exceeds 1.0 near a lamp, so an 8-bit format
	# would clip the brightest part of every wall the room has.
	for c in [v.x, v.y, v.z, 1.0]:
		out.append_array(_half(c))


func _push_rgba8(out: PackedByteArray, n: Vector3, frac: float) -> void:
	out.append(int(clampf(n.x * 0.5 + 0.5, 0.0, 1.0) * 255.0))
	out.append(int(clampf(n.y * 0.5 + 0.5, 0.0, 1.0) * 255.0))
	out.append(int(clampf(n.z * 0.5 + 0.5, 0.0, 1.0) * 255.0))
	out.append(int(clampf(frac, 0.0, 1.0) * 255.0))


func _half(f: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_half(0, f)
	return b


## Saved as two flat `Image` resources rather than as ImageTexture3D.
##
## An ImageTexture3D drops its source images once it has uploaded them — its
## get_data() fails with "raw_images.is_empty()" — so ResourceSaver writes a
## texture with no pixels in it and reports success. An Image serialises
## properly, so the volume is stored as a TALL 2D image, dims.z slices of
## dims.y rows stacked, and rebuilt into a 3D texture at load. The grid's frame
## rides along as resource metadata, because the shader cannot derive a world
## position from the texture and nothing else in the scene knows it.
func _save(irr: PackedByteArray, dir: PackedByteArray, bounds: AABB,
		dims: Vector3i, out_name: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var tall := dims.y * dims.z
	var images := {
		"irr": Image.create_from_data(dims.x, tall, false, Image.FORMAT_RGBAH, irr),
		"dir": Image.create_from_data(dims.x, tall, false, Image.FORMAT_RGBA8, dir),
	}
	for suffix in images:
		var img: Image = images[suffix]
		img.set_meta("gi_min", bounds.position)
		img.set_meta("gi_size", bounds.size)
		img.set_meta("gi_dims", dims)
		var path := "%s/%s_%s.res" % [OUT_DIR, out_name, suffix]
		var err := ResourceSaver.save(img, path)
		if err != OK:
			push_error("[bake] could not write %s (%d)" % [path, err])
			return
	print("[bake] wrote %s  %dx%dx%d  (%d texels, %.0f KiB)" % [
		out_name, dims.x, dims.y, dims.z, dims.x * dims.y * dims.z,
		(irr.size() + dir.size()) / 1024.0])

## Swaps a room's shell materials to the unshaded variant on a headset, and
## feeds them the room's real lights.
##
## Only on mobile VR. On a desktop the shell keeps Godot's lighting: the whole
## trade here is buying fragment cost back by giving up shadows, probes and
## clustering, and a desktop GPU is not short of any of them. See
## `pbr_surface_unshaded.gdshader` for the measurement that motivates it.
##
## WHAT IT OWNS. Only the shell materials' own light uniforms. It never writes a
## Light3D — it reads them, every one of them, and so a switch flipped, a cord
## pulled, a TV turned on or the time lever dragged all still reach the walls
## through their ordinary owner. That is the whole reason this is a light LOOP
## rather than authored constants.
class_name ShellLighting
extends Node

## The bound volume changed, because the wall switch was flipped. PropLighting
## listens so the machines and the furniture go dark with the walls rather than
## staying lit in a room whose light was just switched off.
signal bake_volume_changed(volume: Dictionary)

## Every shell shader, and the unshaded twin it is swapped to on a headset.
##
## A map rather than one pair because a room's shell is not one material: the
## bedroom's walls, floor and ceiling all wear `pbr_surface`, and the arcade's
## floor and ceiling are two procedural shaders that could not be one - a neon
## carpet pattern and a tile grid are not a texture set. What they share is the
## contract, not the paint: each twin reads the same baked volume through
## `shell_gi.gdshaderinc` and takes the same uniforms from this node.
const SHELL_SHADERS := {
	"res://Shaders/pbr_surface.gdshader": "res://Shaders/pbr_surface_unshaded.gdshader",
	"res://Shaders/arcade_carpet.gdshader": "res://Shaders/arcade_carpet_unshaded.gdshader",
	"res://Shaders/ceiling_tiles.gdshader": "res://Shaders/ceiling_tiles_unshaded.gdshader",
}

## Slots in the shader. Past this the lights are ranked and the tail dropped.
const MAX_LIGHTS := 4

## Room to convert and light. Empty means this node's parent, which is what a
## room scene wants.
@export var room_path: NodePath

## How often the light uniforms are refreshed, in seconds. The room's lights
## change on a human action — a switch, a cord, a lever — never per frame, and
## the one exception (the TV's screen-cast light) already updates on a six-frame
## cadence of its own. 10 Hz is under the rate any of those reads as stepped at
## and costs a few dozen uniform writes.
@export var update_interval: float = 0.1

## WorldEnvironment whose ambient this shell follows. Empty means the room is
## searched for one. Godot's own ambient never reaches an unshaded fragment, so
## without this the blinds and the time lever would still move every light in
## the room and leave the walls' base level fixed.
@export var world_env_path: NodePath

## How much darker the downward half of the hemispheric ambient is than the
## upward half. Godot's ambient is one flat colour, which leaves a normal map
## dead wherever no lamp reaches; splitting it costs one mix and keeps the
## plaster's relief readable there.
@export_range(0.0, 1.0) var ambient_floor_ratio: float = 0.45

## Basename of this room's baked irradiance volumes under `res://Scenes/baked`,
## as written by `Tools/room/bake_shell_gi.gd`. Empty, or a bake that is not on
## disk, leaves every material on the analytic loop — which is what a room
## without a bake wants, and is why this is not an error.
@export var gi_bake: String = ""

## Render layer the bake covers. The volume is fitted to the room's INTERIOR;
## the ground, road and kerbs outside the window are on layer 2, sit far outside
## it, and keep the analytic loop.
@export_flags_3d_render var gi_layers: int = 1

const BAKE_DIR := "res://Scenes/baked"

## Group naming the lights the two bakes differ by. Their state chooses which
## volume is bound.
const SWITCHED_GROUP := "ceiling_light"

## Lights that exist only to fake shell lighting, and which a bake makes
## redundant. The bedroom's "Dusk" is a directional fill standing in for sky
## light indoors, and "FloorBounce" is a fake bounce under the ceiling globe -
## both were authored because nothing was lighting the walls. The volume carries
## both now, and every light left in the room costs the PROPS: measured on a
## Quest 3 at eye buffer 1.75x, the room's lights are 5.8 ms of a 24.9 ms frame.
##
## Only dropped where a bake is actually bound, so a desktop and any room
## without one keep them.
const SHELL_ONLY_GROUP := "shell_only_light"

var _materials: Array[ShaderMaterial] = []
## Render layer mask each material's meshes were found on, parallel to
## `_materials`. A light only reaches a material whose layers its cull mask
## covers — that split is what keeps the street's sun off the bedroom's walls
## and the bedroom's lamp off the street.
var _layers: PackedInt32Array = PackedInt32Array()
## World-space bounds of the meshes wearing each material, parallel to
## `_materials`. A material is shared by every wall in the room, so there is no
## single point to measure a light's distance from — but there IS a box, and the
## nearest point on it is what decides whether a light reaches the material at
## all. Without this the ranking is by raw energy, and the street lamp outside
## (3.6 energy, 16 m away, 14 m range) takes the top slot in the bedroom while
## contributing nothing, pushing a lamp that IS lighting the wall out of the
## budget. That is not hypothetical: it is what the first run did.
var _bounds: Array[AABB] = []
var _room: Node3D
var _elapsed: float = 0.0
## {"on": {"irr": ImageTexture3D, "dir": ImageTexture3D}, "off": {...}}
var _volumes: Dictionary = {}
var _gi_min: Vector3
var _gi_size: Vector3
## Which volume is currently bound, so a rebind only happens when it changes.
var _gi_state: String = ""


const OFF_CFG := "/sdcard/Android/data/com.xenu.retroxr/files/shellshaded.cfg"


## Mobile VR is the only place this trade is worth making.
##
## `--shell-unshaded` forces it on anywhere, which is how the headset path gets
## LOOKED at: the whole point of this shader is how the room reads, and a
## desktop render of the desktop path cannot show a regression in it. Same shape
## as the other on-device QA hooks in this project.
##
## `shellshaded.cfg` in the external files dir forces it back OFF on a headset,
## so ONE build measures both arms of a before/after sweep. Two builds would
## have to be compared across two installs and two sessions, which is a worse
## measurement of a difference this size. Unlike vrsprobe.cfg this is NOT
## deleted as it is read: an adb-pushed file lands owned by `shell` and the app
## cannot remove it, so a self-deleting probe would log a failure every launch
## and stay wedged on anyway. Remove it over adb when the sweep is done.
static func active() -> bool:
	if OS.get_cmdline_user_args().has("--shell-unshaded"):
		return true
	if OS.get_name() != "Android":
		return false
	if FileAccess.file_exists(OFF_CFG):
		print("[ShellLighting] shellshaded.cfg present - staying on Godot lighting")
		return false
	return true


func _ready() -> void:
	if not active():
		set_process(false)
		return
	_room = get_node_or_null(room_path) as Node3D
	if _room == null:
		_room = get_parent() as Node3D
	if _room == null:
		set_process(false)
		return
	_load_bake()
	_convert()
	# Logged for the same reason QualityManager logs its resolved state: on a
	# headset the only evidence this path is live is the frame time, and a
	# measurement whose mechanism cannot be seen is not a measurement.
	print("[ShellLighting] %d shell material(s) unshaded in %s, bake %s"
		% [_materials.size(), _room.name,
			"'%s'" % gi_bake if not _volumes.is_empty() else "none"])
	if _materials.is_empty():
		set_process(false)
		return
	_retire_shell_lights()
	_refresh()


## The currently bound volume, for PropLighting to share.
##
## Handed out rather than reloaded so both readers hold the same textures - the
## volume is 400 KB and there is no reason for two copies of it on a headset.
## Empty when this room has no bake, which is PropLighting's signal to leave
## every prop on Godot's lighting.
func volume_for_props() -> Dictionary:
	if _volumes.is_empty():
		return {}
	var state := _gi_state if not _gi_state.is_empty() else _switch_state()
	var pair: Dictionary = _volumes[state]
	return {"irr": pair["irr"], "dir": pair["dir"], "min": _gi_min, "size": _gi_size}


## Turn off the lights the bake has replaced.
##
## `visible`, not `light_energy`: energy on several of these belongs to
## TimeOfDay and WindowBlinds, which go on writing it, and a value this node
## zeroed would be overwritten by its real owner a frame later.
func _retire_shell_lights() -> void:
	if _volumes.is_empty():
		return
	var retired := 0
	for node in _room.find_children("*", "Light3D", true, false):
		var light := node as Light3D
		if light.is_in_group(SHELL_ONLY_GROUP):
			light.visible = false
			retired += 1
	if retired > 0:
		print("[ShellLighting] retired %d shell-only light(s)" % retired)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < update_interval:
		return
	_elapsed = 0.0
	_refresh()


## Read the baked volumes off disk and rebuild them into 3D textures.
##
## They are stored as flat `Image` resources, dims.z slices of dims.y rows
## stacked into one tall image, because an ImageTexture3D drops its source
## images once uploaded and therefore cannot be serialised — ResourceSaver
## writes an empty texture and reports success. The grid's frame rides on the
## image as resource metadata.
func _load_bake() -> void:
	if gi_bake.is_empty():
		return
	var dims := Vector3i.ZERO
	for state in ["on", "off"]:
		var pair: Dictionary = {}
		for kind in ["irr", "dir"]:
			var path := "%s/%s_gi_%s_%s.res" % [BAKE_DIR, gi_bake, state, kind]
			if not ResourceLoader.exists(path):
				return
			var img: Image = load(path) as Image
			if img == null or not img.has_meta("gi_dims"):
				push_warning("[ShellLighting] %s is not a baked volume" % path)
				return
			dims = img.get_meta("gi_dims")
			_gi_min = img.get_meta("gi_min")
			_gi_size = img.get_meta("gi_size")
			pair[kind] = _volume(img, dims)
		_volumes[state] = pair


func _volume(img: Image, dims: Vector3i) -> ImageTexture3D:
	var slices: Array[Image] = []
	for z in dims.z:
		slices.append(img.get_region(Rect2i(0, z * dims.y, dims.x, dims.y)))
	var tex := ImageTexture3D.new()
	tex.create(img.get_format(), dims.x, dims.y, dims.z, false, slices)
	return tex


## Which baked state the room is in right now, from the wall switch.
func _switch_state() -> String:
	for node in _room.find_children("*", "Light3D", true, false):
		var light := node as Light3D
		if light.is_in_group(SWITCHED_GROUP) and light.is_visible_in_tree() 				and light.light_energy > 0.0:
			return "on"
	return "off"


## Find every shell material under the room and put it on the unshaded shader.
##
## A material is opted in by its own `shell` uniform rather than by a group on
## the meshes: the material is what the decision is about, and a room's shell is
## thirty-odd MeshInstance3D nodes sharing seven of them. A prop that happens to
## use the same shader — the table, the storage box — leaves `shell` false and
## keeps the real lighting, which is right: a prop is small on screen, so it was
## never part of the cost, and it wants the shadows.
func _convert() -> void:
	var seen: Dictionary = {}
	for node in _room.find_children("*", "GeometryInstance3D", true, false):
		var gi := node as GeometryInstance3D
		for mat in _materials_of(gi):
			var id := mat.get_instance_id()
			if seen.has(id):
				# Shared between meshes on different layers — take the union, so
				# a light reaching either one reaches the material.
				var at: int = seen[id]
				_layers[at] = _layers[at] | gi.layers
				_bounds[at] = _bounds[at].merge(_world_aabb(gi))
				continue
			if not _is_shell(mat):
				continue
			var unshaded: Shader = load(SHELL_SHADERS[mat.shader.resource_path])
			if unshaded == null:
				continue
			mat.shader = unshaded
			seen[id] = _materials.size()
			_materials.append(mat)
			_layers.append(gi.layers)
			_bounds.append(_world_aabb(gi))


func _world_aabb(gi: GeometryInstance3D) -> AABB:
	return gi.global_transform * gi.get_aabb()


func _materials_of(gi: GeometryInstance3D) -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	var over := gi.material_override as ShaderMaterial
	if over != null:
		out.append(over)
	var mi := gi as MeshInstance3D
	if mi == null or mi.mesh == null:
		return out
	for i in mi.mesh.get_surface_count():
		var mat := mi.get_surface_override_material(i) as ShaderMaterial
		if mat == null:
			mat = mi.mesh.surface_get_material(i) as ShaderMaterial
		if mat != null:
			out.append(mat)
	return out


func _is_shell(mat: ShaderMaterial) -> bool:
	if mat.shader == null or not SHELL_SHADERS.has(mat.shader.resource_path):
		return false
	return mat.get_shader_parameter("shell") == true


## Push the current lights into every shell material.
func _refresh() -> void:
	var lights := _gather()
	var env := _environment()
	var sky := Vector3(0.35, 0.33, 0.30)
	var energy := 1.0
	if env != null:
		var c := env.ambient_light_color.srgb_to_linear()
		sky = Vector3(c.r, c.g, c.b)
		energy = env.ambient_light_energy
	var ground := sky * ambient_floor_ratio
	var state := _switch_state() if not _volumes.is_empty() else ""
	var rebind := state != _gi_state
	if rebind and not state.is_empty():
		print("[ShellLighting] bake state -> %s" % state)
	_gi_state = state
	if rebind:
		bake_volume_changed.emit(volume_for_props())
	for i in _materials.size():
		var mat := _materials[i]
		mat.set_shader_parameter("ambient_sky", sky)
		mat.set_shader_parameter("ambient_ground", ground)
		mat.set_shader_parameter("ambient_energy", energy)
		# A material the bake covers takes the volume and skips the loop
		# entirely. One the bake does not reach - the street outside the window -
		# keeps the loop, so it still follows the time of day.
		var baked: bool = not state.is_empty() and _layers[i] & gi_layers != 0
		if rebind or not baked:
			mat.set_shader_parameter("use_gi", baked)
		if baked:
			if rebind:
				var pair: Dictionary = _volumes[state]
				mat.set_shader_parameter("gi_irr", pair["irr"])
				mat.set_shader_parameter("gi_dir", pair["dir"])
				mat.set_shader_parameter("gi_min", _gi_min)
				mat.set_shader_parameter("gi_size", _gi_size)
			continue
		_write(mat, _for_layer(lights, _layers[i], _bounds[i]))


## Never cached. WindowBlinds._ready() replaces WorldEnvironment.environment with
## a duplicate, so a reference taken once can be the copy that got discarded —
## the same trap time_of_day.gd documents.
func _environment() -> Environment:
	var node := get_node_or_null(world_env_path) as WorldEnvironment
	if node == null:
		var found := _room.find_children("*", "WorldEnvironment", true, false)
		if found.is_empty():
			return null
		node = found[0] as WorldEnvironment
	return node.environment if node != null else null


## Every light that is actually contributing. A hidden light, a light with no
## energy and a light whose whole subtree is hidden all read the same to a
## player, so all three are dropped here rather than written as a zero.
func _gather() -> Array[Light3D]:
	var out: Array[Light3D] = []
	for node in _room.find_children("*", "Light3D", true, false):
		var light := node as Light3D
		if not light.is_visible_in_tree() or light.light_energy <= 0.0:
			continue
		out.append(light)
	return out


## The MAX_LIGHTS lights that put the most light on this material.
##
## Ranked by how much energy ARRIVES, not by how much the light has: a
## positional light is scored at the nearest point of the material's own bounds,
## through the same falloff the shader will use, and a light whose range does
## not reach the bounds at all scores zero and is dropped. A directional keeps
## its energy wherever it is.
func _for_layer(lights: Array[Light3D], layers: int, bounds: AABB) -> Array[Light3D]:
	var reach: Array[Light3D] = []
	var score: Dictionary = {}
	for light in lights:
		if light.light_cull_mask & layers == 0:
			continue
		var s := _arriving(light, bounds)
		if s <= 0.0:
			continue
		score[light.get_instance_id()] = s
		reach.append(light)
	reach.sort_custom(func(a: Light3D, b: Light3D) -> bool:
		return score[a.get_instance_id()] > score[b.get_instance_id()])
	if reach.size() > MAX_LIGHTS:
		reach.resize(MAX_LIGHTS)
	return reach


## Energy arriving at the nearest point of `bounds`. Zero means out of range.
func _arriving(light: Light3D, bounds: AABB) -> float:
	if light is DirectionalLight3D:
		return light.light_energy
	var p := light.global_position
	var near := Vector3(
		clampf(p.x, bounds.position.x, bounds.end.x),
		clampf(p.y, bounds.position.y, bounds.end.y),
		clampf(p.z, bounds.position.z, bounds.end.z))
	var dist := p.distance_to(near)
	var spot := light as SpotLight3D
	var range_m: float = spot.spot_range if spot != null else (light as OmniLight3D).omni_range
	var falloff: float = spot.spot_attenuation if spot != null else (light as OmniLight3D).omni_attenuation
	if dist >= range_m:
		return 0.0
	# The same curve the shader uses, so the ranking agrees with the result.
	var nd := dist / range_m
	nd = nd * nd
	nd = nd * nd
	nd = maxf(1.0 - nd, 0.0)
	nd = nd * nd
	return light.light_energy * nd * pow(maxf(dist, 0.0001), -maxf(falloff, 0.0001))


func _write(mat: ShaderMaterial, lights: Array[Light3D]) -> void:
	var vecs := PackedVector4Array()
	var rgbe := PackedVector4Array()
	var axis := PackedVector4Array()
	var falloff := PackedVector4Array()
	for light in lights:
		var basis := light.global_transform.basis
		var origin := light.global_position
		if light is DirectionalLight3D:
			# A light points down its own -Z, so the direction TO it is +Z. The
			# w carries the negative that means "directional" to the shader.
			var to_light := basis.z.normalized()
			vecs.append(Vector4(to_light.x, to_light.y, to_light.z, -1.0))
			axis.append(Vector4(0.0, 0.0, 0.0, 2.0))
			# A directional reads neither, but the four arrays are indexed by the
			# same i — skipping one here shifts every later light onto the wrong
			# falloff and leaves the array a slot short.
			falloff.append(Vector4(1.0, 1.0, 0.0, 0.0))
		elif light is SpotLight3D:
			var spot := light as SpotLight3D
			var aim := -basis.z.normalized()
			vecs.append(Vector4(origin.x, origin.y, origin.z, spot.spot_range))
			axis.append(Vector4(aim.x, aim.y, aim.z, cos(deg_to_rad(spot.spot_angle))))
			falloff.append(Vector4(spot.spot_attenuation, spot.spot_angle_attenuation, 0.0, 0.0))
		else:
			var omni := light as OmniLight3D
			var range_m: float = omni.omni_range if omni != null else 1.0
			vecs.append(Vector4(origin.x, origin.y, origin.z, range_m))
			# Above 1.0, so no cone test can ever narrow an omni.
			axis.append(Vector4(0.0, 0.0, 0.0, 2.0))
			falloff.append(Vector4(
				omni.omni_attenuation if omni != null else 1.0, 1.0, 0.0, 0.0))
		# Linear, because a shader gets no sRGB conversion on a plain vec4 array —
		# `light_rgbe` cannot be `source_color`, it carries an energy in its alpha.
		# Skipping this washed every light out and was half of why the first run
		# read flat.
		var c := light.light_color.srgb_to_linear()
		rgbe.append(Vector4(c.r, c.g, c.b, light.light_energy))

	# The tail is written rather than left stale: `light_count` stops the shader
	# reading it, but a slot holding a light that was switched off an hour ago is
	# a trap for the next person to read a uniform dump.
	while vecs.size() < MAX_LIGHTS:
		vecs.append(Vector4(0.0, 0.0, 0.0, -1.0))
		rgbe.append(Vector4(0.0, 0.0, 0.0, 0.0))
		axis.append(Vector4(0.0, 0.0, 0.0, 2.0))
		falloff.append(Vector4(1.0, 1.0, 0.0, 0.0))

	mat.set_shader_parameter("light_count", lights.size())
	mat.set_shader_parameter("light_vec", vecs)
	mat.set_shader_parameter("light_rgbe", rgbe)
	mat.set_shader_parameter("light_axis", axis)
	mat.set_shader_parameter("light_falloff", falloff)

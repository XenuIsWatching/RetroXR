## Puts the room's PROPS on the same baked volume as its shell, on a headset.
##
## `ShellLighting` did the walls; this does the consoles, the sets and the
## furniture standing in front of them. Measured on a Quest 3 at eye buffer
## x1.75 with the shell already baked, the props' pipeline was 24% of the frame
## and substituting a constant colour for it took 21.6% off the whole frame —
## by then more than the shell was still worth.
##
## WHAT IT CONVERTS, and what it will not touch:
##   • StandardMaterial3D / ORMMaterial3D only. A ShaderMaterial is somebody's
##     authored effect — the CRT phosphor, the screen, the outline — and
##     replacing one would be replacing the thing it was written for.
##   • Opaque only. A transparent material's blending and sort order are load
##     bearing, and this shader does not reproduce them.
##   • Nothing on the exterior layer. The volume is fitted to the room's inside,
##     and the street is nowhere near it.
##   • Nothing under a ControllerArt. The controller the runtime draws is not a
##     prop, and that node owns its materials — see _in_controller_art.
##
## The prop's own albedo, normal and emission maps are carried across, so a
## console still looks like that console. What it gives up is per-light
## specular and shadow, neither of which the mobile backend was giving it.
class_name PropLighting
extends Node

const PROP_SHADER := "res://Shaders/pbr_prop_unshaded.gdshader"

## Room to convert. Empty means this node's parent.
@export var room_path: NodePath

## Render layers the baked volume covers — the interior.
@export_flags_3d_render var layers: int = 1

## ShellLighting in the same room, which owns the volume this borrows.
@export var shell_lighting_path: NodePath

var _converted: int = 0
var _room: Node3D
var _shader: Shader
var _volume: Dictionary = {}
# Weak values let despawning release materials and their textures immediately.
var _materials: Dictionary = {}
var _converted_meshes: Dictionary = {}
var _pending: Dictionary = {}
var _flush_queued := false


func _ready() -> void:
	if not ShellLighting.active():
		return
	var room := get_node_or_null(room_path) as Node3D
	if room == null:
		room = get_parent() as Node3D
	if room == null:
		return
	var shell := get_node_or_null(shell_lighting_path) as ShellLighting
	if shell == null:
		var found := room.find_children("*", "ShellLighting", true, false)
		if found.is_empty():
			return
		shell = found[0] as ShellLighting
	# Deferred: ShellLighting loads the volume in its own _ready, and node order
	# inside a scene is not something to depend on for this.
	await get_tree().process_frame
	var volume := shell.volume_for_props()
	if volume.is_empty():
		return
	var shader: Shader = load(PROP_SHADER)
	if shader == null:
		return
	_start(room, shader, volume)
	shell.bake_volume_changed.connect(_on_volume_changed)
	print("[PropLighting] %d prop material(s) on the bake in %s" % [_converted, room.name])


func _start(room: Node3D, shader: Shader, volume: Dictionary) -> void:
	_room = room
	_shader = shader
	_volume = volume
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	for node in room.find_children("*", "MeshInstance3D", true, false):
		_convert(node as MeshInstance3D)


func _on_node_added(node: Node) -> void:
	if node is MeshInstance3D and is_instance_valid(_room) and _room.is_ancestor_of(node):
		_pending[node.get_instance_id()] = weakref(node)
		if not _flush_queued:
			_flush_queued = true
			_flush_pending.call_deferred()


# node_added precedes _ready. Wait until model setup has installed its screen,
# LED and button overrides; async models are covered when their children arrive.
func _flush_pending() -> void:
	_flush_queued = false
	var pending := _pending
	_pending = {}
	for ref: WeakRef in pending.values():
		var mi := ref.get_ref() as MeshInstance3D
		if is_instance_valid(mi) and mi.is_inside_tree() and _room.is_ancestor_of(mi):
			_convert(mi)


func _on_node_removed(node: Node) -> void:
	var id := node.get_instance_id()
	_pending.erase(id)
	if not _converted_meshes.has(id):
		return
	_restore(id)
	# Removal is an event, not a per-frame scene traversal.
	for key in _materials.keys():
		if _materials[key].get_ref() == null:
			_materials.erase(key)


func _restore(id: int) -> void:
	if not _converted_meshes.has(id):
		return
	var record: Dictionary = _converted_meshes[id]
	var mi := (record["mesh"] as WeakRef).get_ref() as MeshInstance3D
	if is_instance_valid(mi) and mi.mesh != null:
		for surface: int in record["surfaces"]:
			if surface >= mi.mesh.get_surface_count():
				continue
			var mat := mi.get_surface_override_material(surface) as ShaderMaterial
			if mat != null and mat.shader == _shader:
				mi.set_surface_override_material(surface, null)
	_converted_meshes.erase(id)


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	if get_tree().node_removed.is_connected(_on_node_removed):
		get_tree().node_removed.disconnect(_on_node_removed)
	for id: int in _converted_meshes.keys():
		_restore(id)
	_pending.clear()
	_materials.clear()


## Follow the wall switch, so the machines darken with the walls.
func _on_volume_changed(volume: Dictionary) -> void:
	if volume.is_empty():
		return
	_volume = volume
	for id in _materials.keys():
		var mat := _materials[id].get_ref() as ShaderMaterial
		if mat == null:
			_materials.erase(id)
		else:
			_set_volume(mat, volume)


func _convert(mi: MeshInstance3D) -> void:
	if mi.layers & layers == 0:
		return
	if _in_controller_art(mi):
		return
	if mi.mesh == null or mi.material_override != null:
		return
	var surfaces: Array[int] = []
	for i in mi.mesh.get_surface_count():
		# Overrides belong to the object: its scripts may retain the material or
		# cast it back to StandardMaterial3D to update LEDs, screens and buttons.
		# Never replace an authored ShaderMaterial by falling back to its mesh.
		if mi.get_surface_override_material(i) != null:
			continue
		var src := mi.mesh.surface_get_material(i) as BaseMaterial3D
		if not _supported(src):
			continue
		var id := src.get_instance_id()
		var mat: ShaderMaterial = _materials[id].get_ref() if _materials.has(id) else null
		if mat == null:
			mat = _translate(src, _shader, _volume)
			_materials[id] = weakref(mat)
		mi.set_surface_override_material(i, mat)
		surfaces.append(i)
		_converted += 1
	if not surfaces.is_empty():
		var mesh_id := mi.get_instance_id()
		if _converted_meshes.has(mesh_id):
			_converted_meshes[mesh_id]["surfaces"].append_array(surfaces)
		else:
			_converted_meshes[mesh_id] = {"mesh": weakref(mi), "surfaces": surfaces}


# Leave features this shader cannot reproduce on their authored material. In
# particular, changing a pixel-art texture's filter would sacrifice sharpness.
func _supported(src: BaseMaterial3D) -> bool:
	return src != null and src.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
		and src.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL \
		and src.cull_mode == BaseMaterial3D.CULL_BACK and not src.no_depth_test \
		and src.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY \
		and src.texture_filter == BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS \
		and src.texture_repeat and not src.uv1_triplanar and not src.uv2_triplanar \
		and not src.vertex_color_use_as_albedo and not src.emission_enabled \
		and not src.grow and not src.proximity_fade_enabled \
		and src.distance_fade_mode == BaseMaterial3D.DISTANCE_FADE_DISABLED \
		and src.billboard_mode == BaseMaterial3D.BILLBOARD_DISABLED and src.next_pass == null


## One StandardMaterial3D, as the unshaded equivalent.
##
## Shared by instance id, so two props wearing the same source material end up
## wearing one replacement and can still batch — the same reason
## bedroom_exterior.gd caches its toned materials.
func _translate(src: BaseMaterial3D, shader: Shader, volume: Dictionary) -> ShaderMaterial:
	var out := ShaderMaterial.new()
	out.shader = shader
	out.render_priority = src.render_priority
	out.set_shader_parameter("uv1_scale", src.uv1_scale)
	out.set_shader_parameter("uv1_offset", src.uv1_offset)

	var albedo := src.albedo_texture
	out.set_shader_parameter("albedo_color", src.albedo_color)
	out.set_shader_parameter("has_albedo_tex", albedo != null)
	if albedo != null:
		out.set_shader_parameter("albedo_tex", albedo)

	var normal := src.normal_texture
	out.set_shader_parameter("has_normal_tex", normal != null and src.normal_enabled)
	if normal != null:
		out.set_shader_parameter("normal_tex", normal)
		out.set_shader_parameter("normal_scale", src.normal_scale)

	# Emission is the one thing that must survive verbatim: it is every power
	# LED, every lit dial and the glow inside a lamp shade, and an unshaded
	# shader that dropped it would turn the room's switched-on machines off.
	var emitting: bool = src.emission_enabled
	out.set_shader_parameter("emission_color",
		Vector3(src.emission.r, src.emission.g, src.emission.b) if emitting else Vector3.ZERO)
	out.set_shader_parameter("emission_energy", src.emission_energy_multiplier if emitting else 0.0)
	var emission_tex := src.emission_texture
	out.set_shader_parameter("has_emission_tex", emitting and emission_tex != null)
	if emission_tex != null:
		out.set_shader_parameter("emission_tex", emission_tex)

	_set_volume(out, volume)
	return out


func _set_volume(mat: ShaderMaterial, volume: Dictionary) -> void:
	mat.set_shader_parameter("gi_irr", volume["irr"])
	mat.set_shader_parameter("gi_dir", volume["dir"])
	mat.set_shader_parameter("gi_min", volume["min"])
	mat.set_shader_parameter("gi_size", volume["size"])


## The controller art the XR runtime hands over is not a prop, and converting it
## does lasting damage rather than costing a frame. ControllerArt duplicates
## those materials and writes `albedo_color.a` on them to fade the controller out
## of a grab. Conversion would leave a ShaderMaterial behind, which is not
## a BaseMaterial3D, so the fade can never write to it again to put it right.
##
## The room walk reaches it at all because the scene root is the room here, and
## because the runtime delivers the model asynchronously — measured on a Quest 3,
## it landed 354 ms before this walk, so the ordering is not reliably either way.
##
## Scoped to ControllerArt rather than to the whole rig on purpose: the hands and
## pointers hanging off XROrigin3D are shown and hidden outright, never faded, so
## they have no alpha to freeze and go on taking the room's light as before.
func _in_controller_art(node: Node) -> bool:
	var n: Node = node
	while n != null:
		if n is ControllerArt:
			return true
		n = n.get_parent()
	return false

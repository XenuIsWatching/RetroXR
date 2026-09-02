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
var _materials: Array[ShaderMaterial] = []


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
	var seen: Dictionary = {}
	for node in room.find_children("*", "GeometryInstance3D", true, false):
		_convert(node as GeometryInstance3D, shader, volume, seen)
	shell.bake_volume_changed.connect(_on_volume_changed)
	print("[PropLighting] %d prop material(s) on the bake in %s" % [_converted, room.name])


## Follow the wall switch, so the machines darken with the walls.
func _on_volume_changed(volume: Dictionary) -> void:
	if volume.is_empty():
		return
	for mat in _materials:
		mat.set_shader_parameter("gi_irr", volume["irr"])
		mat.set_shader_parameter("gi_dir", volume["dir"])


func _convert(gi: GeometryInstance3D, shader: Shader, volume: Dictionary,
		seen: Dictionary) -> void:
	if gi.layers & layers == 0:
		return
	if _in_controller_art(gi):
		return
	var mi := gi as MeshInstance3D
	if mi == null or mi.mesh == null:
		return
	for i in mi.mesh.get_surface_count():
		var src := mi.get_surface_override_material(i) as BaseMaterial3D
		if src == null:
			src = mi.mesh.surface_get_material(i) as BaseMaterial3D
		if src == null:
			continue
		if src.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			continue
		var id := src.get_instance_id()
		if not seen.has(id):
			seen[id] = _translate(src, shader, volume)
			_materials.append(seen[id])
		mi.set_surface_override_material(i, seen[id])
		_converted += 1


## One StandardMaterial3D, as the unshaded equivalent.
##
## Shared by instance id, so two props wearing the same source material end up
## wearing one replacement and can still batch — the same reason
## bedroom_exterior.gd caches its toned materials.
func _translate(src: BaseMaterial3D, shader: Shader, volume: Dictionary) -> ShaderMaterial:
	var out := ShaderMaterial.new()
	out.shader = shader
	out.render_priority = src.render_priority

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

	out.set_shader_parameter("gi_irr", volume["irr"])
	out.set_shader_parameter("gi_dir", volume["dir"])
	out.set_shader_parameter("gi_min", volume["min"])
	out.set_shader_parameter("gi_size", volume["size"])
	return out


## The controller art the XR runtime hands over is not a prop, and converting it
## does lasting damage rather than costing a frame. ControllerArt duplicates
## those materials and writes `albedo_color.a` on them to fade the controller out
## of a grab; this shader resolves ALPHA from a COPY of albedo_color taken at
## conversion, so a walk that lands mid-fade freezes the controller translucent
## for the rest of the session — and leaves a ShaderMaterial behind, which is not
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

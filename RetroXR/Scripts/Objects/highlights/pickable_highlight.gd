## PickableHighlight — add as a child of any XRToolsPickable.
## Automatically builds outline overlay meshes for every MeshInstance3D direct-child
## of the parent and manages four visual states:
##   - Ray hovering  → white   (highlight_updated signal on parent pickable)
##   - Ray held      → yellow  (XRTools ray-grab, plus desktop_hand pickup)
##   - Hand held     → blue    (picked_up / dropped signals on parent pickable, XR hand-grab path)
##   - In trash      → red     (set_trash_mode(true) called by StorageBox — highest priority)
##
## Why the two separate paths: godot-xr-tools ray-grab bypasses the pickable's
## picked_up/grabbed signals entirely and only emits has_picked_up on the pickup
## function node. Hand-grab emits picked_up/dropped on the pickable as normal.
##
## Uses a stencil-masked inverted-hull outline (Godot 4.4+ stencil, two passes
## chained via next_pass on a single overlay mesh per source):
##   1. outline_mask.gdshader (priority 1) invisibly stamps the object's screen
##      footprint into the stencil buffer, ignoring depth.
##   2. outline.gdshader (priority 2) draws the normal-inflated hull with depth
##      testing disabled where the stencil is NOT set — the rim outside the
##      footprint. The outline therefore shows through occluders (x-ray) and is
##      never clipped by geometry resting near the object.
## Multiple overlays on complex objects (e.g. NES with 25 sub-meshes) compose
## correctly: all masks stamp the union footprint before any outline draws.
##
## Overlays use a smoothed-normal copy of each source mesh (cached per mesh) so
## hard edges don't tear the inflated hull open at corners.
class_name PickableHighlight
extends Node3D

const OUTLINE_SHADER := preload("res://Shaders/outline.gdshader")
const OUTLINE_MASK_SHADER := preload("res://Shaders/outline_mask.gdshader")

## Color shown while the pointer ray is hovering over the object.
@export var hover_color: Color = Color(1.0, 1.0, 1.0, 1.0)
## Color shown while the object is held by the ray (ranged grab).
@export var ray_color:   Color = Color(1.0, 0.85, 0.0, 1.0)
## Color shown while the object is held by a physical hand grab.
@export var held_color:  Color = Color(0.25, 0.6, 1.0, 1.0)
## Color shown while the object is inside a StorageBox detection area (overrides held colour).
@export var trash_color: Color = Color(1.0, 0.15, 0.15, 1.0)
## Color shown while a held TV remote is pointing at the object.
@export var remote_color: Color = Color(0.5, 0.0, 0.13, 1.0)
## Color shown while the held object is snapping onto a socket (about to slot in).
@export var snap_preview_color: Color = Color(1.0, 0.5, 0.0, 1.0)

@export_range(0.0, 8.0, 0.1)  var outline_width: float = 1.0
@export_range(0.0, 8.0, 0.1)  var glow_strength: float = 2.0
@export_range(0.0, 10.0, 0.1) var fade_start: float = 0.0
@export_range(0.1, 50.0, 0.1) var fade_end: float = 10.0

var _overlays: Array[MeshInstance3D] = []
var _overlay_sources: Array[MeshInstance3D] = []  # parallel to _overlays
var _outline_material: ShaderMaterial = null      # shared — all overlays use the same instance
var _mask_material: ShaderMaterial = null         # stencil footprint pass, next_pass = outline

# Smoothed-normal outline meshes, keyed by source mesh RID. Static so identical
# meshes across many pickables (e.g. spawned cartridges) share one copy.
static var _outline_mesh_cache: Dictionary = {}

var _is_highlighted:   bool = false
var _is_ray_held:      bool = false
var _is_hand_held:     bool = false
var _is_in_trash:      bool = false
var _is_remote_target: bool = false
var _is_snap_preview:  bool = false
var _ray_grabber:      Node = null


func _ready() -> void:
	set_process(false)

	_outline_material = ShaderMaterial.new()
	_outline_material.shader = OUTLINE_SHADER
	_outline_material.render_priority = 2

	_mask_material = ShaderMaterial.new()
	_mask_material.shader = OUTLINE_MASK_SHADER
	_mask_material.render_priority = 1
	_mask_material.next_pass = _outline_material
	_sync_material_params()

	var parent := get_parent()
	if parent and parent.has_signal("highlight_updated"):
		parent.highlight_updated.connect(_on_highlight_updated)
	else:
		push_warning("PickableHighlight: parent has no highlight_updated signal")
		return

	if parent.has_signal("grabbed"):
		parent.grabbed.connect(_on_grabbed)
	if parent.has_signal("dropped"):
		parent.dropped.connect(_on_hand_dropped)

	_connect_pickup_nodes.call_deferred()
	rebuild_overlays.call_deferred()


## Rebuild overlays from scratch — call this after the parent's meshes change.
func rebuild_overlays() -> void:
	for overlay in _overlays:
		if is_instance_valid(overlay):
			overlay.queue_free()
	_overlays.clear()
	_overlay_sources.clear()

	var parent := get_parent()
	if parent:
		_collect_overlays(parent)


func _collect_overlays(node: Node) -> void:
	var parent_inv := (get_parent() as Node3D).global_transform.affine_inverse()
	for child in node.get_children():
		if child == self:
			continue
		if child is MeshInstance3D and not child.is_in_group("outline_exclude"):
			var src := child as MeshInstance3D
			var overlay := MeshInstance3D.new()
			overlay.mesh = _get_outline_mesh(src.mesh)
			overlay.transform = parent_inv * src.global_transform
			overlay.material_override = _mask_material
			overlay.visible = false
			overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			overlay.extra_cull_margin = 16.0
			add_child(overlay)
			_overlays.append(overlay)
			_overlay_sources.append(src)
		_collect_overlays(child)


func _connect_pickup_nodes() -> void:
	for node in get_tree().root.find_children("*", "XRToolsFunctionPickup", true, false):
		node.has_picked_up.connect(_on_ray_picked_up.bind(node))
		node.has_dropped.connect(_on_ray_dropped.bind(node))


# --- Signal handlers ---

func _on_highlight_updated(_object: Node, highlighted: bool) -> void:
	_is_highlighted = highlighted
	_update_state()


func _on_grabbed(_pickable, by: Node) -> void:
	if by is XRToolsFunctionPickup:
		_is_hand_held = true
	elif by.is_in_group("desktop_hand"):
		_is_ray_held = true
		_ray_grabber = by
	_update_state()


func _on_hand_dropped(_pickable) -> void:
	_is_hand_held = false
	if is_instance_valid(_ray_grabber) and _ray_grabber.is_in_group("desktop_hand"):
		_is_ray_held = false
		_ray_grabber = null
	_update_state()


func _on_ray_picked_up(what: Node3D, pickup: Node) -> void:
	if what != get_parent():
		return
	_is_ray_held = true
	_ray_grabber = pickup
	_update_state()


func _on_ray_dropped(pickup: Node) -> void:
	if pickup != _ray_grabber:
		return
	_is_ray_held = false
	_ray_grabber = null
	_update_state()


# --- State machine ---

func _update_state() -> void:
	if _is_in_trash:
		_set_color(trash_color)
		_set_overlays_visible(true)
	elif _is_snap_preview:
		_set_color(snap_preview_color)
		_set_overlays_visible(true)
	elif _is_remote_target:
		_set_color(remote_color)
		_set_overlays_visible(true)
	elif _is_hand_held:
		_set_color(held_color)
		_set_overlays_visible(true)
	elif _is_ray_held:
		_set_color(ray_color)
		_set_overlays_visible(true)
	elif _is_highlighted:
		_set_color(hover_color)
		_set_overlays_visible(true)
	else:
		_set_overlays_visible(false)


## Called by StorageBox when this object enters or exits the trash detection area.
func set_trash_mode(in_trash: bool) -> void:
	_is_in_trash = in_trash
	_update_state()


## Called by the grab driver while the held object is snapping onto a socket
## (cartridge/disc/plug hovering in a slot's range) — turns the outline orange.
func set_snap_preview(on: bool) -> void:
	if _is_snap_preview == on:
		return
	_is_snap_preview = on
	_update_state()


## Called by a held TVRemote when it starts/stops pointing at this object.
func set_remote_target(active: bool) -> void:
	_is_remote_target = active
	_update_state()


func _set_overlays_visible(shown: bool) -> void:
	set_process(shown)
	var parent_inv := (get_parent() as Node3D).global_transform.affine_inverse()
	for i in range(_overlays.size()):
		var overlay := _overlays[i]
		if not is_instance_valid(overlay):
			continue
		if shown and i < _overlay_sources.size() and is_instance_valid(_overlay_sources[i]):
			var src := _overlay_sources[i]
			var was_hidden := not overlay.visible
			overlay.transform = parent_inv * src.global_transform
			if was_hidden:
				# _process is off while hidden, so this offset has been frozen since
				# the last time the outline was up — and a source that moved in the
				# meantime (a TV re-seats every bezel button, speaker and port the
				# moment its shell model lands) leaves it pointing somewhere else.
				# Correcting it here is not enough on its own: physics interpolation
				# then spends the first frame sliding the overlay in from the stale
				# pose, which is the frame the player sees.
				overlay.reset_physics_interpolation()
			overlay.visible = src.is_visible_in_tree()
		else:
			overlay.visible = false


func _process(_delta: float) -> void:
	var parent_inv := (get_parent() as Node3D).global_transform.affine_inverse()
	for i in range(mini(_overlays.size(), _overlay_sources.size())):
		var overlay := _overlays[i]
		var src := _overlay_sources[i]
		if is_instance_valid(overlay) and is_instance_valid(src):
			var outline_mesh := _get_outline_mesh(src.mesh)
			if overlay.mesh != outline_mesh:
				overlay.mesh = outline_mesh
			overlay.transform = parent_inv * src.global_transform
			overlay.visible = src.is_visible_in_tree()


func _set_color(color: Color) -> void:
	if _outline_material:
		_outline_material.set_shader_parameter("outline_color", color)


func _sync_material_params() -> void:
	if not _outline_material:
		return
	_outline_material.set_shader_parameter("outline_color", hover_color)
	_outline_material.set_shader_parameter("outline_width", outline_width)
	_outline_material.set_shader_parameter("glow_strength", glow_strength)
	_outline_material.set_shader_parameter("fade_start", fade_start)
	_outline_material.set_shader_parameter("fade_end", fade_end)


# --- Outline mesh construction ---

static func _get_outline_mesh(src_mesh: Mesh) -> Mesh:
	if src_mesh == null:
		return null
	var key: RID = src_mesh.get_rid()
	var cached: Mesh = _outline_mesh_cache.get(key)
	if cached:
		return cached
	var smoothed := _build_smoothed_mesh(src_mesh)
	_outline_mesh_cache[key] = smoothed
	return smoothed


## Copy of src_mesh with normals averaged across vertices that share a position.
## Hard edges duplicate vertices with diverging face normals; inflating along
## those tears the hull open at corners, so the outline copy needs them merged.
static func _build_smoothed_mesh(src_mesh: Mesh) -> Mesh:
	var snap := Vector3(1e-4, 1e-4, 1e-4)
	var accum: Dictionary = {}
	var all_arrays: Array = []

	for s in src_mesh.get_surface_count():
		var arrays := src_mesh.surface_get_arrays(s)
		all_arrays.append(arrays)
		var normals_v = arrays[Mesh.ARRAY_NORMAL]
		if normals_v == null:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = normals_v
		for i in verts.size():
			var k := verts[i].snapped(snap)
			accum[k] = accum.get(k, Vector3.ZERO) + normals[i]

	var out := ArrayMesh.new()
	for s in src_mesh.get_surface_count():
		var arrays: Array = all_arrays[s]
		var normals_v = arrays[Mesh.ARRAY_NORMAL]
		if normals_v != null:
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = normals_v
			var smoothed := PackedVector3Array()
			smoothed.resize(verts.size())
			for i in verts.size():
				var n: Vector3 = accum[verts[i].snapped(snap)]
				smoothed[i] = n.normalized() if n.length_squared() > 1e-12 else normals[i]
			arrays[Mesh.ARRAY_NORMAL] = smoothed
		# surface_get_primitive_type is only exposed on ArrayMesh; PrimitiveMesh
		# surfaces are always triangles.
		var primitive := Mesh.PRIMITIVE_TRIANGLES
		if src_mesh is ArrayMesh:
			primitive = (src_mesh as ArrayMesh).surface_get_primitive_type(s)
		out.add_surface_from_arrays(primitive, arrays)
	return out

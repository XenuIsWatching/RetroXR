## A strand of string lights threaded along a path.
##
## Built rather than downloaded. Sketchfab's CC0/CC-BY pool has essentially one
## usable strand and it is modelled dead straight, which is no good for either of
## the ways this room uses them — a rigid mesh cannot be run round a window casing
## or bordered along a poster frame.
##
## `path` is a polyline in local space, so one node covers every case: two points
## make a hanging swag, four with `closed` make a frame. Each run droops by `sag`
## at its midpoint. A real hanging wire is a catenary; over these spans, with this
## little droop, a parabola is indistinguishable and much cheaper.
##
## Two draw calls per strand whatever the bulb count — bulbs are one MultiMesh,
## wire segments another. Draw calls are the binding constraint on Quest, not
## triangles, so that matters more than the tri count does.
##
## Bulbs are EMISSIVE, not lights. Thirty OmniLights is unthinkable on the mobile
## backend and is not needed: the room's Environment has glow enabled, so emissive
## bulbs bloom on their own. One optional dim Omni gives the wall wash that
## emission alone cannot.
@tool
class_name StringLights
extends Node3D


## Polyline the strand follows, in this node's local space. Needs 2+ points.
@export var path: PackedVector3Array = []:
	set(v): path = v; _rebuild()

## Join the last point back to the first, for a frame.
@export var closed: bool = false:
	set(v): closed = v; _rebuild()

## Droop at the middle of each run, in metres. Small values (0.02–0.05) read as
## a strand pinned along a frame; large ones (0.15+) as a swag hung between two
## points.
@export var sag: float = 0.03:
	set(v): sag = v; _rebuild()

## Bulbs per metre of run, so spacing stays even whatever the path length.
@export var bulbs_per_metre: float = 9.0:
	set(v): bulbs_per_metre = maxf(0.5, v); _rebuild()

@export var bulb_radius: float = 0.014:
	set(v): bulb_radius = v; _rebuild()
@export var wire_radius: float = 0.002:
	set(v): wire_radius = v; _rebuild()

@export var bulb_color: Color = Color(1.0, 0.84, 0.56):
	set(v): bulb_color = v; _rebuild()
@export var emission_energy: float = 3.4:
	set(v): emission_energy = v; _rebuild()

## Cycle bulbs through these instead of one colour. Empty means single-colour.
@export var multicolour: PackedColorArray = []:
	set(v): multicolour = v; _rebuild()

## A single dim unshadowed Omni at the path's centroid, for the wash on the
## surface behind. Joins "no_shadow": a shadow-caster sitting inside its own bulb
## geometry would carve the strand's silhouette into the wall.
@export var wash_light: bool = true:
	set(v): wash_light = v; _rebuild()
@export var wash_energy: float = 0.30:
	set(v): wash_energy = v; _rebuild()
@export var wash_range: float = 2.4:
	set(v): wash_range = v; _rebuild()

## Strand on/off. A plain assignment rather than a rebuild: the strand is two
## MultiMeshes and an Omni, and turning it off changes exactly two numbers on them.
## The wall switch drives this every press, so a rebuild here would free and
## re-create both MultiMeshes on a hand movement.
@export var lit: bool = true:
	set(v): lit = v; _apply_lit()


func _ready() -> void:
	_rebuild()


## The switch's entry point, and the one object_sync/_apply_lit round trip. Named to
## match GlowMesh.set_lit(), which the same switch calls on the ceiling fixture.
func set_lit(on: bool) -> void:
	lit = on


## Push `lit` onto the already-built children. A no-op before the first _rebuild()
## — this is a @tool script and a setter can fire before the children exist.
##
## Writing light_energy is safe HERE and would not be on the ceiling fixture:
## QualityManager._adjust_lights() owns the energy of everything in the
## "ceiling_light" group and rewrites it per quality tier, and the wash Omni is
## deliberately not in that group.
func _apply_lit() -> void:
	var bulbs := get_node_or_null("Bulbs") as MultiMeshInstance3D
	if bulbs != null:
		var mat := bulbs.material_override as StandardMaterial3D
		if mat != null:
			mat.emission_energy_multiplier = emission_energy if lit else 0.0
	var wash := get_node_or_null("Wash") as OmniLight3D
	if wash != null:
		wash.light_energy = wash_energy if lit else 0.0


## Set the strand to trace a rectangle in a plane, which is how both of this
## room's strands are placed. `axis` is the plane normal: 0 = X (side walls),
## 2 = Z (end walls).
func set_rect(centre: Vector3, width: float, height: float, axis: int) -> void:
	var u := Vector3(0, 0, 1) if axis == 0 else Vector3(1, 0, 0)
	var v := Vector3(0, 1, 0)
	var hw: Vector3 = u * (width * 0.5)
	var hh: Vector3 = v * (height * 0.5)
	closed = true
	path = PackedVector3Array([
		centre - hw + hh, centre + hw + hh,
		centre + hw - hh, centre - hw - hh,
	])


func _runs() -> Array:
	var out: Array = []
	if path.size() < 2:
		return out
	for i in path.size() - 1:
		out.append([path[i], path[i + 1]])
	if closed and path.size() > 2:
		out.append([path[path.size() - 1], path[0]])
	return out


## Bulb positions, evenly spaced along every run, with each run's midpoint droop.
func _bulbs() -> PackedVector3Array:
	var pts: PackedVector3Array = []
	for run in _runs():
		var a: Vector3 = run[0]
		var b: Vector3 = run[1]
		var n: int = maxi(2, int(round(a.distance_to(b) * bulbs_per_metre)))
		# Skip the last point of each run: the next run starts there, so emitting
		# both would double a bulb at every corner.
		for i in n:
			var t: float = float(i) / float(n)
			var p: Vector3 = a.lerp(b, t)
			p.y -= sag * 4.0 * t * (1.0 - t)
			pts.append(p)
	if not closed and not path.is_empty():
		pts.append(path[path.size() - 1])
	return pts


func _rebuild() -> void:
	if not is_inside_tree():
		return
	for child in get_children():
		child.queue_free()
	var pts := _bulbs()
	if pts.size() < 2:
		return
	_build_bulbs(pts)
	_build_wire(pts)
	if wash_light:
		_build_wash(pts)


func _build_bulbs(pts: PackedVector3Array) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = bulb_radius
	sphere.height = bulb_radius * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not multicolour.is_empty()
	mm.mesh = sphere
	mm.instance_count = pts.size()
	for i in pts.size():
		mm.set_instance_transform(i, Transform3D(Basis(), pts[i]))
		if mm.use_colors:
			mm.set_instance_color(i, multicolour[i % multicolour.size()])

	var mat := StandardMaterial3D.new()
	mat.albedo_color = bulb_color if multicolour.is_empty() else Color.WHITE
	mat.emission_enabled = true
	mat.emission = bulb_color if multicolour.is_empty() else Color.WHITE
	mat.emission_energy_multiplier = emission_energy if lit else 0.0
	if mm.use_colors:
		# Emission does not read instance colour by itself; route it through
		# albedo and multiply the emission by it.
		mat.vertex_color_use_as_albedo = true
		mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Bulbs"
	mmi.multimesh = mm
	mmi.material_override = mat
	add_child(mmi)


func _build_wire(pts: PackedVector3Array) -> void:
	var seg := CylinderMesh.new()
	seg.top_radius = wire_radius
	seg.bottom_radius = wire_radius
	seg.height = 1.0
	seg.radial_segments = 4
	seg.rings = 0

	var count: int = pts.size() if closed else pts.size() - 1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = seg
	mm.instance_count = count
	for i in count:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[(i + 1) % pts.size()]
		var dir: Vector3 = b - a
		var length: float = dir.length()
		if length <= 0.0:
			mm.set_instance_transform(i, Transform3D(Basis(), a))
			continue
		# The cylinder's own axis is Y, so build a basis whose Y runs along the
		# segment; any perpendicular serves for the other two.
		var y: Vector3 = dir / length
		var ref := Vector3.RIGHT if absf(y.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
		var x: Vector3 = ref.cross(y).normalized()
		var z: Vector3 = x.cross(y)
		mm.set_instance_transform(i, Transform3D(Basis(x, y * length, z), (a + b) * 0.5))

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.09, 0.09, 0.1)
	mat.roughness = 0.7

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Wire"
	mmi.multimesh = mm
	mmi.material_override = mat
	add_child(mmi)


func _build_wash(pts: PackedVector3Array) -> void:
	var centroid := Vector3.ZERO
	for p in pts:
		centroid += p
	centroid /= float(pts.size())

	var light := OmniLight3D.new()
	light.name = "Wash"
	light.position = centroid
	light.light_color = bulb_color
	light.light_energy = wash_energy if lit else 0.0
	light.omni_range = wash_range
	light.light_cull_mask = 1
	light.add_to_group("no_shadow")
	add_child(light)

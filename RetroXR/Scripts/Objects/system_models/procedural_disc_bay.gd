## ProceduralDiscBay — the disc mechanism drawn on the placeholder box.
##
## Every dimension in here is a measurement of that box: it is 0.3 x 0.1 x 0.25,
## so its top is y = 0.05 and its front face z = 0.125, and the pod, the shelf and
## the slit are all placed against those numbers. That is what makes this the
## DEFAULT model's geometry rather than the cabinet's — a bespoke shell brings its
## own mechanism and its own measurements, and RetroSystemModel.build_disc_bay
## returns null for it.
##
## Three shapes, by what the platform loads through:
##   tray  — a raised pod with a recessed well and a spring-latched lid
##   front — a bay mouth with a shelf that slides out through it
##   slot  — a dark slit in the front face, no moving part at all
class_name ProceduralDiscBay
extends RefCounted

## How far the spring lid stands up when the latch releases.
const LID_OPEN_DEG := 75.0
## Depth of the recessed well the disc drops into.
const WELL_DEPTH := 0.006
## How far the front-loading shelf runs out, and how long it takes.
const SLIDE_TRAVEL := 0.19
const SLIDE_TIME := 0.9

## The placeholder console box every measurement in here was taken from. Passed
## as `box` by default so the consoles are unchanged; an expansion unit is a
## different size and hands its own in, which is the only reason this is a
## parameter at all.
const PLACEHOLDER_BOX := Vector3(0.30, 0.10, 0.25)

## The spring lid, on a hinged tray. Null on a front-loader and a slot.
var lid_hinge: VRSpringLatchedHinge = null
## The moving shelf, on a front-loader. Null on a hinged tray and a slot.
var slide_pivot: Node3D = null

var _host: Node3D = null
var _slide_rest := Vector3.ZERO
var _slide_tween: Tween = null


## Build the tray mechanism on `host` and seat `slot` on it. `front` picks the
## sliding shelf over the hinged pod; `on_lid_swung` is told when a hand pushes
## the lid home.
static func build_tray(host: Node3D, slot: Node3D, systemid: String, front: bool,
		on_lid_swung: Callable, box: Vector3 = PLACEHOLDER_BOX) -> ProceduralDiscBay:
	var bay := ProceduralDiscBay.new()
	bay._host = host
	if front:
		bay._build_front_tray(slot, systemid, box)
	else:
		bay._build_lid_tray(slot, systemid, on_lid_swung)
	return bay


## Dark slit on the front face where slot-loaded discs go in. Nothing moves, so
## there is no bay to keep.
static func build_slit(host: Node3D, systemid: String) -> void:
	var d := MediaDimensions.disc_diameter(systemid)
	var slit := MeshInstance3D.new()
	slit.name = "DiscSlit"
	var slit_mesh := BoxMesh.new()
	slit_mesh.size = Vector3(d + 0.008, 0.007, 0.003)
	slit.mesh = slit_mesh
	var slit_mat := StandardMaterial3D.new()
	slit_mat.albedo_color = Color(0.08, 0.08, 0.1)
	slit.set_surface_override_material(0, slit_mat)
	slit.position = Vector3(0, 0.03, 0.1255)
	host.add_child(slit)


## Run the front-sliding shelf out of the bay and back. No-op on a hinged lid,
## which MediaTray swings instead. Eased rather than linear — a real tray coasts
## out and thumps home (same motion as RetroSystemModelPCTower._slide_to).
func slide(open: bool) -> void:
	if slide_pivot == null:
		return
	if _slide_tween != null and _slide_tween.is_valid():
		_slide_tween.kill()
	var target: Vector3 = _slide_rest
	if open:
		target += Vector3(0.0, 0.0, SLIDE_TRAVEL)
	_slide_tween = _host.create_tween()
	_slide_tween.tween_property(slide_pivot, "position", target, SLIDE_TIME) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## The front-loading shelf: a bay mouth in the front face and a tray that carries
## the disc out through it. The placeholder box is 0.3 x 0.1 x 0.25, so the front
## face is z = 0.125 and the shelf hides inside at rest.
func _build_front_tray(slot: Node3D, systemid: String, box: Vector3 = PLACEHOLDER_BOX) -> void:
	var d := MediaDimensions.disc_diameter(systemid)
	# Up the front face, not centred on it: the box carries its nameplate across the
	# middle and the shelf slid straight through the lettering. Kept as a fraction
	# of the box's height so a shallower machine -- a Mega-CD is 80 mm where the
	# placeholder console is 100 -- puts its tray at the same place on its face
	# rather than off the top of it. 0.24 reproduces the console's 0.024 exactly.
	var deck_y := box.y * 0.24
	var front_z := box.z * 0.5 + 0.0005

	var bay_mat := StandardMaterial3D.new()
	bay_mat.albedo_color = Color(0.08, 0.08, 0.1)
	var shelf_mat := StandardMaterial3D.new()
	shelf_mat.albedo_color = Color(0.16, 0.16, 0.18)
	var well_mat := StandardMaterial3D.new()
	well_mat.albedo_color = Color(0.10, 0.10, 0.12)

	# Bay mouth on the front face, the slot the shelf emerges from.
	var bay := MeshInstance3D.new()
	bay.name = "DiscBayMouth"
	var bay_mesh := BoxMesh.new()
	bay_mesh.size = Vector3(d + 0.020, 0.010, 0.003)
	bay.mesh = bay_mesh
	bay.set_surface_override_material(0, bay_mat)
	bay.position = Vector3(0, deck_y, front_z)
	_host.add_child(bay)

	slide_pivot = Node3D.new()
	slide_pivot.name = "DiscTraySlide"
	slide_pivot.position = Vector3(0, deck_y, 0.010)
	_host.add_child(slide_pivot)
	_slide_rest = slide_pivot.position

	var shelf := MeshInstance3D.new()
	shelf.name = "DiscTrayShelf"
	var shelf_mesh := BoxMesh.new()
	shelf_mesh.size = Vector3(d + 0.014, 0.005, d + 0.018)
	shelf.mesh = shelf_mesh
	shelf.set_surface_override_material(0, shelf_mat)
	shelf.position = Vector3(0, -0.004, 0)
	slide_pivot.add_child(shelf)

	# Recessed well the disc lies in, plus the hub it centres on.
	var well := MeshInstance3D.new()
	well.name = "DiscTrayWell"
	var well_mesh := CylinderMesh.new()
	well_mesh.top_radius = d / 2.0 + 0.004
	well_mesh.bottom_radius = d / 2.0 + 0.004
	well_mesh.height = 0.003
	well.mesh = well_mesh
	well.set_surface_override_material(0, well_mat)
	well.position = Vector3(0, -0.0005, 0)
	slide_pivot.add_child(well)

	var spindle := MeshInstance3D.new()
	spindle.name = "DiscTraySpindle"
	var spindle_mesh := CylinderMesh.new()
	spindle_mesh.top_radius = 0.0075
	spindle_mesh.bottom_radius = 0.0075
	spindle_mesh.height = 0.004
	spindle.mesh = spindle_mesh
	spindle.set_surface_override_material(0, shelf_mat)
	spindle.position = Vector3(0, 0.0015, 0)
	slide_pivot.add_child(spindle)

	# Seat the snap zone on the well. MediaTray re-expresses this relative to the
	# shelf, so it must be set with the tray at REST — which it is.
	slot.position = _slide_rest + Vector3(0, 0.0025, 0)
	var visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if visual != null:
		visual.visible = false


## The physical disc well + hinged lid: a raised pod bridging the box top
## (y=0.05) up to the seated-disc height (y=0.07), a dark recessed bed the disc
## rests in, and a lid hinged at the pod's back edge. The lid doubles as a touch
## button — physically pushing an open lid shuts it (same replicated path as the
## OPEN button).
func _build_lid_tray(slot: Node3D, systemid: String, on_lid_swung: Callable) -> void:
	var d := MediaDimensions.disc_diameter(systemid)
	var pod_r := d / 2.0 + 0.024
	var lid_r := d / 2.0 + 0.028

	var pod_mat := StandardMaterial3D.new()
	pod_mat.albedo_color = Color(0.45, 0.45, 0.48)
	var bed_mat := StandardMaterial3D.new()
	bed_mat.albedo_color = Color(0.10, 0.10, 0.12)
	var lid_mat := StandardMaterial3D.new()
	lid_mat.albedo_color = Color(0.55, 0.55, 0.58)

	# The well the disc drops into: mouth at the pod's top face, floor
	# WELL_DEPTH below it, 6 mm of clearance round the disc's edge.
	var well_r := d / 2.0 + 0.006
	var rim_y := 0.0667
	var floor_y := rim_y - WELL_DEPTH

	# Raised pod, open-topped: its top cap would roof the well over, so the ring
	# between the well and the pod's edge is a separate rim face.
	var pod := MeshInstance3D.new()
	pod.name = "DiscTrayPod"
	var pod_mesh := CylinderMesh.new()
	pod_mesh.top_radius = pod_r
	pod_mesh.bottom_radius = pod_r
	pod_mesh.height = 0.0167
	pod_mesh.cap_top = false
	pod.mesh = pod_mesh
	pod.set_surface_override_material(0, pod_mat)
	pod.position = Vector3(0, 0.05 + 0.0167 / 2.0, 0)   # top at rim_y
	_host.add_child(pod)

	var rim := MeshInstance3D.new()
	rim.name = "DiscTrayRim"
	rim.mesh = _ring_mesh(well_r, pod_r)
	rim.set_surface_override_material(0, pod_mat)
	rim.position = Vector3(0, rim_y, 0)
	_host.add_child(rim)

	# Floor and side wall of the well, one dark surface. Depth alone would not read
	# as a recess — the rooms light with a flat ambient colour and no occlusion, so
	# the inside of a hole is lit exactly as brightly as its mouth.
	var well := MeshInstance3D.new()
	well.name = "DiscTrayWell"
	well.mesh = _well_mesh(well_r, WELL_DEPTH)
	well.set_surface_override_material(0, bed_mat)
	well.position = Vector3(0, floor_y, 0)
	_host.add_child(well)

	# Seat the snap zone on the well floor, as the front-tray build does on its
	# shelf. MediaTray seats the disc at the zone origin (seat_offset is only
	# re-expressed for a disc that rides a moving pivot), so the zone's own height
	# IS the disc's: left at the cabinet default it sits inside the pod.
	slot.position = Vector3(0, floor_y + 0.0005 + 0.00125, 0)

	# Spring-loaded lid, as on the hardware: OPEN is a latch release that pops it
	# up, and it is pushed back down by hand until it clicks. mount() hinges it on
	# the lid's own back-bottom edge, so placing the mesh is what sets the hinge.
	var lid := MeshInstance3D.new()
	lid.name = "DiscTrayLid"
	var lid_mesh := CylinderMesh.new()
	lid_mesh.top_radius = lid_r
	lid_mesh.bottom_radius = lid_r
	lid_mesh.height = 0.005
	lid.mesh = lid_mesh
	lid.set_surface_override_material(0, lid_mat)
	lid.position = Vector3(0, 0.076, 0)
	_host.add_child(lid)
	lid_hinge = VRSpringLatchedHinge.mount(_host, lid, LID_OPEN_DEG)
	if lid_hinge != null and on_lid_swung.is_valid():
		lid_hinge.rotation_changed.connect(on_lid_swung)


## A flat ring in the XZ plane at y = 0, facing up. Godot has no annulus
## primitive, and it is the one face a cylinder cannot give: the pod needs a top
## with a hole in it.
static func _ring_mesh(inner_r: float, outer_r: float, segments: int = 48) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	for i in segments:
		var a0 := TAU * i / float(segments)
		var a1 := TAU * (i + 1) / float(segments)
		var i0 := Vector3(cos(a0) * inner_r, 0.0, sin(a0) * inner_r)
		var i1 := Vector3(cos(a1) * inner_r, 0.0, sin(a1) * inner_r)
		var o0 := Vector3(cos(a0) * outer_r, 0.0, sin(a0) * outer_r)
		var o1 := Vector3(cos(a1) * outer_r, 0.0, sin(a1) * outer_r)
		for v: Vector3 in [i0, o0, o1, i0, o1, i1]:
			verts.append(v)
			norms.append(Vector3.UP)
	return _surface_mesh(verts, norms)


## The inside of the disc well, origin at the centre of its floor: a disc facing
## up, and the side wall facing IN — it is only ever seen from within the well.
static func _well_mesh(r: float, depth: float, segments: int = 48) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	for i in segments:
		var a0 := TAU * i / float(segments)
		var a1 := TAU * (i + 1) / float(segments)
		var c0 := Vector3(cos(a0), 0.0, sin(a0))
		var c1 := Vector3(cos(a1), 0.0, sin(a1))
		var b0 := c0 * r
		var b1 := c1 * r
		var t0 := b0 + Vector3(0.0, depth, 0.0)
		var t1 := b1 + Vector3(0.0, depth, 0.0)
		# Floor.
		for v: Vector3 in [Vector3.ZERO, b0, b1]:
			verts.append(v)
			norms.append(Vector3.UP)
		# Wall.
		verts.append_array([b0, t0, t1, b0, t1, b1])
		for n: Vector3 in [-c0, -c0, -c1, -c0, -c1, -c1]:
			norms.append(n)
	return _surface_mesh(verts, norms)


static func _surface_mesh(verts: PackedVector3Array, norms: PackedVector3Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

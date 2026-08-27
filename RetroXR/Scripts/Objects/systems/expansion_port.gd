## ExpansionPort — the connector two machines are bolted together through.
##
## One relation, drawn from both sides. The LOWER machine wears the SOCKET: a
## snap zone sitting on its top face, with a dark recessed plate and a row of
## pins so the join is visible in the room and not only in a menu. The UPPER
## machine wears the FOOT: a snap grab point on its underside, with the matching
## plate, so when the socket takes it the two faces meet exactly.
##
## Nothing here knows what a 64DD is. A console asks for a socket when something
## mounts above it and for a foot when it stands on something; an expansion asks
## for the opposite pair. Which way round a given unit goes is one field in
## ExpansionCatalog, and this file never reads it.
##
## Why a grab point rather than a fixed offset: XRToolsSnapZone.snap_pose_for
## already positions a snapped object by its grab point, and the whole preview
## path (the real object ghosted onto the socket while your hand hovers) is built
## on that. A foot is therefore not extra machinery — it is the ONE piece that
## makes an object land with its underside on the socket instead of its origin.
class_name ExpansionPort
extends RefCounted

const SNAP_ZONE_SCENE := preload("res://addons/godot-xr-tools/objects/snap_zone.tscn")

## Every expansion socket joins this. A foot names it as its require_group, so a
## machine's underside grab point is offered to expansion sockets and to nothing
## else — a storage box or a hand never sees it.
const GROUP := "expansion_port"

## Group the consoles are already in, and the one expansions join in _ready.
## A socket takes exactly one of the two, which is what lets the snap ghost work:
## XRToolsSnapZone.can_preview refuses to preview for a zone with no
## snap_require, so "accept either kind" would silently cost the preview.
const GROUP_SYSTEM := "retro_system"
const GROUP_EXPANSION := "retro_expansion"

## Connector plate: 60% of the narrower span, 3 mm proud. Big enough to read as
## a real interface from standing height, small enough that it never reaches the
## edges of a box it is centred on.
const _PLATE_FRACTION := 0.6
const _PLATE_DEPTH := 0.003
const _PIN_COUNT := 12

const _PLATE_COLOUR := Color(0.05, 0.05, 0.06)
const _PIN_COLOUR := Color(0.72, 0.62, 0.28)


## Build the socket on `host`'s top face and return it.
##
## `top_y` is the top face in `host`'s local space, `span` the box's X and Z. The
## zone's origin IS the mating plane — an object snapped here puts its foot grab
## point exactly on it, so the two boxes end up face to face with no gap and no
## overlap.
##
## `accept_group` is the kind of machine this socket takes, and `filter` the
## finer test on top of it (a Mega-CD's socket takes a Mega Drive and no other
## console). The zone is placed in GROUP so only a foot answers it.
static func build_socket(host: Node3D, top_y: float, span: Vector2,
		accept_group: String, filter: Callable) -> XRToolsSnapZone:
	var zone := SNAP_ZONE_SCENE.instantiate() as XRToolsSnapZone
	zone.name = "ExpansionSocket"
	zone.snap_require = accept_group
	zone.snap_filter = filter
	# Generous: what enters this socket is a whole console, not a cartridge, and
	# a player lowers one onto a base from further out than they push a cart in.
	zone.grab_distance = 0.16
	zone.add_to_group(GROUP)
	host.add_child(zone)
	zone.position = Vector3(0.0, top_y, 0.0)
	_add_plate(zone, span, false)
	return zone


## Build the foot on `host`'s underside and return the grab point.
##
## `bottom_y` is the bottom face in `host`'s local space. The point carries no
## rotation, so a machine seats the way up it already is — the socket's own
## orientation decides which way the stack faces.
##
## The caller must register the returned point with the pickable's grab-point
## list; XRToolsPickable only collects the children present when IT runs _ready,
## and a console's body is not measured until its model has loaded, which is
## after that. See RetroSystem._build_expansion_hardware.
static func build_foot(host: Node3D, bottom_y: float, span: Vector2) -> XRToolsGrabPointSnap:
	var point := XRToolsGrabPointSnap.new()
	point.name = "ExpansionFoot"
	point.require_group = GROUP
	host.add_child(point)
	point.position = Vector3(0.0, bottom_y, 0.0)
	_add_plate(point, span, true)
	return point


## Put `obj` exactly where `zone` says it belongs, now.
##
## Needed because the grab driver a snap zone builds is a RemoteTransform3D, and
## a RemoteTransform3D does not move a frozen RigidBody. Measured: the driver is
## created carrying the correct pose and the body never follows it, so a console
## bolted to a base hangs a few centimetres above it -- and then drops into place
## the first time anything moves the base, because that is what finally changes
## the driver's own transform. Media never showed this, because the slots
## position their contents themselves rather than relying on the driver.
##
## This is the pose the zone computed, not a correction to it: the two faces are
## already flush by construction.
static func seat(zone: XRToolsSnapZone, obj: Node3D) -> void:
	if not (is_instance_valid(zone) and is_instance_valid(obj)):
		return
	var pose := zone.snap_pose_for(obj)
	obj.global_transform = pose
	# And again once the frame is over. This runs from the zone's own
	# has_picked_up, which fires inside the physics step, and a transform written
	# to a body there is overwritten before anyone sees it -- measured: the
	# immediate assignment alone leaves the console exactly where it started.
	obj.set_deferred("global_transform", pose)


## Detach whatever a socket is holding, without the socket having to be found
## again by name. Null-safe: a machine with no socket simply has nothing to drop.
static func release(zone: XRToolsSnapZone) -> void:
	if is_instance_valid(zone) and zone.has_snapped_object():
		zone.drop_object()


## The dark plate and its pin row. `downward` flips it so a foot's pins point
## down into the socket's, which is what they do on the hardware and what makes
## a half-assembled stack read correctly while it is in your hand.
static func _add_plate(parent: Node3D, span: Vector2, downward: bool) -> void:
	var w := maxf(minf(span.x, span.y) * _PLATE_FRACTION, 0.02)
	var d := w * 0.45
	var dir := -1.0 if downward else 1.0

	var plate_mesh := BoxMesh.new()
	plate_mesh.size = Vector3(w, _PLATE_DEPTH, d)
	var plate_mat := StandardMaterial3D.new()
	plate_mat.albedo_color = _PLATE_COLOUR
	plate_mat.roughness = 0.55
	var plate := MeshInstance3D.new()
	plate.name = "ConnectorPlate"
	plate.mesh = plate_mesh
	plate.set_surface_override_material(0, plate_mat)
	parent.add_child(plate)
	# Half sunk into the face it sits on, so it reads as recessed rather than
	# stuck on: the plate straddles the mating plane by design.
	plate.position = Vector3(0.0, dir * _PLATE_DEPTH * 0.5, 0.0)

	var pin_mesh := BoxMesh.new()
	pin_mesh.size = Vector3(w / (_PIN_COUNT * 2.2), _PLATE_DEPTH * 0.9, d * 0.6)
	var pin_mat := StandardMaterial3D.new()
	pin_mat.albedo_color = _PIN_COLOUR
	pin_mat.metallic = 0.9
	pin_mat.roughness = 0.35
	var pins := MultiMeshInstance3D.new()
	pins.name = "ConnectorPins"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = pin_mesh
	mm.instance_count = _PIN_COUNT
	var pitch := w * 0.9 / float(_PIN_COUNT)
	for i in _PIN_COUNT:
		var x := (i - (_PIN_COUNT - 1) * 0.5) * pitch
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(x, 0.0, 0.0)))
	pins.multimesh = mm
	pins.material_override = pin_mat
	parent.add_child(pins)
	pins.position = Vector3(0.0, dir * _PLATE_DEPTH * 0.9, 0.0)

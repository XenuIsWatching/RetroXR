## PlugExit — where a cord leaves a connector, and which way it points.
##
## A connector asset is a PackedScene: the shell's MeshInstance3D plus a
## `CordExit` Marker3D whose transform IS the answer. Position and rotation both,
## authored in Blender beside the geometry, so adding a connector is an export
## rather than a code change.
##
## ── Why this exists ──────────────────────────────────────────────────────────
## The exit used to be guessed at runtime, in two places, as "the centre of the
## mesh's back face":
##
##     cable_anchor = Vector3(ab.get_center().x, ab.get_center().y, ab.position.z)
##
## Which is right for a symmetric barrel and wrong for everything else — an
## L-plug, a moulded strain relief off the axis, a shell whose bounding box takes
## in a screw lug or a latch. It also had no way to express DIRECTION at all: the
## cord always left along -Z because that is what the rope assumed globally.
##
## The information was there and thrown away. A .glb arrives as a PackedScene with
## every node's transform; the extract tools reduced it to a bare Mesh, which has
## nowhere to record any of this, and then the code that never saw the model
## reinvented it.
##
## ── Migration ────────────────────────────────────────────────────────────────
## Both forms are accepted, so connectors convert one at a time and nothing has to
## be re-exported in a batch. A bare Mesh, or a scene with no CordExit marker,
## falls back to exactly the old rule — so the fifteen connectors that have not
## been converted behave today as they did yesterday.
class_name PlugExit
extends RefCounted

## The marker a converted connector carries.
const MARKER := "CordExit"


## The cord exit for a connector resource, in the plug's own frame.
##
## `basis.z` is the direction the cord LEAVES along, so a straight plug authored
## the project's way (connector on +Z, cable trailing -Z) has an identity-ish
## basis and a right-angle plug says so in the asset instead of in code.
static func of_resource(res: Resource) -> Transform3D:
	var scene := res as PackedScene
	if scene != null:
		return of_scene(scene)
	var mesh := res as Mesh
	if mesh != null:
		return derive_from_mesh(mesh)
	return Transform3D.IDENTITY


## The marker on a LIVE node — the generic plug carries one as a child, so it
## answers the question the same way a connector asset does.
static func of_node(node: Node) -> Transform3D:
	var marker := node.get_node_or_null(MARKER) as Node3D
	return marker.transform if marker != null else Transform3D.IDENTITY


## The marker inside a connector scene, or the derived fallback when it has none.
static func of_scene(scene: PackedScene) -> Transform3D:
	var root: Node = scene.instantiate()
	var marker := root.get_node_or_null(MARKER) as Node3D
	var out := Transform3D.IDENTITY
	if marker != null:
		out = marker.transform
	else:
		var mesh := first_mesh(root)
		if mesh != null:
			out = derive_from_mesh(mesh)
	root.free()
	return out


## The shell mesh of a connector scene, for the callers that still want one.
static func mesh_of(res: Resource) -> Mesh:
	var mesh := res as Mesh
	if mesh != null:
		return mesh
	var scene := res as PackedScene
	if scene == null:
		return null
	var root: Node = scene.instantiate()
	var found := first_mesh(root)
	if found != null:
		found = found.duplicate(true) as Mesh
	root.free()
	return found


static func first_mesh(root: Node) -> Mesh:
	var mi := root as MeshInstance3D
	if mi != null and mi.mesh != null:
		return mi.mesh
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var child := n as MeshInstance3D
		if child != null and child.mesh != null:
			return child.mesh
	return null


## The old rule, kept as the fallback and stated once instead of twice: the centre
## of the shell's back face, cord along -Z. Every unconverted connector uses this.
## Where the cord leaves this connector, in the connector's own frame: the
## authored CordExit marker if it carries one, else the centre of the tip mesh's
## back face.
##
## The whole rule, in one place. RcaPlug and CablePlug each had a comment saying
## they followed it and a line implementing only the second half — they read the
## mesh and could not have seen a marker — so a converted RCA or composite plug
## would have been laid from its bounding box anyway, silently, and the comment
## would have gone on saying otherwise.
static func origin_of(connector: Node, tip: MeshInstance3D) -> Vector3:
	var marker := connector.get_node_or_null(MARKER) as Node3D
	if marker != null:
		return marker.transform.origin
	return tip.transform * derive_from_mesh(tip.mesh).origin


static func derive_from_mesh(mesh: Mesh) -> Transform3D:
	var ab: AABB = mesh.get_aabb()
	return Transform3D(Basis.IDENTITY,
		Vector3(ab.get_center().x, ab.get_center().y, ab.position.z))

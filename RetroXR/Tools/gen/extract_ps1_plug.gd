## Bakes the PlayStation controller connector out of ps1_plug.glb into the single
## Mesh the PS1 pad's cable end wears.
##
## Run headless to (re)generate the asset:
##   godot --headless --path RetroXR --script res://Tools/gen/extract_ps1_plug.gd
##
## This exists because the asset it writes had no script behind it. ps1_plug.res
## was baked by hand once, and when Tools/glb/split_playstation.py was fixed and
## ps1_plug.glb re-exported, the .res silently kept the OLD geometry — the cable
## every PS1 pad drags around went on wearing normals from before the fix (43.8
## degrees of median deviation on the strain-relief boot, against 1.0 after).
## Nothing catches that: the two files simply drift.
##
## Unlike the NES connector this writes a BARE MESH, not a PackedScene with a
## CordExit marker, because that is what ps1_plug.res already is and what
## controller_plug.gd already reads — PlugExit.of_resource derives the exit from
## the mesh for it. Changing the format is a separate decision from keeping the
## geometry current.
##
## Two things the merge has to do beyond concatenating the five meshes (the
## housing's two materials, the shrouded pin block's two, and the cord anchor),
## both MEASURED off the geometry rather than written down:
##
##   * FLIP. The GLB carries the pin block on -Z and the cord boss on +Z, and
##     controller_plug.gd needs the opposite. Which end is which is read off the
##     Silver surface — the pins — not assumed, so a re-export that flips the
##     asset flips this with it instead of seating every plug backwards.
##
##   * SEAT. The origin goes on the HOUSING'S FRONT FACE, the face that butts up
##     against the console, which puts the pin block 8.8 mm proud of it and inside
##     the socket. That is where the hand-baked asset had it to within 10 microns,
##     so this reproduces the shipped seating rather than moving every PS1 plug.
##     X and Y are centred on the plug's own extents.
extends SceneTree

## The connector's plastic. The Sketchfab shell authors its housing materials at
## baseColorFactor (0.020, 0.017, 0.026) -- named "Grey_Dark" but authored very
## nearly BLACK, with a violet cast, and no texture to sample. That is wrong for
## this part: a real SCPH-1080's connector is moulded in the same light grey as
## the pad it belongs to. Sketchfab's viewer lights it brightly enough to read as
## grey, which is why the asset looks right there and black here.
##
## The value is prepare_ps1_pad.py's PAD_GREY, sampled off the PAD's own texture
## sheet rather than picked, so the connector matches the plastic it is actually
## continuous with.
##
## Done HERE and not in split_playstation.py on purpose: the same two materials
## dress the console's AC IN inlet and its parallel-port cover, and both of those
## are correctly black. Recolouring the material at source would lighten them too.
const PLUG_GREY := Color(165.0 / 255.0, 159.0 / 255.0, 160.0 / 255.0)

## By material name. The pins keep Silver -- they are metal, and they are right.
const RECOLOUR := ["Grey_Dark_Gloss", "Grey_Dark_Rough"]

## The surface whose front face the origin sits on. Named, because the pin block
## and the cord boss both overhang it and neither is the face that meets the
## console.
const HOUSING_SURFACE := "Grey_Dark_Rough"

const SRC := "res://imported-assets/controllers/playstation/ps1_plug.glb"
const DST := "res://Scenes/Objects/controllers/playstation/ps1_plug.res"


func _init() -> void:
	var ps := load(SRC) as PackedScene
	if ps == null:
		print("[extract] cannot load %s" % SRC)
		quit(1)
		return
	var root: Node3D = ps.instantiate()
	var out := ArrayMesh.new()
	var tris := 0
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var x: Transform3D = _relative_to(mi, root)
		if not x.is_equal_approx(Transform3D.IDENTITY):
			print("[extract] NOTE %s carries a transform, applying it: %s" % [mi.name, x])
		for s in mi.mesh.get_surface_count():
			var arr: Array = mi.mesh.surface_get_arrays(s)
			arr[Mesh.ARRAY_VERTEX] = _xform_points(arr[Mesh.ARRAY_VERTEX], x)
			arr[Mesh.ARRAY_NORMAL] = _xform_normals(arr[Mesh.ARRAY_NORMAL], x)
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			tris += idx.size() / 3
			var mat: Material = _dressed(mi.mesh.surface_get_material(s))
			out.surface_set_material(out.get_surface_count() - 1, mat)
			out.surface_set_name(out.get_surface_count() - 1,
				mat.resource_name if mat != null else mi.name)

	if out.get_surface_count() == 0:
		print("[extract] no surfaces in %s" % SRC)
		quit(1)
		return

	var pins: Variant = _surface_bounds(out, "Silver")
	var housing: Variant = _surface_bounds(out, HOUSING_SURFACE)
	if pins == null or housing == null:
		print("[extract] REFUSING: need a Silver (pins) and a %s (housing) surface"
			% HOUSING_SURFACE)
		quit(1)
		return
	var flip := (pins as AABB).get_center().z < 0.0
	var full: AABB = out.get_aabb()
	# After the flip the housing's front face is what was its BACK, so the seat is
	# read from the opposite end of its box.
	var seat_z: float = -(housing as AABB).position.z if flip else (housing as AABB).end.z
	var offset := Vector3(-full.get_center().x, -full.get_center().y, -seat_z)
	if flip:
		offset.x = -offset.x
	out = _rebuild(out, flip, offset)
	print("[extract] pins on %sZ -> %s; origin on the housing face" % [
		"-" if flip else "+", "flipped 180 about Y" if flip else "as exported"])

	# The connector seats along +Z and the cord leaves along -Z. Asserted rather
	# than trusted: it is the one thing about this mesh the cable code relies on,
	# and a re-export that flipped it would look right in isolation and put every
	# plug in backwards.
	var ab: AABB = out.get_aabb()
	if ab.end.z <= 0.0 or ab.position.z >= 0.0:
		print("[extract] REFUSING: connector must sit on +Z and the cord on -Z")
		quit(1)
		return
	print("[extract] %d surfaces, %d tris, aabb %.1f x %.1f x %.1f mm" % [
		out.get_surface_count(), tris,
		ab.size.x * 1000.0, ab.size.y * 1000.0, ab.size.z * 1000.0])
	print("[extract] connector +%.2f mm | cord boss -%.2f mm | y %.2f .. %.2f mm" % [
		ab.end.z * 1000.0, -ab.position.z * 1000.0,
		ab.position.y * 1000.0, ab.end.y * 1000.0])

	var err := ResourceSaver.save(out, DST)
	if err != OK:
		print("[extract] save failed: %d" % err)
		quit(1)
		return
	print("[extract] wrote %s" % DST)
	quit(0)


## The material a surface should wear, recoloured if it is one of the housing's.
##
## DUPLICATED before the albedo is touched: the material handed back by the
## imported GLB is shared with every other user of that scene, and writing
## through it would repaint them as a side effect of a bake.
func _dressed(mat: Material) -> Material:
	var std := mat as StandardMaterial3D
	if std == null or not RECOLOUR.has(std.resource_name):
		return mat
	var out := std.duplicate() as StandardMaterial3D
	print("[extract] %s: albedo %s -> %s" % [std.resource_name, std.albedo_color, PLUG_GREY])
	out.albedo_color = PLUG_GREY
	return out


func _surface_bounds(mesh: ArrayMesh, surface_name: String) -> Variant:
	for i in mesh.get_surface_count():
		if mesh.surface_get_name(i) != surface_name:
			continue
		var arr: Array = mesh.surface_get_arrays(i)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if vs.is_empty():
			continue
		var ab := AABB(vs[0], Vector3.ZERO)
		for v in vs:
			ab = ab.expand(v)
		return ab
	return null


## Re-emit every surface through a yaw of 180 degrees and a translation. Winding
## survives: a 180 rotation has determinant +1, so it does not turn the mesh
## inside out the way mirroring one axis would.
func _rebuild(mesh: ArrayMesh, flip: bool, offset: Vector3) -> ArrayMesh:
	var basis := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1)) 		if flip else Basis.IDENTITY
	var x := Transform3D(basis, offset)
	var out := ArrayMesh.new()
	for i in mesh.get_surface_count():
		var arr: Array = mesh.surface_get_arrays(i)
		arr[Mesh.ARRAY_VERTEX] = _xform_points(arr[Mesh.ARRAY_VERTEX], x)
		arr[Mesh.ARRAY_NORMAL] = _xform_normals(arr[Mesh.ARRAY_NORMAL], x)
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		out.surface_set_material(i, mesh.surface_get_material(i))
		out.surface_set_name(i, mesh.surface_get_name(i))
	return out


## The pose of a node relative to `root`, walked through `transform` rather than
## read off `global_transform`: this scene is instantiated and never added to the
## tree, and an orphan's global_transform is not its pose in the scene — the first
## run of this script trusted it and baked a 1.96 METRE connector.
func _relative_to(n: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node3D = n
	while cur != null and cur != root:
		t = cur.transform * t
		cur = cur.get_parent() as Node3D
	return t


func _xform_points(src: PackedVector3Array, x: Transform3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(src.size())
	for i in src.size():
		out[i] = x * src[i]
	return out


func _xform_normals(src: PackedVector3Array, x: Transform3D) -> PackedVector3Array:
	if src.is_empty():
		return src
	var out := PackedVector3Array()
	out.resize(src.size())
	var b := x.basis.orthonormalized()
	for i in src.size():
		out[i] = (b * src[i]).normalized()
	return out

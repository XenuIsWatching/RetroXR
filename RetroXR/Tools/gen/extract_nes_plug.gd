## Bakes the NES controller connector out of nes_plug.glb into a standalone Mesh
## for the NES pad's cable end.
##
## Run headless to (re)generate the asset:
##   godot --headless --path RetroXR --script res://Tools/gen/extract_nes_plug.gd
##
## The connector is greenestbanana's, lifted from the console GLB where it sits
## posed in port 1 (see imported-assets/consoles/nes/LICENSE-nes-console.txt).
## The Blender pass that produced nes_plug.glb already baked it into
## ControllerPlug's frame — origin at the seated position, connector on +Z, cable
## trailing -Z — reproducing the depth its author posed it at: the tip 16.2 mm
## inside the console's front face, the cable end 27 mm proud of it. So there is
## no transform to apply here, only a format change.
##
## The output is a PackedScene, not a bare Mesh: the shell plus a CordExit
## Marker3D saying where the cord leaves and which way it points. That used to be
## guessed at runtime from the mesh's bounding box, which cannot express a
## direction at all and is wrong for any shell that is not a symmetric barrel.
## The marker is SEEDED from that same guess and then belongs to the asset — open
## the .res in the editor and move it, rather than arguing with a heuristic.
##
## Same job as RetroVR's Tools/extract_psx_plug.gd, which does apply a transform
## because it reads its plug straight out of an un-posed console GLB.
extends SceneTree

const SRC := "res://imported-assets/controllers/nes/nes_plug.glb"
const DST := "res://imported-assets/controllers/nes/nes_controller_plug.res"


func _init() -> void:
	var ps := load(SRC) as PackedScene
	if ps == null:
		print("[extract] cannot load %s" % SRC)
		quit(1)
		return
	var root: Node = ps.instantiate()
	var mi: MeshInstance3D = null
	for n in root.find_children("*", "MeshInstance3D", true, false):
		mi = n as MeshInstance3D
		break
	if mi == null or mi.mesh == null:
		print("[extract] no mesh in %s" % SRC)
		quit(1)
		return

	var mesh: Mesh = mi.mesh.duplicate(true)
	var ab: AABB = mesh.get_aabb()
	print("[extract] aabb %s .. %s" % [ab.position, ab.end])
	if ab.end.z <= 0.0 or ab.position.z >= 0.0:
		print("[extract] REFUSING: connector must sit on +Z and the cable on -Z")
		quit(1)
		return
	print("[extract] connector +%.1f mm | cable boss -%.1f mm | face %.1f x %.1f mm" % [
		ab.end.z * 1000.0, -ab.position.z * 1000.0, ab.size.x * 1000.0, ab.size.y * 1000.0])

	# The connector as a scene: shell, plus the cord exit as data.
	var shell := MeshInstance3D.new()
	shell.name = "Shell"
	shell.mesh = mesh
	var exit := Marker3D.new()
	exit.name = PlugExit.MARKER
	exit.transform = PlugExit.derive_from_mesh(mesh)
	shell.add_child(exit)
	exit.owner = shell
	var packed := PackedScene.new()
	if packed.pack(shell) != OK:
		print("[extract] could not pack the connector scene")
		quit(1)
		return
	print("[extract] CordExit at %.1f, %.1f, %.1f mm" % [
		exit.transform.origin.x * 1000.0, exit.transform.origin.y * 1000.0,
		exit.transform.origin.z * 1000.0])

	var err := ResourceSaver.save(packed, DST)
	if err != OK:
		print("[extract] save failed: %d" % err)
		quit(1)
		return
	print("[extract] wrote %s" % DST)
	quit(0)

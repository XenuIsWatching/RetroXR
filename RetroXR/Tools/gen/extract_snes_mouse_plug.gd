## Bakes the SNES mouse's connector out of snes_mouse_plug.glb into a standalone
## Mesh for the mouse's cable end.
##
## Run headless to (re)generate the asset:
##   godot --headless --path RetroXR --script res://Tools/gen/extract_snes_mouse_plug.gd
##
## The connector is Peardian's, lifted from the mouse GLB (see
## imported-assets/controllers/snes-mouse/LICENSE-snes-mouse.txt). The Blender
## pass that produced snes_mouse_plug.glb already baked it into ControllerPlug's
## frame — origin on the shroud's shoulder, which is the face that meets the
## console's port cheek, with the D-shaped shroud on +Z and the ribbed strain
## relief trailing -Z. So there is no transform here, only the format change
## set_plug_mesh() needs: it wants a Mesh, and a .glb loads as a PackedScene.
##
## Same job as Tools/gen/extract_nes_plug.gd.
extends SceneTree

const SRC := "res://imported-assets/controllers/snes-mouse/snes_mouse_plug.glb"
const DST := "res://imported-assets/controllers/snes-mouse/snes_mouse_plug.res"


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
	print("[extract] shroud +%.1f mm | cable boss -%.1f mm | face %.1f x %.1f mm" % [
		ab.end.z * 1000.0, -ab.position.z * 1000.0, ab.size.x * 1000.0, ab.size.y * 1000.0])

	var err := ResourceSaver.save(mesh, DST)
	if err != OK:
		print("[extract] save failed: %d" % err)
		quit(1)
		return
	print("[extract] wrote %s" % DST)
	quit(0)

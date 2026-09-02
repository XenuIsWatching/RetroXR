## Bakes a to-scale panel-mount RCA (composite) SOCKET to Scenes/Objects/cables/rca_jack.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_rca_jack.gd
##
## The female half of gen_rca_plug.gd's connector, and the replacement for the
## flat yellow cylinder tv.tscn used to draw on the back of the set. Same solid-of-
## revolution approach, same materials (Tools/gen/plug_materials.gd), so the jack and
## the plug that goes into it cannot drift apart in finish.
##
## Sized to MATE with that plug rather than to look right on its own: the plug's
## metal collar is 8.7 mm across the outside and 6.8 mm across the bore, so this
## barrel is 6.7 mm and the collar slides over it. The plug's 3.6 mm centre pin
## enters the 4.0 mm socket.
##
##   * chrome flange 9.6 mm across, seated on the panel
##   * chrome barrel 6.7 mm across, standing 7.5 mm proud
##   * coloured insulator recessed 0.7 mm behind the barrel's rim, which is what
##     puts the metal lip in front of the colour the way a real jack has it
##   * 4.0 mm socket, a genuine bore rather than a dark disc -- it reads black
##     because next to no ambient light reaches 12 mm down a 4 mm hole
##
## The socket runs back PAST the panel face, which is both what a real jack does
## and what this one has to do: a seated plug's pin reaches 14 mm back from its
## collar, and a floor in front of that would have the pin poking through it.
##
## Authored socket-on-+Z with the origin on the panel face, so it drops onto a
## port node whose local +Z points out of the cabinet with no transform of its own.
##
## Surface 0 is the coloured plastic and surface 1 the metal, matching the plug's
## order: Scripts/Objects/cables/rca_jack.gd recolours surface 0 for the white and
## red audio jacks, exactly as system.gd's _decorate_channel_plug tints the plug.
## Surface 2 is the centre socket, kept off surface 0 so recolouring a jack cannot
## turn its hole yellow.
##
## Winding is load-bearing -- generate_normals() reads facing from vertex order
## alone. See the _lathe note at the foot of gen_rca_plug.gd for the rules; both
## profiles below run up the outside, across the rim and back down the bore.
extends SceneTree

const PlugMats := preload("res://Tools/gen/plug_materials.gd")

const OUT_PATH := "res://Scenes/Objects/cables/rca_jack.res"

const RING := 16

const FLANGE_R := 0.0048
const BARREL_R := 0.00335       # plug collar bore is 0.00340, so it slides on
const BORE_R := 0.0030
const SOCKET_R := 0.0020        # plug pin is 0.0018

const Z_PANEL := 0.0
const Z_FLANGE_END := 0.0012
const Z_FLOOR := -0.0050       # behind the panel, where the seated pin ends up
const Z_PLASTIC_FACE := 0.0068
const Z_RIM := 0.0075


func _init() -> void:
	var mesh := ArrayMesh.new()

	# --- surface 0: the coloured insulator ------------------------------------
	# Its outer wall is buried in the metal; the annulus at Z_PLASTIC_FACE is the
	# whole of what anyone sees. The bore below it belongs to surface 2.
	var ins := PackedVector2Array([
		Vector2(Z_FLOOR, BORE_R),
		Vector2(Z_PLASTIC_FACE, BORE_R),        # up the outside, inside the shell
		Vector2(Z_PLASTIC_FACE, SOCKET_R),      # the visible ring, faces +Z
	])
	# One SurfaceTool for the whole jack: each part is lathed after set_color()
	# with its class, and the lot commits as ONE surface on the shared connector
	# material. See Shaders/connector.gdshader for why.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(PlugMats.plastic_vertex(Color(0.95, 0.74, 0.02)))
	_lathe(st, ins)

	# --- flange + barrel + bore, one continuous profile -----------------------
	# Open at the back: that end is against the cabinet, and closing it would only
	# add triangles nobody can see. The bore meets the insulator's outer wall at
	# BORE_R, so no gap shows at the join.
	var shell := PackedVector2Array([
		Vector2(Z_PANEL, FLANGE_R),
		Vector2(Z_FLANGE_END, FLANGE_R),        # flange outside
		Vector2(Z_FLANGE_END, BARREL_R),        # flange shoulder, faces +Z
		Vector2(Z_RIM, BARREL_R),               # barrel outside
		Vector2(Z_RIM, BORE_R),                 # rim, faces +Z
		Vector2(Z_FLOOR, BORE_R),               # back down the bore, faces inward
	])
	st.set_color(PlugMats.chrome_vertex())
	_lathe(st, shell)

	# --- the centre socket ----------------------------------------------------
	# Dark by MATERIAL, not by depth. These rooms light with a flat ambient colour
	# and no radiance map, so nothing is shadowed for being 12 mm down a 4 mm hole:
	# a bore given the insulator's own material renders as bright as the ring
	# around it and the jack loses its hole entirely. Nearly-black and rough is
	# what a recessed contact looks like anyway.
	var socket := PackedVector2Array([
		Vector2(Z_PLASTIC_FACE, SOCKET_R),
		Vector2(Z_FLOOR, SOCKET_R),             # bore wall, faces inward
		Vector2(Z_FLOOR, 0.0),                  # floor, faces +Z
	])
	st.set_color(PlugMats.socket_vertex())
	_lathe(st, socket)

	st.generate_normals()
	var mat := PlugMats.connector()
	st.set_material(mat)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, mat)

	var err := ResourceSaver.save(mesh, OUT_PATH)
	var ab: AABB = mesh.get_aabb()
	var tris := 0
	for s in mesh.get_surface_count():
		tris += mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX].size() / 3
	print("[gen] %s err=%d  %.4f x %.4f x %.4f m  z %.4f..%.4f  tris %d" % [
		OUT_PATH, err, ab.size.x, ab.size.y, ab.size.z,
		ab.position.z, ab.end.z, tris])
	quit()


## Revolve a (z, radius) profile about the Z axis. Copy of gen_rca_plug.gd's,
## whose header documents how the profile's direction decides facing.
func _lathe(st: SurfaceTool, profile: PackedVector2Array) -> void:
	for s in range(profile.size() - 1):
		var z0: float = profile[s].x
		var r0: float = profile[s].y
		var z1: float = profile[s + 1].x
		var r1: float = profile[s + 1].y
		if is_equal_approx(z0, z1) and is_equal_approx(r0, r1):
			continue
		for i in RING:
			var a0: float = TAU * float(i) / float(RING)
			var a1: float = TAU * float(i + 1) / float(RING)
			var p00 := Vector3(cos(a0) * r0, sin(a0) * r0, z0)
			var p10 := Vector3(cos(a1) * r0, sin(a1) * r0, z0)
			var p01 := Vector3(cos(a0) * r1, sin(a0) * r1, z1)
			var p11 := Vector3(cos(a1) * r1, sin(a1) * r1, z1)
			if is_zero_approx(r0):
				st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
			elif is_zero_approx(r1):
				st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p10)
			else:
				st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
				st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)

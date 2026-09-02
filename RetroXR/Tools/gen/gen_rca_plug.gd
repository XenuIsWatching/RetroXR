## Bakes a to-scale RCA (composite) plug to Scenes/Objects/cables/rca_plug_yellow.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_rca_plug.gd
##
## Replaces cable.tscn's stand-in: a plain tapered cylinder plus a separate black
## cylinder for the strain relief, which read as a crayon rather than a connector.
##
## The whole plug is a SOLID OF REVOLUTION, so it is built by revolving one 2D
## (z, r) profile rather than by stacking primitives. That is what makes the
## ribbed strain relief and the barrel's ring grooves cheap: a rib is two extra
## points on the profile, not a separate mesh. 2.3k tris all in, against 15.2k for
## the best CC-BY download found — and decimating that one would have eaten the
## ribs first, since quadric decimation collapses high-curvature detail and keeps
## flat spans.
##
## Dimensions are the real connector:
##   * centre pin 3.6 mm across, protruding 6 mm past the collar
##   * metal collar 8.7 mm outside diameter, 8 mm long
##   * plastic barrel 14.4 mm, ring-grooved near the front
##   * ribbed strain relief tapering to meet the 8.3 mm cord cable.tscn draws
##
## Authored connector-on-+Z, cable-trailing--Z. Origin sits at the collar base,
## which puts the mesh's centre within a millimetre of the cylinder it replaces —
## so the snap zone and the rope both keep their existing alignment. The rope
## attaches at the origin and its last 40 mm run back INSIDE the opaque barrel,
## which is how the stand-in hid the join too.
##
## Surface 0 must stay the yellow plastic: system.gd's _decorate_channel_plug
## tints surface 0 blue to mark a dual-screen host's BOTTOM channel, and that
## wants to recolour the body, not the metal.
##
## Winding is load-bearing — generate_normals() reads facing from vertex order
## alone. _lathe emits in Godot's Plane(a,b,c) order, which makes an
## increasing-z segment face outward and a decreasing-z one face into the bore,
## and a constant-z segment face +Z when the radius shrinks. The metal is
## therefore ONE continuous profile: up the outside, across the rim, back down
## the bore, across the floor, out along the pin.
extends SceneTree

const PlugMats := preload("res://Tools/gen/plug_materials.gd")

const OUT_PATH := "res://Scenes/Objects/cables/rca_plug_yellow.res"

const RING := 16

const CABLE_R := 0.00415        # the cord cable.tscn draws, so the relief meets it
const CORD_MOUTH_R := 0.0012    # under any cord drawn here, so the cord covers it
const CORD_SOCKET_DEPTH := 0.003
const BARREL_R := 0.0072
const COLLAR_OR := 0.00435
const COLLAR_IR := 0.00340
const PIN_R := 0.0018
const PIN_TIP_R := 0.0010

const Z_CABLE := -0.040
const Z_RELIEF_END := -0.021
const Z_BARREL_START := -0.0195
const Z_BARREL_END := -0.0015
const Z_COLLAR := 0.0
const Z_COLLAR_END := 0.008
const Z_PIN_SHOULDER := 0.0130
const Z_PIN_END := 0.0140

## Fine moulded rings, not a coarse thread. The first pass used 8 sawtooth ribs at
## 1.2 mm amplitude and read as a screw: on the real part the ribs are many,
## shallow and rounded. Sampling a sine four times per rib is what rounds them —
## two points per rib gives back the sawtooth however many you use.
const RIBS := 12
const RIB_SAMPLES := 4
const RIB_AMP := 0.0008


func _init() -> void:
	var mesh := ArrayMesh.new()

	# --- surface 0: yellow plastic (relief ribs + barrel) --------------------
	var prof := PackedVector2Array()
	# Cord entry: a BLIND socket, not a hole. The centre is left open so the cord
	# enters something rather than butting against a disc, but the plastic here is
	# a single lathed shell with no interior, so an opening the cord does not cover
	# looks straight into the hollow of the barrel -- the relief's ribs read from
	# the inside as a striped tube around the cord.
	#
	# Two things keep that shut. The mouth is narrower than any cord the project
	# draws (the A/V lead is 8.3 mm, the controller cord 4.5 mm) and than a 3 mm one
	# it might, so the cord covers it. And the socket has a floor 3 mm in, so even a
	# cord thinner than the mouth shows a blind hole rather than the inside of the
	# plug. Cheap: 3 mm of bore is 48 triangles.
	prof.append(Vector2(Z_CABLE + CORD_SOCKET_DEPTH, 0.0))
	prof.append(Vector2(Z_CABLE + CORD_SOCKET_DEPTH, CORD_MOUTH_R))   # floor, faces -Z
	prof.append(Vector2(Z_CABLE, CORD_MOUTH_R))                       # wall, faces inward
	prof.append(Vector2(Z_CABLE, CABLE_R + 0.0003))                   # back face, faces -Z
	# Ribbed strain relief, swelling slightly as it approaches the barrel.
	var steps := RIBS * RIB_SAMPLES
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var z: float = lerpf(Z_CABLE, Z_RELIEF_END, t)
		var base: float = lerpf(CABLE_R + 0.0003, 0.0053, t)
		# -PI/2 phase starts the run in a valley, so the relief leaves the cable at
		# its base radius rather than mid-rib.
		var bump: float = 0.5 + 0.5 * sin(t * float(RIBS) * TAU - PI * 0.5)
		prof.append(Vector2(z, base + RIB_AMP * bump))
	# Pronounced shoulder up to the barrel — on the real part this is a hard step,
	# and smoothing it was what made the first pass read as one continuous cone.
	prof.append(Vector2(Z_RELIEF_END, 0.0053))
	prof.append(Vector2(Z_BARREL_START, BARREL_R))
	# Ring grooves clustered toward the front of the barrel, as on the moulding.
	for gz in [-0.0125, -0.0100, -0.0075, -0.0050]:
		prof.append(Vector2(gz, BARREL_R))
		prof.append(Vector2(gz + 0.0007, BARREL_R - 0.0011))
		prof.append(Vector2(gz + 0.0014, BARREL_R))
	prof.append(Vector2(Z_BARREL_END, BARREL_R))
	# Chamfer down to the collar so no gap shows where the metal emerges.
	prof.append(Vector2(Z_COLLAR, COLLAR_OR + 0.0002))

	# One SurfaceTool for the whole plug: each part is lathed after set_color()
	# with its class, and the lot commits as ONE surface on the shared connector
	# material. See Shaders/connector.gdshader for why.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(PlugMats.plastic_vertex(Color(0.95, 0.74, 0.02)))
	_lathe(st, prof)

	# --- collar + centre pin, one continuous profile --------------------------
	var mp := PackedVector2Array([
		Vector2(Z_COLLAR, COLLAR_OR),          # up the outside of the collar
		Vector2(Z_COLLAR_END, COLLAR_OR),
		Vector2(Z_COLLAR_END, COLLAR_IR),      # front rim, faces +Z
		Vector2(Z_COLLAR, COLLAR_IR),          # back down the bore, faces inward
		Vector2(Z_COLLAR, PIN_R),              # bore floor, faces +Z
		Vector2(Z_PIN_SHOULDER, PIN_R),        # out along the pin
		Vector2(Z_PIN_END, PIN_TIP_R),         # tip taper
		Vector2(Z_PIN_END, 0.0),               # cap
	])
	st.set_color(PlugMats.chrome_vertex())
	_lathe(st, mp)

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
	print("[gen] %s err=%d  %.4f x %.4f x %.4f m  z %.4f..%.4f  centre_z %.4f  tris %d" % [
		OUT_PATH, err, ab.size.x, ab.size.y, ab.size.z,
		ab.position.z, ab.end.z, ab.get_center().z, tris])
	quit()


## Revolve a (z, radius) profile about the Z axis.
##
## Facing follows the profile's direction, which is the whole reason the metal
## collar can be one strip: increasing z faces outward, decreasing z faces into
## the bore, and a constant-z step faces +Z when the radius shrinks, -Z when it
## grows. Order the points and the normals take care of themselves.
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
			# Degenerate at the axis: one triangle, not two.
			if is_zero_approx(r0):
				st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
			elif is_zero_approx(r1):
				st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p10)
			else:
				st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
				st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)

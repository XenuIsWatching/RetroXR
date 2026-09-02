## Bakes a to-scale F-type coaxial pair — the aerial connector — to
## Scenes/Objects/cables/coax_plug.res and Scenes/Objects/cables/coax_jack.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_coax.gd
##
## BOTH HALVES IN ONE FILE, the convention gen_vga.gd and gen_wii_av.gd set: the
## male and the female have to agree on a thread diameter and a standoff, and two
## scripts is two places for those to drift.
##
## Dimensions are the real connector (3/8"-32 UNEF, the aerial socket on the back
## of every television):
##   * thread 9.53 mm outside diameter — this is the "3/8" in the spec
##   * hex nut 11.1 mm across the flats (7/16"), because the nut has to WRAP that
##     thread; 9.5 mm across flats would put the flats inside their own thread
##   * centre conductor 1.0 mm — the coax core itself, there is no separate pin
##   * jack stub 10 mm proud of the panel, nut 8 mm long
##
## MATING STANDOFF = 10.0 mm, and coax_port.tscn carries it: the zone sits where a
## seated plug's ORIGIN belongs and the jack is pushed back by that much so its
## flange lands on the panel. Same figure as the phono pair, which is a
## coincidence worth stating out loud so nobody "fixes" one to match the other.
##
## How that falls out, because the direction catches everyone once:
## a snap zone composes plug_basis = zone_basis * Rx(180), so a seated plug's +Z
## points back along the zone's -Z — the two connectors face each other. The nut's
## RECESS therefore has to be at POSITIVE plug z, in front of the origin, exactly
## as the phono plug's collar bore is. With the nut spanning z 0..8 mm and the
## stub standing 10 mm proud, the stub bottoms on the nut's floor and 2 mm of
## thread stays showing between the nut and the flange — which is what a
## screwed-on F connector looks like.
##
## No mirror correction, unlike gen_vga.gd's D-shell. Rx(180) is y -> -y in
## section, and both the hexagon (vertices on the axes, phase 0) and every round
## part are symmetric under that reflection. Do not copy VGA's Y-flip here.
##
## ONE surface on the shared connector material (Shaders/connector.gdshader), the
## part carried in vertex colour. The boot is the MATTE class in its own near-black,
## not the tinted one: the only lead that carries this plug is the RF switch, whose
## cord colour is the same near-black as the bake, so the tint
## CompositeCable._tint_plug sets on the instance has nothing to add and the boot
## keeps its dry finish.
##
## Winding is load-bearing — generate_normals() reads facing from vertex order
## alone. _lathe_n emits in Godot's Plane(a,b,c) order, so an increasing-z segment
## faces outward, a decreasing-z one faces into the bore, and a constant-z segment
## faces +Z when the radius shrinks and -Z when it grows.
extends SceneTree

const PlugMats := preload("res://Tools/gen/plug_materials.gd")

const PLUG_PATH := "res://Scenes/Objects/cables/coax_plug.res"
const JACK_PATH := "res://Scenes/Objects/cables/coax_jack.res"

const RING := 16
const HEX_SIDES := 6

# --- the standard ------------------------------------------------------------
const HEX_AF := 0.0111              # 7/16" across flats
const HEX_R := 0.006409             # circumradius = HEX_AF / (2 * cos 30)
const THREAD_CREST := 0.004765      # 9.53 mm OD
const THREAD_ROOT := 0.004365       # 0.4 mm thread depth
const PIN_R := 0.00050              # 1.0 mm centre conductor
const PIN_TIP_R := 0.00035

# --- derived, kept apart so nobody mistakes them for standard figures ---------
const NUT_L := 0.0080
const NUT_BORE_R := 0.00485         # clears the 0.004765 crest by 0.085 mm
const NUT_INNER_R := 0.00400        # the ferrule overlaps this; see below
const NUT_CHAMFER := 0.0004
const FERRULE_R := 0.00450
const FERRULE_BACK := -0.0080
const PTFE_R := 0.00410
const PIN_END := 0.0120             # reaches the jack's socket contact
const CORD_R := 0.00300             # RG-59, 6 mm jacket
const BOOT_R := 0.00480
const Z_CORD := -0.0320
const Z_BOOT_END := -0.0070
const CORD_MOUTH_R := 0.0011
const CORD_SOCKET_DEPTH := 0.0025
const RIBS := 4
const RIB_SAMPLES := 4
const RIB_AMP := 0.0004

# --- the jack ----------------------------------------------------------------
const FLANGE_R := 0.0064
const FLANGE_Z := 0.0015
const STUB_TIP := 0.0100            # 10 mm proud == the mating standoff
const TURNS := 11
const BORE_R := 0.00185
const BORE_FLOOR := 0.0060
const SOCKET_R := 0.00070
const SOCKET_BACK := -0.0030

const STANDOFF := 0.0100


func _init() -> void:
	_bake_plug()
	_bake_jack()
	quit()


# ── male ──────────────────────────────────────────────────────────────────────

func _bake_plug() -> void:
	var mesh := ArrayMesh.new()

	# --- surface 0: black boot + strain relief -------------------------------
	var prof := PackedVector2Array()
	# Cord entry as a BLIND socket, for the reason gen_rca_plug.gd gives: the boot
	# is a lathed shell with no interior, so an opening the cord does not cover
	# looks straight up the inside of it. The mouth is narrower than any cord the
	# project draws and the socket has a floor 2.5 mm in.
	prof.append(Vector2(Z_CORD + CORD_SOCKET_DEPTH, 0.0))
	prof.append(Vector2(Z_CORD + CORD_SOCKET_DEPTH, CORD_MOUTH_R))   # floor, faces -Z
	prof.append(Vector2(Z_CORD, CORD_MOUTH_R))                       # wall, faces inward
	prof.append(Vector2(Z_CORD, CORD_R + 0.0003))                    # back face, faces -Z
	# Ribbed relief. Sine-sampled four times per rib, not two: two points per rib
	# gives back a sawtooth however many you use, and a sawtooth reads as a screw —
	# which on this part would be a second thread, right beside the real one.
	var steps := RIBS * RIB_SAMPLES
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var z: float = lerpf(Z_CORD, -0.0110, t)
		var base: float = lerpf(CORD_R + 0.0003, BOOT_R, t)
		var bump: float = 0.5 + 0.5 * sin(t * float(RIBS) * TAU - PI * 0.5)
		prof.append(Vector2(z, base + RIB_AMP * bump))
	prof.append(Vector2(-0.0110, BOOT_R))
	prof.append(Vector2(Z_BOOT_END, BOOT_R))
	# Front annulus, faces +Z. Inner edge is UNDER the ferrule (0.00450), so the
	# open mouth of the boot never shows.
	prof.append(Vector2(Z_BOOT_END, FERRULE_R - 0.00005))

	# One SurfaceTool for the whole plug: each part is lathed after set_color()
	# with its class, and the lot commits as ONE surface on the shared connector
	# material. See Shaders/connector.gdshader for why.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(PlugMats.matte_vertex(Color(0.06, 0.06, 0.07)))
	_lathe_n(st, prof, RING)

	# --- nickel — round ferrule plus the six-sided nut -----------------------
	st.set_color(PlugMats.metal_vertex(Color(0.86, 0.87, 0.89)))
	# Ferrule: a plain crimp barrel running up to the back of the nut.
	_lathe_n(st, PackedVector2Array([
		Vector2(FERRULE_BACK, FERRULE_R),
		Vector2(0.0, FERRULE_R),
	]), RING)
	# The nut. NOT a solid of revolution, and the only part of the project that
	# isn't — same profile machinery, six sides, radius read as the CIRCUMRADIUS.
	#
	# Flat-shaded, or generate_normals() averages the six faces into a lumpy
	# cylinder and the nut stops reading as a nut. The smooth group is restored
	# afterwards so nothing else in this surface facets.
	#
	# Phase 0 puts vertices on the axes and a FLAT facing +Y, which is how a nut
	# sits on a bench.
	#
	# The bore is hexagonal too, which the real part's is not. It is inside an
	# 11 mm nut and covered by the jack's thread whenever anything is plugged in;
	# splitting it into a round bore would need a hexagon-to-circle transition
	# ring at every radius, and a 6-gon meeting a 16-gon of equal radius leaves a
	# sliver at each flat.
	st.set_smooth_group(-1)
	_lathe_n(st, PackedVector2Array([
		Vector2(0.0, NUT_INNER_R),               # buried under the ferrule
		Vector2(0.0, HEX_R),                     # back annulus, faces -Z
		Vector2(NUT_L - NUT_CHAMFER, HEX_R),     # the flats, face outward
		Vector2(NUT_L, HEX_R - NUT_CHAMFER),     # front chamfer
		Vector2(NUT_L, NUT_BORE_R),              # front annulus, faces +Z
		Vector2(0.0, NUT_BORE_R),                # bore wall, faces inward
		Vector2(0.0, NUT_INNER_R),               # bore floor, faces +Z
	]), HEX_SIDES)
	st.set_smooth_group(0)

	# --- the PTFE disc closing the bore --------------------------------------
	# Sat 0.2 mm behind the nut's floor so the two never z-fight. Its 16-gon is
	# wider at every angle than the hexagonal hole it covers.
	st.set_color(PlugMats.matte_vertex(Color(0.92, 0.92, 0.90)))
	_lathe_n(st, PackedVector2Array([
		Vector2(-0.0002, PTFE_R),
		Vector2(-0.0002, PIN_R + 0.0002),
	]), RING)

	# --- the centre conductor ------------------------------------------------
	# Copper, not chrome: on the real thing this IS the cable's core, stripped.
	st.set_color(PlugMats.metal_vertex(Color(0.84, 0.62, 0.38)))
	_lathe_n(st, PackedVector2Array([
		Vector2(-0.0002, PIN_R),
		Vector2(PIN_END, PIN_R),
		Vector2(PIN_END + 0.0004, PIN_TIP_R),
		Vector2(PIN_END + 0.0004, 0.0),
	]), RING)

	_commit(st, mesh)
	_report(PLUG_PATH, mesh)


# ── female ────────────────────────────────────────────────────────────────────

func _bake_jack() -> void:
	var mesh := ArrayMesh.new()

	# --- the PTFE ring at the bottom of the bore -----------------------------
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(PlugMats.matte_vertex(Color(0.92, 0.92, 0.90)))
	_lathe_n(st, PackedVector2Array([
		Vector2(BORE_FLOOR, BORE_R),
		Vector2(BORE_FLOOR, SOCKET_R),
	]), RING)

	# --- flange, threaded stub, bore — one continuous profile ----------------
	var prof := PackedVector2Array()
	# Rear body, behind the panel. Not decoration: the plug's centre conductor
	# reaches 2.4 mm past the flange when seated, and without something to go into
	# it hangs out the back of the socket in mid air. Invisible once the jack is
	# mounted — that is the point, it is what the cabinet would be hiding — but a
	# bulkhead connector has a body back there and this is it.
	prof.append(Vector2(SOCKET_BACK - 0.0010, 0.0))
	prof.append(Vector2(SOCKET_BACK - 0.0010, 0.0030))   # back cap, faces -Z
	prof.append(Vector2(0.0, 0.0030))                    # rear barrel, faces outward
	prof.append(Vector2(0.0, FLANGE_R))              # flange back, faces -Z
	prof.append(Vector2(FLANGE_Z, FLANGE_R))         # flange side, faces outward
	prof.append(Vector2(FLANGE_Z, THREAD_CREST))     # shoulder, faces +Z
	# The thread. A two-point sawtooth per turn is CORRECT here, and it is the
	# exact inverse of the note in gen_rca_plug.gd: its moulded rings had to be
	# sine-sampled because a sawtooth read as a screw. This IS a screw.
	for i in range(TURNS * 2 + 1):
		var t := float(i) / float(TURNS * 2)
		var z: float = lerpf(FLANGE_Z, STUB_TIP, t)
		prof.append(Vector2(z, THREAD_ROOT if i % 2 == 0 else THREAD_CREST))
	prof.append(Vector2(STUB_TIP, THREAD_CREST))
	prof.append(Vector2(STUB_TIP + 0.0004, THREAD_CREST - 0.0006))   # lead-in chamfer
	prof.append(Vector2(STUB_TIP + 0.0004, BORE_R))  # rim, faces +Z
	prof.append(Vector2(BORE_FLOOR, BORE_R))         # bore wall, faces inward

	st.set_color(PlugMats.metal_vertex(Color(0.86, 0.87, 0.89)))
	_lathe_n(st, prof, RING)

	# --- the socket the centre conductor slides into -------------------------
	# Dark by MATERIAL, not by depth. These rooms light with
	# ambient_light_source = COLOR and no radiance map, so a bore renders as
	# brightly as its mouth — the same trap the other three generators document.
	st.set_color(PlugMats.socket_vertex())
	_lathe_n(st, PackedVector2Array([
		Vector2(BORE_FLOOR, SOCKET_R),
		Vector2(SOCKET_BACK, SOCKET_R),
		Vector2(SOCKET_BACK, 0.0),
	]), RING)

	_commit(st, mesh)
	_report(JACK_PATH, mesh)


# ── shared ────────────────────────────────────────────────────────────────────

## The whole connector as ONE surface on the shared connector material.
func _commit(st: SurfaceTool, mesh: ArrayMesh) -> void:
	st.generate_normals()
	var mat := PlugMats.connector()
	st.set_material(mat)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, mat)


func _report(path: String, mesh: ArrayMesh) -> void:
	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	var tris := 0
	for s in mesh.get_surface_count():
		tris += mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX].size() / 3
	print("[gen] %s err=%d  %.4f x %.4f x %.4f m  z %.4f..%.4f  tris %d  standoff %.4f" % [
		path, err, ab.size.x, ab.size.y, ab.size.z,
		ab.position.z, ab.end.z, tris, STANDOFF])


## Revolve a (z, radius) profile about Z with `sides` samples.
##
## gen_rca_plug.gd's _lathe with the ring count lifted out: sides = RING is that
## function verbatim, sides = 6 turns the same profile into a hex prism with the
## radius read as the circumradius. Copied rather than shared because each tool
## script keeps its own — only plug_materials.gd is common — and a generator that
## reaches into another one for geometry is a generator that breaks when the other
## is retuned.
##
## Facing follows the profile's direction: increasing z faces outward, decreasing z
## faces into the bore, and a constant-z step faces +Z when the radius shrinks and
## -Z when it grows. Order the points and the normals take care of themselves.
##
## NOTE for the older generators: gen_rca_plug.gd, gen_vga.gd, gen_trs.gd,
## gen_wii_av.gd and gen_ps2.gd all close their rings on TAU and carry the same seam.
## Not touched here — every one of them means re-baking a committed .res that other
## scenes already use.
func _lathe_n(st: SurfaceTool, profile: PackedVector2Array, sides: int) -> void:
	for s in range(profile.size() - 1):
		var z0: float = profile[s].x
		var r0: float = profile[s].y
		var z1: float = profile[s + 1].x
		var r1: float = profile[s + 1].y
		if is_equal_approx(z0, z1) and is_equal_approx(r0, r1):
			continue
		for i in sides:
			var a0: float = TAU * float(i) / float(sides)
			# MODULO, and it is load-bearing. Closing the ring on TAU rather than on
			# index 0 puts the last column's vertices at sin(TAU) = -2.4e-16 instead
			# of at 0 — a hair off the first column's, but far enough that
			# generate_normals() treats them as separate vertices and does not
			# average across the join. The result is a hard shading line running the
			# whole length of every lathed part, which is exactly what it looked
			# like: a seam down the side of the aerial socket.
			var a1: float = TAU * float((i + 1) % sides) / float(sides)
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

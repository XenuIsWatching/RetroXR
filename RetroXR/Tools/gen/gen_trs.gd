## Bakes a to-scale 3.5 mm TRS (stereo) connector PAIR to Scenes/Objects/trs_{plug,jack}.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_trs.gd
##
## Both halves in one file, as gen_vga.gd does and for the same reason: the fit is
## the point, and a number restated in a second file is one that can drift.
##
## ── Dimensions ───────────────────────────────────────────────────────────────
## SOURCED. Shaft diameter 3.5 mm and overall insertion length 15.0 mm, per
## Wikipedia's "Phone connector (audio)", which cites JEITA/EIAJ RC-5325A,
## JIS C 6560 and IEC 60130-8.
##
## DERIVED, and kept separate so nobody mistakes them for measured values. No free,
## machine-readable drawing gives the tip/ring/sleeve breakdown — the Switchcraft
## 35HD control drawing is an image-only PDF and the JEITA/JIS/IEC standards are
## paywalled. These are the standard 3-pole geometry that manufacturer drawings
## reproduce, and they sum to the 15.0 mm that IS sourced:
##
##                |<----------------- 15.0 overall ----------------->|
##   handle  ]====[ sleeve 6.6 ][i 0.7][ ring 3.0 ][i 0.7][ tip 4.0 )
##                                                            Ø3.5
##
## If a dimensioned drawing turns up, measure it the way the VGA one was measured —
## hole and edge positions off the image with Pillow, scaled from a known callout.
##
## ── Colour ───────────────────────────────────────────────────────────────────
## PC99 colour-codes analog line-level output LIME GREEN, and specifies it as
## Pantone 577C (the same table gives pink 701C for microphone and light blue 284C
## for line in). 577C converts to #A9C47F, RGB(169, 196, 127).
##
## That is a pale sage, and deliberately not pulled into the family of the muted
## purple and green gen_ps2_plug.gd uses — it is the spec value, asked for as the
## spec value. Expect it to read softer than the vivid green on a real motherboard,
## which is manufacturers approximating rather than matching.
##
## ── Contracts ────────────────────────────────────────────────────────────────
## Authored connector-on-+Z, cable-trailing--Z, which is VerletRope's plug_exit_axis
## and what RcaPlug._derive_cable_anchor reads. The MALE origin sits on the handle's
## front face and the FEMALE origin on the panel face, so the jack drops onto a port
## node with no transform of its own.
##
## NO Y-MIRROR, unlike the VGA pair. That correction exists only because a D-shell
## has a wide edge and snap seating composes a 180-about-X; a TRS is a solid of
## revolution and cannot be inserted the wrong way round.
##
## MATING: the female collar stands 2.0 mm proud of the panel and the male handle's
## front face stops against its rim, so a seated plug's origin ends up 2.0 mm proud.
## trs_port.tscn and every seat that copies it carry that number.
##
## Each half is ONE surface on the shared connector material
## (Shaders/connector.gdshader), the part carried in vertex colour:
##   green plastic (the plug's handle, the jack's collar ring)
##   chrome (the plug's tip/ring/sleeve, the jack's mounting bezel)
##   near-black (the plug's two insulator bands, the jack's bore)
## The green is the GLOSS class in its own colour rather than the tinted one:
## trs_cable.tscn's cord_colors carries this same lime, so the tint
## composite_cable.gd::_tint_plug sets on the instance has nothing to add, and a
## jack with no script would otherwise fall back to the shader's default yellow.
##
## The bore is dark by MATERIAL, not by depth — these rooms light with
## ambient_light_source = COLOR and no radiance map, so nothing is shadowed for
## being a few mm down a 3.6 mm hole. And every visible part of the jack sits at
## local z > 0, IN FRONT of the panel face: authoring the VGA insulator behind it
## put the tower's own back panel between the socket and the eye.
##
## Winding is load-bearing. _lathe emits in Godot's Plane(a,b,c) order, so an
## increasing-z profile segment faces outward, a decreasing-z one faces into a bore,
## and a constant-z step faces +Z when the radius shrinks. Order the points and the
## normals take care of themselves.
extends SceneTree

const PlugMats := preload("res://Tools/gen/plug_materials.gd")

const OUT_PLUG := "res://Scenes/Objects/cables/trs_plug.res"
const OUT_JACK := "res://Scenes/Objects/cables/trs_jack.res"

## 24, not the 16 the other connectors use. Every part of this pair is a solid of
## revolution and the jack is looked at square-on, so its silhouette IS a circle —
## at 16 the collar ring reads as a dodecagon. The whole pair is under 1.5k tris
## either way.
const RING := 24

## PC99 lime green, Pantone 577C -> #A9C47F.
const PC99_LIME := Color(0.663, 0.769, 0.498)

# --- the shaft: sourced diameter and overall length, derived segments ---------
const SHAFT_R := 0.00175         # Ø3.5, sourced
const Z_SHAFT_END := 0.0150      # overall insertion, sourced
const Z_SLEEVE_END := 0.0066
const Z_INS1_END := 0.0073
const Z_RING_END := 0.0103
const Z_INS2_END := 0.0110
const TIP_DOME := 0.0013         # the rounded nose, part of the 4.0 mm tip
const DOME_N := 4

# --- the male handle ---------------------------------------------------------
const HANDLE_R := 0.0040         # Ø8 moulded body
const Z_HANDLE_FACE := 0.0
const Z_RELIEF_END := -0.0200
const Z_CORD := -0.0320
## Meets the 4.5 mm cord controller_cable.tscn draws — a speaker lead is thin, so
## that is the rope this plug hangs off rather than the 8.3 mm A/V jacket.
const CORD_R := 0.00225
const RELIEF_RIBS := 6
const RELIEF_RIB_AMP := 0.00025

# --- the female jack ---------------------------------------------------------
const BORE_R := 0.0018           # Ø3.6 against a Ø3.5 shaft
const COLLAR_OR := 0.0045        # Ø9 green ring
const COLLAR_IR := 0.0026
## The male handle seats against this rim, so it IS the port's proud offset.
const Z_COLLAR_END := 0.0020
const Z_RECESS := 0.0014
## In FRONT of the panel face. A bore run back behind it shows the case's own
## back panel as a bright disc a millimetre down the hole — dark by material only
## works when the material is what you are looking at.
const Z_BORE_FLOOR := 0.0002
const BEZEL_OR := 0.0052         # the stamped mounting ring round the collar
const Z_BEZEL_END := 0.0006


func _init() -> void:
	_build_plug()
	_build_jack()
	quit()


# ── the male plug ────────────────────────────────────────────────────────────

func _build_plug() -> void:
	var mesh := ArrayMesh.new()

	# --- surface 0: the green moulded handle and its boot --------------------
	var prof := PackedVector2Array()
	prof.append(Vector2(Z_CORD, 0.0))              # back cap, faces -Z
	prof.append(Vector2(Z_CORD, CORD_R))
	# Ribbed strain relief swelling out to the body. Sampled three times a rib —
	# two points per rib gives back a sawtooth however many you use, which is the
	# lesson gen_rca_plug.gd's relief records.
	var steps := RELIEF_RIBS * 3
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var z: float = lerpf(Z_CORD, Z_RELIEF_END, t)
		var base: float = lerpf(CORD_R, HANDLE_R, t)
		var bump: float = 0.5 + 0.5 * sin(t * float(RELIEF_RIBS) * TAU - PI * 0.5)
		prof.append(Vector2(z, base + RELIEF_RIB_AMP * bump))
	prof.append(Vector2(Z_RELIEF_END, HANDLE_R))
	prof.append(Vector2(Z_HANDLE_FACE, HANDLE_R))
	# Flat front annulus down to the shaft — this face is what stops against the
	# jack's collar rim, and it is why the plug's ORIGIN is here.
	prof.append(Vector2(Z_HANDLE_FACE, SHAFT_R))
	# One SurfaceTool for the whole plug: each part is lathed after set_color()
	# with its class, and the lot commits as ONE surface on the shared connector
	# material. See Shaders/connector.gdshader for why.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(PlugMats.gloss_vertex(PC99_LIME))
	_lathe(st, prof)

	# --- tip, ring and sleeve ------------------------------------------------
	# Three bands at one diameter, butted against the insulators so no seam shows.
	# The sleeve is capped at z 0 facing -Z; that cap is inside the handle and
	# costs 16 triangles to never think about it again.
	st.set_color(PlugMats.chrome_vertex())
	_lathe(st, PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(0.0, SHAFT_R), Vector2(Z_SLEEVE_END, SHAFT_R)]))
	_lathe(st, PackedVector2Array([
		Vector2(Z_INS1_END, SHAFT_R), Vector2(Z_RING_END, SHAFT_R)]))
	var tip := PackedVector2Array([Vector2(Z_INS2_END, SHAFT_R)])
	var z_straight: float = Z_SHAFT_END - TIP_DOME
	tip.append(Vector2(z_straight, SHAFT_R))
	for i in range(1, DOME_N + 1):
		var a: float = PI * 0.5 * float(i) / float(DOME_N)
		tip.append(Vector2(z_straight + TIP_DOME * sin(a), SHAFT_R * cos(a)))
	_lathe(st, tip)

	# --- the two insulator bands ---------------------------------------------
	st.set_color(PlugMats.socket_vertex())
	_lathe(st, PackedVector2Array([
		Vector2(Z_SLEEVE_END, SHAFT_R), Vector2(Z_INS1_END, SHAFT_R)]))
	_lathe(st, PackedVector2Array([
		Vector2(Z_RING_END, SHAFT_R), Vector2(Z_INS2_END, SHAFT_R)]))

	_commit(st, mesh)
	_save(mesh, OUT_PLUG, true)


# ── the female jack ──────────────────────────────────────────────────────────

func _build_jack() -> void:
	var mesh := ArrayMesh.new()

	# --- the green collar ring -----------------------------------------------
	# The ring the whole request turns on: outside wall, front rim, and back down
	# the inside to where the dark insert takes over.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(PlugMats.gloss_vertex(PC99_LIME))
	_lathe(st, PackedVector2Array([
		Vector2(0.0, COLLAR_OR),
		Vector2(Z_COLLAR_END, COLLAR_OR),        # outside wall
		Vector2(Z_COLLAR_END, COLLAR_IR),        # front rim, faces +Z
		Vector2(Z_RECESS, COLLAR_IR),            # inside wall, faces inward
	]))

	# --- the stamped mounting bezel ------------------------------------------
	# A low ring round the collar's base. Open at the back: that face is against
	# the panel and closing it would only add triangles nobody can see.
	st.set_color(PlugMats.chrome_vertex())
	_lathe(st, PackedVector2Array([
		Vector2(0.0, BEZEL_OR),
		Vector2(Z_BEZEL_END, BEZEL_OR),
		Vector2(Z_BEZEL_END, COLLAR_OR),
	]))

	# --- the insert face and the bore ----------------------------------------
	st.set_color(PlugMats.socket_vertex())
	_lathe(st, PackedVector2Array([
		Vector2(Z_RECESS, COLLAR_IR),
		Vector2(Z_RECESS, BORE_R),               # insert face, faces +Z
		Vector2(Z_BORE_FLOOR, BORE_R),           # bore wall, faces inward
		Vector2(Z_BORE_FLOOR, 0.0),              # floor, faces +Z
	]))

	_commit(st, mesh)
	_save(mesh, OUT_JACK, false)


## The whole connector as ONE surface on the shared connector material.
func _commit(st: SurfaceTool, mesh: ArrayMesh) -> void:
	st.generate_normals()
	var mat := PlugMats.connector()
	st.set_material(mat)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, mat)


## Revolve a (z, radius) profile about the Z axis. gen_rca_plug.gd's, whose header
## documents how the profile's direction decides facing.
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


## Save, and REFUSE a bake whose frame is wrong.
##
## The +Z/-Z contract is not something anyone can eyeball once the mesh is baked: a
## mirrored plug seats backwards and trails its cord through the panel, which is a
## bug that shows up three files away. Tools/gen/extract_nes_plug.gd guards its imports
## the same way, and for the same reason.
func _save(mesh: ArrayMesh, path: String, want_cord: bool) -> void:
	var ab: AABB = mesh.get_aabb()
	if ab.end.z <= 0.0:
		push_error("[gen] %s REFUSING: connector must sit on +Z" % path)
		return
	if want_cord and ab.position.z >= 0.0:
		push_error("[gen] %s REFUSING: cable must trail -Z" % path)
		return
	var err := ResourceSaver.save(mesh, path)
	var tris := 0
	for s in mesh.get_surface_count():
		tris += mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX].size() / 3
	print("[gen] %s err=%d  %.4f x %.4f x %.4f m  z %.4f..%.4f  tris %d" % [
		path, err, ab.size.x, ab.size.y, ab.size.z,
		ab.position.z, ab.end.z, tris])

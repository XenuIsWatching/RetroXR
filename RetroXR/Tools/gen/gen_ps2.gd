## Bakes the to-scale PS/2 (mini-DIN 6) PAIR to Scenes/Objects/ps2_{plug,jack}_*.res.
##
## Run once, out of band — a connector's dimensions are a physical fact, not
## something to rebuild every load:
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_ps2.gd
##
## Replaces the generic cylinder plug on the keyboard and mouse, which was a
## 20 mm-diameter, 40 mm-long cone — twice the diameter of a real PS/2 connector
## and four times the shroud length. At arm's length in VR that reads as a garden
## hose rather than a keyboard lead.
##
## Dimensions are the mini-DIN 6 spec:
##   * metal shroud 9.5 mm outside diameter, 9.5 mm long, 0.4 mm wall
##   * 6 pins at 0.9 mm diameter, 7 mm long, recessed inside the shroud
##   * a plastic alignment key against the shroud's inner wall, which is what stops
##     the plug going in the wrong way round
##   * a 13 mm plastic barrel behind, 22 mm long, tapering to a strain relief
##
## PIN LAYOUT and KEY follow the mini-DIN 6 pinout drawing. The six pins ring a
## rectangular plastic key that stands in the CENTRE of the bore — 5 and 6 above
## it, 3 and 4 out at the sides, 1 and 2 below:
##
##       6   5
##     4  |K|  3
##       2   1
##
## Two earlier passes had this wrong: pins fanned evenly across the top arc, and
## the key laid flat against the inner wall like a DIN notch. On the real part the
## key is central and stands tall, and it is what the pins are arranged around.
##
## Numbering is the FEMALE socket's, so a male plug mirrors it left-to-right. The
## mirror is invisible here — every pin is the same brass cylinder — but it would
## matter if anything were ever labelled.
##
## Two colourways, per PC99 (1999, so period-legal for this room): purple for the
## keyboard, green for the mouse. That colour coding is also the only thing that
## tells the two leads apart at a glance once both are plugged in.
##
## Authored in the plug's own frame — connector on +Z, cable trailing -Z — which is
## the contract ControllerPlug.set_plug_mesh expects, so it needs no transform.
##
## Winding matters here: nothing is a primitive, and SurfaceTool.generate_normals()
## derives facing from vertex order alone. Godot's convention is the one Plane(a,b,c)
## uses — normal = (a-c).cross(a-b) — so every helper below emits in that order and
## the caps, rim and box faces each had to be checked against it individually.
extends SceneTree

const PlugMats := preload("res://Tools/gen/plug_materials.gd")

const OUT_DIR := "res://Scenes/Objects/cables/"

const SHROUD_OD := 0.0095
const SHROUD_WALL := 0.0004
const SHROUD_LEN := 0.0095
const PIN_DIA := 0.0009
const PIN_LEN := 0.007
const BARREL_DIA := 0.013
const BARREL_LEN := 0.022
const RELIEF_LEN := 0.012
## Just proud of the 4.5 mm cord controller_cable.tscn draws, which is also what a
## real PS/2 lead measures — so this is both the true dimension and a clean meeting
## with the rope.
const RELIEF_DIA := 0.005
## The contact rows and pair half-spans, off DETAIL D. Everything else on the face is
## derived from these, so a correction lands in one place — moving the middle row
## carries the key with it, because the key's bottom edge IS the middle row.
##
## The rows are EVENLY spaced 2.00 mm apart and centred on the bore axis, so the
## middle row sits at exactly y = 0 and the field is symmetric top to bottom.
##
## Two earlier passes had this wrong. The first read the stacked callouts down the
## right of DETAIL D as the row gaps and made them 1.60 and 2.40, which put the
## bottom row half again further from the middle than the top was. The second evened
## the pitch but left the top row on its 2.16 callout, which floated the whole field
## 0.16 mm above centre. Whatever 2.16, 1.60 and 2.40 dimension on that sheet, it is
## not the row pitch — 1.60 is a plausible contact-hole diameter, which would make
## the sockets here (1.30) undersized, but nothing says so and it is not being
## guessed at a third time.
const ROW_TOP := 0.00200
const ROW_MID := 0.00000
const ROW_BOT := -0.00200
const HALF_TOP := 0.00200      # 4.00 across
const HALF_MID := 0.00250      # 5.00 across
const HALF_BOT := 0.00100      # 2.00 across

## The key. Its WIDTH is the drawing's 1.40. Its height and position are NOT
## dimensioned on either sheet, so they are derived rather than guessed: the top edge
## sits level with the TOP of the top contacts, and the bottom edge at the CENTRE of
## the middle contacts. That puts it high on the face rather than centred on it,
## which is where the drawing shows it — between the top pair, not ringed by all six.
##
## Deriving it also fixes what centring it cost. Centred, the key's bottom corner ran
## at the bottom contacts, which is what forced its height down and still left only
## 0.21 mm to the female's socket opening. Sat where it belongs the nearest clearance
## is 0.55 mm, and the bottom contacts are no longer involved at all.
const KEY_W := 0.0014
const KEY_TOP := ROW_TOP + PIN_DIA * 0.5
const KEY_BOTTOM := ROW_MID
const KEY_H := KEY_TOP - KEY_BOTTOM
const KEY_Y := (KEY_TOP + KEY_BOTTOM) * 0.5

## Contact centres in the connector face, metres, in PS/2 numbering order.
##
## Off the manufacturer's DETAIL D (6 PIN FACE), all callouts +-0.13:
##   rows        evenly pitched 2.00 apart, middle row on the bore axis
##   side pair   5.00 across   (3, 4)
##   top pair    4.00 across   (5, 6)
##   bottom pair 2.00 across   (1, 2)
##
## Both layouts moved off what this file used to carry. Horizontally all three pairs
## shifted — the side pair in by 0.20 a side, the top pair OUT by 0.32, the bottom
## pair in by 0.25 — so the face is far wider at the top than it was. Vertically the
## rows are now evenly pitched and centred, where they used to run 1.62 and 2.41
## about a middle row 0.56 above the axis.
##
## Clearances, against the 4.35 mm bore wall and a 0.65 mm female socket radius: the
## contacts sit 2.24, 2.50 and 2.83 mm out from the axis, so the worst wall clearance
## is 0.87 mm at contacts 5 and 6. Contact 5 is also the one nearest the key — 0.85 mm
## from the male PIN, 0.55 mm from the wider female SOCKET OPENING — and the female
## slot's top corner sits 1.68 mm inside the bore wall.
##
## Numbering is the FEMALE socket's, so a male plug mirrors it left-to-right. The
## mirror costs nothing here because the set is symmetric about X — every contact has
## its partner — so one table serves both halves.
const PIN_XY: Array[Vector2] = [
	Vector2( HALF_BOT, ROW_BOT),   # 1  +DATA   below, right
	Vector2(-HALF_BOT, ROW_BOT),   # 2  n/c     below, left
	Vector2( HALF_MID, ROW_MID),   # 3  GND     side, right
	Vector2(-HALF_MID, ROW_MID),   # 4  Vcc     side, left
	Vector2( HALF_TOP, ROW_TOP),   # 5  +CLK    above, right
	Vector2(-HALF_TOP, ROW_TOP),   # 6  n/c     above, left
]

## 24, not 16. The plug is only ever seen end-on or in a fist, but the RECEPTACLE is
## looked at square-on while somebody lines a plug up with it, and at 16 its collar
## reads as a dodecagon. The whole pair is still under 1.5k tris.
const RING := 24


## The female half, in the same frame as the male: origin on the PANEL face, socket
## opening toward +Z.
##
## Every visible part sits at local z > 0, i.e. IN FRONT of the panel. That is not
## cosmetic — the tower's case is a solid box, and geometry authored behind its back
## face renders as a beige disc down the middle of the socket. Only depth that can be
## seen is modelled; the real part's bore runs 9 mm back and is simply not there.
const JACK_COLLAR_OD := 0.0130     # the drawing's 13.00 housing height, the round part
const JACK_COLLAR_ID := 0.0106
const JACK_SHROUD_OD := 0.0105
## Takes the male's 9.5 mm shroud with 0.1 mm a side.
const JACK_BORE_ID := 0.0097
const Z_COLLAR_END := 0.0020
const Z_SHROUD_END := 0.0050
const Z_INSULATOR := 0.0010
## Visible socket opening. The contact inside is 1.00 across against the male's
## 0.90 pin; neither is dimensioned on the drawing, and at 1.3 mm nobody in a headset
## is measuring it.
const SOCKET_DIA := 0.0013
const SOCKET_SEG := 10          # points round each socket rim, for the face mesh
## How far a socket and the key slot sink below the insulator face.
const WELL_DEPTH := 0.0011
## Slop between the female slot and the male key, so the slot is visibly the larger.
const KEY_FIT := 0.0002
## The keyway cut into the top of the shroud, which the drawing shows as a notch on
## the shell. Width and depth are eyeballed off it — it carries no callout.
const NOTCH_W := 0.0020
const NOTCH_D := 0.0012


func _init() -> void:
	_build("ps2_plug_keyboard.res", Color(0.42, 0.24, 0.58))   # PC99 purple
	_build("ps2_plug_mouse.res", Color(0.24, 0.52, 0.30))      # PC99 green
	_build_jack("ps2_jack_keyboard.res", Color(0.42, 0.24, 0.58))
	_build_jack("ps2_jack_mouse.res", Color(0.24, 0.52, 0.30))
	quit()


## The receptacle: coloured collar, metal shroud, and the contact face inside it.
func _build_jack(file_name: String, collar_tint: Color) -> void:
	var mesh := ArrayMesh.new()

	# --- surface 0: the PC99-coloured collar ---------------------------------
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_tube(st, JACK_COLLAR_OD * 0.5, JACK_COLLAR_OD * 0.5, 0.0, Z_COLLAR_END, false)
	_annulus(st, JACK_COLLAR_ID * 0.5, JACK_COLLAR_OD * 0.5, Z_COLLAR_END)
	_tube(st, JACK_COLLAR_ID * 0.5, JACK_COLLAR_ID * 0.5, Z_COLLAR_END, 0.0, false)
	st.generate_normals()
	var m_collar := PlugMats.plastic(collar_tint)
	st.set_material(m_collar)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, m_collar)

	# --- surface 1: the metal shroud -----------------------------------------
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_tube(st, JACK_SHROUD_OD * 0.5, JACK_SHROUD_OD * 0.5, 0.0, Z_SHROUD_END, false)
	_annulus(st, JACK_BORE_ID * 0.5, JACK_SHROUD_OD * 0.5, Z_SHROUD_END)
	# Bore, wound inward so it faces the eye looking down the socket.
	_tube(st, JACK_BORE_ID * 0.5, JACK_BORE_ID * 0.5, Z_SHROUD_END, Z_INSULATOR, false)
	st.generate_normals()
	var m_shell := PlugMats.chrome()
	st.set_material(m_shell)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(1, m_shell)

	# --- surface 2: the insulator, with the sockets OPEN through it -----------
	# DARK, and the same family as the male's insert and key. It went the other way
	# first — a warm off-white at (0.80, 0.78, 0.72), which sat within a few percent
	# of the case beige and read as the panel showing through a hole in the connector,
	# and was then pushed to a cool near-white to get away from the beige. That fixed
	# the wrong thing. A PS/2 receptacle is a dark cavity, and a white one beside a
	# male whose bore is black made the pair look like two different connectors.
	#
	# 0.20 against the sockets' 0.035 is what keeps the holes legible: dark enough to
	# read as one dark face at arm's length, far enough off the wells that they are
	# still obviously holes in it.
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_holed_face(st, JACK_BORE_ID * 0.5, Z_INSULATOR)
	st.generate_normals()
	var m_ins := PlugMats.plastic(Color(0.20, 0.20, 0.21))
	st.set_material(m_ins)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(2, m_ins)

	# --- surface 3: the wells behind those holes, and the shell keyway --------
	# REAL recesses. These began as flat dark discs laid 0.15 mm PROUD of a solid
	# face, on the argument that at 1.3 mm a disc and a bore come to the same few
	# pixels. That was wrong in a way that mattered: a disc standing off a surface
	# catches the key light exactly as a pin does, and the key slot as a key TAB, so
	# the receptacle read as a second PLUG. A socket has to actually be open.
	var z_floor: float = Z_INSULATOR - WELL_DEPTH
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for xy in PIN_XY:
		var at := Vector3(xy.x, xy.y, 0.0)
		_tube(st, SOCKET_DIA * 0.5, SOCKET_DIA * 0.5, Z_INSULATOR, z_floor, false, at)
		_disc(st, SOCKET_DIA * 0.5, z_floor, at)
	_rect_well(st, KEY_W + KEY_FIT, KEY_H + KEY_FIT, Z_INSULATOR, z_floor,
		Vector3(0.0, KEY_Y, 0.0))
	# The keyway, sunk into the shell's front rim at the TOP where the drawing shows
	# it — a notch cut through the shroud, not a tab sitting on it.
	_rect_well(st, NOTCH_W, (JACK_SHROUD_OD - JACK_BORE_ID) * 0.5 + 0.0005,
		Z_SHROUD_END, Z_SHROUD_END - NOTCH_D,
		Vector3(0.0, (JACK_BORE_ID + JACK_SHROUD_OD) * 0.25, 0.0))
	st.generate_normals()
	var m_dark := PlugMats.metal(Color(0.035, 0.035, 0.04), 0.55)
	st.set_material(m_dark)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(3, m_dark)

	var path := OUT_DIR + file_name
	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	var tris := 0
	for i in mesh.get_surface_count():
		tris += mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX].size() / 3
	print("[gen] %s  err=%d  %.4f x %.4f x %.4f m  z %.4f..%.4f  tris %d" % [
		path, err, ab.size.x, ab.size.y, ab.size.z,
		ab.position.z, ab.end.z, tris])


## Flat disc at z facing +Z.
func _disc(st: SurfaceTool, r: float, z: float, offset := Vector3.ZERO) -> void:
	var c := offset + Vector3(0, 0, z)
	for i in RING:
		var a0: float = TAU * float(i) / float(RING)
		var a1: float = TAU * float(i + 1) / float(RING)
		var p0 := offset + Vector3(cos(a0) * r, sin(a0) * r, z)
		var p1 := offset + Vector3(cos(a1) * r, sin(a1) * r, z)
		st.add_vertex(c); st.add_vertex(p1); st.add_vertex(p0)


## Flat rectangle at z facing +Z.
func _rect(st: SurfaceTool, w: float, h: float, z: float,
		offset := Vector3.ZERO) -> void:
	var a := offset + Vector3( w * 0.5,  h * 0.5, z)
	var b := offset + Vector3(-w * 0.5,  h * 0.5, z)
	var c := offset + Vector3(-w * 0.5, -h * 0.5, z)
	var d := offset + Vector3( w * 0.5, -h * 0.5, z)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(b)
	st.add_vertex(a); st.add_vertex(d); st.add_vertex(c)


## A rectangular recess: four walls facing inward, and a floor facing +Z.
func _rect_well(st: SurfaceTool, w: float, h: float, z_top: float, z_floor: float,
		offset := Vector3.ZERO) -> void:
	var loop := [
		Vector2( w * 0.5,  h * 0.5), Vector2(-w * 0.5,  h * 0.5),
		Vector2(-w * 0.5, -h * 0.5), Vector2( w * 0.5, -h * 0.5)]
	for i in 4:
		var u: Vector2 = loop[i]
		var v: Vector2 = loop[(i + 1) % 4]
		# z DECREASING, which is what turns the wall inward — the same rule every
		# lathe and tube in this file follows.
		var p00 := offset + Vector3(u.x, u.y, z_top)
		var p10 := offset + Vector3(v.x, v.y, z_top)
		var p01 := offset + Vector3(u.x, u.y, z_floor)
		var p11 := offset + Vector3(v.x, v.y, z_floor)
		st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
		st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)
	_rect(st, w, h, z_floor, offset)


## The insulator face with the six sockets and the key slot OPEN through it.
##
## Delaunay over a point set — the bore rim, each socket rim, and the slot corners —
## then throw away every triangle whose centroid lands in a hole or outside the bore.
## GDScript ships no triangulator that takes holes directly (Geometry2D.triangulate_
## polygon is ear clipping, one contour only), and this is exactly the case where
## discard-by-centroid is sound: the bore is convex so the hull Delaunay covers it
## exactly, and no wanted triangle can span a hole because every hole's rim is in the
## point set.
##
## Winding: CLOCKWISE faces +Z under the Plane(a, b, c) convention this file uses,
## and Delaunay guarantees nothing either way, so each triangle is flipped to suit.
func _holed_face(st: SurfaceTool, bore_r: float, z: float) -> void:
	var pts := PackedVector2Array()
	for i in RING:
		var a: float = TAU * float(i) / float(RING)
		pts.append(Vector2(cos(a), sin(a)) * bore_r)
	for xy in PIN_XY:
		for i in SOCKET_SEG:
			var a: float = TAU * float(i) / float(SOCKET_SEG)
			pts.append(xy + Vector2(cos(a), sin(a)) * (SOCKET_DIA * 0.5))
	var kw: float = (KEY_W + KEY_FIT) * 0.5
	var kh: float = (KEY_H + KEY_FIT) * 0.5
	for sx in [-1.0, 0.0, 1.0]:
		for sy in [-1.0, 0.0, 1.0]:
			if is_zero_approx(sx) and is_zero_approx(sy):
				continue
			pts.append(Vector2(sx * kw, KEY_Y + sy * kh))
	var tri: PackedInt32Array = Geometry2D.triangulate_delaunay(pts)
	for t in range(0, tri.size(), 3):
		var a: Vector2 = pts[tri[t]]
		var b: Vector2 = pts[tri[t + 1]]
		var c: Vector2 = pts[tri[t + 2]]
		var cen: Vector2 = (a + b + c) / 3.0
		if cen.length() > bore_r or _in_hole(cen):
			continue
		if (b - a).cross(c - a) > 0.0:
			var swap: Vector2 = b
			b = c
			c = swap
		st.add_vertex(Vector3(a.x, a.y, z))
		st.add_vertex(Vector3(b.x, b.y, z))
		st.add_vertex(Vector3(c.x, c.y, z))


func _in_hole(p: Vector2) -> bool:
	for xy in PIN_XY:
		if p.distance_to(xy) < SOCKET_DIA * 0.5:
			return true
	return absf(p.x) < (KEY_W + KEY_FIT) * 0.5 \
		and absf(p.y - KEY_Y) < (KEY_H + KEY_FIT) * 0.5


func _build(file_name: String, barrel_tint: Color) -> void:
	var mesh := ArrayMesh.new()
	var r_out := SHROUD_OD * 0.5
	var r_in := r_out - SHROUD_WALL

	# --- surface 0: plastic barrel, strain relief, alignment key -------------
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# The shroud occupies z 0..SHROUD_LEN, so the barrel runs from 0 back to
	# -BARREL_LEN and the relief tapers back from there to the cable.
	_tube(st, BARREL_DIA * 0.5, BARREL_DIA * 0.5, -BARREL_LEN, 0.0, true)
	_tube(st, RELIEF_DIA * 0.5, BARREL_DIA * 0.5, -BARREL_LEN - RELIEF_LEN, -BARREL_LEN, true)
	st.generate_normals()
	var m_barrel := PlugMats.plastic(barrel_tint)
	st.set_material(m_barrel)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, m_barrel)

	# --- surface 1: metal shroud --------------------------------------------
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_tube(st, r_out, r_out, 0.0, SHROUD_LEN, false)      # outside wall
	_tube(st, r_in, r_in, SHROUD_LEN, 0.0, false)        # inside wall, wound inward
	_annulus(st, r_in, r_out, SHROUD_LEN)                # rim at the open end
	st.generate_normals()
	var m_metal := PlugMats.chrome()
	st.set_material(m_metal)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(1, m_metal)

	# --- surface 2: pins -----------------------------------------------------
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for xy in PIN_XY:
		_tube(st, PIN_DIA * 0.5, PIN_DIA * 0.5, 0.0, PIN_LEN, true,
			Vector3(xy.x, xy.y, 0.0))
	st.generate_normals()
	var m_pin := PlugMats.brass()
	st.set_material(m_pin)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(2, m_pin)

	# --- surface 3: the insert the pins stand in, and the key ----------------
	# Without this you look straight down the shroud into the coloured barrel, and
	# the key — moulded in the barrel's own colour — disappears into it.
	#
	# BLACK, and 0.4 mm forward of z 0. Both matter. The barrel is a CAPPED tube, so
	# it lays a coloured disc across z 0 exactly where this one sat: two coplanar
	# faces, and the purple won the depth fight in patches. Pulling the insert
	# forward settles it, and black is what stops the eye reading the bore as a
	# window onto the inside of the plug body.
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_disc(st, r_in, 0.0004)
	st.generate_normals()
	var m_insert := PlugMats.plastic(Color(0.055, 0.055, 0.06))
	st.set_material(m_insert)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(3, m_insert)

	# --- surface 4: the alignment key ----------------------------------------
	# Its own surface only so it can be a shade off the insert. On the real part both
	# are one black moulding and the key is genuinely hard to pick out — but this is
	# the feature a player lines the plug up ON, and against a black bore a black tab
	# showed as nothing but a lit top edge. Dark enough to still read as the same
	# piece of plastic, light enough to have a silhouette.
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# The key stands in the CENTRE of the bore, with the pins ringing it. Not a notch
	# in the wall.
	_box(st, KEY_W, KEY_H, SHROUD_LEN * 0.62,
		Vector3(0.0, KEY_Y, SHROUD_LEN * 0.31))
	st.generate_normals()
	var m_key := PlugMats.plastic(Color(0.22, 0.22, 0.23))
	st.set_material(m_key)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(4, m_key)

	var path := OUT_DIR + file_name
	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	print("[gen] %s  err=%d  size %.4f x %.4f x %.4f m  z %.4f..%.4f" % [
		path, err, ab.size.x, ab.size.y, ab.size.z, ab.position.z, ab.end.z])


## Tube along +Z between z0 and z1, radius r0 at z0 tapering to r1 at z1.
## Wound so the outside faces out when z1 > z0 — pass them reversed for a bore.
func _tube(st: SurfaceTool, r0: float, r1: float, z0: float, z1: float,
		capped: bool, offset := Vector3.ZERO) -> void:
	for i in RING:
		var a0: float = TAU * float(i) / float(RING)
		var a1: float = TAU * float(i + 1) / float(RING)
		var p00 := offset + Vector3(cos(a0) * r0, sin(a0) * r0, z0)
		var p10 := offset + Vector3(cos(a1) * r0, sin(a1) * r0, z0)
		var p01 := offset + Vector3(cos(a0) * r1, sin(a0) * r1, z1)
		var p11 := offset + Vector3(cos(a1) * r1, sin(a1) * r1, z1)
		st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
		st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)
		if capped:
			var c0 := offset + Vector3(0, 0, z0)
			var c1 := offset + Vector3(0, 0, z1)
			st.add_vertex(c0); st.add_vertex(p00); st.add_vertex(p10)
			st.add_vertex(c1); st.add_vertex(p11); st.add_vertex(p01)


## Flat ring at z facing +Z, from r_in to r_out — the shroud's front rim.
func _annulus(st: SurfaceTool, r_in: float, r_out: float, z: float) -> void:
	for i in RING:
		var a0: float = TAU * float(i) / float(RING)
		var a1: float = TAU * float(i + 1) / float(RING)
		var i0 := Vector3(cos(a0) * r_in, sin(a0) * r_in, z)
		var i1 := Vector3(cos(a1) * r_in, sin(a1) * r_in, z)
		var o0 := Vector3(cos(a0) * r_out, sin(a0) * r_out, z)
		var o1 := Vector3(cos(a1) * r_out, sin(a1) * r_out, z)
		st.add_vertex(i0); st.add_vertex(o1); st.add_vertex(o0)
		st.add_vertex(i0); st.add_vertex(i1); st.add_vertex(o1)


func _box(st: SurfaceTool, sx: float, sy: float, sz: float, at: Vector3) -> void:
	var h := Vector3(sx, sy, sz) * 0.5
	var v: Array[Vector3] = []
	for i in 8:
		v.append(at + Vector3(
			h.x if (i & 1) else -h.x,
			h.y if (i & 2) else -h.y,
			h.z if (i & 4) else -h.z))
	var faces := [[0,2,3,1], [4,5,7,6], [0,1,5,4], [2,6,7,3], [0,4,6,2], [1,3,7,5]]
	for f in faces:
		st.add_vertex(v[f[0]]); st.add_vertex(v[f[3]]); st.add_vertex(v[f[2]])
		st.add_vertex(v[f[0]]); st.add_vertex(v[f[2]]); st.add_vertex(v[f[1]])

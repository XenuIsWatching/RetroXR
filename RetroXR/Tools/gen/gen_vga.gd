## Bakes a to-scale VGA (DE-15HD) connector PAIR to Scenes/Objects/vga_{plug,jack}.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_vga.gd
##
## Both halves live in one file, unlike the RCA pair, because the fit is the whole
## point: gen_rca_jack.gd has to restate the plug's collar and pin diameters in its
## header to stay in sync with gen_rca_plug.gd, and a restated number is one that can
## drift. Here the male shell and the female bore come off the same constant.
##
## ── Dimensions ───────────────────────────────────────────────────────────────
## MEASURED off the supplied dimensioned drawing, which resolves to a uniform
## 7.208 px/mm; every callout closes within a pixel of its measured value:
##
##   flange              30.8 x 12.6 mm
##   D-shell opening     16.33 x 7.9 mm
##   thumbscrews         25.0 mm centres, 2-M2.5
##   contact columns     2.29 mm pitch
##   contact rows        1.98 mm pitch (the drawing calls out 3.96 across all three)
##
## The CONTACT FIELD is the part worth getting right, and it was measured hole by
## hole rather than recalled. Rows of 5/5/5; rows 1 and 3 are ALIGNED and centred on
## the flange, and row 2 is offset by exactly half a column pitch toward +x:
##
##     o   o   o   o   o        row 1   x = -2P .. +2P
##       o   o   o   o   o      row 2   x = -1.5P .. +2.5P
##     o   o   o   o   o        row 3   x = -2P .. +2P
##
## So the field overhangs half a pitch to the right and is asymmetric by 1.145 mm.
## That is what the drawing shows and what the standard 1-5/6-10/11-15 pinout diagram
## shows, and it is why the shell has to be a trapezoid: at the bottom-right the
## outermost contact of row 2 clears the sloping wall by a tenth of a millimetre.
##
## DERIVED from the DE-15HD standard, because the drawing does not give them — kept
## separate so nobody mistakes them for measured values:
##
##   shell wall 0.4 mm, sidewall taper ~10 deg (bottom edge 2.72 mm narrower)
##   male pin 1.0 mm across, female hole 1.4 mm
##   male shell 8.4 mm forward of the hood face
##   hood 30 x 16 x 48 mm including the strain relief
##   cable 7.5 mm — a shielded VGA lead is nearly double the 4.4 mm RCA cord
##
## ── Contracts ────────────────────────────────────────────────────────────────
## Authored connector-on-+Z, cable-trailing--Z, which is VerletRope's plug_exit_axis
## and what RcaPlug._derive_cable_anchor reads. The MALE origin sits on the hood's
## front face and the FEMALE origin on the flange face, so the jack drops onto a port
## node with no transform of its own — gen_rca_jack.gd's rule.
##
## MATING, and every one of these follows from the next:
##   * the female shell stands 7.5 mm proud of its flange
##   * its insulator sits 5.9 mm down that bore
##   * the male shell is 5.9 mm long, so it bottoms out on that insulator
##   * the male's pins run 0.8 mm further and enter the 1.4 mm bores
## A seated plug's origin therefore ends up 7.5 mm proud of the panel — this
## connector's equivalent of the RCA pair's 10 mm. vga_port.tscn and every seat
## that copies it carry that number; use the RCA one and the plug floats.
##
## Surface order is public API — composite_cable.gd::_tint_plug recolours surface 0:
##   0 = plastic (blue hood / blue insulator)
##   1 = metal (D-shell, flange, thumbscrews)
##   2 = brass pins (male) / the dark contact bores (female)
##
## The 15 bores are dark by MATERIAL, not by depth. These rooms light with
## ambient_light_source = COLOR and no radiance map, so nothing is shadowed for being
## 4 mm down a 1.4 mm hole — given the insulator's own material a bore renders as
## bright as the face around it and the socket loses its holes entirely. Same trap
## gen_rca_jack.gd documents.
##
## Winding is load-bearing: generate_normals() derives facing from vertex order
## alone. Every helper below emits in Godot's Plane(a,b,c) order — normal =
## (a-c).cross(a-b) — so a loft with z increasing faces OUTWARD and one with z
## decreasing faces into a bore. Pass the z values reversed for an inside wall,
## exactly as gen_ps2_plug.gd does with _tube.
extends SceneTree

const PlugMats := preload("res://Tools/gen/plug_materials.gd")

const OUT_PLUG := "res://Scenes/Objects/cables/vga_plug.res"
const OUT_JACK := "res://Scenes/Objects/cables/vga_jack.res"

# --- measured off the drawing ------------------------------------------------
const FLANGE_W := 0.0308
const FLANGE_H := 0.0126
const SCREW_PITCH := 0.0250
const COL_PITCH := 0.00229
const ROW_PITCH := 0.00198
const BORE_W := 0.01633          # D-shell opening, WIDE (top) edge
const BORE_H := 0.0079

# --- derived from the DE-15HD standard ---------------------------------------
const BORE_W_BOT := 0.01361      # 10 deg sidewall over 7.9 mm of height
const SHELL_WALL := 0.0004
const CORNER_R := 0.0008
const MALE_CLEAR := 0.00012      # sliding fit: male shell inside the female bore
const PIN_R := 0.0005
const HOLE_R := 0.0007

## PC99's blue, the sibling of the keyboard purple and mouse green in gen_ps2_plug.gd.
## Muted into their family rather than taken at full saturation — a pure PC99 blue
## reads as cartoon beside them and beside the room's dusk palette.
const VGA_BLUE := Color(0.16, 0.26, 0.62)

const RING := 16
const RING_PIN := 12             # 1.0-1.4 mm parts; 12 is already generous
const ARC := 4                   # samples per filleted corner -> 20 points a loop
const CELL_ARC := 3              # samples per side of a contact cell -> 12 a ring

# --- male: hood, shell, pins, thumbscrews ------------------------------------
const HOOD_W := 0.030
const HOOD_H := 0.016
## A moulded hood is a flat-faced block with a broken edge, not a pillow. 2.5 mm on
## a 16 mm section rounded it away almost entirely.
const HOOD_R := 0.0016
const MID_W := 0.014
const MID_R := 0.007             # == MID_W/2, so the section is already round here
const CORD_R := 0.00375
const RELIEF_RIBS := 7
const RELIEF_RIB_AMP := 0.0004

const Z_HOOD_FACE := 0.0
const Z_HOOD_STEP := -0.019
const Z_HOOD_TAPER := -0.032
const Z_CORD := -0.050
const Z_INSERT_FACE := 0.0012
const Z_PIN_END := 0.0067
const Z_SHELL_END := 0.0059

const SCREW_X := 0.0125          # half of the 25 mm centres
const SCREW_R := 0.00125         # M2.5
const Z_SCREW_TIP := 0.0045
const KNOB_R := 0.0045
const Z_KNOB_BACK := -0.0135
const Z_KNOB_FRONT := -0.0020
const KNOB_RIBS := 10
const KNOB_RIB_AMP := 0.00035

# --- female: flange, shell, insulator, bores ---------------------------------
const Z_PANEL := 0.0
const Z_FLANGE_END := 0.0012
## The male hood face seats against this rim, so it IS the port's proud offset —
## vga_port.tscn and every seat that copies it carry the same 7.5 mm.
const Z_JACK_SHELL_END := 0.0075
## Everything a player can see is at local z > 0, i.e. IN FRONT of the flange face.
## That is not cosmetic. A panel-mount socket sits on a solid panel, and with the
## insulator authored 2 mm BEHIND the flange the case's own back face landed between
## it and the eye: the socket rendered as a blank beige rectangle in a chrome frame,
## with no blue and no holes. Only the shell's rear tail is allowed behind the
## flange, and that is buried in the case where nothing looks at it.
const Z_JACK_INSERT := 0.0016
const Z_BORE_FLOOR := 0.0002
const Z_JACK_BACK := -0.0055
const BOSS_R := 0.00275
const Z_BOSS_END := 0.0022


func _init() -> void:
	_build_plug()
	_build_jack()
	quit()


## Contact centres in the connector face, metres, relative to the shell centre.
##
## Computed from the two measured pitches rather than written out as fifteen
## literals: the layout IS the two pitches plus the half-pitch stagger on row 2, and
## a table would only be a place for one of them to be mistyped.
##
## Clearances, against the trapezoid's sloping wall and a 0.7 mm hole radius: at
## y -1.98 the bore's half-width is 6.97 mm and row 2's outermost contact reaches
## 5.73 mm, so its edge clears the wall by 0.54 mm. Row 1 and 3's outermost reach
## 4.58 mm against a half-width of 8.00 mm.
func _contacts() -> Array:
	var out: Array = []
	for row in 3:
		var y: float = (1.0 - float(row)) * ROW_PITCH        # row 1 on top
		var stagger: float = COL_PITCH * 0.5 if row == 1 else 0.0
		for col in 5:
			out.append(Vector2((float(col) - 2.0) * COL_PITCH + stagger, y))
	return out


# ── the male plug ────────────────────────────────────────────────────────────

func _build_plug() -> void:
	var mesh := ArrayMesh.new()

	var sh_out := _d_loop(BORE_W - 2.0 * MALE_CLEAR, BORE_W_BOT - 2.0 * MALE_CLEAR,
		BORE_H - 2.0 * MALE_CLEAR)
	var sh_in := _d_loop(BORE_W - 2.0 * MALE_CLEAR - 2.0 * SHELL_WALL,
		BORE_W_BOT - 2.0 * MALE_CLEAR - 2.0 * SHELL_WALL,
		BORE_H - 2.0 * MALE_CLEAR - 2.0 * SHELL_WALL)

	# --- surface 0: blue hood, strain relief, insert, thumbscrew knobs --------
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var l_front := _rrect_loop(HOOD_W, HOOD_H, HOOD_R)
	var l_mid := _rrect_loop(MID_W, MID_W, MID_R)
	var l_cord := _rrect_loop(CORD_R * 2.0, CORD_R * 2.0, CORD_R)
	# Front block, a shoulder back to a round section, then the boot. The boot is
	# RIBBED rather than a plain cone: a moulded strain relief is a stack of shallow
	# rings, and the first pass read as a rocket nozzle without them. Sampled three
	# times a rib — two points per rib gives back a sawtooth however many you use,
	# which is the lesson gen_rca_plug.gd's relief records.
	_loft(st, l_front, Z_HOOD_STEP, l_front, Z_HOOD_FACE)
	_loft(st, l_mid, Z_HOOD_TAPER, l_front, Z_HOOD_STEP)
	var steps := RELIEF_RIBS * 3
	var prev := l_mid
	var prev_z := Z_HOOD_TAPER
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var z: float = lerpf(Z_HOOD_TAPER, Z_CORD, t)
		var base: float = lerpf(MID_R, CORD_R, t)
		var bump: float = 0.5 + 0.5 * sin(t * float(RELIEF_RIBS) * TAU - PI * 0.5)
		var rr: float = base + RELIEF_RIB_AMP * bump
		var l := _rrect_loop(rr * 2.0, rr * 2.0, rr)
		_loft(st, l, z, prev, prev_z)
		prev = l
		prev_z = z
	# Front face: a band from the hood's edge in to where the metal shell emerges.
	_band(st, sh_out, l_front, Z_HOOD_FACE, true)
	# Back face, against the cord. The rope tube is drawn at exactly CORD_R so this
	# is covered; no blind socket is needed, unlike the RCA plug whose relief has to
	# meet cords of two different diameters.
	_cap(st, l_cord, Z_CORD, false)
	# The insert the pins stand in, filling the shell's bore.
	var l_ins := _d_loop(BORE_W - 2.0 * MALE_CLEAR - 2.0 * SHELL_WALL - 0.0001,
		BORE_W_BOT - 2.0 * MALE_CLEAR - 2.0 * SHELL_WALL - 0.0001,
		BORE_H - 2.0 * MALE_CLEAR - 2.0 * SHELL_WALL - 0.0001)
	_loft(st, l_ins, Z_HOOD_FACE, l_ins, Z_INSERT_FACE)
	_cap(st, l_ins, Z_INSERT_FACE, true)
	# Knurled thumbscrew knobs, blue like the hood — the ribbed grips on the real
	# lead are moulded plastic, and only the shank that reaches the panel is metal.
	for sx in [-SCREW_X, SCREW_X]:
		_lathe(st, _knob_profile(), Vector3(sx, 0.0, 0.0))
	st.generate_normals()
	var m_body := PlugMats.plastic(VGA_BLUE)
	st.set_material(m_body)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, m_body)

	# --- surface 1: D-shell and the thumbscrew shanks ------------------------
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_loft(st, sh_out, Z_HOOD_FACE, sh_out, Z_SHELL_END)      # outside wall
	_loft(st, sh_in, Z_SHELL_END, sh_in, Z_HOOD_FACE)        # bore, wound inward
	_band(st, sh_in, sh_out, Z_SHELL_END, true)              # rim at the open end
	for sx in [-SCREW_X, SCREW_X]:
		_tube(st, SCREW_R, SCREW_R, Z_KNOB_FRONT, Z_SCREW_TIP, true,
			Vector3(sx, 0.0, 0.0), RING_PIN)
	st.generate_normals()
	var m_metal := PlugMats.chrome()
	st.set_material(m_metal)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(1, m_metal)

	# --- surface 2: the 15 pins ----------------------------------------------
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for xy: Vector2 in _contacts():
		_tube(st, PIN_R, PIN_R, Z_INSERT_FACE, Z_PIN_END, true,
			Vector3(xy.x, xy.y, 0.0), RING_PIN)
	st.generate_normals()
	var m_pin := PlugMats.brass()
	st.set_material(m_pin)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(2, m_pin)

	_save(mesh, OUT_PLUG, true)


## The knurled grip, as a (z, radius) profile revolved about the knob's own axis.
## Ribs sampled off a sine three times each — two points per rib gives back a
## sawtooth however many you use, which is the lesson gen_rca_plug.gd's relief
## records.
func _knob_profile() -> PackedVector2Array:
	var p := PackedVector2Array()
	p.append(Vector2(Z_KNOB_BACK, 0.0))
	p.append(Vector2(Z_KNOB_BACK, KNOB_R - KNOB_RIB_AMP))
	var steps := KNOB_RIBS * 3
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var z: float = lerpf(Z_KNOB_BACK, Z_KNOB_FRONT, t)
		var bump: float = 0.5 + 0.5 * sin(t * float(KNOB_RIBS) * TAU - PI * 0.5)
		p.append(Vector2(z, KNOB_R - KNOB_RIB_AMP + KNOB_RIB_AMP * bump))
	p.append(Vector2(Z_KNOB_FRONT, KNOB_R - KNOB_RIB_AMP))
	p.append(Vector2(Z_KNOB_FRONT, 0.0))
	return p


# ── the female jack ──────────────────────────────────────────────────────────
#
# THE D IS AUTHORED UPSIDE DOWN — wide edge on -Y — and it has to be.
#
# MEASURED, not derived. A snap zone seats a pickable so the pickable's grab point
# lands on the zone, and SnapGrabPoint carries its own 180-about-X; the composition
# is plug_basis = zone_basis * Rx(180), while the jack is a plain child and gets
# zone_basis itself. Seat a plug in a back-panel port and the two come out related
# by Rx(180), which negates Y: with both meshes authored wide-edge-up the socket's
# D points down in the room while the plug's points up, and the pair does not key.
#
# Physical reality relates a mated pair by Ry(180) — turn one to face the other and
# up stays up. This project's convention differs from that by a turn about Z, which
# is invisible on a phono plug and very visible on a D-shell. Since Y-negation is a
# reflection it cannot be put back with any rotation of the port node, so it lives
# in the mesh.
#
# Only the shell needs it. The flange and the jackscrew bosses are symmetric about
# Y, and so is the CONTACT SET: negating Y swaps rows 1 and 3, which carry the same
# five x positions, and leaves the staggered middle row where it was. That is also
# why the contacts already mated correctly while the shell did not.
#
# A socket mounted on some other face wants its own correction again — the same
# caveat pc_tower.tscn records for its port seats, and for the same reason.

func _build_jack() -> void:
	var mesh := ArrayMesh.new()

	# WIDE EDGE DOWN, and that is not a mistake — see the note above _build_jack.
	# The arguments are (top, bottom), so passing the narrow width first is what
	# turns the D over.
	var bore := _d_loop(BORE_W_BOT, BORE_W, BORE_H)
	var sh_out := _d_loop(BORE_W_BOT + 2.0 * SHELL_WALL, BORE_W + 2.0 * SHELL_WALL,
		BORE_H + 2.0 * SHELL_WALL)
	var flange := _rrect_loop(FLANGE_W, FLANGE_H, 0.0015)

	# --- surface 0: the blue insulator face, holes and all -------------------
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_insulator_face(st, bore, Z_JACK_INSERT)
	st.generate_normals()
	var m_body := PlugMats.plastic(VGA_BLUE)
	st.set_material(m_body)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, m_body)

	# --- surface 1: flange, shell, thumbscrew bosses -------------------------
	# Open at the back, as the RCA jack is: that end is against the panel and
	# closing it would only add triangles nobody can see.
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_loft(st, flange, Z_PANEL, flange, Z_FLANGE_END)          # flange edge
	_band(st, sh_out, flange, Z_FLANGE_END, true)             # flange face
	_loft(st, sh_out, Z_JACK_BACK, sh_out, Z_JACK_SHELL_END)  # shell outside
	_loft(st, bore, Z_JACK_SHELL_END, bore, Z_JACK_INSERT)    # bore, wound inward
	_band(st, bore, sh_out, Z_JACK_SHELL_END, true)           # shell rim
	# The jackscrew bosses the plug's thumbscrews thread into. HEX, as the drawing
	# shows them and as the real part is — six segments buy the silhouette, which is
	# the part anyone reads at this size. Bored, so they are something a screw goes
	# into rather than two studs.
	for sx in [-SCREW_X, SCREW_X]:
		var at := Vector3(sx, 0.0, 0.0)
		_tube(st, BOSS_R, BOSS_R, Z_PANEL, Z_BOSS_END, false, at, 6)
		_annulus(st, SCREW_R + 0.0002, BOSS_R, Z_BOSS_END, at, 6)
	st.generate_normals()
	var m_metal := PlugMats.chrome()
	st.set_material(m_metal)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(1, m_metal)

	# --- surface 2: the 15 contact bores, and the screw bores ---------------
	# Nearly black and rough, which is what a recessed contact looks like anyway —
	# see the header. Kept off surface 0 so recolouring an insulator could never
	# turn its holes blue.
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for xy: Vector2 in _contacts():
		var at := Vector3(xy.x, xy.y, 0.0)
		_tube(st, HOLE_R, HOLE_R, Z_JACK_INSERT, Z_BORE_FLOOR, false, at, RING_PIN)
		_disc(st, HOLE_R, Z_BORE_FLOOR, at, RING_PIN)
	for sx in [-SCREW_X, SCREW_X]:
		var at := Vector3(sx, 0.0, 0.0)
		_tube(st, SCREW_R + 0.0002, SCREW_R + 0.0002, Z_BOSS_END, Z_PANEL, false,
			at, RING_PIN)
		_disc(st, SCREW_R + 0.0002, Z_PANEL, at, RING_PIN)
	st.generate_normals()
	var m_bore := PlugMats.metal(Color(0.035, 0.035, 0.04), 0.55)
	st.set_material(m_bore)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(2, m_bore)

	_save(mesh, OUT_JACK, false)


## The insulator's front face: a plate filling the shell bore with fifteen genuine
## holes in it.
##
## Built as three horizontal strips, one per contact row, each tiled into a cell per
## contact — a cell being a ring of quads from its hole out to the cell's rectangle.
## The leftover border between that block and the trapezoid is one more ring.
##
## A flat dark disc laid ON a solid face would read the same at a metre, but the
## holes have to survive a plug being offered up to them from 100 mm, and a real
## bore is the only thing that foreshortens correctly.
func _insulator_face(st: SurfaceTool, bore: PackedVector2Array, z: float) -> void:
	var half_col := COL_PITCH * 0.5
	var half_row := ROW_PITCH * 0.5
	var pts := _contacts()
	# The block the three strips occupy. Row 2's stagger makes it asymmetric, which
	# is why this is measured off the contacts rather than assumed symmetric.
	var x_min := INF
	var x_max := -INF
	for xy: Vector2 in pts:
		x_min = minf(x_min, xy.x - half_col)
		x_max = maxf(x_max, xy.x + half_col)
	var y_max: float = ROW_PITCH + half_row
	var y_min: float = -y_max

	for row in 3:
		var y: float = (1.0 - float(row)) * ROW_PITCH
		var xs: Array = []
		for xy: Vector2 in pts:
			if is_equal_approx(xy.y, y):
				xs.append(xy.x)
		xs.sort()
		# Plain span from the block's edge up to the first cell...
		if xs[0] - half_col > x_min:
			_quad(st, x_min, xs[0] - half_col, y - half_row, y + half_row, z)
		for i in xs.size():
			var cx: float = xs[i]
			var at := Vector2(cx, y)
			# Hole and cell are sampled along the SAME directions so the two loops
			# pair up one for one, and those directions include the cell's four
			# corners. Evenly spaced angles inscribe a polygon in the rectangle and
			# leave its corners uncovered — which showed up as dark wedges between
			# the contacts, the inside of the connector seen through its own face.
			var hole := PackedVector2Array()
			var cell := PackedVector2Array()
			for a: float in _cell_dirs(half_col, half_row):
				var dir := Vector2(cos(a), sin(a))
				# Slightly under HOLE_R so the face always laps INTO the bore. Both
				# are 12-gons but at different rotations, and at equal radius the
				# face's edge midpoints would fall inside the bore's vertices and
				# open a hairline ring.
				hole.append(at + dir * (HOLE_R * 0.95))
				cell.append(at + _rect_at_angle(-half_col, half_col,
					-half_row, half_row, dir))
			_band(st, hole, cell, z, true)
			var next_edge: float = (xs[i + 1] - half_col) if i + 1 < xs.size() else x_max
			if next_edge > cx + half_col:
				_quad(st, cx + half_col, next_edge, y - half_row, y + half_row, z)

	# The border: bore trapezoid outside, the strip block inside. Both are star
	# shaped about the centre, so the inner loop is sampled along the outer's own
	# directions and the two pair up one for one.
	var inner := PackedVector2Array()
	for p: Vector2 in bore:
		inner.append(_rect_at_angle(x_min, x_max, y_min, y_max, p))
	_band(st, inner, bore, z, true)


# ── geometry helpers ─────────────────────────────────────────────────────────
#
# Every one of these emits in Godot's Plane(a,b,c) order, so facing follows vertex
# order and nothing here needs a normal computed by hand. The rules, in the terms
# gen_rca_plug.gd's _lathe note uses: a loft with z increasing faces outward, one
# with z decreasing faces into a bore, and a band faces +Z when its inner loop is
# passed first.


## A closed loop round a trapezoid with filleted corners — the D-shell section.
## Counter-clockwise viewed from +Z, wide edge on top, which is the way a VGA shell
## keys: a plug cannot go in upside down because the bottom is 2.7 mm narrower.
func _d_loop(w_top: float, w_bot: float, h: float) -> PackedVector2Array:
	return _fillet(PackedVector2Array([
		Vector2(w_top * 0.5, h * 0.5),
		Vector2(-w_top * 0.5, h * 0.5),
		Vector2(-w_bot * 0.5, -h * 0.5),
		Vector2(w_bot * 0.5, -h * 0.5),
	]), CORNER_R)


## A rounded rectangle, same point count as _d_loop so the two can be lofted
## together. With r == w/2 == h/2 the fillets meet and this is exactly a circle,
## which is how the strain relief reaches a round cord without a second helper.
func _rrect_loop(w: float, h: float, r: float) -> PackedVector2Array:
	return _fillet(PackedVector2Array([
		Vector2(w * 0.5, h * 0.5),
		Vector2(-w * 0.5, h * 0.5),
		Vector2(-w * 0.5, -h * 0.5),
		Vector2(w * 0.5, -h * 0.5),
	]), r)


## Directions round a contact cell, its four corners among them. See the note at
## the call site for why the corners have to be hit exactly.
func _cell_dirs(hw: float, hh: float) -> PackedFloat32Array:
	var th: float = atan2(hh, hw)
	var corners := [th, PI - th, PI + th, TAU - th]
	var out := PackedFloat32Array()
	for i in 4:
		var a0: float = corners[i]
		var a1: float = corners[(i + 1) % 4]
		if a1 < a0:
			a1 += TAU
		for k in CELL_ARC:
			out.append(a0 + (a1 - a0) * float(k) / float(CELL_ARC))
	return out


## Round the corners of a convex loop. Each corner becomes an arc of ARC+1 points,
## so every loop built this way has the same vertex count and any two can be lofted.
func _fillet(corners: PackedVector2Array, r: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := corners.size()
	for i in n:
		var p: Vector2 = corners[i]
		var u: Vector2 = (corners[(i - 1 + n) % n] - p).normalized()
		var v: Vector2 = (corners[(i + 1) % n] - p).normalized()
		var half: float = acos(clampf(u.dot(v), -1.0, 1.0)) * 0.5
		var c: Vector2 = p + (u + v).normalized() * (r / sin(half))
		var a0: float = (p + u * (r / tan(half)) - c).angle()
		var a1: float = (p + v * (r / tan(half)) - c).angle()
		var da: float = wrapf(a1 - a0, -PI, PI)
		for k in range(ARC + 1):
			out.append(c + Vector2(r, 0.0).rotated(a0 + da * float(k) / float(ARC)))
	return out


## Where a ray from the origin through `dir` leaves an axis-aligned rectangle.
func _rect_at_angle(x0: float, x1: float, y0: float, y1: float,
		dir: Vector2) -> Vector2:
	var t := INF
	if not is_zero_approx(dir.x):
		t = minf(t, ((x1 if dir.x > 0.0 else x0)) / dir.x)
	if not is_zero_approx(dir.y):
		t = minf(t, ((y1 if dir.y > 0.0 else y0)) / dir.y)
	return dir * t


## Wall between two closed loops of equal length. Faces outward when z1 > z0; pass
## the z values reversed for an inside wall.
func _loft(st: SurfaceTool, l0: PackedVector2Array, z0: float,
		l1: PackedVector2Array, z1: float) -> void:
	var n := l0.size()
	for i in n:
		var j := (i + 1) % n
		var p00 := Vector3(l0[i].x, l0[i].y, z0)
		var p10 := Vector3(l0[j].x, l0[j].y, z0)
		var p01 := Vector3(l1[i].x, l1[i].y, z1)
		var p11 := Vector3(l1[j].x, l1[j].y, z1)
		st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
		st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)


## Flat band between two concentric loops at one z — a rim, a flange face, or the
## ring of insulator around a contact hole. Faces +Z as written; pass face_pos
## false to turn it round.
func _band(st: SurfaceTool, inner: PackedVector2Array, outer: PackedVector2Array,
		z: float, face_pos: bool) -> void:
	var n := inner.size()
	for i in n:
		var j := (i + 1) % n
		var i0 := Vector3(inner[i].x, inner[i].y, z)
		var i1 := Vector3(inner[j].x, inner[j].y, z)
		var o0 := Vector3(outer[i].x, outer[i].y, z)
		var o1 := Vector3(outer[j].x, outer[j].y, z)
		if face_pos:
			st.add_vertex(i0); st.add_vertex(o1); st.add_vertex(o0)
			st.add_vertex(i0); st.add_vertex(i1); st.add_vertex(o1)
		else:
			st.add_vertex(i0); st.add_vertex(o0); st.add_vertex(o1)
			st.add_vertex(i0); st.add_vertex(o1); st.add_vertex(i1)


## Fill a closed loop, fanned from its centroid.
func _cap(st: SurfaceTool, loop: PackedVector2Array, z: float,
		face_pos: bool) -> void:
	var c := Vector2.ZERO
	for p: Vector2 in loop:
		c += p
	c /= float(loop.size())
	var cv := Vector3(c.x, c.y, z)
	for i in loop.size():
		var j := (i + 1) % loop.size()
		var a := Vector3(loop[i].x, loop[i].y, z)
		var b := Vector3(loop[j].x, loop[j].y, z)
		if face_pos:
			st.add_vertex(cv); st.add_vertex(b); st.add_vertex(a)
		else:
			st.add_vertex(cv); st.add_vertex(a); st.add_vertex(b)


## An axis-aligned quad at one z, facing +Z. The plain spans between contact cells.
func _quad(st: SurfaceTool, x0: float, x1: float, y0: float, y1: float,
		z: float) -> void:
	var a := Vector3(x1, y1, z)
	var b := Vector3(x0, y1, z)
	var c := Vector3(x0, y0, z)
	var d := Vector3(x1, y0, z)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(b)
	st.add_vertex(a); st.add_vertex(d); st.add_vertex(c)


## Tube along +Z. Wound so the outside faces out when z1 > z0 — pass them reversed
## for a bore. Lifted from gen_ps2_plug.gd, with the segment count made a parameter
## so the 1 mm pins can be cheaper than the 9 mm knobs.
func _tube(st: SurfaceTool, r0: float, r1: float, z0: float, z1: float,
		capped: bool, offset := Vector3.ZERO, seg: int = RING) -> void:
	for i in seg:
		var a0: float = TAU * float(i) / float(seg)
		var a1: float = TAU * float(i + 1) / float(seg)
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


## Flat ring at z facing +Z, from r_in to r_out.
func _annulus(st: SurfaceTool, r_in: float, r_out: float, z: float,
		offset := Vector3.ZERO, seg: int = RING) -> void:
	for i in seg:
		var a0: float = TAU * float(i) / float(seg)
		var a1: float = TAU * float(i + 1) / float(seg)
		var i0 := offset + Vector3(cos(a0) * r_in, sin(a0) * r_in, z)
		var i1 := offset + Vector3(cos(a1) * r_in, sin(a1) * r_in, z)
		var o0 := offset + Vector3(cos(a0) * r_out, sin(a0) * r_out, z)
		var o1 := offset + Vector3(cos(a1) * r_out, sin(a1) * r_out, z)
		st.add_vertex(i0); st.add_vertex(o1); st.add_vertex(o0)
		st.add_vertex(i0); st.add_vertex(i1); st.add_vertex(o1)


## Disc at z facing +Z — the floor of a bore.
func _disc(st: SurfaceTool, r: float, z: float, offset := Vector3.ZERO,
		seg: int = RING) -> void:
	var c := offset + Vector3(0, 0, z)
	for i in seg:
		var a0: float = TAU * float(i) / float(seg)
		var a1: float = TAU * float(i + 1) / float(seg)
		var p0 := offset + Vector3(cos(a0) * r, sin(a0) * r, z)
		var p1 := offset + Vector3(cos(a1) * r, sin(a1) * r, z)
		st.add_vertex(c); st.add_vertex(p1); st.add_vertex(p0)


## Revolve a (z, radius) profile about an axis parallel to Z through `offset`.
## gen_rca_plug.gd's, with the offset the knurled knobs need.
func _lathe(st: SurfaceTool, profile: PackedVector2Array,
		offset := Vector3.ZERO) -> void:
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
			var p00 := offset + Vector3(cos(a0) * r0, sin(a0) * r0, z0)
			var p10 := offset + Vector3(cos(a1) * r0, sin(a1) * r0, z0)
			var p01 := offset + Vector3(cos(a0) * r1, sin(a0) * r1, z1)
			var p11 := offset + Vector3(cos(a1) * r1, sin(a1) * r1, z1)
			if is_zero_approx(r0):
				st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
			elif is_zero_approx(r1):
				st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p10)
			else:
				st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
				st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)


## Save, and REFUSE a bake whose frame is wrong.
##
## The +Z/-Z contract is not a convention anyone can eyeball once the mesh is baked:
## a mirrored plug seats backwards and trails its cord through the case, which is a
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

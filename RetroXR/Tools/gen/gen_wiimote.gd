## Bakes the Wii Remote's shell, its B trigger and its moulding seam to
## Scenes/Objects/controllers/wii/wiimote_*.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_wiimote.gd
##
## What this replaces was one BoxMesh, 36 x 30 x 148 mm, hard edges and flat cut
## ends. The Nunchuk beside it had already been through this pass (gen_nunchuk.gd)
## and the remote had not, so the two sat in the same hand at different fidelities.
##
## The shape in words, read off a side elevation and a face-on photograph:
##
##   * a straight FACE but a curved back: the remote is about 21 mm deep at the
##     IR end and swells to 30 mm by a third of the way along. That swell is the
##     single most recognisable thing about its side view, and building the
##     underside flat is what made the first cut of this read as a bar,
##   * fillets down all four long edges,
##   * an underside noticeably rounder than the face: the bottom corners carry a
##     larger radius than the top ones,
##   * a face that is flat where the buttons are, with the faintest crown across
##     it,
##   * both ends rolled off over a few millimetres into a small flat — NOT domed.
##     The nose has to back the IR window and the tail has to back the expansion
##     socket, and the hardware ends the same way.
##
## Two constraints fix how abrupt those end rolls can be, and both were measured
## off wiimote.tscn rather than chosen:
##
##   * POWER's well is a torus of outer radius 4.4 mm centred at z = -0.066, so
##     its front lip reaches z = -0.0704 — 3.6 mm from the tip. The nose is
##     therefore at full section until t = 0.018 and rolls over the last 2.7 mm.
##   * The player LEDs sit at z = +0.0685 with 1 mm of depth, so the tail is at
##     full section until t = 0.972 and rolls over the last 4.1 mm.
##
## Unlike the Nunchuk, no ring here collapses to a pole: both ends are capped with
## a fan. The section is a ROUNDED RECTANGLE and not the Nunchuk's ellipse, so
## _section() is the one piece of real new geometry — everything below it is
## gen_nunchuk.gd's machinery.
extends SceneTree

# ── The frame ────────────────────────────────────────────────────────────────
# Long axis on Z with -Z forward (the IR window end), matching wiimote.tscn.
# Every station below is t along that axis, 0 at the nose and 1 at the tail.
const Z_NOSE := -0.074
const Z_TAIL := 0.074

## How far the top face bows down at the flanks, in metres. The apex is pinned at
## x = 0 so the crown falls AWAY toward the sides — that is what keeps every
## centreline seat (A, HOME, the d-pad, 1, 2, the speaker holes) at exactly the
## height it was authored at, and costs the off-axis ones a tenth of a millimetre
## they can afford. Lifting the centre instead would have floated all of them.
const CROWN := 0.0003

## How far the trigger's pulling face dishes up in the middle, so a fingertip
## nestles across it rather than resting on a flat.
const TRIGGER_DISH := 0.0008

# ── The battery bay ──────────────────────────────────────────────────────────
## A recess in the underside for the battery cover, and the reason it exists.
##
## The cover used to hang 2.5 mm below the shell with daylight behind it, and the
## obvious fix — move it up until it touches — does not work: SYNC lives under it,
## and SYNC's cap has to break the shell's outer surface to be visible at all when
## the cover is open (the shell is a closed loft; nothing at or below its skin can
## be seen). Cover flush and SYNC visible are contradictory ON A FLAT UNDERSIDE.
##
## So the underside gets a real bay. The floor sits BAY_DEPTH up from the skin,
## the cover fills the opening with its outer face flush where the skin used to
## be, and SYNC stands proud of the FLOOR while still clearing the cover's inner
## face. Everything then has somewhere to be:
##
##     skin / cover outer face   -0.0150
##     cover inner face          -0.0132   (COVER_THICK below the skin)
##     SYNC cap, 1 mm proud      -0.0130 .. -0.0120
##     bay floor                 -0.0120   (BAY_DEPTH up from the skin)
const BAY_DEPTH := 0.003
const COVER_THICK := 0.0018
## Ends of the bay in body z. Taken from the reference, where the cover's outline
## runs from just behind the trigger to close to the tail.
const BAY_Z0 := -0.012
const BAY_Z1 := 0.069
## How long the bay's end walls take to rise. Short, but not a step: a vertical
## wall in a loft needs two rings at the same z and reads as a tear if it gets
## one.
const BAY_RAMP := 0.0025
## Across the ring, the floor is flat over the underside's own flat and eases out
## through the corner arc. Running it to the flanks instead cuts a channel out
## through the sides of the remote.
const BAY_X_FLAT := 0.0105
const BAY_X_EDGE := 0.0165
## Half-width of the cover panel itself. Wider than the flat on purpose — its
## edges bury into the eased part of the bay, which is what a shut line is.
const COVER_HX := 0.0150

# ── Section sampling ─────────────────────────────────────────────────────────
# Eight pieces: two long faces, two flanks, four corner arcs. Each loop below is
# exclusive of its own end point, so the pieces concatenate without a doubled
# vertex at the joins — a duplicate there survives index() and creases the shell.
const N_TOP := 6
const N_BOT := 5
const N_SIDE := 3
const N_CORNER := 6
# SEGS = N_TOP + N_BOT + 2*N_SIDE + 4*N_CORNER = 41


## Control stations: t, half-width, top, bottom (both as positive magnitudes off
## the axis), then the TOP and BOTTOM corner radii. The two radii differ on
## purpose — the reference underside is visibly rounder than the face.
##
## THE BACK FACE IS NOT FLAT, and this table shipped it flat once. The remote is
## slim at the IR end and swells to full depth about a third of the way along; the
## FACE stays straight and all of that movement is on the underside. Measured off
## the reference side elevation by thresholding the silhouette against its white
## ground, with the face edge as the datum:
##
##     0-20%   21.5 - 22.6 mm deep
##     22-36%  swells 24.3 -> 31.7 mm
##     36-90%  31.9 mm, dead constant
##
## (Those are raw pixels; the whole column is scaled by 30.0/31.92 so the body
## lands on the 30 mm the collision box and every authored seat assume.)
##
## Two things follow that are easy to get backwards:
##
##   * `yt` stays at 0.0150 the whole way. The face edge measures constant down
##     the entire length, so the taper is ENTIRELY in `yb`. Splitting it between
##     the two would tilt the button plane and unseat every face feature.
##   * The section stops being symmetric about y = 0. At the nose it runs
##     -0.0057 to +0.0150, so the end cap's fan centre has to be the section's
##     centroid rather than the axis.
##
## The trigger sits ON this swell rather than on a flat, and that is most of what
## a side view of this remote reads as. Modelling the underside flat and then
## making the trigger tall enough to look right is the same silhouette built out
## of the wrong parts — the measured trigger never passes the body's own depth
## line at all.
const _SHELL := [
	# t,      hx,      yt,      yb,      rt,      rb
	[0.000,   0.0128,  0.0106,  0.0068,  0.0046,  0.0040],
	[0.005,   0.0158,  0.0132,  0.0066,  0.0053,  0.0044],
	[0.011,   0.0173,  0.0145,  0.0060,  0.0058,  0.0046],
	[0.018,   0.0179,  0.0149,  0.0058,  0.0060,  0.0046],
	[0.032,   0.0180,  0.0150,  0.0057,  0.0060,  0.0046],
	[0.100,   0.0180,  0.0150,  0.0056,  0.0060,  0.0046],
	[0.150,   0.0180,  0.0150,  0.0053,  0.0060,  0.0044],
	[0.190,   0.0180,  0.0150,  0.0059,  0.0060,  0.0048],
	[0.220,   0.0180,  0.0150,  0.0076,  0.0060,  0.0056],
	[0.260,   0.0180,  0.0150,  0.0103,  0.0060,  0.0064],
	[0.300,   0.0180,  0.0150,  0.0124,  0.0060,  0.0070],
	[0.340,   0.0180,  0.0150,  0.0139,  0.0060,  0.0073],
	[0.380,   0.0180,  0.0150,  0.0147,  0.0060,  0.0075],
	[0.440,   0.0180,  0.0150,  0.0150,  0.0060,  0.0075],
	[0.620,   0.0180,  0.0150,  0.0150,  0.0060,  0.0075],
	[0.880,   0.0180,  0.0150,  0.0150,  0.0060,  0.0075],
	[0.972,   0.0180,  0.0150,  0.0150,  0.0060,  0.0075],
	[0.982,   0.0175,  0.0146,  0.0146,  0.0059,  0.0072],
	[0.991,   0.0161,  0.0135,  0.0134,  0.0055,  0.0066],
	[1.000,   0.0128,  0.0106,  0.0104,  0.0046,  0.0052],
]

## Where the rings actually go. Deliberately NOT uniform: the back half of this
## model is one constant section and rings spent there are triangles that say
## nothing, while the ends turn their whole silhouette inside a few millimetres
## and the underside's swell — 0.20 to 0.46 — is a 9 mm curve that has to resolve
## or it comes out as a chamfer with two creases in it. The clusters at 0.41-0.45
## and 0.945-0.970 are the battery bay's end walls, which rise over 2.5 mm and
## tear if they get one ring.
const _RINGS := [
	0.000, 0.003, 0.007, 0.011, 0.015, 0.019, 0.024, 0.030, 0.038,
	0.055, 0.080, 0.110, 0.145, 0.175,
	0.200, 0.218, 0.236, 0.254, 0.272, 0.290, 0.308, 0.326, 0.344, 0.362,
	0.380, 0.400,
	0.410, 0.419, 0.427, 0.436, 0.448,
	0.500, 0.560, 0.640, 0.720, 0.800, 0.870, 0.920,
	0.945, 0.953, 0.958, 0.962, 0.966, 0.970,
	0.972, 0.978, 0.983, 0.988, 0.992, 0.995, 0.998, 1.000,
]


## The B trigger, measured RELATIVE TO THE SHELL'S UNDERSIDE rather than in
## absolute pivot coordinates, because that underside is a slope here and not a
## flat. Columns are: u along the trigger, half-width, INSET (how far the fin's
## top sits above the local surface, i.e. buried inside the shell) and PROTRUSION
## (how far its bottom sits below it), then the section's corner radius.
##
## Absolute coordinates are what the previous version used, and the moment the
## shell gained its taper the fin stayed where it was and the shell climbed 8 mm
## out from under it — leaving the trigger hanging in free air beside the body.
## Anchored to the surface it grows out of, it cannot come adrift like that again.
##
## It is also far SMALLER than it looks in a side view. Against the reference
## silhouette the trigger peaks about 4.4 mm proud of the shell and is gone within
## 13 mm; nearly all of the big protruding shape a photograph shows is the shell's
## own swell, not the button. Modelling it as a deep fin and the underside as flat
## produces the same outline out of the wrong parts, and it does not survive being
## looked at from any other angle.
const _TRIG := [
	# u,      hx,      inset,   protrude,  r
	[0.00,    0.0040,  0.0016,  -0.0006,   0.0008],
	[0.15,    0.0054,  0.0018,   0.0014,   0.0012],
	[0.32,    0.0062,  0.0020,   0.0032,   0.0016],
	[0.45,    0.0066,  0.0022,   0.0042,   0.0018],
	[0.55,    0.0068,  0.0022,   0.0045,   0.0018],
	[0.68,    0.0068,  0.0024,   0.0038,   0.0018],
	[0.80,    0.0067,  0.0026,   0.0026,   0.0016],
	[0.90,    0.0066,  0.0028,   0.0014,   0.0014],
	[1.00,    0.0064,  0.0030,  -0.0006,   0.0010],
]

## The fin's extent in pivot space — body z -0.0445 to -0.0280, straddling the
## steepest part of the swell, which is where the reference puts it. It starts at
## zero because the pivot IS the fin's front edge; see TRIG_PIVOT.
const TRIG_Z_FRONT := 0.0
const TRIG_Z_BACK := 0.0165
const TRIG_RINGS := 20

## Where wiimote.tscn puts TriggerPivot — the fin's FRONT edge, which is where a
## real B trigger hinges. Mirrored here so the fin can be built against the shell;
## the scene remains the authority, and the two must be changed together.
const TRIG_PIVOT := Vector3(0.0, -0.005, -0.0445)


# ── Seam ─────────────────────────────────────────────────────────────────────

## Half-height of the parting-line ribbon, in metres.
const SEAM_HALF := 0.0005

## How far the ribbon stands off the flank.
##
## gen_nunchuk.gd needs 0.35 mm here and explains why: its ribbon is computed on
## the analytic surface while the shell is a faceted approximation of it, so
## mid-facet the chord cuts inside and the ribbon surfaces through in flecks.
##
## That does not apply at this value here, and the reason is worth keeping: the
## ribbon is emitted at the SAME stations as the rings, and the flank it rides is
## a straight edge of the section rather than an arc. Ribbon chord and shell chord
## are then the same chord, and the only job left is clearing z-fight. _build_seam
## measures the residual error anyway and complains if this is under it, so the
## reasoning is checked rather than trusted.
const SEAM_STANDOFF := 0.00015

## The outer 5% at each end is skipped. The section is turning hard there and a
## parting line does not run onto an end cap on the real shell either.
const SEAM_T_MIN := 0.05
const SEAM_T_MAX := 0.95


const OUT_DIR := "res://Scenes/Objects/controllers/wii/"


func _init() -> void:
	_build_shell()
	_build_cover()
	_build_trigger()
	_build_seam()
	_report_seats()
	_report_profile()
	quit()


# ── The shell ────────────────────────────────────────────────────────────────

func _build_shell() -> void:
	var rings: Array = []
	for t: float in _RINGS:
		rings.append(_shell_ring(t))
	var tris := _loft(rings)
	# Neither end closes to a point, so both get a fan. _cap orients each triangle
	# against an explicit outward direction rather than trusting a winding rule,
	# because _orient below weighs the WHOLE soup and would happily leave a cap
	# inside out inside an otherwise correct solid.
	# The fan centre is the section's CENTROID, not the axis. With the underside
	# tapered the nose section runs -0.0057 to +0.0150 and its middle is 4.7 mm
	# off y = 0; fanning to the axis from there splays the cap into slivers.
	tris.append_array(_cap(rings[0], _axis_point(0.0), Vector3(0, 0, -1)))
	tris.append_array(_cap(rings[-1], _axis_point(1.0), Vector3(0, 0, 1)))
	_save(_smooth(tris), OUT_DIR + "wiimote_shell.res")


## Centre of the shell's section at station `t` — halfway between its top and its
## underside, which is not y = 0 anywhere the taper is active.
static func _axis_point(t: float) -> Vector3:
	return Vector3(0.0, (_sample(_SHELL, t, 2) - _sample(_SHELL, t, 3)) * 0.5,
		lerpf(Z_NOSE, Z_TAIL, t))


func _shell_ring(t: float) -> Array:
	var hx := _sample(_SHELL, t, 1)
	var yb := _sample(_SHELL, t, 3)
	var sec := _section(hx, _sample(_SHELL, t, 2), yb,
		_sample(_SHELL, t, 4), _sample(_SHELL, t, 5), CROWN, 0.0)
	var z := lerpf(Z_NOSE, Z_TAIL, t)
	var out: Array = []
	for p: Vector2 in sec:
		out.append(Vector3(p.x, _bay_lift(p, z, hx, yb), z))
	return out


## Raise one underside point into the battery bay.
##
## Weighted down the section the same way the crown and the trigger dish are, so
## the floor is full depth across the underside's flat and the corner arcs stay
## tangent to it instead of gaining a step where the flat meets them.
static func _bay_lift(p: Vector2, z: float, hx: float, yb: float) -> float:
	if p.y >= 0.0 or yb <= 0.0 or hx <= 0.0:
		return p.y
	var w := _bay_weight(p.x, z)
	if w <= 0.0:
		return p.y
	return p.y + BAY_DEPTH * w * clampf(-p.y / yb, 0.0, 1.0)


## How much bay there is at (x, z): 1 inside the floor, 0 outside the opening.
static func _bay_weight(x: float, z: float) -> float:
	var wz := smoothstep(BAY_Z0, BAY_Z0 + BAY_RAMP, z) 		* (1.0 - smoothstep(BAY_Z1 - BAY_RAMP, BAY_Z1, z))
	return wz * (1.0 - smoothstep(BAY_X_FLAT, BAY_X_EDGE, absf(x)))


## The underside's skin at (x, z) — where it would be with NO bay cut into it.
## This is the surface the cover's outer face has to land on to read as flush.
static func _skin_y(x: float, z: float) -> float:
	var t := _shell_t(z)
	var hx := _sample(_SHELL, t, 1)
	var yb := _sample(_SHELL, t, 3)
	var rb := minf(_sample(_SHELL, t, 5), minf(hx, yb))
	var ax := absf(x)
	if ax <= hx - rb:
		return -yb
	var dx := ax - (hx - rb)
	if dx >= rb:
		return INF
	return -(yb - rb) - sqrt(rb * rb - dx * dx)


# ── The battery cover ────────────────────────────────────────────────────────

## A curved slab whose OUTER face is the shell's own skin, so it cannot gap
## against a surface that is flat over the middle and arced at the edges — the
## reason the old flat 30 mm box could never sit down on this shell.
##
## Built in CoverPivot's frame, hinged at its front edge.
func _build_cover() -> void:
	var nz := 40
	var nx := 14
	var origin := Vector3(0.0, _skin_y(0.0, BAY_Z0), BAY_Z0)
	var outer: Array = []
	var inner: Array = []
	for i in nz + 1:
		var z := lerpf(BAY_Z0, BAY_Z1, float(i) / float(nz))
		var ro: Array = []
		var ri: Array = []
		for j in nx + 1:
			var x := lerpf(-COVER_HX, COVER_HX, float(j) / float(nx))
			var y := _skin_y(x, z)
			ro.append(Vector3(x, y, z) - origin)
			ri.append(Vector3(x, y + COVER_THICK, z) - origin)
		outer.append(ro)
		inner.append(ri)
	# Every face is oriented against an explicit outward direction rather than by
	# a winding rule, the same way _cap is and for the same reason: _orient weighs
	# the whole soup, so a face wound backwards inside an otherwise correct solid
	# sails through it. The first cut of this had both grid faces reversed and
	# _check_outward is what said so.
	var tris: Array[Vector3] = []
	for i in nz:
		for j in nx:
			tris.append_array(_quad(outer[i][j], outer[i][j + 1],
				outer[i + 1][j + 1], outer[i + 1][j], Vector3.DOWN))
			tris.append_array(_quad(inner[i][j], inner[i][j + 1],
				inner[i + 1][j + 1], inner[i + 1][j], Vector3.UP))
	for i in nz:
		tris.append_array(_quad(outer[i][0], outer[i + 1][0],
			inner[i + 1][0], inner[i][0], Vector3.LEFT))
		tris.append_array(_quad(outer[i][nx], outer[i + 1][nx],
			inner[i + 1][nx], inner[i][nx], Vector3.RIGHT))
	for j in nx:
		tris.append_array(_quad(outer[0][j], outer[0][j + 1],
			inner[0][j + 1], inner[0][j], Vector3.FORWARD))
		tris.append_array(_quad(outer[nz][j], outer[nz][j + 1],
			inner[nz][j + 1], inner[nz][j], Vector3.BACK))
	_save(_smooth(tris), OUT_DIR + "wiimote_cover.res")
	print("[gen]   cover hinge at body (0, %.4f, %.4f), %.1f x %.1f mm"
		% [origin.y, origin.z, COVER_HX * 2000.0, (BAY_Z1 - BAY_Z0) * 1000.0])
	var floor_y := _skin_y(0.0, 0.04) + BAY_DEPTH
	print("[gen]   bay floor %+.4f, cover inner face %+.4f, %.1f mm between them"
		% [floor_y, _skin_y(0.0, 0.04) + COVER_THICK,
			(floor_y - (_skin_y(0.0, 0.04) + COVER_THICK)) * 1000.0])


# ── The B trigger ────────────────────────────────────────────────────────────

func _build_trigger() -> void:
	var rings: Array = []
	for r in TRIG_RINGS + 1:
		var u := float(r) / float(TRIG_RINGS)
		rings.append(_trigger_ring(u))
	var tris := _loft(rings)
	tris.append_array(_cap(rings[0], _trig_centre(0.0), Vector3(0, 0, -1)))
	tris.append_array(_cap(rings[-1], _trig_centre(1.0), Vector3(0, 0, 1)))
	_save(_smooth(tris), OUT_DIR + "wiimote_trigger.res")


func _trigger_ring(u: float) -> Array:
	var hx := _sample(_TRIG, u, 1)
	var z := lerpf(TRIG_Z_FRONT, TRIG_Z_BACK, u)
	# Where the shell's underside is at this station, in the PIVOT's frame.
	var surf := -_sample(_SHELL, _shell_t(TRIG_PIVOT.z + z), 3) - TRIG_PIVOT.y
	var yt: float = surf + _sample_signed(_TRIG, u, 2)
	var yb: float = surf - _sample_signed(_TRIG, u, 3)
	var mid := (yt + yb) * 0.5
	var half := maxf((yt - yb) * 0.5, 1e-5)
	var r := _sample(_TRIG, u, 4)
	var sec := _section(hx, half, half, r, r, 0.0, TRIGGER_DISH)
	var out: Array = []
	for p: Vector2 in sec:
		out.append(Vector3(p.x, p.y + mid, z))
	return out


## Body-frame z as a station along the shell.
static func _shell_t(z: float) -> float:
	return clampf((z - Z_NOSE) / (Z_TAIL - Z_NOSE), 0.0, 1.0)


func _trig_centre(u: float) -> Vector3:
	var z := lerpf(TRIG_Z_FRONT, TRIG_Z_BACK, u)
	var surf := -_sample(_SHELL, _shell_t(TRIG_PIVOT.z + z), 3) - TRIG_PIVOT.y
	return Vector3(0.0, surf + (_sample_signed(_TRIG, u, 2)
		- _sample_signed(_TRIG, u, 3)) * 0.5, z)


# ── The moulding seam ────────────────────────────────────────────────────────

func _build_seam() -> void:
	var tris: Array[Vector3] = []
	var worst := 0.0
	for side: float in [1.0, -1.0]:
		var prev: Array = []
		for t: float in _RINGS:
			if t < SEAM_T_MIN or t > SEAM_T_MAX:
				prev = []
				continue
			var hx := _sample(_SHELL, t, 1)
			var y := _seam_y(t)
			var z := lerpf(Z_NOSE, Z_TAIL, t)
			var x := side * (hx + SEAM_STANDOFF)
			var lo := Vector3(x, y - SEAM_HALF, z)
			var hi := Vector3(x, y + SEAM_HALF, z)
			if not prev.is_empty():
				tris.append_array([prev[0], prev[1], lo])
				tris.append_array([prev[1], hi, lo])
			prev = [lo, hi]
		worst = maxf(worst, _seam_chord_error())
	if worst >= SEAM_STANDOFF:
		printerr("[gen] SEAM_STANDOFF %.5f does not clear a chord error of %.5f"
			% [SEAM_STANDOFF, worst])
	else:
		print("[gen] seam standoff %.2f mm clears a measured chord error of %.2f mm"
			% [SEAM_STANDOFF * 1000.0, worst * 1000.0])
	# A ribbon is a sheet: it encloses nothing, so _orient's volume test would flip
	# it on a rounding error. Drawn double-sided by Mat_seam instead.
	_save_sheet(_smooth_sheet(tris), OUT_DIR + "wiimote_seam.res")


## Where round the section the two shell halves meet: the middle of the straight
## flank, between the two corner arcs. Not the section's own mid-height — the top
## and bottom radii differ, so the flank is not centred on the axis.
static func _seam_y(t: float) -> float:
	var yt := _sample(_SHELL, t, 2)
	var yb := _sample(_SHELL, t, 3)
	var rt := _sample(_SHELL, t, 4)
	var rb := _sample(_SHELL, t, 5)
	return ((yt - rt) + (-(yb - rb))) * 0.5


## How far the shell's faceted flank falls inside the analytic flank the ribbon is
## computed on. The ribbon rides the SAME stations as the rings, so lengthwise the
## two are the same chord and this is only the transverse error — zero on a
## straight flank, which is why the standoff can be as small as it is. Measured
## per-station and mid-chord, where a chord is furthest from its curve.
static func _seam_chord_error() -> float:
	var worst := 0.0
	for i in range(_RINGS.size() - 1):
		var a: float = _RINGS[i]
		var b: float = _RINGS[i + 1]
		if b < SEAM_T_MIN or a > SEAM_T_MAX:
			continue
		var m := (a + b) * 0.5
		var chord := (_sample(_SHELL, a, 1) + _sample(_SHELL, b, 1)) * 0.5
		worst = maxf(worst, _sample(_SHELL, m, 1) - chord)
	return worst


# ── The section ──────────────────────────────────────────────────────────────

## One rounded rectangle, as SEGS points in the XY plane.
##
## The Nunchuk's ring is an ellipse and an ellipse is wrong here: the remote has a
## FLAT face carrying flat-bottomed button caps, and an ellipse gives it nowhere
## to sit. Four straight runs and four arcs instead.
##
## Traced anticlockwise seen from +Z — top face +x to -x — which is the winding
## that makes _loft's quads face outward with the rings stacked nose to tail. Get
## it the other way round and the whole shell renders inside out; _orient would
## rescue it, but then the end caps (which orient themselves) disagree with it.
static func _section(hx: float, yt: float, yb: float, rt: float, rb: float,
		crown: float, dish: float) -> Array:
	rt = minf(rt, minf(hx, yt))
	rb = minf(rb, minf(hx, yb))
	var tx := hx - rt
	var bx := hx - rb
	var ty := yt - rt
	var by := -(yb - rb)
	var pts: Array = []

	# top face, +x -> -x
	for i in N_TOP:
		pts.append(Vector2(lerpf(tx, -tx, float(i) / float(N_TOP)), yt))
	# top-left corner, 90 -> 180
	for i in N_CORNER:
		var a := PI * 0.5 + PI * 0.5 * (float(i) / float(N_CORNER))
		pts.append(Vector2(-tx + rt * cos(a), ty + rt * sin(a)))
	# left flank, top -> bottom
	for i in N_SIDE:
		pts.append(Vector2(-hx, lerpf(ty, by, float(i) / float(N_SIDE))))
	# bottom-left corner, 180 -> 270
	for i in N_CORNER:
		var a := PI + PI * 0.5 * (float(i) / float(N_CORNER))
		pts.append(Vector2(-bx + rb * cos(a), by + rb * sin(a)))
	# bottom face, -x -> +x
	for i in N_BOT:
		pts.append(Vector2(lerpf(-bx, bx, float(i) / float(N_BOT)), -yb))
	# bottom-right corner, 270 -> 360
	for i in N_CORNER:
		var a := PI * 1.5 + PI * 0.5 * (float(i) / float(N_CORNER))
		pts.append(Vector2(bx + rb * cos(a), by + rb * sin(a)))
	# right flank, bottom -> top
	for i in N_SIDE:
		pts.append(Vector2(hx, lerpf(by, ty, float(i) / float(N_SIDE))))
	# top-right corner, 0 -> 90
	for i in N_CORNER:
		var a := PI * 0.5 * (float(i) / float(N_CORNER))
		pts.append(Vector2(tx + rt * cos(a), ty + rt * sin(a)))

	if crown <= 0.0 and dish <= 0.0:
		return pts
	# Both deformations are weighted by how far UP (or down) the section a point
	# already is, so they fade to nothing at the widest line and leave the flanks
	# and the corner tangents alone. Applied to the face alone instead, they put a
	# step where the flat meets its corner arc.
	for i in pts.size():
		var p: Vector2 = pts[i]
		var nx: float = 0.0 if hx <= 0.0 else clampf(p.x / hx, -1.0, 1.0)
		if crown > 0.0 and p.y > 0.0 and yt > 0.0:
			p.y -= crown * nx * nx * clampf(p.y / yt, 0.0, 1.0)
		if dish > 0.0 and p.y < 0.0 and yb > 0.0:
			p.y += dish * (1.0 - nx * nx) * clampf(-p.y / yb, 0.0, 1.0)
		pts[i] = p
	return pts


# ── Sampling ─────────────────────────────────────────────────────────────────

## Catmull-Rom through a control table on column `col`, clamped at both ends.
## Magnitudes, so the result is floored at zero.
static func _sample(table: Array, t: float, col: int) -> float:
	return maxf(_sample_signed(table, t, col), 0.0)


## The same, for a column that is a signed height rather than a magnitude. The
## trigger's y_top crosses zero — flooring it would flatten the fin's root into
## the shell's own surface.
static func _sample_signed(table: Array, t: float, col: int) -> float:
	var n := table.size()
	var i := 0
	while i < n - 2 and float(table[i + 1][0]) < t:
		i += 1
	var p1: Array = table[i]
	var p2: Array = table[i + 1]
	var p0: Array = table[maxi(i - 1, 0)]
	var p3: Array = table[mini(i + 2, n - 1)]
	var span := float(p2[0]) - float(p1[0])
	var u := 0.0 if span <= 0.0 else clampf((t - float(p1[0])) / span, 0.0, 1.0)
	return _catmull(float(p0[col]), float(p1[col]), float(p2[col]), float(p3[col]), u)


static func _catmull(a: float, b: float, c: float, d: float, u: float) -> float:
	var u2 := u * u
	var u3 := u2 * u
	return 0.5 * ((2.0 * b) + (-a + c) * u + (2.0 * a - 5.0 * b + 4.0 * c - d) * u2
		+ (-a + 3.0 * b - 3.0 * c + d) * u3)


# ── Stitching ────────────────────────────────────────────────────────────────

## Stitch a stack of equal-length rings into a tube. No ring collapses on either
## solid here, so unlike gen_nunchuk.gd's there is no pole case — both ends are
## closed by _cap instead.
static func _loft(rings: Array) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for r in range(rings.size() - 1):
		var lo: Array = rings[r]
		var hi: Array = rings[r + 1]
		for s in lo.size():
			var s2 := (s + 1) % lo.size()
			out.append_array([lo[s], lo[s2], hi[s]])
			out.append_array([lo[s2], hi[s2], hi[s]])
	return out


## One quad as two triangles, both facing `outward`.
static func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		outward: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for tri: Array in [[a, b, c], [a, c, d]]:
		var p: Vector3 = tri[0]
		var q: Vector3 = tri[1]
		var r: Vector3 = tri[2]
		if (q - p).cross(r - p).dot(outward) >= 0.0:
			out.append_array([p, q, r])
		else:
			out.append_array([p, r, q])
	return out


## Close a ring with a triangle fan to `centre`, every triangle facing `outward`.
##
## Orientation is decided per triangle against that direction rather than by
## winding the fan to match the tube. _orient below weighs the enclosed volume of
## the whole soup, so a cap wound backwards inside an otherwise correct solid
## passes it — the shell reads solid and you can see in through one end.
static func _cap(ring: Array, centre: Vector3, outward: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for s in ring.size():
		var a: Vector3 = ring[s]
		var b: Vector3 = ring[(s + 1) % ring.size()]
		if (a - centre).cross(b - centre).dot(outward) >= 0.0:
			out.append_array([centre, a, b])
		else:
			out.append_array([centre, b, a])
	return out


# ── Helpers (from gen_nunchuk.gd) ────────────────────────────────────────────

## Weld, smooth-shade and pack a triangle soup. Indexing FIRST is what makes
## generate_normals average across the seams instead of faceting every quad.
func _smooth(tris: Array[Vector3]) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in _orient(tris):
		st.add_vertex(v)
	st.index()
	st.generate_normals()
	return st.commit()


func _smooth_sheet(tris: Array[Vector3]) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in tris:
		st.add_vertex(v)
	st.index()
	st.generate_normals()
	return st.commit()


func _save_sheet(mesh: ArrayMesh, path: String) -> void:
	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	print("[gen] %-52s err=%d  %.4f x %.4f x %.4f m  (sheet)"
		% [path, err, ab.size.x, ab.size.y, ab.size.z])


## Turn a solid the right way out if it came out inside in.
##
## The sign here is NOT the textbook one, and getting it from the textbook is how
## the first cut of this shipped a shell you could see straight through.
##
## Godot's front face is the CLOCKWISE one, so `generate_normals` returns the
## negative of the usual (b-a) x (c-a). A soup wound anticlockwise-from-outside —
## the orientation the divergence theorem calls positive volume, and the one
## gen_nunchuk.gd's identical `_orient` selects — is therefore back-to-front for
## the renderer: every outward face is culled, the shell stops writing depth, and
## whatever is inside it draws through. That is exactly what the B trigger did.
##
## So the target is NEGATIVE volume by this measure. Believe `_check_outward`
## below rather than this comment; it is the part that can fail.
static func _orient(tris: Array[Vector3]) -> Array[Vector3]:
	if _volume(tris) <= 0.0:
		return tris
	var out: Array[Vector3] = []
	for i in range(0, tris.size(), 3):
		out.append_array([tris[i], tris[i + 2], tris[i + 1]])
	return out


## Signed volume of a closed triangle soup, anticlockwise-positive. Independent of
## where the origin sits, which a "does this normal point away from the middle"
## test is not.
static func _volume(tris: Array[Vector3]) -> float:
	var v := 0.0
	for i in range(0, tris.size(), 3):
		v += tris[i].dot(tris[i + 1].cross(tris[i + 2])) / 6.0
	return v


func _save(mesh: ArrayMesh, path: String) -> void:
	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	var arrays := mesh.surface_get_arrays(0)
	var tris: int = (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	print("[gen] %-52s err=%d  %.4f x %.4f x %.4f m  %d tris  %s"
		% [path, err, ab.size.x, ab.size.y, ab.size.z, tris, _check_outward(mesh)])


## Does this solid face outward, as the RENDERER will read it?
##
## Not a volume sign — that is the test that was wrong. This reads the normals
## actually stored in the committed mesh, at the six vertices furthest along each
## axis, and asks whether each one points the way that vertex faces. On a closed
## convex-ish solid the extreme vertex along +Y is on the top surface and its
## normal must have a positive Y, and so on round all six.
##
## It is worth the six lines because it is the only check here that can tell an
## inside-out shell from a correct one. A volume sign, an AABB and a manifold edge
## count are all identical for both, and all three passed while the shell was
## inside out.
static func _check_outward(mesh: ArrayMesh) -> String:
	var arrays := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var bad: Array[String] = []
	var axes := {"+X": Vector3.RIGHT, "-X": Vector3.LEFT, "+Y": Vector3.UP,
		"-Y": Vector3.DOWN, "+Z": Vector3.BACK, "-Z": Vector3.FORWARD}
	for label: String in axes:
		var axis: Vector3 = axes[label]
		var best := 0
		for i in v.size():
			if v[i].dot(axis) > v[best].dot(axis):
				best = i
		if n[best].dot(axis) <= 0.0:
			bad.append(label)
	return "outward" if bad.is_empty() else "<-- INSIDE OUT on %s" % ", ".join(bad)


# ── Seats ────────────────────────────────────────────────────────────────────

## Every face feature wiimote.tscn authors by hand, and how far each one now
## stands off the crowned shell. This is the whole reason the crown could be
## taken on: the claim is that pinning its apex at x = 0 leaves every seat still
## seated, and a claim like that is worth exactly what it is measured at.
##
## name, x, z, authored y, and how far the feature's own underside sits below
## that authored y (0 for a bare marker).
##
## POWER's well is sampled at the four cardinal points of the torus's own centre
## line, not at the corner of its bounding box. The box corner is a place the ring
## never reaches, and measuring there reports a float the part cannot have — which
## is how you end up lowering something that was seated.
const _SEATS := [
	["PowerWell -x", -0.0131,  -0.0660, 0.0155,  0.0008],
	["PowerWell +x", -0.0059,  -0.0660, 0.0155,  0.0008],
	["PowerWell -z", -0.0095,  -0.0696, 0.0155,  0.0008],
	["PowerWell +z", -0.0095,  -0.0624, 0.0155,  0.0008],
	["PowerButton ", -0.0095,  -0.0660, 0.0158,  0.0010],
	["DPad edge   ",  0.0095,  -0.0440, 0.0155,  0.0015],
	["AButton     ",  0.0000,  -0.0180, 0.0155,  0.0015],
	["MinusButton ", -0.0110,   0.0040, 0.0155,  0.0013],
	["HomeButton  ",  0.0000,   0.0040, 0.0155,  0.0013],
	["PlusButton  ",  0.0110,   0.0040, 0.0155,  0.0013],
	["speaker hole",  0.0034,   0.0271, 0.0150,  0.0002],
	["OneButton   ",  0.0000,   0.0450, 0.0155,  0.0013],
	["TwoButton   ",  0.0000,   0.0580, 0.0155,  0.0013],
	["LED index   ",  0.0125,   0.0658, 0.0150,  0.0002],
	["LED4 lens   ",  0.0125,   0.0695, 0.0152,  0.0005],
]


func _report_seats() -> void:
	print("[gen] seat            x mm    z mm   surface    under-face clearance")
	for row: Array in _SEATS:
		var x: float = row[1]
		var z: float = row[2]
		var y: float = row[3]
		var drop: float = row[4]
		var surf := _top_y(x, z)
		var clear := (y - drop) - surf
		var flag := ""
		if surf == -INF:
			flag = "  <-- OFF THE SHELL"
		elif clear > 0.0:
			flag = "  <-- FLOATS"
		print("[gen]  %s %+6.2f %+7.2f  %+8.4f  %+7.3f mm%s"
			% [row[0], x * 1000.0, z * 1000.0, surf, clear * 1000.0, flag])


## The shell's depth down its own length, against the reference it was measured
## from. Printed rather than asserted: the taper is a CURVE and there is no single
## number that is right or wrong about it, but a column of depths sitting beside
## the measured column is something a person can actually check, and the earlier
## flat back would be obvious in it at a glance.
func _report_profile() -> void:
	print("[gen] depth down the body (face at +0.0150; reference in brackets)")
	var ref := {0.00: 17.4, 0.02: 20.8, 0.06: 20.8, 0.10: 20.6, 0.14: 20.2,
		0.18: 20.7, 0.20: 21.2, 0.22: 22.9, 0.24: 26.4, 0.28: 28.8, 0.32: 26.9,
		0.36: 29.8, 0.40: 30.0, 0.60: 30.0, 0.80: 30.0, 0.92: 29.6, 1.00: 24.6}
	for t: float in ref:
		var d: float = (_sample(_SHELL, t, 2) + _sample(_SHELL, t, 3)) * 1000.0
		# 0.24-0.32 is where the TRIGGER crosses the reference silhouette, so the
		# measurement there is the trigger, not the shell. Flagged rather than
		# chased: matching the shell to it would model the trigger twice.
		var note := "  (trigger crosses here)" if t > 0.23 and t < 0.33 else ""
		print("[gen]   t=%.2f  %5.1f mm  [ref %5.1f]%s" % [t, d, ref[t], note])


## Height of the shell's upper surface at (x, z). The crown makes this a real
## query rather than the constant 0.015 every seat above was authored against.
static func _top_y(x: float, z: float) -> float:
	var t := clampf((z - Z_NOSE) / (Z_TAIL - Z_NOSE), 0.0, 1.0)
	var hx := _sample(_SHELL, t, 1)
	var yt := _sample(_SHELL, t, 2)
	var rt := minf(_sample(_SHELL, t, 4), minf(hx, yt))
	var ax := absf(x)
	var y := yt
	if ax > hx - rt:
		var dx := ax - (hx - rt)
		if dx >= rt:
			return -INF
		y = (yt - rt) + sqrt(rt * rt - dx * dx)
	if y > 0.0 and yt > 0.0:
		var nx := clampf(x / hx, -1.0, 1.0)
		y -= CROWN * nx * nx * clampf(y / yt, 0.0, 1.0)
	return y

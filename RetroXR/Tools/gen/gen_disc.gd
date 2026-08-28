## Bakes to-scale optical discs to Scenes/Objects/media/disc_{120,80}mm.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen/gen_disc.gd
##
## Replaces the solid CylinderMesh that disc.tscn, dvd_disc.tscn and audio_disc.tscn
## each defined separately — three thicknesses (2.5/1.5/1.5 mm against a real 1.2 mm),
## three silvers, and no centre hole on any of them.
##
## Real Red Book / DVD geometry: 1.2 mm thick (1.3 over the stacking ring), 15 mm
## centre hole. Three diameters are baked — 120 mm, GameCube's 80 mm mini-DVD and
## the PSP's 64 mm UMD platter. They are separate MESHES rather than one scaled
## mesh on purpose: the bore, the thickness and the stacking ring are the same at
## every size, so a uniform scale would shrink them along with the diameter.
##
## The disc lies in XZ and is lathed about Y, matching the CylinderMesh it replaces,
## so every snap pose, tray seat and spin axis downstream keeps working.
##
## Two custom vertex attributes carry everything Shaders/disc.gdshader needs, and
## they are the reason this is a SurfaceTool bake rather than a Blender export:
##
##   UV     planar label UV in [0,1] over the disc's bounding square, so the
##          scraped 600x600 art maps 1:1 by construction. The art is authored
##          full-bleed to the rim with its own transparent centre hole, so no
##          fitting is wanted.
##   UV2.x  face class: 1.0 label / 0.0 data / 0.5 rim and bore.
##
## The zone radii the shader needs are NOT baked. It derives them from
## length(VERTEX.xz), which is exact, costs one vertex instruction, and is immune
## to two things a baked radius is not: attribute compression (16-bit UV2 would
## quantise a 0..0.06 range against a [0,1] scale and band the radial gradient),
## and node scale, which lives in MODEL_MATRIX rather than in VERTEX.
##
## Normals are written explicitly rather than left to generate_normals(), which
## welds by full vertex hash — meaning the instant a per-vertex attribute changes,
## whether the rim gets a hard crease or a smooth one becomes an accident of the
## attribute values. A lathe's normal is analytic: for a profile step (dr, dy) the
## outward normal in the half-plane is normalize((-dy, dr)), which is smooth around
## the circumference and hard-edged across the profile. Exactly what is wanted.
##
## No radial subdivision. The faces are flat and UV is linear in position, so a
## single quad from hole to rim is EXACT, not an approximation.
##
## No material is baked in: the disc's look is per-instance (PS1 black, PS2 blue,
## CD silver...), so the .tscn supplies a resource_local_to_scene ShaderMaterial.
extends SceneTree

const OUT_120 := "res://Scenes/Objects/media/disc_120mm.res"
const OUT_80 := "res://Scenes/Objects/media/disc_80mm.res"
const OUT_64 := "res://Scenes/Objects/media/disc_64mm.res"
const OUT_LP := "res://Scenes/Objects/media/record_lp.res"

## 15 mm centre hole, 1.2 mm thick — identical on a CD, a DVD and a mini-DVD.
const R_HOLE := 0.0075
const HALF_T := 0.0006

## A 1.2 mm slab with a razor edge reads as a decal. The chamfer is there to catch
## a highlight along the rim, which is what makes it read as a solid object; it is
## far too small to be seen as geometry.
const CHAMFER := 0.00015

## The stacking ring: a shallow raised annulus on the label side, there so stacked
## discs rest on it and never touch each other's data area. Only 0.08 mm proud —
## far too small to read as geometry, but the two ramp faces catch a highlight
## line either side of it, which is a detail the eye picks up on a real disc.
const RING_IN := 0.0160
const RING_OUT := 0.0210
const RING_RAMP := 0.0005
const RING_H := 0.00008

## A 12" LP. 302 mm across (the nominal "12 inch" is the trim size, not the disc),
## a 7.24 mm spindle hole, 1.9 mm thick — none of which is a CD figure. The label
## is the standard 4 inch, and the lead-out groove ends about 60 mm out from the
## spindle on a full side.
const LP_R_OUT := 0.1510
const LP_R_HOLE := 0.00362
const LP_HALF_T := 0.00095
const LP_R_LABEL := 0.0508
const LP_R_LEAD_OUT := 0.1455
## The two lands a stacked record rests on — the label area and the outer lip —
## which is why the grooves between them never touch anything. 0.15 mm proud, so
## like the CD's stacking ring it is a highlight line rather than geometry.
const LP_LAND := 0.00015
const LP_LAND_RAMP := 0.0016
const LP_LIP := 0.0035

const FACE_LABEL := 1.0
const FACE_DATA := 0.0
const FACE_EDGE := 0.5


## 96 segments, not the 160 first tried. The silhouette error on a 60 mm radius is
## 60 * (1 - cos(1.875 deg)) = 0.032 mm — well under what anyone resolves holding a
## disc at arm's length. 2304 triangles with the stacking ring.
const SEGMENTS := 96


func _init() -> void:
	_bake(OUT_120, 0.060, SEGMENTS)
	_bake(OUT_80, 0.040, SEGMENTS)
	# The PSP's bare UMD platter. MediaDimensions calls it 64 mm; the real one is
	# 60 mm inside a 64 mm caddy, and the caddy is what that entry was measured
	# from. Kept at 64 so the two stay in step. The 15 mm bore is the standard
	# optical-disc figure rather than a measured UMD one — plausible against
	# photographs, but not verified.
	_bake(OUT_64, 0.032, SEGMENTS)
	_bake_lp(OUT_LP, SEGMENTS)
	quit()


## A 12" LP, for the record player. Deliberately a SEPARATE bake rather than a
## parameterised _bake: a record shares the lathe and the face-class convention
## with an optical disc and nothing else. Every dimension differs (302 mm across a
## 7.24 mm spindle hole at 1.9 mm thick, against 120 mm across 15 mm at 1.2), it
## has no stacking ring, and it carries a paper label on BOTH sides where a CD has
## a printed face and a data face. Keeping _bake untouched also means the three
## optical discs cannot be perturbed by a change made for this one.
##
## The profile adds a raised outer lip and a raised label land — the two places a
## stacked record actually touches, and the reason the grooves never do.
func _bake_lp(path: String, segs: int) -> void:
	var r_out := LP_R_OUT
	var prof := PackedVector2Array([
		Vector2(LP_R_HOLE, LP_HALF_T - CHAMFER),                 # 0
		Vector2(LP_R_HOLE + CHAMFER, LP_HALF_T),                 # 1
		Vector2(LP_R_LABEL, LP_HALF_T),                          # 2  label land
		Vector2(LP_R_LABEL + LP_LAND_RAMP, LP_HALF_T - LP_LAND), # 3  down to grooves
		Vector2(LP_R_LEAD_OUT, LP_HALF_T - LP_LAND),             # 4  grooved area
		Vector2(r_out - LP_LIP, LP_HALF_T),                      # 5  up to the lip
		Vector2(r_out - CHAMFER, LP_HALF_T),                     # 6  lip land
		Vector2(r_out, LP_HALF_T - CHAMFER),                     # 7  rim chamfer
		Vector2(r_out, -LP_HALF_T + CHAMFER),                    # 8  rim
		Vector2(r_out - CHAMFER, -LP_HALF_T),                    # 9  rim chamfer
		Vector2(r_out - LP_LIP, -LP_HALF_T),                     # 10 lip land
		Vector2(LP_R_LEAD_OUT, -LP_HALF_T + LP_LAND),            # 11 grooved area
		Vector2(LP_R_LABEL + LP_LAND_RAMP, -LP_HALF_T + LP_LAND),# 12
		Vector2(LP_R_LABEL, -LP_HALF_T),                         # 13 label land
		Vector2(LP_R_HOLE + CHAMFER, -LP_HALF_T),                # 14
		Vector2(LP_R_HOLE, -LP_HALF_T + CHAMFER),                # 15 bore chamfer
		Vector2(LP_R_HOLE, LP_HALF_T - CHAMFER),                 # 16 == 0, closes
	])
	var faces := PackedFloat32Array([
		FACE_EDGE,    # 0-1   bore chamfer, side A
		FACE_LABEL,   # 1-2   label, side A
		FACE_EDGE,    # 2-3   land ramp down to the grooves
		FACE_DATA,    # 3-4   grooves, side A
		FACE_EDGE,    # 4-5   ramp up to the outer lip
		FACE_DATA,    # 5-6   lip land (ungrooved, but reads as record surface)
		FACE_EDGE,    # 6-7   rim chamfer
		FACE_EDGE,    # 7-8   rim
		FACE_EDGE,    # 8-9   rim chamfer
		FACE_DATA,    # 9-10  lip land, side B
		FACE_EDGE,    # 10-11 ramp down
		FACE_DATA,    # 11-12 grooves, side B
		FACE_EDGE,    # 12-13 land ramp
		FACE_LABEL,   # 13-14 label, side B
		FACE_EDGE,    # 14-15 bore chamfer, side B
		FACE_EDGE,    # 15-16 bore wall
	])

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_lathe(st, prof, faces, r_out, segs)
	st.index()

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())

	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	var arrays := mesh.surface_get_arrays(0)
	var verts: int = arrays[Mesh.ARRAY_VERTEX].size()
	var tris: int = arrays[Mesh.ARRAY_INDEX].size() / 3
	print("[gen] %s err=%d  %.1f x %.1f x %.1f mm  hole %.1f mm  segs %d  tris %d  verts %d" % [
		path, err, ab.size.x * 1000.0, ab.size.y * 1000.0, ab.size.z * 1000.0,
		LP_R_HOLE * 2000.0, segs, tris, verts])


func _bake(path: String, r_out: float, segs: int) -> void:
	# One closed loop: out across the label face, down the rim, back in across the
	# data face, up through the bore. Ordering is load-bearing — the outward normal
	# is derived from each step's direction, so the loop must run this way round.
	var prof := PackedVector2Array([
		Vector2(R_HOLE, HALF_T - CHAMFER),              # 0
		Vector2(R_HOLE + CHAMFER, HALF_T),              # 1
		Vector2(RING_IN, HALF_T),                       # 2  label face, inner
		Vector2(RING_IN + RING_RAMP, HALF_T + RING_H),  # 3  ramp up
		Vector2(RING_OUT - RING_RAMP, HALF_T + RING_H), # 4  stacking ring crown
		Vector2(RING_OUT, HALF_T),                      # 5  ramp down
		Vector2(r_out - CHAMFER, HALF_T),               # 6  label face, outer
		Vector2(r_out, HALF_T - CHAMFER),               # 7  rim chamfer
		Vector2(r_out, -HALF_T + CHAMFER),              # 8  rim
		Vector2(r_out - CHAMFER, -HALF_T),              # 9  rim chamfer
		Vector2(R_HOLE + CHAMFER, -HALF_T),             # 10 data face
		Vector2(R_HOLE, -HALF_T + CHAMFER),             # 11 bore chamfer
		Vector2(R_HOLE, HALF_T - CHAMFER),              # 12 == 0, closes the bore
	])
	# Per-segment face id. The chamfers count as edge: at 0.15 mm they are a
	# highlight line, not a surface anyone reads as printed or as data.
	var faces := PackedFloat32Array([
		FACE_EDGE,    # 0-1  bore chamfer, label side
		FACE_LABEL,   # 1-2  label face, inner
		FACE_LABEL,   # 2-3  stacking ring, ramp up
		FACE_LABEL,   # 3-4  stacking ring, crown
		FACE_LABEL,   # 4-5  stacking ring, ramp down
		FACE_LABEL,   # 5-6  label face, outer
		FACE_EDGE,    # 6-7   rim chamfer, label side
		FACE_EDGE,    # 7-8   rim
		FACE_EDGE,    # 8-9   rim chamfer, data side
		FACE_DATA,    # 9-10  data face
		FACE_EDGE,    # 10-11 bore chamfer, data side
		FACE_EDGE,    # 11-12 bore wall
	])

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_lathe(st, prof, faces, r_out, segs)
	# Weld. The lathe emits six unshared vertices per quad, and PickableHighlight
	# builds its outline hull by hashing every vertex through a GDScript
	# Dictionary — on first hover, on the Quest. Indexing merges everything except
	# the creases (whose normals genuinely differ), roughly halving that cost.
	st.index()

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())

	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	var arrays := mesh.surface_get_arrays(0)
	var verts: int = arrays[Mesh.ARRAY_VERTEX].size()
	var tris: int = arrays[Mesh.ARRAY_INDEX].size() / 3
	print("[gen] %s err=%d  %.1f x %.1f x %.1f mm  hole %.1f mm  segs %d  tris %d  verts %d" % [
		path, err, ab.size.x * 1000.0, ab.size.y * 1000.0, ab.size.z * 1000.0,
		R_HOLE * 2000.0, segs, tris, verts])


## Revolve a (radius, y) profile about the Y axis, writing the analytic normal,
## the planar UV and the face-class UV2 per vertex.
##
## sin(a) is negated so that swapping the lathe axis from Z to Y stays a rotation
## rather than a reflection. Winding is then set to agree with the analytic
## normals — see the note at the emission site, which is the one thing here that
## is easy to get backwards and silent when you do.
func _lathe(st: SurfaceTool, prof: PackedVector2Array, faces: PackedFloat32Array,
		r_out: float, segs: int) -> void:
	var span := r_out * 2.0
	for s in range(prof.size() - 1):
		var r0: float = prof[s].x
		var y0: float = prof[s].y
		var r1: float = prof[s + 1].x
		var y1: float = prof[s + 1].y
		if is_equal_approx(r0, r1) and is_equal_approx(y0, y1):
			continue
		# Outward normal of this profile step, in the (radius, y) half-plane.
		var n2 := Vector2(-(y1 - y0), r1 - r0).normalized()
		var face: float = faces[s]

		for i in segs:
			var a0: float = TAU * float(i) / float(segs)
			var a1: float = TAU * float(i + 1) / float(segs)
			var c0 := cos(a0)
			var s0 := -sin(a0)
			var c1 := cos(a1)
			var s1 := -sin(a1)
			# p00 / p01 / p11 / p10 by (angle index, profile index), wound so the
			# face agrees with the analytic normal above. gen_rca_plug's rule is
			# that a constant-axis step faces the axis when the radius SHRINKS —
			# this profile grows outwards along the label face, so its winding is
			# the reverse of that one's and the second and third corners swap.
			# Getting this backwards culls the label face and silently draws the
			# data face in its place, normals and all.
			_vert(st, c0, s0, r0, y0, n2, face, span)
			_vert(st, c1, s1, r1, y1, n2, face, span)
			_vert(st, c0, s0, r1, y1, n2, face, span)
			_vert(st, c0, s0, r0, y0, n2, face, span)
			_vert(st, c1, s1, r0, y0, n2, face, span)
			_vert(st, c1, s1, r1, y1, n2, face, span)


func _vert(st: SurfaceTool, ca: float, sa: float, r: float, y: float,
		n2: Vector2, face: float, span: float) -> void:
	var x := ca * r
	var z := sa * r
	st.set_normal(Vector3(ca * n2.x, n2.y, sa * n2.x).normalized())
	# Planar, over the disc's bounding square: the art is authored full-bleed.
	st.set_uv(Vector2(x / span + 0.5, z / span + 0.5))
	st.set_uv2(Vector2(face, 0.0))
	st.add_vertex(Vector3(x, y, z))

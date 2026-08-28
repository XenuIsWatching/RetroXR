## Bakes the reusable mains connector family used by the bedroom props.
## Connector mating planes are z=0; plugs point +Z into sockets and cords leave -Z.
extends SceneTree

const PlugMats := preload("res://Tools/plug_materials.gd")
const DIR := "res://Scenes/Objects/cables/"

func _init() -> void:
	_bake_nema()
	_bake_c13()
	_bake_c14()
	_bake_nema_1_15(false)
	_bake_nema_1_15(true)
	_bake_c7(false)
	_bake_c7(true)
	_bake_c8(false)
	_bake_c8(true)
	quit()

## NEMA WD-6 blade geometry: 12.7 mm centre spacing, 1.5 mm thickness,
## 6.35 mm line blade and 7.9 mm polarized neutral blade. The moulding is a
## compact one-piece vinyl style, not the much larger rewireable plug body.
func _bake_nema_1_15(polarized: bool) -> void:
	var plastic := SurfaceTool.new(); plastic.begin(Mesh.PRIMITIVE_TRIANGLES)
	var metal := SurfaceTool.new(); metal.begin(Mesh.PRIMITIVE_TRIANGLES)
	var body := [
		_round_ring(0.000,0.0130,0.0084,0.0042),
		_round_ring(-0.003,0.0140,0.0090,0.0045),
		_round_ring(-0.025,0.0132,0.0085,0.0042),
		_round_ring(-0.029,0.0095,0.0064,0.0038),
	]
	_loft_chain(plastic,body,100); _cap(plastic,body[0],Vector3.ZERO,true)
	# Low-profile ribs ease the moulding into 18/2 SPT zip cord. The 7.2 x 3.6
	# mm exit matches two touching 1.8 mm-radius ribbon strands exactly.
	var boot := [
		body[-1],
		_round_ring(-0.033,0.0078,0.0052,0.0032),
		_round_ring(-0.036,0.0083,0.0056,0.0034),
		_round_ring(-0.040,0.0055,0.0035,0.0025),
		_round_ring(-0.043,0.0060,0.0038,0.0027),
		_round_ring(-0.047,0.0036,0.0018,0.0018),
	]
	_loft_chain(plastic,boot,110); _cap(plastic,boot[-1],Vector3(0,0,-0.047),false)
	var neutral_width := 0.0079 if polarized else 0.00635
	_box(metal,Vector3(-0.00635,0,0.0080),Vector3(0.0015,neutral_width,0.0160))
	_box(metal,Vector3( 0.00635,0,0.0080),Vector3(0.0015,0.00635,0.0160))
	var suffix := "_polarized" if polarized else ""
	_save(DIR + "nema_1_15%s_plug.res" % suffix,plastic,metal,
		PlugMats.matte(Color(0.050,0.048,0.045),0.78),PlugMats.metal(Color(0.72,0.52,0.20),0.30))

## SCHURTER 4810 gives the straight C7 moulding as 19.6 x 12 mm. The mating
## contour below follows the usual 16-ish x 8-ish figure-eight profile with
## 8.0 mm contact spacing; C7P replaces the neutral lobe with the square key
## shown on Quail WS-027A-2's dimensioned drawing.
func _bake_c7(polarized: bool) -> void:
	var plastic := SurfaceTool.new(); plastic.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dark := SurfaceTool.new(); dark.begin(Mesh.PRIMITIVE_TRIANGLES)
	var face0 := _c7_ring(0.000,polarized,1.0)
	var face1 := _c7_ring(-0.003,polarized,1.10)
	# _round_ring begins on the upper-right side; the figure-eight begins at its
	# top waist. Rotate each rear ring six vertices so corresponding points stay
	# on the same side of the moulding instead of twisting the loft.
	var body_back := _rotate_ring(_round_ring(-0.032,0.0105,0.0063,0.0035),6)
	_loft(plastic,face0,face1,200)
	_loft(plastic,face1,body_back,201)
	var boot := [
		body_back,
		_rotate_ring(_round_ring(-0.036,0.0082,0.0052,0.0030),6),
		_rotate_ring(_round_ring(-0.039,0.0088,0.0056,0.0032),6),
		_rotate_ring(_round_ring(-0.043,0.0055,0.0035,0.0025),6),
		_rotate_ring(_round_ring(-0.046,0.0060,0.0038,0.0027),6),
		_rotate_ring(_round_ring(-0.050,0.0036,0.0018,0.0018),6),
	]
	_loft_chain(plastic,boot,202); _cap(plastic,boot[-1],Vector3(0,0,-0.050),false)
	_cap(plastic,face0,Vector3.ZERO,true)
	# Two recessed female contacts, 8.0 mm on centre.
	for x in [-0.004,0.004]:
		_cylinder(dark,Vector3(x,0,0.0006),0.00145,0.0012,16)
	var suffix := "_polarized" if polarized else ""
	_save(DIR + "iec_c7%s_plug.res" % suffix,plastic,dark,
		PlugMats.matte(Color(0.045,0.045,0.050),0.76),PlugMats.matte(Color(0.006,0.006,0.008),0.98))

## Matching panel-mount C8 and C8P inlets. The mating shroud projects from the
## z=0 seating plane and keeps both pins inside it, like the existing C14 asset.
func _bake_c8(polarized: bool) -> void:
	var plastic := SurfaceTool.new(); plastic.begin(Mesh.PRIMITIVE_TRIANGLES)
	var metal := SurfaceTool.new(); metal.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(plastic,Vector3(0,0,-0.0015),Vector3(0.0280,0.0160,0.0030))
	_box(plastic,Vector3(0,0,-0.0090),Vector3(0.0210,0.0125,0.0150))
	var shroud0 := _c7_ring(0.000,polarized,1.04)
	var shroud1 := _c7_ring(0.006,polarized,1.04)
	_loft(plastic,shroud0,shroud1,250)
	for x in [-0.004,0.004]:
		_cylinder(metal,Vector3(x,0,0.0030),0.00115,0.0060,16)
	var suffix := "_polarized" if polarized else ""
	_save(DIR + "iec_c8%s_inlet.res" % suffix,plastic,metal,
		PlugMats.matte(Color(0.035,0.035,0.040),0.82),PlugMats.metal(Color(0.68,0.69,0.66),0.38))

func _bake_nema() -> void:
	var plastic := SurfaceTool.new(); plastic.begin(Mesh.PRIMITIVE_TRIANGLES)
	var metal := SurfaceTool.new(); metal.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Rounded straight-body overmold. The broad palm end tapers into a flexible
	# ribbed boot instead of ending in the square step the placeholder used.
	var body := [
		_round_ring(0.000,0.0157,0.0175,0.0040),
		_round_ring(-0.003,0.01765,0.01945,0.0050), # Leviton: 35.3 x 38.9
		_round_ring(-0.029,0.01765,0.01945,0.0050),
		_round_ring(-0.033,0.0145,0.0160,0.0045),
	]
	_loft_chain(plastic,body,10); _cap(plastic,body[0],Vector3(0,0,0),true)
	var boot := [
		_round_ring(-0.033,0.0105,0.0115,0.0040),
		_round_ring(-0.037,0.0093,0.0102,0.0038),
		_round_ring(-0.040,0.0100,0.0109,0.0040), # molded flex rib
		_round_ring(-0.043,0.0085,0.0093,0.0036),
		_round_ring(-0.046,0.0092,0.0100,0.0038), # molded flex rib
		_round_ring(-0.0504,0.00425,0.00425,0.00425), # 8.5 mm SJT jacket
	]
	_loft_chain(plastic,boot,30); _cap(plastic,boot[-1],Vector3(0,0,-0.0504),false)
	# Brass blades: neutral is wider, matching the polarized receptacle.
	# MP005982 drawing: 6.3 x 1.5 mm solid blades and Ø4.75 mm earth pin.
	_box(metal, Vector3(-0.00635,0.0042,0.0085), Vector3(0.0015,0.0063,0.0170))
	_box(metal, Vector3( 0.00635,0.0042,0.0085), Vector3(0.0015,0.0063,0.0170))
	_cylinder(metal, Vector3(0,-0.0078,0.0105), 0.002375, 0.0210, 16)
	_save(DIR + "nema_5_15_plug.res", plastic, metal,
		PlugMats.matte(Color(0.055,0.052,0.048),0.78), PlugMats.metal(Color(0.72,0.52,0.20),0.30))

func _bake_c13() -> void:
	var plastic := SurfaceTool.new(); plastic.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dark := SurfaceTool.new(); dark.begin(Mesh.PRIMITIVE_TRIANGLES)
	# IEC 60320 C13 overmold. The mating face is the real keyed six-sided outline;
	# its clipped upper corners are the feature that distinguishes it at a glance.
	var face0 := _iec_ring(0.000,0.0270,0.0196)
	var face1 := _iec_ring(-0.003,0.0287,0.0210)
	# Schurter 4782 face/body envelope: 28.7 x 21 mm.
	var body_back := _round_ring(-0.038,0.01435,0.0105,0.0040)
	_loft(plastic,face0,face1,40)
	# Equal vertex counts (24) let the keyed face ease into the rounded hand grip.
	_loft(plastic,face1,body_back,41)
	var boot := [
		body_back,
		_round_ring(-0.042,0.0118,0.0090,0.0038),
		_round_ring(-0.046,0.0125,0.0097,0.0040), # relief rib
		_round_ring(-0.050,0.0102,0.0078,0.0035),
		_round_ring(-0.054,0.0109,0.0085,0.0038), # relief rib
		_round_ring(-0.058,0.0068,0.0058,0.0028),
		_round_ring(-0.062,0.00425,0.00425,0.00425), # 8.5 mm cable entry
	]
	_loft_chain(plastic,boot,42); _cap(plastic,boot[-1],Vector3(0,0,-0.062),false)
	_cap(plastic,face0,Vector3(0,0,0),true)
	# Three recessed female contacts in the standard two-over-one arrangement.
	for p in [Vector2(-0.007,0.0048), Vector2(0.007,0.0048), Vector2(0,-0.0060)]:
		_box(dark, Vector3(p.x,p.y,0.0006), Vector3(0.0032,0.0068,0.0012))
	_save(DIR + "iec_c13_plug.res", plastic, dark,
		PlugMats.matte(Color(0.045,0.045,0.050),0.76), PlugMats.matte(Color(0.008,0.008,0.010),0.96))

func _bake_c14() -> void:
	var plastic := SurfaceTool.new(); plastic.begin(Mesh.PRIMITIVE_TRIANGLES)
	var metal := SurfaceTool.new(); metal.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Schurter 6067: 48 x 22.2 flange, 27 x 19.6 panel body and about 24.8
	# mm total depth. The keyed shroud projects 8 mm; pins stay INSIDE it.
	_box(plastic, Vector3(0,0,-0.0015), Vector3(0.048,0.0222,0.003))
	_box(plastic, Vector3(0,0,-0.0139), Vector3(0.027,0.0196,0.0248))
	var shroud0 := _iec_ring(0.000,0.0270,0.0196)
	var shroud1 := _iec_ring(0.008,0.0270,0.0196)
	_loft(plastic,shroud0,shroud1,70)
	for p in [Vector2(-0.007,0.0048), Vector2(0.007,0.0048), Vector2(0,-0.0060)]:
		_box(metal, Vector3(p.x,p.y,0.004), Vector3(0.0020,0.0055,0.008))
	_save(DIR + "iec_c14_inlet.res", plastic, metal,
		PlugMats.matte(Color(0.035,0.035,0.040),0.82), PlugMats.metal(Color(0.68,0.69,0.66),0.38))

func _save(path: String, a: SurfaceTool, b: SurfaceTool, ma: Material, mb: Material) -> void:
	a.generate_normals(); b.generate_normals()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a.commit_to_arrays()); mesh.surface_set_material(0,ma)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, b.commit_to_arrays()); mesh.surface_set_material(1,mb)
	var err := ResourceSaver.save(mesh,path)
	print("[gen] %s err=%d size=%s" % [path,err,mesh.get_aabb().size])

## 24-point rounded rectangle, matching the outlet generator's dry molded edges.
func _round_ring(z: float, hx: float, hy: float, radius: float) -> PackedVector3Array:
	var out := PackedVector3Array(); var r := minf(radius,minf(hx,hy))
	var centres := [Vector2(hx-r,hy-r),Vector2(-hx+r,hy-r),Vector2(-hx+r,-hy+r),Vector2(hx-r,-hy+r)]
	for corner in 4:
		for sample in 6:
			var a := deg_to_rad(float(corner)*90.0+float(sample)*15.0)
			var p: Vector2 = centres[corner]+Vector2(cos(a),sin(a))*r
			out.append(Vector3(p.x,p.y,z))
	return out

## Six-sided C13 outline, with four samples along each edge so it can loft to the
## 24-point rounded body without collapsed or twisted triangles.
func _iec_ring(z: float, width: float, height: float) -> PackedVector3Array:
	var hx := width*0.5; var hy := height*0.5; var clip := 0.0037
	var corners := [Vector2(hx-clip,hy),Vector2(-hx+clip,hy),Vector2(-hx,hy-clip),Vector2(-hx,-hy),Vector2(hx,-hy),Vector2(hx,hy-clip)]
	var out := PackedVector3Array()
	for i in 6:
		var a: Vector2 = corners[i]; var b: Vector2 = corners[(i+1)%6]
		for s in 4:
			var p := a.lerp(b,float(s)/4.0); out.append(Vector3(p.x,p.y,z))
	return out

## 24-point C7/C8 mating outline. Both variants keep identical topology so the
## rings loft cleanly into the 24-point rounded moulding behind them.
func _c7_ring(z: float, polarized: bool, scale: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var d := 0.0040 * scale
	var r := 0.0048 * scale
	var theta := acos(d/r)
	var h := sqrt(r*r-d*d)
	if polarized:
		var square_side := [
			Vector2(0,h),Vector2(-0.0010*scale,0.0040*scale),Vector2(-0.0030*scale,0.0048*scale),
			Vector2(-0.0076*scale,0.0048*scale),Vector2(-0.0085*scale,0.0045*scale),
			Vector2(-0.0088*scale,0.0037*scale),Vector2(-0.0088*scale,-0.0037*scale),
			Vector2(-0.0085*scale,-0.0045*scale),Vector2(-0.0076*scale,-0.0048*scale),
			Vector2(-0.0030*scale,-0.0048*scale),Vector2(-0.0010*scale,-0.0040*scale),Vector2(0,-h),
		]
		for p in square_side: out.append(Vector3(p.x,p.y,z))
	else:
		for sample in 12:
			var a := lerpf(theta,TAU-theta,float(sample)/12.0)
			out.append(Vector3(-d+cos(a)*r,sin(a)*r,z))
	# Bottom intersection to top intersection around the outside of the round lobe.
	for sample in 12:
		var a := lerpf(PI+theta,3.0*PI-theta,float(sample)/12.0)
		out.append(Vector3(d+cos(a)*r,sin(a)*r,z))
	return out

func _rotate_ring(ring: PackedVector3Array, offset: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in ring.size(): out.append(ring[(i+offset)%ring.size()])
	return out

func _loft_chain(st: SurfaceTool, rings: Array, group: int) -> void:
	for i in rings.size()-1: _loft(st,rings[i],rings[i+1],group+i)

func _loft(st: SurfaceTool, lo: PackedVector3Array, hi: PackedVector3Array, group: int) -> void:
	st.set_smooth_group(group)
	for i in lo.size():
		var j := (i+1)%lo.size()
		st.add_vertex(lo[i]);st.add_vertex(hi[i]);st.add_vertex(hi[j])
		st.add_vertex(lo[i]);st.add_vertex(hi[j]);st.add_vertex(lo[j])

func _cap(st: SurfaceTool, ring: PackedVector3Array, centre: Vector3, front: bool) -> void:
	for i in ring.size():
		var j := (i+1)%ring.size()
		if front:
			st.add_vertex(ring[i]);st.add_vertex(centre);st.add_vertex(ring[j])
		else:
			st.add_vertex(centre);st.add_vertex(ring[i]);st.add_vertex(ring[j])

func _box(st: SurfaceTool, c: Vector3, s: Vector3) -> void:
	var h := s * 0.5
	var v := [c+Vector3(-h.x,-h.y,-h.z),c+Vector3(h.x,-h.y,-h.z),c+Vector3(h.x,h.y,-h.z),c+Vector3(-h.x,h.y,-h.z),c+Vector3(-h.x,-h.y,h.z),c+Vector3(h.x,-h.y,h.z),c+Vector3(h.x,h.y,h.z),c+Vector3(-h.x,h.y,h.z)]
	for f in [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,4,7],[0,7,3],[1,2,6],[1,6,5],[0,1,5],[0,5,4],[3,7,6],[3,6,2]]:
		st.add_vertex(v[f[0]]); st.add_vertex(v[f[1]]); st.add_vertex(v[f[2]])

func _cylinder(st: SurfaceTool, c: Vector3, r: float, length: float, sides: int) -> void:
	var z0 := c.z-length*0.5; var z1 := c.z+length*0.5
	for i in sides:
		var a := TAU*float(i)/sides; var b := TAU*float(i+1)/sides
		var p0 := Vector3(c.x+cos(a)*r,c.y+sin(a)*r,z0); var p1 := Vector3(c.x+cos(b)*r,c.y+sin(b)*r,z0)
		var q0 := Vector3(p0.x,p0.y,z1); var q1 := Vector3(p1.x,p1.y,z1)
		st.add_vertex(p0);st.add_vertex(q1);st.add_vertex(p1);st.add_vertex(p0);st.add_vertex(q0);st.add_vertex(q1)
		st.add_vertex(Vector3(c.x,c.y,z1));st.add_vertex(q1);st.add_vertex(q0)
		st.add_vertex(Vector3(c.x,c.y,z0));st.add_vertex(p0);st.add_vertex(p1)

## RetroSystemModelDualScreen — clamshell dual-screen handhelds (DS / 3DS).
##
## Dual-screen cores render BOTH screens into one composite framebuffer
## (melonDS top/bottom stacked 256×384; patched azahar side-by-side stereo
## 400×480). The C++ VideoHandler drives ONE mesh — a hidden proxy quad
## (the Virtual Boy pattern) — and this model feeds the proxy's emission
## texture into a screen_window ShaderMaterial per visible screen quad:
##   * each quad's `source_rect` selects its region of the composite, and
##   * a stereo top screen (3DS) adds `eye_shift` so the RIGHT eye samples the
##     right-eye half (VIEW_INDEX) — real depth in the headset.
##
## The visible shell — base, hinged lid, both screens + bezels, the touch area,
## the hidden proxy quad, the grabbable lid hinge, cosmetics, and the volume
## slider — is authored in the per-device scene (nds.tscn / n3ds.tscn). This
## script caches those nodes, builds the two window ShaderMaterials at runtime
## (source_tex is live core output — it can only be bound per-frame), feeds the
## screens, and handles touch input.
##
## Video-out: TWO cables (get_video_channels), TOP and BOTTOM, each with its
## own labelled port on the back edge. RetroSystem mirrors the same proxy
## texture onto each connected TV through the same shader, and taps on the
## BOTTOM TV feed the touch screen.
##
## Subclasses set the composite UV rects + stereo eye_shift in _init.
class_name RetroSystemModelDualScreen
extends RetroSystemModelHandheld

const SCREEN_WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")

# Base local frame is the handheld convention: flat, top face +Y, hinge/back
# edge -Z. The lid pivots at the back-top edge (LidPivot, authored in the scene).

## Physical bottom-screen size in metres — read back from the authored
## BottomScreen quad; drives the touch-area UV mapping.
var bottom_screen_size := Vector2(0.061, 0.0457)
## Each screen's region of the composite core framebuffer (set in subclass _init).
var top_uv_rect := Rect2(0.0, 0.0, 1.0, 0.5)
var bottom_uv_rect := Rect2(0.0, 0.5, 1.0, 0.5)
## Right-eye UV-x shift for a stereo side-by-side composite (3DS azahar).
## 0 = mono core output (DS).
var top_eye_shift := 0.0

var _bottom_screen: MeshInstance3D = null
# Screen-cast light for the bottom screen (the base handles the top via _screen).
var _bottom_screen_light: ScreenCastLight = null
var _lid_pivot: Node3D = null
# Grabbable lid hinge. The lid's rotation about X lives on _lid_pivot (0 = flat /
# 180° interior open, 180 = folded shut); the public angle (get/set_lid_angle_deg)
# is the interior open angle, 180 minus that rotation.
var _hinge: VRHinge = null
var _touch: Area3D = null
# Hidden proxy quad the C++ VideoHandler renders the composite into.
var _proxy: MeshInstance3D = null
# screen_window materials feeding each quad from the proxy's texture.
var _top_mat: ShaderMaterial = null
var _bottom_mat: ShaderMaterial = null
# Unlit-LCD materials shown while no core picture exists (authored on the quads).
var _top_off_mat: StandardMaterial3D = null
var _bottom_off_mat: StandardMaterial3D = null
## Half-thickness of the TouchScreen collision box (see _place_screen, which
## sizes it 0.012 deep). The engage window is derived from it so the two cannot
## drift apart, and because _place_screen parks the Area3D on the bottom lens the
## box is CENTRED on the picture: local y = 0 is the glass.
const HALF_THICKNESS := 0.006
## Slack past the box before a touch counts, and the multiple of that at which it
## lets go. 6 + 4 mm reproduces the engage distance this has always used.
const GLASS_TOLERANCE := 0.004
const RELEASE_SCALE := 1.6

# VR fingertip touch state (per engaged controller).
var _touch_ctrl: XRController3D = null
var _touch_smoother := TouchSmoother.new()
var _touch_pointer_down := false
var _touch_controllers: Array[XRController3D] = []


## Measure only the base (bottom clamshell half) when placing the system name
## label, so it lands on the base's front — the same +Z face the START button
## sits on — rather than over the raised lid / top screen. (Used by
## RetroSystem._body_aabb / _place_name_label.)
func name_label_body() -> Node3D:
	# The stand-in body only exists on the fallback path; with the detailed shell
	# in, the base half IS the Shell subtree (its lid rides LidPivot).
	#
	# It has to be VISIBLE to count: an invisible HandheldBody hands the label an
	# empty AABB (RetroSystem._body_aabb skips invisible meshes), so
	# _place_name_label bails and the label stays at its default scene pose,
	# floating instead of sitting on the front.
	var body := find_child("HandheldBody", true, false) as Node3D
	if body != null and body.is_visible_in_tree():
		return body
	return get_node_or_null("Shell")


## Upright on the base's vertical front (+Z) face (where the START button is),
## centred and filling most of the thin base height — not flat on the top.
func name_label_placement() -> Dictionary:
	return {"upright": true, "v_center": 0.5, "h_frac": 0.72}


func _ready() -> void:
	_cache_dual_nodes()
	if not has_baked_shell():
		# A plain clamshell IS this scene: its lid meshes already ride
		# LidPivot, so there is no shell to compose — only the lid's grab box,
		# which _adopt_baked_shell would otherwise have sized at the end.
		_setup_lid_grab()
	else:
		_adopt_baked_shell()
	# Screen-cast lights: both screens glow into the room (base _ready — which sets
	# up the single-screen light — is not called here, so create both explicitly).
	_screen_light = _make_screen_light(_screen)
	_bottom_screen_light = _make_screen_light(_bottom_screen)
	# Editor-only cart-seat preview box — hide at runtime (base _ready, which does
	# this for single-screen handhelds, is not called here).
	_hide_seat_previews()
	# Window materials, ready before the first frame of core output.
	_top_mat = ShaderMaterial.new()
	_top_mat.shader = SCREEN_WINDOW_SHADER
	_bottom_mat = ShaderMaterial.new()
	_bottom_mat.shader = SCREEN_WINDOW_SHADER
	_apply_window_params()
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_touch_controllers.append(node as XRController3D)




## Both screens cast light (base drives only the top via _screen).
func _update_screen_light() -> void:
	_drive_screen_light(_screen, _screen_light, top_uv_rect)
	_drive_screen_light(_bottom_screen, _bottom_screen_light, bottom_uv_rect)


## Exact mesh names in the GLB that belong to the LID (fold with the hinge).
## Everything else is the base half. Override per device.
func _lid_mesh_names() -> PackedStringArray:
	return PackedStringArray()


## Forward (toward +Z, away from the very back edge) correction added to the
## computed hinge Z position. 0 by default — the base's back bounding-box edge
## is a fine hinge estimate on most shells. Override when a shell's real hinge
## sits measurably forward of that edge (see n3ds_model.gd for how this was
## derived: solve for the Z that makes the CLOSED lid's footprint match the
## base's footprint, since the naive back-edge estimate is invisible at the
## open angle the GLB ships in and only shows up once you swing the lid shut).
func _hinge_z_offset() -> float:
	return 0.0


## Downward correction added to the computed hinge Y position (base_top_y —
## the base shell's own top face). 0 by default. Override when the real hinge
## barrel sits measurably below the base's top face, which the naive estimate
## can't see any more than the Z case above can — see n3ds_model.gd.
func _hinge_y_offset() -> float:
	return 0.0


## Swap the primitive clamshell for the detailed GLB. The base script's runtime
## nodes stay authoritative — the live TopScreen/BottomScreen picture quads, the
## ProxyScreen, the TouchScreen pad, the grabbable LidHinge — but they get moved
## onto the GLB's real geometry: centre the base half at the origin, split the
## lid meshes onto LidPivot so they fold with the hinge (LidPivot's rest rotation
## derived from the top lens's normal, its pivot from where the lid plane meets
## the base's top face), drop the picture quads onto the GLB screen lenses, resize
## the base collision + touch pad, and hide the primitive stand-ins, the GLB's own
## opaque screen lenses, and its bundled AV lead. Idempotent (skips if the base
## is already GLB-scaled from a prior run / baked scene).
## Baked-scene cleanup: the editable "Shell" instance re-creates the GLB's own
## lid meshes on load, even though the bake reparented UNROTATED copies onto
## LidPivot — so the Shell-side originals reappear at their authored open-pose
## rotation and float free of the console. Hide those duplicates, plus the GLB's
## own opaque screen lenses + LCD backing (the live TopScreen/BottomScreen quads
## replace them). Runtime-only fix — the baked .tscn is untouched.
func _hide_baked_shell_dupes() -> void:
	var shell := get_node_or_null("Shell") as Node3D
	if shell == null:
		return
	if _lid_pivot != null:
		for lp in _lid_pivot.find_children("*", "MeshInstance3D", true, false):
			var dup := shell.find_child(lp.name, true, false) as MeshInstance3D
			if dup != null:
				dup.visible = false
	for n in shell.find_children("*", "MeshInstance3D", true, false):
		var nm := String(n.name)
		if nm == "screen_mesh Top" or nm == "screen_mesh Bottom" or nm.to_lower().contains("backface"):
			(n as MeshInstance3D).visible = false


## Adopt the detailed shell this scene already bakes: hide the duplicate primitive
## meshes it ships alongside, take body_size from the real base half, and size the
## lid's grab box.
##
## body_size matters more than it looks: _cache_dual_nodes seeds it from the
## primitive HandheldBody box, so without this, collision, the pointer area, the
## cart slot depth, the cable attach point and the power button are all sized to a
## stand-in the player cannot even see.
##
## This used to be _upgrade_dual_to_glb(path), whose remaining ~168 lines
## runtime-loaded a GLB and split its meshes into lid vs base to place the two
## screens. All three detailed clamshells (nds, nds_lite, n3ds) bake that result
## into the .tscn and set the dual_glb_baked meta, so that path never ran.
func _adopt_baked_shell() -> void:
	if _lid_pivot == null or _screen == null or _bottom_screen == null:
		return
	_hide_baked_shell_dupes()
	var baked := _base_half_size()
	if baked.length() > 0.0:
		body_size = baked
	_setup_lid_grab()


func _setup_lid_grab() -> void:
	if _hinge == null or _screen == null or _lid_pivot == null:
		return
	if not (_screen.mesh is QuadMesh):
		return
	var qsize: Vector2 = (_screen.mesh as QuadMesh).size
	var w: float = maxf(qsize.x, 0.01)
	var h: float = maxf(qsize.y, 0.01)
	var st: Transform3D = _screen.transform          # quad-local → LidPivot-local
	# Which ±Y edge of the quad is the FREE edge (farther from the hinge at the
	# LidPivot origin)? The grab half centres on that edge's side.
	var e_pos: Vector3 = st * Vector3(0.0, h * 0.5, 0.0)
	var e_neg: Vector3 = st * Vector3(0.0, -h * 0.5, 0.0)
	var free_sign: float = 1.0 if e_pos.length() >= e_neg.length() else -1.0
	var center_local: Vector3 = st * Vector3(0.0, free_sign * h * 0.25, 0.0)
	var grab_basis: Basis = st.basis.orthonormalized()
	_hinge.transform = Transform3D(grab_basis, center_local)
	var col := _hinge.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = Vector3(w, h * 0.5, 0.02)
	# VR proximity sphere covers the free half; icon floats off the face normal
	# (quad local +Z) a touch toward the free edge.
	#
	# Capped so it cannot reach back into the console's OWN grabbable body. The
	# sphere is centred on the grab box, so a radius larger than the gap to the
	# body means one hand position satisfies both this hinge and
	# XRToolsFunctionPickup — you reach for the lid and lift the whole machine.
	# Measured 2026-08-01: of the six clamshells only the two 3DS models crossed
	# that line (reach 41.9 mm against a 41.4 mm gap, and 66.6 against 48.5); the
	# DS and GBA SP sat 8-20 mm clear, which is why only the 3DS misbehaved.
	var reach: float = maxf(w, h * 0.5) * 0.55
	_hinge.engage_radius = clampf(minf(reach, _body_clearance() - HINGE_BODY_MARGIN), 0.02, 0.07)


## Gap from the lid's grab box to the console's grabbable body, in metres. The
## body is the box configure_handheld_body() gives the host: body_size, padded.
const HINGE_BODY_MARGIN := 0.004

func _body_clearance() -> float:
	if _hinge == null or _lid_pivot == null:
		return INF
	var p: Vector3 = _lid_pivot.transform * _hinge.transform.origin
	var half: Vector3 = (body_size + Vector3(0.01, 0.01, 0.01)) * 0.5
	var q := Vector3(absf(p.x) - half.x, absf(p.y) - half.y, absf(p.z) - half.z)
	var outside := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0)).length()
	return outside + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)
	# The hint's position is authored on the HingeHint node in each device scene,
	# not set here. Driving it from code used to stand these three lids' hints out
	# in front of the screen while every other lid sat edge-on.


## How far the shell's own (opaque) glass/surface sits over a lens along its
## normal, so the live picture quad can be raised just clear of it. Samples the
## shell body meshes within the screen footprint; falls back to a small default.
## Dimensions of the BASE half of whatever shell is actually present, in model
## space. On the runtime path the lid meshes are reparented onto LidPivot, but a
## BAKED scene can leave them under Shell (nds_lite.tscn does), so the lid names
## are excluded explicitly rather than assumed to have moved — otherwise this
## measures the whole OPEN clamshell and the body comes out twice as tall.
func _base_half_size() -> Vector3:
	var shell := get_node_or_null("Shell") as Node3D
	if shell == null:
		return Vector3.ZERO
	var lidnames := _lid_mesh_names()
	var acc := AABB()
	var first := true
	for n in shell.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.visible or lidnames.has(String(mi.name)):
			continue
		var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
		acc = ab if first else acc.merge(ab)
		first = false
	return Vector3.ZERO if first else acc.size


## How far to hold the picture off the shell surface once that surface has been
## measured. This only has to beat depth-buffer precision — the geometry is
## already accounted for — so it wants to be as small as will not z-fight. It was
## 0.8 mm, which is most of a millimetre of visible gap on something you hold in
## your hands: the DS Phat's bottom picture read as floating a hair off the
## console, because `best` under that screen is 0.2 mm and the margin was the
## rest of it.
const _DEPTH_MARGIN := 0.0002


func _lens_clearance(center: Vector3, normal: Vector3, size: Vector2) -> float:
	var shell := get_node_or_null("Shell") as Node3D
	if shell == null:
		return _DEPTH_MARGIN * 2.0
	var n := normal.normalized()
	# Test the lens's own RECTANGULAR footprint, built on the same basis
	# _place_screen uses so it matches the quad exactly. This used to be a circle
	# of half the LARGER dimension, which on a 63x49 mm screen reaches 32 mm out
	# — past the bezel into the surrounding shell. On the DS Phat, whose lower
	# half is one big mesh with a raised surround, that picked up shell 11.4 mm
	# above the lens and floated the live picture that far off the console.
	var up_hint := Vector3.FORWARD if absf(n.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var ax := up_hint.cross(n)
	if ax.length() < 1e-5:
		ax = Vector3.RIGHT
	ax = ax.normalized()
	var ay := n.cross(ax).normalized()
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var best := 0.0
	var stack: Array[Node] = [shell]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var mi := node as MeshInstance3D
		if mi != null and mi.visible and mi.mesh != null:
			var nm := String(mi.name)
			if not nm.begins_with("screen_mesh") and not nm.to_lower().contains("rca"):
				var xf := global_transform.affine_inverse() * mi.global_transform
				var arr := mi.mesh.surface_get_arrays(0)
				var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				for v in verts:
					var p := xf * v - center
					var along := p.dot(n)
					if along <= 0.0 or along >= 0.02:
						continue
					var inplane := p - n * along
					if absf(inplane.dot(ax)) <= hx and absf(inplane.dot(ay)) <= hy:
						best = maxf(best, along)
		for c in node.get_children():
			stack.append(c)
	return best + _DEPTH_MARGIN


## Position + orient a screen quad (QuadMesh normal is +Z) to face `normal` at
## `where`, both given in this model node's LOCAL space. Set via global_transform
## so it's correct regardless of the quad's parent (TopScreen rides LidPivot).
func _place_screen(quad: MeshInstance3D, where: Vector3, normal: Vector3, _size: Vector2) -> void:
	var z := normal.normalized()
	var up_hint := Vector3.FORWARD if absf(z.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x := up_hint.cross(z)
	if x.length() < 1e-5:
		x = Vector3.RIGHT
	x = x.normalized()
	var y := z.cross(x).normalized()
	quad.global_transform = global_transform * Transform3D(Basis(x, y, z), where)


## Bundled AV lead / plug (RetroXR spawns its own video-out cables).
func _hide_glb_clutter(root: Node3D) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null:
			var nm := String(mi.name).to_lower()
			if nm.contains("rca") or nm.contains("cable") or nm.contains("plug"):
				mi.visible = false
		for c in n.get_children():
			stack.append(c)


## AABB of a mesh in this model node's local space.
func _local_aabb(mi: MeshInstance3D) -> AABB:
	return (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()


## Cache the authored shell nodes and read the dimensions the runtime logic needs.
func _cache_dual_nodes() -> void:
	_lid_pivot = get_node_or_null("LidPivot")
	_screen = get_node_or_null("LidPivot/TopScreen") as MeshInstance3D
	_bottom_screen = get_node_or_null("BottomScreen") as MeshInstance3D
	_proxy = get_node_or_null("ProxyScreen") as MeshInstance3D
	_touch = get_node_or_null("TouchScreen") as Area3D
	_hinge = get_node_or_null("LidPivot/LidHinge") as VRHinge
	_volume_slider = get_node_or_null("VolumeSlider") as VRSlider
	# find_child, not get_node: the stand-in shell is a "Primitive" subtree now.
	var body := find_child("HandheldBody", true, false) as MeshInstance3D
	if body and body.mesh is BoxMesh:
		body_size = (body.mesh as BoxMesh).size
	if _bottom_screen and _bottom_screen.mesh is QuadMesh:
		bottom_screen_size = (_bottom_screen.mesh as QuadMesh).size
	if _screen:
		_top_off_mat = _screen.get_surface_override_material(0) as StandardMaterial3D
	if _bottom_screen:
		_bottom_off_mat = _bottom_screen.get_surface_override_material(0) as StandardMaterial3D


## Interior open angle in degrees: 0 = folded shut, 180 = flat open.
func get_lid_angle_deg() -> float:
	return 180.0 - rad_to_deg(_lid_pivot.rotation.x) if _lid_pivot else 180.0


## Set the interior open angle (0 shut … 180 flat).
func set_lid_angle_deg(open_deg: float) -> void:
	var rot := clampf(180.0 - open_deg, 0.0, 180.0)
	if _hinge:
		_hinge.set_rotation_deg_no_signal(rot)
	elif _lid_pivot:
		_lid_pivot.rotation.x = deg_to_rad(rot)


## Push the UV windows onto the window materials (rects are set by subclass
## _init, so once at build time is enough).
func _apply_window_params() -> void:
	_top_mat.set_shader_parameter("source_rect",
		Vector4(top_uv_rect.position.x, top_uv_rect.position.y,
			top_uv_rect.size.x, top_uv_rect.size.y))
	_top_mat.set_shader_parameter("eye_shift", top_eye_shift)
	_bottom_mat.set_shader_parameter("source_rect",
		Vector4(bottom_uv_rect.position.x, bottom_uv_rect.position.y,
			bottom_uv_rect.size.x, bottom_uv_rect.size.y))
	_bottom_mat.set_shader_parameter("eye_shift", 0.0)


func get_builtin_screen() -> MeshInstance3D:
	return _proxy   # hidden and now unpainted: it answers "this machine has a panel" and nothing else


## TWO video-out cables: TOP (plain) and BOTTOM (carries touch back to the
## core — tapping the TV showing the bottom screen is tapping the touch screen).
func get_video_channels() -> Array:
	return [
		# The top screen leaves on an ordinary composite pigtail — picture plus the
		# audio pair, three wires. The bottom carries picture ALONE (this hardware
		# has one set of speakers and they are already on the top lead), so it is a
		# single wire. Both black, like every other lead in the room: what tells the
		# two apart is that one is a trio and the other is not.
		{"label": "TOP", "rect": top_uv_rect, "touch": false, "eye_shift": top_eye_shift,
			"wires": PackedColorArray([RcaJack.WIRE_BLACK, RcaJack.WIRE_BLACK,
				RcaJack.WIRE_BLACK])},
		{"label": "BOTTOM", "rect": bottom_uv_rect, "touch": true, "eye_shift": 0.0,
			"wires": PackedColorArray([RcaJack.WIRE_BLACK])},
	]


## Clamshells keep the labelled START/STOP cabinet button (see configure_buttons).
func has_start_stop_button() -> bool:
	return true


func _process(delta: float) -> void:
	# This override replaces the base's _process entirely (the base wraps its ONE
	# screen with _lcd_shader, which does not apply here — both panels carry their
	# own screen_window material below). The base's screen-cast lights still have to
	# be driven, though: without this call the DS/3DS lights added in c988b76 never
	# turned on at all.
	_update_screen_light()
	# Feed both screen quads from the machine's own picture (copy-on-change
	# identity checks). It used to come out of a material the C++ video handler
	# painted onto a hidden proxy mesh, purely because that was the only way to
	# get a texture out of it.
	var tex := host_picture()
	if tex != null:
		if _top_mat.get_shader_parameter("source_tex") != tex:
			_top_mat.set_shader_parameter("source_tex", tex)
			_bottom_mat.set_shader_parameter("source_tex", tex)
		if _screen.get_surface_override_material(0) != _top_mat:
			_screen.set_surface_override_material(0, _top_mat)
			_bottom_screen.set_surface_override_material(0, _bottom_mat)
	else:
		if _screen.get_surface_override_material(0) != _top_off_mat:
			_screen.set_surface_override_material(0, _top_off_mat)
			_bottom_screen.set_surface_override_material(0, _bottom_off_mat)

	_process_fingertip_touch(delta)


## Shrink the cabinet power button to handheld scale and mount it on the front
## edge of the base, facing the player, with its START/STOP label under it.
## (RetroSystem keeps this button visible because has_start_stop_button().)
func configure_buttons(power_btn: VRButton, _reset_btn: VRButton, _eject_btn: VRButton) -> void:
	power_btn.position = Vector3(body_size.x * 0.36, 0, body_size.z / 2.0 + 0.002)
	power_btn.trigger_radius = 0.015
	power_btn.depress_depth = 0.002
	power_btn.depress_axis = Vector3(0, 0, -1)

	var col := power_btn.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = Vector3(0.016, 0.016, 0.008)

	var small := MeshInstance3D.new()
	small.name = "HandheldPowerMesh"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.005
	cyl.bottom_radius = 0.006
	cyl.height = 0.005
	small.mesh = cyl
	small.rotation_degrees = Vector3(90, 0, 0)   # cylinder axis out of the front face
	power_btn.add_child(small)
	# Re-caches the depress origin and hides the console-scale ButtonMesh.
	power_btn.set_button_mesh(small)

	var lbl := power_btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl:
		lbl.transform = Transform3D.IDENTITY
		lbl.position = Vector3(0, -0.0105, 0.002)
		lbl.pixel_size = 0.0004
		lbl.font_size = 12


## Two labelled video-out ports on the back edge, beside the cartridge slot:
## TOP on the right, BOTTOM on the left.
func configure_cable_attach_for(attach_point: Node3D, channel: int) -> void:
	var x := body_size.x * (0.30 if channel == 0 else -0.30)
	attach_point.position = Vector3(x, 0, -body_size.z / 2.0 - 0.002)
	# Both ports are on the back edge, so both cords leave along its normal. The
	# base's side-edge branch never applies here — a clamshell's back edge is wide
	# enough for two — but the aim still has to be stated: an attach point placed
	# without one keeps whatever it was left at.
	aim_cable_exit(attach_point, Vector3(0, 0, -1))
	# Channel 0 is the scene's CableAttachPoint, which carries the console's
	# grey barrel PortVisual — out of scale on a handheld (the extra channels'
	# points are bare Node3Ds), so hide it and let the labels mark the ports.
	var vis := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if vis:
		vis.visible = false
	_add_port_label("TOP" if channel == 0 else "BOTTOM", x)


func _add_port_label(text: String, x: float) -> void:
	# Printed legend — the detailed shells mould their own port markings.
	if has_baked_shell():
		return
	var lbl := Label3D.new()
	lbl.text = text
	lbl.pixel_size = 0.00018
	lbl.font_size = 16
	lbl.modulate = Color(0.92, 0.92, 0.94)
	lbl.outline_size = 4
	# On the back face, reading correctly from behind the device.
	lbl.rotation_degrees = Vector3(0, 180, 0)
	lbl.position = Vector3(x, body_size.y * 0.16, -body_size.z / 2.0 - 0.0015)
	add_child(lbl)


# ── Touch screen ──────────────────────────────────────────────────────────────

## Desktop reticle / VR laser events forwarded from the TouchScreen Area3D.
func pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.PRESSED:
			_touch_pointer_down = true
			_send_touch(event.position, true)
		XRToolsPointerEvent.Type.MOVED:
			if _touch_pointer_down:
				_send_touch(event.position, true)
		XRToolsPointerEvent.Type.RELEASED, XRToolsPointerEvent.Type.EXITED:
			if _touch_pointer_down:
				_touch_pointer_down = false
				_send_touch(event.position, false)


## VR fingertip: a controller tip hovering just above the bottom screen is a
## stylus. Engage within the pad's bounds + a small height window; release
## when it leaves (with hysteresis, VRSlider-style). Hands HOLDING the device
## never count — a gripping hand's tip hovers near the pad permanently and
## would otherwise lock the touch (streaming a stuck press and blocking the
## free hand from poking).
func _process_fingertip_touch(delta: float) -> void:
	if _touch == null or _touch_pointer_down:
		return
	if _touch_ctrl != null:
		if not is_instance_valid(_touch_ctrl) or not _touch_ctrl.get_is_active() \
				or _is_holding_hand(_touch_ctrl) \
				or not _tip_on_screen(PokeTip.tip_of(_touch_ctrl), RELEASE_SCALE):
			var last := _touch_ctrl
			_touch_ctrl = null
			if is_instance_valid(last):
				# The FROZEN last in-window point, not wherever the finger is now
				# — that is outside the pad by definition, and clamping it
				# pinned every lift-off to the border as a small swipe.
				_send_touch_local(_touch_smoother.current(), false)
			_touch_smoother.reset()
		else:
			var tip: Vector3 = PokeTip.tip_of(_touch_ctrl)
			var local: Vector3 = _touch.to_local(tip)
			var p: Vector2 = _touch_smoother.point(Vector2(local.x, local.z),
				_tip_on_screen(tip, 1.0), delta)
			_send_touch_local(p, true)
			_claim_pad_contact(_touch_ctrl, p, local.y)
			return
	for ctrl in _touch_controllers:
		if ctrl and ctrl.get_is_active() and not _is_holding_hand(ctrl) \
				and _tip_on_screen(PokeTip.tip_of(ctrl), 1.0):
			_touch_ctrl = ctrl
			var local: Vector3 = _touch.to_local(PokeTip.tip_of(ctrl))
			var p := Vector2(local.x, local.z)
			_touch_smoother.begin(p)
			_send_touch_local(p, true)
			_claim_pad_contact(ctrl, p, local.y)
			return


## Put the visible fingertip ON THE GLASS, at the point the core is being told
## about. Local y = 0 is the screen mesh: _place_screen parks this Area3D at the
## bottom lens'' own position, so the box is CENTRED on the picture and its
## mid-plane is the glass. Clamped with the same half-extents the UV mapping
## clamps to, so what you see and what the game gets cannot disagree.
func _claim_pad_contact(ctrl: XRController3D, p: Vector2, local_y: float) -> void:
	var half: Vector2 = bottom_screen_size * 0.5
	var q := Vector3(clampf(p.x, -half.x, half.x), 0.0, clampf(p.y, -half.y, half.y))
	var n: Vector3 = _touch.global_transform.basis.y.normalized()
	if local_y < 0.0:
		n = -n
	PokeTip.set_contact(ctrl, _touch.global_transform * q, n, PokeTip.CONTACT_ENGAGED)


## True when this controller's hand is currently gripping the device.
func _is_holding_hand(ctrl: XRController3D) -> bool:
	if _host == null:
		return false
	var driver: Variant = _host.get("_grab_driver")
	if driver == null:
		return false
	if driver.primary and driver.primary.controller == ctrl:
		return true
	if driver.secondary and driver.secondary.controller == ctrl:
		return true
	return false


func _tip_on_screen(world_pos: Vector3, slack: float) -> bool:
	var local := _touch.to_local(world_pos)
	return absf(local.y) <= (HALF_THICKNESS + GLASS_TOLERANCE) * slack \
		and absf(local.x) <= bottom_screen_size.x / 2.0 + 0.005 * slack \
		and absf(local.z) <= bottom_screen_size.y / 2.0 + 0.005 * slack


## World point on/over the bottom screen → composite-framebuffer UV → host.
func _send_touch(world_pos: Vector3, pressed: bool) -> void:
	if _touch == null:
		return
	var local := _touch.to_local(world_pos)
	_send_touch_local(Vector2(local.x, local.z), pressed)


## In-plane surface-local point (metres) → UV. The pad's local frame has +Y as
## the screen normal, X across and Z down the picture.
func _send_touch_local(p: Vector2, pressed: bool) -> void:
	if _host == null or not _host.has_method("feed_touch"):
		return
	var fx := clampf(p.x / bottom_screen_size.x + 0.5, 0.0, 1.0)
	var fy := clampf(p.y / bottom_screen_size.y + 0.5, 0.0, 1.0)
	_host.feed_touch(bottom_uv_rect.position + Vector2(fx, fy) * bottom_uv_rect.size, pressed)


## Mean normal of a mesh IF every face agrees on one — i.e. the mesh is a single
## flat plane. Returns ZERO when the normals disagree, so callers can fall back
## rather than trusting the normal of something that is not a screen surface.
func _planar_normal(mi: MeshInstance3D) -> Vector3:
	if mi == null or mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return Vector3.ZERO
	var arr: Array = mi.mesh.surface_get_arrays(0)
	if arr.is_empty() or arr[Mesh.ARRAY_NORMAL] == null:
		return Vector3.ZERO
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	if norms.is_empty():
		return Vector3.ZERO
	var basis_n: Vector3 = mi.global_transform.basis * norms[0]
	basis_n = basis_n.normalized()
	var acc := Vector3.ZERO
	for n in norms:
		var w: Vector3 = (mi.global_transform.basis * n).normalized()
		# Two-sided quads list both facings; fold the back half onto the front.
		if w.dot(basis_n) < 0.0:
			w = -w
		if w.dot(basis_n) < 0.99:
			return Vector3.ZERO
		acc += w
	return acc.normalized()

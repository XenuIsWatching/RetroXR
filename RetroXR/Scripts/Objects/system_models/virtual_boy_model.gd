## RetroSystemModelVirtualBoy — the 1995 stereoscopic tabletop, reborn in VR.
##
## mednafen_vb is forced to vb_3dmode = "side-by-side" (get_forced_core_options
## → the .opt seam), making the core output BOTH eyes in one 768×224 frame.
## The C++ VideoHandler drives a hidden proxy quad; this model copies the
## proxy's emission texture into the eyepiece quad's stereo ShaderMaterial,
## which samples the left half for the left eye and the right half for the
## right (VIEW_INDEX) — real per-eye stereo depth in the headset, without the
## original's head-in-a-vice sweet spot. On desktop the eyepiece shows the
## left eye's image flat.
##
## Not a handheld: one controller port, and the video-out cable works too. The
## TV does NOT get the raw side-by-side frame (which reads as two squashed
## copies) — get_video_channels() hands it the LEFT half plus eye_shift 0.5, so
## screen_window.gdshader samples the right half for the right eye and a
## connected TV comes out in stereo as well. Same mechanism the 3DS top screen
## uses; the console is stereo end to end.
##
## Serves two separate models: virtual_boy.tscn (detailed shell, baked as "Shell")
## and virtual_boy_primitive.tscn (the bipod authored in the scene itself). Neither
## is a fallback for the other.
class_name RetroSystemModelVirtualBoy
extends RetroSystemModel

const STEREO_SHADER := preload("res://Shaders/vb_stereo.gdshader")
const WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")

## The shell is authored with its EYEPIECES on -Z and its cart slot / A/V out on
## +Z — backwards from the framework's "front is +Z". Yaw it so the lenses face
## the player and the sockets end up round the back.
const _SHELL_YAW := PI
## Bundled A/V lead; RetroXR spawns its own cable.
const _HIDE := ["RCA_Red"]
## The GLB's own opaque lens panes, replaced by the live stereo eyepiece.
const _LENS := ["screen_mesh", "screen_mesh (1)"]

# Visor ~220×110×95 mm on a ~250 mm stand, red-on-black like the hardware.
const VISOR_SIZE := Vector3(0.22, 0.11, 0.095)
const STAND_H := 0.25
## Eyepiece view: one eye's 384×224 image (12:7).
const EYE_SIZE := Vector2(0.132, 0.077)

var _glb: Node3D = null
var _proxy: MeshInstance3D = null
var _eyepiece: MeshInstance3D = null
var _stereo_mat: ShaderMaterial = null
## One live quad per PHYSICAL lens: the left pane shows the left-eye half of the
## side-by-side frame and the right pane the right-eye half, exactly like the
## hardware wires its two displays. With your head in the visor each eye lines up
## with its own pane, which is the arrangement the console was built around.
var _lens_quads: Array[MeshInstance3D] = []
var _lens_mats: Array[ShaderMaterial] = []
var _visor_center_y := 0.0

## Screen-cast light: the visor spills the VB's signature red glow out of the
## eye-shade when it's showing a picture (fixed red — the display is always
## red-on-black, so no per-frame colour sample is needed; energy just tracks
## picture on/off). A SpotLight3D aimed out of the panes, like the TV's ambilight:
## the first attempt was an OmniLight sitting 5 cm INSIDE the visor, which lit the
## whole shell from within and cast nothing.
const VB_LIGHT_ENERGY := 0.7
const VB_LIGHT_COLOR := Color(1.0, 0.05, 0.05)
const VB_LIGHT_ANGLE := 55.0
const VB_LIGHT_RANGE := 0.6
var _vb_light: SpotLight3D = null


## The systemid whose cart dimensions this console takes (MediaDimensions).
func _cart_systemid() -> String:
	return "virtual_boy"


func get_controller_port_count() -> int:
	return 1


func get_builtin_screen() -> MeshInstance3D:
	return _proxy   # hidden and now unpainted: it answers "this machine has a panel" and nothing else


func is_stereo_side_by_side() -> bool:
	return true


## A TV fed the raw side-by-side frame shows two squashed copies. Hand it the
## LEFT half and let screen_window.gdshader shift +0.5 for the right eye, so the
## TV is stereo too rather than a flat curiosity.
func get_video_channels() -> Array:
	return [{"label": "", "rect": Rect2(0.0, 0.0, 0.5, 1.0), "touch": false,
		"eye_shift": 0.5}]


func get_forced_core_options() -> Dictionary:
	return {"vb_3dmode": "side-by-side", "vb_sidebyside_separation": "0"}


func _ready() -> void:
	_visor_center_y = STAND_H + VISOR_SIZE.y / 2.0
	# The stand / visor / eye-shade / eyepiece / hidden proxy are authored in
	# virtual_boy.tscn; cache the two functional nodes.
	_proxy = get_node_or_null("ProxyScreen") as MeshInstance3D
	_eyepiece = get_node_or_null("Eyepiece") as MeshInstance3D
	# The eyepiece's live stereo material is per-instance (source_tex is bound
	# per-frame from the proxy), so build it here rather than sharing one packed
	# sub-resource across every Virtual Boy in the room.
	_stereo_mat = ShaderMaterial.new()
	_stereo_mat.shader = STEREO_SHADER
	if _eyepiece:
		_eyepiece.set_surface_override_material(0, _stereo_mat)
	if not has_baked_shell():
		_place_volume_wheel()   # this model's own knob; nothing to adopt
	else:
		_adopt_baked_shell()
	# Red visor glow: a spot just outside the eye-shade shining out along the panes'
	# normal (+Z, where the player stands). Off until a picture is present.
	_vb_light = SpotLight3D.new()
	_vb_light.name = "ScreenCastLight"
	_vb_light.light_color = VB_LIGHT_COLOR
	_vb_light.spot_angle = VB_LIGHT_ANGLE
	_vb_light.spot_range = VB_LIGHT_RANGE
	_vb_light.shadow_enabled = false
	_vb_light.light_energy = 0.0
	# Hidden, not merely dark: the mobile renderer shades a light for every pixel
	# its range reaches whatever its energy (see ScreenCastLight._apply_energy).
	_vb_light.visible = false
	_vb_light.rotation_degrees = Vector3(180.0, 0.0, 0.0)   # spots emit down -Z
	add_child(_vb_light)
	_vb_light.position = _visor_glow_origin()
	# Editor-only cart-seat preview box — hide it at runtime.
	_hide_seat_previews()


## Swap the primitive bipod for the detailed shell. The functional nodes stay
## authoritative — the hidden proxy the VideoHandler renders into, and the live
## stereo eyepiece — but the eyepiece is moved onto the real lens aperture and
## the GLB's own opaque panes are hidden behind it.
## Adopt the detailed shell virtual_boy.tscn bakes as a "Shell" instance — already
## yawed and recentred, so there is nothing to place.
##
## The load / yaw / recentre branch this replaced was dead (the scene always bakes
## Shell) and was the last thing making a SHARED model script name an imported
## asset: this one script serves both virtual_boy.tscn and virtual_boy_primitive.tscn,
## so a path to a deleted GLB would have outlived the model that needed it.
func _adopt_baked_shell() -> void:
	_glb = _baked_shell
	for nm in _HIDE:
		var e := _glb.find_child(nm, true, false) as Node3D
		if e != null:
			e.visible = false
	_place_eyepiece()
	_place_volume_wheel()


func _glb_aabb() -> AABB:
	var acc := AABB()
	var first := true
	for n in _glb.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
		acc = ab if first else acc.merge(ab)
		first = false
	return acc


## Put the live stereo quad across BOTH lens apertures and retire the GLB panes.
##
## One quad rather than one per lens: in VR each eye sees both physical lenses
## (there is no head-in-a-vice divider), so a per-lens image would be shown to
## both eyes. A single quad sampled by VIEW_INDEX gives each eye its own half —
## correct stereo without needing the barrier the real hardware relies on.
## The volume thumbwheel, split out of the body mesh in Blender (the shell ships
## it welded into "Virtual Boy1"). Turning it drives the console's audio volume
## and spins the wheel itself, so the one control the head unit really does have
## actually works.
const _VOL_SWEEP_DEG := 70.0

var _vol_wheel: MeshInstance3D = null
var _vol_rest: Transform3D
var _vol_slider: VRSlider = null


func _place_volume_wheel() -> void:
	_vol_slider = get_node_or_null("VolumeSlider") as VRSlider
	if _vol_slider == null:
		return
	# Only the detailed shell models a wheel to take over; the stand-in authors
	# its own knob on the visor's right rim and keeps it.
	_vol_wheel = _glb.find_child("VolumeWheel", true, false) as MeshInstance3D if _glb != null else null
	if _vol_wheel != null:
		_vol_rest = _vol_wheel.transform
		var ab: AABB = (global_transform.affine_inverse() * _vol_wheel.global_transform) * _vol_wheel.get_aabb()
		_vol_slider.global_position = to_global(ab.get_center())
		var knob := _vol_slider.get_node_or_null("KnobMesh") as MeshInstance3D
		if knob != null:
			knob.hide()
	_vol_slider.value_changed.connect(_on_volume)
	_apply_volume(_vol_slider.value)


func _on_volume(v: float) -> void:
	_apply_volume(v)
	var host := get_parent()
	if host != null and host.has_method("set_audio_volume"):
		host.set_audio_volume(v)


## Spin the wheel about its own axle (the mesh's long axis, X) so the ribs
## travel through the slot as the value changes.
func _apply_volume(v: float) -> void:
	if _vol_wheel == null:
		return
	var ab: AABB = _vol_wheel.get_aabb()
	var pivot: Vector3 = _vol_rest * ab.get_center()
	var r := Basis(Vector3.RIGHT, deg_to_rad((v - 0.5) * _VOL_SWEEP_DEG))
	_vol_wheel.transform = Transform3D(r, pivot - r * pivot) * _vol_rest


## Where the visor glow comes from, in this model's local frame: just proud of the
## live lens panes when the detailed shell is in, else the authored Eyepiece quad.
##
## It is deliberately NOT parented to the Eyepiece: _place_eyepiece() HIDES that
## quad once the shell's two panes take over, and a light parented under a hidden
## node inherits the invisibility — so the glow never lit anything on a GLB shell.
func _visor_glow_origin() -> Vector3:
	if not _lens_quads.is_empty():
		var c := Vector3.ZERO
		for q in _lens_quads:
			c += q.position
		c /= float(_lens_quads.size())
		return c + Vector3(0.0, 0.0, 0.010)
	if _eyepiece != null:
		return _eyepiece.position + Vector3(0.0, 0.0, 0.010)
	return Vector3(0.0, _visor_center_y, 0.06)


## World position of a GLB marker empty.
func _marker(nm: String) -> Vector3:
	if _glb == null:
		return global_position
	var n := _glb.find_child(nm, true, false) as Node3D
	return n.global_position if n != null else global_position


func _place_eyepiece() -> void:
	if _glb == null:
		return
	# The primitive single quad is retired: the shell models both panes, so feed
	# them separately instead of stretching one image across the pair.
	if _eyepiece != null:
		_eyepiece.visible = false
	var lenses: Array[MeshInstance3D] = []
	for nm in _LENS:
		var lens := _glb.find_child(nm, true, false) as MeshInstance3D
		if lens != null and lens.mesh != null:
			lenses.append(lens)
	if lenses.size() < 2:
		return
	# Sort by x so index 0 is the player's LEFT pane. Facing the console (the
	# player stands at +Z looking down -Z), the player's left is -X.
	lenses.sort_custom(func(a: MeshInstance3D, b: MeshInstance3D) -> bool:
		return _lens_x(a) < _lens_x(b))
	for i in lenses.size():
		var lens := lenses[i]
		var ab: AABB = (global_transform.affine_inverse() * lens.global_transform) * lens.get_aabb()
		lens.visible = false                      # our live quad replaces the pane
		var quad := MeshInstance3D.new()
		quad.name = "LensLeft" if i == 0 else "LensRight"
		var qm := QuadMesh.new()
		qm.size = Vector2(ab.size.x, ab.size.y)
		quad.mesh = qm
		var mat := ShaderMaterial.new()
		mat.shader = WINDOW_SHADER
		# Left half of the composite, pinned per pane: stereo_mode 1 never
		# applies eye_shift (left eye), 2 always applies it (right eye).
		mat.set_shader_parameter("source_rect", Vector4(0.0, 0.0, 0.5, 1.0))
		mat.set_shader_parameter("eye_shift", 0.5)
		mat.set_shader_parameter("stereo_mode", 1 if i == 0 else 2)
		quad.set_surface_override_material(0, mat)
		add_child(quad)
		quad.position = Vector3(ab.get_center().x, ab.get_center().y, ab.end.z + 0.0012)
		_lens_quads.append(quad)
		_lens_mats.append(mat)


func _lens_x(m: MeshInstance3D) -> float:
	var ab: AABB = (global_transform.affine_inverse() * m.global_transform) * m.get_aabb()
	return ab.get_center().x


func _process(_delta: float) -> void:
	# Feed the eyepiece from the machine's own picture (same copy-on-change pattern
	# as the dual-screen quads and the television's CRT stage). It used to be read
	# back out of a material the C++ video handler painted onto a hidden proxy.
	if _stereo_mat == null:
		return
	var tex := host_picture()
	if _stereo_mat.get_shader_parameter("source_tex") != tex:
		_stereo_mat.set_shader_parameter("source_tex", tex)
	for m in _lens_mats:
		if m.get_shader_parameter("source_tex") != tex:
			m.set_shader_parameter("source_tex", tex)
	# Visor glow tracks whether there's a picture (fixed red set at creation).
	if _vb_light:
		_vb_light.visible = tex != null
		_vb_light.light_energy = VB_LIGHT_ENERGY if tex != null else 0.0


## Sit the START/STOP and RESET buttons on the front of the bipod base plate
## instead of leaving them at the default cabinet front-face height, where the
## Virtual Boy's tall stand leaves them floating in mid-air. The StandBase plate
## top is at y = 0.012; the button boxes are 0.02 tall (half-height 0.01), so a
## button resting on the plate centres at y = 0.022. They keep the default
## upright (+Z-facing) orientation, so the poke/press mechanics are unchanged.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, _eject_btn: VRButton) -> void:
	power_btn.set_color(Color(0.0, 1.0, 0.0))   # START/STOP label+colour owned by system.gd
	if _glb != null:
		# No bipod to sit on. Rest them ON the shell's top face, outboard of the
		# carry handle and clear of the cart slot at the back, rather than at the
		# front lip where the protruding eye shade leaves them floating in air.
		# Use the shell's own top controls rather than dropping boxes on it.
		var ab := _glb_aabb()
		_bind_to_shell(power_btn, _FOCUS_L, ab.end.y)
		_bind_to_shell(reset_btn, _FOCUS_R, ab.end.y)
		return
	power_btn.position = Vector3(0.04, 0.022, 0.045)
	reset_btn.position = Vector3(-0.04, 0.022, 0.045)


## The shell's OWN top controls, measured off an orthographic render of the top
## face (the model bakes them into the body mesh, so there is nothing to bind a
## button mesh to — these are positions only).
##
## Note what they actually are: the two silver sliders are the LEFT and RIGHT
## FOCUS adjusters (the word FOCUS is printed between them) and the dial above
## is the IPD wheel. The real Virtual Boy has no power switch or volume on the
## head unit at all — both live on the controller — so there is no authentic
## console control to bind START/STOP to. These are the nearest real affordances.
const _FOCUS_L := Vector3(-0.0163, 0.0, 0.0021)
const _FOCUS_R := Vector3(0.0185, 0.0, 0.0021)
## Focus sliders travel sideways (the caps are marked with left/right arrows).
const _SLIDER_TRAVEL := 0.003


## Put a control's touch zone on a real feature of the shell and remove our own
## placeholder geometry entirely. Nothing animates: the controls are part of the
## body mesh, so there is no separate node to move. Splitting them out would need
## the Blender pass the 3DS slider knobs got.
func _bind_to_shell(btn: VRButton, xz: Vector3, top_y: float) -> void:
	if btn == null:
		return
	var mesh := btn.get_node_or_null("ButtonMesh") as MeshInstance3D
	if mesh != null:
		mesh.hide()
	btn.position = Vector3(xz.x, top_y - 0.004, xz.z)
	btn.depress_depth = _SLIDER_TRAVEL
	btn.set_depress_axis_world(Vector3.LEFT)   # slides, not sinks
	# Drop the cabinet's START/RESET caption: it would be printed across a
	# control that is actually a focus slider, which is worse than no label.
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


## Underside controller socket. Measured off a straight-up render of the bottom
## face against the six-pin socket the shell actually models — not the marker
## names, and not the battery-cover panel just behind it, which is what a first
## eyeball estimate lands on.
const _PORT_X := 0.082
const _PORT_Z := -0.0334


## The single controller port sits under the front of the visor pointing down,
## like the real EXT connector on the underside of the head unit.
func configure_controller_ports(port_zones: Array) -> void:
	if port_zones.size() > 0:
		var zone: Node3D = port_zones[0]
		# The grey barrel and its printed "1" are stand-ins for hardware with no
		# moulded socket; the detailed shell has a real one, so they only ever sat
		# on top of it. (The seat branch below returns early, which is how the "1"
		# survived on the detailed shell after every other legend was dropped.)
		if has_baked_shell():
			hide_port_placeholders([zone])
		# An authored "PortSeat1" marker (baked into virtual_boy.tscn) wins
		# over the computed pose below, same idiom as CartSeat/DiscSeat/UMDSeat.
		var seat := find_child("PortSeat1", true, false) as Node3D
		if seat != null:
			zone.global_transform = seat.global_transform
			return
		if _glb != null:
			# Controller socket on the UNDERSIDE, right of centre — measured off
			# an orthographic render of the bottom face (with a reference marker
			# at a known +X, because looking straight up makes left/right
			# ambiguous). Matches the manual's bottom view: socket to one side,
			# volume dial and headphone jack on the other.
			var ab := _glb_aabb()
			zone.position = Vector3(_PORT_X, ab.position.y + 0.006, _PORT_Z)
			zone.rotation_degrees = Vector3(90, 0, 0)
			var recess := zone.get_node_or_null("PortRecess") as MeshInstance3D
			if recess != null:
				recess.hide()
			return
		zone.position = Vector3(0, STAND_H - 0.008, VISOR_SIZE.z / 2.0 - 0.025)
		# Rotate the zone's +Z (the plug's approach axis on every other system's
		# front face) to face straight down.
		zone.rotation_degrees = Vector3(90, 0, 0)


## How far the cart's centre sits out from socket_media along the grip axis.
##
## socket_media marks where the connector mates and a snap zone seats on the
## object's CENTRE, so some offset is needed or the cart vanishes inside the
## shell — but a full half-length (27 mm) leaves it hanging 32 mm out in open
## air. Sized off the shell instead: scanning the shell mesh across the band the
## cart passes through (|x| < 0.03, y = 0.0147 +/- 0.004) puts its front face at
## z = -0.0629, with the hood overhanging to -0.0761 just above. Park the cart's
## grip end 2 mm proud of that overhang, so it reads as seated but still has a
## lip to take hold of: 0.0781 - 0.0407 - 0.054 / 2.
const _CART_SEAT_OUT := 0.0104


func configure_cartridge_slot(slot: Node3D) -> void:
	# An authored "CartSeat" marker (baked into virtual_boy.tscn) wins over the
	# socket_media-computed pose, so the seated-cart transform can be dialled in
	# visually in the Godot 3D editor.
	var seat := _seat_marker("CartSeat")
	if seat != null:
		slot.global_transform = seat.global_transform
		var svv := slot.get_node_or_null("SlotVisual") as MeshInstance3D
		if svv != null:
			svv.visible = false
		return
	if _glb != null:
		var mk := _glb.find_child("socket_media", true, false) as Node3D
		if mk != null:
			var b: Basis = _glb.global_transform.basis.orthonormalized()
			# Lay the cart flat with the label up, connector leading along the
			# axis the bundle's own `Virtual Boy_Insert_PAN` clip travels on
			# (Z alone — so the cart is pushed in horizontally, not dropped in
			# from the top). A cartridge is authored connector -Y / label +Z, so
			# map its +Y (grip) onto the shell's +Z and its +Z (label) onto
			# world up. X has to invert for this to stay a rotation.
			#
			# Position comes from socket_media itself, NOT from the clip's end
			# pose: the converter bakes node translations but copies animation
			# channel values through untouched, so the two are in different
			# frames and differencing them is meaningless. The clip is good for
			# the axis and nothing else.
			#
			var sb: Basis = b * Basis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0))
			slot.global_transform = Transform3D(sb, mk.global_position + sb.y * _CART_SEAT_OUT)
			var sv := slot.get_node_or_null("SlotVisual") as MeshInstance3D
			if sv != null:
				sv.visible = false
			return
		slot.global_position = _marker("socket_media")
		var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
		if v != null:
			v.visible = false
		return
	slot.position = Vector3(0, _visor_center_y + VISOR_SIZE.y / 2.0 + 0.01, 0)
	var visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if visual:
		visual.visible = false


func configure_cable_attach(attach_point: Node3D) -> void:
	# Video-out on the rear of the visor, not the left edge — and the cord leaves
	# along that face's normal rather than along whatever the attach point was left
	# pointing at (see RetroSystemModel.aim_cable_exit). The shell is yawed so its
	# sockets face the back, so both bodies want the same answer.
	if _glb != null:
		attach_point.global_position = _marker("Cable Plug (R)")
		aim_cable_exit(attach_point, Vector3(0, 0, -1))
		var pv := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
		if pv != null:
			pv.visible = false
		return
	attach_point.position = Vector3(0, _visor_center_y, -VISOR_SIZE.z / 2.0 - 0.002)
	aim_cable_exit(attach_point, Vector3(0, 0, -1))


## The default console collision box (bottom at y=-0.05) leaves the Virtual Boy
## floating above the floor — and a single full-height slab wraps the thin stand
## in a huge invisible volume. Match the actual geometry instead: the main shape
## becomes the visor box (so hand-grabs feel right), plus a base plate and a
## slim column so the stand rests on the ground. The PointerArea (what the
## selection ray hits) must be resized too — its default console-sized box sits
## at floor level, so the ray could never intersect the visor.
func configure_collision(host: Node3D) -> void:
	if _glb != null:
		# One box round the head unit: there is no bipod on this shell, it rests
		# on the table like the real thing does off its stand.
		var ab := _glb_aabb()
		for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
			var c := host.get_node_or_null(path) as CollisionShape3D
			if c != null and c.shape is BoxShape3D:
				c.shape = c.shape.duplicate()
				(c.shape as BoxShape3D).size = ab.size + Vector3(0.01, 0.01, 0.01)
				c.position = ab.get_center()
		return
	# The same three volumes on BOTH bodies. A single full-height slab for the
	# pointer would reach the visor, but it also fills the empty air either side
	# of the stand — and the cabinet hangs START/STOP down there, 12 mm off the
	# floor beside the column, where that slab swallowed them.
	var parts := [
		["", VISOR_SIZE, Vector3(0, _visor_center_y, 0)],
		["StandBaseCollision", Vector3(0.16, 0.012, 0.14), Vector3(0, 0.006, 0)],
		["StandColumnCollision", Vector3(0.03, STAND_H, 0.03), Vector3(0, STAND_H / 2.0, 0)],
	]
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col == null or not (col.shape is BoxShape3D):
			continue
		var parent := col.get_parent()
		for part in parts:
			var part_name: String = part[0]
			var target := col
			if not part_name.is_empty():
				target = parent.get_node_or_null(NodePath(part_name)) as CollisionShape3D
				if target == null:
					target = CollisionShape3D.new()
					target.name = part_name
					parent.add_child(target)
			var shape := BoxShape3D.new()
			shape.size = part[1]
			target.shape = shape
			target.position = part[2]


func on_power_on() -> void:
	if _stereo_mat:
		_stereo_mat.set_shader_parameter("powered", 1.0)
	for q in _lens_quads:
		q.visible = true


func on_power_off() -> void:
	if _stereo_mat:
		_stereo_mat.set_shader_parameter("powered", 0.0)
	for q in _lens_quads:
		q.visible = false

## RetroSystemModelN3DS — Nintendo 3DS (clamshell, asymmetric screens),
## with REAL stereoscopic 3D on the top screen.
##
## Runs the patched azahar core (Tools/azahar-libretro-vr overlay) with
## citra_render_3d = "side-by-side": the composite framebuffer keeps the
## default 400×480 layout but each half is one EYE — left half = the whole
## top+bottom layout for the left eye, right half = the right eye. The UV
## rects below therefore select the LEFT-eye regions, and the top screen's
## eye_shift (+0.5) makes the right VR eye sample the right-eye half — per-eye
## depth in the headset, the thing the 3DS's parallax barrier faked.
##
## Left-eye regions of the 400×480 SBS composite (default layout: top 400×240
## full-width, bottom 320×240 centered with 40px pillarboxes, each squeezed
## to half width per eye):
##   top    = (0,    0,   0.5, 0.5)
##   bottom = (0.05, 0.5, 0.4, 0.5)   ← also where touch maps (azahar folds
##                                       SBS touch onto the left-eye half)
##
## The physical 3D DEPTH SLIDER on the lid's right edge (Slider3D, authored in
## n3ds.tscn) drives citra_factor_3d 0–100%: live while a game runs (azahar
## re-parses options mid-run), and merged into the forced options for the next
## boot. Slider down = 2D-flat (both eyes identical), up = full depth.
##
## NOTE: these rects assume the patched azahar core. A stock citra core
## ignores citra_render_3d and outputs a mono 400×480 layout, which would
## show through these stereo windows misaligned.
class_name RetroSystemModelN3DS
extends RetroSystemModelDualScreen

var _slider_3d: VRSlider = null
## 3D depth 0..1 (slider position). Applied as citra_factor_3d percent.
var _depth_3d := 1.0


func _init() -> void:
	# Left-eye regions of the 400×480 side-by-side composite.
	top_uv_rect = Rect2(0.0, 0.0, 0.5, 0.5)
	bottom_uv_rect = Rect2(0.05, 0.5, 0.4, 0.5)
	top_eye_shift = 0.5
	cart_size = Vector3(0.033, 0.035, 0.004)   # 3DS Game Card




## The upper clamshell half (folds with the hinge); the top screen lens is
## handled by the base. Everything else in the GLB is the base half. The two
## slider knobs ride the lid's edges, so they fold with it too.
func _lid_mesh_names() -> PackedStringArray:
	# GlasTop is the lid's outer glass — it has to fold with the lid, not stay
	# behind on the base half.
	return PackedStringArray(["top", "GlasTop", "Slider3DKnob", "VolumeKnob"])


## The New 3DS XL's real hinge barrel sits well forward of the base shell's
## raw back-edge bounding box — the base's own AABB corner overshoots it by
## about 9 mm. Invisible at the GLB's authored ~155° open rest pose (any hinge
## choice reproduces that pose exactly — see the derivation below), it only
## shows up once the lid swings closed: the naive corner sent the lid
## overhanging past the back of the console while falling ~14 mm short of the
## front edge.
##
## Derived by solving for the Z that makes the CLOSED lid's footprint (rotated
## 180° − rest_rot about the naive Y) match the base shell's own footprint —
## i.e. the value that makes the shut console actually look shut. Rotation
## math and vertex data cross-checked directly against new_3ds_xl.glb; not
## re-derived at runtime since that needs the raw (pre-recenter) mesh data
## dual_screen_handheld_model.gd doesn't keep around after this pass runs.
func _hinge_z_offset() -> float:
	return 0.00895


## The real hinge barrel also sits below the base shell's raw top face
## (base_top_y ≈ 0.012877) — pinned down to an absolute Y of 0.0065, which is this
## offset added to base_top_y. It is a proportion of the shell, so it holds for any
## shell built to the same proportions.
func _hinge_y_offset() -> float:
	return 0.0065 - 0.012877


## Same front-face placement as the DS, but a smaller nameplate.
##
## The shared 0.72 is sized for "NINTENDO DS" — long enough that it nearly fills
## the base's width. This system's name resolves to just "3DS", so the width
## constraint never binds and the height one does: at 0.72 three characters come
## out 18.5 mm tall on a 25.8 mm base, spilling over the touch-screen bezel. 0.45
## lands it on the front lip at about the weight of the shell's own moulded power
## and Wi-Fi icons.
func name_label_placement() -> Dictionary:
	var cfg := super.name_label_placement()
	cfg["h_frac"] = 0.45
	return cfg


## Both grooves are on the LID on this hardware, so the volume slider is authored
## under LidPivot and rides it. The base looks for it as a direct child, which is
## where every other handheld puts it, so point it at the real one. (Only
## _cache_dual_nodes runs for a dual-screen model — its _ready deliberately skips
## the single-screen base's — so this is the one place that needs it.)
func _cache_dual_nodes() -> void:
	super()
	if _volume_slider == null:
		_volume_slider = get_node_or_null("LidPivot/VolumeSlider") as VRSlider


## Force the stereo output mode every boot; depth follows the physical slider.
func get_forced_core_options() -> Dictionary:
	return {
		"citra_render_3d": "side-by-side",
		"citra_layout_option": "default",
		"citra_swap_screen": "Top",
		"citra_factor_3d": str(roundi(_depth_3d * 100.0)),
	}


## Wire the authored 3D depth slider (on the lid, beside the top screen) to
## azahar's citra_factor_3d — up (away from the hinge) = full 3D, down = 2D.
func configure_handheld_controls(host: Node3D) -> void:
	super(host)

	_adopt_slider(_volume_slider, "VolumeKnob")

	_slider_3d = get_node_or_null("LidPivot/Slider3D") as VRSlider
	if _slider_3d == null:
		return
	_adopt_slider(_slider_3d, "Slider3DKnob")
	_depth_3d = _slider_3d.value
	_slider_3d.value_changed.connect(func(v: float) -> void:
		_depth_3d = v
		# Live while running (azahar applies option changes mid-game); the
		# forced options carry the value into the next boot otherwise.
		if _host and _host.get("is_powered_on") and _host.has_method("set_core_option"):
			_host.set_core_option("citra_factor_3d", str(roundi(v * 100.0))))


# ── Physical slider knobs ─────────────────────────────────────────────────────
# Both grooves run along the lid's slanted side rim, so travel is a diagonal in
# the model's local space. Value 0 = the hinge end (2D / quiet), 1 = the far end
# by the top of the screen (full depth / loud) — matching the real hardware.
#
# Throw measured against a 5 mm ruler laid along the groove in an orthographic
# render taken face-on to the rim: the slot runs from 3.2 mm below the modelled
# knob position to 16.9 mm above it, and the tab is 7.2 mm long, so its centre can
# travel 12.9 mm before either end of the tab leaves the slot. At the old 10.5 mm
# the knob stopped ~2.3 mm short of the far end.
#
# The Y sign used to be NEGATIVE, which ran both knobs diagonally OUT of their
# grooves: value 0 sat correctly in the slot and value 1 left it entirely, the
# tab ending up on the bare shell below. Two independent fits of the geometry
# agree the groove climbs — the lid's own surface near the knob comes out at
# (0.031, 0.337, -0.941), and the knob tab, which is elongated along the slot it
# rides in, at (-0.025, 0.430, -0.902). X is fit noise (the grooves sit on the
# side rims and run in the YZ plane; the two fits disagree even on its sign), so
# it is dropped and the Y/Z pair averaged.
const _KNOB_TRAVEL := 0.0128
const _KNOB_AXIS := Vector3(0.0, 0.384, -0.923)

## Hand a slider the shell's REAL knob, so the cap you can see IS the control: it
## takes the pointer highlight and travels with the value.
##
## Both used to drive a hidden placeholder while a bespoke _set_knob slid the real
## cap off value_changed — two mechanisms for one control, with the interaction
## zone placed by hand instead of derived from the knob. The zones drifted badly:
## 26 mm from the 3D knob against a 20 mm engage radius, and 171 mm from the
## volume one, which sits on the lid's LEFT rim while its zone sat on the base
## half's right. Neither was reachable where you could see it.
func _adopt_slider(slider: VRSlider, mesh_name: String) -> void:
	if slider == null:
		return
	var knob := find_child(mesh_name, true, false) as MeshInstance3D
	if knob == null or knob.mesh == null:
		return
	var authored := slider.value
	# _KNOB_AXIS is the DETAILED shell's groove: it climbs out of the lid face
	# because that shell rounds its side rims. The stand-in has no rim — flat lid,
	# flat cap — and its scene already authors the axis, travel and zone that suit
	# it, so applying the measured one slid the knob 23 degrees out of the surface
	# it sits on. Take the cap over and leave the rest alone.
	if not has_baked_shell():
		slider.set_knob_mesh(knob)
		return
	var world_axis := (global_transform.basis * _KNOB_AXIS).normalized()
	slider.travel = _KNOB_TRAVEL
	# Zone at the MIDDLE of the throw: _track_world_point maps the slider's own
	# origin to value 0.5, so anywhere else skews the hand-to-value mapping.
	slider.global_position = (knob.global_transform * knob.get_aabb().get_center()) \
		+ world_axis * (_KNOB_TRAVEL * 0.5)
	slider.axis_local = (slider.global_transform.basis.inverse() * world_axis).normalized()
	# The GLB models both knobs at the quiet / 2D end of the groove, which is
	# value 0 — anchor there, then restore the authored value so taking the knob
	# over does not jump it.
	slider.set_value_no_signal(0.0)
	slider.set_knob_mesh(knob)
	slider.set_value_no_signal(authored)


## The 3DS Game Card slot is on the FRONT edge, left of centre — not the generic
## back-centre mouth the handheld base assumes. Re-seat the snap zone there so a
## grabbed card snaps to where the slot actually is: lying flat, label DOWN, and
## contacts leading in. Falls back to the base placement when there is no baked
## shell, which is the case for the stand-in.
func configure_cartridge_slot(slot: Node3D) -> void:
	super(slot)
	# On the stand-in, super()'s CartSeat is the last word — socket_media marks
	# the DETAILED shell's connector.
	if _has_no_baked_shell():
		return
	var sock := find_child("socket_media", true, false) as Node3D
	if sock == null:
		return
	# Seat the card off the socket marker itself (the connector, deepest point):
	# its centre sits half a card-length toward the front mouth. Deriving this
	# from body_size instead would overshoot — that spans the whole base half,
	# which the rear AV lead inflates well past the real front edge.
	var p := to_local(sock.global_position)
	slot.position = Vector3(p.x, p.y, p.z + cart_size.y * 0.5)
	slot.rotation_degrees = Vector3(90, 0, 0)             # base pose, flipped to a FRONT mouth


## The card slides in from the front of the device (the base assumes the back).
func get_cartridge_insert_direction() -> Vector3:
	return Vector3(0, 0, 1)


## Power button: drive the real PowerButton3ds mesh on the front-right edge
## rather than the base's generic nub, so the visible power button depresses when
## pressed. The button→toggle_power connection is made once by RetroSystem; this
## only repositions the VRButton and points it at the real mesh (as every other
## model's configure_buttons does). The 3DS has no separate reset / eject.
func configure_buttons(power_btn: VRButton, _reset_btn: VRButton, _eject_btn: VRButton) -> void:
	_set_leds(false)   # console starts off — indicators dark until power_on
	var mesh := find_child("PowerButton3ds", true, false) as MeshInstance3D
	var marker := find_child("Power", true, false) as Node3D
	power_btn.trigger_radius = 0.013
	power_btn.depress_depth = 0.0014
	power_btn.set_latched_pressed(false)
	if mesh != null:
		power_btn.set_button_mesh(mesh)   # depress the real button; hides the console ButtonMesh
	if marker != null:
		power_btn.global_position = marker.global_position
	elif mesh != null:
		power_btn.global_position = mesh.global_transform * mesh.get_aabb().get_center()
	# The New 3DS XL moved the power button off the face and onto the FRONT LIP,
	# right of the stylus — so it presses horizontally back into the body, not
	# down. The button mesh confirms it: a 4.8 mm disc only 1.1 mm thick, lying at
	# z = +0.0517 against a shell that ends at +0.0523.
	#
	# Do NOT take the axis from the "Power" empty. set_depress_axis_from_node reads
	# an empty's local -Z as the travel direction, which holds for the GLB's
	# "Finger Button" empties but not this one: its -Z comes out (0, -1, 0), so the
	# button sank straight down out of the lip. The lip faces the model's +Z, so
	# inward is -Z, taken from this node's own basis to survive the layback.
	if mesh != null or marker != null:
		power_btn.set_depress_axis_world(-global_transform.basis.z.normalized())
	var col := power_btn.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null and col.shape is BoxShape3D:
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = Vector3(0.012, 0.010, 0.010)
	var lbl := power_btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


# ── Physical control animation ────────────────────────────────────────────────
# Driven each frame by HandheldInput from the exact joypad state it feeds the
# core: face buttons and shoulders/triggers depress, the D-pad rocks, and the
# Circle Pad SLIDES in its dish (it does not tilt like a thumbstick). The stand-in
# does not author these parts, so the block finds nothing and no-ops; it drives any
# shell that names its meshes this way.

const _FACE_MESH := {
	ControllerBindings.JOYPAD_A: "FireButtonRight",   # A
	ControllerBindings.JOYPAD_B: "FireButtonBottom",  # B
	ControllerBindings.JOYPAD_X: "FireButtonTop",     # X
	ControllerBindings.JOYPAD_Y: "FireButtonLeft",    # Y
	ControllerBindings.JOYPAD_START:  "StartButton",
	ControllerBindings.JOYPAD_SELECT: "SelectButton",
}
const _SHOULDER_MESH := {
	ControllerBindings.JOYPAD_L:  "LShoulderButton",
	ControllerBindings.JOYPAD_R:  "RShoulderButton",
	ControllerBindings.JOYPAD_L2: "LIndexTriggerButton",   # ZL
	ControllerBindings.JOYPAD_R2: "RIndexTriggerButton",   # ZR
}
## Also measured: the A/B/X caps stand 1.64 mm proud of the face, so the old
## 2.6 mm sank them about a millimetre into it. (Y, Start and Select ring-sample
## against taller neighbouring geometry and give no clean reading, but a shallower
## press cannot hurt them.)
const _FACE_PRESS := 0.0010
## Measured, not guessed: all four shoulder/trigger caps stand only 1.40 mm proud
## of the back edge they emerge from (ray-cast against the shell with the buttons
## excluded, ring-sampled around each footprint and confirmed by a centre ray).
## The old 4.0 mm drove them 2.6 mm THROUGH the shell. 0.9 mm reads as a press
## and still leaves half a millimetre showing.
const _SHOULDER_PRESS := 0.0009
const _PAD_SLIDE := 0.0032
## The New 3DS's C-Stick is a stiff nub, not a gimbal - on real hardware it
## barely visibly moves. A small tilt reads without looking like a thumbstick.
const _CSTICK_TILT_DEG := 6.0
const _DPAD_TILT_DEG := 8.0
const _ANIM_W := 0.4
const _ANIM_PRESS_DIR := Vector3(0, -1, 0)
## Shoulders sit on the back edge and press INWARD toward the body (+Z on the
## laid-flat shell), not straight down like the face buttons.
const _SHOULDER_DIR := Vector3(0, 0, 1)

var _anim_cached := false
var _anim_btns: Array[Dictionary] = []   # {node, rest, bit, depth}
var _anim_pad: Dictionary = {}           # circle pad: {node, rest}
var _anim_dpad: Dictionary = {}          # {node, rest, pivot}
var _anim_cstick: Dictionary = {}        # C-Stick nub: {node, rest, pivot}


## Both shells spell the pill switches this way, so this claims them on both paths
## and the shared stand-in pass skips them.
func _own_animated_meshes() -> PackedStringArray:
	return PackedStringArray(["StartButton", "SelectButton"])


func _cache_anim_meshes() -> void:
	_anim_cached = true
	for map: Dictionary in [_FACE_MESH, _SHOULDER_MESH]:
		var depth: float = _FACE_PRESS if map == _FACE_MESH else _SHOULDER_PRESS
		var dir: Vector3 = _ANIM_PRESS_DIR if map == _FACE_MESH else _SHOULDER_DIR
		for bit: int in map:
			var m := find_child(map[bit], true, false) as MeshInstance3D
			if m != null:
				_anim_btns.append({"node": m, "rest": m.transform, "bit": bit, "depth": depth, "dir": dir})
	var pad := find_child("StickLeft22", true, false) as MeshInstance3D
	if pad != null:
		_anim_pad = {"node": pad, "rest": pad.transform}
	# The C-Stick. The GLB calls it "PSButton" (the modeller reused a PlayStation
	# name), but its position gives it away: x=+0.0585, z=-0.0332 - right side,
	# behind the ABXY cluster, which is exactly where the nub sits on hardware.
	var cst := find_child("PSButton", true, false) as MeshInstance3D
	if cst != null:
		# Pivot at the nub's BASE so it rocks like a stick rather than swinging
		# about its centre.
		var ab: AABB = cst.get_aabb()
		var base := Vector3(ab.get_center().x, ab.position.y, ab.get_center().z)
		_anim_cstick = {"node": cst, "rest": cst.transform,
			"pivot": cst.transform * base}
	var dpad := find_child("Dpad22", true, false) as MeshInstance3D
	if dpad != null:
		var pivot := dpad.transform.origin
		var e := find_child("Dpad", true, false)
		if e != null and not (e is MeshInstance3D):
			pivot = dpad.get_parent().to_local((e as Node3D).global_position)
		_anim_dpad = {"node": dpad, "rest": dpad.transform, "pivot": pivot}


## btn = RETRO_JOYPAD bitmask; lstick/rstick are the analog values (−1..1) as sent
## to the core (y already screen-negated). Lerps the meshes toward that state.
func animate_controls(btn: int, lstick: Vector2, rstick: Vector2) -> void:
	# The stand-in shares this shell's names for everything except its pad, which
	# it authors as the two-bar DpadBar1/DpadBar2 the base pass knows.
	super.animate_controls(btn, lstick, rstick)
	if not _anim_cached:
		_cache_anim_meshes()

	for e: Dictionary in _anim_btns:
		var node: MeshInstance3D = e["node"]
		var rest: Transform3D = e["rest"]
		var down := 1.0 if (btn & (1 << int(e["bit"]))) != 0 else 0.0
		var dir: Vector3 = e.get("dir", _ANIM_PRESS_DIR)
		var tgt := Transform3D(rest.basis, rest.origin + dir * (float(e["depth"]) * down))
		node.transform = node.transform.interpolate_with(tgt, _ANIM_W)

	if not _anim_pad.is_empty():
		var node: MeshInstance3D = _anim_pad["node"]
		var rest: Transform3D = _anim_pad["rest"]
		# x = right, z toward the hinge (lstick.y is screen-negated, so forward = −z).
		var off := Vector3(lstick.x, 0.0, lstick.y) * _PAD_SLIDE
		node.transform = node.transform.interpolate_with(Transform3D(rest.basis, rest.origin + off), _ANIM_W)

	if not _anim_cstick.is_empty():
		# Rocks about its base in the stick's direction. Same axis convention as
		# the circle pad: x = right, and rstick.y is already screen-negated.
		var r := Basis.from_euler(Vector3(
			deg_to_rad(rstick.y * _CSTICK_TILT_DEG), 0.0,
			deg_to_rad(-rstick.x * _CSTICK_TILT_DEG)))
		var node: MeshInstance3D = _anim_cstick["node"]
		var rest: Transform3D = _anim_cstick["rest"]
		var pivot: Vector3 = _anim_cstick["pivot"]
		var about := Transform3D(r, pivot - r * pivot)
		node.transform = node.transform.interpolate_with(about * rest, _ANIM_W)

	if not _anim_dpad.is_empty():
		var pitch := float((btn >> ControllerBindings.JOYPAD_UP) & 1) - float((btn >> ControllerBindings.JOYPAD_DOWN) & 1)
		var roll := float((btn >> ControllerBindings.JOYPAD_LEFT) & 1) - float((btn >> ControllerBindings.JOYPAD_RIGHT) & 1)
		# Negate pitch: UP must push the FAR edge of the cross down into the shell,
		# not lift it. The unflipped sign tilted the d-pad backwards (pressing up
		# read as down). Roll (left/right) was already correct.
		var r := Basis.from_euler(Vector3(deg_to_rad(-pitch * _DPAD_TILT_DEG), 0.0, deg_to_rad(roll * _DPAD_TILT_DEG)))
		var node: MeshInstance3D = _anim_dpad["node"]
		var rest: Transform3D = _anim_dpad["rest"]
		var pivot: Vector3 = _anim_dpad["pivot"]
		var about := Transform3D(r, pivot - r * pivot)
		node.transform = node.transform.interpolate_with(about * rest, _ANIM_W)


# ── Power LEDs ────────────────────────────────────────────────────────────────
# The shell's indicator LEDs (power, notification, wireless) ship with their
# emission always on, so the console looked powered even when off. Gate them on
# the run state: dark when off, lit when on.

const _LED_MESHES := ["LED", "LED (1)", "LED (2)"]
var _leds: Array[Dictionary] = []   # {mat, energy}
var _leds_cached := false


func _cache_leds() -> void:
	_leds_cached = true
	for nm in _LED_MESHES:
		var mi := find_child(nm, true, false) as MeshInstance3D
		if mi == null:
			continue
		var src := mi.get_active_material(0)
		if not (src is BaseMaterial3D):
			continue
		# Own copy so the shared GLB material isn't dimmed for every 3DS at once.
		var mat := (src as BaseMaterial3D).duplicate() as BaseMaterial3D
		mi.set_surface_override_material(0, mat)
		_leds.append({"mat": mat, "energy": mat.emission_energy_multiplier})


func _set_leds(lit: bool) -> void:
	if not _leds_cached:
		_cache_leds()
	for e: Dictionary in _leds:
		var mat: BaseMaterial3D = e["mat"]
		mat.emission_enabled = lit
		mat.emission_energy_multiplier = float(e["energy"]) if lit else 0.0


func on_power_on() -> void:
	super.on_power_on()
	_set_leds(true)


func on_power_off() -> void:
	super.on_power_off()
	_set_leds(false)

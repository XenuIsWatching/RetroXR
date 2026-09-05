## RetroSystemModelNES — the American front-loading NES (NES-001).
##
## Wires POWER / RESET, the power LED, the two controller sockets, the AV lead and
## the front-loading cartridge bay. The bay sits behind a hinged front flap (the
## "NesLid"): a grip-latched VRHinge swings the flap on its real hinge, so a
## cartridge can only be seated or pulled while the flap is up. Inserting or
## removing a cart drives the flap automatically.
##
## Ported from RetroVR's model of the same name, which was written against
## Mordred's EmuVR GLB. This one drives greenestbanana's Sketchfab shell instead
## (see LICENSE-nes-console.txt), so the parts that existed only to repair the
## .ugc->.glb conversion are gone:
##
##   * no clutter-hiding — the cord and controller were stripped from the asset.
##   * no decal-alpha repair — Sketchfab exports NesLabels as alphaMode MASK,
##     already correct; it was the .ugc converter that forced OPAQUE.
##   * no front-band repaint — that shell shared one black material between a
##     bogus front band and the cradle. This shell splits into three meshes.
##   * no flap-decal reparenting and no AnimationPlayer to disarm — the wordmark
##     decal was removed from the asset and no clips ship with it.
##
## The flap and port geometry carry over unchanged: both models measure the same
## hardware, and their port positions agree within 2 mm.
class_name RetroSystemModelNES
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/consoles/nes/nes_console.glb"
const RCA_PORT_SCENE := preload("res://Scenes/Objects/cables/rca_port.tscn")
const BUTTON_DEPRESS_DEPTH := 0.0022
# Travel of the CH3/CH4 knob. 3 mm, so that a 6 mm knob stays inside the 9.8 mm
# recess the shell moulds for it at both detents — see _build_channel_switch.
const CH_THROW := 0.003
# --- the ZIF cradle -------------------------------------------------------------
#
# The hardware hinges the whole carriage: Nintendo's patent for this mechanism
# (EP0217538) has the tray "elastically energized upward by these coil springs", the
# cart entering at about 10 degrees to the board, and a push-push latch. This shell
# models that carriage jammed under its own top skin — NesCradle's side walls have
# 1.1 mm of headroom, which is 0.68 degrees before it comes out through the top of
# the console — so the bay is SUNK by CRADLE_DROP first, and cradle and cart swing
# together through TRAY_UP_DEG. The pair of numbers is what the shell allows: past
# 4.5 degrees no drop satisfies both the skin above and the mouth's lower lip.
static var TRAY_UP_DEG := 10.0
## The shell models the cradle jammed under its own top skin — 1.1 mm of headroom,
## which is not enough for it to hinge at all — so the whole bay is sunk this far.
##
## Three surfaces bound the swing, and TRAY_UP_DEG is what is left over:
##   * the mouth is 34.2 mm and the cart 17 mm, over a 138 mm lever from the hinge
##     to the mouth plane: 7.1 degrees, and no choice here can beat it, because the
##     cart has to pass that hole both level and tilted;
##   * the cradle's tallest wall must stay under the deck's outer skin, which costs
##     1.67 mm of drop per degree;
##   * a level cart must still clear the mouth's lower lip, which caps the drop.
## At 6 degrees each of the three keeps about a millimetre in hand.
static var CRADLE_DROP := 0.016
## How much higher the cart rides in the cradle than the tray's own mid-height. The
## cradle is a 34 mm box around a 17 mm cart, and sinking the tray far enough to
## swing would otherwise drag the cart below the mouth with it: lifting it inside
## the tray buys back most of the drop.
static var CART_LIFT := 0.001
## A push released within this of flat counts as home.
const TRAY_LATCH_DEG := 1.5
## Seconds the tray takes to sink under a click. A VR hand carries it down itself,
## but a click has no travel of its own to borrow, and a tray that teleports home
## is not a hinge.
const TRAY_PUSH_TIME := 0.14
## Degrees/sec the springs take it back up — a quarter of the class default, which
## is sized for a disc lid swinging through ninety.
const TRAY_SPRING_DEG := 35.0
## Depth of the seat along the console's front, measured from the tray's own
## centre: 0 is where the cradle puts it, positive brings the cart out of the
## machine. The tray is authored well back in this shell, so this is the knob that
## decides how much of a seated cart the player can actually see.
static var CART_SEAT_DEPTH := -0.005
## How far the HELD cart's ghost stands proud of the shell's front face. The seat
## itself is inside the machine — this bay is authored 24.5 mm behind that face and
## is shorter than the cart — so the offer is measured from the face rather than
## quoted from the seat, and the release slides the whole of that distance home.
static var CART_PROUD := 0.000
## How far a controller plug stands off its socket before it goes in.
static var PLUG_PROUD := 0.012
const LID_OPEN_DEG := -105.0      # flap swing about its top-rear hinge edge
const LID_ANIM_TIME := 0.35

var _glb: Node3D = null

# Front flap (hinge). Rotated about a hinge edge computed from its own AABB —
# the top-rear edge, which on this asset coincides exactly with the NesLidPivot
# node's origin, so the computed pivot lands at (0,0,0) in the flap's parent.
var _lid_mesh: MeshInstance3D = null
var _lid_rest: Transform3D = Transform3D.IDENTITY
var _lid_pivot: Vector3 = Vector3.ZERO   # hinge point in the flap's parent space
var _lid_amount: float = 0.0             # 0 = shut … 1 = fully open
var _lid_tween: Tween = null

# The shell's own RF SWITCH jack and CH3-CH4 slide switch, on the BACK face. The
# jack is used as it is; the switch needs a cap of its own to slide. See
# _build_rf_panel.
var _rf_out: RcaPort = null
var _ch_slider: VRSlider = null
var _ch_knob: MeshInstance3D = null
var _rf_channel: int = 3

var _power_button: VRButton = null

# Switch sounds, recorded off the real NES-001 with a contact mic on the shell
# layered against an air mic. See _build_sfx.
var _reset_button: VRButton = null
var _sfx_voices: Array[PcmOneShot] = []
var _sfx_next: int = 0
var _sfx_power_on: Array = []
var _sfx_power_off: Array = []
var _sfx_reset_press: Array = []
var _sfx_reset_release: Array = []
var _sfx_channel: Array = []
var _sfx_cart_insert: Array = []
var _sfx_cart_remove: Array = []
var _sfx_tray_down: Array = []
var _sfx_tray_up: Array = []
var _sfx_last: Dictionary = {}
# Where the POWER switch physically sits. The NES's is push-push, so a press
# always clicks — which of the two clicks it is depends on the latch position
# BEFORE the press, and not at all on whether a core managed to start.
var _power_in: bool = false
var _reset_was_held: bool = false

var _cartridge_slot: Node3D = null
# The tray is not a mesh here (see TRAY_UP_DEG) — it is a hinged frame that carries
# the cartridge SLOT, so a seated cart rides it and nothing else has to move.
var _tray_pivot: Node3D = null
var _tray_hinge: VRSpringLatchedHinge = null
var _seat_in_tray := Transform3D.IDENTITY
var _tray_applied_deg := INF   # last angle written onto the slot
# Where the cradle was before the bay was built, so the whole thing can be torn
# down and laid out again from changed numbers (see retune).
var _cradle_home_parent: Node = null
var _cradle_home_xform := Transform3D.IDENTITY
var _tray_tween: Tween = null
var _tray_down := false

# Front-flap interaction — a grip-latched VRHinge drives the flap: grab its
# bottom (free) half and swing it. _flap_frame/_flap_pivot form the angle-driver
# frame the hinge reports into (origin at the real hinge, -Z along the shut
# flap); _deg_open is that frame's angle at full open, so the reported degrees
# map onto _lid_amount 0..1.
var _lid_open: bool = false
var _flap_hinge: VRHinge = null
var _flap_frame: Node3D = null
var _flap_pivot: Node3D = null
var _deg_open: float = 0.0


func _ready() -> void:
	# An authored nes.tscn may instance the shell as a "Shell" child so the
	# cartridge seat can be dialled in in the Godot 3D editor. Reuse that instance
	# rather than loading a second copy of the GLB.
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
	else:
		if not ResourceLoader.exists(_MODEL_PATH):
			push_warning("NESModel: %s missing — using placeholder box" % _MODEL_PATH)
			var host := get_parent()
			if host:
				var body := host.get_node_or_null("SystemBody") as MeshInstance3D
				if body:
					body.show()
			return
		var scene := load(_MODEL_PATH) as PackedScene
		if scene == null:
			push_warning("NESModel: failed to load %s" % _MODEL_PATH)
			return
		_glb = scene.instantiate() as Node3D
		# MUST be "Shell": that is what RetroSystemModel.has_baked_shell() looks
		# for, and it is how the framework knows this model brings its own printed
		# legends. Left unnamed, the cabinet decided there was no detailed shell
		# and laid its own SystemNameLabel — "NINTENDO ENTERTAINMENT SYSTEM" — flat
		# across the console's front face.
		_glb.name = "Shell"
		add_child(_glb)

	var preview := find_child("SeatPreview", true, false)
	if preview is Node3D:
		(preview as Node3D).visible = false

	# nes.tscn deliberately authors this imported pivot OPEN so the complete shell
	# and both activation boxes can be edited together. Runtime starts from the real
	# shut rest pose; the flap interaction below then owns all subsequent movement.
	var editor_lid_pivot := _glb.find_child("NesLidPivot", true, false) as Node3D
	if editor_lid_pivot != null:
		editor_lid_pivot.rotation = Vector3.ZERO

	# The shell is authored centred on its own middle, so half of it would hang
	# below any surface it is placed on. Recentre on X/Z and rest the base at
	# y = 0 — which is also what the port constants below assume. Baked scenes
	# already carry this in the Shell transform, so re-running it would double up.
	if baked == null:
		var b := _model_aabb(_glb)
		var c := b.position + b.size * 0.5
		_glb.position = Vector3(-c.x, -b.position.y, -c.z)

	_lid_mesh = _glb.find_child("NesLid", true, false) as MeshInstance3D
	if _lid_mesh:
		_lid_rest = _lid_mesh.transform
		var a := _lid_mesh.get_aabb()
		var hinge_local := Vector3(a.position.x + a.size.x * 0.5, a.position.y + a.size.y, a.position.z)
		_lid_pivot = _lid_mesh.transform * hinge_local
		_setup_flap_hinge()

	_power_light_mesh = _glb.find_child("PowerLight", true, false) as MeshInstance3D
	if _power_light_mesh:
		prep_power_light(Color(1.0, 0.05, 0.0), LED_COLOR, LED_ENERGY, 3.0)
		set_power_light(false)

	_build_sfx()


# --- switch sounds --------------------------------------------------------------

## Recordings of this exact machine's switches, spatialised through PcmOneShot.
##
## They hang off the WIDGETS, not off RetroSystem.power_on()/power_off(): those are
## also called by code — scene_persistence powers every running machine down when it
## tears a room out — and a rack of consoles all clicking at once during a room
## change is not what a power switch means. A switch sound means something moved.
##
## TWO voices, round-robin. RESET is a spring button whose press and release are
## separate clips ~250 ms apart, and PcmOneShot restarts rather than layers, so a
## single voice would cut the press off the moment the finger lifted.
const SFX_DIR := "res://Audio/nes/"


func _build_sfx() -> void:
	_sfx_power_on = _load_variants("nes_power_on")
	_sfx_power_off = _load_variants("nes_power_off")
	_sfx_reset_press = _load_variants("nes_reset_press")
	_sfx_reset_release = _load_variants("nes_reset_release")
	_sfx_channel = _load_variants("nes_channel_switch")
	_sfx_cart_insert = _load_variants("nes_cart_insert")
	_sfx_cart_remove = _load_variants("nes_cart_remove")
	_sfx_tray_down = _load_variants("nes_tray_down")
	_sfx_tray_up = _load_variants("nes_tray_up")
	for i in 2:
		var v := PcmOneShot.new()
		v.name = "SwitchSfx%d" % i
		# A console's switch is a small, local noise: you are within arm's reach of
		# the front panel to press it at all. Matches bead_pull_cord's pull click
		# rather than the console's own audio feed (unit_size 3.0).
		v.unit_size = 0.6
		v.max_distance = 3.0
		v.volume = 0.6
		add_child(v)
		_sfx_voices.append(v)
	set_process(true)


## Every `<prefix>_NN.wav` in SFX_DIR, counting up until one is missing.
## ResourceLoader.exists(), never FileAccess.file_exists() — the latter is false in
## an exported build, where res:// paths are remapped into the pck.
func _load_variants(prefix: String) -> Array:
	var out: Array = []
	var i := 1
	while true:
		var p := "%s%s_%02d.wav" % [SFX_DIR, prefix, i]
		if not ResourceLoader.exists(p):
			break
		var frames := PcmClip.load_frames(p)
		if not frames.is_empty():
			out.append(frames)
		i += 1
	if out.is_empty():
		push_warning("NESModel: no %s_NN.wav under %s" % [prefix, SFX_DIR])
	return out


## Pick a variant and play it on the next free-ish voice. Never repeats the variant
## it played last for that key — with 5-8 takes per switch, a plain random pick
## still doubles often enough to read as a glitch rather than as variation.
func _play_sfx(bank: Array, key: String) -> void:
	if bank.is_empty() or _sfx_voices.is_empty():
		return
	var idx := randi() % bank.size()
	if bank.size() > 1 and idx == int(_sfx_last.get(key, -1)):
		idx = (idx + 1) % bank.size()
	_sfx_last[key] = idx
	var voice: PcmOneShot = _sfx_voices[_sfx_next]
	_sfx_next = (_sfx_next + 1) % _sfx_voices.size()
	voice.play(bank[idx])


## False while a save is being reloaded. RetroSystem.restore_cartridge seats media
## through the same snap zone a hand uses, so without this, loading a room plays a
## cartridge insert for every console in it at once.
##
## The tray hinge needs its own half of that. It is persisted as an articulated
## control and restored by writing its angle and latch back, which emits
## rotation_changed exactly like a push — and that write happens BEFORE the media
## restore, outside _restoring_media entirely. ScenePersistence marks the control
## for the duration of the write (the same flag that stops ObjectSync echoing a
## restore back onto the wire), so read it here: without it, every room saved with
## a cart pushed home clicks its cradle shut on arrival. A REMOTE peer's push is
## deliberately not covered — a hand did move that one, just not this player's.
func _hand_did_it() -> bool:
	if _tray_hinge != null \
			and bool(_tray_hinge.get_meta("net_restore_in_progress", false)):
		return false
	var host := get_parent()
	if host == null:
		return true
	return host.has_method("is_restoring_media") and host.is_restoring_media()


func _on_power_button_pressed() -> void:
	_power_in = not _power_in
	_play_sfx(_sfx_power_on if _power_in else _sfx_power_off, "power")


func _on_reset_button_pressed() -> void:
	_play_sfx(_sfx_reset_press, "reset_press")
	_reset_was_held = true


## VRButton reports the press but has no released signal, so the release click is
## driven off the falling edge of is_held(). Watched here rather than by adding a
## signal to VRButton — that widget is shared by every machine, every panel and the
## Wiimote, and this is one console's sound.
func _process(_delta: float) -> void:
	_sync_cart_tray()
	if not _reset_was_held or _reset_button == null:
		return
	if not _reset_button.is_held():
		_reset_was_held = false
		_play_sfx(_sfx_reset_release, "reset_release")


# --- power LED ------------------------------------------------------------------

## Set from the PEAK value the light lays on the panel directly behind the lens:
## energy = peak * LED_STANDOFF^2. Godot attenuates a positional light as
##     (1 - (d/range)^4)^2 * d^(-decay)
## which is inverse square at LED_DECAY 2.0, with the range window still ~1 this
## close in.
##
## NOT from the LED's rated millicandela. A point source over-predicts the bezel
## by more than an order of magnitude at 6 mm: the lens is about as wide as the
## distance being divided by, and the real emitter sits IN the panel, occluded
## sideways by its own bezel.
##
## Peak 3.0 because spill cannot outshine what spills it — the lit lens runs
## emission 3.0, so this puts the brightest plastic level with the lens and
## everything else below it. Past about 6 the panel clips white under FILMIC and
## blooms; under about 1.5 the machine stops reading as switched on.
const LED_ENERGY := 0.000108
const LED_COLOR := Color(1.0, 0.09, 0.03)


func _model_aabb(inst: Node3D) -> AABB:
	var acc := AABB()
	var first := true
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible:
			var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for ch in n.get_children():
			stack.append(ch)
	return acc


func _mesh_center(mesh_name: String) -> Vector3:
	if _glb == null:
		return global_position
	var m := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	return (m.global_transform * m.get_aabb().get_center()) if m != null else global_position


# --- front flap (hinge) ---------------------------------------------------------

## Pose the flap: 0 = shut, 1 = fully open. Rotates the mesh about its hinge edge.
func _set_lid(amount: float) -> void:
	_lid_amount = amount
	if _lid_mesh == null:
		return
	var r := Basis(Vector3.RIGHT, deg_to_rad(LID_OPEN_DEG) * amount)
	var about := Transform3D(r, _lid_pivot - r * _lid_pivot)
	_lid_mesh.transform = about * _lid_rest
	_sync_flap_plug()


func _tween_lid(to: float) -> void:
	if _lid_tween != null and _lid_tween.is_valid():
		_lid_tween.kill()
	_lid_tween = create_tween()
	_lid_tween.tween_method(_set_lid, _lid_amount, to, LID_ANIM_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## Swing the flap up on its hinge and enable the cartridge bay. Also snaps the
## grab hinge to the open angle so a following grab resumes from the right pose.
func play_open() -> void:
	if _lid_open:
		return
	_lid_open = true
	print("[NES state] lid: OPENING (automatic)")
	_tween_lid(1.0)
	if _flap_hinge != null:
		_flap_hinge.set_rotation_deg_no_signal(_deg_open)
	if _cartridge_slot != null:
		_cartridge_slot.enabled = true


## Swing the flap shut and gate the bay closed.
func play_close() -> void:
	if not _lid_open:
		return
	_lid_open = false
	print("[NES state] lid: CLOSING (automatic)")
	_tween_lid(0.0)
	if _flap_hinge != null:
		_flap_hinge.set_rotation_deg_no_signal(0.0)
	if _cartridge_slot != null:
		_cartridge_slot.enabled = false


## How far the flap has swung, in degrees from shut. The clamshell's
## interior-angle convention does not apply to a front flap, but the save format
## is the same field: a lid pose in degrees, or -1 for hardware without one.
func get_lid_angle_deg() -> float:
	return _lid_amount * absf(LID_OPEN_DEG)


## Pose the flap at a saved angle, with no animation — a restore is a state the
## room was already in, not something the player just did. Takes the bay gate and
## the grab hinge with it, so the next grab resumes from the right pose.
func set_lid_angle_deg(open_deg: float) -> void:
	if _lid_tween != null and _lid_tween.is_valid():
		_lid_tween.kill()
	var amount := clampf(open_deg / absf(LID_OPEN_DEG), 0.0, 1.0)
	_set_lid(amount)
	_lid_open = amount > 0.5
	if _flap_hinge != null:
		_flap_hinge.set_rotation_deg_no_signal(_deg_open * amount)
	if _cartridge_slot != null:
		_cartridge_slot.enabled = _lid_open


## Build the grip-latched grab handle on the flap. A hidden angle-driver frame
## (origin at the real hinge, -Z along the shut flap, X along the hinge axis) is
## what the VRHinge reports into; the reported degrees are remapped onto the
## flap's own about-the-hinge rotation via _set_lid, so the mesh keeps its pivot
## math. The grab Area3D rides the flap mesh, so the box, the VR proximity sphere
## and the floating hint icon track the swinging flap.
func _setup_flap_hinge() -> void:
	if _lid_mesh == null:
		return
	var fp := _lid_mesh.get_parent() as Node3D
	if fp == null:
		return
	var a := _lid_mesh.get_aabb()
	var cx := a.position.x + a.size.x * 0.5
	var cz := a.position.z + a.size.z * 0.5
	var hinge_par: Vector3 = _lid_rest * Vector3(cx, a.position.y + a.size.y, cz)
	var free_par: Vector3 = _lid_rest * Vector3(cx, a.position.y, cz)
	var open_rot := Basis(Vector3.RIGHT, deg_to_rad(LID_OPEN_DEG))
	var free_open_par: Vector3 = hinge_par + open_rot * (free_par - hinge_par)
	var to_model: Transform3D = global_transform.affine_inverse() * fp.global_transform
	var hinge_m: Vector3 = to_model * hinge_par
	var free_m: Vector3 = to_model * free_par
	var free_open_m: Vector3 = to_model * free_open_par
	var axis_m: Vector3 = (to_model.basis * Vector3.RIGHT).normalized()
	var shut_dir: Vector3 = (free_m - hinge_m).normalized()
	var x_axis := axis_m
	var z_axis := (-shut_dir - x_axis * (-shut_dir).dot(x_axis)).normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	_flap_frame = Node3D.new()
	_flap_frame.name = "FlapHinge"
	add_child(_flap_frame)
	_flap_frame.transform = Transform3D(Basis(x_axis, y_axis, z_axis), hinge_m)
	_flap_pivot = Node3D.new()
	_flap_pivot.name = "FlapDragPivot"
	_flap_frame.add_child(_flap_pivot)
	var open_rel: Vector3 = _flap_frame.transform.affine_inverse() * free_open_m
	_deg_open = rad_to_deg(atan2(open_rel.y, -open_rel.z))
	_flap_hinge = VRHinge.new()
	_flap_hinge.name = "FlapGrab"
	# Squeeze to swing it. Nobody picks a deck up off the desk by its cartridge
	# flap, so the grip is free to mean "open this" here; the hinge mutes that
	# hand's pickup while it is on the flap so the console stays put.
	_flap_hinge.grip_engages = true
	_flap_hinge.box_engages = true
	# In this asset the flap's outward/front face is local +Z. Its torque decides
	# direction; the bottom (-Y) remains open-only and the top (+Y) close-only.
	_flap_hinge.poke_open_faces = VRHinge.FACE_Y_NEG
	_flap_hinge.poke_close_faces = VRHinge.FACE_Y_POS
	_flap_hinge.poke_torque_faces = VRHinge.FACE_Z_POS
	_flap_hinge.poke_release_momentum = true
	_flap_hinge.state_log_name = "lid"
	_flap_hinge.target = _flap_pivot
	_flap_hinge.min_deg = minf(0.0, _deg_open)
	_flap_hinge.max_deg = maxf(0.0, _deg_open)
	_flap_hinge.engage_radius = clampf(maxf(a.size.x, a.size.y * 0.5) * 0.6, 0.03, 0.09)
	_lid_mesh.add_child(_flap_hinge)
	var col := _lid_mesh.find_child("LidActivationBox", true, false) as CollisionShape3D
	if col != null and col.shape is BoxShape3D:
		# The scene owns both transform and size. Move the shape under the live Area3D
		# while preserving exactly what was authored relative to the lid mesh.
		var preview_area := col.get_parent() as Area3D
		_flap_hinge.global_transform = col.global_transform
		col.reparent(_flap_hinge, true)
		col.transform = Transform3D.IDENTITY
		if preview_area != null:
			preview_area.queue_free()
	else:
		# Fallback for a bare script instance: the shipped model always takes the
		# authored branch, but keeping this makes the class independently usable.
		_flap_hinge.transform = Transform3D(Basis.IDENTITY,
			Vector3(cx, a.position.y + a.size.y * 0.25, cz))
		col = CollisionShape3D.new()
		col.name = "LidActivationBox"
		var fallback_box := BoxShape3D.new()
		fallback_box.size = Vector3(a.size.x * 0.9, a.size.y * 0.5,
			maxf(a.size.z, 0.006) + 0.012)
		col.shape = fallback_box
		_flap_hinge.add_child(col)
	# Poke uses two thin boxes matching the lid's horizontal and front planes,
	# independent of the generous trigger/grip box above. Move the authored shapes
	# under the live hinge so they follow the flap while retaining lid-local poses.
	var poke_area := _lid_mesh.get_node_or_null("LidPokeSurfaces") as Area3D
	if poke_area != null:
		for node in poke_area.find_children("*", "CollisionShape3D", true, false):
			var poke_shape := node as CollisionShape3D
			if poke_shape != null:
				poke_shape.reparent(_flap_hinge, true)
		poke_area.queue_free()
	# Hint in the flap's OWN plane, just past the grab box. Derived from the pivot
	# rather than written as a literal -Y: this hinge hangs off the flap MESH while
	# its pivot lives under _flap_frame, so their axes only happen to line up.
	var ax_w: Vector3 = _flap_pivot.global_transform.basis.x.normalized()
	var radial: Vector3 = _flap_hinge.global_position - _flap_pivot.global_position
	radial -= ax_w * radial.dot(ax_w)
	if radial.length() > 0.0001:
		var box_size: Vector3 = (col.shape as BoxShape3D).size
		_flap_hinge.place_hint(_flap_hinge.to_local(_flap_hinge.global_position
			+ radial.normalized() * (box_size.y * 0.5 + 0.014)))
	_flap_hinge.rotation_changed.connect(_on_flap_drag)


## Map the grab hinge's reported angle onto the flap open amount and gate the bay.
func _on_flap_drag(deg: float) -> void:
	if is_zero_approx(_deg_open):
		return
	var amount := clampf(deg / _deg_open, 0.0, 1.0)
	_set_lid(amount)
	var open := amount > 0.5
	if open == _lid_open:
		return
	_lid_open = open
	print("[NES state] lid: %s at %.2f deg" % [
		"OPEN" if open else "CLOSED", absf(deg)])
	if _cartridge_slot != null:
		_cartridge_slot.enabled = _lid_open


# --- ports / buttons / cable ----------------------------------------------------

## Push the plug the last centimetre in. Same shape as the cartridge slide, and for
## the same reason: the ghost stood off the socket, so something has to cover the
## distance or the plug simply appears seated.
##
## The cord is anchored to this plug, so the move has to be a TRAVEL and not a
## teleport — a rope whose anchor jumps re-lays itself across the room.
func play_port_plug_insert(plug: Node3D, zone: Node3D) -> void:
	if not _hand_did_it():
		return
	var socket := zone as XRToolsSnapZone
	if socket == null or not (plug is RigidBody3D):
		return
	var seated := socket.snap_pose_for(plug)
	# The snap zone already froze and owns this body. Keep it kinematic for the
	# travel: unfreezing here revives the downward release velocity that Pickable
	# deliberately gives a dropped body, so a physics tick can pull the plug down
	# for one rendered frame before the tween puts it back.
	plug.global_transform = socket.preview_pose_for(plug)
	var tween := plug.create_tween()
	tween.tween_property(plug, "global_transform", seated, 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func get_controller_port_count() -> int:
	return 2


func card_slot_count() -> int:
	return 0


## POWER latches down and stays in; RESET is momentary. This shell ships no
## "Finger Button" empties to read the travel axis from, so both are placed at
## their mesh centres and pressed along the console's own -Z, into the front face.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, _eject_btn: VRButton) -> void:
	_power_button = power_btn
	_reset_button = reset_btn
	power_btn.depress_depth = BUTTON_DEPRESS_DEPTH
	reset_btn.depress_depth = BUTTON_DEPRESS_DEPTH
	power_btn.set_latched_pressed(false)
	reset_btn.set_latched_pressed(false)
	power_btn.button_pressed.connect(_on_power_button_pressed)
	reset_btn.button_pressed.connect(_on_reset_button_pressed)
	if _glb != null:
		var into_face: Vector3 = -global_transform.basis.z.normalized()
		var power_mesh := _glb.find_child("ButtonPower", true, false) as MeshInstance3D
		var reset_mesh := _glb.find_child("ButtonReset", true, false) as MeshInstance3D
		if power_mesh:
			power_btn.set_button_mesh(power_mesh)   # also hides the placeholder box
			power_btn.global_position = _mesh_center("ButtonPower")
			power_btn.set_depress_axis_world(into_face)
			_ride_cap(power_mesh, "ButtonPowerLabel")
		if reset_mesh:
			reset_btn.set_button_mesh(reset_mesh)
			reset_btn.global_position = _mesh_center("ButtonReset")
			reset_btn.set_depress_axis_world(into_face)
			_ride_cap(reset_mesh, "ButtonResetLabel")
	for btn in [power_btn, reset_btn]:
		var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
		if lbl:
			lbl.hide()


## Hang a printed legend on the cap it is printed on.
##
## The shell models POWER and RESET as decal planes 0.1 mm proud of their cap's
## face, but parents them BESIDE the cap under the shared ButtonPowerPivot rather
## than to it. VRButton travels the cap mesh alone, so a pressed button sank 2.2 mm
## and left its word hanging in the air in front of the hole.
func _ride_cap(cap: MeshInstance3D, legend_name: String) -> void:
	var legend := _glb.find_child(legend_name, true, false) as Node3D
	if legend != null and legend.get_parent() != cap:
		legend.reparent(cap)


## The two front-panel sockets, measured off the shell's own "1" and "2" number
## decals and dropped to the socket mouths below them. Carried over from RetroVR's
## model of the same hardware — this shell's decals sit at x = 0.0658 / 0.0840,
## within 2 mm of those, so the same constants hold.
const _PORT_X := [0.0645, 0.0824]
const _PORT_Y := 0.0301
const _PORT_Z := 0.0975


func configure_controller_ports(port_zones: Array) -> void:
	for i in range(port_zones.size()):
		var zone: Node3D = port_zones[i]
		# An authored "PortSeat1"/"PortSeat2" marker wins over the computed pose,
		# the same "authored beats computed" idiom as CartSeat/DiscSeat.
		var seat := find_child("PortSeat%d" % (i + 1), true, false) as Node3D
		if seat != null:
			zone.global_transform = seat.global_transform
		elif i < _PORT_X.size():
			zone.position = Vector3(_PORT_X[i], _PORT_Y, _PORT_Z)
			# Front-facing socket: ROLL 180 about Z so the plug seats connector-in
			# and upright. A yaw lands it backwards and upside down.
			#
			# The turning is not done by this rotation alone. ControllerPlug's
			# SnapGrabPoint is itself rotated 180 about X, and XRTools aligns that
			# grab point — not the plug's origin — to the zone. Composed with it, a
			# roll sends the plug's +Z connector to -Z (into the shell) and keeps +Y
			# up; a yaw sends the connector back OUT and flips the plug over.
			zone.rotation_degrees = Vector3(0, 0, 180)
		# Offer the plug at the socket's mouth rather than already inside it. The
		# roll above is about Z, which leaves the zone's own +Z pointing out of the
		# shell, so the stand-off is that axis whether the pose was authored or
		# computed.
		zone.preview_offset = Vector3(0, 0, PLUG_PROUD)
	hide_port_placeholders(port_zones)


## Sockets, not a captive lead: this shell moulds the two jacks the hardware has,
## so the player runs a mono composite lead from them to the set the way you did.
## Video and ONE audio channel — the NES is mono, and its single cord feeds
## whichever speaker it reaches.
func av_port_channels() -> Array:
	return [RcaPort.Channel.VIDEO, RcaPort.Channel.AUDIO_L]


## Seat the two ports on the jacks the shell already moulds — JackYellow for video,
## JackRed for the one audio channel an NES puts out.
##
## Positions are read off those meshes rather than written down: the shell is a
## downloaded asset and its jacks are where they are. The ports' own jack visuals
## are turned off, because the moulded pair underneath is the one that belongs to
## this console and two in the same place would z-fight.
##
## Rotation is +90° about Y, which puts each socket's local +Z on device +X — out
## of the flank. NOT the captive lead's -90°: that convention exists because
## VerletRope leaves an attach point along its local -Z, so it aims the OPPOSITE
## way. Used here it yaws every plug 180° and the connector points out of the
## console while the body sits inside it.
func configure_av_ports(ports: Array) -> void:
	if _glb == null:
		return
	var jacks := ["JackYellow", "JackRed"]
	for i in mini(ports.size(), jacks.size()):
		var port: Node3D = ports[i]
		var centre := _mesh_center(jacks[i])
		if centre == Vector3.ZERO:
			continue
		port.global_position = centre
		port.rotation = Vector3(0.0, PI / 2.0, 0.0)
		if port.has_method("set"):
			port.set("show_jack", false)
	# The back face carries two more of the console's own fittings.
	_build_rf_panel()


## Make the shell's own RF SWITCH jack and CH3-CH4 slide switch work.
##
## BOTH ARE ALREADY MOULDED, on the BACK face beside the AC adapter legend, and the
## shell prints their names in red. Nothing is drawn here: this hangs a snap zone
## over the jack and a VRSlider over the switch, exactly as configure_av_ports does
## for the moulded AUDIO/VIDEO pair on the flank.
##
## ── Measured by raycast, because neither is a named node ────────────────────
## JackRed and JackYellow are their own MeshInstances and can be looked up. These
## two are baked into NesDeck / NesDeckBlack, so the only way to find them is to
## fire rays at the back face along +Z and read where the surface is:
##
##   panel face                z = -0.0964
##   RF SWITCH jack, centred   (0.0635, 0.0290)   boss 2.1 mm proud
##   CH3-CH4 switch, centred   (0.0783, 0.0295)   recessed 2.1 mm into the panel
##
## Absolute in the model's frame rather than stepped off another mesh, which is what
## the rest of this file does for hand-measured geometry (see configure_collision).
## _ready re-centres the GLB deterministically, so these are stable for this asset;
## a re-export that moves the case needs them re-measured.
const RF_OUT_POS := Vector3(0.0635, 0.0290, -0.0985)
const CH_SW_POS := Vector3(0.0783, 0.0308, -0.0982)


func _build_rf_panel() -> void:
	if _glb == null:
		return
	_build_rf_out()
	_build_channel_switch()


func _build_rf_out() -> void:
	var port := RCA_PORT_SCENE.instantiate() as RcaPort
	port.name = "RfOut"
	# Channel.VIDEO, not a channel of its own: an RF feed is not composite video,
	# but nothing in the routing has to know — which input a television treats it as
	# is decided by the SOCKET it lands in at the far end. See CoaxPort.
	port.channel = RcaPort.Channel.VIDEO
	port.direction = RcaPort.Direction.OUT
	# The shell moulds this jack, so the port must not draw a second one on top of
	# it — the same call the AUDIO/VIDEO pair makes, and for the same reason.
	port.show_jack = false
	add_child(port)
	port.position = RF_OUT_POS
	# Yawed a half turn so the socket receives along device -Z, out of the back.
	# The flank pair uses +90 for the same reason; this is that rule on the other
	# face, and a plain yaw is enough because a phono connector is round.
	port.rotation = Vector3(0.0, PI, 0.0)
	_rf_out = port


## Make the moulded CH3-CH4 switch work, and let it actually slide.
##
## The switch IS already modelled — a ribbed thumb cap at the CH3 end of a black slot
## — but it cannot be moved: it is baked into NesDeckBlack along with half the case,
## not a node of its own. A switch that never moves is a switch the player cannot
## read, so the moulded cap is MASKED by a plate the colour of the slot behind it and
## a cap of our own rides in the slot instead. Only two small meshes, both inside the
## recess the shell already moulds, and nothing else about the console is touched.
##
## The alternative — a hidden placeholder knob, the case VRSlider and WidgetOutline
## both document — leaves the printed CH3-CH4 legend pointing at something that never
## changes. Worth the two meshes to avoid.
##
## Sizes come off the raycast and the render: the moulded cap spans x 0.0771..0.0832,
## y 0.0280..0.0336, inside a slot running x 0.0729..0.0836. The mask covers the
## former and our cap slides 3 mm inside the latter.
##
## The mask's DEPTH is the part that bit. A 2.5 mm raycast sweep reported the switch
## at z = -0.0943 and a plate put there left the ribs poking straight through it: the
## sweep had been landing in the rib VALLEYS, and the crests stand out at -0.0965,
## flush with the panel. Both plate and cap therefore sit in FRONT of -0.0965, which
## is also why the cap ends up standing a couple of millimetres proud — as a thumb
## switch does.
const CH_MASK_POS := Vector3(0.0801, 0.0308, -0.0969)


func _build_channel_switch() -> void:
	# The slot's own black, so the plate reads as empty slot rather than as a patch.
	# UNSHADED, and that is the whole trick: the slot it has to disappear into is a
	# deep recess the key light never reaches, so a lit plate across the mouth of it
	# comes back several stops brighter and reads as a patch. Darkness by MATERIAL,
	# the same call gen_rca_jack.gd makes for a socket bore.
	var slot_ink := StandardMaterial3D.new()
	slot_ink.albedo_color = Color(0.02, 0.02, 0.022)
	slot_ink.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var mask := MeshInstance3D.new()
	mask.name = "ChannelMask"
	var mask_mesh := BoxMesh.new()
	mask_mesh.size = Vector3(0.0068, 0.0062, 0.0008)
	mask.mesh = mask_mesh
	mask.material_override = slot_ink
	add_child(mask)
	mask.position = CH_MASK_POS

	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(0.52, 0.51, 0.50)
	cap_mat.roughness = 0.62

	# Authored at the CH3 detent, which is slider value 0 — set_knob_mesh anchors the
	# knob wherever it finds it AT THE CURRENT VALUE, so a cap left mid-slot would put
	# both detents half a throw out.
	_ch_knob = MeshInstance3D.new()
	_ch_knob.name = "ChannelKnob"
	var knob_mesh := BoxMesh.new()
	knob_mesh.size = Vector3(0.0052, 0.0042, 0.0018)
	_ch_knob.mesh = knob_mesh
	_ch_knob.material_override = cap_mat
	add_child(_ch_knob)
	_ch_knob.position = CH_SW_POS + Vector3(CH_THROW * 0.5, 0.0, 0.0)

	var slider := VRSlider.new()
	slider.name = "ChannelSwitch"
	# -X, not +X: the shell prints "CH3-CH4" reading along device -X, so CH3 is the
	# +X end. Value 0 is the low end of the axis, and value 0 has to be CH3.
	slider.axis_local = Vector3(-1.0, 0.0, 0.0)
	slider.travel = CH_THROW
	slider.steps = 2
	slider.value = 0.0
	slider.collision_layer = 1 | (1 << 20)
	slider.engage_radius = 0.020
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(CH_THROW + 0.008, 0.009, 0.008)
	col.shape = box
	slider.add_child(col)
	add_child(slider)                     # _ready runs here, before adopting
	slider.position = CH_SW_POS
	# The panel this switch sits in is recessed inside the deck's back face, so a
	# ray aimed at the switch reaches the shell first. Grow the touch box back
	# through the recess until it stands proud of that face. The knob is untouched
	# — it rides set_knob_mesh, not this shape.
	var back: float = DECK_POS.z - DECK_BOX.z * 0.5 - SWITCH_PROUD
	var grow: float = (CH_SW_POS.z - box.size.z * 0.5) - back
	if grow > 0.0:
		box.size.z += grow
		col.position.z -= grow * 0.5
	slider.set_knob_mesh(_ch_knob)
	slider.value_changed.connect(_on_channel_slider_changed)
	_ch_slider = slider


func _on_channel_slider_changed(value: float) -> void:
	var next: int = 3 if value < 0.5 else 4
	if next == _rf_channel:
		return
	_rf_channel = next
	_play_sfx(_sfx_channel, "channel")
	print("[NES] RF channel switch -> CH%d" % _rf_channel)
	# The set has to re-read it: on the aerial input the picture only appears when
	# its own tuning matches, and nothing else would tell it this moved.
	var host := get_parent()
	if host != null and host.has_method("on_rf_channel_changed"):
		host.call("on_rf_channel_changed")


## Which channel this console's RF switch puts it on. -1 from the base class means
## "no such switch", which is every other machine in the room.
func get_rf_channel() -> int:
	return _rf_channel


## The NES's AV jacks sit on the RIGHT (+X) flank — this shell moulds them there
## (JackRed / JackYellow at x = 0.12) — so the video cable trails out +X rather
## than straight back like a rear-panel console.
func configure_cable_attach(attach_point: Node3D) -> void:
	if _glb != null:
		attach_point.global_position = _mesh_center("JackYellow")
	# VerletRope leaves the attach point stiffly along its local -Z, so rotate
	# -90° about Y (local -Z -> device +X) to steer the cable out of the flank.
	# That also aims PortVisual's +Z connector into the jack, since the plug mesh
	# is authored connector-on-+Z. Same rule as RetroSystemModel.aim_cable_exit,
	# stated as the one turn it needs.
	attach_point.rotation = Vector3(0.0, -PI / 2.0, 0.0)
	# PortVisual stays VISIBLE. It used to be hidden because it was a grey
	# cylinder stub that looked wrong against the shell's moulded jacks; now that
	# it is the same yellow RCA plug the TV end wears, it is the connector seated
	# in JackYellow, and hiding it left the cord emerging from nothing.


# --- cartridge (front-load: slides straight back into the ZIF socket) -----------

func configure_cartridge_slot(slot: Node3D) -> void:
	_cartridge_slot = slot
	if _glb != null:
		var cradle := _glb.find_child("NesCradle", true, false) as MeshInstance3D
		if cradle:
			# Remember where the shell put it, so a rebuild starts from the asset
			# rather than from the last layout — the drop below is relative.
			if _cradle_home_parent == null:
				_cradle_home_parent = cradle.get_parent()
				_cradle_home_xform = cradle.transform
			# Sink the whole bay so it can hinge — see CRADLE_DROP. Done before the
			# seat is read off it, so the cart follows the tray down rather than
			# floating where the tray used to be.
			cradle.global_position -= global_transform.basis.y.normalized() * CRADLE_DROP
			# Lay the cart FLAT, label up, connector pointing into the machine. A
			# cartridge is authored connector -Y / label +Z, so map its +Y (grip)
			# onto +Z (out the front) and its +Z (label) onto up; X inverts to keep
			# it a rotation. Without this the cart stands on end in the bay.
			#
			# Composed onto the SHELL's basis, not written as a world one: a bare
			# Basis here is an absolute orientation, so the cart faced the same
			# compass direction whichever way the console was turned.
			var b: Basis = _glb.global_transform.basis.orthonormalized()
			slot.global_transform = Transform3D(
				b * Basis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)),
				_cart_seat_point(cradle))
		var seat := find_child("CartSeat", true, false) as Node3D
		if seat != null:
			slot.global_transform = seat.global_transform
		_setup_cart_tray(slot)
		# Settle the slot onto the tray's rest angle first: building the hinge swings
		# the pivot at once, but the slot only follows in _process, and a perch
		# measured against the un-tilted seat lands short of where it was aimed.
		_sync_cart_tray()
		_set_cart_perch(slot)
	var slot_visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if slot_visual:
		slot_visual.hide()
	# Bay is sealed by the flap: only accept a cartridge while the flap is open.
	slot.enabled = _lid_open


## Where a seated cart sits, in world space: the tray's own centre, raised by
## CART_LIFT so the cradle has room to sink under it (see CRADLE_DROP). The cradle
## has already been dropped by the time this is read, so the seat inherits that.
func _cart_seat_point(cradle: MeshInstance3D) -> Vector3:
	var to_model := global_transform.affine_inverse()
	var centre: Vector3 = to_model * (cradle.global_transform * cradle.get_aabb().get_center())
	return global_transform * Vector3(
		centre.x, centre.y + CART_LIFT, centre.z + CART_SEAT_DEPTH)


## Stand the held cart's ghost proud of the mouth, so the release has somewhere to
## slide FROM. Measured rather than written down: this bay seats a cart well inside
## the shell's own front face, so a stand-off quoted from the seat would leave the
## ghost buried in the machine and the slide invisible.
func _set_cart_perch(slot: Node3D) -> void:
	var deck := _glb.find_child("NesDeck", true, false) as MeshInstance3D
	if deck == null:
		return
	var to_model := global_transform.affine_inverse()
	var front: float = ((to_model * deck.global_transform) * deck.get_aabb()).end.z
	var seat_z: float = (to_model * slot.global_transform).origin.z
	var half: float = MediaDimensions.cart_size("nes").y * 0.5
	# Along the TRAY's axis, which is what the offset actually travels: the mouth
	# points up while the tray is sprung, so a distance quoted in the console's own
	# depth falls short of the face by the cosine of that angle.
	var axis: Vector3 = (to_model.basis * get_cartridge_insert_direction()).normalized()
	var face: float = seat_z + half * axis.z
	var proud: float = maxf((front + CART_PROUD - face) / maxf(axis.z, 0.001), 0.0)
	# Along the mouth, not along the console: a cart leaves the way its slot points.
	# Zone-LOCAL, so it rides the tray's angle without knowing the tray can move.
	var out_zone: Vector3 = (slot.global_transform.basis.inverse()
		* get_cartridge_insert_direction()).normalized()
	slot.preview_offset = out_zone * proud


## Lay the bay out again from the current numbers. For the tuning probe — nothing
## in the room calls this, and it costs a rebuild of the tray rig.
func retune() -> void:
	if _cartridge_slot == null:
		return
	var cradle := _cradle_mesh()
	if cradle != null and _cradle_home_parent != null:
		cradle.reparent(_cradle_home_parent, false)
		cradle.transform = _cradle_home_xform
	if _tray_pivot != null:
		_tray_pivot.queue_free()
		_tray_pivot = null
		_tray_hinge = null
	_tray_applied_deg = INF
	_tray_down = false
	configure_cartridge_slot(_cartridge_slot)


## The cradle mesh, wherever it currently hangs: it starts under the GLB and is
## reparented onto the tray pivot once that exists.
func _cradle_mesh() -> MeshInstance3D:
	if is_instance_valid(_tray_pivot):
		var moved := _tray_pivot.find_child("NesCradle", true, false) as MeshInstance3D
		if moved != null:
			return moved
	if _glb == null:
		return null
	return _glb.find_child("NesCradle", true, false) as MeshInstance3D


## The hinged frame the cartridge slot and the cradle mesh both ride.
func _setup_cart_tray(slot: Node3D) -> void:
	var cradle := _cradle_mesh()
	if cradle == null:
		return
	var authored_col := cradle.find_child("CradleActivationBox", true, false) as CollisionShape3D
	var to_model := global_transform.affine_inverse()
	var ab: AABB = ((to_model * cradle.global_transform) * cradle.get_aabb())
	_tray_pivot = Node3D.new()
	_tray_pivot.name = "CartTrayPivot"
	add_child(_tray_pivot)
	# Hinged at the cradle's back-bottom edge, and yawed 180 so a POSITIVE angle
	# lifts the FRONT — the sense VRSpringLatchedHinge is written to, where min_deg
	# is the latched limit and max_deg the sprung one.
	_tray_pivot.transform = Transform3D(Basis(Vector3.UP, PI),
		Vector3(ab.get_center().x, ab.position.y, ab.position.z))
	_seat_in_tray = _tray_pivot.global_transform.affine_inverse() * slot.global_transform
	# The cradle rides the hinge, so the tray the player sees is the tray that moves.
	# It goes on BEFORE the hinge exists, and that order is the whole of it: adding
	# the hinge runs its _ready, which swings the pivot to max_deg on the spot, and a
	# cradle reparented after that keeps its flat WORLD pose under an already-turned
	# parent — which leaves it flat when the tray is up and dipping when it is home,
	# the exact inverse of the cart it carries. Captured here it is flat at rest, on
	# the same terms as _seat_in_tray above.
	cradle.reparent(_tray_pivot, true)
	_tray_hinge = VRSpringLatchedHinge.new()
	_tray_hinge.name = "CartTrayHinge"
	_tray_hinge.target = _tray_pivot
	_tray_hinge.min_deg = 0.0
	_tray_hinge.max_deg = TRAY_UP_DEG
	_tray_hinge.close_latch_deg = TRAY_LATCH_DEG
	_tray_hinge.spring_speed_deg = TRAY_SPRING_DEG
	# An empty bay rests UP, where the springs hold it — not shut like a disc lid.
	_tray_hinge.start_closed = false
	_tray_hinge.box_engages = true
	# The NES push-push carriage is worked only from its top face: first press
	# drives it home and latches, the next adds overtravel and releases the latch.
	_tray_hinge.poke_close_faces = VRHinge.FACE_Y_POS
	_tray_hinge.state_log_name = "cradle"
	_tray_pivot.add_child(_tray_hinge)
	if authored_col != null and authored_col.shape is BoxShape3D:
		# It was authored under NesCradle, so at this point it has already inherited
		# the sink and sprung-up tray pose. Make that exact pose the live Area origin.
		var preview_area := authored_col.get_parent() as Area3D
		_tray_hinge.global_transform = authored_col.global_transform
		authored_col.reparent(_tray_hinge, true)
		authored_col.transform = Transform3D.IDENTITY
		if preview_area != null:
			preview_area.queue_free()
	else:
		var cart: Vector3 = MediaDimensions.cart_size("nes")
		_tray_hinge.position = _seat_in_tray.origin + Vector3(0, cart.z * 0.5 + 0.004, 0)
		authored_col = CollisionShape3D.new()
		authored_col.name = "CradleActivationBox"
		var fallback_box := BoxShape3D.new()
		fallback_box.size = Vector3(cart.x * 0.9, 0.008, cart.y * 0.6)
		authored_col.shape = fallback_box
		_tray_hinge.add_child(authored_col)
	_tray_hinge.push_push = true       # a hand may take hold of it to let it up
	_tray_hinge.rotation_changed.connect(_on_tray_moved)


## Carry the slot with the tray. Driven from the pivot's angle rather than from the
## hinge's signal because the spring return is deliberately silent — it reports no
## rotation at all, and a cart that only followed the reported moves would stay
## behind when the tray sprang back up under a released push.
func _sync_cart_tray() -> void:
	if _tray_pivot == null or _cartridge_slot == null:
		return
	var deg := rad_to_deg(_tray_pivot.rotation.x)
	if is_equal_approx(deg, _tray_applied_deg):
		return
	_tray_applied_deg = deg
	_cartridge_slot.global_transform = _tray_pivot.global_transform * _seat_in_tray


func _on_tray_moved(_deg: float) -> void:
	_sync_cart_tray()
	if _tray_hinge != null:
		_set_tray_down(_tray_hinge.is_latched_closed())


## Push the cart home. Only now is the machine wired to it.
##
## The latch is thrown FIRST and the travel drawn afterwards: an unlatched hinge is
## sprung, so a tray tweened down before latching would be hauled back up by
## VRSpringLatchedHinge's own idle spring on the very next frame.
func push_tray_down() -> void:
	if _tray_hinge == null or _tray_hinge.is_latched_closed():
		return
	var from := _tray_pivot.rotation.x
	_tray_hinge.latch_closed()
	_set_tray_down(true)
	if not _hand_did_it():
		return
	_tray_pivot.rotation.x = from
	if _tray_tween != null and _tray_tween.is_valid():
		_tray_tween.kill()
	_tray_tween = create_tween()
	_tray_tween.tween_property(_tray_pivot, "rotation:x", 0.0, TRAY_PUSH_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## Let the springs take it back up. The cart stays in the tray; the machine loses it.
## No tween here — unlatching is all it takes, and the hinge's own spring carries it
## at TRAY_SPRING_DEG.
func lift_tray() -> void:
	if _tray_hinge == null or not _tray_hinge.is_latched_closed():
		return
	if _tray_tween != null and _tray_tween.is_valid():
		_tray_tween.kill()
	_tray_hinge.open()
	_set_tray_down(false)
	if not _hand_did_it():
		_tray_pivot.rotation.x = deg_to_rad(TRAY_UP_DEG)


func is_tray_down() -> bool:
	return _tray_down


func has_push_tray() -> bool:
	return true


func _set_tray_down(down: bool) -> void:
	if down == _tray_down:
		return
	_tray_down = down
	print("[NES state] cradle: %s" % ("LOCKED_DOWN" if down else "RELEASED_UP"))
	if _hand_did_it():
		_play_sfx(_sfx_tray_down if down else _sfx_tray_up, "tray")
	cart_tray_changed.emit(down)


## Read off the TRAY, which tilts: a cart goes in along the cradle's mouth, not
## along the console's level front, and the two differ by TRAY_UP_DEG for as long as
## the tray is up — which is every moment a cart is being handled.
func get_cartridge_insert_direction() -> Vector3:
	if _tray_pivot != null:
		return (-_tray_pivot.global_transform.basis.z).normalized()
	return global_transform.basis.z.normalized()


func play_cartridge_insert(cartridge: Node3D, slot: Node3D) -> void:
	# A restore is a state, not a motion: the cart is already at the seat and no hand
	# put it there.
	if not _hand_did_it():
		return
	_play_sfx(_sfx_cart_insert, "cart_insert")
	# Make sure the flap is up, then slide the cart home from where its ghost was
	# standing. XRTools has already snapped/frozen it at the seat, and the start is
	# read back off the zone rather than written down, so the ghost and the slide
	# cannot drift apart when the perch or the tray's angle is retuned.
	play_open()
	var zone := slot as XRToolsSnapZone
	if zone == null:
		return
	# The seat, asked of the zone — NOT the cart's transform, which at this moment is
	# still wherever it was released: the socket only pulls it home on the next
	# physics tick, so a tween aimed there lands short and is then dragged the rest
	# of the way by the grab driver.
	var seated := zone.snap_pose_for(cartridge)
	# It is already frozen by the snap zone. The insertion is authored motion,
	# not a free rigid body: unfreezing would reactivate the drop's retained
	# gravity velocity and expose a one-frame world -Y excursion.
	cartridge.global_transform = zone.preview_pose_for(cartridge)
	var tween := cartridge.create_tween()
	tween.tween_property(cartridge, "global_transform", seated, 0.25) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func play_cartridge_eject(_cartridge: Node3D, _slot: Node3D) -> void:
	if _hand_did_it():
		_play_sfx(_sfx_cart_remove, "cart_remove")
	# Cart is already in hand; make sure the flap is up so the pull reads right.
	play_open()


func on_power_on() -> void:
	if _power_button:
		_power_button.set_latched_pressed(true)
	# Track the switch position but make no sound: this also runs when code powers
	# the machine, and nothing has physically moved. _on_power_button_pressed is
	# what a finger sounds like.
	_power_in = true
	set_power_light(true)


func on_power_off() -> void:
	if _power_button:
		_power_button.set_latched_pressed(false)
	_power_in = false
	set_power_light(false)


# --- collision ------------------------------------------------------------------

## Deck envelope, measured off this asset (0.256 x 0.093 x 0.204) and rounded out.
## Without it the console keeps system.tscn's generic box, centred on the model
## origin, so half hangs below the shell and every table contact holds it in the air.
const DECK_BOX := Vector3(0.26, 0.094, 0.208)
const DECK_POS := Vector3(0.0, 0.047, 0.0)
## Slack around the bay mouth, and the extra the flap carries so it still seals
## the mouth from inside.
const MOUTH_MARGIN := 0.001
const PLUG_MARGIN := 0.003
## The flap is an L: a top plate 2.1 mm thick running the bay's full 42 mm depth,
## and a front plate 5.2 mm thick standing its full 34 mm height, with the inside
## corner empty. Padded to something a solver can stop against. One box round the
## pair would fill that corner, which is bay interior — harmless shut, and a
## 48 mm-deep slab standing over the machine once the flap is up.
const FLAP_TOP_PLATE := 0.008
const FLAP_FRONT_PLATE := 0.010
## How far a recessed control's touch box stands out of the face it sits under,
## so a ray meets the control rather than the shell.
const SWITCH_PROUD := 0.002
## Bodies the deck is built on: the console's own, and its pointer body.
const COLLISION_PATHS := ["CollisionShape3D", "PointerArea/CollisionShape3D"]

# The flap's plates, on each of those bodies, re-posed by _set_lid. Centres are
# in the flap mesh's own space and run parallel to the shapes.
var _flap_shapes: Array[CollisionShape3D] = []
var _flap_centres: Array[Vector3] = []
var _glb_to_host: Transform3D = Transform3D.IDENTITY


## Rest the console on the surface it is placed on, and leave the cartridge bay
## open to the front.
##
## Four boxes around a fifth that is left empty. A seated cart lies entirely
## inside the deck envelope — front edge 21 mm behind the deck face, top face
## 10 mm below it — so one box for the whole deck puts shell in front of the cart
## from every angle, and no depth threshold tells the deck top (11 mm of box) from
## the bay mouth (26 mm), because the legitimate path is the deeper one. Carved,
## there is nothing in front of the cart to ask the question about.
##
## The mouth is shut by the flap's own box, which _set_lid carries with the flap.
func configure_collision(host: Node3D) -> void:
	var env := AABB(DECK_POS - DECK_BOX * 0.5, DECK_BOX)
	var mouth := _bay_mouth(host, env)
	var open_bay := mouth.size.x > 0.0 and mouth.size.y > 0.0 and mouth.size.z > 0.0
	for path in COLLISION_PATHS:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col == null or not (col.shape is BoxShape3D):
			continue
		if open_bay:
			_carve_bay(col, env, mouth)
		else:
			_box(col, env)
	if open_bay:
		_build_flap_plug(host)


## The front opening, in the host's frame: the flap's own footprint carried out
## to the deck's top and front faces.
func _bay_mouth(host: Node3D, env: AABB) -> AABB:
	if _lid_mesh == null:
		return AABB()
	var fp := _lid_mesh.get_parent() as Node3D
	if fp == null:
		return AABB()
	_glb_to_host = host.global_transform.affine_inverse() * fp.global_transform
	var m: AABB = (_glb_to_host * _lid_rest) * _lid_mesh.get_aabb()
	m = m.grow(MOUTH_MARGIN)
	var hi := Vector3(m.end.x, env.end.y, env.end.z)
	return AABB(m.position, hi - m.position).intersection(env)


## Reuse `col` for the slab under the mouth and give its body three siblings for
## the volume behind it and to either side.
func _carve_bay(col: CollisionShape3D, env: AABB, mouth: AABB) -> void:
	var up_y := mouth.position.y
	var up_h := env.end.y - up_y
	var front_z := mouth.position.z
	var front_d := env.end.z - front_z
	_box(col, AABB(env.position, Vector3(env.size.x, up_y - env.position.y, env.size.z)))
	var walls := [
		["ShellRear", AABB(Vector3(env.position.x, up_y, env.position.z),
			Vector3(env.size.x, up_h, front_z - env.position.z))],
		["ShellLeft", AABB(Vector3(env.position.x, up_y, front_z),
			Vector3(mouth.position.x - env.position.x, up_h, front_d))],
		["ShellRight", AABB(Vector3(mouth.end.x, up_y, front_z),
			Vector3(env.end.x - mouth.end.x, up_h, front_d))],
	]
	var parent := col.get_parent()
	for wall in walls:
		var part_name: String = wall[0]
		var a: AABB = wall[1]
		if a.size.x <= 0.0 or a.size.y <= 0.0 or a.size.z <= 0.0:
			continue
		var extra := parent.get_node_or_null(NodePath(part_name)) as CollisionShape3D
		if extra == null:
			extra = CollisionShape3D.new()
			extra.name = part_name
			parent.add_child(extra)
		_box(extra, a)


## The flap's box, one shape on each of the console's own bodies rather than a
## body of its own parented to the flap mesh. XRTools mutes a held object through
## its body's collision_layer and collision_mask, which reaches every shape on
## that body and nothing on a separate one, so a flap body would keep its Pickable
## layer and sweep a solid box through the room whenever the console was carried.
func _build_flap_plug(host: Node3D) -> void:
	if _lid_mesh == null:
		return
	var a := _lid_mesh.get_aabb()
	var m := PLUG_MARGIN
	# Each plate keeps the flap's own outer face and takes its thickness inward,
	# so the pair reads as the door rather than as a block the size of the door's
	# travel. They meet in the corner, which is solid on the real shell.
	var plates := {
		"BayFlapTop": AABB(
			Vector3(a.position.x - m, a.end.y - FLAP_TOP_PLATE, a.position.z - m),
			Vector3(a.size.x + m * 2.0, FLAP_TOP_PLATE + m, a.size.z + m * 2.0)),
		"BayFlapFront": AABB(
			Vector3(a.position.x - m, a.position.y - m, a.end.z - FLAP_FRONT_PLATE),
			Vector3(a.size.x + m * 2.0, a.size.y + m * 2.0, FLAP_FRONT_PLATE + m)),
	}
	_flap_shapes.clear()
	_flap_centres.clear()
	for path in COLLISION_PATHS:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col == null:
			continue
		var parent := col.get_parent()
		for plate_name in plates:
			var box: AABB = plates[plate_name]
			var plug := parent.get_node_or_null(NodePath(plate_name)) as CollisionShape3D
			if plug == null:
				plug = CollisionShape3D.new()
				plug.name = plate_name
				parent.add_child(plug)
			var shape := BoxShape3D.new()
			shape.size = box.size
			plug.shape = shape
			_flap_shapes.append(plug)
			_flap_centres.append(box.get_center())
	_sync_flap_plug()


## Carry the flap's plates with the flap. Both bodies they live on sit at the
## host's own origin, so the flap mesh's pose in host space is their transform.
func _sync_flap_plug() -> void:
	if _lid_mesh == null or _flap_shapes.is_empty():
		return
	var pose: Transform3D = _glb_to_host * _lid_mesh.transform
	for i in range(_flap_shapes.size()):
		var cs := _flap_shapes[i]
		if is_instance_valid(cs):
			cs.transform = pose * Transform3D(Basis.IDENTITY, _flap_centres[i])


## A fresh BoxShape3D spanning `a`. Never the scene's own shape resource: one
## BoxShape3D sub-resource is shared by every cabinet in the room.
func _box(col: CollisionShape3D, a: AABB) -> void:
	var shape := BoxShape3D.new()
	shape.size = a.size
	col.shape = shape
	col.position = a.get_center()

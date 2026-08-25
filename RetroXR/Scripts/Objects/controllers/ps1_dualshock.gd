## Ps1DualShock — the later PlayStation pad (SCPH-1200), the one with the sticks.
##
## Everything moves: the four face buttons, both shoulder pairs, SELECT, START,
## ANALOG, a rocking D-pad and both sticks.
##
## That took mesh surgery. This shell comes out of the console scene, which ships
## its four face buttons, both shoulder pairs and SELECT/START as ONE object —
## the reason Tools/glb/prepare_ps1_pad.py went and found a different download
## for the SCPH-1080, and the reason this pad could originally animate nothing
## but its D-pad. They are not one SURFACE though: welded, that object falls into
## eight loose islands, the D-pad into its four arms and each stick into two, so
## split_playstation.separate_dualshock_controls names them from measured
## position and joins back the ones that have to move as a piece.
##
## Bindings match Ps1Controller's, since it is the same hardware map: cross is
## the primary button (B) because a PS1 core reads fire off B.
class_name Ps1DualShock
extends AnimatedController

# --- the ANALOG lamp --------------------------------------------------------

## The shell already emits: the LED's material carries emissiveFactor (1, 0, 0)
## over a dark red lens, so it GLOWS. It lit nothing, which is the same gap the
## console's power lamp had -- a glowing lens is not a lamp.
##
## nes_model's method, deliberately NOT re-derived, exactly as playstation_model
## reuses it: brightness is set from the PEAK the light lays on the shell behind
## the lens, and energy solved back out as peak * LED_STANDOFF^2.
##
## Dimmer than either console's, at peak 2.0 against their 3.0: this is a lamp on
## a pad held in the hand and read from 300 mm, not a panel indicator across a
## room, and the lens is 4.5 x 1.8 mm against the console's.
##
## The ENERGY is a sixth of theirs rather than two-thirds, and comparing energies
## across the three is meaningless: this standoff is 3 mm against their 6, and
## d^(-2) squares that difference. Compare peaks.
const LED_STANDOFF := 0.003
const LED_ENERGY := 0.000018
const LED_DECAY := 2.0
const LED_RANGE := 0.25
## Red, from the ASSET: the material's emissive is (1, 0, 0) over a (0.133, 0, 0)
## lens, which is a red LED that happens to be off.
const LED_COLOR := Color(1.0, 0.12, 0.06)

## The mesh, by the suffix the exporter leaves on it. Not renamed in
## split_playstation like the controls are, because nothing has to FIND it by a
## meaningful name -- it never moves.
const LED_MESH_SUFFIX := "_Controller_LED_0"

var _led_mesh: MeshInstance3D = null
var _led_mats: Array[StandardMaterial3D] = []
var _led_glow: OmniLight3D = null

# --- analogue mode ----------------------------------------------------------

## What the ANALOG switch actually switches, and why it is one flag rather than
## three settings kept in step.
##
## On the hardware this button is a MODE, not an input: in analogue mode the
## sticks are read, the lamp is lit and the console sees a DualShock; in digital
## mode the sticks report nothing, the lamp is dark and the console sees a plain
## pad. So the same toggle drives the light, the axes and pad_type_pref, and the
## user's two suggestions -- "disable the sticks" and "toggle to a standard
## controller" -- are the same switch seen from either end.
##
## Starts ON: a DualShock powers up in analogue mode, and this scene declares
## pad_type_pref "dualshock" for the port it is plugged into.
var _analog_mode: bool = true

@onready var _analog_button: VRButton = $AnalogButton

## Measured by ray against the shell beside each cap, not taken from the recess
## depth: the caps stand 1.04 to 1.39 mm proud on both pads, NOT the ~2.6 mm this
## file used to claim. A 1.4 mm throw therefore pushed CIRCLE and TRIANGLE below
## the surface and they vanished at full press. 0.8 mm is a clear press that
## leaves a quarter of a millimetre still standing on the shallowest cap.
const PRESS_FACE: float = 0.0008
## SELECT and START are flush membrane buttons that barely travel, and on the
## DualShock they sit in a recess LOWER than the shell around them, so this is
## half what the face caps get rather than merely less.
const PRESS_SMALL: float = 0.0004
## Shoulders hinge more than they sink, but a short straight push reads correctly
## at the scale they are seen from.
const PRESS_SHOULDER: float = 0.0012

## The rocker sits on the shell surface, below the cross's own centre, and
## _find_pivot's AABB fallback would rock it about its middle. Ps1Controller's
## figure — same moulding.
const DPAD_PIVOT_DROP: float = 0.0025

## A stick pivots at its base, not at the middle of its own box. The cap sits
## 8.6 mm tall on the shell, so dropping the pivot by half that puts it where the
## shaft enters the dish, and the cap swings rather than skating sideways.
const STICK_PIVOT_DROP: float = 0.0043

const FACE: Dictionary = {
	"BtnCross":    ControllerBindings.JOYPAD_B,
	"BtnCircle":   ControllerBindings.JOYPAD_A,
	"BtnSquare":   ControllerBindings.JOYPAD_Y,
	"BtnTriangle": ControllerBindings.JOYPAD_X,
}
const SMALL: Dictionary = {
	"BtnSelect": ControllerBindings.JOYPAD_SELECT,
	"BtnStart":  ControllerBindings.JOYPAD_START,
}
## Which way a shoulder travels, in the pad's own frame.
##
## NOT the -Y every other control uses. The shoulders are on the pad's REAR
## VERTICAL FACE, stacked 1 over 2, so pressing them down slides them ALONG that
## face instead of into it -- which is what a straight-down press looked like
## from behind. A finger curls over the top edge and pushes FORWARD, into the
## body, which is +Z here: the cord leaves the far edge on -Z, so the front of
## the pad is +Z.
const SHOULDER_DIR := Vector3(0.0, 0.0, 1.0)


const SHOULDERS: Dictionary = {
	"BtnL1": ControllerBindings.JOYPAD_L,
	"BtnR1": ControllerBindings.JOYPAD_R,
	"BtnL2": ControllerBindings.JOYPAD_L2,
	"BtnR2": ControllerBindings.JOYPAD_R2,
}


## Lit while the pad is plugged into a machine. That is the honest condition for
## this lamp rather than a toggle on the ANALOG button: the DualShock's red light
## means the pad is IN analogue mode, and this pad declares pad_type_pref
## "dualshock", so it is always in that mode when a console is driving it.
func _set_analog_lamp(on: bool) -> void:
	for m in _led_mats:
		m.emission_energy_multiplier = 2.5 if on else 0.0
	if _led_glow != null:
		# Hidden rather than dimmed to zero: an energy-0 light is still a light
		# the renderer culls and binds per object.
		_led_glow.visible = on


func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	super(system, port_index)
	_set_analog_lamp(_analog_mode)


func on_unplugged() -> void:
	super()
	_set_analog_lamp(false)


## Give the lens its own emissive material so the lamp can be turned OFF, and
## hang a real OmniLight3D just off it so a live pad lays a red wash on its own
## face and on whatever it is lying on.
##
## OMNI rather than a forward spot, for the reason nes_model records: a cone aimed
## out of the face cannot light that face, because the two are coplanar, and the
## ring of glow around the lens is the recognisable part. Shadows off and in the
## "no_shadow" group QualityManager honours -- the source sits millimetres from
## what it lights, where a shadow map buys acne and an atlas slot per pad.
func _build_analog_lamp() -> void:
	if _led_mesh != null:
		return
	for n in find_children("*", "MeshInstance3D", true, false):
		if String(n.name).ends_with(LED_MESH_SUFFIX):
			_led_mesh = n as MeshInstance3D
			break
	if _led_mesh == null or _led_mesh.mesh == null:
		return
	_led_mats.clear()
	for i in _led_mesh.mesh.get_surface_count():
		var src := _led_mesh.get_active_material(i) as BaseMaterial3D
		var m := StandardMaterial3D.new()
		if src != null:
			m.albedo_color = src.albedo_color
		m.emission_enabled = true
		m.emission = LED_COLOR
		m.emission_energy_multiplier = 0.0
		_led_mesh.set_surface_override_material(i, m)
		_led_mats.append(m)
	# Forward+ only — see RetroSystemModel.lamp_glow_supported. On the mobile
	# backend this light does not render as a light at all, and the lens above
	# carries the lamp there on its own.
	if not RetroSystemModel.lamp_glow_supported():
		return
	_led_glow = OmniLight3D.new()
	_led_glow.name = "AnalogLampGlow"
	_led_glow.add_to_group("no_shadow")
	_led_glow.light_color = LED_COLOR
	_led_glow.light_energy = LED_ENERGY
	_led_glow.omni_range = LED_RANGE
	_led_glow.omni_attenuation = LED_DECAY
	# A point source millimetres from glossy ABS throws a specular highlight the
	# real lens cannot — here a bright arc on both stick rims. Its reflection comes
	# from the emissive mesh instead.
	_led_glow.light_specular = 0.0
	_led_glow.shadow_enabled = false
	_led_glow.distance_fade_enabled = true
	_led_glow.distance_fade_begin = 2.0
	_led_glow.distance_fade_length = 1.0
	_led_glow.visible = false
	add_child(_led_glow)
	# Measured off the lens rather than written down: the scene drops the model on
	# its own offset, so the GLB's coordinates are not this node's.
	var lens: Vector3 = to_local(_led_mesh.global_transform * _led_mesh.get_aabb().get_center())
	_led_glow.position = lens + Vector3(0.0, LED_STANDOFF, 0.0)


## Sit the switch on its own cap and let VRButton drive the depress, the way
## RetroSystemModelPlayStation.configure_buttons does for POWER and OPEN. The cap
## is no longer in _buttons: a control cannot be driven by a RetroPad bit and a
## finger at once, and ANALOG has no bit -- it was only ever given L3 so the cap
## had something to travel on.
func _build_analog_switch() -> void:
	var cap := _find_mesh("BtnAnalog")
	if cap == null or _analog_button == null:
		return
	_analog_button.depress_depth = PRESS_SMALL
	_analog_button.set_button_mesh(cap)
	_analog_button.global_position = cap.global_transform * cap.get_aabb().get_center()
	_analog_button.set_depress_axis_world(-global_transform.basis.y.normalized())
	if not _analog_button.button_pressed.is_connected(_on_analog_pressed):
		_analog_button.button_pressed.connect(_on_analog_pressed)
	_analog_button.set_latched_pressed(not _analog_mode)


func _on_analog_pressed() -> void:
	set_analog_mode(not _analog_mode)


## The one place the mode changes. Latched IN means digital, which is what the
## switch looks like on the hardware once you have pushed it out of analogue.
func set_analog_mode(on: bool) -> void:
	_analog_mode = on
	_set_analog_lamp(on and _connected_system != null)
	pad_type_pref = "dualshock" if on else "standard"
	if _analog_button != null:
		_analog_button.set_latched_pressed(not on)
	print("[Ps1DualShock] analogue mode %s -> pad type '%s'"
		% ["ON" if on else "OFF", pad_type_pref])
	# Follow the pad into the running core without needing the cable pulled.
	if _connected_system != null and _connected_system.has_method("reapply_pad_types"):
		_connected_system.reapply_pad_types()


## Digital mode reports centred sticks. Cut here, at the single funnel to the
## core, so the axes the console sees and the axes the sticks are ANIMATED from
## go dead together -- a stick that still leans while the core reads nothing
## would be the pad telling the player two different things.
func _send_joypad(btn: int, alx: int, aly: int, arx: int, ary: int) -> void:
	if not _analog_mode:
		alx = 0
		aly = 0
		arx = 0
		ary = 0
	super(btn, alx, aly, arx, ary)


func _cache_meshes() -> void:
	_build_analog_lamp()
	_build_analog_switch.call_deferred()
	_buttons.clear()
	for stem: String in FACE:
		_add(stem, int(FACE[stem]), PRESS_FACE)
	for stem: String in SMALL:
		_add(stem, int(SMALL[stem]), PRESS_SMALL)
	for stem: String in SHOULDERS:
		_add(stem, int(SHOULDERS[stem]), PRESS_SHOULDER, SHOULDER_DIR)
	_dpad = _rocker("DPad", DPAD_PIVOT_DROP)
	_stick_l = _rocker("StickL", STICK_PIVOT_DROP)
	_stick_r = _rocker("StickR", STICK_PIVOT_DROP)


## Face-up shell with the D-pad on -X puts its UP arm on -Z, so the default pitch
## would lift UP instead of pressing it. Same as Ps1Controller and the NES pad.
func _dpad_pitch_sign() -> float:
	return -1.0


func _add(stem: String, bit: int, depth: float, dir: Vector3 = Vector3.ZERO) -> void:
	var m := _find_mesh(stem)
	if m == null:
		push_warning("Ps1DualShock: control mesh not found: " + stem)
		return
	var e := {"node": m, "rest": m.transform, "bit": bit, "depth": depth}
	# Omitted rather than passed as the default: ControlAnimator falls back to its
	# own press_dir when an entry carries no "dir", and writing a zero vector here
	# would pin the control in place instead.
	if dir != Vector3.ZERO:
		e["dir"] = dir
	_buttons.append(e)


func _rocker(stem: String, drop: float) -> Dictionary:
	var m := _find_mesh(stem)
	if m == null:
		push_warning("Ps1DualShock: control mesh not found: " + stem)
		return {}
	var pivot: Vector3 = _find_pivot(m, stem + "Pivot")
	pivot.y -= drop
	return {"node": m, "rest": m.transform, "pivot": pivot}

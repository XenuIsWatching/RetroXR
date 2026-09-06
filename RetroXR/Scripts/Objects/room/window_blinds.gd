## Vinyl mini blinds that raise and lower on a pull cord.
##
## Slats are one MultiMesh — 48 of them in a single draw call, with no per-frame
## mesh rebuild; only instance transforms move. Draw calls are the binding
## constraint on Quest, so a slat-per-MeshInstance would have been 48 of them for
## a window dressing.
##
## `drop` is 0 (fully raised) to 1 (fully lowered) and everything derives from it.
## Real blinds do not slide as a rigid unit: the slats STACK at the headrail as
## they rise, so the pitch between them collapses rather than the whole assembly
## translating. That is why raising bunches them at the top instead of sliding
## them out of view.
##
## Pulling is BeadPullCord's, not a second interaction. The cord signals `pulled`
## and this steps `drop`; leaving the cord's light_path empty stops it toggling a
## lamp as well.
class_name WindowBlinds
extends Node3D

const SLAT_SHADER: Shader = preload("res://Shaders/blind_slat.gdshader")


signal drop_changed(drop: float)


## Window opening the blinds cover, in this node's local space.
@export var width: float = 1.44
@export var height: float = 1.18

@export var slat_count: int = 48
@export var slat_thickness: float = 0.0022
@export var slat_height: float = 0.019

## Pitch when fully raised. Not zero — stacked vinyl slats still occupy their own
## thickness, and collapsing them to a plane makes the headrail look empty.
@export var stack_pitch: float = 0.0055

@export var slat_color: Color = Color(0.87, 0.85, 0.79)

## Peak bow of a hanging slat's middle, in metres. 6 mm is a draught through a
## closed window, not a gale — at more than about 12 mm the slats visibly pass
## through each other, because the gap between them is only a few millimetres
## wider than the slat is thick.
@export var sway_amplitude: float = 0.006
@export var sway_speed: float = 1.1

## Lower bound on the window sun while the blind is down, used ONLY when the sun
## actually casts shadows. See _apply(): with shadows on, the slats do the
## occluding and the light has to survive for them to occlude it.
@export_range(0.0, 1.0) var shadowed_min_open: float = 0.85

## 0 = raised (stacked at the headrail), 1 = lowered (covering the window).
@export_range(0.0, 1.0) var drop: float = 1.0:
	set(v):
		drop = clampf(v, 0.0, 1.0)
		_apply()
		drop_changed.emit(drop)

## How much a single pull changes `drop`. Pulls step DOWN through the range and
## wrap back to fully lowered, which matches the one-cord blinds this models —
## a two-cord blind would need a second cord to reverse, and one cord that only
## ever goes one way is easier to understand in VR than a hidden direction toggle.
@export var step: float = 0.25

@export var animate_time: float = 0.45

## Everything the window's daylight drives, dimmed together as the blinds close.
## Scaling only the sun SPOT was not enough: that removed the sun patch but left
## the room's general daylight untouched, so closing the blinds barely changed the
## room. A covered window has to take the ambient down with it.
##
## Owning these energies is safe. QualityManager rewrites shadow_enabled on every
## light, but only touches light_energy for the "ceiling_light" group, and none of
## these is in it.
@export var sun_path: NodePath
@export var sun_energy: float = 3.0

## The warm directional fill standing in for sky light through the window.
@export var daylight_path: NodePath
@export var daylight_open: float = 0.15
## Not zero when shut — a vinyl blind leaks, and the room still has its lamps.
@export var daylight_shut: float = 0.035

## The room Environment's ambient, which is the rest of the daylight.
@export var env_path: NodePath
@export var ambient_open: float = 0.25
@export var ambient_shut: float = 0.10

var _sun: Light3D = null
var _daylight: Light3D = null
var _env: Environment = null

var _slats: MultiMeshInstance3D = null
var _slat_mat: ShaderMaterial = null
var _bottom: MeshInstance3D = null
var _tween: Tween = null


func _ready() -> void:
	if not sun_path.is_empty():
		_sun = get_node_or_null(sun_path) as Light3D
	if not daylight_path.is_empty():
		_daylight = get_node_or_null(daylight_path) as Light3D
	if not env_path.is_empty():
		var we := get_node_or_null(env_path) as WorldEnvironment
		if we != null and we.environment != null:
			# Duplicated because a .tscn sub_resource is SHARED between instances
			# of that scene; writing ambient on the shared copy would have every
			# bedroom in a session dimming together.
			we.environment = we.environment.duplicate()
			_env = we.environment
	_build()
	_apply()


func _build() -> void:
	var slat := BoxMesh.new()
	slat.size = Vector3(width, slat_height, slat_thickness)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = slat
	mm.instance_count = slat_count

	# On blind_slat.gdshader rather than a StandardMaterial3D, for the sway. The
	# movement is a vertex displacement, so it costs no per-frame GDScript over 48
	# MultiMesh instances — see that shader's header. Sheen and colour are the
	# same vinyl as before, now as shader parameters.
	var mat := ShaderMaterial.new()
	mat.shader = SLAT_SHADER
	mat.set_shader_parameter("slat_color", slat_color)
	mat.set_shader_parameter("slat_roughness", 0.42)
	mat.set_shader_parameter("slat_half_width", width * 0.5)
	mat.set_shader_parameter("sway_speed", sway_speed)
	mat.set_shader_parameter("sway_amplitude", 0.0)
	_slat_mat = mat

	_slats = MultiMeshInstance3D.new()
	_slats.name = "Slats"
	_slats.multimesh = mm
	_slats.material_override = mat
	add_child(_slats)

	# Headrail, fixed at the top.
	var head := MeshInstance3D.new()
	head.name = "HeadRail"
	var hb := BoxMesh.new()
	hb.size = Vector3(width + 0.03, 0.042, 0.032)
	head.mesh = hb
	head.position = Vector3(0.0, 0.021, 0.0)
	var hm := StandardMaterial3D.new()
	hm.albedo_color = slat_color.darkened(0.08)
	hm.roughness = 0.45
	head.material_override = hm
	add_child(head)

	# Bottom rail rides the lowest slat, so it is placed in _apply().
	_bottom = MeshInstance3D.new()
	_bottom.name = "BottomRail"
	var bb := BoxMesh.new()
	bb.size = Vector3(width + 0.006, 0.026, 0.007)
	_bottom.mesh = bb
	_bottom.material_override = hm
	add_child(_bottom)


func _apply() -> void:
	if _slats == null:
		return
	# A blind does NOT compress every slat evenly as it rises. The slats still
	# HANGING stay at their full pitch with daylight between them, and only the
	# raised ones bunch up against the headrail. Interpolating one pitch across the
	# whole run was the first attempt and it read as a solid sheet, because at any
	# partial height the pitch fell below slat_height and every slat overlapped its
	# neighbour.
	var full_pitch := height / float(slat_count)
	var hanging := int(round(float(slat_count) * drop))
	var stacked := slat_count - hanging
	var mm := _slats.multimesh
	var y := 0.0
	for i in slat_count:
		y -= stack_pitch if i < stacked else full_pitch
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(0.0, y, 0.0)))
	if _bottom != null:
		_bottom.position = Vector3(0.0, y - 0.012, 0.0)
	var open := openness()
	if _sun != null:
		# Two different occlusion models, picked by whether the sun can cast.
		#
		# With NO shadows — Quest, and any LOW preset — nothing stops the spot, so
		# fading it out as the blind comes down IS the occlusion. That is the
		# original behaviour and it has to stay.
		#
		# With real shadows, the slats occlude it themselves, and they are not a
		# solid sheet: at 48 slats over 1.18 m the pitch is 24.6 mm against a
		# 19 mm slat, so roughly 5 mm of daylight survives between every pair.
		# That gap is what stripes a floor under a real vinyl mini blind — and
		# fading the spot to zero would leave nothing to cast it. So the energy
		# gets a floor and the geometry does the work.
		var lit: float = open
		if _sun.shadow_enabled:
			lit = maxf(open, shadowed_min_open)
		_sun.light_energy = sun_energy * lit
	if _daylight != null:
		_daylight.light_energy = lerpf(daylight_shut, daylight_open, open)
	if _env != null:
		_env.ambient_light_energy = lerpf(ambient_shut, ambient_open, open)

	# Only the HANGING slats can move. Raised ones are bunched against the
	# headrail with stack_pitch between them and no free length to bow, so the
	# amplitude follows the drop rather than being a constant — a fully raised
	# blind that still fluttered would read as a stack of loose vinyl.
	if _slat_mat != null:
		_slat_mat.set_shader_parameter("sway_amplitude", sway_amplitude * drop)


## Replace the daylight BASE these three energies are scaled from.
##
## TimeOfDay owns the numbers; this script keeps the only writes to
## WindowSun.light_energy, Dusk.light_energy and Environment.ambient_light_energy,
## so there is still exactly one writer per property. Colours are deliberately not
## here — nothing in this script has ever written a light_color, and TimeOfDay
## writes those direct.
func set_daylight_base(p_sun_energy: float, p_daylight_open: float,
		p_daylight_shut: float, p_ambient_open: float, p_ambient_shut: float) -> void:
	sun_energy = p_sun_energy
	daylight_open = p_daylight_open
	daylight_shut = p_daylight_shut
	ambient_open = p_ambient_open
	ambient_shut = p_ambient_shut
	_apply()


## Signal target for BeadPullCord.pulled, which carries a bool that means nothing
## here — a blind has no on/off, only a height. Needed as its own method because
## GDScript will not connect a 1-argument signal to a 0-argument callable.
func _on_cord_pulled(_on: bool) -> void:
	pull_step()


## One pull: step down through the range, wrapping back to fully lowered.
func pull_step() -> void:
	var target: float = drop - step
	if target < -0.001:
		target = 1.0
	target = clampf(target, 0.0, 1.0)
	_animate_to(target)
	NetworkManager.report_event(NetEvents.Event.EV_BLINDS,
		{"blinds": self, "drop": target})


func set_drop_remote(value: float) -> void:
	_animate_to(clampf(value, 0.0, 1.0))


func _animate_to(target: float) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(_set_drop, drop, target, animate_time) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _set_drop(v: float) -> void:
	drop = v


## Fraction of the window still open, for anything that wants to dim with the
## blinds — the sun spot does.
func openness() -> float:
	return 1.0 - drop

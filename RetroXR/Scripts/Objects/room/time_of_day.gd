## Drives the bedroom's daylight from a single 0..1 time: morning, day, evening, night.
##
## The room used to be one hard-authored moment — a late-evening golden hour baked
## into every light's energy, every colour and the sky material. `time` 0.75 is that
## moment, reproduced exactly, so the shipped appearance is a keyframe rather than
## something this script approximates.
##
## OWNERSHIP. Three energies are NOT written here: WindowSun.light_energy,
## Dusk.light_energy and Environment.ambient_light_energy belong to WindowBlinds,
## which scales them by how far the blinds are open. This script owns the BASE they
## are scaled from and pushes it with set_daylight_base(), so there is still exactly
## one writer per property. Everything else — colours, both exterior lights, the sky
## and the street lamp — is written here and nowhere else.
##
## What it deliberately does NOT touch:
##   • FanGlobeLight — `visible` belongs to LightSwitch and `light_energy` to the
##     "ceiling_light" convention. Daylight going away at night is exactly what makes
##     the wall switch worth flipping, so this script is blind to its state.
##   • The bedside and desk lamps — the player's own, on their pull cords.
##   • StringLights — every one of its exports has a setter that rebuilds the
##     MultiMesh, and a lever drag would rebuild two strands per frame.
class_name TimeOfDay
extends Node3D

signal time_changed(time: float)

## 0 = morning, 0.25 = midday, 0.5 = afternoon, 0.75 = dusk (as authored), 1 = night.
@export_range(0.0, 1.0) var time: float = 0.75

@export_group("Nodes")
@export var world_env_path: NodePath
@export var blinds_path: NodePath
## The warm directional fill standing in for sky light indoors.
@export var room_daylight_path: NodePath
## The sun patch through the window. A spot, not a directional — see the note in
## _apply_suns() for why it is never rotated.
@export var window_sun_path: NodePath
@export var exterior_sun_path: NodePath
@export var exterior_fill_path: NodePath
@export var street_lamp_path: NodePath
## MeshInstance3D whose surface 0 is the street lamp's glowing head.
@export var street_lamp_head_path: NodePath
## The lever driving this. Only used to put its arm back where the player left it
## on load — the lever pushes time the rest of the time, never the other way.
@export var lever_path: NodePath

@export_group("Tuning")
## Swing the exterior sun (and the room fill's azimuth) with the time. Off leaves
## every light at its authored angle and changes colour and energy alone.
@export var rotate_suns: bool = true

## Where this bedroom is, for the sun's path. Chicago.
@export var latitude_deg: float = 41.88

## Solar declination for the day being modelled: +23.44 at midsummer, 0 at the
## equinoxes, -23.44 at midwinter. 12.1 is late August, which is the season the
## room already dresses for — the trees outside are in full leaf and the light is
## warm. It sets how high the sun gets at noon: 90 - latitude + declination, so
## 60.2 degrees here.
@export_range(-23.44, 23.44) var solar_declination_deg: float = 12.1

## The room must stay usable at night with the wall switch off and both lamp cords
## pulled. Nothing may take ambient below this.
@export var night_ambient_floor: float = 0.06

## Max apply rate while the lever is being dragged. The expensive half of an apply
## is the sky's radiance rebuild, not the property writes, and a lever emits every
## frame it moves. 12 Hz is under the rate a lerped sky reads as stepped at.
@export var min_apply_interval: float = 0.08

## Remember the time across sessions, in AppPrefs. Off for a scene that wants the
## authored moment every load.
@export var persist: bool = true

# --- Keyframes ---------------------------------------------------------------
# Five keys on the QUARTERS, so t = 0.75 is a key and lands on the authored dusk
# exactly. A 0/0.33/0.66/1 grid cannot do that — 0.75 would fall a third of the way
# into night and the shipped room would change colour the day this landed.
#
# The energies are BASE, fully-open values: the scene ships the blinds at drop 0.25,
# so what renders at dusk is these x 0.75, which is what the .tscn authors today.
#
# Colours interpolate component-wise. They are `source_color` uniforms, so these
# numbers are sRGB and this is a gamma-space lerp — the right trade here, because
# the keys were authored by eye in that same space.
#
# `hour_angle` is degrees from SOLAR NOON, negative in the morning — 15 per hour.
# The sun's direction is derived from it (solar_position), not authored, so the
# whole path follows from latitude and declination and stays consistent if either
# is changed. The clock times it works out to are on each row.
#
# The keys are not evenly spaced in clock time and are not meant to be: they are
# spaced by how the room LOOKS, and midday to dusk covers six hours where morning
# to midday covers five.
const KEYS: Array[Dictionary] = [
	{   # 0.00 — early morning, sun low and to the north-east, sky still cool
		"t": 0.0,
		"sky_top": Color(0.20, 0.34, 0.62),
		"sky_horizon": Color(0.86, 0.62, 0.52),
		"ground_horizon": Color(0.42, 0.38, 0.34),
		"ground_bottom": Color(0.05, 0.06, 0.07),
		"sky_energy": 1.0,
		"ambient_color": Color(0.78, 0.84, 1.00),
		"amb_open": 0.35, "amb_shut": 0.14,
		"day_color": Color(0.90, 0.88, 0.95),
		"day_open": 0.22, "day_shut": 0.05,
		"win_color": Color(1.00, 0.90, 0.78),
		"sun_energy": 3.0,
		"ext_color": Color(1.00, 0.86, 0.70), "ext_energy": 2.2,
		"fill_color": Color(0.50, 0.62, 0.90), "fill_energy": 0.7,
		"hour_angle": -75,   # 07:00
	},
	{   # 0.25 — midday, near-white light, sky at its bluest
		"t": 0.25,
		"sky_top": Color(0.16, 0.36, 0.78),
		"sky_horizon": Color(0.62, 0.74, 0.92),
		"ground_horizon": Color(0.52, 0.52, 0.48),
		"ground_bottom": Color(0.06, 0.07, 0.07),
		"sky_energy": 1.15,
		"ambient_color": Color(0.86, 0.92, 1.00),
		"amb_open": 0.55, "amb_shut": 0.20,
		"day_color": Color(1.00, 0.97, 0.92),
		"day_open": 0.30, "day_shut": 0.07,
		"win_color": Color(1.00, 0.97, 0.90),
		"sun_energy": 4.6,
		"ext_color": Color(1.00, 0.95, 0.86), "ext_energy": 3.2,
		"fill_color": Color(0.55, 0.66, 0.95), "fill_energy": 0.9,
		"hour_angle": 0,   # 12:00 solar noon
	},
	{   # 0.50 — afternoon, warming, sun swinging west
		"t": 0.5,
		"sky_top": Color(0.12, 0.27, 0.62),
		"sky_horizon": Color(0.80, 0.68, 0.56),
		"ground_horizon": Color(0.55, 0.46, 0.36),
		"ground_bottom": Color(0.05, 0.06, 0.06),
		"sky_energy": 1.0,
		"ambient_color": Color(1.00, 0.90, 0.80),
		"amb_open": 0.40, "amb_shut": 0.16,
		"day_color": Color(1.00, 0.86, 0.70),
		"day_open": 0.22, "day_shut": 0.05,
		"win_color": Color(1.00, 0.90, 0.74),
		"sun_energy": 4.2,
		"ext_color": Color(1.00, 0.86, 0.66), "ext_energy": 2.4,
		"fill_color": Color(0.50, 0.60, 0.88), "fill_energy": 0.7,
		"hour_angle": 52.5,   # 15:30
	},
	{   # 0.75 — THE AUTHORED ROOM. Every value here is what BedroomScene.tscn
		# shipped before this script existed, including the two sun angles, which
		# are the decomposition of its authored bases. Changing anything on this
		# row changes the room's default appearance.
		"t": 0.75,
		"sky_top": Color(0.06, 0.11, 0.30),
		"sky_horizon": Color(0.78, 0.45, 0.28),
		"ground_horizon": Color(0.55, 0.35, 0.24),
		"ground_bottom": Color(0.05, 0.05, 0.06),
		"sky_energy": 1.0,
		"ambient_color": Color(1.00, 0.84, 0.70),
		"amb_open": 0.25, "amb_shut": 0.10,
		"day_color": Color(1.00, 0.72, 0.50),
		"day_open": 0.15, "day_shut": 0.035,
		"win_color": Color(1.00, 0.83, 0.62),
		"sun_energy": 3.6,
		"ext_color": Color(1.00, 0.74, 0.48), "ext_energy": 1.5,
		"fill_color": Color(0.45, 0.55, 0.85), "fill_energy": 0.5,
		"hour_angle": 95,   # 18:20
	},
	{   # 0.875 — blue hour. Its only job is to stop the dusk-orange to night-blue
		# segment transiting through grey, which a straight two-key lerp does.
		"t": 0.875,
		"sky_top": Color(0.03, 0.05, 0.15),
		"sky_horizon": Color(0.28, 0.22, 0.30),
		"ground_horizon": Color(0.22, 0.16, 0.16),
		"ground_bottom": Color(0.03, 0.03, 0.04),
		"sky_energy": 0.9,
		"ambient_color": Color(0.72, 0.72, 0.95),
		"amb_open": 0.16, "amb_shut": 0.08,
		"day_color": Color(0.80, 0.70, 0.78),
		"day_open": 0.09, "day_shut": 0.032,
		"win_color": Color(0.82, 0.76, 0.82),
		"sun_energy": 1.6,
		"ext_color": Color(0.80, 0.62, 0.62), "ext_energy": 0.6,
		"fill_color": Color(0.38, 0.46, 0.80), "fill_energy": 0.36,
		"hour_angle": 108.75,   # 19:15
	},
	{   # 1.00 — night. WindowSun stays lit, cool and dim: it is the moon patch, and
		# zeroing it turns the window into a black rectangle.
		"t": 1.0,
		"sky_top": Color(0.010, 0.016, 0.045),
		"sky_horizon": Color(0.08, 0.07, 0.10),
		"ground_horizon": Color(0.05, 0.05, 0.07),
		"ground_bottom": Color(0.02, 0.02, 0.03),
		"sky_energy": 0.75,
		"ambient_color": Color(0.55, 0.62, 1.00),
		"amb_open": 0.10, "amb_shut": 0.06,
		"day_color": Color(0.55, 0.66, 1.00),
		"day_open": 0.05, "day_shut": 0.03,
		"win_color": Color(0.60, 0.70, 1.00),
		"sun_energy": 0.50,
		"ext_color": Color(0.45, 0.55, 0.95), "ext_energy": 0.18,
		"fill_color": Color(0.30, 0.38, 0.70), "fill_energy": 0.25,
		"hour_angle": 142.5,   # 21:30
	},
]

## Street lamp at the authored dusk, and at deep night. Gated rather than
## interpolated — see _lamp_gain().
const LAMP_ENERGY_DUSK := 3.0
const LAMP_ENERGY_NIGHT := 3.6
const LAMP_EMISSION_DUSK := 6.0
const LAMP_EMISSION_NIGHT := 7.0

var _world_env: WorldEnvironment = null
var _blinds: WindowBlinds = null
var _room_daylight: Light3D = null
var _window_sun: Light3D = null
var _exterior_sun: Light3D = null
var _exterior_fill: Light3D = null
var _street_lamp: Light3D = null
var _street_lamp_head: MeshInstance3D = null
var _lever: VRLever = null

# Instance-local copies of resources the .tscn shares between every instance of
# this scene. See _localise().
var _sky: Sky = null
var _sky_mat: ProceduralSkyMaterial = null
var _lamp_mat: StandardMaterial3D = null

var _last_apply: float = -1000.0
var _pending: bool = false


func _ready() -> void:
	# Nothing here runs per frame; every apply is driven by the lever's signal.
	set_process(false)
	set_physics_process(false)

	_world_env = get_node_or_null(world_env_path) as WorldEnvironment
	_blinds = get_node_or_null(blinds_path) as WindowBlinds
	_room_daylight = get_node_or_null(room_daylight_path) as Light3D
	_window_sun = get_node_or_null(window_sun_path) as Light3D
	_exterior_sun = get_node_or_null(exterior_sun_path) as Light3D
	_exterior_fill = get_node_or_null(exterior_fill_path) as Light3D
	_street_lamp = get_node_or_null(street_lamp_path) as Light3D
	_street_lamp_head = get_node_or_null(street_lamp_head_path) as MeshInstance3D
	_lever = get_node_or_null(lever_path) as VRLever

	if persist:
		time = clampf(AppPrefs.bedroom_time_of_day, 0.0, 1.0)
	if _lever != null:
		_lever.value_changed.connect(set_time)
		# Saved on RELEASE, not on every frame of a drag: a sweep would otherwise
		# rewrite the prefs JSON ~70 times, which is a stutter on Quest.
		_lever.released.connect(_on_lever_released)
		# no_signal, or restoring the arm would immediately push the value back
		# through set_time and look like the player had just moved it.
		_lever.set_value_no_signal(time)

	# DEFERRED, and this matters. WindowBlinds._ready() REPLACES the WorldEnvironment's
	# environment with a duplicate of its own. Localising the sky before that happens
	# would write it onto the object the blinds are about to throw away — and onto the
	# shared .tscn sub-resource, permanently, for every later instance. Authoring this
	# node last in the scene already orders the two; deferring survives a reorder.
	_apply.call_deferred()


## The lever's signal target. Also the public setter — assigning `time` directly
## moves nothing.
func set_time(t: float) -> void:
	var v := clampf(t, 0.0, 1.0)
	if is_equal_approx(v, time):
		return
	time = v
	_schedule()
	time_changed.emit(time)


## Apply immediately, ignoring the throttle. For a restore, which happens once.
func apply_now(t: float) -> void:
	time = clampf(t, 0.0, 1.0)
	_apply()


# --- Throttle ------------------------------------------------------------------
# A lever emits every frame it moves, so a drag would otherwise ask for ~72 applies
# a second. A one-shot timer rather than a _process poll, so an idle room costs
# nothing, and the trailing call guarantees the released value is the one that lands.

func _schedule() -> void:
	var now: float = Time.get_ticks_msec() * 0.001
	if now - _last_apply >= min_apply_interval:
		_apply()
	elif not _pending:
		_pending = true
		get_tree().create_timer(min_apply_interval, false).timeout.connect(_flush)


func _flush() -> void:
	_pending = false
	_apply()


# --- Apply ---------------------------------------------------------------------

func _apply() -> void:
	_last_apply = Time.get_ticks_msec() * 0.001
	var env := _resolve_env()
	_localise(env)
	var k := _sample(time)
	# Once, and shared: the exterior sun's ENERGY depends on where it is, not just
	# on the keyframe, so the two cannot be worked out independently.
	var sol := solar_position(k["hour_angle"], latitude_deg, solar_declination_deg)
	_apply_sky(k, env)
	_apply_daylight(k, env)
	_apply_exterior(k, sol.y)
	_apply_suns(k, sol)
	_apply_street_lamp(time)


## Never cached. WindowBlinds._ready() replaces WorldEnvironment.environment with a
## duplicate, so a reference taken once can be the copy that got discarded.
func _resolve_env() -> Environment:
	if _world_env == null:
		return null
	return _world_env.environment


## Take instance-local copies of the resources this script writes.
##
## Resource.duplicate() is SHALLOW in Godot 4 — it copies the resource's own
## properties and SHARES every nested resource. So the blinds' duplicated Environment
## still points at the .tscn's one Sky, which still points at its one
## ProceduralSkyMaterial. Writing a sky colour without this repaints the sky in every
## bedroom in the session. Both levels are copied by hand, once.
func _localise(env: Environment) -> void:
	if _sky_mat == null and env != null and env.sky != null \
			and env.sky.sky_material is ProceduralSkyMaterial:
		var sky := env.sky.duplicate() as Sky
		var mat := sky.sky_material.duplicate() as ProceduralSkyMaterial
		sky.sky_material = mat
		# Explicit rather than left on AUTOMATIC: what a lever drag costs should be a
		# decision, not an inference about which mode the engine picked. INCREMENTAL
		# spreads the radiance rebuild over a mip per frame instead of spiking, and at
		# 128 the chain converges in a handful of frames.
		sky.radiance_size = Sky.RADIANCE_SIZE_128
		sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
		env.sky = sky
		_sky = sky
		_sky_mat = mat
	if _lamp_mat == null and _street_lamp_head != null:
		var src := _street_lamp_head.get_surface_override_material(0) as StandardMaterial3D
		if src != null:
			_lamp_mat = src.duplicate() as StandardMaterial3D
			_street_lamp_head.set_surface_override_material(0, _lamp_mat)


## The keyframe row for a time, linearly interpolated between the two it falls between.
func _sample(t: float) -> Dictionary:
	var lo: Dictionary = KEYS[0]
	var hi: Dictionary = KEYS[KEYS.size() - 1]
	for i in range(KEYS.size() - 1):
		if t <= float(KEYS[i + 1]["t"]):
			lo = KEYS[i]
			hi = KEYS[i + 1]
			break
	var span: float = float(hi["t"]) - float(lo["t"])
	var f: float = 0.0 if span <= 0.0 else clampf((t - float(lo["t"])) / span, 0.0, 1.0)
	var out: Dictionary = {}
	for key: Variant in lo:
		var a: Variant = lo[key]
		var b: Variant = hi[key]
		if a is Color:
			out[key] = (a as Color).lerp(b as Color, f)
		else:
			out[key] = lerpf(float(a), float(b), f)
	return out


func _apply_sky(k: Dictionary, env: Environment) -> void:
	if _sky_mat != null:
		_sky_mat.sky_top_color = k["sky_top"]
		_sky_mat.sky_horizon_color = k["sky_horizon"]
		_sky_mat.ground_horizon_color = k["ground_horizon"]
		_sky_mat.ground_bottom_color = k["ground_bottom"]
		_sky_mat.energy_multiplier = k["sky_energy"]
	if env != null:
		env.ambient_light_color = k["ambient_color"]


## Colours direct; the three contested ENERGIES through the blinds, which keep the
## only writes to them and go on scaling by how far they are open.
func _apply_daylight(k: Dictionary, env: Environment) -> void:
	if _room_daylight != null:
		_room_daylight.light_color = k["day_color"]
	if _window_sun != null:
		_window_sun.light_color = k["win_color"]

	var amb_open: float = maxf(k["amb_open"], night_ambient_floor)
	# Clamped to amb_open as well as to the floor: shut must never be brighter than
	# open, or closing the blinds would LIGHT the room.
	var amb_shut: float = clampf(k["amb_shut"], night_ambient_floor, amb_open)

	if _blinds != null:
		_blinds.set_daylight_base(k["sun_energy"], k["day_open"], k["day_shut"],
			amb_open, amb_shut)
		return
	# No blinds in this scene, so this script is the only writer and "fully open" is
	# the right reading — there is nothing over the window to scale by.
	if _window_sun != null:
		_window_sun.light_energy = k["sun_energy"]
	if _room_daylight != null:
		_room_daylight.light_energy = k["day_open"]
	if env != null:
		env.ambient_light_energy = amb_open


func _apply_exterior(k: Dictionary, altitude_deg: float) -> void:
	if _exterior_sun != null:
		_exterior_sun.light_color = k["ext_color"]
		_exterior_sun.light_energy = k["ext_energy"] * horizon_gain(altitude_deg)
	if _exterior_fill != null:
		_exterior_fill.light_color = k["fill_color"]
		_exterior_fill.light_energy = k["fill_energy"]


## How much DIRECT sun survives at a given altitude. Zero once the sun is down.
##
## This is not a nicety. The keyframes carry the sun past sunset — it is 1.1 energy
## and still falling when it crosses the horizon around t = 0.81 — and a
## DirectionalLight3D below the horizon shines UPWARD: undersides light up, and
## every shadow on the street points at the sky. The energy has to be gone before
## the direction turns, and no amount of keyframing the energy alone gets that
## right, because where the sun is depends on latitude and declination.
##
## The band ends at 4 degrees rather than at 0 so that the authored dusk key, which
## sits at 4.39 degrees, is untouched: the room shipped at that frame. The lower end
## is 1 degree BELOW the horizon so the last of it is gone by the time the direction
## flips rather than exactly as it does.
##
## Real sunlight falls off this steeply near the horizon anyway — the path through
## the atmosphere lengthens sharply — so the shape is not a fudge.
static func horizon_gain(altitude_deg: float) -> float:
	return smoothstep(-1.0, 4.0, altitude_deg)


## Which lights may turn, and which may not.
##
## COMPASS. The window wall (z = -2.2, with the street beyond it) faces SOUTH, so
## in this room -Z is south, +Z north, -X east and +X west. That is the orientation
## a bedroom wants in the northern hemisphere: a south-facing window takes sun for
## most of the day. NB that wall's nodes are still named North* — layout labels from
## when the room was blocked out, and renaming them would break every NodePath into
## Room/. The compass here is the authority.
##
## One consequence, before it reads as a bug: with the sun in the southern sky and
## the houses opposite ALSO to the south, those houses show us their north faces,
## which never take direct sun. ExteriorFill, the sky term, is what lights them.
## That is what a real south-facing street view looks like — you are always looking
## into the light.
##
## WindowSun is FROZEN. It is not a sun, it is a fake occluder: shadows are off on
## Quest, so a directional would light the room through its walls, and the 11-degree
## cone stands in for the shadow map. It was measured to be 1.27 m across at a
## 1.5 x 1.2 m opening, which is the only reason nothing spills onto the plaster
## around it — a few degrees of yaw walks the patch off the window entirely. Aiming
## it from the real sun, so the patch TRAVELS across the floor through the day, is
## the obvious next thing and is deliberately not done here: it needs the cone
## re-solved against the opening at every angle, or it paints the wall instead.
##
## ExteriorFill is frozen too: a sky fill's direction carries no information.
##
## ExteriorSun takes the real solar path. It is masked to the street (layer 2), so
## nothing about it can rake the room — which is what makes a physically low sun
## safe out there when it would be unusable indoors.
##
## Dusk, the room's own fill, follows the sun's AZIMUTH but holds a fixed high
## elevation. Unshadowed and masked to the room, its angle only picks which walls
## take the warm rake, and a real low sun would rake straight through them.
func _apply_suns(k: Dictionary, sol: Vector2) -> void:
	if not rotate_suns:
		return
	if _exterior_sun != null:
		_exterior_sun.transform = Transform3D(
			sun_basis(sol.x, sol.y), _exterior_sun.transform.origin)
	if _room_daylight != null and _room_daylight is DirectionalLight3D:
		_room_daylight.transform = Transform3D(
			sun_basis(sol.x, DUSK_ELEVATION_DEG), _room_daylight.transform.origin)


## Elevation the room's own fill is held at. Not astronomy and not meant to be.
const DUSK_ELEVATION_DEG := 45.2


## Where the sun is: hour angle in degrees from solar noon (negative = morning),
## a latitude and a declination. Returns Vector2(azimuth for sun_basis, altitude),
## both degrees.
##
## Altitude goes NEGATIVE after sunset, and that is not harmless: a directional
## light below the horizon shines upward. horizon_gain() is what takes the energy
## away before the direction turns over.
##
##   sin(alt) = sin(lat) sin(dec) + cos(lat) cos(dec) cos(h)
##   A        = atan2(sin h, cos h sin(lat) - tan(dec) cos(lat))
##
## A comes out measured from due SOUTH, positive toward the west, which is the
## convenient form — it is 0 at solar noon by construction. sun_basis puts the sun
## in the NORTH at azimuth 0 (a DirectionalLight3D shines down its own -Z), so the
## conversion is 180 - A: noon becomes 180 and the sun stands due south.
static func solar_position(hour_angle_deg: float, lat_deg: float,
		dec_deg: float) -> Vector2:
	var lat := deg_to_rad(lat_deg)
	var dec := deg_to_rad(dec_deg)
	var h := deg_to_rad(hour_angle_deg)
	var sin_alt: float = sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(h)
	var alt := asin(clampf(sin_alt, -1.0, 1.0))
	var a := atan2(sin(h), cos(h) * sin(lat) - tan(dec) * cos(lat))
	return Vector2(180.0 - rad_to_deg(a), rad_to_deg(alt))


## Basis for a directional light at an azimuth and elevation. A DirectionalLight3D
## shines down its own -Z: identity aims along the horizon, the pitch tips it down by
## `elevation`, the yaw swings it round.
static func sun_basis(azimuth_deg: float, elevation_deg: float) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(azimuth_deg)) \
		* Basis(Vector3.RIGHT, deg_to_rad(-elevation_deg))


## The street lamp is a photocell, not a dimmer: it snaps on at dusk over a narrow
## band. Interpolating it with everything else would leave it half-lit at 2pm.
func _apply_street_lamp(t: float) -> void:
	var gain := _lamp_gain(t)
	var deepen := smoothstep(0.75, 1.0, t)
	if _street_lamp != null:
		# Range is NOT touched. The lamp is 18 m out with a 14 m reach, so it stays
		# outside; widening it at night would light the bedroom through the wall.
		_street_lamp.light_energy = lerpf(LAMP_ENERGY_DUSK, LAMP_ENERGY_NIGHT, deepen) * gain
	if _lamp_mat != null:
		# emission_enabled stays true and the MULTIPLIER goes to zero. Toggling the
		# flag is a shader-variant switch, which costs a pipeline compile on Quest.
		_lamp_mat.emission_energy_multiplier = \
			lerpf(LAMP_EMISSION_DUSK, LAMP_EMISSION_NIGHT, deepen) * gain


## Dusk-on only. There is no dawn ramp because the lever's range has no pre-dawn in
## it — t = 0 is morning, not the night before — and a lamp still blazing at the
## lever's leftmost position read as 4am rather than as the start of the day.
func _on_lever_released(v: float) -> void:
	NetworkManager.report_event(NetEvents.Event.EV_TIME_OF_DAY,
		{"clock": self, "time": clampf(v, 0.0, 1.0)})
	if not persist:
		return
	AppPrefs.bedroom_time_of_day = clampf(v, 0.0, 1.0)
	AppPrefs.save_prefs()


func net_set_time(value: float) -> void:
	var v := clampf(value, 0.0, 1.0)
	if _lever != null:
		_lever.set_value_no_signal(v)
	apply_now(v)


func _lamp_gain(t: float) -> float:
	return smoothstep(0.60, 0.70, t)

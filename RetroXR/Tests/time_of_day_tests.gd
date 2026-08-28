extends Node

## The bedroom's time-of-day lever and the lighting it drives.
##
##   godot --headless --path RetroXR res://Tests/time_of_day_tests.tscn
##   godot --headless --path RetroXR res://Tests/time_of_day_tests.tscn -- --only=sun
##
## Exits non-zero on failure, so it can gate a commit. No ROM, core, headset or
## GPU — the whole feature is property writes over a scene that loads headless.
##
## Nothing here asserts an authored colour or energy. The `authored` group used to,
## mirroring every value the shipped dusk was built from, and it went red on any
## retune of a light rather than on a defect. The room's lighting is expected to
## keep moving, so what is left asserts RELATIONS — orderings, who owns which
## property, what survives a round trip — which stay true across a retune.
##
## `sharing` is the one worth keeping. Resource.duplicate() is shallow, so an
## Environment copy still points at the .tscn's one Sky and its one sky material;
## without hand-copying both levels, changing the time in one bedroom repaints the
## sky in every other instance in the session.
##
## What this canNOT check is how any of it LOOKS. That is
## `Tools/models/bedroom_probe.tscn --mode=timesweep`, windowed.

const GROUPS := ["sun", "sharing", "sweep", "night", "blinds", "lever",
	"glyphs", "desktop", "persist"]
const SCENE := preload("res://Scenes/BedroomScene.tscn")

var _fail := 0
var _ran := 0
var _only := ""

var _root: Node = null
var _tod: TimeOfDay = null
var _lever: VRLever = null
var _blinds: WindowBlinds = null
var _we: WorldEnvironment = null
var _dusk: DirectionalLight3D = null
var _ext_sun: DirectionalLight3D = null
var _ext_fill: DirectionalLight3D = null
var _win_sun: SpotLight3D = null
var _lamp: OmniLight3D = null
var _pref_backup := 0.0


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.trim_prefix("--only=")

	# The persist cases write the player's real prefs, so put them back after.
	_pref_backup = AppPrefs.bedroom_time_of_day

	_root = SCENE.instantiate()
	add_child(_root)
	for i in 6:
		await get_tree().process_frame

	_tod = _root.get_node("TimeOfDay")
	_lever = _root.get_node("Furniture/TimeLever/LeverPivot/Lever")
	_blinds = _root.get_node("Furniture/Blinds")
	_we = _root.get_node("WorldEnvironment")
	_dusk = _root.get_node("Dusk")
	_ext_sun = _root.get_node("ExteriorSun")
	_ext_fill = _root.get_node("ExteriorFill")
	_win_sun = _root.get_node("WindowSun")
	_lamp = _root.get_node("Exterior/StreetLamp/Light")

	if _want("sun"):
		await _test_sun()
	if _want("sharing"):
		await _test_sharing()
	if _want("sweep"):
		await _test_sweep()
	if _want("night"):
		await _test_night()
	if _want("blinds"):
		await _test_blinds()
	if _want("lever"):
		await _test_lever()
	if _want("glyphs"):
		await _test_glyphs()
	if _want("desktop"):
		await _test_desktop()
	if _want("persist"):
		await _test_persist()

	AppPrefs.bedroom_time_of_day = _pref_backup
	AppPrefs.save_prefs()

	await _settle()
	print("[test] %d cases, %s" % [_ran,
		"PASS" if _fail == 0 else "%d FAILURE(S)" % _fail])
	get_tree().quit(0 if _fail == 0 else 1)


## Drop the room and let the AudioServer reclaim what it was playing, BEFORE the
## main loop ends.
##
## Godot's Main::cleanup() frees the SceneTree, then unregisters the GDExtension
## classes, and only then deletes the AudioServer — which destroys the playbacks
## it was still holding. A custom AudioStreamPlayback alive at that point is
## destroyed after its class record is gone, and the process dies with an access
## violation and no crash-handler output. Nothing between those steps pumps the
## AudioServer, so no extension-side change can help: a playback is handed back
## only by AudioServer::update() -> _cleanup_lists() on the main thread, which
## needs FRAMES after the emitter is released. quit() leaves at most the rest of
## the current iteration, so the caller has to spend them.
##
## BedroomScene is full of spatial emitters, so this suite hit it every other run
## — it passed in isolation and crashed in the full sequence, which is what a race
## looks like from the outside. Treat this await as load-bearing; the same
## reasoning is why Tools/netplay/netplay_live_probe.gd awaits before ITS quit().
##
## THE FRAME COUNT IS MEASURED, NOT PICKED. Dropping the room is not enough on its
## own and neither is a token wait: at 12 frames it still died 3 runs in 6, because
## the reclaim is a CHAIN — the emitters have to go, then the MetaXR mixer notices
## it has no voices left and frees its own player, and only then does another
## AudioServer::update() hand the playback back. 60 frames covers the whole chain
## and ran 18 times green (it crashed 2 in 3 before). If this ever flakes again the
## answer is to find which link got slower, not to shave this number.
##
## It also tells the two teardown crashes apart, which look identical from a test
## runner: this one prints NO crash-handler backtrace and stops right after the
## summary line, while a stale Node* in a GDExtension prints
## "CrashHandlerException ... signal 11" and names the module.
func _settle() -> void:
	if is_instance_valid(_root):
		_root.queue_free()
		_root = null
	for _i in range(60):
		await get_tree().process_frame


# ── The sun's path ────────────────────────────────────────────────────────────

## COMPASS: the window wall faces SOUTH, so -Z is south, +Z north, -X east and
## +X west. A DirectionalLight3D shines down its own -Z, so the direction light
## TRAVELS is -basis.z, and the sun is in the opposite direction from that.
##
##   sun in the east  -> light travels +X
##   sun in the south -> light travels +Z
##   sun in the west  -> light travels -X
##
## These are the cases that would catch the compass being flipped, which is the
## failure that looks plausible in every still and is wrong all day.
func _test_sun() -> void:
	var lat: float = _tod.latitude_deg
	var dec: float = _tod.solar_declination_deg

	# Solar noon: due south, and at the textbook altitude for the latitude.
	_tod.apply_now(0.25)
	await get_tree().process_frame
	var noon: Vector3 = -_ext_sun.global_transform.basis.z
	_num(noon.x, 0.0, "sun/at noon the sun is due south (no east-west lean)", 0.01)
	_ok(noon.z > 0.0, "sun/at noon light travels north, so the sun is south (z %.3f)"
		% noon.z)
	_num(rad_to_deg(asin(-noon.y)), 90.0 - lat + dec,
		"sun/noon altitude is 90 - latitude + declination", 0.05)

	# Morning in the east, afternoon and dusk in the west.
	_tod.apply_now(0.0)
	await get_tree().process_frame
	var morn: Vector3 = -_ext_sun.global_transform.basis.z
	_ok(morn.x > 0.5, "sun/morning sun is in the east (light travels +x, %.3f)" % morn.x)
	_ok(morn.y < 0.0, "sun/morning sun is above the horizon")

	_tod.apply_now(0.5)
	await get_tree().process_frame
	var aft: Vector3 = -_ext_sun.global_transform.basis.z
	_ok(aft.x < -0.5, "sun/afternoon sun is in the west (light travels -x, %.3f)" % aft.x)

	# It climbs to noon and sinks after: altitude is single-peaked.
	var alts: Array[float] = []
	for t in [0.0, 0.25, 0.5, 0.75, 1.0]:
		_tod.apply_now(t)
		await get_tree().process_frame
		alts.append(rad_to_deg(asin(-(-_ext_sun.global_transform.basis.z).y)))
	_ok(alts[1] > alts[0] and alts[1] > alts[2],
		"sun/altitude peaks at noon (%.1f, %.1f, %.1f)" % [alts[0], alts[1], alts[2]])
	_ok(alts[2] > alts[3] and alts[3] > alts[4], "sun/and falls away through the evening")
	_ok(alts[4] < 0.0, "sun/at night the sun is below the horizon (%.1f)" % alts[4])

	# The room's own fill shares the azimuth but NOT the altitude. It is unshadowed
	# and masked to the room, so a real low sun would rake straight through a wall.
	for t in [0.0, 0.25, 0.75]:
		_tod.apply_now(t)
		await get_tree().process_frame
		var sd: Vector3 = -_dusk.global_transform.basis.z
		var xd: Vector3 = -_ext_sun.global_transform.basis.z
		_num(atan2(sd.x, sd.z), atan2(xd.x, xd.z),
			"sun/room fill shares the sun's azimuth at t = %.2f" % t, 0.001)
		_num(rad_to_deg(asin(-sd.y)), TimeOfDay.DUSK_ELEVATION_DEG,
			"sun/room fill holds its high elevation at t = %.2f" % t, 0.05)

	# THE one that matters after sunset. A DirectionalLight3D below the horizon
	# shines UPWARD — undersides light up and every shadow on the street points at
	# the sky. Sweep finely through the whole range: the sun crosses the horizon
	# around t = 0.81, between two keys, so checking only the keys misses it.
	var worst_up: float = 0.0
	var worst_t: float = -1.0
	for i in 101:
		var t: float = float(i) / 100.0
		_tod.apply_now(t)
		await get_tree().process_frame
		var dir: Vector3 = -_ext_sun.global_transform.basis.z
		if dir.y > 0.0:   # light travelling upward, i.e. sun below the horizon
			var lit: float = _ext_sun.light_energy * dir.y
			if lit > worst_up:
				worst_up = lit
				worst_t = t
	_ok(worst_up < 0.02,
		"sun/never lights the street from below (worst %.4f at t = %.2f)"
		% [worst_up, worst_t])

	# And the gate must not touch the sun while it is still up — the authored dusk
	# key sits at 4.39 degrees and the room shipped at that frame.
	_num(TimeOfDay.horizon_gain(4.39), 1.0, "sun/the authored dusk sun is ungated", 0.0001)
	_num(TimeOfDay.horizon_gain(60.2), 1.0, "sun/a high sun is ungated", 0.0001)
	_num(TimeOfDay.horizon_gain(-1.5), 0.0, "sun/a set sun is fully gated", 0.0001)
	_ok(TimeOfDay.horizon_gain(2.0) < 1.0, "sun/the gate ramps below 4 degrees")

	# The window cone and the sky fill must never move.
	var win0: Basis = _win_sun.global_transform.basis
	var fill0: Basis = _ext_fill.global_transform.basis
	for t in [0.0, 0.25, 0.5, 0.75, 1.0]:
		_tod.apply_now(t)
		await get_tree().process_frame
		_basis(_win_sun.global_transform.basis, win0,
			"sun/WindowSun never turns (t = %.2f)" % t)
		_basis(_ext_fill.global_transform.basis, fill0,
			"sun/ExteriorFill never turns (t = %.2f)" % t)

	# And the whole thing is opt-out.
	_tod.apply_now(0.25)
	await get_tree().process_frame
	var parked: Basis = _ext_sun.global_transform.basis
	_tod.rotate_suns = false
	_tod.apply_now(1.0)
	await get_tree().process_frame
	_basis(_ext_sun.global_transform.basis, parked,
		"sun/rotate_suns = false leaves every light where it was")
	_tod.rotate_suns = true


# ── Instance-local resources ──────────────────────────────────────────────────

func _test_sharing() -> void:
	_tod.apply_now(0.0)
	await get_tree().process_frame
	var env: Environment = _we.environment
	var mine: ProceduralSkyMaterial = env.sky.sky_material

	# A second, untouched instance of the same scene is the oracle: whatever it
	# holds is what the .tscn's shared sub-resources still say.
	var other: Node = SCENE.instantiate()
	var shared: Environment = other.get_node("WorldEnvironment").environment

	_ok(env.sky != shared.sky, "sharing/the Sky is a copy, not the shared one")
	_ok(mine != shared.sky.sky_material,
		"sharing/the sky material is a copy, not the shared one")
	_col(shared.sky.sky_material.sky_top_color, Color(0.06, 0.11, 0.3),
		"sharing/a morning room left the shared sky at its authored dusk")
	other.free()


# ── The sweep actually sweeps ─────────────────────────────────────────────────

func _test_sweep() -> void:
	var amb: Array[float] = []
	var sun: Array[float] = []
	var tops: Array[Color] = []
	for t in [0.0, 0.25, 0.5, 0.75, 1.0]:
		_tod.apply_now(t)
		await get_tree().process_frame
		amb.append(_we.environment.ambient_light_energy)
		sun.append(_ext_sun.light_energy)
		tops.append(_we.environment.sky.sky_material.sky_top_color)

	_ok(amb[1] > amb[0], "sweep/midday is brighter than morning")
	_ok(amb[1] > amb[3], "sweep/midday is brighter than dusk")
	_ok(amb[4] < amb[3], "sweep/night is darker than dusk")
	_ok(sun[4] < sun[1], "sweep/the exterior sun dims into the night")
	var distinct := {}
	for c in tops:
		distinct[c] = true
	_eq(distinct.size(), 5, "sweep/all five keys give a distinct sky")

	# Between keys, not at them: the interpolation has to actually run.
	_tod.apply_now(0.125)
	await get_tree().process_frame
	var mid: float = _we.environment.ambient_light_energy
	_ok(mid > amb[0] and mid < amb[1], "sweep/a value between keys interpolates")

	# The street lamp is GATED, not lerped — a photocell does not sit half-lit
	# through the afternoon.
	_tod.apply_now(0.0)
	await get_tree().process_frame
	_num(_lamp.light_energy, 0.0, "sweep/street lamp is off in the morning")
	_tod.apply_now(0.5)
	await get_tree().process_frame
	_num(_lamp.light_energy, 0.0, "sweep/street lamp is still off at 2pm")
	_tod.apply_now(1.0)
	await get_tree().process_frame
	_ok(_lamp.light_energy > 3.0, "sweep/street lamp is on at night")


# ── The room stays usable at night ────────────────────────────────────────────

func _test_night() -> void:
	_tod.apply_now(1.0)
	await get_tree().process_frame
	_ok(_we.environment.ambient_light_energy >= _tod.night_ambient_floor - 0.0001,
		"night/ambient stays at or above the floor")
	# Zeroing it turns the window into a black rectangle; it is the moon patch.
	_ok(_win_sun.light_energy > 0.05, "night/the window still carries a moon patch")

	# The lamps are the player's, on their pull cords, and the ceiling globe is the
	# light switch's. TimeOfDay writing any of them would fight its owner.
	var bedside: OmniLight3D = _root.get_node("BedsideLampLight")
	var desk: OmniLight3D = _root.get_node("DeskLampLight")
	var globe: OmniLight3D = _root.get_node("FanGlobeLight")
	_num(bedside.light_energy, 1.0, "night/the bedside lamp is left alone")
	_num(desk.light_energy, 1.0, "night/the desk lamp is left alone")
	_num(globe.light_energy, 1.2, "night/the ceiling globe's energy is left alone")
	_ok(globe.visible, "night/the ceiling globe's visibility is the switch's")

	# Blinds shut at night is the darkest the room gets by daylight alone.
	_blinds.drop = 1.0
	await get_tree().process_frame
	_ok(_we.environment.ambient_light_energy >= _tod.night_ambient_floor - 0.0001,
		"night/shut blinds at night still clear the floor")
	_blinds.drop = 0.25


# ── The blinds keep owning the three energies ─────────────────────────────────

func _test_blinds() -> void:
	_tod.apply_now(0.25)
	await get_tree().process_frame
	var open_amb: float = _we.environment.ambient_light_energy
	var open_day: float = _dusk.light_energy

	_blinds.drop = 1.0
	await get_tree().process_frame
	_ok(_we.environment.ambient_light_energy < open_amb, "blinds/shut dims the ambient")
	_ok(_dusk.light_energy < open_day, "blinds/shut dims the indoor fill")

	# Shut must never be BRIGHTER than open, at any time of day, or closing the
	# blinds would light the room.
	for t in [0.0, 0.25, 0.5, 0.75, 1.0]:
		_tod.apply_now(t)
		_blinds.drop = 0.0
		await get_tree().process_frame
		var o: float = _we.environment.ambient_light_energy
		_blinds.drop = 1.0
		await get_tree().process_frame
		_ok(_we.environment.ambient_light_energy <= o + 0.0001,
			"blinds/shut <= open ambient at t = %.2f" % t)

	# And a blind moved AFTER the time changed must still scale the new base.
	_tod.apply_now(0.25)
	_blinds.drop = 0.0
	await get_tree().process_frame
	var bright: float = _win_sun.light_energy
	_tod.apply_now(1.0)
	await get_tree().process_frame
	_ok(_win_sun.light_energy < bright,
		"blinds/a time change reaches the lights through the blinds")
	_blinds.drop = 0.25


# ── The lever ─────────────────────────────────────────────────────────────────

func _test_lever() -> void:
	var pivot: Node3D = _root.get_node("Furniture/TimeLever/LeverPivot")
	var ball: Node3D = _root.get_node("Furniture/TimeLever/LeverPivot/Ball")

	for pair in [[0.0, 65.0], [0.5, 0.0], [1.0, -65.0], [0.25, 32.5]]:
		_lever.set_value_no_signal(pair[0])
		_num(rad_to_deg(pivot.rotation.x), pair[1],
			"lever/value %.2f is %+.1f deg" % [pair[0], pair[1]], 0.05)
		_num(_lever.get_value(), pair[0], "lever/value %.2f reads back" % pair[0], 0.001)

	# The whole point of the mount/pivot split: the arm turns about the WALL NORMAL,
	# so the ball tracks along the wall and never swings into the room or through
	# the plaster. If x moves, the mount's basis has been transposed or overwritten.
	var pts: Array[Vector3] = []
	for v in [0.0, 0.25, 0.5, 0.75, 1.0]:
		_lever.set_value_no_signal(v)
		await get_tree().process_frame
		pts.append(ball.global_position)
	var xs: Array[float] = []
	for p in pts:
		xs.append(p.x)
	_ok(float(xs.max()) - float(xs.min()) < 0.001,
		"lever/the ball turns about the wall normal (x is constant)")
	_ok(pts[0].x > -2.525, "lever/the ball stays proud of the wall face")
	_ok(pts[0].z > pts[4].z, "lever/morning is the door side, night the far side")
	# The light switch is at z 0.55 and the door opening starts at z 0.70.
	_ok(pts[0].z < 0.45, "lever/the sweep clears the light switch")
	_ok(pts[0].z < 0.70, "lever/the sweep clears the door opening")

	# Moving the lever moves the room.
	_lever.set_value(0.25)
	await get_tree().create_timer(0.2).timeout
	var day: float = _we.environment.ambient_light_energy
	_lever.set_value(1.0)
	await get_tree().create_timer(0.2).timeout
	_ok(_we.environment.ambient_light_energy < day, "lever/drives the room's ambient")
	_num(_tod.time, 1.0, "lever/drives TimeOfDay.time", 0.001)

	# The throttle coalesces a drag, but the value the player let go on must land.
	for i in 20:
		_lever.set_value(float(i) / 19.0)
	await get_tree().create_timer(0.3).timeout
	_num(_tod.time, 1.0, "lever/the final value of a fast sweep still lands", 0.001)


# ── The plate's Nerd Font glyphs ──────────────────────────────────────────────

## A tofu box is a SILENT failure — the label still draws, still sits in the right
## place, and shows a hollow rectangle. Nothing errors, so only an explicit check
## catches it, and only on a device where the font is missing would anyone notice.
##
## These codepoints are Private Use Area: they exist in SymbolsNerdFont-Regular.ttf
## and in no theme or system font. So both halves matter — that a font is attached
## at all, and that the attached font actually has the character.
const TICK_GLYPHS := {
	"TickMorning": 0xE34C,   # weather-sunrise
	"TickDay": 0xE30D,       # weather-day_sunny
	"TickEvening": 0xE34D,   # weather-sunset
	"TickNight": 0xE3A5,     # weather-moon_waning_crescent_3
}


func _test_glyphs() -> void:
	var plate: Node3D = _root.get_node("Furniture/TimeLever/Plate")
	for tick_name: String in TICK_GLYPHS:
		var label := plate.get_node_or_null(tick_name) as Label3D
		if not _ok(label != null, "glyphs/%s exists" % tick_name):
			continue
		var cp: int = TICK_GLYPHS[tick_name]
		_eq(label.text, String.chr(cp), "glyphs/%s carries its codepoint" % tick_name)
		var f: Font = label.font
		if not _ok(f != null, "glyphs/%s has a font attached" % tick_name):
			continue
		_ok(f.has_char(cp),
			"glyphs/%s: the attached font really has U+%X" % [tick_name, cp])
		# Unshaded, or the tint stops being the colour the moment the room dims.
		_ok(not label.shaded, "glyphs/%s is unshaded" % tick_name)
		# Flat on the plate. A billboarded tick would swing to face the player and
		# stop marking the arc position it exists to mark.
		_eq(label.billboard, BaseMaterial3D.BILLBOARD_DISABLED,
			"glyphs/%s does not billboard" % tick_name)

	# Each tint distinct — sunrise and sunset are the same sun over the same
	# horizon, so colour is what separates the two ends of the arc.
	var seen := {}
	for tick_name: String in TICK_GLYPHS:
		var label := plate.get_node_or_null(tick_name) as Label3D
		if label != null:
			seen[label.modulate] = true
	_eq(seen.size(), TICK_GLYPHS.size(), "glyphs/all four tints are distinct")

	# Every glyph must sit ON the plate — measured by its real AABB, not by its
	# origin. These are 40-60 mm wide drawn, so a position comfortably inside the
	# plate can still hang its rays over the edge, and the sunrise one did.
	var plate_mesh := (plate as MeshInstance3D).mesh as BoxMesh
	var half_y: float = plate_mesh.size.y * 0.5
	var half_z: float = plate_mesh.size.z * 0.5
	for tick_name: String in TICK_GLYPHS:
		var label := plate.get_node_or_null(tick_name) as Label3D
		if label == null:
			continue
		var box: AABB = label.get_aabb()
		# Into plate space: the label is turned to lie flat, so its own local
		# extents are not the plate's axes.
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for i in 8:
			var corner: Vector3 = label.transform * box.get_endpoint(i)
			lo = lo.min(corner)
			hi = hi.max(corner)
		_ok(lo.y >= -half_y and hi.y <= half_y and lo.z >= -half_z and hi.z <= half_z,
			"glyphs/%s fits the plate (y %.3f..%.3f in +-%.3f, z %.3f..%.3f in +-%.3f)"
			% [tick_name, lo.y, hi.y, half_y, lo.z, hi.z, half_z])


# ── Desktop press-drag ────────────────────────────────────────────────────────

func _test_desktop() -> void:
	# VRHinge gates its pointer tracking on use_xr and rolls the angle from the
	# mouse WHEEL on desktop, which is right for a lid and wrong for a lever.
	# VRLever overrides that, and this is the case that proves it.
	_ok(not get_viewport().use_xr, "desktop/this run is the non-XR path")

	var mount: Node3D = _root.get_node("Furniture/TimeLever")
	var mid: Vector3 = mount.global_transform * Vector3(0.018, 0.0, -0.11)
	var morning: Vector3 = mount.global_transform * Vector3(0.018, 0.0997, -0.0465)

	_lever.set_value_no_signal(0.5)
	_point(XRToolsPointerEvent.Type.ENTERED, mid, mid)
	_point(XRToolsPointerEvent.Type.PRESSED, mid, mid)
	_num(_lever.get_value(), 0.5, "desktop/a press alone does not jump the lever", 0.01)

	_point(XRToolsPointerEvent.Type.MOVED, morning, mid)
	var dragged: float = _lever.get_value()
	_ok(absf(dragged - 0.5) > 0.1, "desktop/dragging while held moves it")
	_ok(dragged < 0.5, "desktop/it moves toward the end the pointer went to")

	_point(XRToolsPointerEvent.Type.RELEASED, morning, morning)
	var after: float = _lever.get_value()
	_point(XRToolsPointerEvent.Type.MOVED, mid, morning)
	_num(_lever.get_value(), after, "desktop/after release, movement is ignored", 0.001)

	# EXITED must NOT drop the drag — a sweep leaves the grab box almost at once,
	# because the box rides the arm and the pointer is chasing it.
	_lever.set_value_no_signal(0.5)
	_point(XRToolsPointerEvent.Type.PRESSED, mid, mid)
	_point(XRToolsPointerEvent.Type.EXITED, mid, mid)
	_point(XRToolsPointerEvent.Type.MOVED, morning, mid)
	_ok(absf(_lever.get_value() - 0.5) > 0.1,
		"desktop/a drag survives leaving the grab box")
	_point(XRToolsPointerEvent.Type.RELEASED, morning, morning)


# ── Persistence ───────────────────────────────────────────────────────────────

func _test_persist() -> void:
	var before: float = AppPrefs.bedroom_time_of_day

	_lever.set_value(0.4)
	await get_tree().process_frame
	_num(AppPrefs.bedroom_time_of_day, before,
		"persist/a drag does not write prefs every frame", 0.0001)

	_lever.released.emit(_lever.get_value())
	await get_tree().process_frame
	_num(AppPrefs.bedroom_time_of_day, 0.4, "persist/release writes the pref", 0.001)

	# And a fresh room reads it back.
	AppPrefs.bedroom_time_of_day = 0.2
	var fresh: Node = SCENE.instantiate()
	add_child(fresh)
	for i in 4:
		await get_tree().process_frame
	var tod2: TimeOfDay = fresh.get_node("TimeOfDay")
	var lever2: VRLever = fresh.get_node("Furniture/TimeLever/LeverPivot/Lever")
	_num(tod2.time, 0.2, "persist/a fresh room restores the saved time", 0.001)
	_num(lever2.get_value(), 0.2, "persist/and puts the lever's arm back", 0.001)
	fresh.queue_free()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _want(name: String) -> bool:
	return _only.is_empty() or _only == name


func _point(type: XRToolsPointerEvent.Type, at: Vector3, last: Vector3) -> void:
	_lever.pointer_event(XRToolsPointerEvent.new(type, null, _lever, at, last))


## Returns the result so a case can bail out rather than cascade — checking a
## font on a label that does not exist reports four failures for one fault.
func _ok(cond: bool, what: String) -> bool:
	_ran += 1
	if cond:
		print("[test] ok   %s" % what)
	else:
		_fail += 1
		print("[test] FAIL %s" % what)
	return cond


func _eq(got: Variant, want: Variant, what: String) -> bool:
	return _ok(got == want,
		what if got == want else "%s (got %s, want %s)" % [what, got, want])


func _num(got: float, want: float, what: String, tol: float = 0.002) -> bool:
	return _ok(absf(got - want) <= tol,
		what if absf(got - want) <= tol
		else "%s (got %.4f, want %.4f)" % [what, got, want])


func _col(got: Color, want: Color, what: String) -> bool:
	var ok := absf(got.r - want.r) <= 0.002 and absf(got.g - want.g) <= 0.002 \
		and absf(got.b - want.b) <= 0.002
	return _ok(ok, what if ok else "%s (got %s, want %s)" % [what, str(got), str(want)])


func _basis(got: Basis, want: Basis, what: String) -> bool:
	var ok := (got.x - want.x).length() <= 0.01 and (got.y - want.y).length() <= 0.01 \
		and (got.z - want.z).length() <= 0.01
	return _ok(ok, what if ok else "%s (got x=%v y=%v z=%v)" % [what, got.x, got.y, got.z])

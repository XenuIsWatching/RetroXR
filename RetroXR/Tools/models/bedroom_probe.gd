## Visual-evaluation probe for the 90s bedroom. Stills, a flythrough, or both.
##
## Lives here rather than being written fresh each time because the framings below
## took several rounds each to settle, and because a render that does not match
## what ships is worse than no render. Two things it gets right that a throwaway
## probe kept getting wrong:
##
##  * The fan globe is forced to the energy QualityManager actually applies
##    (0.8 desktop / 0.6 Quest). The scene AUTHORS 1.2, and _adjust_lights has not
##    run yet this early, so a naive probe renders the room brighter than any
##    player will ever see it.
##  * `own_world_3d = false` with the scene added under this node, or anything
##    that parents itself to the scene root renders into the wrong world.
##
## Run it windowed, NOT headless — `--headless` uses the dummy renderer and hands
## back a blank image:
##
##     "$godot" --path RetroXR --resolution 320x240 --position 20,20 \
##         res://Tools/models/bedroom_probe.tscn -- --mode=flythrough
##
## `--mode=timesweep` walks the TimeOfDay lever from morning to night: one still per
## keyframe from three framings, then a continuous clip of the room changing under a
## held camera, with the lever's own arm driven from the same t so the ball is seen
## sweeping its arc. `--sweep-frames=N` sets the clip length.
##
## Modes: stills (default), flythrough, both, timesweep. PNGs land in `out_dir`; delete it
## when finished. Encode a flythrough with imageio at 24 fps:
##
##     iio.get_writer("tour.mp4", fps=24, codec="libx264", pixelformat="yuv420p",
##                    macro_block_size=1, output_params=["-crf","24"])
##
## CRF 24 is worth specifying — imageio's default quality put an 11 s clip at
## 21 MB, and CRF 24 gives 2 MB with no visible difference at this size.
extends Node3D

enum Mode { STILLS, FLYTHROUGH, BOTH, TIMESWEEP }

const SCENE := preload("res://Scenes/BedroomScene.tscn")

@export var mode: Mode = Mode.STILLS
@export var out_dir: String = "res://probe_out"
@export var still_size := Vector2i(1000, 750)
@export var video_size := Vector2i(960, 640)

## Ceiling-light energy to render at. QualityManager forces 0.8 on desktop and
## 0.6 on Quest over whatever the scene authors, so 0.6 is the honest worst case.
@export var globe_energy: float = 0.6

## name, camera position, look-at target, fov.
## 30 deg is Quest angular density at 750 px tall (25 px/degree), for judging how
## large a detail reads in the headset. The wide values here are for surveying
## layout — at 30 deg a 5 m room fills the frame three times over.
const STILLS: Array = [
	["overview", Vector3(-2.25, 1.95, 1.95), Vector3(1.40, 0.55, -1.50), 82.0],
	["bed", Vector3(0.15, 1.45, 0.35), Vector3(2.10, 0.85, -1.60), 62.0],
	["desk", Vector3(-0.40, 1.30, -0.75), Vector3(-1.50, 0.85, -1.80), 55.0],
	["window", Vector3(-0.10, 1.45, -0.30), Vector3(-1.00, 1.40, -2.10), 62.0],
	["tv_corner", Vector3(0.10, 1.60, 0.05), Vector3(2.00, 0.75, 1.60), 58.0],
	["bookcases", Vector3(-0.55, 1.05, -0.35), Vector3(-2.40, 0.35, -1.30), 55.0],
	["wardrobe", Vector3(-1.40, 1.60, -0.60), Vector3(0.55, 1.20, 2.10), 66.0],
	["switch", Vector3(-1.90, 1.45, 1.35), Vector3(-2.60, 1.20, 0.55), 55.0],
]

# --- Flythrough ------------------------------------------------------------
# Radius 1.0 about (0.05, 0) was sized against a player-capsule sweep of the
# room: it clears the chair collider band at z -1.51..-1.14, the bed at
# x >= 0.971 and the wardrobe at z >= 1.443. The radius eases up from zero so the
# camera leaves the centre without a jump, and the spin ends facing +X, which is
# the circle's opening tangent, so the two phases join with no visible cut.
const EYE := 1.6
const CENTRE := Vector3(0.05, EYE, 0.0)
const RADIUS := 1.0
const SPIN_FRAMES := 96          # 4 s at 24 fps
const WALK_FRAMES := 168         # 7 s

var _sv: SubViewport = null
var _cam: Camera3D = null
var _n := 0


func _ready() -> void:
	get_tree().create_timer(900.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT"); get_tree().quit(1))
	_run()


func _resolve_mode() -> Mode:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="):
			match arg.split("=")[1]:
				"stills": return Mode.STILLS
				"flythrough": return Mode.FLYTHROUGH
				"both": return Mode.BOTH
				"timesweep": return Mode.TIMESWEEP
	return mode


func _run() -> void:
	var m: Mode = _resolve_mode()
	DirAccess.make_dir_recursive_absolute(out_dir)
	add_child(SCENE.instantiate())

	_sv = SubViewport.new()
	_sv.size = still_size if m == Mode.STILLS else video_size
	# false, so anything parenting itself to the scene root shares this world.
	_sv.own_world_3d = false
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)
	_cam = Camera3D.new()
	_cam.near = 0.05
	_sv.add_child(_cam)
	_cam.current = true          # make_current() does NOT work in a SubViewport
	# `--lights-off` flips the wall switch before anything is framed. The room has
	# two baked lighting states and only one of them is reachable by default, so
	# without this half of the bake can never be looked at.
	if OS.get_cmdline_user_args().has("--lights-off"):
		# Flip the SWITCH, not the light. `visible` on a ceiling fixture belongs to
		# LightSwitch, which reasserts it from its own state - setting the light
		# directly is overwritten a frame later, and the room renders lit while
		# the log says it was turned off.
		var hit := 0
		for node in get_tree().get_root().find_children("*", "LightSwitch", true, false):
			(node as LightSwitch).set_lights_on(false)
			hit += 1
		# Counted, not announced: printing "off" whether or not a switch was found
		# is a check that cannot fail, and it passed for a run that turned nothing
		# off at all.
		var lit := 0
		for node in get_tree().get_nodes_in_group("ceiling_light"):
			print("[probe] ceiling id=%d vis=%s" % [node.get_instance_id(), (node as Light3D).visible])
			if (node as Light3D).visible:
				lit += 1
		print("[probe] light switches turned off: %d, ceiling lights still visible: %d"
			% [hit, lit])
	for i in 30:
		await get_tree().process_frame

	var globe := get_tree().root.find_child("FanGlobeLight", true, false) as OmniLight3D
	if globe != null:
		globe.light_energy = globe_energy

	if m == Mode.STILLS or m == Mode.BOTH:
		await _do_stills()
	if m == Mode.FLYTHROUGH or m == Mode.BOTH:
		await _do_flythrough()
	if m == Mode.TIMESWEEP:
		await _do_timesweep()
	print("[probe] done -> %s" % out_dir)
	get_tree().quit(0)


func _do_stills() -> void:
	for shot in STILLS:
		_cam.fov = shot[3]
		_cam.global_position = shot[1]
		_cam.look_at(shot[2], Vector3.UP)
		await _save("%s/%s.png" % [out_dir, shot[0]])
		print("[probe] still %s" % shot[0])


func _do_flythrough() -> void:
	_sv.size = video_size
	_cam.fov = 70.0
	for i in 4:
		await get_tree().process_frame

	# Spin in place. 90..450 deg, so it starts AND ends facing +X.
	for f in SPIN_FRAMES:
		var a: float = deg_to_rad(90.0 + 360.0 * float(f) / float(SPIN_FRAMES))
		_cam.global_position = CENTRE
		_cam.look_at(CENTRE + Vector3(sin(a), 0.0, cos(a)), Vector3.UP)
		await _frame()

	# Walk the circle, facing the direction of travel.
	for f in WALK_FRAMES:
		var t: float = float(f) / float(WALK_FRAMES)
		var phi: float = TAU * t
		var r: float = RADIUS * smoothstep(0.0, 0.28, t)
		var pos: Vector3 = CENTRE + Vector3(sin(phi), 0.0, cos(phi)) * r
		_cam.global_position = pos
		_cam.look_at(pos + Vector3(cos(phi), 0.0, -sin(phi)), Vector3.UP)
		await _frame()
	print("[probe] flythrough: %d frames" % _n)


# --- Time-of-day sweep --------------------------------------------------------
# Framings chosen for what each one proves: `overview` for the room as a whole,
# `window` for the beam, the sky and the street outside (where the change is
# largest), and `switch` for the lever, which is on that wall.
const SWEEP_SHOTS: Array = [
	["overview", Vector3(-2.25, 1.95, 1.95), Vector3(1.40, 0.55, -1.50), 82.0],
	["window", Vector3(-0.10, 1.45, -0.30), Vector3(-1.00, 1.40, -2.10), 62.0],
	# Near head-on, deliberately. The ball stands 22 mm proud of the plate the tick
	# glyphs are printed on, so an oblique view projects it over whichever glyph it
	# is nearest and reads as an overlap that is not there. A player working this
	# lever is facing the wall.
	["lever", Vector3(-1.82, 1.24, 0.34), Vector3(-2.60, 1.21, 0.26), 40.0],
]

## Keyframe times, and what each is called in the filename.
const SWEEP_KEYS: Array = [
	[0.00, "morning"], [0.25, "midday"], [0.50, "afternoon"],
	[0.75, "dusk"], [1.00, "night"],
]


func _do_timesweep() -> void:
	var tod: TimeOfDay = get_tree().root.find_child("TimeOfDay", true, false) as TimeOfDay
	if tod == null:
		print("[probe] no TimeOfDay in the scene"); return
	var lever: VRLever = get_tree().root.find_child("Lever", true, false) as VRLever
	# The lever must NOT be left driving time from here: apply_now bypasses the
	# throttle, which a 240-frame render wants, and set_value would fight it.
	if lever != null:
		lever.value_changed.disconnect(tod.set_time)

	_sv.size = still_size
	for shot in SWEEP_SHOTS:
		_cam.fov = shot[3]
		_cam.global_position = shot[1]
		_cam.look_at(shot[2], Vector3.UP)
		for key in SWEEP_KEYS:
			tod.apply_now(key[0])
			if lever != null:
				lever.set_value_no_signal(key[0])
			# The sky is INCREMENTAL, so its radiance map needs a few frames to
			# converge. A still taken on the next frame shows the previous key's
			# reflections.
			for i in 12:
				await get_tree().process_frame
			await _save("%s/t_%s_%s.png" % [out_dir, shot[0], key[1]])
			print("[probe] still %s %s" % [shot[0], key[1]])

	var frames: int = _sweep_frames()
	_sv.size = video_size
	for shot in SWEEP_SHOTS:
		_cam.fov = shot[3]
		_cam.global_position = shot[1]
		_cam.look_at(shot[2], Vector3.UP)
		_n = 0
		for f in frames:
			var t: float = float(f) / float(frames - 1)
			tod.apply_now(t)
			if lever != null:
				lever.set_value_no_signal(t)
			await _save("%s/sweep_%s_%04d.png" % [out_dir, shot[0], _n])
			if _n % 40 == 0:
				print("[probe] sweep %s frame %d/%d" % [shot[0], _n, frames])
			_n += 1
	print("[probe] timesweep: %d frames per framing" % frames)


func _sweep_frames() -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sweep-frames="):
			return maxi(2, int(arg.split("=")[1]))
	return 240


func _frame() -> void:
	await _save("%s/f_%04d.png" % [out_dir, _n])
	if _n % 40 == 0:
		print("[probe] frame %d" % _n)
	_n += 1


func _save(path: String) -> void:
	for j in 2:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_sv.get_texture().get_image().save_png(path)

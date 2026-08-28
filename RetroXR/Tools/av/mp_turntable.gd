## Turntable render of the MotionPlus dongle. Windowed, not headless: the dummy
## renderer returns a blank image, so this draws into a SubViewport on the real
## GPU and saves one PNG per step.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/av/mp_turntable.tscn -- --seated
##
## `--seated` shows the dongle clipped into a Wii Remote instead of on its own,
## which is the framing that checks the mating face rather than the shape.
extends Node

const MOTION_PLUS := preload("res://Scenes/Objects/controllers/wii/motion_plus.tscn")
const WIIMOTE := preload("res://Scenes/Objects/controllers/wii/wiimote.tscn")

const OUT_DIR := "res://probe_out"
const FRAMES := 72
const SIZE := Vector2i(900, 675)

## The dongle's body centre in its own frame. Its origin sits 2 mm BEHIND the
## mating face (see motion_plus.tscn), so the middle of the block is half the
## body length past that face rather than half past the origin.
const MP_CENTRE := Vector3(0.0, 0.0, 0.02075)


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	_run.call_deferred()


func _run() -> void:
	var seated := "--seated" in OS.get_cmdline_user_args()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var sv := SubViewport.new()
	sv.size = SIZE
	sv.own_world_3d = true
	sv.transparent_bg = false
	sv.msaa_3d = Viewport.MSAA_4X
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	# A sky, not just ambient. The shell is a clearcoat material and its whole
	# read is in the reflection; lit flat it renders as one white silhouette with
	# no shape in it at all.
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.42, 0.47, 0.56)
	sky_mat.sky_horizon_color = Color(0.62, 0.64, 0.68)
	sky_mat.ground_bottom_color = Color(0.16, 0.16, 0.18)
	sky_mat.ground_horizon_color = Color(0.30, 0.30, 0.33)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# Low. The shell is near-white already (albedo 0.93) and clips to a flat
	# silhouette the moment the total exposure goes much over 1: the first pass at
	# this rendered as a plain white rectangle with no edges in it.
	env.ambient_light_energy = 0.28
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.85
	var we := WorldEnvironment.new()
	we.environment = env
	sv.add_child(we)

	var key := DirectionalLight3D.new()
	key.light_energy = 0.95
	key.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	key.shadow_enabled = true
	sv.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.28
	fill.rotation_degrees = Vector3(-15.0, -125.0, 0.0)
	sv.add_child(fill)

	# Something for the shadow to fall on. A white object on an empty gradient has
	# no scale and nothing to sit on; the plane is what says how big it is.
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1.0, 1.0)
	floor_mesh.mesh = plane
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.20, 0.21, 0.24)
	floor_mat.roughness = 0.85
	floor_mesh.set_surface_override_material(0, floor_mat)
	floor_mesh.position = Vector3(0.0, -0.016, 0.0)
	sv.add_child(floor_mesh)

	# The subject. Frozen so it cannot fall out of frame, and parented to a pivot
	# so the TURNTABLE spins rather than the camera flying: a spinning object
	# under a fixed key light shows its form far better than a fixed object under
	# a light that appears to chase the camera.
	var pivot := Node3D.new()
	sv.add_child(pivot)

	var mp := MOTION_PLUS.instantiate() as MotionPlus
	mp.freeze = true
	var look_at := Vector3.ZERO
	var radius := 0.145

	if seated:
		var wm := WIIMOTE.instantiate() as Wiimote
		wm.freeze = true
		pivot.add_child(wm)
		# Centre the pair on the remote's middle: 148 mm of remote plus 46 mm of
		# dongle hanging off its +Z end.
		wm.position = Vector3(0.0, 0.0, -0.02)
		# The dongle has to be IN THE TREE before the zone can take it:
		# pick_up_object drives the pickable's own grab machinery, which needs a
		# parent and a finished _ready. Left detached it silently does nothing and
		# the remote renders bare.
		pivot.add_child(mp)
		await get_tree().process_frame
		var port := wm.get_node("ExpansionPort") as XRToolsSnapZone
		port.pick_up_object(mp)
		await get_tree().process_frame
		print("[probe] seated ok=%s device_type=%d"
			% [str(wm.get_motion_plus() == mp), wm.device_type])
		radius = 0.34
	else:
		pivot.add_child(mp)
		mp.position = -MP_CENTRE

	var cam := Camera3D.new()
	cam.fov = 40.0
	cam.near = 0.005
	sv.add_child(cam)
	cam.position = Vector3(0.0, radius * 0.45, radius)
	cam.look_at(look_at)
	cam.current = true

	for i in range(12):
		await get_tree().process_frame

	var saved := 0
	for i in range(FRAMES):
		pivot.rotation.y = TAU * float(i) / float(FRAMES)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := sv.get_texture().get_image()
		if img == null or img.is_empty():
			print("[probe] frame %d EMPTY" % i)
			continue
		img.save_png("%s/mp_%03d.png" % [OUT_DIR, i])
		saved += 1

	print("[probe] saved %d/%d frames to %s (seated=%s)" % [saved, FRAMES, OUT_DIR, str(seated)])
	get_tree().quit(0)

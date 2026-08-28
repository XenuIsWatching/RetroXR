## Elevations and a turntable of the Nunchuk shell. Windowed, not headless: the
## dummy renderer returns a blank image, so this draws into a SubViewport on the
## real GPU and saves PNGs.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/models/nunchuk_views.tscn -- --mode=stills
##
## Modes: `stills` (default) writes the four framings the reference photographs
## were shot from — side, back, front and three-quarter — and `turntable` writes
## 72 frames of a spin.
##
## The four stills exist because the shell's SILHOUETTE is the thing under test
## and no assertion can check it. A profile table that describes the wrong object
## still bakes a clean, watertight, correctly-wound mesh; gen_nunchuk.gd's own
## checks all pass on it. Only a picture beside the reference can fail.
##
## The elevations are shot level, at the body's mid-height, on a long lens (fov
## 26 at 300 mm), so they can be measured against a photographed elevation rather
## than only admired. The floor sits well below the tail for the same reason: a
## horizon line crossing the body is the one thing that makes a silhouette hard
## to read.
##
## Lighting is lifted verbatim from mp_turntable.gd, including the low exposure —
## the shell is albedo 0.93 clearcoat and clips to a flat white cutout the moment
## total exposure goes much over 1.
extends Node

const NUNCHUK := preload("res://Scenes/Objects/controllers/wii/nunchuk.tscn")

const OUT_DIR := "res://probe_out"
const FRAMES := 72
const SIZE := Vector2i(750, 1000)
const TURN_SIZE := Vector2i(900, 675)
const LAY_SIZE := Vector2i(1100, 700)

## Camera distance for the stills. The shell is 105 mm crown to tail today and
## the plan takes it to 113; at fov 26 this frames either with room to spare.
const RADIUS := 0.30

## name, azimuth degrees, elevation degrees, laid down.
##
## Azimuth 0 looks down -Z at the FRONT face, the one C and Z live on. 180 is the
## back, where the stick's gate is. 90 is a side elevation. The three-quarter is
## the framing that shows the scoop, which neither elevation does on its own.
##
## The LAID views tip the body onto its side, Rx(-90), which puts the nose at
## screen right, the spine up and the buttons down — the pose every reference
## photograph of this thing is taken in. They exist because a silhouette is only
## comparable against a photograph in the photograph's own orientation: upright,
## the same shell reads as a bottle and the eye stops trusting it.
const VIEWS := [
	["front", 0.0, 0.0, false],
	["side", 90.0, 0.0, false],
	["back", 180.0, 0.0, false],
	["threequarter", 145.0, 22.0, false],
	["lay_side", 90.0, 0.0, true],
	["lay_threequarter", 90.0, 30.0, true],
]


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	_run.call_deferred()


func _run() -> void:
	var mode := "stills"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			mode = a.substr(7)
	var turn := mode == "turntable"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var sv := SubViewport.new()
	sv.size = TURN_SIZE if turn else SIZE
	sv.own_world_3d = true
	sv.transparent_bg = false
	sv.msaa_3d = Viewport.MSAA_4X
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

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

	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1.0, 1.0)
	floor_mesh.mesh = plane
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.20, 0.21, 0.24)
	floor_mat.roughness = 0.85
	floor_mesh.set_surface_override_material(0, floor_mat)
	floor_mesh.position = Vector3(0.0, -0.10, 0.0)
	sv.add_child(floor_mesh)

	var pivot := Node3D.new()
	sv.add_child(pivot)

	# Frozen, or it falls out of frame before the first save. The cord is not
	# spawned here: nunchuk.gd only lays it once the node is in a real room, and
	# a rope thrashing through the elevation would hide the silhouette anyway.
	var nc := NUNCHUK.instantiate() as Nunchuk
	nc.freeze = true
	pivot.add_child(nc)
	await get_tree().process_frame

	_report_extents(nc)

	var cam := Camera3D.new()
	cam.fov = 26.0
	cam.near = 0.005
	sv.add_child(cam)

	for i in range(12):
		await get_tree().process_frame

	var saved := 0
	if turn:
		cam.position = Vector3(0.0, RADIUS * 0.45, RADIUS)
		cam.look_at(Vector3.ZERO)
		cam.current = true
		for i in range(FRAMES):
			pivot.rotation.y = TAU * float(i) / float(FRAMES)
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := sv.get_texture().get_image()
			if img == null or img.is_empty():
				print("[probe] frame %d EMPTY" % i)
				continue
			img.save_png("%s/nc_turn_%03d.png" % [OUT_DIR, i])
			saved += 1
		print("[probe] saved %d/%d turntable frames to %s" % [saved, FRAMES, OUT_DIR])
	else:
		cam.current = true
		for row: Array in VIEWS:
			var az: float = deg_to_rad(row[1])
			var el: float = deg_to_rad(row[2])
			var laid: bool = row[3]
			pivot.rotation = Vector3(-PI * 0.5, 0.0, 0.0) if laid else Vector3.ZERO
			sv.size = LAY_SIZE if laid else SIZE
			cam.position = Vector3(
				RADIUS * cos(el) * sin(az),
				RADIUS * sin(el),
				-RADIUS * cos(el) * cos(az))
			cam.look_at(Vector3.ZERO)
			# Three, not one. A camera that JUMPS between framings needs the
			# viewport to catch up: with a single frame the first view in the
			# list came back as bare sky and floor with no subject in it.
			for _w in range(3):
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := sv.get_texture().get_image()
			if img == null or img.is_empty():
				print("[probe] view %s EMPTY" % row[0])
				continue
			img.save_png("%s/nc_view_%s.png" % [OUT_DIR, row[0]])
			saved += 1
		print("[probe] saved %d/%d views to %s" % [saved, VIEWS.size(), OUT_DIR])

	get_tree().quit(0)


## What the assembled controller actually measures, printed so the render can be
## checked against the reference dimensions (113 x 38 x 37 mm) rather than only
## eyeballed. Walks the visible meshes' AABBs in the controller's own frame.
func _report_extents(nc: Node3D) -> void:
	var total := AABB()
	var first := true
	for child in nc.get_children():
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var box: AABB = mi.transform * mi.mesh.get_aabb()
		if first:
			total = box
			first = false
		else:
			total = total.merge(box)
		print("[probe]   %-13s y %+7.1f .. %+7.1f  z %+7.1f .. %+7.1f  w %6.1f" % [
			mi.name,
			box.position.y * 1000.0, box.end.y * 1000.0,
			box.position.z * 1000.0, box.end.z * 1000.0,
			box.size.x * 1000.0])
	print("[probe] whole: %.1f long x %.1f wide x %.1f deep (mm)" % [
		total.size.y * 1000.0, total.size.x * 1000.0, total.size.z * 1000.0])

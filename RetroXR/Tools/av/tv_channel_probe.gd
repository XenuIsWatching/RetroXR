extends Node3D

## Spawns a TV, switches it to the built-in tuner and photographs the glass.
##
## Windowed, not --headless — the dummy renderer returns a blank image:
##   godot --path RetroXR --resolution 900x700 --position 20,20 \
##     res://Tools/av/tv_channel_probe.tscn -- --mode=live
##
## Modes: live          tune the first channel and wait for a picture
##        static        tune a deliberately dead URL, catch the error screen
##        static_frames the same, as a numbered sequence for an mp4
##        frames        live, as a numbered sequence for an mp4
## PNGs land in res://probe_out/ (gitignored).

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")

var _sv: SubViewport = null
var _tv: RetroTV = null
var _tuner: TVTuner = null
var _mode := "live"
var _shot := 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="):
			_mode = arg.split("=")[1]
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[tvprobe] TIMEOUT")
		get_tree().quit(1))
	await _build()


func _build() -> void:
	_sv = SubViewport.new()
	_sv.size = Vector2i(900, 700)
	_sv.own_world_3d = true
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.10, 0.13)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.82, 0.9)
	e.ambient_light_energy = 0.5
	env.environment = e
	_sv.add_child(env)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	key.light_energy = 1.1
	_sv.add_child(key)

	_tv = TV_SCENE.instantiate() as RetroTV
	_tv.freeze = true
	_sv.add_child(_tv)
	await get_tree().process_frame

	# Square on to the glass: this probe is about what the picture looks like,
	# not about the cabinet.
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 0.0, 0.62)
	cam.fov = 45.0
	_sv.add_child(cam)
	cam.current = true

	_tuner = _tv.ensure_tuner()
	_tuner.channels_changed.connect(_on_channels)
	print("[tvprobe] mode=%s, waiting for channels…" % _mode)


func _on_channels() -> void:
	if _tuner.channels.is_empty():
		return
	if _tv.get_source() == RetroTV.Source.TV:
		return                                  # already running
	# Wait for discovery to settle first. Switching source the moment the CACHED
	# list arrives races the lineup: _on_lineup_ready re-sorts the channel array
	# underneath a tune that has already been issued.
	if _tuner.discovered_host().is_empty() and _tuner.tuner_status_line().begins_with("Looking"):
		return
	print("[tvprobe] %d channels; first = %s %s"
		% [_tuner.channels.size(), _tuner.channels[0].get("number", ""),
		   _tuner.channels[0].get("name", "")])
	_tv.cycle_source()                          # COMPONENT -> TV
	print("[tvprobe] source now %s" % RetroTV.SOURCE_NAMES[_tv.get_source()])
	if _mode == "static" or _mode == "static_frames":
		# A channel that cannot possibly resolve, to photograph the error screen.
		_tuner.channels.insert(0, {
			"number": "0.0", "name": "Dead Channel",
			"url": "http://192.168.0.199:5004/auto/v99.9",
			"source": "stream", "hd": false,
		})
		_tuner.tune(0)
	_run()


func _run() -> void:
	if _mode == "static" or _mode == "static_frames":
		await _wait_for(func() -> bool: return not _tuner.error_text().is_empty(), 30.0)
		print("[tvprobe] error text: %s" % _tuner.error_text().replace("\n", " / "))
		await _settle(20)
		if _mode == "static":
			_save("tv_static")
		else:
			# Static is animated by definition — a still cannot show whether the
			# grain steps, whether the roll bar drifts, or whether either boils.
			for i in 60:
				await get_tree().process_frame
				await RenderingServer.frame_post_draw
				_save("frames/tv_%03d" % i)
	elif _mode == "frames":
		await _wait_for(func() -> bool: return _tuner.has_picture(), 40.0)
		await _settle(10)
		for i in 48:
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			_save("frames/tv_%03d" % i)
	else:
		await _wait_for(func() -> bool: return _tuner.has_picture(), 40.0)
		print("[tvprobe] picture acquired: %s" % _tuner.status_banner())
		await _settle(24)
		_save("tv_live")
	print("[tvprobe] done (%d image(s))" % _shot)
	get_tree().quit(0)


func _wait_for(test: Callable, seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if test.call():
			return
		await get_tree().process_frame
	print("[tvprobe] WARNING: wait timed out after %.0fs" % seconds)


func _settle(frames: int) -> void:
	for f in range(frames):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame


func _save(name: String) -> void:
	DirAccess.make_dir_recursive_absolute("res://probe_out/frames")
	var img := _sv.get_texture().get_image()
	img.save_png("res://probe_out/%s.png" % name)
	_shot += 1

extends Node

# Boots the real arcade room, restores the saved slot, plants a sensor bar on the
# television, aims the Wii Remote at a sequence of known points and photographs
# what the game draws. The driver outlives the scene change by living under the
# tree root rather than under the scene.

func _ready() -> void:
	var driver := Driver.new()
	driver.name = "IRDriver"
	driver.process_priority = 100      # after every object in the room
	get_tree().root.add_child.call_deferred(driver)
	get_tree().change_scene_to_file.call_deferred("res://Scenes/MainScene.tscn")


class Driver extends Node:
	# user://, not res:// — res:// is inside the pck on an exported build and
	# every save_png there fails with ERR_UNAVAILABLE.
	const OUT := "user://probe_out"
	const JOYPAD_B := 0
	const JOYPAD_A := 8

	var _t := 0.0
	var _stage := "wait"
	var _wii: Node = null
	var _remote: Node = null
	var _bar: Node = null
	var _tv: Node = null
	var _shots: Array = []
	var _shot := 0
	var _shot_t := 0.0
	## Which shot the aim has actually been applied for. Was a `_shot_t < 0.05`
	## window, which is shorter than one frame whenever the emulator drags the
	## frame rate down — on the Quest every shot after the first kept the previous
	## aim, and five identical photographs looked like a pointer that had died.
	var _applied := -1
	var _busy := false
	var _dist := 2.0
	## Similarity test. Shrinking the bar by S and moving in by S reproduces, at
	## the exact same angles, a room whose television is 1/S times bigger — which
	## is the only way to ask "is the pointer wrong, or is this set just small?"
	## without a television that can be resized.
	var _barscale := 1.0
	var _mode := "aim"
	var _below := false
	var _screen_centre := Vector3.ZERO

	func _log(s: String) -> void:
		print("[probe] %s" % s)

	func _find(cls: String) -> Node:
		for n: Node in get_tree().get_nodes_in_group("spawned"):
			if n.get_class() == "Node3D" or true:
				if n.get_script() != null and (n.get_script() as Script).get_global_name() == cls:
					return n
		return null

	func _process(delta: float) -> void:
		_t += delta
		match _stage:
			"perf":      _perf(delta)
			"wait":      _wait()
			"setup":     _setup()
			"boot":      _boot(delta)
			"shoot":     _shoot(delta)

	# ── 1. wait for the room and the saved slot ───────────────────────────────
	func _wait() -> void:
		if _t < 6.0:
			return
		for n: Node in get_tree().get_nodes_in_group("spawned"):
			if n is RetroSystem and (n as RetroSystem).systemid == "wii":
				_wii = n
			if n is Wiimote:
				_remote = n
		_tv = get_tree().get_first_node_in_group("tv")
		if _tv == null:
			for n: Node in get_tree().root.find_children("*", "", true, false):
				if n is RetroTV:
					_tv = n
					break
		_log("wii=%s remote=%s tv=%s" % [_wii != null, _remote != null, _tv != null])
		if _wii == null or _remote == null or _tv == null:
			if _t > 25.0:
				_log("FAILED: room never produced the objects")
				get_tree().quit(1)
			return
		_stage = "setup"

	# ── 2. plant the bar, aim the remote, switch on ───────────────────────────
	func _setup() -> void:
		# _setup awaits, so _process would re-enter it several times over before
		# the stage flips. One bar, one pairing, one power-on.
		if _busy:
			return
		_busy = true
		# An exported Android build gets no user args at all, so on the headset the
		# switches come from a file instead — one per line, pushed with
		#   adb shell "run-as com.xenu.retroxr sh -c 'echo --mode=perf > files/probe_args.txt'"
		var args: Array[String] = []
		args.assign(OS.get_cmdline_user_args())
		if FileAccess.file_exists("user://probe_args.txt"):
			for line: String in FileAccess.open("user://probe_args.txt",
					FileAccess.READ).get_as_text().split("\n"):
				if not line.strip_edges().is_empty():
					args.append(line.strip_edges())
		_log("args: %s" % [args])
		for arg: String in args:
			if arg.begins_with("--dist="):
				_dist = float(arg.trim_prefix("--dist="))
			if arg.begins_with("--barscale="):
				_barscale = float(arg.trim_prefix("--barscale="))
			if arg.begins_with("--mode="):
				_mode = arg.trim_prefix("--mode=")
			if arg == "--below":
				_below = true
		# Nail the set down. It is an unfrozen RigidBody, and a sensor bar dropped in
		# next to it shoves it across the room — after which every measurement below
		# is taken against a television that is no longer where it was measured from.
		(_tv as RigidBody3D).freeze = true
		(_wii as RigidBody3D).freeze = true
		var link: WiiLink = (_wii as RetroSystem).get_wii_link()
		_log("wii_link=%s  disc=%s" % [link != null, (_wii as RetroSystem).get_snapped_cartridge()])

		_bar = load("res://Scenes/Objects/system_models/wii/sensor_bar.tscn").instantiate()
		get_tree().current_scene.add_child(_bar)
		_bar.add_to_group("spawned")
		await get_tree().process_frame
		await get_tree().process_frame

		# On top of the set, centred on the glass, facing the room. World size, not
		# the mesh's own: the television carries a scale_factor and get_aabb() is
		# local, so a scaled set would otherwise get its bar planted inside itself.
		var screen: MeshInstance3D = (_tv as RetroTV).get_screen_mesh()
		var st := screen.global_transform
		var sc := st.basis.get_scale()
		var h: float = screen.get_aabb().size.y * sc.y
		var w: float = screen.get_aabb().size.x * sc.x
		var pos: Vector3 = st.origin + st.basis.y.normalized() * (h * 0.5 + 0.04 * _barscale) \
			+ st.basis.z.normalized() * 0.02
		(_bar as Node3D).global_transform = Transform3D(
			st.basis.orthonormalized().rotated(st.basis.y.normalized(), PI).scaled(
				Vector3.ONE * _barscale), pos)
		(_bar as RigidBody3D).freeze = true
		_log("bar planted at %v, %.3f m %s centre (glass %.3f x %.3f m)"
			% [pos, (pos - st.origin).length(), "BELOW" if _below else "above", w, h])

		# A saved room may have no disc in the tray — the Quest's does not. Put one
		# in, so the same probe runs on either machine.
		if (_wii as RetroSystem).get_snapped_cartridge() == null:
			var roms := "/sdcard/Android/data/com.xenu.retroxr/files/roms/wii" \
				if OS.get_name() == "Android" \
				else OS.get_environment("USERPROFILE").replace("\\", "/") + "/retroxr/roms/wii"
			var rom := roms + "/Wii Sports (USA) (Rev 1).rvz"
			var disc := load("res://Scenes/Objects/media/disc.tscn").instantiate() as RetroCartridge
			disc.rom_path = rom
			disc.game_label = "Wii Sports"
			disc.systemid = "wii"
			get_tree().current_scene.add_child(disc)
			disc.add_to_group("spawned")
			await get_tree().process_frame
			var slot := _wii.get_node("CartridgeSlot") as XRToolsSnapZone
			slot.pick_up_object(disc)
			await get_tree().process_frame
			_log("disc inserted: %s (exists=%s)" % [rom, FileAccess.file_exists(rom)])

		var port: XRToolsSnapZone = link.get_sensor_bar_port()
		port.pick_up_object(_bar.get_plug())
		await get_tree().process_frame
		_log("bar system=%s lit=%s" % [_bar.get_system(), _bar.is_lit()])

		if int(_remote.get("_port_index")) < 0:
			_log("remote unpaired; pairing -> slot %d" % link.pair(_remote))
		else:
			_log("remote already on slot %d" % int(_remote.get("_port_index")))

		_screen_centre = st.origin
		_aim_at(st.origin, _dist)
		(_remote as RigidBody3D).freeze = true

		(_wii as RetroSystem).power_on()
		_log("powered on; waiting for the disc to boot")
		_t = 0.0
		_stage = "boot"

	## Park the remote `dist` in front of the screen and point its barrel at
	## `target`. Unheld on purpose: _camera_pose uses the barrel whether or not a
	## hand is on it, so the pose IS the aim.
	func _aim_at(target: Vector3, dist: float) -> void:
		var screen: MeshInstance3D = (_tv as RetroTV).get_screen_mesh()
		var st := screen.global_transform
		var eye: Vector3 = st.origin + st.basis.z.normalized() * dist
		(_remote as Node3D).global_transform = Transform3D(Basis(), eye).looking_at(
			target, Vector3.UP)

	# ── 3. hold A+B past the health screen and the title ──────────────────────
	func _boot(_delta: float) -> void:
		var lib: Libretro = (_wii as RetroSystem).get_libretro_node()
		if lib == null:
			return
		var port := int(_remote.get("_port_index"))
		# After the remote's own _process (priority 100), so this wins the frame.
		# Pulsed rather than held: Wii Sports wants presses, not a stuck button.
		if _t > 12.0 and fmod(_t, 1.0) < 0.25:
			lib.SetJoypadState(port, (1 << JOYPAD_A) | (1 << JOYPAD_B), 0, 0, 0, 0)
		if _t > 45.0 and _mode == "perf":
			_stage = "perf"
			_t = 0.0
			return
		if _t > 45.0:
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
			var screen: MeshInstance3D = (_tv as RetroTV).get_screen_mesh()
			var c := screen.global_transform.origin
			var up := screen.global_transform.basis.y.normalized()
			var right := screen.global_transform.basis.x.normalized()
			var sc := screen.global_transform.basis.get_scale()
			var w: float = screen.get_aabb().size.x * sc.x
			var h: float = screen.get_aabb().size.y * sc.y
			if _mode == "barheight":
				# Aim never moves. The BAR climbs, so the only thing changing is how
				# far above the aim axis the lights sit — which is the one number the
				# Wii has to guess at, and the one this is here to measure.
				_shots = []
				for mm: int in [20, 60, 100, 140, 180]:
					_shots.append(["bar%03dmm" % mm, c + up * (float(mm) / 1000.0)])
			else:
				_shots = [
					["centre", c],
					["left",   c - right * w * 0.30],
					["right",  c + right * w * 0.30],
					["top",    c + up * h * 0.30],
					["bottom", c - up * h * 0.30],
				]
			_t = 0.0
			_stage = "shoot"

	# ── 4a. how fast is it actually emulating? ────────────────────────────────
	#
	# GetFrameCount is one per retro_run, so frames per wall-clock second IS the
	# emulation speed. Wii Sports is 60 Hz: 60 means full speed, and anything
	# under it is where the audio crackle comes from — a starved buffer is just
	# "below 100%" wearing a different hat.
	var _perf_t := 0.0
	var _perf_frames := -1
	var _perf_window := 0

	func _perf(delta: float) -> void:
		var lib: Libretro = (_wii as RetroSystem).get_libretro_node()
		if lib == null:
			return
		if _perf_frames < 0:
			_perf_frames = int(lib.GetFrameCount())
			_perf_t = 0.0
			return
		_perf_t += delta
		if _perf_t < 5.0:
			return
		var now := int(lib.GetFrameCount())
		var fps := float(now - _perf_frames) / _perf_t
		_log("PERF emulated %5.1f fps (%3.0f%% of 60)  |  godot %4.1f fps"
			% [fps, fps / 60.0 * 100.0, Engine.get_frames_per_second()])
		_perf_frames = now
		_perf_t = 0.0
		_perf_window += 1
		if _perf_window >= 6:
			_log("done")
			get_tree().quit(0)


	# ── 4b. sweep and photograph ──────────────────────────────────────────────
	func _shoot(delta: float) -> void:
		_shot_t += delta
		if _shot >= _shots.size():
			_log("done")
			get_tree().quit(0)
			return
		var entry: Array = _shots[_shot]
		if _applied != _shot:
			_applied = _shot
			if _mode == "barheight":
				(_bar as Node3D).global_position = entry[1] as Vector3
				_aim_at(_screen_centre, _dist)
			else:
				_aim_at(entry[1] as Vector3, _dist)
			_log("%s -> %s" % ["bar to" if _mode == "barheight" else "aiming at", entry[0]])
		if _shot_t > 2.0:
			_grab(str(entry[0]))
			_shot += 1
			_shot_t = 0.0

	func _grab(label: String) -> void:
		var screen: MeshInstance3D = (_tv as RetroTV).get_screen_mesh()
		var mat: Material = screen.get_surface_override_material(0)
		var tex := _extract(mat)
		if tex == null:
			_log("%s: no texture on the screen material (%s)" % [label, mat])
			return
		var img := tex.get_image()
		if img == null:
			_log("%s: texture had no image" % label)
			return
		img.save_png("%s/%s.png" % [OUT, label])
		var leds: Array = _bar.led_positions()
		var sep := 0.0
		if leds.size() >= 2:
			sep = (leds[0] as Vector3).distance_to(leds[1] as Vector3)
		var rem := (_remote as Node3D).global_position
		var scr: Vector3 = (_tv as RetroTV).get_screen_mesh().global_position
		_log("captured %s  lit=%s  led_sep=%.4f m  bar=%v  remote=%v  screen=%v  bar->remote=%.3f m"
			% [label, _bar.is_lit(), sep, (_bar as Node3D).global_position, rem, scr,
			   rem.distance_to((_bar as Node3D).global_position)])

	func _extract(mat: Material) -> Texture2D:
		if mat is StandardMaterial3D:
			var std := mat as StandardMaterial3D
			return std.emission_texture if std.emission_texture != null else std.albedo_texture
		if mat is ShaderMaterial:
			var sm := mat as ShaderMaterial
			var t: Variant = sm.get_shader_parameter("video_tex")
			if t == null:
				t = sm.get_shader_parameter("source_tex")
			return t as Texture2D
		return null

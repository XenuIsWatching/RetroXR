## power_on_stall_probe -- what the frame spike at a core's first power-on is.
##
## Ships as its own package (QuestPowerOnProbe preset, custom feature
## "poweronprobe") so the installed RetroXR is never disturbed. Read it with:
##   adb logcat -s 'godot:*'
##
## The measurement is a per-frame delta table with markers, plus the split that
## actually names a culprit: Godot's TIME_PROCESS monitor is main-thread script
## and node _process time, so a spike that shows up THERE is GDScript or the
## Libretro node's queue drain (a zip extract, an ImageTexture alloc), and a
## spike that does NOT is the renderer -- a first-draw pipeline compile.
##
## Three trials in one process, because the difference between them is the
## experiment:
##   1. cold      -- first power-on of the process
##   2. again     -- power off, power on the same machine
##   3. second    -- a SECOND machine, same core, first power-on for it
## and a fourth as a separate run: --warm draws the screen shaders through an
## offscreen viewport before trial 1.
## If the stall is a pipeline compile it is large in 1, gone in 2 and 3, and
## gone in 1 under --warm. If it is per-start work it survives into 2 and 3.
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")
const CRT_SHADER := preload("res://Shaders/crt_effect.gdshader")
const PHOSPHOR_SHADER := preload("res://Shaders/phosphor_decay.gdshader")

## Frames recorded after each marker.
const WINDOW := 240
## Let the room, the model warmer and the XR session settle before trial 1, so
## nothing measured here is really boot cost.
const SETTLE_FRAMES := 420
## A frame worth printing. One 72 Hz period is 13.9 ms; this is two of them.
const SPIKE_MS := 28.0

var core := "mgba"
var systemid := "game_boy_advance"
var rom := ""
var warm := false
var use_tv := true
## Load the real bedroom as room content. An empty probe room is not the load
## the stutter is reported under -- the room brings the lights, the furniture
## and the GPU cost that a compile stall has to compete with.
var use_room := false

var _t_prev := 0
var _deltas: PackedFloat32Array = PackedFloat32Array()
var _proc_ms: PackedFloat32Array = PackedFloat32Array()
var _frame := 0
## frame index -> label, printed beside the table.
var _marks := {}
var _origin: XROrigin3D = null

## The mesh whose material should start carrying a picture, and the frame it
## first did. Without this the whole measurement is unfalsifiable: a machine
## whose model failed to load draws nothing, compiles nothing, and reports a
## beautifully quiet frame table.
var _watch_mesh: MeshInstance3D = null
var _first_pic_frame := -1
var _fail := false
## The machine whose picture the glass is supposed to be showing. The oracle is
## IDENTITY against this node's own GetVideoTexture(), not brightness: a set
## with no signal paints its own blue screen, which is bright, constant, and
## passes every luminance threshold you would think to write. Three runs here
## reported a luminance of exactly 0.694 -- a GBA game and a BIOS screen cannot
## both be that -- which is how the blue screen was caught masquerading as a
## picture.
var _watch_sys: RetroSystem = null


func _ready() -> void:
	_parse_args()
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[stall] TIMEOUT")
		get_tree().quit(1))
	_start_xr()
	_t_prev = Time.get_ticks_usec()
	_run()


func _parse_args() -> void:
	# An exported build gets no user args (see quest-probe-as-separate-package),
	# so the on-device switches come from a file the pusher writes.
	var cfg := "user://poweron_probe.cfg"
	var lines: PackedStringArray = PackedStringArray()
	if FileAccess.file_exists(cfg):
		lines = FileAccess.get_file_as_string(cfg).split("\n", false)
	for a: String in OS.get_cmdline_user_args():
		lines.append(a)
	for arg: String in lines:
		var s := arg.strip_edges()
		if s.begins_with("--core="):
			core = s.trim_prefix("--core=")
		elif s.begins_with("--systemid="):
			systemid = s.trim_prefix("--systemid=")
		elif s.begins_with("--rom="):
			rom = s.trim_prefix("--rom=")
		elif s == "--warm":
			warm = true
		elif s == "--no-tv":
			use_tv = false
		elif s == "--room":
			use_room = true
	print("[stall] cfg core=%s systemid=%s warm=%s tv=%s room=%s rom=%s"
		% [core, systemid, warm, use_tv, use_room, rom])


func _start_xr() -> void:
	var xri: XRInterface = XRServer.find_interface("OpenXR")
	var ok: bool = xri != null and xri.is_initialized()
	print("[stall] OpenXR initialized=%s" % ok)
	if ok:
		xri.set_play_area_mode(XRInterface.XR_PLAY_AREA_ROOMSCALE)
		get_viewport().use_xr = true
	# A camera either way, so a desktop run of this probe still renders.
	_origin = XROrigin3D.new()
	add_child(_origin)
	var cam := XRCamera3D.new()
	cam.current = true
	_origin.add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -30, 0)
	add_child(light)


func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	_deltas.append(float(now - _t_prev) / 1000.0)
	_proc_ms.append(float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0)
	_t_prev = now
	_frame += 1
	# Polled every frame rather than awaited, so the frame the picture lands on
	# is the frame recorded -- that is the one a compile stall would sit in.
	if _first_pic_frame < 0 and _core_picture_is_on_glass():
		_first_pic_frame = _frame
		_mark("first picture")


## Is the texture on the glass THE core's texture? Anything else -- the set's
## blue screen, a stale frame from a previous run -- is not a picture.
func _core_picture_is_on_glass() -> bool:
	if _watch_sys == null or not is_instance_valid(_watch_sys):
		return false
	var lib: Libretro = _watch_sys.get_libretro_node()
	if lib == null:
		return false
	var core_tex: Texture2D = lib.GetVideoTexture()
	if core_tex == null:
		return false
	return _picture_texture() == core_tex


## The core's texture as it reaches the glass, whichever material is on it.
func _picture_texture() -> Texture2D:
	if _watch_mesh == null or not is_instance_valid(_watch_mesh):
		return null
	var mat := _watch_mesh.get_surface_override_material(0)
	if mat is ShaderMaterial:
		return (mat as ShaderMaterial).get_shader_parameter("source_tex") as Texture2D
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).get_texture(BaseMaterial3D.TEXTURE_EMISSION)
	return null


## Mean channel value over a coarse grid -- enough to tell a live picture from
## a black panel, which is all this needs to decide the run was valid.
func _luminance() -> float:
	var tex := _picture_texture()
	if tex == null:
		return -1.0
	var img := tex.get_image()
	if img == null:
		return -1.0
	var total := 0.0
	var n := 0
	for y in range(0, img.get_height(), maxi(1, img.get_height() / 8)):
		for x in range(0, img.get_width(), maxi(1, img.get_width() / 8)):
			var c := img.get_pixel(x, y)
			total += c.r + c.g + c.b
			n += 1
	return total / maxi(n, 1)


func _mark(label: String) -> void:
	_marks[_frame] = label


func _wait(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## The table for one trial, plus the one number that matters: the worst frame.
func _report(trial: String, from: int) -> void:
	var to: int = mini(_frame, from + WINDOW)
	var worst := 0.0
	var worst_at := -1
	var worst_proc := 0.0
	var over := 0
	var total := 0.0
	for i in range(from, to):
		var d: float = _deltas[i]
		total += d
		if d > SPIKE_MS:
			over += 1
		if d > worst:
			worst = d
			worst_at = i
			worst_proc = _proc_ms[i]
	print("[stall] --- %s: %d frames, %.0f ms wall, worst %.1f ms at f%d "
		% [trial, to - from, total, worst, worst_at]
		+ "(script %.1f ms of it), %d frames over %.0f ms"
		% [worst_proc, over, SPIKE_MS])
	# The validity line. A run whose picture never arrived measured an idle room.
	var lum := _luminance()
	var pic_at: String = "NEVER" if _first_pic_frame < 0 \
		else "f%d (+%d frames after power_on)" % [_first_pic_frame, _first_pic_frame - from]
	print("[stall]     core picture on glass: %s  luminance %.3f  (still the core's own: %s)"
		% [pic_at, lum, _core_picture_is_on_glass()])
	if _first_pic_frame < 0 or lum < 0.02:
		_fail = true
		print("[stall]     INVALID: the core's texture never reached the glass "
			+ "in this trial -- the set was painting something of its own")
	elif _first_pic_frame >= from and _first_pic_frame < to:
		print("[stall]     frame the picture landed on: %.1f ms (script %.1f ms)"
			% [_deltas[_first_pic_frame], _proc_ms[_first_pic_frame]])
	# Every frame that missed a 72 Hz vsync by more than one period, with its
	# script share, so a render-side stall is visible as a big delta over a
	# small script time.
	for i in range(from, to):
		if _deltas[i] < SPIKE_MS:
			continue
		var tag: String = str(_marks.get(i, ""))
		print("[stall]     f%-5d %8.1f ms   script %6.1f ms  %s"
			% [i, _deltas[i], _proc_ms[i], tag])
	for f: int in _marks:
		if f >= from and f < to:
			print("[stall]     mark f%-5d %s" % [f, _marks[f]])


## Which mesh this trial expects a picture on: the set's glass when one is
## connected, otherwise the handheld's own panel. Reported either way, so a
## model that failed to load is named rather than measured.
func _watch(sys: RetroSystem, tv: RetroTV) -> void:
	_first_pic_frame = -1
	_watch_sys = sys
	if use_tv and tv != null:
		_watch_mesh = tv.get_screen_mesh()
	else:
		var model: RetroSystemModel = sys._model
		_watch_mesh = model.get_builtin_screen() if model != null else null
	print("[stall] watching %s" % ("<nothing -- no screen mesh>" if _watch_mesh == null
		else _watch_mesh.get_path()))
	if _watch_mesh == null:
		_fail = true


func _make_system() -> RetroSystem:
	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = systemid
	sys.core_name = core
	sys.rom_path = rom
	add_child(sys)
	return sys


## Draw the screen shaders through a throwaway viewport, the way ModelWarmer
## warms a model. This is the candidate FIX as much as the control: if trial 1
## goes quiet under --warm, the stall was a first-draw pipeline compile.
func _warm_screen_shaders() -> void:
	var t0 := Time.get_ticks_usec()
	var sv := SubViewport.new()
	sv.size = Vector2i(64, 64)
	sv.render_target_update_mode = SubViewport.UPDATE_ONCE
	sv.transparent_bg = true
	add_child(sv)
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.4, 0.8))
	var tex := ImageTexture.create_from_image(img)
	# The phosphor pass really is a ColorRect in a viewport, so warm it as one.
	var rect := ColorRect.new()
	rect.size = Vector2(64, 64)
	var pm := ShaderMaterial.new()
	pm.shader = PHOSPHOR_SHADER
	pm.set_shader_parameter("src", tex)
	pm.set_shader_parameter("prev", tex)
	pm.set_shader_parameter("decay", Vector3(0.5, 0.4, 0.3))
	rect.material = pm
	sv.add_child(rect)
	# The CRT stage reaches the glass as a surface override on a mesh, and a
	# canvas-item pipeline is not the same pipeline -- so warm it on a quad.
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	var cm := ShaderMaterial.new()
	cm.shader = CRT_SHADER
	cm.set_shader_parameter("source_tex", tex)
	quad.set_surface_override_material(0, cm)
	quad.position = Vector3(0, 0, -1.5)
	_origin.add_child(quad)
	await _wait(6)
	sv.queue_free()
	quad.queue_free()
	print("[stall] warm_screen_shaders took %.1f ms"
		% (float(Time.get_ticks_usec() - t0) / 1000.0))


func _run() -> void:
	if use_room:
		var t_room := Time.get_ticks_usec()
		var room: Node = load("res://Scenes/BedroomScene.tscn").instantiate()
		add_child(room)
		print("[stall] bedroom loaded in %.0f ms"
			% (float(Time.get_ticks_usec() - t_room) / 1000.0))
		await _wait(120)

	print("[stall] settling %d frames" % SETTLE_FRAMES)
	await _wait(SETTLE_FRAMES)
	print("[stall] steady state before trial 1: %.1f fps"
		% Performance.get_monitor(Performance.TIME_FPS))

	if warm:
		_mark("warm start")
		await _warm_screen_shaders()
		await _wait(30)

	var tv: RetroTV = null
	if use_tv:
		tv = TV_SCENE.instantiate() as RetroTV
		add_child(tv)
		await _wait(60)

	# -- trial 1: cold --------------------------------------------------------
	var sys := _make_system()
	await _wait(90)
	if use_tv and tv != null:
		sys.on_tv_connected(tv)
		await _wait(30)
	_watch(sys, tv)
	var base := _frame
	_mark("power_on #1 (cold)")
	var t0 := Time.get_ticks_usec()
	sys.power_on()
	var call_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("[stall] power_on() call itself: %.1f ms  (powered=%s)"
		% [call_ms, sys.is_powered_on])
	await _wait(WINDOW)
	_report("trial 1 cold", base)

	# -- trial 2: same machine, off then on -----------------------------------
	sys.power_off()
	await _wait(120)
	_first_pic_frame = -1
	base = _frame
	_mark("power_on #2 (same machine again)")
	t0 = Time.get_ticks_usec()
	sys.power_on()
	call_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	print("[stall] power_on() call itself: %.1f ms" % call_ms)
	await _wait(WINDOW)
	_report("trial 2 again", base)
	sys.power_off()
	await _wait(60)

	# -- trial 3: a second machine's own first power-on -----------------------
	var sys2 := _make_system()
	await _wait(90)
	if use_tv and tv != null:
		sys2.on_tv_connected(tv)
		await _wait(30)
	_watch(sys2, tv)
	_first_pic_frame = -1
	base = _frame
	_mark("power_on #3 (second machine)")
	t0 = Time.get_ticks_usec()
	sys2.power_on()
	call_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	print("[stall] power_on() call itself: %.1f ms" % call_ms)
	await _wait(WINDOW)
	_report("trial 3 second machine", base)

	print("[stall] RESULT=%s" % ("INVALID" if _fail else "VALID"))
	print("[stall] DONE")
	await _wait(30)
	get_tree().quit(1 if _fail else 0)

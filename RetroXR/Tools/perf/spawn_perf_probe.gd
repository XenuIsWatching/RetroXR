## Times a spawn on the device it actually feels slow on.
##
## Desktop numbers were misleading: there the whole cabinet lands in 90-320 ms,
## while on Quest a stand-in reportedly takes seconds. Storage is far slower here
## and the CPU several times slower, and pipeline compilation on the mobile
## backend is a different animal — those need opposite fixes, so they get split
## apart per phase and per repeat rather than guessed at.
##
## Ships as its own package (see the QuestSpawnProbe preset) so the installed
## RetroXR is never touched.
extends Node3D

## [model_id, systemid]
const CASES := [
	["n3ds_primitive", "3ds"],
	["game_boy_primitive", "game_boy"],
	["placeholder", "playstation2"],
	["virtual_boy_primitive", "virtual_boy"],
]
const REPEATS := 3

var _frames := 0
var _alive := 0.0


func _us() -> int: return Time.get_ticks_usec()
func _ms(a: int) -> float: return float(_us() - a) / 1000.0


func _process(delta: float) -> void:
	# Heartbeat: tells "process died" apart from "process running, not ticking".
	_frames += 1
	_alive += delta
	if _frames % 120 == 0:
		print("[perf] alive t=%.1f frames=%d" % [_alive, _frames])


func _ready() -> void:
	get_tree().create_timer(600.0).timeout.connect(func() -> void:
		print("[perf] TIMEOUT")
		get_tree().quit(1))
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.25, 0.6)
	cam.rotation_degrees = Vector3(-18, 0, 0)
	add_child(cam)
	cam.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, 25, 0)
	add_child(light)
	await _run()
	get_tree().quit(0)


## Does warming a model somewhere OTHER than the main pass actually pre-compile
## the pipelines the main pass needs? On Quest the main pass is MULTIVIEW stereo,
## so a variant compiled for a plain SubViewport may not be the one it wants — in
## which case the 2 s is paid again at real spawn time and pre-warming buys
## nothing. Mode comes from user://warmmode.cfg so the same build can be run cold
## and warm in FRESH processes; comparing within one process is useless because
## the first spawn warms everything the second would have measured.
const WARM_MODEL := "n3ds_primitive"
const WARM_SYSTEM := "3ds"


func _warm_mode() -> String:
	var f := FileAccess.open("user://warmmode.cfg", FileAccess.READ)
	if f == null:
		return "none"
	return f.get_as_text().strip_edges()


func _run() -> void:
	print("[perf] device=%s renderer=%s" % [OS.get_name(), RenderingServer.get_video_adapter_name()])
	var mode := _warm_mode()
	print("[perf] warm mode = %s" % mode)
	if mode == "sweep":
		await _full_sweep()
		return
	if mode == "all":
		await _preload_all()
		return
	if mode != "none":
		await _warm(mode)
	# Let the startup warm finish first. Without this the probe races it and times
	# a half-warmed process — which is exactly what happened the first time.
	var waited := 0
	while not ModelWarmer.is_warmed() and waited < 900:
		await get_tree().process_frame
		waited += 1
	print("[perf] startup warm complete = %s (waited %d frames)"
		% [ModelWarmer.is_warmed(), waited])
	# The measurement: the SAME model, now spawned into the real (stereo) view.
	print("[perf] %-22s %-5s %8s %8s %8s %8s %9s" %
		["case", "pass", "load", "inst", "ready", "draw", "TOTAL"])
	for pass_i in 2:
		await _one([WARM_MODEL, WARM_SYSTEM], pass_i)
	print("[perf] DONE")


## Instantiate the model and get it drawn once, then throw it away. "sv" draws it
## in an offscreen SubViewport; "main" draws it in the real world behind the
## camera, which is the fallback if the SubViewport variant does not transfer.
func _warm(mode: String) -> void:
	var t := _us()
	var row := SystemModelRegistry._row(WARM_MODEL)
	var model: RetroSystemModel = SystemModelRegistry.instantiate(row)
	if model == null:
		print("[perf] warm FAILED to instantiate")
		return
	var host: Node = self
	var sv: SubViewport = null
	if mode == "sv":
		sv = SubViewport.new()
		sv.size = Vector2i(256, 256)
		sv.own_world_3d = true
		sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(sv)
		var wcam := Camera3D.new()
		wcam.position = Vector3(0, 0.1, 0.35)
		sv.add_child(wcam)
		wcam.current = true
		sv.add_child(DirectionalLight3D.new())
		host = sv
	host.add_child(model)
	if mode == "main":
		model.position = Vector3(0, 0, 4.0)      # behind the camera, still drawn
	for i in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	model.queue_free()
	if sv != null:
		await get_tree().process_frame
		sv.queue_free()
	for i in 5:
		await get_tree().process_frame
	print("[perf] warm(%s) took %.1f ms" % [mode, _ms(t)])


## Every model, three passes each — the survey that found the first-spawn cliff.
func _full_sweep() -> void:
	print("[perf] %-22s %-5s %8s %8s %8s %8s %9s" %
		["case", "pass", "load", "inst", "ready", "draw", "TOTAL"])
	for c: Array in CASES:
		for pass_i in REPEATS:
			await _one(c, pass_i)
	print("[perf] DONE")


func _one(c: Array, pass_i: int) -> void:
	var row := SystemModelRegistry._row(c[0] as String) if c[0] != "placeholder" \
		else SystemModelRegistry.placeholder_row()
	var path: String = row.get("scene", "")

	var t := _us()
	if not path.is_empty():
		SystemModelRegistry.packed_scene(path)
	var t_load := _ms(t)

	t = _us()
	var sys := load("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	sys.systemid = c[1]
	sys.model_id = c[0]
	var t_inst := _ms(t)

	t = _us()
	add_child(sys)
	sys.freeze = true
	sys.ignore_gravity = true
	sys.position = Vector3(0, 0, 0)
	var t_ready := _ms(t)

	t = _us()
	await RenderingServer.frame_post_draw
	var t_draw := _ms(t)

	print("[perf] %-22s %-5d %7.1f %7.1f %7.1f %7.1f %8.1f" %
		[c[0], pass_i + 1, t_load, t_inst, t_ready, t_draw,
			t_load + t_inst + t_ready + t_draw])
	for i in 5:
		await get_tree().process_frame
	sys.queue_free()
	for i in 5:
		await get_tree().process_frame


## What warming EVERY model costs, in seconds and in bytes. Both matter: the time
## has to fit behind a loading screen, and the memory has to fit on a Quest, which
## is the reason to scope a pre-warm rather than just doing all of it.
func _preload_all() -> void:
	var mem0: float = Performance.get_monitor(Performance.MEMORY_STATIC)
	var tex0: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	var t_all := _us()

	var sv := SubViewport.new()
	sv.size = Vector2i(256, 256)
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.1, 0.35)
	sv.add_child(cam)
	cam.current = true
	sv.add_child(DirectionalLight3D.new())

	var n := 0
	var slowest := 0.0
	var slowest_id := ""
	for id: String in SystemModelRegistry.all_ids():
		if not SystemModelRegistry.is_available(id):
			print("[perf] skip %s (assets absent)" % id)
			continue
		var t := _us()
		var model: RetroSystemModel = SystemModelRegistry.instantiate(
			SystemModelRegistry._row(id))
		if model == null:
			continue
		sv.add_child(model)
		for i in 4:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		model.queue_free()
		await get_tree().process_frame
		var dt := _ms(t)
		n += 1
		if dt > slowest:
			slowest = dt
			slowest_id = id
		print("[perf] warm %-32s %7.1f ms" % [id, dt])

	sv.queue_free()
	await get_tree().process_frame
	var mem1: float = Performance.get_monitor(Performance.MEMORY_STATIC)
	var tex1: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	print("[perf] ---- %d models warmed in %.2f s ----" % [n, _ms(t_all) / 1000.0])
	print("[perf] slowest: %s at %.1f ms" % [slowest_id, slowest])
	print("[perf] static memory  %.1f -> %.1f MiB  (+%.1f)"
		% [mem0 / 1048576.0, mem1 / 1048576.0, (mem1 - mem0) / 1048576.0])
	print("[perf] texture memory %.1f -> %.1f MiB  (+%.1f)"
		% [tex0 / 1048576.0, tex1 / 1048576.0, (tex1 - tex0) / 1048576.0])
	print("[perf] DONE")

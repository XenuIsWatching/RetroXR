## ModelWarmer — pays a model's first-spawn cost up front, where nobody is looking.
##
## Spawning a model the first time in a session is expensive on Quest and cheap
## every time after. Measured on a Quest 3, the 3DS stand-in: 3949 ms the first
## time, 85 ms the second. The cost is three one-off things — parsing the scene,
## the model's own _ready, and compiling its pipelines on first draw — and all
## three are paid by simply instantiating the model and letting it be drawn once.
##
## Drawing it in a 256x256 offscreen SubViewport is enough: the pipelines it
## compiles are the ones the main STEREO pass wants, which was not obvious and had
## to be measured (176 ms afterwards against 184 ms for warming in the real world,
## versus 2621 ms cold). So nothing is ever placed where a player could see it.
##
## The stand-ins are warmed by instantiating and drawing them, above. The imported
## shells load their GLB threaded first — a plain load() of the NES GLB blocked
## the Quest 3 main thread for 6.9 s — and are then drawn once like the stand-ins,
## because the draw has its own cost (the Atari's first draw is 266 ms of shader
## compile on-device). See warm_shells().
##
## Everything that needs a shell asset goes through acquire(): a coroutine that
## joins the in-flight threaded load instead of blocking on it. A menu spawn or a
## slot restore racing the warm previously fell into a synchronous load() that
## WAITED for the whole threaded load — the "spawning an NES freezes the game"
## bug, second edition.
##
## They were once left out entirely, as "1.1 GiB of texture memory between them,
## which a Quest cannot spare". Measured on-device that is ~6 MiB for the NES; the
## gigabyte was the reflection atlas, unrelated to any model.
##
## The instances are thrown away. What persists is _held's grip on each Resource —
## without that the scene is dropped and re-parsed on the next spawn — plus the
## compiled pipelines in the renderer's own cache.
class_name ModelWarmer
extends RefCounted

## Set when warming BEGINS, so a second caller does not start a parallel pass.
static var _started := false
## Set when it ENDS. These have to be separate: a caller that wants to know the
## models are ready (a probe timing a spawn, or anything gating on it) is asking
## about the second, and reading the reentry guard instead races the warm and
## measures a half-warmed process.
static var _finished := false

## Same pair for the shells, which warm separately — see warm_shells().
static var _shells_started := false
static var _shells_finished := false

## Every acquired shell asset, path -> Resource, held for the life of the
## process. This IS the warm: a model instantiates its GLB and keeps only the
## nodes, so the moment that model is freed the scene would leave the cache and
## the next spawn would pay the whole load again.
static var _held: Dictionary = {}

## Paths with a threaded load in flight. acquire() calls for the same path join
## this load instead of starting (or worse, BLOCKING on) a second one.
static var _pending: Dictionary = {}

## How far the current pass has got, for anything drawing a progress bar over it
## (LoadingOverlay). Counters rather than a signal because this class is entirely
## static and Godot 4 has no static signal; a reader polls three ints.
static var warm_done := 0
static var warm_total := 0
static var warm_phase := ""


## True once every stand-in has been warmed and thrown away.
static func is_warmed() -> bool:
	return _finished


static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## Fire the threaded request for a path unless it is already held, in flight, or
## cached. Costs the main thread nothing; acquire() collects the result.
static func _request(path: String) -> void:
	if path.is_empty() or _held.has(path) or _pending.has(path) \
			or ResourceLoader.has_cached(path):
		return
	if ResourceLoader.load_threaded_request(path) == OK:
		_pending[path] = true
	else:
		push_warning("[ModelWarmer] threaded request refused: " + path)


## Start every shell GLB loading in the background. Called first thing at boot,
## BEFORE the stand-in warm: these loads are what a spawn or a slot restore has
## to wait for, and starting them costs the main thread nothing.
static func request_shells() -> void:
	for path: String in SystemModelRegistry.shell_assets():
		_request(path)


## Coroutine. THE way to get a model asset: never blocks the main thread, joins
## an in-flight threaded load instead of starting a second one, and keeps the
## result referenced for the life of the process. Returns null on a failed load.
##
## A plain load() of a path that a threaded load is already pulling in does not
## come back early — it waits for the whole threaded load, on the main thread.
## Measured 6.9 s for the NES GLB on a Quest 3. Anything that might touch a
## shell asset before the warm has finished awaits this instead.
static func acquire(path: String) -> Resource:
	if _held.has(path):
		return _held[path]
	if _pending.has(path):
		return await _finish_pending(path)
	if ResourceLoader.has_cached(path):
		var res := load(path)
		if res != null:
			_held[path] = res
		return res
	_request(path)
	if not _pending.has(path):
		return null
	return await _finish_pending(path)


## Poll an in-flight load a frame at a time. Any number of callers may await the
## same path: whichever resumes first takes the resource and clears the pending
## flag, the rest fall out of the loop and read _held.
static func _finish_pending(path: String) -> Resource:
	var tree := _tree()
	while _pending.has(path):
		match ResourceLoader.load_threaded_get_status(path):
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				await tree.process_frame
			ResourceLoader.THREAD_LOAD_LOADED:
				var res := ResourceLoader.load_threaded_get(path)
				if res != null:
					_held[path] = res
				_pending.erase(path)
			_:
				push_warning("[ModelWarmer] asset failed to load: " + path)
				_pending.erase(path)
	var out: Resource = _held.get(path)
	return out


## Coroutine. `host` only needs to be in the tree — the warming viewport is
## parented to it and removed again.
static func warm_stand_ins(host: Node) -> void:
	if _started or host == null or not host.is_inside_tree():
		return
	_started = true
	var tree := host.get_tree()

	var ids: Array[String] = []
	for id: String in SystemModelRegistry.stand_in_ids():
		if SystemModelRegistry.is_available(id):
			ids.append(id)
	# The scene parses (~30 ms each on-device) ride the loader threads while the
	# first models draw; by the time the loop reaches a scene it is usually held.
	for id: String in ids:
		var scene_path: String = SystemModelRegistry.row_for(id).get("scene", "")
		_request(scene_path)

	var sv := _make_warm_viewport(host)
	var t := Time.get_ticks_usec()
	var mem0: float = Performance.get_monitor(Performance.MEMORY_STATIC)
	var tex0: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	var n := 0
	warm_phase = "stand-ins"
	warm_total = ids.size()
	warm_done = 0
	for id: String in ids:
		var scene_path: String = SystemModelRegistry.row_for(id).get("scene", "")
		if not scene_path.is_empty():
			await acquire(scene_path)
		if not is_instance_valid(host) or not host.is_inside_tree():
			return
		if await _draw_once(sv, tree, id):
			n += 1
		warm_done += 1

	sv.queue_free()
	await tree.process_frame
	_finished = true
	# Reported, not assumed: what this costs to KEEP is the reason it is limited to
	# the stand-ins, so the figure belongs in the log next to the time.
	print("[ModelWarmer] %d stand-ins warmed in %.2f s  (+%.1f MiB static, +%.1f MiB texture)"
		% [n, float(Time.get_ticks_usec() - t) / 1000000.0,
			(Performance.get_monitor(Performance.MEMORY_STATIC) - mem0) / 1048576.0,
			(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) - tex0) / 1048576.0])


static func _make_warm_viewport(host: Node) -> SubViewport:
	var sv := SubViewport.new()
	sv.name = "ModelWarmViewport"
	sv.size = Vector2i(256, 256)
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.add_child(sv)
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 0.1, 0.35)
	sv.add_child(cam)
	cam.current = true
	sv.add_child(DirectionalLight3D.new())
	return sv


## Instantiate one registry row, let it draw a frame, throw it away. The draw is
## the point: first draw is where the renderer compiles this model's pipelines.
static func _draw_once(sv: SubViewport, tree: SceneTree, id: String) -> bool:
	var model: RetroSystemModel = SystemModelRegistry.instantiate(
		SystemModelRegistry.row_for(id))
	if model == null:
		return false
	sv.add_child(model)
	await tree.process_frame
	await RenderingServer.frame_post_draw
	model.queue_free()
	await tree.process_frame
	return true


## Pull each bespoke shell's GLB into the resource cache off the main thread,
## then pay each shell model's build-and-first-draw, offscreen.
##
## A shell's model loads its GLB with a plain load() inside _ready(), so that cost
## lands on whichever frame the player spawns one. Measured on a Quest 3 with
## Tools/perf/quest_spawn_probe.tscn: the NES shell took **6861 ms with not one frame
## drawn**, against 63-78 ms per spawn once cached. That is the freeze.
##
## Two things make this work:
##
##   * The reference is KEPT. A model keeps only the instantiated nodes, not the
##     PackedScene, so without _held the scene is dropped when that model is
##     freed and the next spawn pays the full load again.
##   * The load is THREADED, via acquire(). Warming these the way the stand-ins
##     are warmed would just move the same seven seconds into startup; loading on
##     the loader threads leaves the room drawing throughout.
##
## The draw pass at the end exists because the load is not the whole cost: with
## the GLB fully cached, the Atari's first draw still blocked 266 ms on-device
## compiling its materials' pipelines. Paid here, a spawn is ~70 ms.
##
## The shells were originally left out of warming as "1.1 GiB of texture memory
## between them, which a Quest cannot spare". That figure does not survive
## measurement — the NES shell costs ~6 MiB of texture on-device. The gigabyte was
## the reflection atlas, which is sized by project settings and had nothing to do
## with the shells (see rendering/reflections/reflection_atlas/reflection_count).
static func warm_shells(host: Node) -> void:
	if _shells_started or host == null or not host.is_inside_tree():
		return
	_shells_started = true
	var tree := host.get_tree()
	var t := Time.get_ticks_usec()
	var tex0: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)

	request_shells()
	var n := 0
	var assets: Array = SystemModelRegistry.shell_assets()
	warm_phase = "shell assets"
	warm_total = assets.size()
	warm_done = 0
	for path: String in assets:
		if await acquire(path) != null:
			n += 1
		warm_done += 1
	if not is_instance_valid(host) or not host.is_inside_tree():
		return

	var sv := _make_warm_viewport(host)
	var bespoke: Array = SystemModelRegistry.bespoke_ids()
	warm_phase = "shell draws"
	warm_total = bespoke.size()
	warm_done = 0
	for id: String in bespoke:
		await _draw_once(sv, tree, id)
		warm_done += 1
	sv.queue_free()
	await tree.process_frame

	_shells_finished = true
	print("[ModelWarmer] %d shells warmed in %.2f s  (+%.1f MiB texture)"
		% [n, float(Time.get_ticks_usec() - t) / 1000000.0,
			(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) - tex0) / 1048576.0])

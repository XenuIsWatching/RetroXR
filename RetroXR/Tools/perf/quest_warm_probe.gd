extends Node3D

## On-device boot-freeze profile — validates the acquire()-based model loading.
##
## Boots the real room and lets SceneManager's autoload warm run exactly as the
## shipped app does, while tracking the WORST main-thread frame gap each second
## (the number the player feels). Mid-warm, spawns an NES the way the spawn menu
## now does — awaiting ModelWarmer.acquire — which must WAIT without freezing,
## then spawns both shells again post-warm to show the steady-state cost.
##
## Ships as com.xenu.retroxr.spawnprobe (QuestSpawnProbe preset):
##   adb logcat -c && adb logcat -s 'godot:*' > probe.log &
##   adb shell monkey -p com.xenu.retroxr.spawnprobe 1

const ROOM_PATH   := "res://Scenes/MainScene.tscn"
const SYSTEM_PATH := "res://Scenes/Objects/system.tscn"

var _phase := "boot"
var _frames := 0
var _last_process_us := 0
var _worst_gap_ms := 0.0
var _watch: Thread = null
var _watch_run := true
var _room: Node = null


func _ready() -> void:
	print("[qwarm] probe start")
	_watch = Thread.new()
	_watch.start(_watchdog)
	_run()


func _process(_delta: float) -> void:
	_frames += 1
	var now := Time.get_ticks_usec()
	if _last_process_us > 0:
		_worst_gap_ms = maxf(_worst_gap_ms, (now - _last_process_us) / 1000.0)
	_last_process_us = now


## Off the main thread: reports even through a wedge, and carries the per-second
## worst frame gap out (read-and-reset — racy but fine for a probe).
func _watchdog() -> void:
	while _watch_run:
		OS.delay_msec(1000)
		var worst := _worst_gap_ms
		_worst_gap_ms = 0.0
		print("[qwarm] t=%5.1fs frames=%5d worst_gap=%6.1f ms  phase='%s'"
			% [Time.get_ticks_msec() / 1000.0, _frames, worst, _phase])


func _run() -> void:
	_phase = "load room"
	var room_scene := load(ROOM_PATH) as PackedScene
	_phase = "add room"
	_room = room_scene.instantiate()
	add_child(_room)
	get_tree().current_scene = _room
	_phase = "settle 1s (warm starting)"
	await _wait_ms(1000)

	# Mid-warm spawn, the way the menu now spawns: acquire first, never block.
	_phase = "acquire nes (mid-warm)"
	var t0 := Time.get_ticks_msec()
	var f0 := _frames
	for path: String in SystemModelRegistry.resolve("nes", "nes").get("requires", []):
		await ModelWarmer.acquire(path)
	var t1 := Time.get_ticks_msec()
	_phase = "add nes (mid-warm)"
	_spawn_system("nes", Vector3(-0.6, 1.0, -0.5))
	var t2 := Time.get_ticks_msec()
	print("[qwarm] MID-WARM nes: waited %d ms (%d frames drawn while waiting), add %d ms"
		% [t1 - t0, _frames - f0, t2 - t1])

	# Let the warm finish, then the steady-state spawns.
	_phase = "wait for warm to finish"
	while not ModelWarmer._shells_finished:
		await get_tree().process_frame
	await _wait_ms(2000)

	for id: String in ["nes", "atari_2600"]:
		_phase = "steady spawn " + id
		var t3 := Time.get_ticks_msec()
		for path: String in SystemModelRegistry.resolve(id, id).get("requires", []):
			await ModelWarmer.acquire(path)
		var t4 := Time.get_ticks_msec()
		_spawn_system(id, Vector3(0.6, 1.0, -0.5))
		var t5 := Time.get_ticks_msec()
		print("[qwarm] STEADY %s: acquire %d ms, add %d ms" % [id, t4 - t3, t5 - t4])
		await _wait_ms(1000)

	_phase = "done"
	print("[qwarm] COMPLETE")
	_watch_run = false
	_watch.wait_to_finish()
	get_tree().quit(0)


func _spawn_system(id: String, pos: Vector3) -> void:
	var sys_scene := load(SYSTEM_PATH) as PackedScene
	var sys := sys_scene.instantiate() as RetroSystem
	sys.systemid = id
	sys.model_id = id
	sys.ignore_gravity = true
	sys.position = pos
	_room.add_child(sys)


func _wait_ms(ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame

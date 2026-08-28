extends Node3D

## On-device spawn probe — finds where a Quest system spawn blocks.
##
## The freeze wedges the MAIN thread inside a single frame, so the main thread
## cannot report it: prints stop, and the last line before silence is whatever
## ran before the block. A watchdog THREAD carries the answer out instead — the
## main thread writes a phase label before each step, the watchdog prints that
## label once a second, so a wedge shows up as the same phase held for tens of
## seconds. The frame counter in the same line separates "process died" from
## "process alive but not ticking".
##
## Ships as its own package (com.xenu.retroxr.spawnprobe) so the real app on the
## headset is untouched — see the QuestSpawnProbe export preset.
##
##   adb logcat -c && adb logcat -s 'godot:*' > probe.log &
##   adb shell monkey -p com.xenu.retroxr.spawnprobe 1

const ROOM_PATH   := "res://Scenes/MainScene.tscn"
const SYSTEM_PATH := "res://Scenes/Objects/system.tscn"
const NES_GLB     := "res://imported-assets/consoles/nes/nes_console.glb"
const NES_SCRIPT  := "res://Scripts/Objects/system_models/nes_model.gd"

## How many times to spawn. The hang is intermittent, so one is not an answer.
const ROUNDS := 6

var _phase := "boot"
var _phase_ms := 0
var _frames := 0
var _tex_mib := 0.0
var _vid_mib := 0.0
var _watch: Thread = null
var _watch_run := true
var _room: Node = null


func _ready() -> void:
	print("[qspawn] probe start")
	_watch = Thread.new()
	_watch.start(_watchdog)
	_run()


func _process(_delta: float) -> void:
	_frames += 1
	# Sampled on the main thread and cached: the watchdog must not touch the
	# servers from its own thread just to print a number.
	_tex_mib = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
	_vid_mib = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0


## Runs off the main thread, so it keeps reporting after the main thread wedges.
func _watchdog() -> void:
	while _watch_run:
		OS.delay_msec(1000)
		print("[qspawn] alive t=%.1fs frames=%d phase='%s' held=%dms tex=%.0f vid=%.0f MiB"
			% [Time.get_ticks_msec() / 1000.0, _frames, _phase,
				Time.get_ticks_msec() - _phase_ms, _tex_mib, _vid_mib])


func _mark(p: String) -> void:
	var prev := _phase
	var held := Time.get_ticks_msec() - _phase_ms
	if prev != "boot":
		print("[qspawn]   %-34s %6d ms" % [prev, held])
	_phase = p
	_phase_ms = Time.get_ticks_msec()


func _run() -> void:
	# 1. The room, so the spawn happens under the real conditions.
	_mark("load room")
	var room_scene := load(ROOM_PATH) as PackedScene
	_mark("instantiate room")
	_room = room_scene.instantiate()
	_mark("add room to tree")
	add_child(_room)
	get_tree().current_scene = _room
	_mark("settle room")
	await _wait(180)
	_mark("idle")
	print("[qspawn] room up — tex=%.0f MiB vid=%.0f MiB" % [_tex_mib, _vid_mib])

	# 2. The fix under test: warm the shells the way the real app now does at boot.
	# The frame counter in the watchdog line is the whole point — it must keep
	# climbing while this runs, or the warm is just the same stall moved earlier.
	# Usually a no-op by now: SceneManager warms during the room settle above, and
	# the watchdog's frame counter across that window is the evidence that it does
	# not block (26 -> 155 while the shells loaded, against a dead 179 when the
	# spawn did the load itself).
	_mark("WARM SHELLS (threaded)")
	await ModelWarmer.warm_shells(self)

	# And the load the spawn will make, now that it is cached: was 6861 ms cold.
	_mark("load NES glb (post-warm)")
	var glb := load(NES_GLB) as PackedScene
	_mark("idle after warm")
	print("[qspawn] warm done — tex=%.0f MiB vid=%.0f MiB glb=%s"
		% [_tex_mib, _vid_mib, "ok" if glb != null else "NULL"])

	# 3. The real thing, repeatedly.
	for i in range(ROUNDS):
		print("[qspawn] --- round %d ---" % (i + 1))
		_mark("load system.tscn r%d" % (i + 1))
		var sys_scene := load(SYSTEM_PATH) as PackedScene
		_mark("instantiate system r%d" % (i + 1))
		var sys := sys_scene.instantiate() as RetroSystem
		sys.systemid = "nes"
		sys.model_id = "nes"
		sys.ignore_gravity = true
		sys.position = Vector3(0.4 * i, 1.0, -0.5)
		# The suspect: _ready -> _load_system_model runs inside this call.
		_mark("add_child system r%d  <-- suspect" % (i + 1))
		_room.add_child(sys)
		_mark("settle r%d" % (i + 1))
		await _wait(90)
		print("[qspawn] round %d done — tex=%.0f MiB vid=%.0f MiB"
			% [i + 1, _tex_mib, _vid_mib])

	_mark("done")
	print("[qspawn] ALL ROUNDS COMPLETE — no hang this run")
	_watch_run = false
	_watch.wait_to_finish()
	get_tree().quit(0)


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame

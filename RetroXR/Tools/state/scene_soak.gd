## Regression test for the scene-change crash: a libretro core running, then
## arcade -> test hallway -> den, unattended. Drives SceneManager from /root so
## it outlives the scenes it swaps.
##
## To run on a Quest, point the QuestTestHall preset at it —
## `run/main_scene.testhall="res://Tools/state/scene_soak.tscn"` in project.godot —
## then export, install and `adb shell monkey -p com.xenu.retroxr.testhall 1`.
## That package needs its own copy of the core and ROM (scoped storage keeps it
## out of the main app's files): push them to /data/local/tmp and `run-as ... cp`
## into `files/libretro/cores/` and `files/roms/smb.nes`.
##
## Prints a heartbeat so "crashed" is distinguishable from "hung", and states up
## front whether the core actually started — a run where it did not proves
## nothing, because Wrapper::FinishTeardown returns early with no core loaded.
## Desktop cannot substitute: Windows leaves the freed mesh mapped, so the
## dangling read this catches does not fault there.
extends Node

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")

var _sys: RetroSystem = null


const SCRATCH_SLOT := "zz_soak_scratch"


func _ready() -> void:
	_drive.call_deferred()


## Covers every exit the soak has, including the timeout and the early quits.
func _exit_tree() -> void:
	for room: String in SceneManager.SLOT_ROOMS:
		var scratch := "%s/%s.json" % [ScenePersistence.new(room).slot_dir(), SCRATCH_SLOT]
		if FileAccess.file_exists(scratch):
			DirAccess.remove_absolute(scratch)


func _drive() -> void:
	get_tree().create_timer(420.0).timeout.connect(func() -> void:
		print("[soak] TIMEOUT — hung rather than crashed"); get_tree().quit(2))
	# Both, because the first one does not hold: SpawnMenuController's deferred
	# setup calls _on_auto_save_changed(AppPrefs.auto_save_scene) once the room is
	# up and turns auto-save back on from the player's prefs. A soak then writes
	# its own idea of the room over their arcade save on every switch. Pointing
	# the active slot at one nothing else reads makes that harmless. Every room
	# that keeps slots, not just the arcade — the soak leaves and re-enters more
	# than one, and each auto-saves into its own set.
	SceneManager.auto_save_on_switch = false
	for room: String in SceneManager.SLOT_ROOMS:
		SceneManager.active_slots[room] = SCRATCH_SLOT

	var arcade: Node = (load("res://Scenes/MainScene.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(arcade)
	get_tree().current_scene = arcade
	for i in 60:
		await get_tree().process_frame
	print("[soak] arcade up")

	if not await _start_core(arcade):
		return
	await _switch("test")
	await _switch("den")
	await _switch("bedroom")
	print("[soak] RESULT: SURVIVED all transitions with a core running")
	get_tree().quit(0)


func _start_core(scene: Node) -> bool:
	_sys = SYSTEM_SCENE.instantiate() as RetroSystem
	_sys.systemid = "nes"
	# Named outright: this package has no core_defaults.json, so the systemid
	# lookup finds nothing and power_on() refuses to start.
	_sys.core_name = "fceumm"
	_sys._video_out_from_save = 1
	scene.add_child(_sys)
	_sys.global_position = Vector3(0.6, 0.85, -0.4)

	for ch in _sys.get_channel_count():
		var tv := TV_SCENE.instantiate() as RetroTV
		scene.add_child(tv)
		tv.global_position = Vector3(-0.5, 0.95 + 0.42 * float(ch), -0.5)
		tv.freeze = true
		_sys.restore_cable_connection(tv, ch)
	for i in 30:
		await get_tree().process_frame

	_sys.rom_path = OS.get_user_data_dir() + "/roms/smb.nes"
	print("[soak] rom=%s exists=%s" % [_sys.rom_path, FileAccess.file_exists(_sys.rom_path)])
	_sys.power_on()
	print("[soak] powered_on=%s" % _sys.is_powered_on)
	if not _sys.is_powered_on:
		print("[soak] RESULT: INVALID — core never started, teardown path not exercised")
		get_tree().quit(3)
		return false

	for i in 420:
		await get_tree().process_frame
	var tv0: RetroTV = _sys.get_channel_tv(0)
	var mat: Material = tv0.get_screen_mesh().get_surface_override_material(0)
	print("[soak] warmed up, screen material=%s" % mat)
	print("[soak] core is running and rendering to a live mesh")
	return true


func _switch(scene_id: String) -> void:
	print("[soak] ==> change_scene('%s') with the core still running" % scene_id)
	SceneManager.change_scene(scene_id)
	for i in 300:
		await get_tree().process_frame
		if i % 60 == 59:
			print("[soak]     alive f%d current=%s" % [i + 1,
				get_tree().current_scene.name if get_tree().current_scene else "<none>"])
	print("[soak] <== reached '%s'" % scene_id)
